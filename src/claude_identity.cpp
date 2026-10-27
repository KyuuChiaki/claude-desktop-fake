#include "claude_identity.h"
#include "time_core.h"
#include "sha256.h"
#define JSMN_STRICT
#define JSMN_STATIC
#include "jsmn.h"

extern "C" {
NTSYSAPI NTSTATUS NTAPI NtQueryInformationFile(HANDLE, PIO_STATUS_BLOCK, PVOID, ULONG, ULONG);
NTSYSAPI BOOLEAN NTAPI RtlEqualUnicodeString(const UNICODE_STRING*, const UNICODE_STRING*, BOOLEAN);
}

namespace {
constexpr ULONG max_manifest_size=65536, max_images=64, max_tokens=1536;
constexpr NTSTATUS invalid_data=static_cast<NTSTATUS>(0xc000000dUL);
struct PartialValue { ULONG title,type,length; BYTE data[1]; };
struct Basic { LARGE_INTEGER creation,access,write,change; ULONG attributes; };
struct Standard { LARGE_INTEGER allocation,size; ULONG links; BOOLEAN pending,directory; };
struct FileId { ULONGLONG volume; BYTE id[16]; };
static_assert(sizeof(Basic)==40 && sizeof(Standard)==24 && sizeof(FileId)==24);
struct Image { WCHAR name[128],path[520],native_path[520]; FileId file; ULONGLONG size; LONGLONG write;cdf::claude::RuntimeBinding runtime; };
struct Manifest { WCHAR signer[64]; ULONG count,version; Image images[max_images]; };
cdf::claude::IdentityStatus identity_status{};
cdf::claude::RuntimeBinding runtime_binding{};

bool Equal(const WCHAR* a,const WCHAR* b) {
    UNICODE_STRING x,y; RtlInitUnicodeString(&x,a); RtlInitUnicodeString(&y,b);
    return RtlEqualUnicodeString(&x,&y,TRUE)!=FALSE;
}
bool BytesEqual(const BYTE* a,const BYTE* b,ULONG size) {
    for (ULONG i=0;i<size;++i) if (a[i]!=b[i]) return false;
    return true;
}
int Hex(char c) {
    if (c>='0' && c<='9') return c-'0';
    if (c>='a' && c<='f') return c-'a'+10;
    if (c>='A' && c<='F') return c-'A'+10;
    return -1;
}
bool Decode(const char* json,const jsmntok_t& t,WCHAR* out,ULONG capacity) {
    ULONG used=0;
    for (int i=t.start;i<t.end;) {
        unsigned c=static_cast<BYTE>(json[i++]);
        if (c=='\\') {
            if (i>=t.end) return false;
            c=static_cast<BYTE>(json[i++]);
            if (c=='u') {
                c=0;
                for (int n=0;n<4;++n) { if (i>=t.end || Hex(json[i])<0) return false; c=(c<<4)|Hex(json[i++]); }
                if (c>=0xd800 && c<=0xdbff) {
                    if (i+6>t.end || json[i++]!='\\' || json[i++]!='u') return false;
                    unsigned low=0;
                    for (int n=0;n<4;++n) { if(Hex(json[i])<0) return false; low=(low<<4)|Hex(json[i++]); }
                    if (low<0xdc00 || low>0xdfff) return false;
                    c=0x10000+((c-0xd800)<<10)+(low-0xdc00);
                } else if (c>=0xdc00 && c<=0xdfff) return false;
            } else if (c!='"' && c!='\\' && c!='/') return false;
        } else if (c>=0x80) {
            unsigned extra=0,min=0;
            if ((c&0xe0)==0xc0) { extra=1; min=0x80; c&=0x1f; }
            else if ((c&0xf0)==0xe0) { extra=2; min=0x800; c&=0x0f; }
            else if ((c&0xf8)==0xf0) { extra=3; min=0x10000; c&=7; }
            else return false;
            while(extra--) { if(i>=t.end || (static_cast<BYTE>(json[i])&0xc0)!=0x80) return false; c=(c<<6)|(static_cast<BYTE>(json[i++])&0x3f); }
            if(c<min || c>0x10ffff || (c>=0xd800 && c<=0xdfff)) return false;
        }
        if(c<32 || c==0x7f || used+(c>0xffff?2:1)>=capacity) return false;
        if(c>0xffff) { c-=0x10000; out[used++]=static_cast<WCHAR>(0xd800+(c>>10)); out[used++]=static_cast<WCHAR>(0xdc00+(c&0x3ff)); }
        else out[used++]=static_cast<WCHAR>(c);
    }
    out[used]=0; return true;
}
struct Reader {
    const char* json; ULONG length,cursor=0; int index=0,count=0; jsmntok_t* tokens;
    void Space() { while(cursor<length && (json[cursor]==' ' || json[cursor]=='\t' || json[cursor]=='\r' || json[cursor]=='\n')) ++cursor; }
    bool Char(char c) { Space(); return cursor<length && json[cursor++]==c; }
    bool Begin(jsmntype_t type,char c,int& children) {
        Space(); if(index>=count || tokens[index].type!=type || tokens[index].start!=static_cast<int>(cursor)) return false;
        children=tokens[index++].size; return Char(c);
    }
    bool Token(jsmntype_t type,jsmntok_t& t,bool key=false) {
        if(index>=count) return false;
        t=tokens[index++]; Space();
        const int start=type==JSMN_STRING?t.start-1:t.start, end=type==JSMN_STRING?t.end+1:t.end;
        if(t.type!=type || t.size!=(key?1:0) || start!=static_cast<int>(cursor) || end<start || end>static_cast<int>(length)) return false;
        cursor=static_cast<ULONG>(end); return true;
    }
    bool String(WCHAR* out,ULONG capacity) { jsmntok_t t; return Token(JSMN_STRING,t) && Decode(json,t,out,capacity); }
    bool Key(WCHAR (&out)[64]) { jsmntok_t t; return Token(JSMN_STRING,t,true) && Decode(json,t,out,64) && Char(':'); }
    bool Number(ULONGLONG& out) {
        jsmntok_t t; if(!Token(JSMN_PRIMITIVE,t) || t.start==t.end || (json[t.start]=='0' && t.end-t.start>1)) return false;
        out=0;
        for(int i=t.start;i<t.end;++i) { if(json[i]<'0' || json[i]>'9') return false; const unsigned d=json[i]-'0'; if(out>(0x7fffffffffffffffULL-d)/10) return false; out=out*10+d; }
        return true;
    }
    bool HexValue(BYTE* out,ULONG bytes) {
        jsmntok_t t; if(!Token(JSMN_STRING,t) || t.end-t.start!=static_cast<int>(bytes*2)) return false;
        for(ULONG i=0;i<bytes;++i) { const int h=Hex(json[t.start+2*i]),l=Hex(json[t.start+2*i+1]); if(h<0 || l<0) return false; out[i]=static_cast<BYTE>((h<<4)|l); }
        return true;
    }
    bool Entry(Image& image) {
        int fields=0; unsigned seen=0;
        if(!Begin(JSMN_OBJECT,'{',fields) || (fields!=7&&fields!=10&&fields!=11)) return false;
        for(int i=0;i<fields;++i) {
            WCHAR key[64]{}; unsigned bit=0;
            if(!Key(key)) return false;
            if(Equal(key,L"name")) { bit=1; if(!String(image.name,128) || !image.name[0]) return false; }
            else if(Equal(key,L"path")) { bit=2; if(!String(image.path,520) || !image.path[0]) return false; }
            else if(Equal(key,L"nativePath")) { bit=4; if(!String(image.native_path,520) || !image.native_path[0]) return false; }
            else if(Equal(key,L"volumeSerial")) { bit=8; BYTE raw[8]{}; if(!HexValue(raw,8)) return false; for(BYTE b:raw) image.file.volume=(image.file.volume<<8)|b; }
            else if(Equal(key,L"fileId")) { bit=16; if(!HexValue(image.file.id,16)) return false; }
            else if(Equal(key,L"size")) { bit=32; if(!Number(image.size) || !image.size) return false; }
            else if(Equal(key,L"lastWriteTimeUtcTicks")) { bit=64; ULONGLONG value=0; if(!Number(value)) return false; image.write=static_cast<LONGLONG>(value); }
            else if(Equal(key,L"runtimeType")){bit=128;if(!String(image.runtime.type,16)||(!Equal(image.runtime.type,L"native")&&!Equal(image.runtime.type,L"electron")))return false;}
            else if(Equal(key,L"adapterId")){bit=256;if(!String(image.runtime.adapter_id,96))return false;}
            else if(Equal(key,L"compatibilityPolicy")){bit=512;if(!String(image.runtime.policy,16)||(!Equal(image.runtime.policy,L"block")&&!Equal(image.runtime.policy,L"passthrough")))return false;}
            else if(Equal(key,L"runtimeBindingSha256")){bit=1024;if(!HexValue(image.runtime.binding_hash,32))return false;}
            else return false;
            if(seen&bit) return false; seen|=bit;
            if(!Char(i+1==fields?'}':',')) return false;
        }
        if((seen!=127&&seen!=1023&&seen!=2047) || image.path[1]!=L':' || image.path[2]!=L'\\' || image.native_path[0]!=L'\\') return false;
        image.runtime.version=fields==11?3:fields==10?2:1;
        const WCHAR* name=image.path;
        for(const WCHAR* p=image.path;*p;++p) if(*p==L'\\') name=p+1;
        if(!Equal(name,image.name)) return false;
        for(ULONG i=0;image.name[i];++i) if(image.name[i]==L'\\' || image.name[i]==L'/' || image.name[i]==L':') return false;
        return true;
    }
};
bool Parse(const char* data,ULONG bytes,Manifest& out) {
    if(!bytes || bytes>max_manifest_size) return false;
    if(bytes>=3 && static_cast<BYTE>(data[0])==0xef && static_cast<BYTE>(data[1])==0xbb && static_cast<BYTE>(data[2])==0xbf) { data+=3; bytes-=3; }
    static jsmntok_t tokens[max_tokens]; cdf::Zero(tokens,sizeof(tokens));
    jsmn_parser parser; jsmn_init(&parser); Reader r{data,bytes,0,0,jsmn_parse(&parser,data,bytes,tokens,max_tokens),tokens};
    int fields=0; unsigned seen=0;
    if(r.count<1 || !r.Begin(JSMN_OBJECT,'{',fields) || fields!=5) return false;
    for(int i=0;i<fields;++i) {
        WCHAR key[64]{},text[64]{}; unsigned bit=0;
        if(!r.Key(key)) return false;
        if(Equal(key,L"schemaVersion")) { bit=1; ULONGLONG v=0; if(!r.Number(v) || (v!=1&&v!=2&&v!=3)) return false;out.version=static_cast<ULONG>(v); }
        else if(Equal(key,L"packageName")) { bit=2; if(!r.String(text,64) || !Equal(text,L"AnthropicPBC.Claude")) return false; }
        else if(Equal(key,L"packageFamily")) { bit=4; if(!r.String(text,64) || !Equal(text,L"AnthropicPBC.Claude_fnn82j28hfe8t")) return false; }
        else if(Equal(key,L"signer")) { bit=8; if(!r.String(out.signer,64) || !Equal(out.signer,L"Anthropic, PBC")) return false; }
        else if(Equal(key,L"images")) {
            bit=16; int images=0;
            if(!r.Begin(JSMN_ARRAY,'[',images) || images<1 || images>static_cast<int>(max_images)) return false;
            for(int j=0;j<images;++j) {
                if(!r.Entry(out.images[j])) return false;
                for(int k=0;k<j;++k) if(Equal(out.images[k].native_path,out.images[j].native_path)) return false;
                if(!r.Char(j+1==images?']':',')) return false;
            }
            out.count=static_cast<ULONG>(images);
        } else return false;
        if(seen&bit) return false; seen|=bit;
        if(!r.Char(i+1==fields?'}':',')) return false;
    }
    for(ULONG i=0;i<out.count;i++)if(out.images[i].runtime.version!=out.version)return false;
    r.Space(); return seen==31 && r.index==r.count && r.cursor==r.length;
}
bool ManifestPath(WCHAR (&path)[512],NTSTATUS& status) {
    UNICODE_STRING name; RtlInitUnicodeString(&name,L"\\REGISTRY\\MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Folders");
    OBJECT_ATTRIBUTES attributes; InitializeObjectAttributes(&attributes,&name,OBJ_CASE_INSENSITIVE,nullptr,nullptr);
    HANDLE key=nullptr; status=NtOpenKey(&key,KEY_QUERY_VALUE|KEY_WOW64_64KEY,&attributes);
    if(status<0) return false;
    RtlInitUnicodeString(&name,L"Common AppData"); alignas(8) BYTE buffer[1024]{}; ULONG returned=0;
    status=NtQueryValueKey(key,&name,2,buffer,sizeof(buffer),&returned); NtClose(key);
    const auto* v=reinterpret_cast<const PartialValue*>(buffer);
    if(status<0) return false;
    if(returned<12 || v->type!=REG_SZ || v->length<6 || v->length%2 || v->length>returned-12 || v->length>768) { status=invalid_data; return false; }
    WCHAR directory[385]{}; cdf::Copy(directory,v->data,v->length);
    if(directory[1]!=L':' || directory[2]!=L'\\' || directory[v->length/2-1]) { status=invalid_data; return false; }
    cdf::CopyText(path,512,L"\\??\\");
    if(!cdf::CopyText(path+4,508,directory)) { status=invalid_data; return false; }
    ULONG n=0; while(path[n]) ++n; if(path[n-1]==L'\\') --n;
#ifdef CDF_CLAUDE_IDENTITY_MANIFEST_TEST
    const WCHAR suffix[]=L"\\ClaudeDesktopFake\\stage3\\claude\\images-test.json";
#else
    const WCHAR suffix[]=L"\\ClaudeDesktopFake\\stage3\\claude\\images.json";
#endif
    if(!cdf::CopyText(path+n,512-n,suffix)) { status=invalid_data; return false; }
    return true;
}
bool ReadManifest(Manifest& out,NTSTATUS& status) {
    cdf::Zero(&out,sizeof(out)); static char data[max_manifest_size]; WCHAR path[512]{};
    if(!ManifestPath(path,status)) return false;
    UNICODE_STRING name; RtlInitUnicodeString(&name,path); OBJECT_ATTRIBUTES attr; InitializeObjectAttributes(&attr,&name,OBJ_CASE_INSENSITIVE,nullptr,nullptr);
    HANDLE file=nullptr; IO_STATUS_BLOCK io{};
    status=NtOpenFile(&file,FILE_READ_DATA|FILE_READ_ATTRIBUTES|SYNCHRONIZE,&attr,&io,FILE_SHARE_READ,FILE_SYNCHRONOUS_IO_NONALERT|FILE_OPEN_REPARSE_POINT);
    if(status<0) return false;
    Basic b{}; Standard s{};
    status=NtQueryInformationFile(file,&io,&b,sizeof(b),4);
    if(status>=0) status=NtQueryInformationFile(file,&io,&s,sizeof(s),5);
    if(status>=0 && ((b.attributes&FILE_ATTRIBUTE_REPARSE_POINT) || s.directory || s.size.QuadPart<=0 || s.size.QuadPart>max_manifest_size)) status=invalid_data;
    if(status>=0) { LARGE_INTEGER offset{}; status=NtReadFile(file,nullptr,nullptr,nullptr,&io,data,static_cast<ULONG>(s.size.QuadPart),&offset,nullptr); if(status>=0 && io.Information!=static_cast<ULONG_PTR>(s.size.QuadPart)) status=invalid_data; }
    NtClose(file);
    if(status<0) return false;
    if(!Parse(data,static_cast<ULONG>(s.size.QuadPart),out)) { status=invalid_data; return false; }
    return true;
}
bool CurrentImage(cdf::claude::IdentityStatus& out) {
    alignas(8) static BYTE image_data[8192]; ULONG returned=0;
    out.reason=static_cast<DWORD>(cdf::claude::Reason::ProcessImageUnavailable);
    out.native_status=NtQueryInformationProcess(reinterpret_cast<HANDLE>(static_cast<LONG_PTR>(-1)),ProcessImageFileName,image_data,sizeof(image_data),&returned);
    if(out.native_status<0) return false;
    const auto* image=reinterpret_cast<const UNICODE_STRING*>(image_data);
    const auto base=reinterpret_cast<ULONG_PTR>(image_data),start=reinterpret_cast<ULONG_PTR>(image->Buffer);
    if(returned<sizeof(*image) || returned>sizeof(image_data) || !image->Length || image->Length%2 || image->Length>=sizeof(out.current_image_path) ||
        start<base+sizeof(*image) || start-base>returned || image->Length>returned-(start-base)) { out.native_status=invalid_data; return false; }
    cdf::Copy(out.current_image_path,image->Buffer,image->Length);
    out.reason=static_cast<DWORD>(cdf::claude::Reason::ImageFileUnavailable);
    UNICODE_STRING path=*image; OBJECT_ATTRIBUTES attr; InitializeObjectAttributes(&attr,&path,OBJ_CASE_INSENSITIVE,nullptr,nullptr);
    IO_STATUS_BLOCK io{}; HANDLE file=nullptr;
    out.native_status=NtOpenFile(&file,FILE_READ_ATTRIBUTES|SYNCHRONIZE,&attr,&io,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,FILE_SYNCHRONOUS_IO_NONALERT|FILE_OPEN_REPARSE_POINT);
    if(out.native_status<0) return false;
    FileId id{}; Basic b{}; Standard s{};
    out.native_status=NtQueryInformationFile(file,&io,&id,sizeof(id),59);
    if(out.native_status>=0) out.native_status=NtQueryInformationFile(file,&io,&b,sizeof(b),4);
    if(out.native_status>=0) out.native_status=NtQueryInformationFile(file,&io,&s,sizeof(s),5);
    NtClose(file);
    if(out.native_status<0) return false;
    if(s.directory || s.size.QuadPart<0 || (b.attributes&FILE_ATTRIBUTE_REPARSE_POINT)) { out.native_status=invalid_data; return false; }
    out.volume_serial=id.volume; cdf::Copy(out.file_id,id.id,16); out.image_size=static_cast<ULONGLONG>(s.size.QuadPart); out.last_write_time=b.write.QuadPart;
    return true;
}
}
namespace cdf::claude {
bool MatchesCurrentImage() {
    auto& out=identity_status; cdf::Zero(&out,sizeof(out)); out.size=sizeof(out); out.version=1; out.state=1;
    if(!CurrentImage(out)) { out.error_code=RtlNtStatusToDosError(out.native_status); return false; }
    out.state|=2; static Manifest manifest{};
    if(!ReadManifest(manifest,out.native_status)) {
        out.reason=static_cast<DWORD>(out.native_status==static_cast<NTSTATUS>(0xc0000034UL) || out.native_status==static_cast<NTSTATUS>(0xc000003aUL) ? Reason::ManifestMissing:Reason::ManifestInvalid);
        out.error_code=RtlNtStatusToDosError(out.native_status); return false;
    }
    out.state|=4; out.image_count=manifest.count; cdf::CopyText(out.signer,64,manifest.signer);
    out.reason=static_cast<DWORD>(Reason::ImageNotListed);
    for(ULONG i=0;i<manifest.count;++i) {
        const auto& entry=manifest.images[i];
        if(!Equal(entry.native_path,out.current_image_path)) continue;
        out.reason=static_cast<DWORD>(Reason::FileIdentityMismatch);
        if(entry.file.volume==out.volume_serial && entry.size==out.image_size && entry.write==out.last_write_time && BytesEqual(entry.file.id,out.file_id,16)) {
            runtime_binding=entry.runtime;
            out.state|=8; out.reason=static_cast<DWORD>(Reason::Matched); cdf::CopyText(out.matched_image_path,520,entry.path); out.error_code=0; return true;
        }
    }
    out.error_code=ERROR_ACCESS_DENIED; return false;
}
void QueryIdentityStatus(IdentityStatus& output) { cdf::Copy(&output,&identity_status,sizeof(output)); }
void QueryRuntimeBinding(RuntimeBinding& output){output=runtime_binding;}
bool ReadRuntimeBinding(compat::Binding& output,DWORD& error){
    WCHAR path[512]{};NTSTATUS status=0;if(!ManifestPath(path,status)){error=RtlNtStatusToDosError(status);return false;}
    ULONG n=0;while(path[n])++n;while(n&&path[n-1]!=L'\\')--n;
    const WCHAR suffix[]=L"bindings\\";if(!CopyText(path+n,512-n,suffix)){error=ERROR_INVALID_DATA;return false;}n+=9;
    const WCHAR digits[]=L"0123456789ABCDEF";
    if(n+69>=512){error=ERROR_INVALID_DATA;return false;}
    for(ULONG i=0;i<32;i++){path[n++]=digits[runtime_binding.binding_hash[i]>>4];path[n++]=digits[runtime_binding.binding_hash[i]&15];}
    CopyText(path+n,512-n,L".bin");
    UNICODE_STRING name;RtlInitUnicodeString(&name,path);OBJECT_ATTRIBUTES attributes;InitializeObjectAttributes(&attributes,&name,OBJ_CASE_INSENSITIVE,nullptr,nullptr);
    HANDLE file=nullptr;IO_STATUS_BLOCK io{};status=NtOpenFile(&file,FILE_READ_DATA|FILE_READ_ATTRIBUTES|SYNCHRONIZE,&attributes,&io,FILE_SHARE_READ,FILE_SYNCHRONOUS_IO_NONALERT|FILE_OPEN_REPARSE_POINT);
    if(status<0){error=RtlNtStatusToDosError(status);return false;}
    Standard length{};Basic basic{};status=NtQueryInformationFile(file,&io,&length,sizeof(length),5);
    if(status>=0)status=NtQueryInformationFile(file,&io,&basic,sizeof(basic),4);
    if(status>=0&&(length.size.QuadPart!=sizeof(output)||length.directory||(basic.attributes&FILE_ATTRIBUTE_REPARSE_POINT)))status=invalid_data;
    LARGE_INTEGER zero{};if(status>=0){status=NtReadFile(file,nullptr,nullptr,nullptr,&io,&output,sizeof(output),&zero,nullptr);if(status>=0&&io.Information!=sizeof(output))status=invalid_data;}
    NtClose(file);if(status<0){error=RtlNtStatusToDosError(status);return false;}
    BYTE hash[32];compat::Sha(reinterpret_cast<const BYTE*>(&output),sizeof(output),hash);
    if(!compat::Equal(hash,runtime_binding.binding_hash,32)){error=ERROR_CRC;return false;}error=0;return true;
}
}
extern "C" __declspec(dllexport) DWORD WINAPI CdfClaudeQueryIdentityStatus(cdf::claude::IdentityStatus* output,DWORD size) {
    if(!output || size!=sizeof(*output)) return ERROR_INVALID_PARAMETER;
    cdf::claude::QueryIdentityStatus(*output); return ERROR_SUCCESS;
}
