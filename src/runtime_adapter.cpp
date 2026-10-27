#include "runtime_adapter.h"
#include "runtime_provider.h"
#include "runtime_capture.h"
#include "sha256.h"
#if defined(CDF_CLAUDE_IDENTITY_REQUIRED)
#include "claude_identity.h"
#endif
#include <intrin.h>
extern "C" {
NTSYSAPI NTSTATUS NTAPI NtProtectVirtualMemory(HANDLE,PVOID*,PSIZE_T,ULONG,PULONG);
NTSYSAPI NTSTATUS NTAPI NtFlushInstructionCache(HANDLE,PVOID,ULONG);
NTSYSAPI NTSTATUS NTAPI NtQueryVirtualMemory(HANDLE,PVOID,ULONG,PVOID,SIZE_T,PSIZE_T);
NTSYSAPI NTSTATUS NTAPI RtlGetVersion(OSVERSIONINFOW*);
NTSYSAPI NTSTATUS NTAPI NtAllocateVirtualMemory(HANDLE,PVOID*,ULONG_PTR,PSIZE_T,ULONG,ULONG);
NTSYSAPI NTSTATUS NTAPI NtFreeVirtualMemory(HANDLE,PVOID*,PSIZE_T,ULONG);
NTSYSAPI NTSTATUS NTAPI NtQueryInformationFile(HANDLE,PIO_STATUS_BLOCK,PVOID,ULONG,ULONG);
#if defined(CDF_CLAUDE_IDENTITY_MANIFEST_TEST)
NTSYSAPI NTSTATUS NTAPI RtlQueryEnvironmentVariable_U(PVOID,PCUNICODE_STRING,PUNICODE_STRING);
#endif
}
namespace {
cdf::AdapterState state{};
cdf::compat::Binding resolved{};
CdfRuntimeCompatibilityStatus compatibility_status{};
BYTE locale_prolog[14]{},public_prolog[20]{};
BYTE* target=nullptr;BYTE patch[14]{};bool installed=false;
BYTE* public_target=nullptr;BYTE public_patch[20]{};bool public_installed=false;
ULONG target_protection=0,public_protection=0;
struct RuntimeString { BYTE bytes[24]; };
RuntimeString default_locale{};
char locale_text[LOCALE_NAME_MAX_LENGTH]{};
char ui_text[LOCALE_NAME_MAX_LENGTH]{};
BYTE* Image();
// Verified libc++ ABI descriptor, never a MSVC std::string object. This is a
// read-only borrowed reference; V8 copies it through its own string constructor.
const RuntimeString* __cdecl DefaultLocale(PVOID isolate){
    if(cdf::RuntimeConfigSnapshot().runtime.capture)cdf::CaptureContext(isolate,Image());
    return &default_locale;
}
RuntimeString* __cdecl PublicLocale(PVOID,RuntimeString* output){
    const bool node_navigator=_ReturnAddress()==Image()+resolved.sites[cdf::compat::NodeNavigatorCall].rva+5;
    PCSTR text=node_navigator?ui_text:locale_text;SIZE_T n=0;while(text[n])++n;
    if(n<23){cdf::Zero(output,sizeof(*output));output->bytes[0]=static_cast<BYTE>(n*2);cdf::Copy(output->bytes+1,text,n);return output;}
    // Use the runtime's verified own string constructor for long results, so
    // its allocator/destructor own the resulting memory.
    return reinterpret_cast<RuntimeString*(__cdecl*)(RuntimeString*,PCSTR,SIZE_T)>(cdf::RuntimeAddress(cdf::compat::StringCtor))(output,text,n);
}
bool Same(const BYTE* a,const BYTE* b,SIZE_T n){while(n--)if(*a++!=*b++)return false;return true;}
#if defined(CDF_CLAUDE_IDENTITY_MANIFEST_TEST)
bool InjectFailure(PCWSTR expected){
    UNICODE_STRING name,value;WCHAR text[32]{};RtlInitUnicodeString(&name,L"CDF_RUNTIME_TEST_FAULT");
    value.Buffer=text;value.Length=0;value.MaximumLength=sizeof(text);
    ULONG wanted=0;while(expected[wanted])++wanted;
    if(wanted>=32)return false;
    if(RtlQueryEnvironmentVariable_U(nullptr,&name,&value)>=0&&value.Length==wanted*sizeof(WCHAR)){
        bool equal=true;for(unsigned i=0;i<wanted;i++)if(text[i]!=expected[i])equal=false;
        if(equal)return true;
    }
    // Chromium sanitizes environment variables in some child-process paths.
    // A fixed isolated-test-only marker exercises the same failure in every
    // child without adding any production configuration or runtime behavior.
    RtlInitUnicodeString(&name,L"\\??\\C:\\ProgramData\\ClaudeDesktopFake\\stage3\\claude\\runtime-test-fault.txt");
    OBJECT_ATTRIBUTES attributes;InitializeObjectAttributes(&attributes,&name,OBJ_CASE_INSENSITIVE,nullptr,nullptr);
    IO_STATUS_BLOCK io{};HANDLE file=nullptr;
    if(NtOpenFile(&file,FILE_READ_DATA|SYNCHRONIZE,&attributes,&io,FILE_SHARE_READ,FILE_SYNCHRONOUS_IO_NONALERT)<0)return false;
    char data[32]{};LARGE_INTEGER offset{};const NTSTATUS read=NtReadFile(file,nullptr,nullptr,nullptr,&io,data,sizeof(data),&offset,nullptr);NtClose(file);
    if(read<0||io.Information!=wanted)return false;
    for(unsigned i=0;i<wanted;i++)if(data[i]!=static_cast<char>(expected[i]))return false;
    return true;
}
#endif
BYTE* Image(){return *reinterpret_cast<BYTE**>(__readgsqword(0x60)+0x10);}
IMAGE_NT_HEADERS64* Header(BYTE* image){
    const auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(image);
    if(dos->e_magic!=IMAGE_DOS_SIGNATURE||dos->e_lfanew<64||dos->e_lfanew>1048576)return nullptr;
    auto* pe=reinterpret_cast<IMAGE_NT_HEADERS64*>(image+dos->e_lfanew);
    return pe->Signature==IMAGE_NT_SIGNATURE&&pe->FileHeader.Machine==IMAGE_FILE_MACHINE_AMD64&&pe->OptionalHeader.Magic==IMAGE_NT_OPTIONAL_HDR64_MAGIC?pe:nullptr;
}
struct ImageFile {
    HANDLE file=nullptr;PVOID mapping=nullptr;SIZE_T length=0;
    ~ImageFile(){if(mapping){SIZE_T zero=0;NtFreeVirtualMemory(reinterpret_cast<HANDLE>(-1),&mapping,&zero,MEM_RELEASE);}if(file)NtClose(file);}
    bool Open(){
        alignas(8) BYTE data[4096]{};ULONG returned=0;
        NTSTATUS status=NtQueryInformationProcess(reinterpret_cast<HANDLE>(-1),ProcessImageFileName,data,sizeof(data),&returned);
        if(status<0){state.error_code=RtlNtStatusToDosError(status);return false;}
        auto* path=reinterpret_cast<UNICODE_STRING*>(data);OBJECT_ATTRIBUTES attributes;InitializeObjectAttributes(&attributes,path,OBJ_CASE_INSENSITIVE,nullptr,nullptr);IO_STATUS_BLOCK io{};
        status=NtOpenFile(&file,FILE_READ_DATA|FILE_READ_ATTRIBUTES|SYNCHRONIZE,&attributes,&io,FILE_SHARE_READ|FILE_SHARE_DELETE,FILE_SYNCHRONOUS_IO_NONALERT|FILE_OPEN_REPARSE_POINT);
        struct Standard {LARGE_INTEGER allocation,size;ULONG links;BOOLEAN pending,directory;} info{};
        if(status>=0)status=NtQueryInformationFile(file,&io,&info,sizeof(info),5);
        if(status>=0&&(info.directory||info.size.QuadPart<=0||info.size.QuadPart>0x7fffffff))status=static_cast<NTSTATUS>(0xc000000dUL);
        // Chromium installs its section-map interception in sandbox children
        // before the loader runs providers. Mapping a raw PE through that hook
        // before CRT initialization is unsafe. Native reads avoid that path.
        SIZE_T reserve=static_cast<SIZE_T>(info.size.QuadPart);
        if(status>=0)status=NtAllocateVirtualMemory(reinterpret_cast<HANDLE>(-1),&mapping,0,&reserve,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
        for(LONGLONG offset=0;status>=0&&offset<info.size.QuadPart;){
            const ULONG count=static_cast<ULONG>(info.size.QuadPart-offset>1048576?1048576:info.size.QuadPart-offset);LARGE_INTEGER position;position.QuadPart=offset;
            status=NtReadFile(file,nullptr,nullptr,nullptr,&io,static_cast<BYTE*>(mapping)+offset,count,&position,nullptr);
            if(status>=0&&io.Information!=count)status=static_cast<NTSTATUS>(0xc000000dUL);offset+=count;
        }
        if(status<0){state.error_code=RtlNtStatusToDosError(status);return false;}length=static_cast<SIZE_T>(info.size.QuadPart);return true;
    }
};
#if !defined(CDF_CLAUDE_IDENTITY_REQUIRED)
bool ReadSmall(PCWSTR path,PVOID output,ULONG bytes){
    UNICODE_STRING name;RtlInitUnicodeString(&name,path);OBJECT_ATTRIBUTES attributes;InitializeObjectAttributes(&attributes,&name,OBJ_CASE_INSENSITIVE,nullptr,nullptr);HANDLE file=nullptr;IO_STATUS_BLOCK io{};
    const NTSTATUS opened=NtOpenFile(&file,FILE_READ_DATA|SYNCHRONIZE,&attributes,&io,FILE_SHARE_READ,FILE_SYNCHRONOUS_IO_NONALERT|FILE_OPEN_REPARSE_POINT);
    if(opened<0)return false;LARGE_INTEGER zero{};const NTSTATUS read=NtReadFile(file,nullptr,nullptr,nullptr,&io,output,bytes,&zero,nullptr);NtClose(file);return read>=0&&io.Information==bytes;
}
bool GenericBinding(const BYTE (&image_hash)[32],bool& present){
    WCHAR path[256]=L"\\??\\C:\\ProgramData\\ClaudeDesktopFake\\stage2\\bindings\\";ULONG n=0;while(path[n])++n;const WCHAR digits[]=L"0123456789ABCDEF";
    for(unsigned i=0;i<32;i++){path[n+2*i]=digits[image_hash[i]>>4];path[n+2*i+1]=digits[image_hash[i]&15];}cdf::CopyText(path+n+64,256-n-64,L".ref");
    char reference[64]{};present=ReadSmall(path,reference,64);if(!present)return false;
    BYTE hash[32]{};for(unsigned i=0;i<64;i++){
        unsigned v=0;if(reference[i]>='0'&&reference[i]<='9')v=reference[i]-'0';else if(reference[i]>='A'&&reference[i]<='F')v=reference[i]-'A'+10;else return false;
        hash[i/2]=static_cast<BYTE>((hash[i/2]<<4)|v);path[n+i]=static_cast<WCHAR>(reference[i]);
    }
    cdf::CopyText(path+n+64,256-n-64,L".bin");if(!ReadSmall(path,&resolved,sizeof(resolved)))return false;
    BYTE actual[32];cdf::compat::Sha(reinterpret_cast<const BYTE*>(&resolved),sizeof(resolved),actual);return Same(actual,hash,32);
}
#endif
bool Executable(BYTE* address,SIZE_T length){
    MEMORY_BASIC_INFORMATION info{};SIZE_T returned=0;
    if(NtQueryVirtualMemory(reinterpret_cast<HANDLE>(-1),address,0,&info,sizeof(info),&returned)<0)return false;
    const auto start=reinterpret_cast<ULONG_PTR>(info.BaseAddress),value=reinterpret_cast<ULONG_PTR>(address);
    return info.Type==MEM_IMAGE&&info.State==MEM_COMMIT&&!(info.Protect&(PAGE_GUARD|PAGE_NOACCESS))&&
        (info.Protect&(PAGE_EXECUTE_READ|PAGE_EXECUTE_WRITECOPY))&&value>=start&&length<=info.RegionSize-(value-start);
}
bool Mitigations(){
    // No executable allocator or dynamic trampoline is used. CFG strict mode
    // requires all participating images to be CFG instrumented; this no-CRT
    // provider does not claim that capability. Tail jumps preserve CET's return
    // stack, and the image is linked CETCOMPAT. Unknown policy data is rejected.
    struct Policy {ULONG kind,flags;};
    for(const ULONG kind:{2U,7U,16U}){
        Policy p{kind,0};const NTSTATUS status=NtQueryInformationProcess(reinterpret_cast<HANDLE>(-1),static_cast<PROCESSINFOCLASS>(52),&p,sizeof(p),nullptr);
        if(status<0){state.error_code=RtlNtStatusToDosError(status);return false;}
        if((kind==2&&(p.flags&1))||(kind==7&&(p.flags&4))){state.error_code=ERROR_ACCESS_DISABLED_BY_POLICY;return false;}
    }
    return true;
}
bool Write(BYTE* address,const BYTE* bytes,ULONG length,ULONG& original_protection){
#if defined(CDF_CLAUDE_IDENTITY_MANIFEST_TEST)
    // Simulate an actual protection denial, including repeated denial during
    // rollback. The first successful protection call is the only operation
    // that sets original_protection, so zero proves this site was never written.
    if((!original_protection&&InjectFailure(L"deny-first-protect"))||
        (address==public_target&&InjectFailure(L"deny-second-protect"))){state.error_code=ERROR_ACCESS_DENIED;return false;}
#endif
    PVOID page=address;SIZE_T size=length;ULONG previous=0;
    NTSTATUS s=NtProtectVirtualMemory(reinterpret_cast<HANDLE>(-1),&page,&size,PAGE_EXECUTE_READWRITE,&previous);
    if(s<0){state.error_code=RtlNtStatusToDosError(s);return false;}
    if(!original_protection)original_protection=previous;
    cdf::Copy(address,bytes,length);ULONG discarded=0;
    s=NtProtectVirtualMemory(reinterpret_cast<HANDLE>(-1),&page,&size,original_protection,&discarded);
    const NTSTATUS flushed=NtFlushInstructionCache(reinterpret_cast<HANDLE>(-1),address,length);
    if(s<0||flushed<0){state.error_code=RtlNtStatusToDosError(s<0?s:flushed);return false;}return true;
}
}
namespace cdf {
bool PrepareAdapter(const Config& config){
    if(config.schema_version!=3||!config.runtime.enabled)return true;
    OSVERSIONINFOW os{};os.dwOSVersionInfoSize=sizeof(os);
    if(RtlGetVersion(&os)<0||os.dwBuildNumber!=19045){state.error_stage=10;state.error_code=ERROR_OLD_WIN_VERSION;return false;}
    state.error_stage=10;auto* image=Image();auto* pe=Header(image);
    if(!pe){state.error_code=ERROR_BAD_EXE_FORMAT;return false;}
    state.compatibility=2;
    compatibility_status.size=sizeof(compatibility_status);compatibility_status.version=1;compatibility_status.state=1;
    ImageFile file;if(!file.Open())return false;
    compat::Image raw{};compat::Result result{};
    if(!raw.Open(static_cast<const BYTE*>(file.mapping),file.length)){state.error_code=ERROR_BAD_EXE_FORMAT;return false;}
    compat::Sha(raw.data,raw.size,state.fingerprint);bool loaded=false,present=false;
#if defined(CDF_CLAUDE_IDENTITY_REQUIRED)
    claude::RuntimeBinding binding{};claude::QueryRuntimeBinding(binding);
    bool binding_hash=false;for(BYTE value:binding.binding_hash)if(value)binding_hash=true;
    if(binding.version==3&&binding.type[0]==L'e'&&binding_hash){
        present=true;loaded=claude::ReadRuntimeBinding(resolved,state.error_code);
    }
#else
    loaded=GenericBinding(state.fingerprint,present);
#endif
    bool valid=false;
    if(present){
        if(loaded)valid=compat::ValidateBinding(raw,resolved,config.runtime.capture,result);
        else result.failure=compat::BindingInvalid;
    }else{valid=compat::Resolve(raw,config.runtime.capture,false,result);if(valid)resolved=result.binding;}
    auto& diagnostic=compatibility_status;
    diagnostic.failure=result.failure;diagnostic.failed_role=result.failed_role;diagnostic.binding_loaded=loaded;
    diagnostic.match=result.binding.match;diagnostic.catalog_revision=compat::CatalogRevision();Copy(diagnostic.catalog_sha256,compat::CatalogHash(),32);Copy(diagnostic.image_sha256,state.fingerprint,32);
    if(!valid){
        state.error_stage=present?15:result.failure==compat::UnknownRuntime?10:11;
        state.error_code=state.error_code?state.error_code:result.failure==compat::UnknownRuntime?ERROR_REVISION_MISMATCH:ERROR_INVALID_DATA;
        diagnostic.error_code=state.error_code;return false;
    }
    if(resolved.match==compat::NativeImage){state.compatibility=0;state.error_stage=state.error_code=0;diagnostic.core_ready=1;return true;}
    Copy(diagnostic.engine_sha256,resolved.engine_sha256,32);compat::Sha(reinterpret_cast<const BYTE*>(&resolved),sizeof(resolved),diagnostic.binding_sha256);
    CopyText(diagnostic.abi_id,64,compat::AbiName(resolved.abi_index));compat::BindingName(resolved,diagnostic.engine_id);
    for(ULONG r=0;r<compat::RoleCount;r++){diagnostic.rvas[r]=resolved.sites[r].rva;if(diagnostic.rvas[r])++diagnostic.site_count;}
    diagnostic.capture_ready=resolved.capture_ready;
    state.compatibility=1;compat::BindingName(resolved,state.id);CopyText(state.version,64,resolved.runtime_version);
    if(!config.locale.enabled){state.error_stage=0;diagnostic.core_ready=1;return true;}
    state.error_stage=11;ULONG failed=0;
    if(!compat::ValidateMapped(image,pe->OptionalHeader.SizeOfImage,resolved,config.runtime.capture,failed)){
        diagnostic.failure=compat::MemoryChanged;diagnostic.failed_role=failed;state.error_code=ERROR_INVALID_DATA;diagnostic.error_code=state.error_code;return false;
    }
    target=image+resolved.sites[compat::DefaultLocale].rva;public_target=image+resolved.sites[compat::PublicLocale].rva;
    Copy(locale_prolog,target,sizeof(locale_prolog));Copy(public_prolog,public_target,sizeof(public_prolog));
    for(ULONG r=0;r<compat::RoleCount;r++){
        if(r>=compat::HandleScopeCtor&&!config.runtime.capture)continue;
        if(!Executable(image+resolved.sites[r].function_rva,resolved.sites[r].function_size)){state.error_code=ERROR_ACCESS_DENIED;return false;}
    }
    state.error_stage=14;
    if(!Executable(target,sizeof(patch))||!Executable(public_target,sizeof(public_patch))){state.error_code=ERROR_ACCESS_DENIED;return false;}
    if(!Mitigations())return false;
    SIZE_T n=0;while(config.locale.format_locale[n]&&n<LOCALE_NAME_MAX_LENGTH-1){locale_text[n]=static_cast<char>(config.locale.format_locale[n]);++n;}
    for(SIZE_T i=0;config.locale.ui_language[i]&&i<LOCALE_NAME_MAX_LENGTH-1;i++)ui_text[i]=static_cast<char>(config.locale.ui_language[i]);
    Zero(&default_locale,sizeof(default_locale));
    if(n<23){default_locale.bytes[0]=static_cast<BYTE>(n*2);Copy(default_locale.bytes+1,locale_text,n);}
    else{*reinterpret_cast<ULONGLONG*>(default_locale.bytes)=((n+16)&~15ULL)|1;*reinterpret_cast<SIZE_T*>(default_locale.bytes+8)=n;*reinterpret_cast<PCSTR*>(default_locale.bytes+16)=locale_text;}
    patch[0]=0xff;patch[1]=0x25;for(unsigned i=2;i<6;i++)patch[i]=0;
    *reinterpret_cast<PVOID*>(patch+6)=reinterpret_cast<PVOID>(DefaultLocale);
    Copy(public_patch,patch,sizeof(patch));for(unsigned i=14;i<20;i++)public_patch[i]=0x90;
    *reinterpret_cast<PVOID*>(public_patch+6)=reinterpret_cast<PVOID>(PublicLocale);
    state.error_stage=12;
    installed=true;
    if(!Write(target,patch,sizeof(patch),target_protection)){RollbackAdapter();return false;}
#if defined(CDF_CLAUDE_IDENTITY_MANIFEST_TEST)
    // Only the isolated gate-test binary contains fault injection. This point
    // deliberately leaves one installed patch for the real rollback path.
    if(InjectFailure(L"after-first-patch")){state.error_code=ERROR_WRITE_FAULT;RollbackAdapter();return false;}
#endif
    public_installed=true;
    if(!Write(public_target,public_patch,sizeof(public_patch),public_protection)){RollbackAdapter();return false;}
    state.patch_count=2;state.error_code=state.error_stage=0;compatibility_status.core_ready=1;compatibility_status.state|=2;return true;
}
bool RollbackAdapter(){
    if(public_installed){
        if(!Same(public_target,public_patch,20)&&!Same(public_target,public_prolog,20)){state.error_code=ERROR_INVALID_DATA;return false;}
        // A failed first NtProtectVirtualMemory leaves the original bytes and
        // protection untouched. Requiring another write here would turn safe
        // passthrough into process termination under the same protection denial.
        if((public_protection||!Same(public_target,public_prolog,20))&&!Write(public_target,public_prolog,20,public_protection))return false;
        public_installed=false;
    }
    if(!installed)return true;
    if(!Same(target,patch,14)&&!Same(target,locale_prolog,14)){state.error_code=ERROR_INVALID_DATA;return false;}
    if((target_protection||!Same(target,locale_prolog,14))&&!Write(target,locale_prolog,14,target_protection))return false;
    installed=false;state.patch_count=0;return true;
}
void QueryAdapter(AdapterState& output){output=state;}
PVOID RuntimeAddress(compat::Role role){return Image()+resolved.sites[role].rva;}
}

extern "C" __declspec(dllexport) DWORD WINAPI CdfRuntimeQueryCompatibilityStatus(CdfRuntimeCompatibilityStatus* output,DWORD size){
    if(!output||size!=sizeof(*output))return ERROR_INVALID_PARAMETER;
    cdf::Copy(output,&compatibility_status,sizeof(*output));output->size=sizeof(*output);output->version=1;return ERROR_SUCCESS;
}
