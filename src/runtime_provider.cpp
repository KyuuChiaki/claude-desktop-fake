#include "runtime_provider.h"
#include "locale_native.h"
#include "runtime_adapter.h"
#include "runtime_capture.h"
#if defined(CDF_CLAUDE_IDENTITY_REQUIRED)
#include "claude_identity.h"
#endif
#include <intrin.h>
extern "C" NTSYSAPI NTSTATUS NTAPI NtTerminateProcess(HANDLE,NTSTATUS);
extern "C" NTSYSAPI BOOLEAN NTAPI RtlEqualUnicodeString(const UNICODE_STRING*,const UNICODE_STRING*,BOOLEAN);
extern "C" __declspec(dllexport) DWORD WINAPI CdfRuntimeQueryStatus(CdfRuntimeStatus*,DWORD);

namespace {
cdf::Config config{};
bool prepared=false,time_active=false,locale_active=false,region_active=false,passthrough=false;
DWORD runtime_error=0,runtime_stage=0;
CdfRuntimeStatus runtime_status{};volatile LONG runtime_sequence=0;
void Publish(){_InterlockedIncrement(&runtime_sequence);CdfRuntimeQueryStatus(&runtime_status,sizeof(runtime_status));_InterlockedIncrement(&runtime_sequence);}
cdf::verifier::ThunkDescriptor *base_time=nullptr,*kernel_time=nullptr,*native_time=nullptr;
PVOID native_query_export=nullptr;
cdf::verifier::ThunkDescriptor *base_geo[2]{},*kernel_geo[2]{};
alignas(8) volatile LONG64 process_calls=0,native_calls=0,activation_calls=0,region_calls=0;
DWORD tls_index=TLS_OUT_OF_INDEXES;
decltype(&TlsAlloc) tls_alloc=nullptr;
decltype(&TlsFree) tls_free=nullptr;
decltype(&TlsGetValue) tls_get=nullptr;
decltype(&TlsSetValue) tls_set=nullptr;
struct Thread { ULONG process_depth,capture_depth; };
PVOID Heap(){return NtCurrentTeb()->ProcessEnvironmentBlock->Reserved4[1];}
Thread* CurrentThread(bool create){
    if(tls_index==TLS_OUT_OF_INDEXES)return nullptr;
    const DWORD saved=RtlGetLastWin32Error();auto* value=static_cast<Thread*>(tls_get(tls_index));
    if(!value&&create){value=static_cast<Thread*>(RtlAllocateHeap(Heap(),HEAP_ZERO_MEMORY,sizeof(Thread)));
        if(value&&!tls_set(tls_index,value)){RtlFreeHeap(Heap(),0,value);value=nullptr;}}
    RtlSetLastWin32Error(saved);return value;
}
void InitTls(){
    if(time_active&&!native_query_export)native_query_export=cdf::ResolveLoaded(L"ntdll.dll","NtQueryInformationProcess");
    if(tls_index!=TLS_OUT_OF_INDEXES||!prepared)return;
    tls_alloc=reinterpret_cast<decltype(tls_alloc)>(cdf::ResolveLoaded(L"kernelbase.dll","TlsAlloc"));
    tls_free=reinterpret_cast<decltype(tls_free)>(cdf::ResolveLoaded(L"kernelbase.dll","TlsFree"));
    tls_get=reinterpret_cast<decltype(tls_get)>(cdf::ResolveLoaded(L"kernelbase.dll","TlsGetValue"));
    tls_set=reinterpret_cast<decltype(tls_set)>(cdf::ResolveLoaded(L"kernelbase.dll","TlsSetValue"));
    if(tls_alloc&&tls_free&&tls_get&&tls_set)tls_index=tls_alloc();
}
struct ProcessTimes { LARGE_INTEGER creation,exit,kernel,user; };
static_assert(sizeof(ProcessTimes)==32);
void Adjust(FILETIME& value,bool preserve_zero){
    const LONGLONG input=cdf::FileTicks(value);LONGLONG output=0;
    if((!preserve_zero||input!=0)&&cdf::AddTicks(input,config.offset_ticks,output))cdf::ToFileTime(output,value);
}
BOOL WINAPI HookGetProcessTimes(HANDLE process,LPFILETIME creation,LPFILETIME exit,LPFILETIME kernel,LPFILETIME user){
    auto raw=reinterpret_cast<decltype(&GetProcessTimes)>((base_time&&base_time->old_address)?base_time->old_address:kernel_time->old_address);
    auto* t=CurrentThread(true);
    // Failure to allocate state must never allow a nested Native call to apply
    // a second offset. Report an ordinary Win32 resource failure instead.
    if(time_active&&!t){RtlSetLastWin32Error(ERROR_NOT_ENOUGH_MEMORY);return FALSE;}
    if(t)++t->process_depth;
    const BOOL result=raw(process,creation,exit,kernel,user);const DWORD last=RtlGetLastWin32Error();
    if(t)--t->process_depth;
    if(result&&time_active){
        _InterlockedIncrement64(&process_calls);
        // Preserve final-writer semantics when callers alias the output buffers.
        // Windows writes creation, exit, kernel, user in that order.
        if(creation!=exit&&creation!=kernel&&creation!=user)Adjust(*creation,false);
        if(exit!=kernel&&exit!=user)Adjust(*exit,true);
    }
    RtlSetLastWin32Error(last);return result;
}
NTSTATUS NTAPI HookNtQueryInformationProcess(HANDLE process,PROCESSINFOCLASS kind,PVOID output,ULONG length,PULONG returned){
    auto raw=reinterpret_cast<decltype(&NtQueryInformationProcess)>(native_time->old_address);
    const NTSTATUS result=raw(process,kind,output,length,returned);const DWORD last=RtlGetLastWin32Error();
    if(result>=0&&time_active&&static_cast<ULONG>(kind)==4&&output&&length>=sizeof(ProcessTimes)){
        auto* t=CurrentThread(false);
        if(!t||!t->process_depth){
            _InterlockedIncrement64(&native_calls);auto* times=static_cast<ProcessTimes*>(output);LONGLONG value=0;
            if(cdf::AddTicks(times->creation.QuadPart,config.offset_ticks,value))times->creation.QuadPart=value;
            if(times->exit.QuadPart&&cdf::AddTicks(times->exit.QuadPart,config.offset_ticks,value))times->exit.QuadPart=value;
        }
    }
    RtlSetLastWin32Error(last);return result;
}
int WINAPI HookGetUserDefaultGeoName(LPWSTR output,int capacity){
    auto raw=reinterpret_cast<decltype(&GetUserDefaultGeoName)>(base_geo[0]->old_address);
    if(!region_active||capacity<0||(!output&&capacity))return raw(output,capacity);
    _InterlockedIncrement64(&region_calls);
    if(!capacity)return 3;
    if(capacity<3){RtlSetLastWin32Error(ERROR_INSUFFICIENT_BUFFER);return 0;}
    output[0]=config.region.home_region[0];output[1]=config.region.home_region[1];output[2]=0;return 3;
}
GEOID WINAPI HookGetUserGeoID(GEOCLASS kind){
    auto raw=reinterpret_cast<decltype(&GetUserGeoID)>(base_geo[1]->old_address);
    if(!region_active||kind!=GEOCLASS_NATION)return raw(kind);
    _InterlockedIncrement64(&region_calls);return config.region.geo_id;
}
using Activation=HRESULT(WINAPI*)(void*,REFIID,void**);
using Activate=HRESULT(WINAPI*)(void*,void**);
HRESULT WINAPI HookRoGetActivationFactory(void*,REFIID,void**);
HRESULT WINAPI HookRoActivateInstance(void*,void**);
cdf::verifier::ThunkDescriptor com_thunks[]={
    {const_cast<PCHAR>("RoGetActivationFactory"),nullptr,reinterpret_cast<PVOID>(HookRoGetActivationFactory)},
    {const_cast<PCHAR>("RoActivateInstance"),nullptr,reinterpret_cast<PVOID>(HookRoActivateInstance)},{}};
HRESULT WINAPI HookRoGetActivationFactory(void* name,REFIID iid,void** output){
    const HRESULT hr=reinterpret_cast<Activation>(com_thunks[0].old_address)(name,iid,output);const DWORD last=RtlGetLastWin32Error();
    HRESULT wrapped=S_FALSE;
    if(SUCCEEDED(hr)&&output&&*output&&(config.runtime.enabled||region_active)){
        _InterlockedIncrement64(&activation_calls);wrapped=cdf::WrapRuntimeFactory(name,iid,output);
    }
    RtlSetLastWin32Error(last);return FAILED(wrapped)?wrapped:hr;
}
HRESULT WINAPI HookRoActivateInstance(void* name,void** output){
    const DWORD last=RtlGetLastWin32Error();
    const HRESULT custom=cdf::ActivateRuntimeInstance(name,output);
    if(custom!=S_FALSE){_InterlockedIncrement64(&activation_calls);RtlSetLastWin32Error(last);return custom;}
    return reinterpret_cast<Activate>(com_thunks[1].old_address)(name,output);
}
void Append(cdf::verifier::ThunkDescriptor* table,const char* name,PVOID hook,cdf::verifier::ThunkDescriptor*& binding){
    while(table->name)++table;binding=table;table->name=const_cast<PCHAR>(name);table->new_address=hook;
}
}
namespace cdf {
PVOID RedirectRuntimeAddress(PVOID address){
    // Verifier itself wraps NtQueryInformationProcess on this Windows build.
    // A thunk's OldAddress is then a verifier chain entry, while export lookup
    // still returns the ntdll syscall stub. Match both without bypassing the
    // original verifier chain when the hook calls through.
    if(time_active&&address&&address==native_query_export)return reinterpret_cast<PVOID>(HookNtQueryInformationProcess);
    return address;
}
bool RuntimeEnterCapture(){auto* t=CurrentThread(true);if(!t||t->capture_depth)return false;t->capture_depth=1;return true;}
void RuntimeLeaveCapture(){if(auto* t=CurrentThread(false))t->capture_depth=0;}
bool RuntimePreflight(const Config& input){
    config=input;
    bool accepted=PrepareAdapter(input);AdapterState adapter{};QueryAdapter(adapter);
#if defined(CDF_CLAUDE_IDENTITY_REQUIRED)
    if(accepted&&input.schema_version==3&&input.runtime.enabled){
        claude::RuntimeBinding binding{};claude::QueryRuntimeBinding(binding);
        UNICODE_STRING expected,actual;RtlInitUnicodeString(&expected,adapter.id);RtlInitUnicodeString(&actual,binding.adapter_id);
        const bool kind=adapter.compatibility==1?binding.type[0]==L'e':binding.type[0]==L'n';
        accepted=(binding.version==2||binding.version==3)&&kind&&RtlEqualUnicodeString(&expected,&actual,FALSE);
        if(!accepted){adapter.error_code=ERROR_REVISION_MISMATCH;adapter.error_stage=13;}
    }
#endif
    if(accepted)return true;
    runtime_error=adapter.error_code;runtime_stage=adapter.error_stage;
    // Startup blocking is reserved for identity-matched managed Claude images.
    // The generic probe provider must never apply that lifecycle policy to an
    // arbitrary registered test process.
#if defined(CDF_CLAUDE_IDENTITY_REQUIRED)
    const bool enforce_block=true;
#else
    const bool enforce_block=false;
#endif
    if(input.runtime.passthrough||!enforce_block){
        if(!RollbackAdapter())NtTerminateProcess(reinterpret_cast<HANDLE>(-1),static_cast<NTSTATUS>(CdfRuntimeBlockedExit));
        passthrough=true;Publish();return false;
    }
    NtTerminateProcess(reinterpret_cast<HANDLE>(-1),static_cast<NTSTATUS>(CdfRuntimeBlockedExit));return false;
}
void PrepareRuntime(const Config& input,bool parsed,bool active){
    config=input;
    if(!parsed||input.schema_version!=3)return;
    prepared=input.runtime.enabled||input.region.enabled;
    time_active=input.runtime.enabled&&active;
    locale_active=input.runtime.enabled&&LocalePrepared();
    if(locale_active){DWORD error=0;NTSTATUS status=0;if(!ValidateLocale(config.locale,error,status)){locale_active=false;runtime_error=error;runtime_stage=2;}}
    if(input.region.enabled){runtime_stage=1;region_active=ValidateRegion(config.region,runtime_error);if(region_active)runtime_stage=0;}
    InitTls();
    Publish();
}
bool RuntimePrepared(){return prepared;}
bool RuntimeLocaleEnabled(){return locale_active;}
bool RuntimeRegionEnabled(){return region_active;}
bool RuntimeTimeEnabled(){return time_active;}
bool RuntimePassthrough(){return passthrough;}
const Config& RuntimeConfigSnapshot(){return config;}
void AppendRuntimeThunks(verifier::ThunkDescriptor* base,verifier::ThunkDescriptor* kernel,verifier::ThunkDescriptor* native){
    if(time_active){Append(base,"GetProcessTimes",reinterpret_cast<PVOID>(HookGetProcessTimes),base_time);Append(kernel,"GetProcessTimes",reinterpret_cast<PVOID>(HookGetProcessTimes),kernel_time);Append(native,"NtQueryInformationProcess",reinterpret_cast<PVOID>(HookNtQueryInformationProcess),native_time);}
    if(config.region.enabled){
        Append(base,"GetUserDefaultGeoName",reinterpret_cast<PVOID>(HookGetUserDefaultGeoName),base_geo[0]);
        Append(kernel,"GetUserDefaultGeoName",reinterpret_cast<PVOID>(HookGetUserDefaultGeoName),kernel_geo[0]);
        Append(base,"GetUserGeoID",reinterpret_cast<PVOID>(HookGetUserGeoID),base_geo[1]);
        Append(kernel,"GetUserGeoID",reinterpret_cast<PVOID>(HookGetUserGeoID),kernel_geo[1]);
    }
}
verifier::ThunkDescriptor* RuntimeComThunks(){return com_thunks;}
PVOID ResolveLoaded(const WCHAR* module,const char* symbol){
    UNICODE_STRING name;RtlInitUnicodeString(&name,module);PVOID handle=nullptr,address=nullptr;
    if(LdrGetDllHandle(nullptr,nullptr,&name,&handle)<0)return nullptr;
    ANSI_STRING export_name;RtlInitAnsiString(&export_name,symbol);
    return OriginalProcedure(handle,&export_name,0,&address)>=0?address:nullptr;
}
void RuntimeEvent(DWORD reason){
    if(!prepared)return;
    if(reason==DLL_PROCESS_ATTACH)InitTls();
    if(reason==DLL_THREAD_DETACH||reason==DLL_PROCESS_DETACH){
        if(auto* value=CurrentThread(false)){tls_set(tls_index,nullptr);RtlFreeHeap(Heap(),0,value);}
        if(reason==DLL_PROCESS_DETACH&&tls_index!=TLS_OUT_OF_INDEXES){tls_free(tls_index);tls_index=TLS_OUT_OF_INDEXES;}
    }
    if(reason==DLL_PROCESS_ATTACH)Publish();
}
void NTAPI RuntimeDllLoaded(PWSTR,PVOID,SIZE_T,PVOID){
    if(!prepared||passthrough)return;
    InitTls();
    if(config.region.enabled&&!region_active){region_active=ValidateRegion(config.region,runtime_error);if(region_active)runtime_stage=0;}
    if(prepared)Publish();
}
}
extern "C" __declspec(dllexport) DWORD WINAPI CdfRuntimeQueryStatus(CdfRuntimeStatus* output,DWORD size){
    if(!output||size!=sizeof(*output))return ERROR_INVALID_PARAMETER;
    cdf::Zero(output,sizeof(*output));output->size=sizeof(*output);output->version=2;
    output->state=(prepared?CdfRuntimeConfigured:0U)|(time_active?CdfRuntimeTime:0U)|(locale_active?CdfRuntimeLocale:0U)|(region_active?CdfRuntimeRegion:0U)|(tls_index!=TLS_OUT_OF_INDEXES?CdfRuntimeTlsReady:0U);
    output->schema_version=config.schema_version;output->policy=config.runtime.passthrough?1:0;
    output->error_code=runtime_error;output->error_stage=runtime_stage;
    for(auto* p:{base_time,kernel_time,native_time})if(p&&p->old_address)++output->resolved_process_hooks;
    for(auto* p=com_thunks;p->name;++p)if(p->old_address)++output->resolved_winrt_hooks;
    for(auto* p:base_geo)if(p&&p->old_address)++output->region_hooks;
    output->process_time_calls=static_cast<ULONGLONG>(_InterlockedCompareExchange64(&process_calls,0,0));
    output->native_process_time_calls=static_cast<ULONGLONG>(_InterlockedCompareExchange64(&native_calls,0,0));
    output->activation_calls=static_cast<ULONGLONG>(_InterlockedCompareExchange64(&activation_calls,0,0));
    output->region_calls=static_cast<ULONGLONG>(_InterlockedCompareExchange64(&region_calls,0,0));
    output->language_calls=cdf::WinrtLanguageCalls();output->format_calls=cdf::WinrtFormatCalls();
    cdf::CopyText(output->home_region,4,config.region.home_region);
    cdf::CopyText(output->format_locale,LOCALE_NAME_MAX_LENGTH,config.locale.format_locale);
    cdf::CopyText(output->ui_language,LOCALE_NAME_MAX_LENGTH,config.locale.ui_language);
    cdf::AdapterState adapter{};cdf::QueryAdapter(adapter);
    output->compatibility=adapter.compatibility;output->patch_count=adapter.patch_count;
    if(adapter.compatibility==1&&!adapter.error_code&&!passthrough)output->state|=CdfRuntimeAdapterReady;
    if(passthrough)output->state|=CdfRuntimePassthrough;
    cdf::CopyText(output->adapter_id,96,adapter.id);cdf::CopyText(output->runtime_version,64,adapter.version);cdf::Copy(output->fingerprint,adapter.fingerprint,32);
    output->capture_enabled=config.runtime.enabled&&config.runtime.capture;
    cdf::CaptureCounts(output->captured_contexts,output->capture_failures,output->capture_truncated);return 0;
}
