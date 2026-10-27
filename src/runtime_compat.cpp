#include "runtime_compat.h"
#include "sha256.h"
#include "time_core.h"

namespace cdf::compat {
namespace {
struct Reference {ULONG displacement,next,target_role,length;const BYTE* bytes;};
struct Template {ULONG role,offset,length;bool capture,unwind;const BYTE* code;const BYTE* mask;const Reference* references;ULONG reference_count;};
struct Family {PCWSTR id;const Template* sites;ULONG count;};
struct Build {PCWSTR id,description;ULONG abi;BYTE engine[32];ULONG rvas[RoleCount];};
struct Exact {BYTE sha[32];ULONG build;};
#include "runtime_catalog.generated.inc"
bool Text(const char* a,const char* b,SIZE_T n=0){for(SIZE_T i=0;!n||i<n;i++){if(a[i]!=b[i])return false;if(!a[i])return true;}return true;}
bool Bounds(SIZE_T start,SIZE_T n,SIZE_T limit){return start<=limit&&n<=limit-start;}
ULONG U32(const BYTE* p){ULONG n=0;Copy(&n,p,4);return n;}
bool TemplateMatches(const Image& image,ULONG site,const Template& t,SiteBinding& result){
    if(site<t.offset)return false;const ULONG begin=site-t.offset;const BYTE* code=image.At(begin,t.length);
    if(!code)return false;
    ULONG entry=0,length=0;
    if(t.unwind&&(!image.Function(site,entry,length)||entry!=begin||length!=t.length))return false;
    for(ULONG i=0;i<t.length;i++)if((code[i]&t.mask[i])!=(t.code[i]&t.mask[i]))return false;
    for(ULONG i=0;i<t.reference_count;i++){
        const auto& reference=t.references[i];if(reference.target_role<RoleCount)continue;
        LONG displacement=0;Copy(&displacement,code+reference.displacement,4);
        const LONGLONG destination=static_cast<LONGLONG>(begin)+reference.next+displacement;
        if(destination<0||destination>MAXDWORD)return false;
        const BYTE* data=image.At(static_cast<ULONG>(destination),reference.length);
        if(!data||!Equal(data,reference.bytes,reference.length))return false;
    }
    result.rva=site;result.function_rva=begin;result.function_size=t.length;Sha(code,t.length,result.code_sha256);return true;
}
ULONG Locate(const Image& image,const Template& t,SiteBinding& result){
    ULONG matches=0;
    const ULONG directory=image.pe+24+112+3*8;
    const auto* functions=image.At(U32(image.data+directory),U32(image.data+directory+4));
    if(t.unwind&&functions){
        const ULONG count=U32(image.data+directory+4)/12;
        for(ULONG i=0;i<count;i++){
            const ULONG begin=U32(functions+i*12),end=U32(functions+i*12+4);
            if(end<begin||end-begin!=t.length)continue;
            SiteBinding candidate{};if(TemplateMatches(image,begin+t.offset,t,candidate)){result=candidate;if(++matches>1)return matches;}
        }
    }else{
        for(ULONG s=0;s<image.section_count;s++){
            const auto& section=image.sections[s];if(!(section.flags&IMAGE_SCN_MEM_EXECUTE)||section.raw_size<t.length)continue;
            for(ULONG i=0;i<=section.raw_size-t.length;i++){
                // Every accepted locator starts with at least twelve exact or
                // constrained instruction bytes. The complete function is then
                // checked; a short prologue never establishes compatibility.
                const BYTE* p=image.data+section.raw+i;bool prefix=true;
                for(ULONG j=0;j<12;j++)if((p[j]&t.mask[j])!=(t.code[j]&t.mask[j])){prefix=false;break;}
                if(!prefix)continue;SiteBinding candidate{};
                if(TemplateMatches(image,section.rva+i+t.offset,t,candidate)){result=candidate;if(++matches>1)return matches;}
            }
        }
    }
    return matches;
}
bool EngineFingerprint(const Image& image,BYTE (&digest)[32]){
    constexpr char sentinel[]="dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX";
    ULONG fuse=0,fuse_count=0;
    for(ULONG s=0;s<image.section_count;s++){
        const auto& sec=image.sections[s];if(!Text(sec.name,".rdata",7))continue;
        for(ULONG i=0;i+sizeof(sentinel)+10<sec.raw_size;i++){
            const BYTE* p=image.data+sec.raw+i;if(!Equal(p,reinterpret_cast<const BYTE*>(sentinel),sizeof(sentinel)-1))continue;
            if(++fuse_count>1||p[32]!=1||p[33]!=9)return false;
            for(ULONG j=0;j<9;j++)if(p[34+j]!='0'&&p[34+j]!='1')return false;
            fuse=sec.raw+i+34;
        }
    }
    if(fuse_count!=1)return false;
    Sha256 hash;hash.Init();constexpr char tag[]="CDFENGINE1";hash.Update(reinterpret_cast<const BYTE*>(tag),sizeof(tag)-1);
    for(ULONG s=0;s<image.section_count;s++){
        const auto& sec=image.sections[s];if(Text(sec.name,".rsrc",6))continue;
        hash.Update(reinterpret_cast<const BYTE*>(sec.name),8);
        const ULONG metadata[]={Text(sec.name,".reloc",7)?0:sec.rva,sec.virtual_size,sec.raw_size,sec.flags};
        hash.Update(reinterpret_cast<const BYTE*>(metadata),sizeof(metadata));
        if(fuse>=sec.raw&&fuse-sec.raw<sec.raw_size){
            hash.Update(image.data+sec.raw,fuse-sec.raw);const BYTE normalized[9]={'?','?','?','?','?','?','?','?','?'};hash.Update(normalized,9);
            hash.Update(image.data+fuse+9,sec.raw_size-(fuse-sec.raw)-9);
        }else hash.Update(image.data+sec.raw,sec.raw_size);
    }
    hash.Finish(digest);return true;
}
bool Relationships(const Image& image,const Binding& binding){
    const auto& family=families[binding.abi_index];
    for(ULONG r=0;r<RoleCount;r++){
        const auto& site=binding.sites[r];if(!site.rva)continue;
        const auto& t=family.sites[site.reserved];const BYTE* code=image.At(site.function_rva,t.length);if(!code)return false;
        for(ULONG i=0;i<t.reference_count;i++){
            const auto& reference=t.references[i];if(reference.target_role>=RoleCount||!binding.sites[reference.target_role].rva)continue;
            LONG displacement=0;Copy(&displacement,code+reference.displacement,4);
            const LONGLONG destination=static_cast<LONGLONG>(site.function_rva)+reference.next+displacement;
            if(destination!=binding.sites[reference.target_role].rva)return false;
        }
    }
    return true;
}
}
bool Equal(const BYTE* a,const BYTE* b,SIZE_T length){for(SIZE_T i=0;i<length;i++)if(a[i]!=b[i])return false;return true;}
void Sha(const BYTE* bytes,SIZE_T length,BYTE (&out)[32]){Sha256 hash;hash.Init();hash.Update(bytes,length);hash.Finish(out);}
bool Image::Open(const BYTE* bytes,SIZE_T length){
    Zero(this,sizeof(*this));data=bytes;size=length;
    if(length<4096||bytes[0]!='M'||bytes[1]!='Z')return false;pe=U32(bytes+60);
    if(!Bounds(pe,264,length)||U32(bytes+pe)!=IMAGE_NT_SIGNATURE)return false;
    USHORT machine=0,optional=0,magic=0,count=0;Copy(&machine,bytes+pe+4,2);Copy(&count,bytes+pe+6,2);Copy(&optional,bytes+pe+20,2);Copy(&magic,bytes+pe+24,2);
    if(machine!=IMAGE_FILE_MACHINE_AMD64||magic!=IMAGE_NT_OPTIONAL_HDR64_MAGIC||optional<240||!count||count>max_sections||!Bounds(pe+24+optional,count*40,length))return false;
    image_size=U32(bytes+pe+24+56);timestamp=U32(bytes+pe+8);section_count=count;
    if(image_size<4096||image_size>0x70000000)return false;
    for(ULONG i=0;i<count;i++){
        const BYTE* p=bytes+pe+24+optional+i*40;auto& s=sections[i];Copy(s.name,p,8);
        s.virtual_size=U32(p+8);s.rva=U32(p+12);s.raw_size=U32(p+16);s.raw=U32(p+20);s.flags=U32(p+36);
        if(!Bounds(s.raw,s.raw_size,length)||!Bounds(s.rva,s.virtual_size,image_size)||!Bounds(s.rva,s.raw_size,image_size))return false;
        for(ULONG j=0;j<i;j++){
            const auto& previous=sections[j];
            if(s.raw_size&&previous.raw_size&&static_cast<SIZE_T>(s.raw)<static_cast<SIZE_T>(previous.raw)+previous.raw_size&&static_cast<SIZE_T>(previous.raw)<static_cast<SIZE_T>(s.raw)+s.raw_size)return false;
            if(s.virtual_size&&previous.virtual_size&&static_cast<SIZE_T>(s.rva)<static_cast<SIZE_T>(previous.rva)+previous.virtual_size&&static_cast<SIZE_T>(previous.rva)<static_cast<SIZE_T>(s.rva)+s.virtual_size)return false;
        }
    }
    return true;
}
const BYTE* Image::At(ULONG rva,SIZE_T length) const{
    for(ULONG i=0;i<section_count;i++){const auto& s=sections[i];if(rva>=s.rva&&Bounds(rva-s.rva,length,s.raw_size))return data+s.raw+(rva-s.rva);}return nullptr;
}
bool Image::Export(const char* name) const{
    const BYTE* exports=At(U32(data+pe+24+112),40);if(!exports)return false;
    const ULONG count=U32(exports+24);if(count>65536)return false;const BYTE* table=At(U32(exports+32),count*4);if(!table)return false;
    for(ULONG i=0;i<count;i++){const BYTE* symbol=At(U32(table+i*4),64);if(symbol&&Text(reinterpret_cast<const char*>(symbol),name,64))return true;}return false;
}
bool Image::Function(ULONG rva,ULONG& begin,ULONG& length) const{
    const ULONG dir=pe+24+112+3*8;const ULONG bytes=U32(data+dir+4);if(bytes%12)return false;
    const BYTE* table=At(U32(data+dir),bytes);if(!table)return false;
    ULONG low=0,high=bytes/12;
    while(low<high){const ULONG mid=low+(high-low)/2;const BYTE* p=table+mid*12;const ULONG first=U32(p),last=U32(p+4);
        if(rva<first)high=mid;else if(rva>=last)low=mid+1;else{begin=first;length=last-first;return true;}}
    return false;
}
bool Resolve(const Image& image,bool capture,bool allow_scan,Result& out){
    Zero(&out,sizeof(out));out.failed_role=RoleCount;auto& b=out.binding;b.magic=binding_magic;b.version=binding_version;b.size=sizeof(b);b.catalog_revision=catalog_revision;b.machine=IMAGE_FILE_MACHINE_AMD64;b.windows_build=19045;b.image_size=image.image_size;b.timestamp=image.timestamp;
    Copy(b.catalog_sha256,catalog_hash,32);Sha(image.data,image.size,b.image_sha256);
    out.runtime=image.Export("node_module_register");
    if(!out.runtime){
        constexpr char signature[]="dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX";
        for(ULONG s=0;s<image.section_count&&!out.runtime;s++){
            const auto& section=image.sections[s];if(!Text(section.name,".rdata",7)||section.raw_size<sizeof(signature))continue;
            for(ULONG i=0;i+sizeof(signature)<=section.raw_size;i++)if(Equal(image.data+section.raw+i,reinterpret_cast<const BYTE*>(signature),sizeof(signature)-1)){out.runtime=true;break;}
        }
    }
    if(!out.runtime){b.match=NativeImage;return true;}
    if(!EngineFingerprint(image,b.engine_sha256)){out.failure=InvalidFuse;return false;}
    ULONG selected=0;bool known=false;
    for(const auto& exact:exact_images)if(Equal(exact.sha,b.image_sha256,32)){selected=exact.build;known=true;b.match=ExactImage;break;}
    if(!known)for(ULONG i=0;i<sizeof(builds)/sizeof(builds[0]);i++)if(Equal(builds[i].engine,b.engine_sha256,32)){selected=i;known=true;b.match=EngineReuse;break;}
    if(!known&&!allow_scan){out.failure=UnknownRuntime;return false;}
    b.engine_index=selected;b.abi_index=builds[selected].abi;b.capture_ready=1;
    CopyText(b.runtime_version,64,known?builds[selected].description:L"ABI validated; product version unverified");
    const auto& family=families[b.abi_index];
    for(ULONG r=0;r<RoleCount;r++){
        const auto& t=family.sites[r];bool matched=false;out.candidates=0;
        for(ULONG variant=0;variant<family.count;variant++){
            const auto& candidate_template=family.sites[variant];if(candidate_template.role!=r)continue;
            SiteBinding candidate{};const ULONG count=known?(TemplateMatches(image,builds[selected].rvas[r],candidate_template,candidate)?1U:0U):Locate(image,candidate_template,candidate);
            if(count>1){out.candidates=count;matched=false;break;}
            if(count==1){
                if(matched&&candidate.rva!=b.sites[r].rva){out.candidates=2;matched=false;break;}
                candidate.reserved=variant;b.sites[r]=candidate;matched=true;out.candidates=1;
            }
        }
        if(!matched){
            if(t.capture)b.capture_ready=0;
            if(t.capture&&!capture)continue;
            out.failed_role=r;out.failure=!known&&out.candidates>1?AmbiguousSite:(t.capture?CaptureUnavailable:MissingSite);return false;
        }
    }
    if(!Relationships(image,b)){out.failure=AbiMismatch;out.failed_role=NodeNavigatorCall;return false;}
    if(!known)b.match=AbiResolved;out.failure=0;return true;
}
bool ValidateBinding(const Image& image,const Binding& b,bool capture,Result& out){
    Zero(&out,sizeof(out));out.failed_role=RoleCount;out.binding=b;out.runtime=true;
    if(b.magic!=binding_magic||b.version!=binding_version||b.size!=sizeof(b)||b.catalog_revision!=catalog_revision||!Equal(b.catalog_sha256,catalog_hash,32)||b.abi_index>=sizeof(families)/sizeof(families[0])||b.engine_index>=sizeof(builds)/sizeof(builds[0])||b.machine!=IMAGE_FILE_MACHINE_AMD64||b.windows_build!=19045||b.match<ExactImage||b.match>AbiResolved||b.runtime_version[63]){out.failure=BindingInvalid;return false;}
    BYTE sha[32];Sha(image.data,image.size,sha);
    if(!Equal(sha,b.image_sha256,32)||image.image_size!=b.image_size||image.timestamp!=b.timestamp){out.failure=BindingStale;return false;}
    if(!EngineFingerprint(image,sha)||!Equal(sha,b.engine_sha256,32)){out.failure=BindingStale;return false;}
    if(capture&&!b.capture_ready){out.failure=CaptureUnavailable;return false;}
    for(ULONG r=0;r<RoleCount;r++){
        const auto& family=families[b.abi_index];if(family.sites[r].capture&&!capture&&!b.sites[r].rva)continue;
        const auto variant=b.sites[r].reserved;
        if(variant>=family.count||family.sites[variant].role!=r){out.failure=BindingInvalid;return false;}
        const auto& t=family.sites[variant];
        SiteBinding site{};if(!TemplateMatches(image,b.sites[r].rva,t,site)||site.function_rva!=b.sites[r].function_rva||site.function_size!=b.sites[r].function_size||!Equal(site.code_sha256,b.sites[r].code_sha256,32)){out.failure=BindingInvalid;out.failed_role=r;return false;}
    }
    if(!Relationships(image,b)){out.failure=AbiMismatch;return false;}return true;
}
bool ValidateMapped(const BYTE* image,ULONG size,const Binding& b,bool capture,ULONG& role){
    for(ULONG r=0;r<RoleCount;r++){
        const auto& t=families[b.abi_index].sites[r];if(t.capture&&!capture)continue;
        const auto& site=b.sites[r];if(!Bounds(site.function_rva,site.function_size,size)){role=r;return false;}
        BYTE sha[32];Sha(image+site.function_rva,site.function_size,sha);if(!Equal(sha,site.code_sha256,32)){role=r;return false;}
        const auto& variant=families[b.abi_index].sites[site.reserved];
        for(ULONG i=0;i<variant.reference_count;i++){
            const auto& reference=variant.references[i];if(reference.target_role<RoleCount)continue;
            LONG displacement=0;Copy(&displacement,image+site.function_rva+reference.displacement,4);
            const LONGLONG destination=static_cast<LONGLONG>(site.function_rva)+reference.next+displacement;
            if(destination<0||!Bounds(static_cast<SIZE_T>(destination),reference.length,size)||!Equal(image+destination,reference.bytes,reference.length)){role=r;return false;}
        }
    }return true;
}
const WCHAR* RoleName(ULONG r){const WCHAR* names[]={L"DefaultLocale",L"PublicLocale",L"StringCtor",L"NodeNavigatorCall",L"HandleScopeCtor",L"TryCatchCtor",L"TryCatchDtor",L"HandleScopeDtor",L"CurrentContext",L"NewString",L"Compile",L"Run",L"Utf8Length",L"WriteUtf8"};return r<RoleCount?names[r]:L"unknown";}
const WCHAR* AbiName(ULONG i){return i<sizeof(families)/sizeof(families[0])?families[i].id:L"";}
const WCHAR* EngineName(ULONG i){return i<sizeof(builds)/sizeof(builds[0])?builds[i].id:L"";}
const WCHAR* EngineVersion(ULONG i){return i<sizeof(builds)/sizeof(builds[0])?builds[i].description:L"";}
void BindingName(const Binding& b,WCHAR (&out)[96]){
    if(b.match!=AbiResolved){CopyText(out,96,EngineName(b.engine_index));return;}
    CopyText(out,96,L"resolved-");const WCHAR digits[]=L"0123456789ABCDEF";
    for(ULONG i=0;i<8;i++){out[9+2*i]=digits[b.engine_sha256[i]>>4];out[10+2*i]=digits[b.engine_sha256[i]&15];}out[25]=0;
}
const char* FailureName(ULONG f){const char* names[]={"none","invalid-pe","unsupported-windows-build","unknown-fingerprint","missing-site","ambiguous-site","abi-mismatch","invalid-fuse","binding-missing","binding-invalid","binding-stale","capture-unavailable","mapped-code-changed","unsupported-symbols"};return f<sizeof(names)/sizeof(names[0])?names[f]:"unknown";}
ULONG CatalogRevision(){return catalog_revision;}const BYTE* CatalogHash(){return catalog_hash;}ULONG EngineCount(){return sizeof(builds)/sizeof(builds[0]);}
}
