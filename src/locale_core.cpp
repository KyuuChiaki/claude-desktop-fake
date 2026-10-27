#include "time_core.h"
#include "locale_native.h"

namespace cdf {
namespace {
bool Normalize(WCHAR* text, LCID& id, NTSTATUS& status) {
    if (!text[0]) return false;
    for (ULONG i = 0; text[i]; ++i) {
        const WCHAR c = text[i];
        if (!((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') ||
              (c >= L'0' && c <= L'9') || c == L'-')) return false;
    }
    // Rtl's flag 2 permits neutral names without silently expanding them.
    status = RtlLocaleNameToLcid(text, &id, 2);
    if (status < 0 || id == LOCALE_CUSTOM_UNSPECIFIED || id == LOCALE_INVARIANT ||
        id > 0xffff || SUBLANGID(LANGIDFROMLCID(id)) == SUBLANG_NEUTRAL) return false;
    WCHAR normalized[LOCALE_NAME_MAX_LENGTH]{};
    UNICODE_STRING name{}; name.Buffer = normalized; name.MaximumLength = sizeof(normalized);
    status = RtlLcidToLocaleName(id, &name, 0, FALSE);
    if (status < 0 || name.Length >= sizeof(normalized)) return false;
    normalized[name.Length / sizeof(WCHAR)] = 0;
    return CopyText(text, LOCALE_NAME_MAX_LENGTH, normalized);
}
}
bool ValidateLocale(LocaleConfig& config, DWORD& error, NTSTATUS& status) {
    status = 0; error = ERROR_INVALID_PARAMETER;
    if (!Normalize(config.format_locale, config.format_lcid, status) ||
        !Normalize(config.ui_language, config.ui_lcid, status)) {
        if (status >= 0) status = status_invalid_parameter;
        return false;
    }
    error = 0; status = 0; return true;
}
bool ValidateRegion(RegionConfig& config,DWORD& error) {
    error=ERROR_INVALID_PARAMETER;
    UNICODE_STRING module;RtlInitUnicodeString(&module,L"kernelbase.dll");PVOID handle=nullptr,address=nullptr;
    if(LdrGetDllHandle(nullptr,nullptr,&module,&handle)<0)return false;
    ANSI_STRING name;RtlInitAnsiString(&name,"GetGeoInfoEx");
    if(LdrGetProcedureAddress(handle,&name,0,&address)<0)return false;
    WCHAR id[16]{};
    const auto query=reinterpret_cast<decltype(&GetGeoInfoEx)>(address);
    if(!query(config.home_region,GEO_ID,id,16))return false;
    ULONG number=0;
    for(unsigned i=0;id[i];++i){if(id[i]<L'0'||id[i]>L'9')return false;const ULONG digit=id[i]-L'0';if(number>(0x7fffffffU-digit)/10)return false;number=number*10+digit;}
    if(!number||number>0x7fffffff)return false;
    WCHAR iso[8]{},iso3[8]{};
    if(!query(config.home_region,GEO_ISO2,iso,8)||iso[0]!=config.home_region[0]||iso[1]!=config.home_region[1]||iso[2]||!query(config.home_region,GEO_ISO3,iso3,8))return false;
    // Require installed concrete ISO alpha-2 and alpha-3 data. Macro regions
    // (001, EU, etc.) cannot pass this round trip.
    for(unsigned i=0;i<3;i++)if(iso3[i]<L'A'||iso3[i]>L'Z')return false;
    if(iso3[3])return false;
    config.geo_id=static_cast<GEOID>(number);error=0;return true;
}
}
