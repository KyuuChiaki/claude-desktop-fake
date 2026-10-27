#include "claude_identity.h"
#include "time_zone_status.h"
#include "locale_status.h"
#include <iostream>
#include <string>

using IdentityQuery = DWORD(WINAPI*)(cdf::claude::IdentityStatus*,DWORD);
using TimeQuery = DWORD(WINAPI*)(CdfTimeZoneStatus*,DWORD);
using LocaleQuery = DWORD(WINAPI*)(CdfLocaleStatus*,DWORD);

namespace {
struct Snapshot { bool module=false, identity_found=false, time_found=false; DWORD identity_result=ERROR_PROC_NOT_FOUND, time_result=ERROR_PROC_NOT_FOUND, locale_result=ERROR_PROC_NOT_FOUND; cdf::claude::IdentityStatus identity{}; CdfTimeZoneStatus time{}; CdfLocaleStatus locale{}; WCHAR observed_locale[LOCALE_NAME_MAX_LENGTH]{}; DYNAMIC_TIME_ZONE_INFORMATION observed_zone{}; };
Snapshot tls;

void Sample(Snapshot& value) {
    GetUserDefaultLocaleName(value.observed_locale,LOCALE_NAME_MAX_LENGTH);
    GetDynamicTimeZoneInformation(&value.observed_zone);
    HMODULE module=GetModuleHandleW(L"CdfClaudeTimeZoneTest64.dll");
    if (!module) module=GetModuleHandleW(L"CdfClaudeTimeZone64.dll");
    value.module=module!=nullptr;
    if (!module) return;
    auto identity=reinterpret_cast<IdentityQuery>(GetProcAddress(module,"CdfClaudeQueryIdentityStatus"));
    auto time=reinterpret_cast<TimeQuery>(GetProcAddress(module,"CdfTimeZoneQueryStatus"));
    auto locale=reinterpret_cast<LocaleQuery>(GetProcAddress(module,"CdfLocaleQueryStatus"));
    if (identity) { value.identity_result=identity(&value.identity,sizeof(value.identity)); value.identity_found=true; }
    if (time) { value.time_result=time(&value.time,sizeof(value.time)); value.time_found=true; }
    if (locale) value.locale_result=locale(&value.locale,sizeof(value.locale));
}
void NTAPI Tls(PVOID,DWORD reason,PVOID) {
    if (reason==DLL_PROCESS_ATTACH) Sample(tls);
}

#pragma section(".CRT$XLB",long,read)
extern "C" __declspec(allocate(".CRT$XLB")) const PIMAGE_TLS_CALLBACK cdf_claude_gate_tls=Tls;
#pragma comment(linker,"/INCLUDE:_tls_used")
#pragma comment(linker,"/INCLUDE:cdf_claude_gate_tls")

const WCHAR* Reason(DWORD value) {
    switch (static_cast<cdf::claude::Reason>(value)) {
    case cdf::claude::Reason::Matched: return L"matched";
    case cdf::claude::Reason::ManifestMissing: return L"manifest-missing";
    case cdf::claude::Reason::ManifestInvalid: return L"manifest-invalid";
    case cdf::claude::Reason::ProcessImageUnavailable: return L"process-image-unavailable";
    case cdf::claude::Reason::ImageFileUnavailable: return L"image-file-unavailable";
    case cdf::claude::Reason::ImageNotListed: return L"image-not-listed";
    case cdf::claude::Reason::FileIdentityMismatch: return L"file-identity-mismatch";
    default: return L"not-checked";
    }
}

bool Check(const Snapshot& value,const std::wstring& expectation) {
    if (!value.module || !value.identity_found || !value.time_found || value.identity_result || value.time_result) return false;
    if (expectation==L"match") return value.identity.reason==static_cast<DWORD>(cdf::claude::Reason::Matched) &&
        (value.identity.state&8)!=0 && value.time.state==31 && value.time.resolved_hooks==CdfTimeHookCount && value.time.resolved_bridges==5 &&
        value.locale_result==0 && value.locale.state==63 && value.locale.resolved_hooks==CdfLocaleHookCount &&
        std::wstring(value.observed_locale)==value.locale.format_locale && std::wstring(value.observed_zone.TimeZoneKeyName)==value.time.time_zone_id;
    return value.identity.reason!=static_cast<DWORD>(cdf::claude::Reason::Matched) &&
        (value.identity.state&8)==0 && (value.time.state&8)==0 && value.time.resolved_hooks==0 && value.locale.resolved_hooks==0;
}

void Json(const WCHAR* stage,const Snapshot& value) {
    std::wcout<<L"{\"stage\":\""<<stage<<L"\",\"providerLoaded\":"<<(value.module?L"true":L"false")
        <<L",\"identityExport\":"<<(value.identity_found?L"true":L"false")<<L",\"identityResult\":"<<value.identity_result
        <<L",\"identityState\":"<<value.identity.state<<L",\"identityReason\":\""<<Reason(value.identity.reason)
        <<L"\",\"identityError\":"<<value.identity.error_code<<L",\"nativeStatus\":"<<value.identity.native_status
        <<L",\"imageCount\":"<<value.identity.image_count<<L",\"timeExport\":"<<(value.time_found?L"true":L"false")
        <<L",\"timeResult\":"<<value.time_result<<L",\"timeState\":"<<value.time.state
        <<L",\"resolvedHooks\":"<<value.time.resolved_hooks<<L",\"resolvedBridges\":"<<value.time.resolved_bridges
        <<L",\"localeState\":"<<value.locale.state<<L",\"localeHooks\":"<<value.locale.resolved_hooks
        <<L",\"observedLocale\":\""<<value.observed_locale<<L"\",\"observedZone\":\""<<value.observed_zone.TimeZoneKeyName<<L"\"}";
}
}

int wmain(int argc,WCHAR** argv) {
    std::wstring expectation=L"match";
    if (argc==3 && std::wstring(argv[1])==L"--expect") expectation=argv[2];
    if (expectation!=L"match" && expectation!=L"deny" && expectation!=L"absent") return 87;
    Snapshot main{}; Sample(main);
    const bool tls_ok=expectation==L"absent" ? !tls.module : Check(tls,expectation);
    const bool main_ok=expectation==L"absent" ? !main.module : Check(main,expectation);
    std::wcout<<L"{\"expected\":\""<<expectation<<L"\",\"tls\":"; Json(L"tls",tls);
    std::wcout<<L",\"main\":"; Json(L"main",main);
    std::wcout<<L",\"matched\":"<<(tls_ok&&main_ok?L"true":L"false")<<L"}"<<std::endl;
    return tls_ok&&main_ok?0:1;
}
