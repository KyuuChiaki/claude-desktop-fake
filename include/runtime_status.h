#pragma once
#include <Windows.h>
#include <cstddef>
enum CdfRuntimeState : DWORD {
    CdfRuntimeConfigured=1, CdfRuntimeTime=2, CdfRuntimeLocale=4,
    CdfRuntimeRegion=8, CdfRuntimeAdapterReady=16, CdfRuntimePassthrough=32,
    CdfRuntimeTlsReady=64
};
inline constexpr DWORD CdfRuntimeBlockedExit=0xE0CDF501;
struct CdfRuntimeStatus {
    DWORD size,version,state,error_code,resolved_process_hooks,resolved_winrt_hooks;
    ULONGLONG process_time_calls,native_process_time_calls,activation_calls,language_calls;
    DWORD schema_version,policy,compatibility,error_stage,patch_count,region_hooks;
    ULONGLONG region_calls,format_calls;
    WCHAR home_region[4],format_locale[LOCALE_NAME_MAX_LENGTH],ui_language[LOCALE_NAME_MAX_LENGTH];
    WCHAR adapter_id[96],runtime_version[64];
    BYTE fingerprint[32];
    DWORD capture_enabled,captured_contexts,capture_failures,capture_truncated;
};
static_assert(offsetof(CdfRuntimeStatus,schema_version)==56);
static_assert(sizeof(CdfRuntimeStatus)==816);
using CdfRuntimeQuery=DWORD(WINAPI*)(CdfRuntimeStatus*,DWORD);
