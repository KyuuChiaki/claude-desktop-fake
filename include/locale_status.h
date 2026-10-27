#pragma once
#include <Windows.h>
#include <cstddef>
enum CdfLocaleHook : DWORD {
#define CDF_LOCALE_HOOK(name, modules) CdfLocale##name,
#include "locale_hooks.inc"
#undef CDF_LOCALE_HOOK
    CdfLocaleHookCount
};
inline constexpr const char* cdf_locale_hook_names[CdfLocaleHookCount] = {
#define CDF_LOCALE_HOOK(name, modules) #name,
#include "locale_hooks.inc"
#undef CDF_LOCALE_HOOK
};
struct CdfLocaleStatus {
    DWORD size, version, config_version, state, verifier_flags;
    DWORD error_stage, error_code; LONG native_status;
    LCID format_lcid; LANGID ui_langid; WORD reserved;
    WCHAR format_locale[LOCALE_NAME_MAX_LENGTH], ui_language[LOCALE_NAME_MAX_LENGTH];
    DWORD resolved_hooks, required_hooks, resolved_aliases, required_aliases;
    ULONGLONG live_thread_records, calls[CdfLocaleHookCount];
};
static_assert(sizeof(CdfLocaleStatus)==832);
static_assert(offsetof(CdfLocaleStatus,calls)==408);
// 1 handshake, 2 attach, 4 valid JSON, 8 enabled snapshot, 16 all hook
// aliases resolved, 32 TLS storage ready. Full readiness is 0x3f.
using CdfLocaleQuery = DWORD(WINAPI*)(CdfLocaleStatus*, DWORD);
