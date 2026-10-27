#include "locale_observation.h"
#include "test_support.h"
#include <iostream>
#include <thread>
#include <atomic>
#include <clocale>
#include <cwchar>

extern "C" __declspec(dllimport) const cdf::test::LocaleObservation* WINAPI CdfLocaleEarlySnapshot();
namespace {
cdf::test::LocaleObservation tls_observation{};
void NTAPI Tls(PVOID,DWORD reason,PVOID) { if (reason==DLL_PROCESS_ATTACH) cdf::test::CaptureLocale(tls_observation); }
#pragma section(".CRT$XLB",long,read)
extern "C" __declspec(allocate(".CRT$XLB")) const PIMAGE_TLS_CALLBACK cdf_locale_tls=Tls;
#pragma comment(linker,"/INCLUDE:_tls_used")
#pragma comment(linker,"/INCLUDE:cdf_locale_tls")
std::vector<std::string> failures;
unsigned checks=0;
void Check(bool ok,const std::string& label) { ++checks; if (!ok) failures.push_back(label); }
std::wstring Info(const WCHAR* name,LCTYPE type) {
    WCHAR text[256]{}; GetLocaleInfoEx(name,type|LOCALE_NOUSEROVERRIDE,text,256); return text;
}
void Observation(const cdf::test::LocaleObservation& o,const std::string& stage,bool enabled,bool present,const std::wstring& region,const std::wstring& ui) {
    Check((o.loaded!=FALSE)==present,stage+" provider presence");
    if (!enabled) {
        if (present) Check(o.status_valid && !(o.status.state&8),stage+" inactive");
        Check(o.original_entries!=FALSE,stage+" inactive locale imports and dynamic exports belong to original Windows modules"); return;
    }
    const LCID id=LocaleNameToLCID(region.c_str(),0), uid=LocaleNameToLCID(ui.c_str(),0);
    Check(o.status_valid && o.status.state==0x3f,stage+" ready state="+std::to_string(o.status.state)+" stage="+std::to_string(o.status.error_stage)+" code="+std::to_string(o.status.error_code));
    Check(o.status.resolved_hooks==CdfLocaleHookCount,stage+" all hooks");
    Check(region==o.user && region==o.system,stage+" locale names");
    Check(o.user_id==id && o.system_id==id && o.thread_id==id && o.native_user==id && o.native_system==id,stage+" LCIDs");
    Check(o.user_ui==LANGIDFROMLCID(uid) && o.system_ui==LANGIDFROMLCID(uid) && o.thread_ui==LANGIDFROMLCID(uid) && o.native_default_ui==LANGIDFROMLCID(uid) && o.native_install_ui==LANGIDFROMLCID(uid),stage+" UI language IDs");
    Check(Info(region.c_str(),LOCALE_SSHORTDATE)==o.date && Info(region.c_str(),LOCALE_STIMEFORMAT)==o.time,stage+" date/time NLS");
    Check(Info(region.c_str(),LOCALE_SDECIMAL)==o.decimal && Info(region.c_str(),LOCALE_STHOUSAND)==o.thousands && Info(region.c_str(),LOCALE_SCURRENCY)==o.currency,stage+" number/currency NLS");
    for (unsigned i=0;i<4;++i) Check(o.lists_ok[i] && o.native_lists[i]>=0 && ui==o.preferred[i] && ui==o.native_preferred[i],stage+" preferred list "+std::to_string(i));
}
#include "locale_checks.h"
void PrintObservation(const cdf::test::LocaleObservation& o) {
    std::cout<<"{\"loaded\":"<<(o.loaded?"true":"false")<<",\"originalEntries\":"<<(o.original_entries?"true":"false")<<",\"state\":"<<o.status.state<<",\"errorStage\":"<<o.status.error_stage<<",\"errorCode\":"<<o.status.error_code
        <<",\"nativeError\":"<<o.status.native_status<<",\"resolvedHooks\":"<<o.status.resolved_hooks<<",\"requiredHooks\":"<<o.status.required_hooks
        <<",\"resolvedAliases\":"<<o.status.resolved_aliases<<",\"requiredAliases\":"<<o.status.required_aliases<<",\"user\":"<<cdf::test::Json(std::wstring(o.user))<<",\"system\":"<<cdf::test::Json(std::wstring(o.system))
        <<",\"userLCID\":"<<o.user_id<<",\"systemLCID\":"<<o.system_id<<",\"threadLCID\":"<<o.thread_id<<",\"userUI\":"<<o.user_ui<<",\"systemUI\":"<<o.system_ui<<",\"threadUI\":"<<o.thread_ui
        <<",\"shortDate\":"<<cdf::test::Json(std::wstring(o.date))<<",\"currency\":"<<cdf::test::Json(std::wstring(o.currency))<<",\"preferred\":[";
    for (unsigned i=0;i<4;++i) { if(i) std::cout<<','; std::cout<<cdf::test::Json(std::wstring(o.preferred[i])); }
    std::cout<<"],\"local\":"; cdf::test::PrintDate(std::cout,o.local); std::cout<<",\"currentDate\":"<<cdf::test::Json(std::wstring(o.current_date))<<",\"currentTime\":"<<cdf::test::Json(std::wstring(o.current_time))<<'}';
}
}
int wmain(int argc,WCHAR** argv) {
    std::wstring expectation=L"absent",region=L"en-US",ui=L"en-US",late;
    bool smoke=false,wait_input=false;
    for(int i=1;i<argc;++i) {
        const std::wstring option=argv[i];
        if(option==L"--smoke") smoke=true;
        else if(option==L"--wait-for-input") wait_input=true;
        else if(i+1<argc && option==L"--expect") expectation=argv[++i];
        else if(i+1<argc && option==L"--format") region=argv[++i];
        else if(i+1<argc && option==L"--ui") ui=argv[++i];
        else if(i+1<argc && option==L"--late") late=argv[++i];
        else return 2;
    }
    if(wait_input) { std::cout<<"{\"ready\":true}\n"<<std::flush; std::string line; std::getline(std::cin,line); }
    cdf::test::LocaleObservation main{}; cdf::test::CaptureLocale(main);
    const auto early=*CdfLocaleEarlySnapshot();
    const bool enabled=expectation==L"active",present=expectation!=L"absent";
    Observation(early,"early",enabled,present,region,ui); Observation(tls_observation,"tls",enabled,present,region,ui); Observation(main,"main",enabled,present,region,ui);
    cdf::test::LocaleObservation late_observation{}; HMODULE module=nullptr;
    if(!late.empty()) {
        module=LoadLibraryW(late.c_str()); Check(module!=nullptr,"late consumer load");
        if(module) {
            using Fn=const cdf::test::LocaleObservation*(WINAPI*)();
            const auto fn=cdf::test::Resolve<Fn>(module,"CdfLocaleLateSnapshot"); Check(fn!=nullptr,"late export");
            if(fn) { late_observation=*fn(); Observation(late_observation,"late",enabled,present,region,ui); }
        }
    }
    QueryContracts();
    if(enabled && !smoke) { RegionData(region); FormatData(region); MuiContracts(ui); Resolvers(region); ExplicitState(region,ui); PreferredOverrides(ui); Threads(region,ui); Ucrt(region); }
    CdfLocaleStatus final_status{};
    if(enabled && !smoke) {
        const auto query=cdf::test::Resolve<CdfLocaleQuery>(GetModuleHandleW(L"CdfTimeZone64.dll"),"CdfLocaleQueryStatus"); query(&final_status,sizeof(final_status));
        for(unsigned i=0;i<CdfLocaleHookCount;++i) Check(final_status.calls[i]>0,std::string("hook exercised: ")+cdf_locale_hook_names[i]);
    }
    std::cout<<"{\"passed\":"<<(failures.empty()?"true":"false")<<",\"checks\":"<<checks<<",\"early\":"; PrintObservation(early);
    std::cout<<",\"tls\":"; PrintObservation(tls_observation); std::cout<<",\"main\":"; PrintObservation(main); std::cout<<",\"late\":"; PrintObservation(late_observation);
    std::cout<<",\"nlsReference\":"<<NlsReference(region)<<",\"ucrtDefault\":"<<cdf::test::Json(ucrt_default)<<",\"nativeContracts\":[";
    for(size_t i=0;i<native_contracts.size();++i) { if(i)std::cout<<','; std::cout<<native_contracts[i]; }
    std::cout<<"],\"nameContracts\":[";for(size_t i=0;i<name_contracts.size();++i){if(i)std::cout<<',';std::cout<<name_contracts[i];}
    std::cout<<"],\"hookCalls\":["; for(unsigned i=0;i<CdfLocaleHookCount;++i) { if(i)std::cout<<','; std::cout<<final_status.calls[i]; }
    std::cout<<"],\"failures\":["; for(size_t i=0;i<failures.size();++i) { if(i)std::cout<<','; std::cout<<cdf::test::Json(failures[i]); } std::cout<<"]}\n";
    if(module) FreeLibrary(module);
    return failures.empty()?0:1;
}
