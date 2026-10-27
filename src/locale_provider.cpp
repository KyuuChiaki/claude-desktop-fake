#include "locale_provider.h"
#include "locale_native.h"
#include "locale_status.h"
#include <intrin.h>

namespace {
cdf::LocaleConfig config{};
DWORD schema = 0, state = 0, error_stage = 0, error_code = 0;
NTSTATUS native_error = 0;
bool prepared = false;
alignas(8) volatile LONG64 counters[CdfLocaleHookCount]{}, live_records = 0;
struct Binding { cdf::verifier::ThunkDescriptor* descriptors[3]; };
Binding bindings[CdfLocaleHookCount]{};
struct Saved {
    Saved* next; PVOID handle; bool preferred, ui;
};
struct ThreadState {
    bool locale, preferred, ui; Saved* saved;
};
DWORD tls_index = TLS_OUT_OF_INDEXES;
decltype(&TlsAlloc) tls_alloc = nullptr;
decltype(&TlsFree) tls_free = nullptr;
decltype(&TlsGetValue) tls_get = nullptr;
decltype(&TlsSetValue) tls_set = nullptr;
PVOID process_heap = nullptr;
volatile LONG process_preferred = 0;

template<class T> T Original(CdfLocaleHook hook) {
    for (auto* descriptor : bindings[hook].descriptors)
        if (descriptor && descriptor->old_address) return reinterpret_cast<T>(descriptor->old_address);
    return nullptr;
}
#define RAW(name) Original<decltype(&name)>(CdfLocale##name)
bool Operational() { return tls_index!=TLS_OUT_OF_INDEXES; }
void Count(CdfLocaleHook hook) { _InterlockedIncrement64(&counters[hook]); }
bool Equal(const WCHAR* a, const WCHAR* b) {
    if (!a || !b) return a == b;
    while (*a && *a == *b) { ++a; ++b; } return *a == *b;
}
ThreadState* Thread(bool create = false) {
    if (tls_index == TLS_OUT_OF_INDEXES) return nullptr;
    const DWORD last = RtlGetLastWin32Error();
    auto* result = static_cast<ThreadState*>(tls_get(tls_index));
    if (!result && create) {
        result = static_cast<ThreadState*>(RtlAllocateHeap(process_heap, HEAP_ZERO_MEMORY, sizeof(ThreadState)));
        if (result && !tls_set(tls_index,result)) { RtlFreeHeap(process_heap,0,result); result = nullptr; }
        if (result) _InterlockedIncrement64(&live_records);
    }
    RtlSetLastWin32Error(last); return result;
}
bool FailMemory() { RtlSetLastWin32Error(ERROR_NOT_ENOUGH_MEMORY); return false; }
bool IsDefault(LCID id) {
    return id == LOCALE_NEUTRAL || id == LOCALE_USER_DEFAULT || id == LOCALE_SYSTEM_DEFAULT ||
        id == LOCALE_CUSTOM_DEFAULT || id == LOCALE_CUSTOM_UI_DEFAULT;
}
LCID MapId(LCID id, bool* changed = nullptr) {
    const bool replace = IsDefault(id);
    if (changed) *changed = replace;
    return replace ? (id == LOCALE_CUSTOM_UI_DEFAULT ? config.ui_lcid : config.format_lcid) : id;
}
LPCWSTR MapName(LPCWSTR name, bool* changed = nullptr) {
    const bool replace = !name || Equal(name,LOCALE_NAME_SYSTEM_DEFAULT);
    if (changed) *changed = replace;
    return replace ? config.format_locale : name;
}
LCID WINAPI HookGetUserDefaultLCID() {
    if (!Operational()) return RAW(GetUserDefaultLCID)(); Count(CdfLocaleGetUserDefaultLCID); return config.format_lcid; }
LCID WINAPI HookGetSystemDefaultLCID() {
    if (!Operational()) return RAW(GetSystemDefaultLCID)(); Count(CdfLocaleGetSystemDefaultLCID); return config.format_lcid; }
LANGID WINAPI HookGetUserDefaultLangID() {
    if (!Operational()) return RAW(GetUserDefaultLangID)(); Count(CdfLocaleGetUserDefaultLangID); return LANGIDFROMLCID(config.format_lcid); }
LANGID WINAPI HookGetSystemDefaultLangID() {
    if (!Operational()) return RAW(GetSystemDefaultLangID)(); Count(CdfLocaleGetSystemDefaultLangID); return LANGIDFROMLCID(config.format_lcid); }
LANGID WINAPI HookGetUserDefaultUILanguage() {
    if (!Operational()) return RAW(GetUserDefaultUILanguage)(); Count(CdfLocaleGetUserDefaultUILanguage); return LANGIDFROMLCID(config.ui_lcid); }
LANGID WINAPI HookGetSystemDefaultUILanguage() {
    if (!Operational()) return RAW(GetSystemDefaultUILanguage)(); Count(CdfLocaleGetSystemDefaultUILanguage); return LANGIDFROMLCID(config.ui_lcid); }
int WINAPI HookGetUserDefaultLocaleName(LPWSTR output, int capacity) {
    if (!Operational()) return RAW(GetUserDefaultLocaleName)(output,capacity);
    Count(CdfLocaleGetUserDefaultLocaleName);
    if (capacity<0) { RtlSetLastWin32Error(ERROR_INVALID_PARAMETER); return 0; }
    int length=0; while(config.format_locale[length]) ++length;
    // KernelBase uses StringCchCopyW here: partial copy and a terminating
    // zero on short nonempty buffers; zero capacity is not a length query.
    if (capacity>0) {
        const int copied=length<capacity ? length : capacity-1;
        cdf::Copy(output,config.format_locale,copied*sizeof(WCHAR)); output[copied]=0;
    }
    if (capacity<=length) { RtlSetLastWin32Error(ERROR_CANNOT_COPY); return 0; }
    return length+1;
}
int WINAPI HookGetSystemDefaultLocaleName(LPWSTR output, int capacity) {
    if (!Operational()) return RAW(GetSystemDefaultLocaleName)(output,capacity);
    Count(CdfLocaleGetSystemDefaultLocaleName);
    if (capacity<0) { RtlSetLastWin32Error(ERROR_INVALID_PARAMETER); return 0; }
    int length=0; while(config.format_locale[length]) ++length;
    // This entry preflights length before copying, unlike the user getter.
    if (length>capacity) { RtlSetLastWin32Error(ERROR_INSUFFICIENT_BUFFER); return 0; }
    if (capacity>0) {
        const int copied=length<capacity ? length : capacity-1;
        cdf::Copy(output,config.format_locale,copied*sizeof(WCHAR)); output[copied]=0;
    }
    if (capacity<=length) { RtlSetLastWin32Error(ERROR_INSUFFICIENT_BUFFER); return 0; }
    return length+1;
}
LCID WINAPI HookGetThreadLocale() {
    if (!Operational()) return RAW(GetThreadLocale)();
    Count(CdfLocaleGetThreadLocale); const auto* t=Thread();
    return t && t->locale ? RAW(GetThreadLocale)() : config.format_lcid;
}
BOOL WINAPI HookSetThreadLocale(LCID id) {
    if (!Operational()) return RAW(SetThreadLocale)(id);
    Count(CdfLocaleSetThreadLocale); auto* t=Thread(true); if (!t) return FailMemory();
    const BOOL result=RAW(SetThreadLocale)(MapId(id));
    if (result) t->locale=!IsDefault(id);
    return result;
}
LANGID WINAPI HookGetThreadUILanguage() {
    if (!Operational()) return RAW(GetThreadUILanguage)();
    Count(CdfLocaleGetThreadUILanguage); const auto* t=Thread();
    if (t && (t->ui || t->preferred)) return RAW(GetThreadUILanguage)();
    if (_InterlockedCompareExchange(&process_preferred,0,0)) {
        const DWORD last=RtlGetLastWin32Error(); WCHAR list[4096]{}; ULONG count=0,length=4096; LCID id=0;
        const NTSTATUS s=RAW(RtlGetProcessPreferredUILanguages)(MUI_LANGUAGE_NAME,&count,list,&length);
        const bool valid=s>=0 && list[0] && RtlLocaleNameToLcid(list,&id,2)>=0;
        RtlSetLastWin32Error(last); if (valid) return LANGIDFROMLCID(id);
    }
    return LANGIDFROMLCID(config.ui_lcid);
}
LANGID WINAPI HookSetThreadUILanguage(LANGID id) {
    if (!Operational()) return RAW(SetThreadUILanguage)(id);
    Count(CdfLocaleSetThreadUILanguage); auto* t=Thread(true); if (!t) { FailMemory(); return 0; }
    // Zero selects the virtual default. Passing it through would materialize
    // Windows' host fallback list and leave a stale MUI cache after a reset.
    const LANGID result=RAW(SetThreadUILanguage)(id ? id : LANGIDFROMLCID(config.ui_lcid));
    if (result) { t->ui=id!=0; t->preferred=id!=0; }
    return result;
}
int WINAPI HookGetLocaleInfoEx(LPCWSTR name,LCTYPE type,LPWSTR output,int capacity) {
    if (!Operational()) return RAW(GetLocaleInfoEx)(name,type,output,capacity);
    Count(CdfLocaleGetLocaleInfoEx); bool changed=false; name=MapName(name,&changed);
    return RAW(GetLocaleInfoEx)(name,type | (changed ? LOCALE_NOUSEROVERRIDE : 0),output,capacity);
}
int WINAPI HookGetLocaleInfoW(LCID id,LCTYPE type,LPWSTR output,int capacity) {
    if (!Operational()) return RAW(GetLocaleInfoW)(id,type,output,capacity);
    Count(CdfLocaleGetLocaleInfoW); bool changed=false; id=MapId(id,&changed);
    return RAW(GetLocaleInfoW)(id,type | (changed ? LOCALE_NOUSEROVERRIDE : 0),output,capacity);
}
int WINAPI HookGetLocaleInfoA(LCID id,LCTYPE type,LPSTR output,int capacity) {
    if (!Operational()) return RAW(GetLocaleInfoA)(id,type,output,capacity);
    Count(CdfLocaleGetLocaleInfoA); bool changed=false; id=MapId(id,&changed);
    return RAW(GetLocaleInfoA)(id,type | (changed ? LOCALE_NOUSEROVERRIDE : 0),output,capacity);
}
LCID WINAPI HookConvertDefaultLocale(LCID id) {
    if (!Operational()) return RAW(ConvertDefaultLocale)(id); Count(CdfLocaleConvertDefaultLocale); return RAW(ConvertDefaultLocale)(MapId(id)); }
LCID WINAPI HookLocaleNameToLCID(LPCWSTR name,DWORD flags) {
    if (!Operational()) return RAW(LocaleNameToLCID)(name,flags); Count(CdfLocaleLocaleNameToLCID); return RAW(LocaleNameToLCID)(MapName(name),flags); }
int WINAPI HookLCIDToLocaleName(LCID id,LPWSTR output,int capacity,DWORD flags) {
    if (!Operational()) return RAW(LCIDToLocaleName)(id,output,capacity,flags); Count(CdfLocaleLCIDToLocaleName); return RAW(LCIDToLocaleName)(MapId(id),output,capacity,flags); }
int WINAPI HookResolveLocaleName(LPCWSTR name,LPWSTR output,int capacity) {
    if (!Operational()) return RAW(ResolveLocaleName)(name,output,capacity); Count(CdfLocaleResolveLocaleName); return RAW(ResolveLocaleName)(MapName(name),output,capacity); }

// Generated, explicit wrappers for A/W/Ex formatting and calendar queries.
#include "locale_formats.inc"

NTSTATUS NTAPI HookNtQueryDefaultLocale(BOOLEAN user,PLCID output) {
    if (!Operational()) return RAW(NtQueryDefaultLocale)(user,output);
    Count(CdfLocaleNtQueryDefaultLocale); const NTSTATUS s=RAW(NtQueryDefaultLocale)(user,output);
    if (s>=0) *output=config.format_lcid; return s;
}
NTSTATUS NTAPI HookNtQueryDefaultUILanguage(LANGID* output) {
    if (!Operational()) return RAW(NtQueryDefaultUILanguage)(output);
    Count(CdfLocaleNtQueryDefaultUILanguage); const NTSTATUS s=RAW(NtQueryDefaultUILanguage)(output);
    if (s>=0) *output=LANGIDFROMLCID(config.ui_lcid); return s;
}
NTSTATUS NTAPI HookNtQueryInstallUILanguage(LANGID* output) {
    if (!Operational()) return RAW(NtQueryInstallUILanguage)(output);
    Count(CdfLocaleNtQueryInstallUILanguage); const NTSTATUS s=RAW(NtQueryInstallUILanguage)(output);
    if (s>=0) *output=LANGIDFROMLCID(config.ui_lcid); return s;
}

struct Languages {
    WCHAR text[4096]{}; ULONG length=1, count=0;
    bool Add(const WCHAR* name) {
        ULONG n=0; while (name[n]) ++n;
        if (!n) return true;
        for (ULONG i=0;i+1<length;) {
            if (Equal(text+i,name)) return true;
            while (text[i]) ++i; ++i;
        }
        if (length+n+1>4096) return false;
        cdf::Copy(text+length-1,name,(n+1)*sizeof(WCHAR)); length+=n+1; text[length-1]=0; ++count; return true;
    }
    bool AddMulti(const WCHAR* names, ULONG capacity) {
        for (ULONG i=0;i<capacity && names[i];) {
            ULONG end=i; while (end<capacity && names[end]) ++end;
            if (end==capacity || !Add(names+i)) return false;
            i=end+1;
        }
        return true;
    }
    void Parents(const WCHAR* locale) {
        WCHAR name[LOCALE_NAME_MAX_LENGTH]{}; cdf::CopyText(name,LOCALE_NAME_MAX_LENGTH,locale);
        for (ULONG depth=0;depth<4;++depth) {
            WCHAR parent[LOCALE_NAME_MAX_LENGTH]{};
            if (!RAW(GetLocaleInfoEx)(name,LOCALE_SPARENT|LOCALE_NOUSEROVERRIDE,parent,LOCALE_NAME_MAX_LENGTH) || !parent[0] || Equal(parent,name)) break;
            Add(parent); cdf::CopyText(name,LOCALE_NAME_MAX_LENGTH,parent);
        }
    }
    bool AddSource(const WCHAR* names,ULONG capacity,bool parents) {
        for (ULONG i=0;i<capacity && names[i];) {
            ULONG end=i; while (end<capacity && names[end]) ++end;
            if (end==capacity || !Add(names+i)) return false;
            if (parents) Parents(names+i);
            i=end+1;
        }
        return true;
    }
};
enum class Kind { System, User, Process, Thread };
NTSTATUS RawLanguages(Kind kind,ULONG flags,PCWSTR locale,PULONG count,PZZWSTR buffer,PULONG length) {
    switch(kind) {
    case Kind::System: return RAW(RtlGetSystemPreferredUILanguages)(flags,locale,count,buffer,length);
    case Kind::User: return RAW(RtlGetUserPreferredUILanguages)(flags,locale,count,buffer,length);
    case Kind::Process: return RAW(RtlGetProcessPreferredUILanguages)(flags,count,buffer,length);
    default: return RAW(RtlGetThreadPreferredUILanguages)(flags,count,buffer,length);
    }
}
NTSTATUS QueryLanguages(Kind kind,ULONG flags,PCWSTR locale,PULONG count,PZZWSTR output,PULONG capacity) {
    if (!count || !capacity || (!output && *capacity) || (locale && locale[0])) return RawLanguages(kind,flags,locale,count,output,capacity);
    const DWORD last=RtlGetLastWin32Error();
    // Let the exact OS entry validate its flags using private scratch space.
    WCHAR raw[4096]{}; ULONG raw_count=0, raw_size=4096;
    const NTSTATUS validation=RawLanguages(kind,flags,locale,&raw_count,raw,&raw_size);
    if (validation<0 && validation!=static_cast<NTSTATUS>(0xc0000023UL)) { RtlSetLastWin32Error(last); return validation; }
    Languages list; const auto* t=Thread();
    const bool explicit_thread=kind==Kind::Thread && t && (t->preferred || t->ui);
    const bool explicit_process=(kind==Kind::Process || kind==Kind::Thread) && _InterlockedCompareExchange(&process_preferred,0,0);
    const bool thread_only=kind==Kind::Thread && (flags & MUI_THREAD_LANGUAGES);
    const bool system_fallback=kind==Kind::Thread && (flags & MUI_MERGE_SYSTEM_FALLBACK);
    const bool user_fallback=kind==Kind::Thread && !thread_only &&
        ((flags & MUI_MERGE_USER_FALLBACK) || !(flags & (MUI_UI_FALLBACK)));
    if (explicit_thread) {
        raw_size=4096; raw_count=0;
        const NTSTATUS s=RawLanguages(Kind::Thread,MUI_LANGUAGE_NAME|MUI_THREAD_LANGUAGES,nullptr,&raw_count,raw,&raw_size);
        if (s<0) { RtlSetLastWin32Error(last); return s; }
        if (!list.AddSource(raw,raw_size,system_fallback)) { RtlSetLastWin32Error(last); return static_cast<NTSTATUS>(0xc0000017UL); }
    }
    if (explicit_process && !thread_only) {
        raw_size=4096; raw_count=0;
        const NTSTATUS s=RawLanguages(Kind::Process,MUI_LANGUAGE_NAME,nullptr,&raw_count,raw,&raw_size);
        if (s<0) { RtlSetLastWin32Error(last); return s; }
        if (!list.AddSource(raw,raw_size,system_fallback)) { RtlSetLastWin32Error(last); return static_cast<NTSTATUS>(0xc0000017UL); }
    }
    // The virtual user/system source contains the configured language. A
    // thread-only query excludes the process list; system fallback expands
    // each source using its NLS parent chain, in the same source order.
    if (!list.count || user_fallback || system_fallback) {
        list.Add(config.ui_language);
        if (system_fallback) list.Parents(config.ui_language);
    }
    Languages rendered;
    if (flags & MUI_LANGUAGE_ID) {
        for (ULONG i=0;i+1<list.length;) {
            LCID id=0; NTSTATUS s=RtlLocaleNameToLcid(list.text+i,&id,2);
            if (s<0) { RtlSetLastWin32Error(last); return s; }
            WCHAR hex[5]{}; const WCHAR digits[]=L"0123456789ABCDEF";
            for (ULONG j=0;j<4;++j) hex[j]=digits[(LANGIDFROMLCID(id) >> ((3-j)*4)) & 15];
            rendered.Add(hex); while (list.text[i]) ++i; ++i;
        }
    } else { cdf::Copy(&rendered,&list,sizeof(list)); }
    const ULONG provided=*capacity;
    *capacity=rendered.length;
    // Native thread queries publish their count even on short-buffer failure.
    if (kind==Kind::Thread) *count=rendered.count;
    if (!output) { *count=rendered.count; RtlSetLastWin32Error(last); return 0; }
    if (provided<rendered.length) { RtlSetLastWin32Error(last); return static_cast<NTSTATUS>(0xc0000023UL); }
    cdf::Copy(output,rendered.text,rendered.length*sizeof(WCHAR)); *count=rendered.count;
    RtlSetLastWin32Error(last); return 0;
}
BOOL WinLanguages(Kind kind,ULONG flags,PULONG count,PZZWSTR buffer,PULONG length) {
    const NTSTATUS s=QueryLanguages(kind,flags,nullptr,count,buffer,length);
    if (s<0) { RtlSetLastWin32Error(RtlNtStatusToDosError(s)); return FALSE; } return TRUE;
}
#define WIN_GET(name,kind) BOOL WINAPI Hook##name(ULONG f,PULONG n,PZZWSTR b,PULONG l) { if (!Operational()) return RAW(name)(f,n,b,l); Count(CdfLocale##name); return WinLanguages(Kind::kind,f,n,b,l); }
WIN_GET(GetSystemPreferredUILanguages,System)
WIN_GET(GetUserPreferredUILanguages,User)
WIN_GET(GetProcessPreferredUILanguages,Process)
WIN_GET(GetThreadPreferredUILanguages,Thread)
#undef WIN_GET
NTSTATUS NTAPI HookRtlGetSystemPreferredUILanguages(ULONG f,PCWSTR locale,PULONG n,PZZWSTR b,PULONG l) {
    if (!Operational()) return RAW(RtlGetSystemPreferredUILanguages)(f,locale,n,b,l); Count(CdfLocaleRtlGetSystemPreferredUILanguages); return QueryLanguages(Kind::System,f,locale,n,b,l); }
NTSTATUS NTAPI HookRtlGetUserPreferredUILanguages(ULONG f,PCWSTR locale,PULONG n,PZZWSTR b,PULONG l) {
    if (!Operational()) return RAW(RtlGetUserPreferredUILanguages)(f,locale,n,b,l); Count(CdfLocaleRtlGetUserPreferredUILanguages); return QueryLanguages(Kind::User,f,locale,n,b,l); }
NTSTATUS NTAPI HookRtlGetProcessPreferredUILanguages(ULONG f,PULONG n,PZZWSTR b,PULONG l) {
    if (!Operational()) return RAW(RtlGetProcessPreferredUILanguages)(f,n,b,l); Count(CdfLocaleRtlGetProcessPreferredUILanguages); return QueryLanguages(Kind::Process,f,nullptr,n,b,l); }
NTSTATUS NTAPI HookRtlGetThreadPreferredUILanguages(ULONG f,PULONG n,PZZWSTR b,PULONG l) {
    if (!Operational()) return RAW(RtlGetThreadPreferredUILanguages)(f,n,b,l); Count(CdfLocaleRtlGetThreadPreferredUILanguages); return QueryLanguages(Kind::Thread,f,nullptr,n,b,l); }

void RecordPreferred(ThreadState* t, PCZZWSTR list,ULONG flags) {
    // Filter-only calls update MUI filters without replacing the language list.
    if (!list && (flags & (MUI_CONSOLE_FILTER|MUI_COMPLEX_SCRIPT_FILTER|MUI_RESET_FILTERS))) return;
    t->preferred=list && list[0]; t->ui=false;
}
void SaveFlags(ThreadState* t, PVOID handle, bool preferred, bool ui, Saved* allocated) {
    if (!handle) { if (allocated) RtlFreeHeap(process_heap,0,allocated); return; }
    for (auto* p=t->saved;p;p=p->next) if (p->handle==handle) { if (allocated) RtlFreeHeap(process_heap,0,allocated); return; }
    allocated->handle=handle; allocated->preferred=preferred; allocated->ui=ui;
    allocated->next=t->saved; t->saved=allocated;
}
template<class Fn> auto SetPreferred(Fn fn,ULONG flags,PCZZWSTR list,PULONG count,bool process) -> decltype(fn(flags,list,count)) {
    ThreadState* t=process ? nullptr : Thread(true);
    if (!process && !t) return static_cast<decltype(fn(flags,list,count))>(static_cast<NTSTATUS>(0xc0000017UL));
    const auto s=fn(flags,list,count);
    if (s>=0) { if (process) _InterlockedExchange(&process_preferred,list && list[0]); else RecordPreferred(t,list,flags); }
    return s;
}
NTSTATUS NTAPI HookRtlSetProcessPreferredUILanguages(ULONG f,PCZZWSTR b,PULONG n) {
    if (!Operational()) return RAW(RtlSetProcessPreferredUILanguages)(f,b,n); Count(CdfLocaleRtlSetProcessPreferredUILanguages); return SetPreferred(RAW(RtlSetProcessPreferredUILanguages),f,b,n,true); }
NTSTATUS NTAPI HookRtlSetThreadPreferredUILanguages(ULONG f,PCZZWSTR b,PULONG n) {
    if (!Operational()) return RAW(RtlSetThreadPreferredUILanguages)(f,b,n); Count(CdfLocaleRtlSetThreadPreferredUILanguages); return SetPreferred(RAW(RtlSetThreadPreferredUILanguages),f,b,n,false); }
BOOL WINAPI HookSetProcessPreferredUILanguages(ULONG f,PCZZWSTR b,PULONG n) {
    if (!Operational()) return RAW(SetProcessPreferredUILanguages)(f,b,n);
    Count(CdfLocaleSetProcessPreferredUILanguages); const BOOL s=RAW(SetProcessPreferredUILanguages)(f,b,n);
    if (s) _InterlockedExchange(&process_preferred,b && b[0]); return s;
}
BOOL WINAPI HookSetThreadPreferredUILanguages(ULONG f,PCZZWSTR b,PULONG n) {
    if (!Operational()) return RAW(SetThreadPreferredUILanguages)(f,b,n);
    Count(CdfLocaleSetThreadPreferredUILanguages); auto* t=Thread(true); if (!t) return FailMemory();
    const BOOL s=RAW(SetThreadPreferredUILanguages)(f,b,n); if (s) RecordPreferred(t,b,f); return s;
}
template<class Fn> auto SetPreferred2(Fn fn,ULONG f,PCZZWSTR b,PULONG n,PVOID* snapshot) -> decltype(fn(f,b,n,snapshot)) {
    auto* t=Thread(true); if (!t) return static_cast<decltype(fn(f,b,n,snapshot))>(static_cast<NTSTATUS>(0xc0000017UL));
    const bool preferred=t->preferred, ui=t->ui;
    auto* saved=snapshot ? static_cast<Saved*>(RtlAllocateHeap(process_heap,HEAP_ZERO_MEMORY,sizeof(Saved))) : nullptr;
    if (snapshot && !saved) return static_cast<decltype(fn(f,b,n,snapshot))>(static_cast<NTSTATUS>(0xc0000017UL));
    const auto result=fn(f,b,n,snapshot);
    if (result>=0) { RecordPreferred(t,b,f); if (snapshot) SaveFlags(t,*snapshot,preferred,ui,saved); }
    else if (saved) RtlFreeHeap(process_heap,0,saved);
    return result;
}
NTSTATUS NTAPI HookRtlSetThreadPreferredUILanguages2(ULONG f,PCZZWSTR b,PULONG n,PVOID* s) {
    if (!Operational()) return RAW(RtlSetThreadPreferredUILanguages2)(f,b,n,s); Count(CdfLocaleRtlSetThreadPreferredUILanguages2); return SetPreferred2(RAW(RtlSetThreadPreferredUILanguages2),f,b,n,s); }
BOOL WINAPI HookSetThreadPreferredUILanguages2(ULONG f,PCZZWSTR b,PULONG n,PVOID* snapshot) {
    if (!Operational()) return Original<CdfSetPreferred2>(CdfLocaleSetThreadPreferredUILanguages2)(f,b,n,snapshot);
    Count(CdfLocaleSetThreadPreferredUILanguages2);
    auto* t=Thread(true); if (!t) return FailMemory();
    const bool preferred=t->preferred,ui=t->ui;
    auto* saved=snapshot ? static_cast<Saved*>(RtlAllocateHeap(process_heap,HEAP_ZERO_MEMORY,sizeof(Saved))) : nullptr;
    if (snapshot && !saved) return FailMemory();
    const BOOL result=Original<CdfSetPreferred2>(CdfLocaleSetThreadPreferredUILanguages2)(f,b,n,snapshot);
    const DWORD last=RtlGetLastWin32Error();
    if (result) { RecordPreferred(t,b,f); if (snapshot) SaveFlags(t,*snapshot,preferred,ui,saved); }
    else if (saved) RtlFreeHeap(process_heap,0,saved);
    RtlSetLastWin32Error(last); return result;
}
void Restore(PVOID handle, bool native) {
    auto* t=Thread(); bool found=false, preferred=false, ui=false;
    if (t) for (auto* p=t->saved;p;p=p->next) if (p->handle==handle) { found=true; preferred=p->preferred; ui=p->ui; break; }
    if (native) RAW(RtlRestoreThreadPreferredUILanguages)(handle);
    else Original<CdfRestorePreferred>(CdfLocaleRestoreThreadPreferredUILanguages)(handle);
    const DWORD last=RtlGetLastWin32Error();
    if (found && t) {
        t->preferred=preferred; t->ui=ui;
        Saved** p=&t->saved;
        while (*p) { if ((*p)->handle==handle) { auto* old=*p; *p=old->next; RtlFreeHeap(process_heap,0,old); break; } p=&(*p)->next; }
    }
    RtlSetLastWin32Error(last);
}
void NTAPI HookRtlRestoreThreadPreferredUILanguages(PVOID handle) {
    if (!Operational()) return RAW(RtlRestoreThreadPreferredUILanguages)(handle); Count(CdfLocaleRtlRestoreThreadPreferredUILanguages); Restore(handle,true); }
void WINAPI HookRestoreThreadPreferredUILanguages(PVOID handle) {
    if (!Operational()) return Original<CdfRestorePreferred>(CdfLocaleRestoreThreadPreferredUILanguages)(handle); Count(CdfLocaleRestoreThreadPreferredUILanguages); Restore(handle,false); }

struct Definition { const char* name; ULONG modules; PVOID hook; };
Definition definitions[] = {
#define CDF_LOCALE_HOOK(name, modules) {#name,modules,reinterpret_cast<PVOID>(&Hook##name)},
#include "locale_hooks.inc"
#undef CDF_LOCALE_HOOK
};
PVOID Resolve(PVOID module,const char* text) {
    ANSI_STRING name{}; name.Buffer=const_cast<PCHAR>(text);
    while (text[name.Length]) ++name.Length; name.MaximumLength=name.Length;
    PVOID address=nullptr; return cdf::OriginalProcedure(module,&name,0,&address)>=0 ? address : nullptr;
}
}

namespace cdf {
void PrepareLocale(const Config& input,DWORD error,NTSTATUS status) {
    state=1; schema=input.schema_version; config=input.locale;
    error_stage=1; error_code=error; native_error=status;
    if (error) return;
    state|=4; error_stage=0;
    if (!config.enabled) return;
    error_stage=2;
    if (!ValidateLocale(config,error_code,native_error)) return;
    prepared=true; error_stage=error_code=0;
}
bool LocalePrepared() { return prepared; }
bool LocaleProcessLanguages(WCHAR* buffer,ULONG capacity){
    ULONG count=0,length=capacity;
    return Operational()&&QueryLanguages(Kind::Process,MUI_LANGUAGE_NAME,nullptr,&count,buffer,&length)>=0;
}
void AppendLocaleThunks(verifier::ThunkDescriptor* base,verifier::ThunkDescriptor* kernel,verifier::ThunkDescriptor* native) {
    verifier::ThunkDescriptor* cursors[]={base,kernel,native};
    for (ULONG i=0;i<CdfLocaleHookCount;++i) for (ULONG module=0;module<3;++module) {
        if (!(definitions[i].modules & (1U<<module))) continue;
        auto* p=cursors[module]++; p->name=const_cast<PCHAR>(definitions[i].name); p->new_address=definitions[i].hook;
        bindings[i].descriptors[module]=p;
    }
}
PVOID RedirectLocaleAddress(PVOID address) {
    if (!prepared || !address) return address;
    for (ULONG i=0;i<CdfLocaleHookCount;++i) for (auto* p:bindings[i].descriptors)
        if (p && p->old_address==address) return definitions[i].hook;
    return address;
}
void InitializeTls(PVOID module) {
    if (!module || Operational()) return;
    {
            tls_alloc=reinterpret_cast<decltype(tls_alloc)>(Resolve(module,"TlsAlloc"));
            tls_get=reinterpret_cast<decltype(tls_get)>(Resolve(module,"TlsGetValue"));
            tls_set=reinterpret_cast<decltype(tls_set)>(Resolve(module,"TlsSetValue"));
            tls_free=reinterpret_cast<decltype(tls_free)>(Resolve(module,"TlsFree"));
            const auto get_heap=reinterpret_cast<decltype(&GetProcessHeap)>(Resolve(module,"GetProcessHeap"));
            if (get_heap) process_heap=get_heap();
        }
        if (tls_alloc && tls_get && tls_set && tls_free && process_heap) tls_index=tls_alloc();
        if (tls_index==TLS_OUT_OF_INDEXES) { error_stage=3; error_code=ERROR_NOT_ENOUGH_MEMORY; return; }
        state|=8|32; error_stage=error_code=0; native_error=0;
}
void NTAPI LocaleDllLoaded(PWSTR name,PVOID address,SIZE_T,PVOID) {
    if (!prepared || !name) return;
    const WCHAR* tail=name;
    for (const WCHAR* p=name;*p;++p) if (*p==L'\\' || *p==L'/') tail=p+1;
    const WCHAR expected[]=L"kernelbase.dll"; ULONG i=0;
    while (tail[i] && expected[i]) {
        WCHAR c=tail[i]; if (c>=L'A' && c<=L'Z') c+=L'a'-L'A';
        if (c!=expected[i]) return;
        ++i;
    }
    if (!tail[i] && !expected[i]) InitializeTls(address);
}

void LocaleEvent(DWORD reason) {
    if (reason==DLL_PROCESS_ATTACH) {
        state|=2;
        if (!prepared) return;
        UNICODE_STRING name; RtlInitUnicodeString(&name,L"kernelbase.dll"); PVOID module=nullptr;
        native_error=LdrGetDllHandle(nullptr,nullptr,&name,&module);
        if (native_error>=0) InitializeTls(module);
    } else if (reason==DLL_THREAD_DETACH && tls_index!=TLS_OUT_OF_INDEXES) {
        auto* t=Thread(); if (!t) return;
        while (t->saved) { auto* p=t->saved; t->saved=p->next; RtlFreeHeap(process_heap,0,p); }
        tls_set(tls_index,nullptr); RtlFreeHeap(process_heap,0,t); _InterlockedDecrement64(&live_records);
    }
}
}
extern "C" __declspec(dllexport) DWORD WINAPI CdfLocaleQueryStatus(CdfLocaleStatus* output,DWORD size) {
    if (!output || size!=sizeof(*output)) return ERROR_INVALID_PARAMETER;
    cdf::Zero(output,sizeof(*output)); output->size=sizeof(*output); output->version=1;
    output->config_version=schema; output->state=state; output->verifier_flags=cdf::ProviderVerifierFlags();
    output->error_stage=error_stage; output->error_code=error_code; output->native_status=native_error;
    output->format_lcid=config.format_lcid; output->ui_langid=LANGIDFROMLCID(config.ui_lcid);
    cdf::CopyText(output->format_locale,LOCALE_NAME_MAX_LENGTH,config.format_locale);
    cdf::CopyText(output->ui_language,LOCALE_NAME_MAX_LENGTH,config.ui_language);
    output->required_hooks=CdfLocaleHookCount;
    for (ULONG i=0;i<CdfLocaleHookCount;++i) {
        bool resolved=prepared;
        for (ULONG m=0;m<3;++m) if (definitions[i].modules & (1U<<m)) {
            ++output->required_aliases;
            const auto* p=bindings[i].descriptors[m];
            if (p && p->old_address) ++output->resolved_aliases; else resolved=false;
        }
        if (resolved) ++output->resolved_hooks;
        output->calls[i]=static_cast<ULONGLONG>(_InterlockedCompareExchange64(&counters[i],0,0));
    }
    if (output->resolved_hooks==CdfLocaleHookCount) output->state|=16;
    output->live_thread_records=static_cast<ULONGLONG>(_InterlockedCompareExchange64(&live_records,0,0));
    return ERROR_SUCCESS;
}
