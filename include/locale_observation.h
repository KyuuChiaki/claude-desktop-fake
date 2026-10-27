#pragma once
#include "locale_status.h"
#include "locale_native.h"

namespace cdf::test {
struct LocaleObservation {
    BOOL loaded, status_valid, original_entries; CdfLocaleStatus status;
    WCHAR user[85], system[85], date[128], time[128], decimal[32], thousands[32], currency[32];
    LCID user_id, system_id, thread_id, native_user, native_system;
    LANGID user_ui, system_ui, thread_ui, native_default_ui, native_install_ui;
    NTSTATUS native_status[4];
    WCHAR preferred[4][512], native_preferred[4][512];
    ULONG counts[4], lengths[4]; BOOL lists_ok[4]; NTSTATUS native_lists[4];
    SYSTEMTIME local; WCHAR current_date[128], current_time[128];
};
inline void CaptureLocale(LocaleObservation& o) {
    const HMODULE provider=GetModuleHandleW(L"CdfTimeZone64.dll"); o.loaded=provider!=nullptr;
    if (provider) {
        const auto query=reinterpret_cast<CdfLocaleQuery>(GetProcAddress(provider,"CdfLocaleQueryStatus"));
        o.status_valid=query && query(&o.status,sizeof(o.status))==0;
    }
    o.original_entries=TRUE;
    const PVOID imports[]={reinterpret_cast<PVOID>(&GetUserDefaultLocaleName),reinterpret_cast<PVOID>(&GetSystemDefaultLocaleName),
        reinterpret_cast<PVOID>(&GetUserDefaultLCID),reinterpret_cast<PVOID>(&GetSystemDefaultLCID),reinterpret_cast<PVOID>(&GetThreadLocale),
        reinterpret_cast<PVOID>(&GetUserDefaultUILanguage),reinterpret_cast<PVOID>(&GetSystemDefaultUILanguage),
        reinterpret_cast<PVOID>(&GetThreadUILanguage),reinterpret_cast<PVOID>(&GetLocaleInfoEx),reinterpret_cast<PVOID>(&GetThreadPreferredUILanguages)};
    for(const PVOID entry:imports) {
        HMODULE owner=nullptr;
        if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(entry),&owner) || (provider && owner==provider)) o.original_entries=FALSE;
    }
    if(provider) {
        const HMODULE modules[]={GetModuleHandleW(L"kernelbase.dll"),GetModuleHandleW(L"kernel32.dll"),GetModuleHandleW(L"ntdll.dll")};
#define CDF_LOCALE_HOOK(name,mask) for(unsigned m=0;m<3;++m) if((mask)&(1U<<m)) { \
        HMODULE owner=nullptr;const auto entry=GetProcAddress(modules[m],#name); \
        if(!entry || !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,reinterpret_cast<LPCWSTR>(entry),&owner) || owner==provider) o.original_entries=FALSE; }
#include "locale_hooks.inc"
#undef CDF_LOCALE_HOOK
    }
    GetUserDefaultLocaleName(o.user,85); GetSystemDefaultLocaleName(o.system,85);
    o.user_id=GetUserDefaultLCID(); o.system_id=GetSystemDefaultLCID(); o.thread_id=GetThreadLocale();
    o.user_ui=GetUserDefaultUILanguage(); o.system_ui=GetSystemDefaultUILanguage(); o.thread_ui=GetThreadUILanguage();
    o.native_status[0]=NtQueryDefaultLocale(TRUE,&o.native_user);
    o.native_status[1]=NtQueryDefaultLocale(FALSE,&o.native_system);
    o.native_status[2]=NtQueryDefaultUILanguage(&o.native_default_ui);
    o.native_status[3]=NtQueryInstallUILanguage(&o.native_install_ui);
    GetLocaleInfoEx(nullptr,LOCALE_SSHORTDATE,o.date,128);
    GetLocaleInfoW(LOCALE_SYSTEM_DEFAULT,LOCALE_STIMEFORMAT,o.time,128);
    GetLocaleInfoEx(nullptr,LOCALE_SDECIMAL,o.decimal,32);
    GetLocaleInfoW(LOCALE_USER_DEFAULT,LOCALE_STHOUSAND,o.thousands,32);
    GetLocaleInfoEx(nullptr,LOCALE_SCURRENCY,o.currency,32);
    using Getter=BOOL(WINAPI*)(DWORD,PULONG,PZZWSTR,PULONG);
    const Getter getters[]={GetSystemPreferredUILanguages,GetUserPreferredUILanguages,GetProcessPreferredUILanguages,GetThreadPreferredUILanguages};
    for (ULONG i=0;i<4;++i) {
        o.lengths[i]=512; o.lists_ok[i]=getters[i](MUI_LANGUAGE_NAME,&o.counts[i],o.preferred[i],&o.lengths[i]);
        ULONG count=0,length=512;
        switch(i) {
        case 0:o.native_lists[i]=RtlGetSystemPreferredUILanguages(MUI_LANGUAGE_NAME,nullptr,&count,o.native_preferred[i],&length);break;
        case 1:o.native_lists[i]=RtlGetUserPreferredUILanguages(MUI_LANGUAGE_NAME,nullptr,&count,o.native_preferred[i],&length);break;
        case 2: {
            const auto fn=reinterpret_cast<decltype(&RtlGetProcessPreferredUILanguages)>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"RtlGetProcessPreferredUILanguages"));
            o.native_lists[i]=fn ? fn(MUI_LANGUAGE_NAME,&count,o.native_preferred[i],&length) : static_cast<NTSTATUS>(0xc000007aUL); break;
        }
        default:o.native_lists[i]=RtlGetThreadPreferredUILanguages(MUI_LANGUAGE_NAME,&count,o.native_preferred[i],&length);break;
        }
    }
    GetLocalTime(&o.local);
    GetDateFormatEx(nullptr,DATE_SHORTDATE,nullptr,nullptr,o.current_date,128,nullptr);
    GetTimeFormatEx(nullptr,0,nullptr,nullptr,o.current_time,128);
}
}
