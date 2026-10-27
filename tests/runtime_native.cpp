#include <Windows.h>
#include <Unknwn.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.System.UserProfile.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Globalization.DateTimeFormatting.h>
#include <winrt/Windows.Globalization.NumberFormatting.h>
#include "time_zone_status.h"
#include "locale_status.h"
#include "runtime_status.h"
#include "runtime_test.h"
#include <sstream>
#include <string>
#include <vector>
#include <cstring>
#include <thread>
#include <atomic>
#include <stdexcept>
#include <winternl.h>
#if !defined(CDF_RUNTIME_ADDON)
extern "C" __declspec(dllimport) const CdfRuntimeStage* CdfRuntimeEarlyStage();
namespace { CdfRuntimeStage tls_stage{}; }
void NTAPI RuntimeTls(PVOID,DWORD reason,PVOID){if(reason==DLL_PROCESS_ATTACH)tls_stage=CdfReadRuntimeStage();}
#pragma section(".CRT$XLB",read)
extern "C" __declspec(allocate(".CRT$XLB")) const PIMAGE_TLS_CALLBACK runtime_tls=RuntimeTls;
#pragma comment(linker,"/INCLUDE:_tls_used")
#pragma comment(linker,"/INCLUDE:runtime_tls")
#endif

std::string Utf8(const WCHAR* value) {
    const int n=WideCharToMultiByte(CP_UTF8,0,value,-1,nullptr,0,nullptr,nullptr);
    std::string s(n?static_cast<size_t>(n):1,0);
    if(n) WideCharToMultiByte(CP_UTF8,0,value,-1,s.data(),n,nullptr,nullptr);
    s.pop_back();return s;
}
void Quoted(std::ostringstream& s,const std::string& value) {
    s<<'"';for(unsigned char c:value){if(c=='"'||c=='\\')s<<'\\';if(c>=32)s<<c;}s<<'"';
}
ULONGLONG Ticks(const FILETIME& f){return (static_cast<ULONGLONG>(f.dwHighDateTime)<<32)|f.dwLowDateTime;}
std::string Contracts(){
    unsigned checks=0,failures=0;
    std::string failure_lines;
    auto record=[&](bool condition,int line){++checks;if(!condition){if(failures++)failure_lines+=',';failure_lines+=std::to_string(line);}};
#define check(condition) record((condition),__LINE__)
    struct Times {LARGE_INTEGER creation,exit,kernel,user;};Times native{};ULONG returned=0;
    const auto query=reinterpret_cast<decltype(&NtQueryInformationProcess)>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"NtQueryInformationProcess"));
    FILETIME c{},e{},k{},u{};SetLastError(0x4321);const BOOL ok=GetProcessTimes(GetCurrentProcess(),&c,&e,&k,&u);
    check(ok&&GetLastError()==0x4321);check(query(GetCurrentProcess(),static_cast<PROCESSINFOCLASS>(4),&native,sizeof(native),&returned)>=0&&returned==sizeof(native));
    const ULONGLONG win32_creation=Ticks(c),win32_exit=Ticks(e),native_creation=native.creation.QuadPart,native_exit=native.exit.QuadPart;
    check(win32_creation==static_cast<ULONGLONG>(native.creation.QuadPart));check(win32_exit==0&&native.exit.QuadPart==0);
    check(Ticks(k)<=static_cast<ULONGLONG>(native.kernel.QuadPart)&&Ticks(u)<=static_cast<ULONGLONG>(native.user.QuadPart));
    FILETIME alias{};check(GetProcessTimes(GetCurrentProcess(),&alias,&alias,&alias,&alias)!=FALSE);check(Ticks(alias)<1000000000000ULL);
    check(!GetProcessTimes(reinterpret_cast<HANDLE>(0x123456),&c,&e,&k,&u)&&GetLastError()==ERROR_INVALID_HANDLE);
    {
        HMODULE self=nullptr;WCHAR path[1024]{};
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,reinterpret_cast<LPCWSTR>(&Contracts),&self);
        GetModuleFileNameW(self,path,1024);std::wstring executable(path);const auto slash=executable.find_last_of(L"\\/");
        executable=executable.substr(0,slash+1)+L"CdfRuntimeProbe64.exe";
        std::wstring command=L"\""+executable+L"\" --exit-child";STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION child{};
        FILETIME before{},after{};GetSystemTimePreciseAsFileTime(&before);
        const BOOL started=CreateProcessW(executable.c_str(),command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&child);check(started!=FALSE);
        if(started){
            const DWORD wait=WaitForSingleObject(child.hProcess,10000);if(wait!=WAIT_OBJECT_0)TerminateProcess(child.hProcess,99);check(wait==WAIT_OBJECT_0);
            check(GetProcessTimes(child.hProcess,&c,&e,&k,&u)!=FALSE);check(query(child.hProcess,static_cast<PROCESSINFOCLASS>(4),&native,sizeof(native),&returned)>=0);
            GetSystemTimePreciseAsFileTime(&after);
            // Schema 1/2 and runtime.enabled=false intentionally keep process
            // timestamps real while the original Windows wall-clock group may
            // still be offset. Compare against the appropriate clock model.
            LONGLONG reference_delta=0;HMODULE provider=GetModuleHandleW(L"CdfTimeZone64.dll");
            if(!provider)provider=GetModuleHandleW(L"CdfClaudeTimeZoneTest64.dll");
            if(provider){
                auto tq=reinterpret_cast<CdfTimeZoneQuery>(GetProcAddress(provider,"CdfTimeZoneQueryStatus"));
                auto rq=reinterpret_cast<CdfRuntimeQuery>(GetProcAddress(provider,"CdfRuntimeQueryStatus"));
                CdfTimeZoneStatus time{};CdfRuntimeStatus runtime{};
                if(tq&&rq&&tq(&time,sizeof(time))==0&&rq(&runtime,sizeof(runtime))==0&&(time.state&8)&&!(runtime.state&CdfRuntimeTime))reference_delta=time.utc_offset_seconds*10000000;
            }
            check(Ticks(c)==static_cast<ULONGLONG>(native.creation.QuadPart)&&Ticks(e)==static_cast<ULONGLONG>(native.exit.QuadPart));
            check(static_cast<LONGLONG>(Ticks(c))>=static_cast<LONGLONG>(Ticks(before))-reference_delta&&Ticks(e)>=Ticks(c)&&static_cast<LONGLONG>(Ticks(e))<=static_cast<LONGLONG>(Ticks(after))-reference_delta&&Ticks(e)!=0);
            check(Ticks(k)<1000000000000ULL&&Ticks(u)<1000000000000ULL);
            CloseHandle(child.hThread);CloseHandle(child.hProcess);
        }
    }
    WCHAR geo[16]{};const int length=GetUserDefaultGeoName(geo,16);check(length>0&&length==GetUserDefaultGeoName(nullptr,0));
    WCHAR exact[16]{};check(GetUserDefaultGeoName(exact,length)==length&&std::wcscmp(geo,exact)==0);
    SetLastError(0x9876);check(GetUserDefaultGeoName(exact,1)==0&&GetLastError()==ERROR_INSUFFICIENT_BUFFER);
    try{
        using namespace winrt::Windows::System::UserProfile;using namespace winrt::Windows::Foundation::Collections;
        auto list=GlobalizationPreferences::Languages();check(list.Size()>0);auto iterable=list.as<IIterable<winrt::hstring>>();
        const auto a=list.as<IUnknown>(),b=iterable.as<IUnknown>();check(a.get()==b.get());
        const ULONG refs=a->AddRef();check(a->Release()+1==refs);
        auto iterator=iterable.First();unsigned n=0;while(iterator.HasCurrent()){check(iterator.Current()==list.GetAt(n));++n;iterator.MoveNext();}check(n==list.Size());
        std::vector<winrt::hstring> many(list.Size()+2);check(list.GetMany(0,many)==list.Size());
        for(unsigned i=0;i<list.Size();i++)check(many[i]==list.GetAt(i));
        check(list.GetMany(list.Size(),many)==0);uint32_t found=0;check(list.IndexOf(list.GetAt(0),found)&&found==0);
        check(!list.IndexOf(L"x-cdf-nonexistent",found));
        try{list.GetAt(list.Size());check(false);}catch(const winrt::hresult_error& ex){check(ex.code()==E_BOUNDS);}
        try{list.GetMany(list.Size()+1,many);check(false);}catch(const winrt::hresult_error& ex){check(ex.code()==E_BOUNDS);}
        check(winrt::Windows::Globalization::GeographicRegion(L"JP").CodeTwoLetter()==L"JP");
        try{
            const auto current=winrt::Windows::System::User::GetDefault();
            if(current)check(GlobalizationPreferences::GetForUser(current).Languages().GetAt(0)==list.GetAt(0));
        }catch(const winrt::hresult_error& ex){check(ex.code()==E_NOINTERFACE||ex.code()==E_NOTIMPL);}
        // Exercise the same activation ABI through normal export lookup, the
        // Native resolver and the WinRT API Set, rather than only C++/WinRT's IAT.
        using GetFactory=HRESULT(WINAPI*)(void*,const winrt::guid&,void**);
        using Activate=HRESULT(WINAPI*)(void*,void**);
        using Resolver=NTSTATUS(NTAPI*)(PVOID,ANSI_STRING*,ULONG,PVOID*);
        const auto resolver=reinterpret_cast<Resolver>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"LdrGetProcedureAddress"));
        const auto api_set=LoadLibraryW(L"api-ms-win-core-winrt-l1-1-0.dll");check(api_set!=nullptr&&resolver!=nullptr);
        const auto expected_region=winrt::Windows::Globalization::GeographicRegion().CodeTwoLetter();
        for(const auto module:{GetModuleHandleW(L"combase.dll"),api_set}){
            if(!module)continue;
            PVOID native_address=nullptr;char symbol[]="RoGetActivationFactory";
            ANSI_STRING name{sizeof(symbol)-1,sizeof(symbol),symbol};
            check(resolver&&resolver(module,&name,0,&native_address)>=0&&native_address);
            for(const auto get:{reinterpret_cast<GetFactory>(GetProcAddress(module,symbol)),reinterpret_cast<GetFactory>(native_address)}){
                check(get!=nullptr);if(!get)continue;
                winrt::hstring class_name(L"Windows.System.UserProfile.GlobalizationPreferences");void* raw=nullptr;
                using Statics=winrt::Windows::System::UserProfile::IGlobalizationPreferencesStatics;
                const auto hr=get(winrt::get_abi(class_name),winrt::guid_of<Statics>(),&raw);check(SUCCEEDED(hr)&&raw);
                if(SUCCEEDED(hr)&&raw){Statics factory{raw,winrt::take_ownership_from_abi};check(factory.Languages().GetAt(0)==list.GetAt(0));}
            }
            const auto activate=reinterpret_cast<Activate>(GetProcAddress(module,"RoActivateInstance"));
            check(activate!=nullptr);
            if(activate){winrt::hstring class_name(L"Windows.Globalization.GeographicRegion");void* raw=nullptr;
                const auto hr=activate(winrt::get_abi(class_name),&raw);check(SUCCEEDED(hr)&&raw);
                if(SUCCEEDED(hr)&&raw){winrt::Windows::Globalization::GeographicRegion region{raw,winrt::take_ownership_from_abi};check(region.CodeTwoLetter()==expected_region);}
            }
        }
        if(api_set)FreeLibrary(api_set);
        using namespace winrt::Windows::Globalization::DateTimeFormatting;
        auto date=DateTimeFormatter::ShortDate();auto second=date.as<winrt::Windows::Globalization::DateTimeFormatting::IDateTimeFormatter2>();
        check(date.as<IUnknown>().get()==second.as<IUnknown>().get());
        check(!date.Format(winrt::clock::from_time_t(1705320000)).empty());
        using namespace winrt::Windows::Globalization::NumberFormatting;
        DecimalFormatter number;number.IsGrouped(true);number.FractionDigits(3);number.NumeralSystem(L"Latn");
        check(number.FractionDigits()==3&&number.IsGrouped()&&number.NumeralSystem()==L"Latn");check(!number.Format(1234.5).empty());
        auto parsed=number.ParseDouble(number.Format(1234.5));check(parsed&&parsed.Value()==1234.5);
        SignificantDigitsNumberRounder rounder;rounder.SignificantDigits(3);number.NumberRounder(rounder);check(number.NumberRounder()!=nullptr);
        CurrencyFormatter currency(L"EUR");check(currency.Currency()==L"EUR");currency.ApplyRoundingForCurrency(RoundingAlgorithm::RoundHalfUp);check(!currency.Format(123.456).empty());
        bool sta_ok=false;const auto expected=list.GetAt(0);
        std::thread sta([&](){try{winrt::init_apartment(winrt::apartment_type::single_threaded);sta_ok=GlobalizationPreferences::Languages().GetAt(0)==expected;winrt::uninit_apartment();}catch(...){}});sta.join();check(sta_ok);
        std::vector<std::thread> threads;std::atomic<unsigned> successes{0};
        for(unsigned i=0;i<8;i++)threads.emplace_back([&](){try{winrt::init_apartment();for(unsigned j=0;j<20;j++)if(GlobalizationPreferences::Languages().GetAt(0)!=expected)throw std::runtime_error("apartment language mismatch");++successes;winrt::uninit_apartment();}catch(...){}});
        for(auto& t:threads)t.join();check(successes==8);
    }catch(...){check(false);}
    std::ostringstream s;s<<"{\"checks\":"<<checks<<",\"failures\":"<<failures<<",\"failureLines\":["<<failure_lines<<"],\"win32Creation\":"<<win32_creation<<",\"nativeCreation\":"<<native_creation<<",\"win32Exit\":"<<win32_exit<<",\"nativeExit\":"<<native_exit<<",\"nativeQuery\":"<<reinterpret_cast<ULONG_PTR>(query)<<",\"passed\":"<<(failures==0?"true":"false")<<"}";return s.str();
#undef check
}
std::string WinrtOracles(){
    using namespace winrt::Windows::Globalization::DateTimeFormatting;
    using namespace winrt::Windows::Globalization::NumberFormatting;
    struct Case {const wchar_t* locale;const wchar_t* region;const wchar_t* zone;const wchar_t* windows;};
    const Case cases[]={{L"en-US",L"US",L"America/Los_Angeles",L"Pacific Standard Time"},{L"de-DE",L"DE",L"America/New_York",L"Eastern Standard Time"},
        {L"fr-FR",L"JP",L"Etc/UTC",L"UTC"},{L"ja-JP",L"IN",L"Asia/Calcutta",L"India Standard Time"},
        {L"en-GB",L"GB",L"America/Los_Angeles",L"Pacific Standard Time"},{L"zh-CN",L"US",L"America/New_York",L"Eastern Standard Time"}};
    std::ostringstream s;s<<'[';bool first=true;
    for(const auto& c:cases){
        if(!first)s<<',';first=false;s<<"{\"locale\":";Quoted(s,Utf8(c.locale));
        s<<",\"region\":";Quoted(s,Utf8(c.region));
        const std::vector<winrt::hstring> languages={c.locale};
        WCHAR clock[8]{};GetLocaleInfoEx(c.locale,LOCALE_ITIME|LOCALE_NOUSEROVERRIDE,clock,8);
        DateTimeFormatter formatter(L"longdate longtime",languages,c.region,L"GregorianCalendar",clock[0]==L'0'?L"12HourClock":L"24HourClock");
        s<<",\"dateLocale\":";Quoted(s,winrt::to_string(formatter.ResolvedLanguage()));
        const auto instant=winrt::clock::from_time_t(1705320000);
        s<<",\"date\":";Quoted(s,winrt::to_string(formatter.Format(instant,c.zone)));
        s<<",\"tokyo\":";Quoted(s,winrt::to_string(formatter.Format(instant,L"Asia/Tokyo")));
        // WinRT uses current-user date overrides when an explicit language is
        // also the host language. The default virtual environment deliberately
        // uses standard NLS data, so keep a separate NOUSEROVERRIDE oracle.
        auto standard=[&](const wchar_t* windows){
            DYNAMIC_TIME_ZONE_INFORMATION zone{};bool found=false;
            for(DWORD i=0;EnumDynamicTimeZoneInformation(i,&zone)==ERROR_SUCCESS;i++)if(std::wcscmp(zone.TimeZoneKeyName,windows)==0){found=true;break;}
            if(!found)throw std::runtime_error("Oracle time zone unavailable");
            SYSTEMTIME utc{2024,1,1,15,12,0,0,0},local{};WCHAR date[256]{},time[256]{};
            if(!SystemTimeToTzSpecificLocalTimeEx(&zone,&utc,&local)||!GetDateFormatEx(c.locale,DATE_LONGDATE|LOCALE_NOUSEROVERRIDE,&local,nullptr,date,256,nullptr)||!GetTimeFormatEx(c.locale,LOCALE_NOUSEROVERRIDE,&local,nullptr,time,256))throw std::runtime_error("NLS oracle failed");
            return Utf8(date)+" "+Utf8(time);
        };
        s<<",\"standardDate\":";Quoted(s,standard(c.windows));s<<",\"standardTokyo\":";Quoted(s,standard(L"Tokyo Standard Time"));
        DecimalFormatter decimal(languages,c.region);PercentFormatter percent(languages,c.region);
        PermilleFormatter permille(languages,c.region);CurrencyFormatter currency(L"JPY",languages,c.region);
        s<<",\"numberLocale\":";Quoted(s,winrt::to_string(decimal.ResolvedLanguage()));
        s<<",\"numbers\":[";Quoted(s,winrt::to_string(decimal.Format(123456.78)));s<<',';
        Quoted(s,winrt::to_string(percent.Format(0.1234)));s<<',';Quoted(s,winrt::to_string(permille.Format(0.1234)));s<<',';
        Quoted(s,winrt::to_string(currency.Format(123456.78)));s<<"]}";
    }
    s<<']';return s.str();
}
std::string Snapshot(){
    std::ostringstream s;s<<"{";
#if !defined(CDF_RUNTIME_ADDON)
    const auto* early=CdfRuntimeEarlyStage();
    s<<"\"early\":{\"loaded\":"<<early->loaded<<",\"state\":"<<early->state<<",\"error\":"<<early->error<<",\"geo\":";Quoted(s,Utf8(early->geo));s<<",\"creation\":"<<early->creation<<"},";
    s<<"\"tls\":{\"loaded\":"<<tls_stage.loaded<<",\"state\":"<<tls_stage.state<<",\"error\":"<<tls_stage.error<<",\"geo\":";Quoted(s,Utf8(tls_stage.geo));s<<",\"creation\":"<<tls_stage.creation<<"},";
#endif
    FILETIME c{},e{},k{},u{};SetLastError(0x1234);BOOL ok=GetProcessTimes(GetCurrentProcess(),&c,&e,&k,&u);DWORD last=GetLastError();
    s<<"\"processTimes\":{\"ok\":"<<(ok?"true":"false")<<",\"lastError\":"<<last<<",\"creation\":"<<Ticks(c)<<",\"exit\":"<<Ticks(e)<<",\"kernel\":"<<Ticks(k)<<",\"user\":"<<Ticks(u)<<"}";
    WCHAR geo[100]{},iso[100]{};int n=GetUserDefaultGeoName(geo,100);GEOID id=GetUserGeoID(GEOCLASS_NATION);GetGeoInfoW(122,GEO_ISO2,iso,100,0);
    s<<",\"geoName\":";Quoted(s,n?Utf8(geo):"");s<<",\"geoId\":"<<id<<",\"explicitJapan\":";Quoted(s,Utf8(iso));
    int winrt_step=0;std::ostringstream w;
    try{
        try{winrt::init_apartment(winrt::apartment_type::multi_threaded);}catch(const winrt::hresult_error& ex){if(ex.code()!=RPC_E_CHANGED_MODE)throw;}
        winrt_step=1;using P=winrt::Windows::System::UserProfile::GlobalizationPreferences;
        w<<",\"winrtLanguages\":[";bool first=true;for(const auto& x:P::Languages()){if(!first)w<<',';first=false;Quoted(w,winrt::to_string(x));}
        w<<"],\"winrtHomeRegion\":";Quoted(w,winrt::to_string(P::HomeGeographicRegion()));
        winrt_step=2;using namespace winrt::Windows::Globalization;
        w<<",\"winrtGeo\":";Quoted(w,winrt::to_string(GeographicRegion().CodeTwoLetter()));
        winrt_step=3;w<<",\"winrtAppLanguages\":[";first=true;for(const auto& x:ApplicationLanguages::Languages()){if(!first)w<<',';first=false;Quoted(w,winrt::to_string(x));}w<<"]";
        using namespace DateTimeFormatting;using namespace NumberFormatting;
        winrt_step=4;DateTimeFormatter date(L"longdate longtime");
        w<<",\"winrtFormatLocale\":";Quoted(w,winrt::to_string(date.ResolvedLanguage()));
        w<<",\"winrtFormatRegion\":";Quoted(w,winrt::to_string(date.GeographicRegion()));
        const auto instant=winrt::clock::from_time_t(1705320000);
        w<<",\"winrtDate\":";Quoted(w,winrt::to_string(date.Format(instant)));
        const auto tokyo=date.Format(instant,L"Asia/Tokyo");
        w<<",\"winrtDateExplicitTokyo\":";Quoted(w,winrt::to_string(tokyo));
        w<<",\"winrtNumbers\":[";
        winrt_step=5;DecimalFormatter decimal;PercentFormatter percent;PermilleFormatter permille;CurrencyFormatter currency(L"JPY");
        Quoted(w,winrt::to_string(decimal.Format(123456.78)));w<<',';Quoted(w,winrt::to_string(percent.Format(0.1234)));w<<',';Quoted(w,winrt::to_string(permille.Format(0.1234)));w<<',';Quoted(w,winrt::to_string(currency.Format(123456.78)));w<<"]";
        w<<",\"winrtNumberLocale\":";Quoted(w,winrt::to_string(decimal.ResolvedLanguage()));
        w<<",\"winrtOracles\":"<<WinrtOracles();
        s<<w.str();
    }catch(const winrt::hresult_error& ex){s<<",\"winrtError\":"<<static_cast<LONG>(ex.code())<<",\"winrtStep\":"<<winrt_step;}
    HMODULE provider=GetModuleHandleW(L"CdfTimeZone64.dll");if(!provider)provider=GetModuleHandleW(L"CdfClaudeTimeZone64.dll");
    if(!provider)provider=GetModuleHandleW(L"CdfClaudeTimeZoneTest64.dll");
    if(provider){CdfTimeZoneStatus t{};CdfLocaleStatus l{};auto tq=reinterpret_cast<CdfTimeZoneQuery>(GetProcAddress(provider,"CdfTimeZoneQueryStatus"));auto lq=reinterpret_cast<CdfLocaleQuery>(GetProcAddress(provider,"CdfLocaleQueryStatus"));if(tq)tq(&t,sizeof(t));if(lq)lq(&l,sizeof(l));s<<",\"provider\":{\"timeState\":"<<t.state<<",\"localeState\":"<<l.state<<",\"timeCalls\":[";for(unsigned i=0;i<CdfTimeHookCount;i++){if(i)s<<',';s<<t.calls[i];}s<<"],\"localeCalls\":[";for(unsigned i=0;i<CdfLocaleHookCount;i++){if(i)s<<',';s<<l.calls[i];}s<<"]}";}
    if(provider){auto query=reinterpret_cast<CdfRuntimeQuery>(GetProcAddress(provider,"CdfRuntimeQueryStatus"));CdfRuntimeStatus r{};if(query&&query(&r,sizeof(r))==0){s<<",\"runtime\":{\"version\":"<<r.version<<",\"state\":"<<r.state<<",\"error\":"<<r.error_code<<",\"stage\":"<<r.error_stage<<",\"patchCount\":"<<r.patch_count<<",\"compatibility\":"<<r.compatibility<<",\"processCalls\":"<<r.process_time_calls<<",\"nativeProcessCalls\":"<<r.native_process_time_calls<<",\"activations\":"<<r.activation_calls<<",\"languageCalls\":"<<r.language_calls<<",\"formatCalls\":"<<r.format_calls<<",\"captured\":"<<r.captured_contexts<<",\"captureFailures\":"<<r.capture_failures<<",\"captureTruncated\":"<<r.capture_truncated<<"}";}}
    s<<",\"contracts\":"<<Contracts()<<"}";return s.str();
}
#ifdef CDF_RUNTIME_ADDON
using napi_env=void*;using napi_value=void*;using napi_callback_info=void*;
using CreateString=int(__cdecl*)(napi_env,const char*,size_t,napi_value*);
using CreateFunction=int(__cdecl*)(napi_env,const char*,size_t,napi_value(__cdecl*)(napi_env,napi_callback_info),void*,napi_value*);
using SetProperty=int(__cdecl*)(napi_env,napi_value,const char*,napi_value);
napi_value __cdecl Sample(napi_env env,napi_callback_info){auto f=reinterpret_cast<CreateString>(GetProcAddress(GetModuleHandleW(nullptr),"napi_create_string_utf8"));if(!f)return nullptr;napi_value value=nullptr;const auto text=Snapshot();f(env,text.c_str(),text.size(),&value);return value;}
extern "C" __declspec(dllexport) napi_value __cdecl napi_register_module_v1(napi_env env,napi_value exports){
    auto create=reinterpret_cast<CreateFunction>(GetProcAddress(GetModuleHandleW(nullptr),"napi_create_function"));auto set=reinterpret_cast<SetProperty>(GetProcAddress(GetModuleHandleW(nullptr),"napi_set_named_property"));if(!create||!set)return nullptr;napi_value fn=nullptr;create(env,"sample",6,Sample,nullptr,&fn);set(env,exports,"sample",fn);return exports;
}
#else
#include <iostream>
int main(int argc,char** argv){if(argc>1&&std::strcmp(argv[1],"--exit-child")==0)return 0;std::cout<<Snapshot()<<std::endl;if(argc>1&&std::strcmp(argv[1],"--hold")==0)Sleep(15000);}
#endif
