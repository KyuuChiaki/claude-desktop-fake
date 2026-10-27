#include "runtime_capture.h"
#include "runtime_provider.h"
#include "runtime_adapter.h"
#include <intrin.h>
namespace {
CdfRuntimeCapture runtime_capture{sizeof(CdfRuntimeCapture),1,0,0,0,0,{}};
volatile LONG capture_lock=0;
// Public V8 opaque objects, constructed and destroyed by this exact runtime.
// Layouts are pinned to V8 15.2.124.43 headers (three and six pointer slots).
struct HandleScope { PVOID fields[3]; };
struct TryCatch { PVOID fields[6]; };
struct Local { PVOID slot; };
struct Guard {
    HandleScope scope{};TryCatch catcher{};
    Guard(PVOID iso,PVOID){
        reinterpret_cast<void(__cdecl*)(PVOID,PVOID)>(cdf::RuntimeAddress(cdf::compat::HandleScopeCtor))(&scope,iso);
        reinterpret_cast<void(__cdecl*)(PVOID,PVOID)>(cdf::RuntimeAddress(cdf::compat::TryCatchCtor))(&catcher,iso);
    }
    ~Guard(){
        reinterpret_cast<void(__cdecl*)(PVOID)>(cdf::RuntimeAddress(cdf::compat::TryCatchDtor))(&catcher);
        reinterpret_cast<void(__cdecl*)(PVOID)>(cdf::RuntimeAddress(cdf::compat::HandleScopeDtor))(&scope);
    }
};
constexpr char script[]=
"(()=>{const r={dateNow:Date.now(),dateString:new Date().toString(),"
"intl:{},navigator:null,performance:null,process:null};"
"for(const k of ['DateTimeFormat','NumberFormat','Collator','PluralRules','RelativeTimeFormat','ListFormat','DisplayNames','Segmenter']){"
"try{r.intl[k]=new Intl[k](undefined,k==='DisplayNames'?{type:'region'}:undefined).resolvedOptions()}catch(e){r.intl[k]={error:String(e)}}}"
"if(typeof navigator==='object')r.navigator={language:navigator.language,languages:Array.from(navigator.languages)};"
"if(typeof performance==='object')r.performance={timeOrigin:performance.timeOrigin,now:performance.now()};"
"if(typeof process==='object'&&process.versions)r.process={type:process.type||'node',versions:{...process.versions},"
"uptime:process.uptime(),hrtime:process.hrtime.bigint().toString(),creationTime:typeof process.getCreationTime==='function'?process.getCreationTime():null};"
"return JSON.stringify(r)})()";
}
namespace cdf {
void CaptureContext(PVOID isolate,PVOID base){
    if(!RuntimeConfigSnapshot().runtime.capture||!RuntimeEnterCapture())return;
    Guard guard(isolate,base);Local context{};
    reinterpret_cast<Local*(__cdecl*)(PVOID,Local*)>(cdf::RuntimeAddress(cdf::compat::CurrentContext))(isolate,&context);
    if(!context.slot){RuntimeLeaveCapture();return;}
    const ULONGLONG identity=*static_cast<ULONGLONG*>(context.slot);
    if(_InterlockedCompareExchange(&capture_lock,1,0)){RuntimeLeaveCapture();return;}
    for(LONG i=0;i<runtime_capture.count;i++)if(runtime_capture.slots[i].context==identity){_InterlockedExchange(&capture_lock,0);RuntimeLeaveCapture();return;}
    if(runtime_capture.count>=static_cast<LONG>(CdfCaptureCapacity)){_InterlockedIncrement(&runtime_capture.truncated);_InterlockedExchange(&capture_lock,0);RuntimeLeaveCapture();return;}
    const LONG index=runtime_capture.count;
    auto* slot=&runtime_capture.slots[index];slot->sequence=1;slot->context=identity;slot->state=1;slot->thread_id=__readgsdword(0x48);
    _InterlockedExchange(&runtime_capture.count,index+1);
    _InterlockedExchange(&capture_lock,0);
    Local text{},compiled{},result{};
    reinterpret_cast<Local*(__cdecl*)(Local*,PVOID,PCSTR,int,int)>(cdf::RuntimeAddress(cdf::compat::NewString))(&text,isolate,script,0,sizeof(script)-1);
    if(text.slot)reinterpret_cast<Local*(__cdecl*)(Local*,PVOID,PVOID,PVOID)>(cdf::RuntimeAddress(cdf::compat::Compile))(&compiled,context.slot,text.slot,nullptr);
    if(compiled.slot)reinterpret_cast<Local*(__cdecl*)(PVOID,Local*,PVOID,PVOID)>(cdf::RuntimeAddress(cdf::compat::Run))(compiled.slot,&result,context.slot,nullptr);
    if(result.slot){
        const SIZE_T length=reinterpret_cast<SIZE_T(__cdecl*)(PVOID,PVOID)>(cdf::RuntimeAddress(cdf::compat::Utf8Length))(result.slot,isolate);
        if(length<CdfCaptureTextCapacity){
            const SIZE_T count=reinterpret_cast<SIZE_T(__cdecl*)(PVOID,PVOID,char*,SIZE_T,int,SIZE_T*)>(cdf::RuntimeAddress(cdf::compat::WriteUtf8))(result.slot,isolate,slot->json,CdfCaptureTextCapacity,0,nullptr);
            slot->bytes=static_cast<DWORD>(count);slot->state=2;
        }else{slot->state=4;_InterlockedIncrement(&runtime_capture.truncated);}
    }else{slot->state=3;_InterlockedIncrement(&runtime_capture.failures);}
    _InterlockedExchange(&slot->sequence,2);RuntimeLeaveCapture();
}
void CaptureCounts(DWORD& contexts,DWORD& failures,DWORD& truncated){
    contexts=static_cast<DWORD>(_InterlockedCompareExchange(&runtime_capture.count,0,0));
    failures=static_cast<DWORD>(_InterlockedCompareExchange(&runtime_capture.failures,0,0));
    truncated=static_cast<DWORD>(_InterlockedCompareExchange(&runtime_capture.truncated,0,0));
}
}
