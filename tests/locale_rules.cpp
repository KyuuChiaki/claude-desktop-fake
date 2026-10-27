#include "test_support.h"
#include "locale_native.h"
#include <iostream>
#include <string>

namespace {
unsigned checks=0; std::vector<std::string> failures;
void Check(bool ok,const std::string& text) { ++checks; if(!ok)failures.push_back(text); }
std::string Profile(const std::string& region,const std::string& ui) {
    return "{\"schemaVersion\":2,\"time\":{\"enabled\":false,\"timeZoneId\":\"UTC\",\"utcOffsetSeconds\":0},\"locale\":{\"enabled\":true,\"formatLocale\":\""+region+"\",\"uiLanguage\":\""+ui+"\"}}";
}
void Parser() {
    cdf::Config config{}; DWORD error=0;
    const std::string old="{\"schemaVersion\":1,\"enabled\":true,\"timeZoneId\":\"UTC\",\"utcOffsetSeconds\":3600}";
    Check(cdf::ParseConfig(old.data(),static_cast<ULONG>(old.size()),config,error) && config.schema_version==1 && !config.locale.enabled && config.offset_ticks==3600*cdf::ticks_second,"legacy schema stays time only");
    const auto valid=Profile("en-US","de-DE");
    Check(cdf::ParseConfig(valid.data(),static_cast<ULONG>(valid.size()),config,error) && config.schema_version==2 && !config.enabled && config.locale.enabled,"v2 independent activation");
    const std::string reversed="{\"locale\":{\"uiLanguage\":\"fr-FR\",\"formatLocale\":\"en-GB\",\"enabled\":false},\"time\":{\"utcOffsetSeconds\":-90000,\"timeZoneId\":\"UTC\",\"enabled\":true},\"schemaVersion\":2}";
    Check(cdf::ParseConfig(reversed.data(),static_cast<ULONG>(reversed.size()),config,error) && config.enabled && !config.locale.enabled && config.offset_seconds==-90000,"ordering and independent time activation");
    std::vector<std::string> invalid={"", "{}", valid+"x", "["+valid+"]"};
    auto Replace=[&](const std::string& from,const std::string& to) { auto text=valid; const auto pos=text.find(from); Check(pos!=std::string::npos,"fixture token"); text.replace(pos,from.size(),to); invalid.push_back(text); };
    Replace("\"schemaVersion\":2","\"schemaVersion\":3");
    Replace("\"schemaVersion\":2","\"schemaVersion\":2,\"schemaVersion\":2");
    Replace("\"locale\":{","\"extra\":1,\"locale\":{");
    Replace("\"enabled\":true","\"enabled\":1");
    Replace("\"formatLocale\":\"en-US\"","\"formatLocale\":\"en-US\",\"formatLocale\":\"en-US\"");
    Replace("\"formatLocale\":\"en-US\",","");
    Replace("\"formatLocale\":\"en-US\"","\"formatLocale\":123");
    Replace("\"formatLocale\":\"en-US\"","\"formatLocale\":\"\"");
    Replace("\"formatLocale\":\"en-US\"","\"formatLocale\":\"en-US\",\"unknown\":0");
    Replace("\"locale\":{","\"locale\":[");
    Replace("\"utcOffsetSeconds\":0","\"utcOffsetSeconds\":1.5");
    Replace("\"utcOffsetSeconds\":0","\"utcOffsetSeconds\":9223372036854775807");
    Replace("\"uiLanguage\":\"de-DE\"","\"uiLanguage\":\"de-DE\",");
    Replace("\"time\":{","\"time\":{\"time\":0,");
    for(size_t i=0;i<invalid.size();++i) Check(!cdf::ParseConfig(invalid[i].data(),static_cast<ULONG>(invalid[i].size()),config,error),"reject malformed v2 "+std::to_string(i));
    const std::string bom="\xef\xbb\xbf"+valid;
    Check(cdf::ParseConfig(bom.data(),static_cast<ULONG>(bom.size()),config,error),"v2 BOM");
    auto escaped=valid; escaped.replace(escaped.find("en-US"),5,"en-\\u0055S");
    Check(cdf::ParseConfig(escaped.data(),static_cast<ULONG>(escaped.size()),config,error),"escaped locale ASCII");
    const std::string oversized(16385,' '); Check(!cdf::ParseConfig(oversized.data(),static_cast<ULONG>(oversized.size()),config,error),"size bound");
}
void Names() {
    const std::pair<const char*,const WCHAR*> names[]={{"en-us",L"en-US"},{"EN-gb",L"en-GB"},{"de-de",L"de-DE"},{"fr-fr",L"fr-FR"},{"zh-cn",L"zh-CN"},{"ja-jp",L"ja-JP"}};
    for(const auto& region:names) for(const auto& ui:names) {
        const auto text=Profile(region.first,ui.first); cdf::Config config{}; DWORD error=0; NTSTATUS status=0;
        Check(cdf::ParseConfig(text.data(),static_cast<ULONG>(text.size()),config,error) && cdf::ValidateLocale(config.locale,error,status),"NLS supported names");
        Check(std::wstring(config.locale.format_locale)==region.second && std::wstring(config.locale.ui_language)==ui.second,"canonical names");
        Check(config.locale.format_lcid==LocaleNameToLCID(region.second,0) && config.locale.ui_lcid==LocaleNameToLCID(ui.second,0),"NLS identity agreement");
    }
    for(const char* invalid:{"en","de","zh-Hans","iv","zz-ZZ","en-US-x-private","!x-sys-default-locale","en_US","1033","en-US/../xx"}) {
        const auto text=Profile(invalid,"en-US"); cdf::Config config{}; DWORD error=0; NTSTATUS status=0;
        Check(cdf::ParseConfig(text.data(),static_cast<ULONG>(text.size()),config,error) && !cdf::ValidateLocale(config.locale,error,status) && error!=0,"reject nonconcrete/unknown format locale");
        const auto other=Profile("en-US",invalid);
        Check(cdf::ParseConfig(other.data(),static_cast<ULONG>(other.size()),config,error) && !cdf::ValidateLocale(config.locale,error,status),"reject nonconcrete/unknown UI language");
    }
}
}
int main() {
    Parser(); Names();
    std::cout<<"{\"passed\":"<<(failures.empty()?"true":"false")<<",\"checks\":"<<checks<<",\"failures\":[";
    for(size_t i=0;i<failures.size();++i) { if(i)std::cout<<',';std::cout<<cdf::test::Json(failures[i]); } std::cout<<"]}\n";
    return failures.empty()?0:1;
}
