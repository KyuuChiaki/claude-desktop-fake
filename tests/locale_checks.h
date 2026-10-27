// Included inside the probe's anonymous namespace after Check and Info.
std::string ucrt_default;
std::vector<NTSTATUS> native_contracts;
std::vector<ULONGLONG> name_contracts;
std::string NlsReference(const std::wstring& region) {
    std::ostringstream out; out<<"{\"locale\":"<<cdf::test::Json(region)<<",\"lcid\":"<<LocaleNameToLCID(region.c_str(),0)<<",\"data\":[";
    bool first=true;
    for(const LCTYPE type:{LOCALE_SNAME,LOCALE_SSHORTDATE,LOCALE_SLONGDATE,LOCALE_STIMEFORMAT,LOCALE_SDECIMAL,LOCALE_STHOUSAND,
        LOCALE_SCURRENCY,LOCALE_SMONDECIMALSEP,LOCALE_SMONTHOUSANDSEP,LOCALE_SDAYNAME1,LOCALE_SMONTHNAME1}) {
        if(!first) out<<',';first=false;out<<cdf::test::Json(Info(region.c_str(),type));
    }
    SYSTEMTIME fixed{2024,2,4,29,15,6,7,0};WCHAR value[256]{};out<<"],\"formats\":[";
    GetDateFormatEx(region.c_str(),LOCALE_NOUSEROVERRIDE,&fixed,nullptr,value,256,nullptr);out<<cdf::test::Json(std::wstring(value));
    GetTimeFormatEx(region.c_str(),LOCALE_NOUSEROVERRIDE,&fixed,nullptr,value,256);out<<','<<cdf::test::Json(std::wstring(value));
    GetNumberFormatEx(region.c_str(),LOCALE_NOUSEROVERRIDE,L"1234567.89",nullptr,value,256);out<<','<<cdf::test::Json(std::wstring(value));
    GetCurrencyFormatEx(region.c_str(),LOCALE_NOUSEROVERRIDE,L"1234567.89",nullptr,value,256);out<<','<<cdf::test::Json(std::wstring(value));
    out<<"]}";return out.str();
}
void QueryContracts() {
    const HMODULE ntdll=GetModuleHandleW(L"ntdll.dll");
    for(unsigned api=0;api<3;++api) for(unsigned dynamic=0;dynamic<2;++dynamic) for(unsigned mode=0;mode<3;++mode) {
        alignas(8) BYTE buffer[32]; std::memset(buffer,0x5a,sizeof(buffer));
        BYTE* target=mode==2 ? nullptr : buffer+8+mode;
        SetLastError(0x7654);
        NTSTATUS result=0;
        if(api==0) {
            const auto fn=dynamic ? cdf::test::Resolve<decltype(&NtQueryDefaultLocale)>(ntdll,"ZwQueryDefaultLocale") : NtQueryDefaultLocale;
            result=fn(TRUE,reinterpret_cast<PLCID>(target));
        } else {
            const char* name=api==1 ? "NtQueryDefaultUILanguage" : "ZwQueryInstallUILanguage";
            const auto fn=dynamic ? cdf::test::Resolve<decltype(&NtQueryDefaultUILanguage)>(ntdll,name) : api==1 ? NtQueryDefaultUILanguage : NtQueryInstallUILanguage;
            result=fn(reinterpret_cast<LANGID*>(target));
        }
        native_contracts.push_back(result);
        Check(GetLastError()==0x7654,"Native query preserves LastError");
        bool boundary=true;
        for(unsigned i=0;i<sizeof(buffer);++i) if ((!target || i<8+mode || i>=8+mode+(api==0 ? 4 : 2)) && buffer[i]!=0x5a) boundary=false;
        Check(boundary,"Native query canary");
    }
    for(const auto getter:{GetUserDefaultLocaleName,GetSystemDefaultLocaleName}) for(const int capacity:{-1,0,1,2,5,6,85,32768}) {
        WCHAR text[85];std::fill_n(text,85,WCHAR(0x5555));SetLastError(0x1234);
        const int result=getter(text,capacity);const DWORD error=GetLastError();ULONG changed=0;
        for(const WCHAR c:text) if(c!=WCHAR(0x5555)) ++changed;
        name_contracts.push_back(static_cast<ULONGLONG>(result));name_contracts.push_back(error);name_contracts.push_back(changed);
    }
}
void RegionData(const std::wstring& region) {
    const LCID id=LocaleNameToLCID(region.c_str(),0);
    const LCTYPE types[]={LOCALE_SNAME,LOCALE_SSHORTDATE,LOCALE_SLONGDATE,LOCALE_STIMEFORMAT,LOCALE_SSHORTTIME,LOCALE_SDATE,LOCALE_STIME,
        LOCALE_SDECIMAL,LOCALE_STHOUSAND,LOCALE_SCURRENCY,LOCALE_SMONDECIMALSEP,LOCALE_SMONTHOUSANDSEP,LOCALE_SISO639LANGNAME,
        LOCALE_SISO3166CTRYNAME,LOCALE_SDAYNAME1,LOCALE_SMONTHNAME1,LOCALE_S1159,LOCALE_S2359,LOCALE_IDIGITS|LOCALE_RETURN_NUMBER,
        LOCALE_IMEASURE|LOCALE_RETURN_NUMBER,LOCALE_IFIRSTDAYOFWEEK|LOCALE_RETURN_NUMBER,0xffff};
    for(const LCTYPE type:types) for(const int capacity:{0,1,2,5,6,32,128}) {
        WCHAR a[130],b[130]; std::fill_n(a,130,WCHAR(0x5555)); std::fill_n(b,130,WCHAR(0x5555));
        SetLastError(0x5678); const int expected=GetLocaleInfoEx(region.c_str(),type|LOCALE_NOUSEROVERRIDE,a,capacity); const DWORD last=GetLastError();
        SetLastError(0x5678); const int actual=GetLocaleInfoEx(nullptr,type,b,capacity);
        Check(expected==actual && last==GetLastError() && std::memcmp(a,b,sizeof(a))==0,"GetLocaleInfoEx contract "+std::to_string(type)+"/"+std::to_string(capacity));
        std::fill_n(a,130,WCHAR(0x5555)); std::fill_n(b,130,WCHAR(0x5555));
        SetLastError(0x5678); const int ew=GetLocaleInfoW(id,type|LOCALE_NOUSEROVERRIDE,a,capacity); const DWORD lw=GetLastError();
        SetLastError(0x5678); const int aw=GetLocaleInfoW(LOCALE_SYSTEM_DEFAULT,type,b,capacity);
        Check(ew==aw && lw==GetLastError() && std::memcmp(a,b,sizeof(a))==0,"GetLocaleInfoW contract");
        char x[130],y[130]; std::memset(x,0x55,sizeof(x)); std::memset(y,0x55,sizeof(y));
        SetLastError(0x5678); const int ea=GetLocaleInfoA(id,type|LOCALE_NOUSEROVERRIDE,x,capacity); const DWORD la=GetLastError();
        SetLastError(0x5678); const int aa=GetLocaleInfoA(LOCALE_USER_DEFAULT,type,y,capacity);
        Check(ea==aa && la==GetLastError() && std::memcmp(x,y,sizeof(x))==0,"GetLocaleInfoA contract");
    }
    Check(GetUserDefaultLangID()==LANGIDFROMLCID(id) && GetSystemDefaultLangID()==LANGIDFROMLCID(id),"regional language IDs");
    Check(ConvertDefaultLocale(LOCALE_USER_DEFAULT)==id && LocaleNameToLCID(nullptr,0)==id,"default LCID resolution");
    WCHAR name[85]{}; Check(LCIDToLocaleName(LOCALE_SYSTEM_DEFAULT,name,85,0)>0 && region==name,"default LCID name resolution");
    Check(ResolveLocaleName(nullptr,name,85)>0 && region==name,"default name resolution");
    Check(LocaleNameToLCID(L"",0)==LOCALE_INVARIANT && LocaleNameToLCID(L"ja-JP",0)==0x411,"explicit/invariant resolution");
    for(const WCHAR* explicit_name:{L"ja-JP",L"de-DE"}) {
        const LCID explicit_id=LocaleNameToLCID(explicit_name,0);
        WCHAR explicit_text[128]{}; GetLocaleInfoEx(explicit_name,LOCALE_SNAME,explicit_text,128);
        Check(std::wstring(explicit_name)==explicit_text,"explicit locale query");
        Check(ConvertDefaultLocale(explicit_id)==explicit_id,"explicit LCID conversion");
    }
    for(int capacity:{0,1,2,5,6,85}) {
        WCHAR expected[85],actual[85]; std::fill_n(expected,85,WCHAR(0x5555)); std::fill_n(actual,85,WCHAR(0x5555));
        const int name_length=static_cast<int>(region.size());
        const int user_result=capacity>name_length ? name_length+1 : 0;
        const DWORD error=user_result ? 0x1234 : ERROR_CANNOT_COPY;
        if(capacity>0) {const int copied=user_result ? name_length : capacity-1;std::copy_n(region.c_str(),copied,expected);expected[copied]=0;}
        SetLastError(0x1234); const int got=GetUserDefaultLocaleName(actual,capacity);
        Check(got==user_result && GetLastError()==error && std::memcmp(actual,expected,sizeof(actual))==0,"user name length contract");
        std::fill_n(expected,85,WCHAR(0x5555)); std::fill_n(actual,85,WCHAR(0x5555));
        const int er=capacity>name_length ? name_length+1 : 0;
        const DWORD el=er ? 0x1234 : ERROR_INSUFFICIENT_BUFFER;
        if(capacity>=name_length && capacity>0) {
            const int copied=er ? name_length : capacity-1;
            std::copy_n(region.c_str(),copied,expected);expected[copied]=0;
        }
        SetLastError(0x1234); const int ar=GetSystemDefaultLocaleName(actual,capacity);
        Check(er==ar && el==GetLastError() && std::memcmp(actual,expected,sizeof(actual))==0,"system name length contract");
    }
    WCHAR large[85]{};
    Check(GetUserDefaultLocaleName(large,32768)>0 && region==large,"user name large advertised capacity");
    Check(GetSystemDefaultLocaleName(large,32768)>0 && region==large,"system name large advertised capacity");
}
void FormatData(const std::wstring& region) {
    const LCID id=LocaleNameToLCID(region.c_str(),0); SYSTEMTIME fixed{2024,2,4,29,15,6,7,0};
    WCHAR expected[256]{},actual[256]{};
    Check(GetDateFormatEx(region.c_str(),LOCALE_NOUSEROVERRIDE,&fixed,nullptr,expected,256,nullptr)>0 && GetDateFormatEx(nullptr,0,&fixed,nullptr,actual,256,nullptr)>0 && std::wstring(expected)==actual,"date Ex");
    Check(GetTimeFormatEx(region.c_str(),LOCALE_NOUSEROVERRIDE,&fixed,nullptr,expected,256)>0 && GetTimeFormatEx(nullptr,0,&fixed,nullptr,actual,256)>0 && std::wstring(expected)==actual,"time Ex");
    Check(GetNumberFormatEx(region.c_str(),LOCALE_NOUSEROVERRIDE,L"1234567.89",nullptr,expected,256)>0 && GetNumberFormatEx(nullptr,0,L"1234567.89",nullptr,actual,256)>0 && std::wstring(expected)==actual,"number Ex");
    Check(GetCurrencyFormatEx(region.c_str(),LOCALE_NOUSEROVERRIDE,L"1234567.89",nullptr,expected,256)>0 && GetCurrencyFormatEx(nullptr,0,L"1234567.89",nullptr,actual,256)>0 && std::wstring(expected)==actual,"currency Ex");
    Check(GetDateFormatW(id,LOCALE_NOUSEROVERRIDE,&fixed,nullptr,expected,256)>0 && GetDateFormatW(LOCALE_SYSTEM_DEFAULT,0,&fixed,nullptr,actual,256)>0 && std::wstring(expected)==actual,"date W");
    Check(GetTimeFormatW(id,LOCALE_NOUSEROVERRIDE,&fixed,nullptr,expected,256)>0 && GetTimeFormatW(LOCALE_USER_DEFAULT,0,&fixed,nullptr,actual,256)>0 && std::wstring(expected)==actual,"time W");
    Check(GetNumberFormatW(id,LOCALE_NOUSEROVERRIDE,L"1234567.89",nullptr,expected,256)>0 && GetNumberFormatW(LOCALE_USER_DEFAULT,0,L"1234567.89",nullptr,actual,256)>0 && std::wstring(expected)==actual,"number W");
    Check(GetCurrencyFormatW(id,LOCALE_NOUSEROVERRIDE,L"1234567.89",nullptr,expected,256)>0 && GetCurrencyFormatW(LOCALE_USER_DEFAULT,0,L"1234567.89",nullptr,actual,256)>0 && std::wstring(expected)==actual,"currency W");
    char a[256]{},b[256]{};
    Check(GetDateFormatA(id,LOCALE_NOUSEROVERRIDE,&fixed,nullptr,a,256)>0 && GetDateFormatA(LOCALE_USER_DEFAULT,0,&fixed,nullptr,b,256)>0 && std::string(a)==b,"date A");
    Check(GetTimeFormatA(id,LOCALE_NOUSEROVERRIDE,&fixed,nullptr,a,256)>0 && GetTimeFormatA(LOCALE_SYSTEM_DEFAULT,0,&fixed,nullptr,b,256)>0 && std::string(a)==b,"time A");
    Check(GetNumberFormatA(id,LOCALE_NOUSEROVERRIDE,"1234567.89",nullptr,a,256)>0 && GetNumberFormatA(LOCALE_USER_DEFAULT,0,"1234567.89",nullptr,b,256)>0 && std::string(a)==b,"number A");
    Check(GetCurrencyFormatA(id,LOCALE_NOUSEROVERRIDE,"1234567.89",nullptr,a,256)>0 && GetCurrencyFormatA(LOCALE_SYSTEM_DEFAULT,0,"1234567.89",nullptr,b,256)>0 && std::string(a)==b,"currency A");
    GetDateFormatEx(nullptr,0,&fixed,L"yyyy'/'MM'/'dd",actual,256,nullptr);
    Check(std::wstring(actual)==L"2024/02/29","explicit date pattern");
    NUMBERFMTW number{3,1,0,const_cast<LPWSTR>(L"@"),const_cast<LPWSTR>(L"_"),1};
    Check(GetNumberFormatEx(region.c_str(),0,L"123.5",&number,expected,256)>0 && GetNumberFormatEx(nullptr,0,L"123.5",&number,actual,256)>0 && std::wstring(expected)==actual,"explicit number format");
    Check(GetCalendarInfoEx(region.c_str(),CAL_GREGORIAN,nullptr,CAL_SMONTHNAME1|CAL_NOUSEROVERRIDE,expected,256,nullptr)>0 && GetCalendarInfoEx(nullptr,CAL_GREGORIAN,nullptr,CAL_SMONTHNAME1,actual,256,nullptr)>0 && std::wstring(expected)==actual,"calendar Ex");
    Check(GetCalendarInfoW(id,CAL_GREGORIAN,CAL_SMONTHNAME1|CAL_NOUSEROVERRIDE,expected,256,nullptr)>0 && GetCalendarInfoW(LOCALE_USER_DEFAULT,CAL_GREGORIAN,CAL_SMONTHNAME1,actual,256,nullptr)>0 && std::wstring(expected)==actual,"calendar W");
    Check(GetCalendarInfoA(id,CAL_GREGORIAN,CAL_SMONTHNAME1|CAL_NOUSEROVERRIDE,a,256,nullptr)>0 && GetCalendarInfoA(LOCALE_USER_DEFAULT,CAL_GREGORIAN,CAL_SMONTHNAME1,b,256,nullptr)>0 && std::string(a)==b,"calendar A");
    SYSTEMTIME before{},after{}; WCHAR current[256]{},lo[256]{},hi[256]{};
    GetLocalTime(&before); GetDateFormatEx(nullptr,0,nullptr,nullptr,current,256,nullptr); GetLocalTime(&after);
    GetDateFormatEx(region.c_str(),LOCALE_NOUSEROVERRIDE,&before,nullptr,lo,256,nullptr); GetDateFormatEx(region.c_str(),LOCALE_NOUSEROVERRIDE,&after,nullptr,hi,256,nullptr);
    Check(std::wstring(current)==lo || std::wstring(current)==hi,"format current date uses unified local clock");
    GetLocalTime(&before); GetTimeFormatEx(nullptr,0,nullptr,nullptr,current,256); GetLocalTime(&after);
    GetTimeFormatEx(region.c_str(),LOCALE_NOUSEROVERRIDE,&before,nullptr,lo,256); GetTimeFormatEx(region.c_str(),LOCALE_NOUSEROVERRIDE,&after,nullptr,hi,256);
    Check(std::wstring(current)==lo || std::wstring(current)==hi,"format current time uses unified local clock");
}
using MuiGetter=BOOL(WINAPI*)(DWORD,PULONG,PZZWSTR,PULONG);
std::wstring Preferred(MuiGetter getter,DWORD flags=MUI_LANGUAGE_NAME) {
    WCHAR text[512]{}; ULONG count=0,length=512; return getter(flags,&count,text,&length) ? text : L"!failed";
}
void MuiContracts(const std::wstring& ui) {
    const MuiGetter getters[]={GetSystemPreferredUILanguages,GetUserPreferredUILanguages,GetProcessPreferredUILanguages,GetThreadPreferredUILanguages};
    for(unsigned i=0;i<4;++i) for(const DWORD flags:std::initializer_list<DWORD>{0,MUI_LANGUAGE_NAME,MUI_LANGUAGE_ID}) {
        WCHAR text[512]{}; ULONG count=0x1234,length=0; SetLastError(0x1234);
        const BOOL sized=getters[i](flags,&count,nullptr,&length); const DWORD sized_error=GetLastError();
        Check(sized && count==1 && length>1 && sized_error==0x1234,"MUI size query api="+std::to_string(i)+" flags="+std::to_string(flags)+" count="+std::to_string(count)+" len="+std::to_string(length)+" error="+std::to_string(sized_error));
        const ULONG required=length; count=0x1234; length=0; std::fill_n(text,512,WCHAR(0x5555));
        Check(!getters[i](flags,&count,text,&length) && GetLastError()==ERROR_INSUFFICIENT_BUFFER && length==required && text[0]==WCHAR(0x5555),"MUI nonnull zero capacity is short buffer");
        count=0x1234; length=required-1; SetLastError(0x1234);
        Check(!getters[i](flags,&count,text,&length) && length==required && GetLastError()==ERROR_INSUFFICIENT_BUFFER && count==(i==3 ? 1UL : 0x1234UL),"MUI short count api="+std::to_string(i)+" count="+std::to_string(count));
        count=0; length=required; SetLastError(0x1234);
        Check(getters[i](flags,&count,text,&length) && count==1 && text[required-1]==0 && text[required-2]==0 && text[required]==WCHAR(0x5555) && GetLastError()==0x1234,"MUI exact api="+std::to_string(i)+" count="+std::to_string(count));
        if(!(flags&MUI_LANGUAGE_ID)) Check(std::wstring(text)==ui,"MUI configured name");
        else { std::wostringstream expected; expected<<std::uppercase<<std::hex<<std::setfill(L'0')<<std::setw(4)<<LANGIDFROMLCID(LocaleNameToLCID(ui.c_str(),0)); Check(expected.str()==text,"MUI configured hexadecimal LANGID"); }
        count=0x1234; length=512; Check(!getters[i](MUI_LANGUAGE_NAME|MUI_LANGUAGE_ID,&count,text,&length) && GetLastError()==ERROR_INVALID_PARAMETER && count==0x1234 && length==512,"MUI invalid flags preserve output");
        count=0x1234; length=512; Check(!getters[i](flags,&count,nullptr,&length) && GetLastError()==ERROR_INVALID_PARAMETER && length==512,"MUI null nonzero buffer");
    }
    Check(Preferred(GetThreadPreferredUILanguages,MUI_LANGUAGE_NAME|MUI_UI_FALLBACK)==ui,"configured fallback head");
}
void ExplicitState(const std::wstring& region,const std::wstring& ui) {
    const LCID id=LocaleNameToLCID(region.c_str(),0); ULONG count=0;
    Check(SetThreadLocale(0x411) && GetThreadLocale()==0x411 && GetUserDefaultLCID()==id,"thread explicit Japanese locale");
    SetLastError(0x1234); Check(!SetThreadLocale(0xdeadbeef) && GetThreadLocale()==0x411,"failed thread setter retains selection");
    Check(SetThreadLocale(LOCALE_USER_DEFAULT) && GetThreadLocale()==id,"thread locale reset");
    Check(SetThreadUILanguage(0x411)!=0 && GetThreadUILanguage()==0x411,"thread explicit Japanese UI");
    Check(SetThreadUILanguage(0)!=0 && GetThreadUILanguage()==LANGIDFROMLCID(LocaleNameToLCID(ui.c_str(),0)),"thread UI reset");
    const BOOL selected_ja=SetThreadPreferredUILanguages(MUI_LANGUAGE_NAME,L"ja-JP\0",&count); const auto actual_ja=Preferred(GetThreadPreferredUILanguages);
    Check(selected_ja && actual_ja==L"ja-JP","thread preferred Japanese actual="+cdf::test::Utf8(actual_ja));
    Check(!SetThreadPreferredUILanguages(0x80000000,L"de-DE\0",&count) && Preferred(GetThreadPreferredUILanguages)==L"ja-JP","failed preferred setter retains selection");
    Check(SetThreadPreferredUILanguages(MUI_LANGUAGE_NAME,nullptr,&count) && Preferred(GetThreadPreferredUILanguages)==ui,"thread preferred reset");
    Check(SetProcessPreferredUILanguages(MUI_LANGUAGE_NAME,L"de-DE\0",&count) && Preferred(GetProcessPreferredUILanguages)==L"de-DE" && Preferred(GetThreadPreferredUILanguages)==L"de-DE" && GetThreadUILanguage()==0x407,"process preferred override");
    Check(SetProcessPreferredUILanguages(MUI_LANGUAGE_NAME,nullptr,&count) && Preferred(GetProcessPreferredUILanguages)==ui,"process preferred reset");
    const HMODULE native=GetModuleHandleW(L"ntdll.dll"),base=GetModuleHandleW(L"kernelbase.dll");
    const auto set_thread=cdf::test::Resolve<decltype(&RtlSetThreadPreferredUILanguages)>(native,"RtlSetThreadPreferredUILanguages");
    const auto set_process=cdf::test::Resolve<decltype(&RtlSetProcessPreferredUILanguages)>(native,"RtlSetProcessPreferredUILanguages");
    Check(set_thread(MUI_LANGUAGE_NAME,L"fr-FR\0",&count)>=0 && Preferred(GetThreadPreferredUILanguages)==L"fr-FR","Native thread preferred setter");
    Check(set_thread(MUI_LANGUAGE_NAME,nullptr,&count)>=0 && Preferred(GetThreadPreferredUILanguages)==ui,"Native thread preferred reset");
    Check(set_process(MUI_LANGUAGE_NAME,L"ja-JP\0",&count)>=0 && Preferred(GetProcessPreferredUILanguages)==L"ja-JP","Native process setter");
    Check(set_process(MUI_LANGUAGE_NAME,nullptr,&count)>=0 && Preferred(GetProcessPreferredUILanguages)==ui,"Native process reset");
    const auto set2=cdf::test::Resolve<CdfSetPreferred2>(base,"SetThreadPreferredUILanguages2");
    const auto restore=cdf::test::Resolve<CdfRestorePreferred>(base,"RestoreThreadPreferredUILanguages");
    PVOID saved=nullptr;
    Check(set2 && restore && set2(MUI_LANGUAGE_NAME,L"de-DE\0",&count,&saved) && saved && Preferred(GetThreadPreferredUILanguages)==L"de-DE","Win32 preferred snapshot");
    if(saved) restore(saved);
    Check(Preferred(GetThreadPreferredUILanguages)==ui,"Win32 preferred restore virtual default");
    const auto nset2=cdf::test::Resolve<decltype(&RtlSetThreadPreferredUILanguages2)>(native,"RtlSetThreadPreferredUILanguages2");
    const auto nrestore=cdf::test::Resolve<decltype(&RtlRestoreThreadPreferredUILanguages)>(native,"RtlRestoreThreadPreferredUILanguages");
    saved=nullptr; Check(nset2(MUI_LANGUAGE_NAME,L"fr-FR\0",&count,&saved)>=0 && saved && Preferred(GetThreadPreferredUILanguages)==L"fr-FR","Native preferred snapshot");
    if(saved) nrestore(saved);
    Check(Preferred(GetThreadPreferredUILanguages)==ui,"Native preferred restore virtual default");
}
std::vector<std::wstring> PreferredList(MuiGetter getter,DWORD flags=MUI_LANGUAGE_NAME) {
    WCHAR text[512]{}; ULONG count=0,length=512; std::vector<std::wstring> result;
    if(!getter(flags,&count,text,&length)) return {L"!failed"};
    for(ULONG i=0;i<length && text[i];) {result.emplace_back(text+i);i+=static_cast<ULONG>(result.back().size())+1;}
    Check(result.size()==count,"MUI MULTI_SZ count agrees with full list"); return result;
}
void PreferredOverrides(const std::wstring& ui) {
    ULONG count=0;
    Check(SetProcessPreferredUILanguages(MUI_LANGUAGE_NAME,L"ja-JP\0fr-FR\0",&count) && count==2,"process multiple preferred languages");
    Check(SetThreadPreferredUILanguages(MUI_LANGUAGE_NAME,L"de-DE\0en-GB\0",&count) && count==2,"thread multiple preferred languages");
    const auto process=PreferredList(GetProcessPreferredUILanguages);
    Check(process==std::vector<std::wstring>{L"ja-JP",L"fr-FR"},"process list preserves order");
    const auto only=PreferredList(GetThreadPreferredUILanguages,MUI_LANGUAGE_NAME|MUI_THREAD_LANGUAGES);
    Check(only==std::vector<std::wstring>{L"de-DE",L"en-GB"},"thread-only list excludes process and user defaults");
    const auto merged=PreferredList(GetThreadPreferredUILanguages,MUI_LANGUAGE_NAME|MUI_MERGE_USER_FALLBACK);
    std::vector<std::wstring> expected{L"de-DE",L"en-GB",L"ja-JP",L"fr-FR"};
    if(std::find(expected.begin(),expected.end(),ui)==expected.end()) expected.push_back(ui);
    Check(merged==expected,"thread/process/user fallback precedence");
    const auto system=PreferredList(GetThreadPreferredUILanguages,MUI_LANGUAGE_NAME|MUI_MERGE_SYSTEM_FALLBACK);
    Check(system.size()>=8 && system[0]==L"de-DE" && system[1]==L"de" && system[2]==L"en-GB" && system[3]==L"en", "system fallback expands each explicit parent in order");
    WCHAR native[512]{},win[512]{}; ULONG nc=0,nl=512,wc=0,wl=512;
    Check(RtlGetThreadPreferredUILanguages(MUI_LANGUAGE_NAME|MUI_UI_FALLBACK,&nc,native,&nl)>=0 &&
        GetThreadPreferredUILanguages(MUI_LANGUAGE_NAME|MUI_UI_FALLBACK,&wc,win,&wl) && nc==wc && nl==wl &&
        std::memcmp(native,win,wl*sizeof(WCHAR))==0,"Native and Win32 merged lists agree");
    const auto ids=PreferredList(GetThreadPreferredUILanguages,MUI_LANGUAGE_ID|MUI_THREAD_LANGUAGES);
    Check(ids==std::vector<std::wstring>{L"0407",L"0809"},"explicit list ID rendering");
    Check(SetThreadPreferredUILanguages(MUI_RESET_FILTERS,nullptr,&count) &&
        PreferredList(GetThreadPreferredUILanguages,MUI_LANGUAGE_NAME|MUI_THREAD_LANGUAGES)==only,"filter-only reset retains explicit list");
    const auto set2=cdf::test::Resolve<CdfSetPreferred2>(GetModuleHandleW(L"kernelbase.dll"),"SetThreadPreferredUILanguages2");
    const auto restore=cdf::test::Resolve<CdfRestorePreferred>(GetModuleHandleW(L"kernelbase.dll"),"RestoreThreadPreferredUILanguages");
    PVOID outer=nullptr,inner=nullptr;
    Check(set2(MUI_LANGUAGE_NAME,L"ja-JP\0",&count,&outer) && outer,"nested outer snapshot");
    Check(set2(MUI_LANGUAGE_NAME,L"fr-FR\0",&count,&inner) && inner && Preferred(GetThreadPreferredUILanguages)==L"fr-FR","nested inner snapshot");
    if(inner) restore(inner);
    Check(Preferred(GetThreadPreferredUILanguages)==L"ja-JP","nested inner restore");
    if(outer) restore(outer);
    Check(PreferredList(GetThreadPreferredUILanguages,MUI_LANGUAGE_NAME|MUI_THREAD_LANGUAGES)==only,"nested outer restores prior explicit list");
    Check(SetThreadPreferredUILanguages(MUI_LANGUAGE_NAME,nullptr,&count) && GetThreadUILanguage()==0x411,"thread reset falls back to explicit process language");
    Check(SetProcessPreferredUILanguages(MUI_LANGUAGE_NAME,nullptr,&count) && GetThreadUILanguage()==LANGIDFROMLCID(LocaleNameToLCID(ui.c_str(),0)),"clearing both lists restores configured UI");
}
void Resolvers(const std::wstring& region) {
    const LCID id=LocaleNameToLCID(region.c_str(),0);
    struct Entry {const char* name;unsigned mask;};
    const Entry entries[]={
#define CDF_LOCALE_HOOK(name,modules) {#name,modules},
#include "locale_hooks.inc"
#undef CDF_LOCALE_HOOK
    };
    const HMODULE modules[]={GetModuleHandleW(L"kernelbase.dll"),GetModuleHandleW(L"kernel32.dll"),GetModuleHandleW(L"ntdll.dll")};
    for(const auto& entry:entries) for(unsigned m=0;m<3;++m) if(entry.mask&(1U<<m)) {
        const auto address=GetProcAddress(modules[m],entry.name); Check(address!=nullptr,std::string("resolve ")+entry.name);
        ANSI_STRING name{}; RtlInitAnsiString(&name,entry.name); PVOID found=nullptr;
        Check(LdrGetProcedureAddress(modules[m],&name,0,&found)>=0 && found==reinterpret_cast<PVOID>(address),"Ldr resolver agrees");
    }
    const auto getter=cdf::test::Resolve<decltype(&GetSystemDefaultLCID)>(modules[1],"GetSystemDefaultLCID"); Check(getter && getter()==id,"dynamic kernel32 invocation");
    HMODULE api=LoadLibraryW(L"api-ms-win-core-localization-l1-2-0.dll"); Check(api!=nullptr,"API Set localization load");
    if(api) { const auto fn=cdf::test::Resolve<decltype(&GetUserDefaultLCID)>(api,"GetUserDefaultLCID"); Check(fn && fn()==id,"API Set resolved invocation"); FreeLibrary(api); }
}
void Threads(const std::wstring& region,const std::wstring& ui) {
    std::atomic<unsigned> errors{0}; const LCID id=LocaleNameToLCID(region.c_str(),0);
    const LANGID uid=LANGIDFROMLCID(LocaleNameToLCID(ui.c_str(),0));
    CdfLocaleStatus before{},after{}; const auto query=cdf::test::Resolve<CdfLocaleQuery>(GetModuleHandleW(L"CdfTimeZone64.dll"),"CdfLocaleQueryStatus"); query(&before,sizeof(before));
    std::vector<std::thread> threads;
    for(unsigned i=0;i<16;++i) threads.emplace_back([&,i] {
        if(GetThreadLocale()!=id || GetThreadUILanguage()!=uid || Preferred(GetThreadPreferredUILanguages)!=ui) ++errors;
        const LCID chosen=i%2 ? 0x411 : 0x407;
        if(!SetThreadLocale(chosen) || !SetThreadUILanguage(LANGIDFROMLCID(chosen))) ++errors;
        for(unsigned j=0;j<1000;++j) {
            WCHAR name[85]{}; GetUserDefaultLocaleName(name,85);
            if(GetThreadLocale()!=chosen || GetThreadUILanguage()!=LANGIDFROMLCID(chosen) || GetUserDefaultLCID()!=id || region!=name) ++errors;
        }
    });
    for(auto& t:threads) t.join(); query(&after,sizeof(after));
    Check(errors==0,"16000 concurrent locale query rounds");
    Check(before.live_thread_records==after.live_thread_records,"thread records reclaimed");
    Check(GetThreadLocale()==id && GetThreadUILanguage()==uid,"worker setters do not affect main thread");
}
void Ucrt(const std::wstring& region) {
    const std::string utf8=cdf::test::Utf8(region);
    _locale_t explicit_locale=_create_locale(LC_ALL,utf8.c_str()); Check(explicit_locale!=nullptr,"UCRT explicit locale construction");
    if(!explicit_locale) return;
    // UCRT accepts BCP-47 names or legacy Language_Country.CodePage names;
    // BCP-47 plus a numeric code page (for example en-US.936) is invalid.
    const std::wstring reference_name=Info(region.c_str(),LOCALE_SENGLISHLANGUAGENAME)+L"_"+
        Info(region.c_str(),LOCALE_SENGCOUNTRY)+L"."+std::to_wstring(GetACP());
    const WCHAR* reference_selected=_wsetlocale(LC_ALL,reference_name.c_str());
    Check(reference_selected!=nullptr,"UCRT explicit same-code-page reference "+cdf::test::Utf8(reference_name));
    const lconv reference=*localeconv();
    const std::string decimal=reference.decimal_point, thousands=reference.thousands_sep;
    _wsetlocale(LC_ALL,L"C"); Check(std::string(localeconv()->decimal_point)==".","explicit C locale preserved");
    const WCHAR* selected=_wsetlocale(LC_ALL,L""); if(selected) ucrt_default=cdf::test::Utf8(selected);
    Check(selected && std::string(localeconv()->decimal_point)==decimal && std::string(localeconv()->thousands_sep)==thousands,"UCRT default numeric locale expected="+decimal+"/"+thousands+" actual="+localeconv()->decimal_point+"/"+localeconv()->thousands_sep);
    _wsetlocale(LC_ALL,L"C"); _free_locale(explicit_locale);
}
