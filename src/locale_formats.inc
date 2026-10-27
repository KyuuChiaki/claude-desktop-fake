// Explicit wrappers delegate formatting to Windows NLS after resolving defaults.
int WINAPI HookGetDateFormatEx(LPCWSTR locale,DWORD flags,const SYSTEMTIME* input,LPCWSTR format,LPWSTR output,int capacity,LPCWSTR calendar) {
    if (!Operational()) return RAW(GetDateFormatEx)(locale,flags,input,format,output,capacity,calendar);
    Count(CdfLocaleGetDateFormatEx); bool changed=false;
    locale=MapName(locale,&changed);
    if (changed && !format && !(flags & LOCALE_NOUSEROVERRIDE)) flags|=LOCALE_NOUSEROVERRIDE;
    SYSTEMTIME now{}; if (!input && cdf::VirtualLocalTime(now)) input=&now;
    return RAW(GetDateFormatEx)(locale,flags,input,format,output,capacity,calendar);
}
int WINAPI HookGetDateFormatW(LCID locale,DWORD flags,const SYSTEMTIME* input,LPCWSTR format,LPWSTR output,int capacity) {
    if (!Operational()) return RAW(GetDateFormatW)(locale,flags,input,format,output,capacity);
    Count(CdfLocaleGetDateFormatW); bool changed=false;
    locale=MapId(locale,&changed);
    if (changed && !format && !(flags & LOCALE_NOUSEROVERRIDE)) flags|=LOCALE_NOUSEROVERRIDE;
    SYSTEMTIME now{}; if (!input && cdf::VirtualLocalTime(now)) input=&now;
    return RAW(GetDateFormatW)(locale,flags,input,format,output,capacity);
}
int WINAPI HookGetDateFormatA(LCID locale,DWORD flags,const SYSTEMTIME* input,LPCSTR format,LPSTR output,int capacity) {
    if (!Operational()) return RAW(GetDateFormatA)(locale,flags,input,format,output,capacity);
    Count(CdfLocaleGetDateFormatA); bool changed=false;
    locale=MapId(locale,&changed);
    if (changed && !format && !(flags & LOCALE_NOUSEROVERRIDE)) flags|=LOCALE_NOUSEROVERRIDE;
    SYSTEMTIME now{}; if (!input && cdf::VirtualLocalTime(now)) input=&now;
    return RAW(GetDateFormatA)(locale,flags,input,format,output,capacity);
}
int WINAPI HookGetTimeFormatEx(LPCWSTR locale,DWORD flags,const SYSTEMTIME* input,LPCWSTR format,LPWSTR output,int capacity) {
    if (!Operational()) return RAW(GetTimeFormatEx)(locale,flags,input,format,output,capacity);
    Count(CdfLocaleGetTimeFormatEx); bool changed=false;
    locale=MapName(locale,&changed);
    if (changed && !format && !(flags & LOCALE_NOUSEROVERRIDE)) flags|=LOCALE_NOUSEROVERRIDE;
    SYSTEMTIME now{}; if (!input && cdf::VirtualLocalTime(now)) input=&now;
    return RAW(GetTimeFormatEx)(locale,flags,input,format,output,capacity);
}
int WINAPI HookGetTimeFormatW(LCID locale,DWORD flags,const SYSTEMTIME* input,LPCWSTR format,LPWSTR output,int capacity) {
    if (!Operational()) return RAW(GetTimeFormatW)(locale,flags,input,format,output,capacity);
    Count(CdfLocaleGetTimeFormatW); bool changed=false;
    locale=MapId(locale,&changed);
    if (changed && !format && !(flags & LOCALE_NOUSEROVERRIDE)) flags|=LOCALE_NOUSEROVERRIDE;
    SYSTEMTIME now{}; if (!input && cdf::VirtualLocalTime(now)) input=&now;
    return RAW(GetTimeFormatW)(locale,flags,input,format,output,capacity);
}
int WINAPI HookGetTimeFormatA(LCID locale,DWORD flags,const SYSTEMTIME* input,LPCSTR format,LPSTR output,int capacity) {
    if (!Operational()) return RAW(GetTimeFormatA)(locale,flags,input,format,output,capacity);
    Count(CdfLocaleGetTimeFormatA); bool changed=false;
    locale=MapId(locale,&changed);
    if (changed && !format && !(flags & LOCALE_NOUSEROVERRIDE)) flags|=LOCALE_NOUSEROVERRIDE;
    SYSTEMTIME now{}; if (!input && cdf::VirtualLocalTime(now)) input=&now;
    return RAW(GetTimeFormatA)(locale,flags,input,format,output,capacity);
}
int WINAPI HookGetNumberFormatEx(LPCWSTR locale,DWORD flags,LPCWSTR input,const NUMBERFMTW* format,LPWSTR output,int capacity) {
    if (!Operational()) return RAW(GetNumberFormatEx)(locale,flags,input,format,output,capacity);
    Count(CdfLocaleGetNumberFormatEx); bool changed=false;
    locale=MapName(locale,&changed);
    if (changed && !format && !(flags & LOCALE_NOUSEROVERRIDE)) flags|=LOCALE_NOUSEROVERRIDE;
    return RAW(GetNumberFormatEx)(locale,flags,input,format,output,capacity);
}
int WINAPI HookGetNumberFormatW(LCID locale,DWORD flags,LPCWSTR input,const NUMBERFMTW* format,LPWSTR output,int capacity) {
    if (!Operational()) return RAW(GetNumberFormatW)(locale,flags,input,format,output,capacity);
    Count(CdfLocaleGetNumberFormatW); bool changed=false;
    locale=MapId(locale,&changed);
    if (changed && !format && !(flags & LOCALE_NOUSEROVERRIDE)) flags|=LOCALE_NOUSEROVERRIDE;
    return RAW(GetNumberFormatW)(locale,flags,input,format,output,capacity);
}
int WINAPI HookGetNumberFormatA(LCID locale,DWORD flags,LPCSTR input,const NUMBERFMTA* format,LPSTR output,int capacity) {
    if (!Operational()) return RAW(GetNumberFormatA)(locale,flags,input,format,output,capacity);
    Count(CdfLocaleGetNumberFormatA); bool changed=false;
    locale=MapId(locale,&changed);
    if (changed && !format && !(flags & LOCALE_NOUSEROVERRIDE)) flags|=LOCALE_NOUSEROVERRIDE;
    return RAW(GetNumberFormatA)(locale,flags,input,format,output,capacity);
}
int WINAPI HookGetCurrencyFormatEx(LPCWSTR locale,DWORD flags,LPCWSTR input,const CURRENCYFMTW* format,LPWSTR output,int capacity) {
    if (!Operational()) return RAW(GetCurrencyFormatEx)(locale,flags,input,format,output,capacity);
    Count(CdfLocaleGetCurrencyFormatEx); bool changed=false;
    locale=MapName(locale,&changed);
    if (changed && !format && !(flags & LOCALE_NOUSEROVERRIDE)) flags|=LOCALE_NOUSEROVERRIDE;
    return RAW(GetCurrencyFormatEx)(locale,flags,input,format,output,capacity);
}
int WINAPI HookGetCurrencyFormatW(LCID locale,DWORD flags,LPCWSTR input,const CURRENCYFMTW* format,LPWSTR output,int capacity) {
    if (!Operational()) return RAW(GetCurrencyFormatW)(locale,flags,input,format,output,capacity);
    Count(CdfLocaleGetCurrencyFormatW); bool changed=false;
    locale=MapId(locale,&changed);
    if (changed && !format && !(flags & LOCALE_NOUSEROVERRIDE)) flags|=LOCALE_NOUSEROVERRIDE;
    return RAW(GetCurrencyFormatW)(locale,flags,input,format,output,capacity);
}
int WINAPI HookGetCurrencyFormatA(LCID locale,DWORD flags,LPCSTR input,const CURRENCYFMTA* format,LPSTR output,int capacity) {
    if (!Operational()) return RAW(GetCurrencyFormatA)(locale,flags,input,format,output,capacity);
    Count(CdfLocaleGetCurrencyFormatA); bool changed=false;
    locale=MapId(locale,&changed);
    if (changed && !format && !(flags & LOCALE_NOUSEROVERRIDE)) flags|=LOCALE_NOUSEROVERRIDE;
    return RAW(GetCurrencyFormatA)(locale,flags,input,format,output,capacity);
}
int WINAPI HookGetCalendarInfoEx(LPCWSTR locale,CALID calendar,LPCWSTR reserved,CALTYPE type,LPWSTR output,int capacity,LPDWORD number) {
    if (!Operational()) return RAW(GetCalendarInfoEx)(locale,calendar,reserved,type,output,capacity,number);
    Count(CdfLocaleGetCalendarInfoEx); bool changed=false;
    locale=MapName(locale,&changed);
    if (changed) type|=CAL_NOUSEROVERRIDE;
    return RAW(GetCalendarInfoEx)(locale,calendar,reserved,type,output,capacity,number);
}
int WINAPI HookGetCalendarInfoW(LCID locale,CALID calendar,CALTYPE type,LPWSTR output,int capacity,LPDWORD number) {
    if (!Operational()) return RAW(GetCalendarInfoW)(locale,calendar,type,output,capacity,number);
    Count(CdfLocaleGetCalendarInfoW); bool changed=false;
    locale=MapId(locale,&changed);
    if (changed) type|=CAL_NOUSEROVERRIDE;
    return RAW(GetCalendarInfoW)(locale,calendar,type,output,capacity,number);
}
int WINAPI HookGetCalendarInfoA(LCID locale,CALID calendar,CALTYPE type,LPSTR output,int capacity,LPDWORD number) {
    if (!Operational()) return RAW(GetCalendarInfoA)(locale,calendar,type,output,capacity,number);
    Count(CdfLocaleGetCalendarInfoA); bool changed=false;
    locale=MapId(locale,&changed);
    if (changed) type|=CAL_NOUSEROVERRIDE;
    return RAW(GetCalendarInfoA)(locale,calendar,type,output,capacity,number);
}
