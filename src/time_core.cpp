#include "time_core.h"
#define JSMN_STRICT
#define JSMN_STATIC
#include "jsmn.h"

namespace cdf {
void Zero(void* data, SIZE_T size) {
    volatile BYTE* p = static_cast<volatile BYTE*>(data);
    while (size--) *p++ = 0;
}
void Copy(void* to, const void* from, SIZE_T size) {
    volatile BYTE* d = static_cast<volatile BYTE*>(to);
    const volatile BYTE* s = static_cast<const volatile BYTE*>(from);
    while (size--) *d++ = *s++;
}
bool CopyText(WCHAR* to, SIZE_T capacity, const WCHAR* from) {
    SIZE_T i = 0;
    while (from[i] && i + 1 < capacity) { to[i] = from[i]; ++i; }
    if (capacity) to[i] = 0;
    return from[i] == 0;
}
bool AddTicks(LONGLONG value, LONGLONG delta, LONGLONG& output) {
    if (value < 0 || (delta > 0 && value > max_ticks - delta) ||
        (delta < 0 && delta < -value)) return false;
    output = value + delta;
    return true;
}
namespace {
bool Equal(const WCHAR* a, const WCHAR* b) {
    while (*a && *a == *b) { ++a; ++b; }
    return *a == *b;
}
bool Space(char c) { return c == ' ' || c == '\r' || c == '\n' || c == '\t'; }
void Skip(const char* json, ULONG size, ULONG& cursor) { while (cursor < size && Space(json[cursor])) ++cursor; }
bool Integer(const char* p, int size, LONGLONG& value) {
    int i = 0; const bool negative = size > 0 && p[0] == '-';
    if (negative) ++i;
    if (i == size || (p[i] == '0' && i + 1 < size)) return false;
    ULONGLONG n = 0;
    const ULONGLONG limit = negative ? 0x8000000000000000ULL : 0x7fffffffffffffffULL;
    for (; i < size; ++i) {
        if (p[i] < '0' || p[i] > '9') return false;
        const ULONGLONG digit = static_cast<ULONGLONG>(p[i] - '0');
        if (n > (limit - digit) / 10) return false;
        n = n * 10 + digit;
    }
    value = negative ? (n == 0x8000000000000000ULL ? (-max_ticks - 1) : -static_cast<LONGLONG>(n)) : static_cast<LONGLONG>(n);
    return true;
}
int Hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
bool String(const char* json, const jsmntok_t& token, WCHAR* out, ULONG capacity) {
    ULONG n = 0;
    for (int i = token.start; i < token.end; ++i) {
        unsigned c = static_cast<unsigned char>(json[i]);
        if (c == '\\') {
            if (++i >= token.end) return false;
            c = static_cast<unsigned char>(json[i]);
            if (c == 'u') {
                c = 0;
                for (int k = 0; k != 4; ++k) {
                    if (++i >= token.end || Hex(json[i]) < 0) return false;
                    c = c * 16 + static_cast<unsigned>(Hex(json[i]));
                }
            } else if (c != '"' && c != '\\' && c != '/') return false;
        }
        // Installed Windows zone identifiers and schema keys use printable ASCII.
        if (c < 32 || c > 126 || n + 1 >= capacity) return false;
        out[n++] = static_cast<WCHAR>(c);
    }
    out[n] = 0;
    return true;
}
bool TokenAt(const char* json, ULONG size, const jsmntok_t& token, ULONG& cursor) {
    Skip(json, size, cursor);
    const bool string = token.type == JSMN_STRING;
    const int begin = string ? token.start - 1 : token.start;
    const int end = string ? token.end + 1 : token.end;
    if (begin < 0 || cursor != static_cast<ULONG>(begin) || end < begin || static_cast<ULONG>(end) > size) return false;
    cursor = static_cast<ULONG>(end);
    return true;
}
struct PartialValue { ULONG title, type, length; BYTE data[1]; };
bool Query(HANDLE key, const WCHAR* name, DWORD type, void* output, ULONG capacity, ULONG& size, NTSTATUS& status) {
    UNICODE_STRING value_name; RtlInitUnicodeString(&value_name, name);
    alignas(8) BYTE buffer[1024]; ULONG returned = 0;
    status = NtQueryValueKey(key, &value_name, 2, buffer, sizeof(buffer), &returned);
    if (status < 0) return false;
    const auto* value = reinterpret_cast<const PartialValue*>(buffer);
    if (returned < 12 || value->type != type || value->length > returned - 12 || value->length > capacity) {
        status = status_invalid_parameter; return false;
    }
    size = value->length; Copy(output, value->data, size); return true;
}
bool Open(const WCHAR* path, HANDLE parent, HANDLE& key, NTSTATUS& status) {
    UNICODE_STRING name; RtlInitUnicodeString(&name, path);
    OBJECT_ATTRIBUTES attributes;
    InitializeObjectAttributes(&attributes, &name, OBJ_CASE_INSENSITIVE, parent, nullptr);
    status = NtOpenKey(&key, KEY_QUERY_VALUE | KEY_WOW64_64KEY, &attributes);
    return status >= 0;
}
bool ReadName(HANDLE key, const WCHAR* name, WCHAR (&out)[32], NTSTATUS& status) {
    WCHAR text[256]; Zero(text, sizeof(text)); ULONG size = 0;
    if (!Query(key, name, REG_SZ, text, sizeof(text) - sizeof(WCHAR), size, status) || size % 2 != 0) return false;
    SIZE_T i = 0; while (text[i] && i < 31) { out[i] = text[i]; ++i; } out[i] = 0;
    return true;
}
bool ReadRule(HANDLE key, const WCHAR* name, RegTzi& out, NTSTATUS& status) {
    ULONG size = 0;
    if (!Query(key, name, REG_BINARY, &out, sizeof(out), size, status) || size != sizeof(out)) {
        if (status >= 0) status = status_invalid_parameter;
        return false;
    }
    if (out.bias < -1440 || out.bias > 1440 || out.standard_bias < -1440 || out.standard_bias > 1440 ||
        out.daylight_bias < -1440 || out.daylight_bias > 1440) { status = status_invalid_parameter; return false; }
    for (const SYSTEMTIME* date : {&out.standard_date, &out.daylight_date}) {
        if (date->wMonth > 12 || (date->wMonth && (date->wDay < 1 || date->wDay > (date->wYear ? 31 : 5) ||
            date->wDayOfWeek > 6 || date->wHour > 23 || date->wMinute > 59 || date->wSecond > 59 || date->wMilliseconds > 999))) {
            status = status_invalid_parameter; return false;
        }
    }
    if ((out.standard_date.wMonth == 0) != (out.daylight_date.wMonth == 0)) { status = status_invalid_parameter; return false; }
    return true;
}
void Fields(const SYSTEMTIME& in, TimeFields& out) {
    out.year = static_cast<SHORT>(in.wYear); out.month = static_cast<SHORT>(in.wMonth);
    out.day = static_cast<SHORT>(in.wDay); out.hour = static_cast<SHORT>(in.wHour);
    out.minute = static_cast<SHORT>(in.wMinute); out.second = static_cast<SHORT>(in.wSecond);
    out.milliseconds = static_cast<SHORT>(in.wMilliseconds); out.weekday = static_cast<SHORT>(in.wDayOfWeek);
}
int Days(int year, int month) {
    static const int days[] = {31,28,31,30,31,30,31,31,30,31,30,31};
    return days[month - 1] + (month == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 1 : 0);
}
bool Transition(const SYSTEMTIME& rule, int year, LONGLONG& ticks) {
    SYSTEMTIME date; Copy(&date, &rule, sizeof(date));
    if (!date.wYear) {
        date.wYear = static_cast<WORD>(year); date.wDay = 1;
        LONGLONG first = 0; SYSTEMTIME calendar;
        if (!ToTicks(date, first) || !ToSystemTime(first, calendar)) return false;
        int day = 1 + (7 + rule.wDayOfWeek - calendar.wDayOfWeek) % 7 + (rule.wDay - 1) * 7;
        if (day > Days(year, rule.wMonth)) day -= 7;
        date.wDay = static_cast<WORD>(day);
    }
    return ToTicks(date, ticks);
}
}

namespace {
struct ConfigReader {
    const char* json; ULONG size, cursor = 0; jsmntok_t tokens[96]{}; int count = 0, index = 0;
    bool Begin(int& pairs) {
        if (index >= count || tokens[index].type != JSMN_OBJECT) return false;
        pairs = tokens[index++].size; Skip(json, size, cursor);
        return cursor < size && json[cursor++] == '{';
    }
    bool Key(WCHAR* text) {
        if (index >= count) return false;
        const auto& t = tokens[index++];
        if (t.type != JSMN_STRING || t.size != 1 || !TokenAt(json,size,t,cursor) || !String(json,t,text,32)) return false;
        Skip(json,size,cursor); return cursor < size && json[cursor++] == ':';
    }
    bool Value(jsmntok_t& t) {
        if (index >= count) return false;
        t = tokens[index++]; return t.size == 0 && TokenAt(json,size,t,cursor);
    }
    bool EndPair(bool last) {
        Skip(json,size,cursor); return cursor < size && json[cursor++] == (last ? '}' : ',');
    }
    bool Boolean(const jsmntok_t& t, bool& out) {
        if (t.type != JSMN_PRIMITIVE) return false;
        const int n = t.end-t.start; const char* p = json+t.start;
        if (n == 4 && p[0]=='t' && p[1]=='r' && p[2]=='u' && p[3]=='e') { out=true; return true; }
        if (n == 5 && p[0]=='f' && p[1]=='a' && p[2]=='l' && p[3]=='s' && p[4]=='e') { out=false; return true; }
        return false;
    }
    bool TimeValue(const WCHAR* key, const jsmntok_t& value, Config& config, unsigned& seen) {
        unsigned bit = 0;
        if (Equal(key,L"enabled")) {
            bit=1; if (!Boolean(value,config.enabled)) return false;
        } else if (Equal(key,L"timeZoneId")) {
            bit=2;
            if (value.type != JSMN_STRING || !String(json,value,config.zone_id,128) || !config.zone_id[0]) return false;
            for (ULONG i=0;config.zone_id[i];++i) if (config.zone_id[i]=='\\' || config.zone_id[i]=='/') return false;
        } else if (Equal(key,L"utcOffsetSeconds")) {
            bit=4;
            if (value.type != JSMN_PRIMITIVE || !Integer(json+value.start,value.end-value.start,config.offset_seconds)) return false;
        } else return false;
        if (seen & bit) return false;
        seen |= bit; return true;
    }
    bool Time(Config& config) {
        int pairs = 0; unsigned seen = 0;
        if (!Begin(pairs) || pairs != 3) return false;
        for (int i=0;i<pairs;++i) {
            WCHAR key[32]; jsmntok_t value;
            if (!Key(key) || !Value(value) || !TimeValue(key,value,config,seen) || !EndPair(i+1==pairs)) return false;
        }
        return seen==7;
    }
    bool Locale(LocaleConfig& config) {
        int pairs=0; unsigned seen=0;
        if (!Begin(pairs) || pairs!=3) return false;
        for (int i=0;i<pairs;++i) {
            WCHAR key[32]; jsmntok_t value; unsigned bit=0;
            if (!Key(key) || !Value(value)) return false;
            if (Equal(key,L"enabled")) { bit=1; if (!Boolean(value,config.enabled)) return false; }
            else if (Equal(key,L"formatLocale")) {
                bit=2; if (value.type!=JSMN_STRING || !String(json,value,config.format_locale,LOCALE_NAME_MAX_LENGTH) || !config.format_locale[0]) return false;
            } else if (Equal(key,L"uiLanguage")) {
                bit=4; if (value.type!=JSMN_STRING || !String(json,value,config.ui_language,LOCALE_NAME_MAX_LENGTH) || !config.ui_language[0]) return false;
            } else return false;
            if (seen & bit) return false;
            seen|=bit; if (!EndPair(i+1==pairs)) return false;
        }
        return seen==7;
    }
    bool Region(RegionConfig& config) {
        int pairs=0; unsigned seen=0;
        if (!Begin(pairs) || pairs!=2) return false;
        for(int i=0;i<pairs;++i) {
            WCHAR key[32]; jsmntok_t value; unsigned bit=0;
            if(!Key(key)||!Value(value))return false;
            if(Equal(key,L"enabled")){bit=1;if(!Boolean(value,config.enabled))return false;}
            else if(Equal(key,L"homeRegion")){
                bit=2;if(value.type!=JSMN_STRING||!String(json,value,config.home_region,3))return false;
                for(unsigned j=0;j<2;++j){WCHAR& c=config.home_region[j];if(c>=L'a'&&c<=L'z')c-=L'a'-L'A';if(c<L'A'||c>L'Z')return false;}
            }else return false;
            if(seen&bit)return false;seen|=bit;if(!EndPair(i+1==pairs))return false;
        }
        return seen==3;
    }
    bool Runtime(RuntimeConfig& config) {
        int pairs=0;unsigned seen=0;
        if(!Begin(pairs)||pairs!=3)return false;
        for(int i=0;i<pairs;++i){
            WCHAR key[32],policy[16]{};jsmntok_t value;unsigned bit=0;
            if(!Key(key)||!Value(value))return false;
            if(Equal(key,L"enabled")){bit=1;if(!Boolean(value,config.enabled))return false;}
            else if(Equal(key,L"captureEnabled")){bit=2;if(!Boolean(value,config.capture))return false;}
            else if(Equal(key,L"unknownVersionPolicy")){
                bit=4;if(value.type!=JSMN_STRING||!String(json,value,policy,16))return false;
                if(Equal(policy,L"passthrough"))config.passthrough=true;else if(!Equal(policy,L"block"))return false;
            }else return false;
            if(seen&bit)return false;seen|=bit;if(!EndPair(i+1==pairs))return false;
        }
        return seen==7;
    }
};
}
bool ParseConfig(const char* json, ULONG size, Config& config, DWORD& error) {
    Zero(&config,sizeof(config)); error=ERROR_INVALID_DATA;
    if (size>16384) return false;
    if (size>=3 && static_cast<BYTE>(json[0])==0xef && static_cast<BYTE>(json[1])==0xbb && static_cast<BYTE>(json[2])==0xbf) { json+=3; size-=3; }
    if (!size || size>16384) return false;
    ConfigReader reader{}; reader.json=json; reader.size=size;
    jsmn_parser parser; jsmn_init(&parser);
    reader.count=jsmn_parse(&parser,json,size,reader.tokens,96);
    if (reader.count<1) return false;
    int pairs=0; unsigned seen=0, time_seen=0;
    if (!reader.Begin(pairs) || (pairs!=3 && pairs!=4 && pairs!=5)) return false;
    for (int i=0;i<pairs;++i) {
        WCHAR key[32]; unsigned bit=0; jsmntok_t value;
        if (!reader.Key(key)) return false;
        if (Equal(key,L"schemaVersion")) {
            LONGLONG version=0; bit=1;
            if (!reader.Value(value) || value.type!=JSMN_PRIMITIVE || !Integer(json+value.start,value.end-value.start,version) || (version<1 || version>3)) return false;
            config.schema_version=static_cast<DWORD>(version);
        } else if (Equal(key,L"time")) { bit=2; if (!reader.Time(config)) return false; }
        else if (Equal(key,L"locale")) { bit=4; if (!reader.Locale(config.locale)) return false; }
        else if (Equal(key,L"region")) { bit=64; if (!reader.Region(config.region)) return false; }
        else if (Equal(key,L"runtime")) { bit=128; if (!reader.Runtime(config.runtime)) return false; }
        else {
            if (!reader.Value(value) || !reader.TimeValue(key,value,config,time_seen)) return false;
            bit=8U << (Equal(key,L"enabled") ? 0 : Equal(key,L"timeZoneId") ? 1 : 2);
        }
        if (seen & bit) return false;
        seen|=bit; if (!reader.EndPair(i+1==pairs)) return false;
    }
    Skip(json,size,reader.cursor);
    if (reader.index!=reader.count || reader.cursor!=size ||
        (config.schema_version==1 ? seen!=57 || time_seen!=7 : config.schema_version==2 ? seen!=7 : seen!=199)) return false;
    if (config.offset_seconds>max_ticks/ticks_second || config.offset_seconds< -max_ticks/ticks_second) {
        error=ERROR_ARITHMETIC_OVERFLOW; return false;
    }
    config.offset_ticks=config.offset_seconds*ticks_second;
    error=0; return true;
}

bool ReadConfig(Config& config, DWORD& error, NTSTATUS& native_status) {
    static char buffer[16385];
    // Match the manager's machine CommonApplicationData folder, without
    // trusting a per-process ProgramData environment-variable override.
    HANDLE folders=nullptr; WCHAR directory[384]{}; ULONG directory_size=0;
    if (!Open(L"\\REGISTRY\\MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Folders",nullptr,folders,native_status)) {
        error=RtlNtStatusToDosError(native_status); return false;
    }
    const bool queried=Query(folders,L"Common AppData",REG_SZ,directory,sizeof(directory)-sizeof(WCHAR),directory_size,native_status);
    NtClose(folders);
    if (!queried) { error=RtlNtStatusToDosError(native_status); return false; }
    if (directory_size<6 || directory_size%2 || directory[1]!=L':' || directory[2]!=L'\\') {
        error=ERROR_INVALID_DATA; native_status=status_invalid_parameter; return false;
    }
    WCHAR path[512]{}; CopyText(path,512,L"\\??\\");
    if (!CopyText(path+4,508,directory)) { error=ERROR_FILENAME_EXCED_RANGE; return false; }
    ULONG length=0; while(path[length]) ++length;
    if (length && path[length-1]==L'\\') --length;
    if (!CopyText(path+length,512-length,L"\\ClaudeDesktopFake\\stage2\\timezone.json")) { error=ERROR_FILENAME_EXCED_RANGE; return false; }
    UNICODE_STRING name; RtlInitUnicodeString(&name,path);
    OBJECT_ATTRIBUTES attributes; InitializeObjectAttributes(&attributes, &name, OBJ_CASE_INSENSITIVE, nullptr, nullptr);
    HANDLE file = nullptr; IO_STATUS_BLOCK io;
    native_status = NtOpenFile(&file, FILE_READ_DATA | SYNCHRONIZE, &attributes, &io,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, 0x20 | 0x40);
    if (native_status < 0) { error = RtlNtStatusToDosError(native_status); return false; }
    LARGE_INTEGER offset; offset.QuadPart = 0;
    native_status = NtReadFile(file, nullptr, nullptr, nullptr, &io, buffer, sizeof(buffer), &offset, nullptr);
    NtClose(file);
    if (native_status < 0) { error = RtlNtStatusToDosError(native_status); return false; }
    return ParseConfig(buffer, static_cast<ULONG>(io.Information), config, error);
}

bool LoadZone(const WCHAR* id, Zone& zone, DWORD& error, NTSTATUS& native_status) {
    Zero(&zone, sizeof(zone)); error = ERROR_INVALID_DATA;
    if (!CopyText(zone.id, 128, id)) return false;
    WCHAR path[512];
    CopyText(path, 512, L"\\REGISTRY\\MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Time Zones\\");
    SIZE_T length = 0; while (path[length]) ++length;
    if (!CopyText(path + length, 512 - length, id)) return false;
    HANDLE key = nullptr;
    if (!Open(path, nullptr, key, native_status)) { error = RtlNtStatusToDosError(native_status); return false; }
    bool ok = ReadRule(key, L"TZI", zone.base, native_status) && ReadName(key, L"Std", zone.standard_name, native_status) &&
        ReadName(key, L"Dlt", zone.daylight_name, native_status);
    HANDLE dynamic = nullptr;
    if (ok && Open(L"Dynamic DST", key, dynamic, native_status)) {
        ULONG size = 0;
        ok = Query(dynamic, L"FirstEntry", REG_DWORD, &zone.first_year, sizeof(ULONG), size, native_status) && size == sizeof(ULONG) &&
            Query(dynamic, L"LastEntry", REG_DWORD, &zone.last_year, sizeof(ULONG), size, native_status) && size == sizeof(ULONG);
        if (ok && (zone.first_year < 1601 || zone.last_year > 30827 || zone.last_year < zone.first_year ||
            zone.last_year - zone.first_year >= max_year_rules)) { ok = false; native_status = status_invalid_parameter; }
        if (ok) {
            zone.year_count = zone.last_year - zone.first_year + 1;
            for (ULONG i = 0; ok && i < zone.year_count; ++i) {
                WCHAR year_name[6]; ULONG n = zone.first_year + i, digits = n >= 10000 ? 5UL : 4UL;
                year_name[digits] = 0;
                while (digits) { year_name[--digits] = static_cast<WCHAR>('0' + n % 10); n /= 10; }
                ok = ReadRule(dynamic, year_name, zone.years[i], native_status);
            }
        }
        NtClose(dynamic);
    } else if (ok && native_status != status_object_name_not_found && native_status != status_object_path_not_found) ok = false;
    NtClose(key);
    if (!ok) { error = RtlNtStatusToDosError(native_status < 0 ? native_status : status_invalid_parameter); return false; }
    error = ERROR_SUCCESS; native_status = 0; return true;
}

const RegTzi& Rule(const Zone& zone, int year) {
    if (!zone.year_count) return zone.base;
    if (year <= static_cast<int>(zone.first_year)) return zone.years[0];
    if (year >= static_cast<int>(zone.last_year)) return zone.years[zone.year_count - 1];
    return zone.years[static_cast<ULONG>(year) - zone.first_year];
}
void WinTzi(const Zone& zone, int year, TIME_ZONE_INFORMATION& out) {
    Zero(&out, sizeof(out)); const RegTzi& rule = Rule(zone, year);
    out.Bias = rule.bias; out.StandardBias = rule.standard_bias; out.DaylightBias = rule.daylight_bias;
    Copy(&out.StandardDate, &rule.standard_date, sizeof(SYSTEMTIME)); Copy(&out.DaylightDate, &rule.daylight_date, sizeof(SYSTEMTIME));
    CopyText(out.StandardName, 32, zone.standard_name); CopyText(out.DaylightName, 32, zone.daylight_name);
}
void WinDynamicTzi(const Zone& zone, int year, DYNAMIC_TIME_ZONE_INFORMATION& out) {
    Zero(&out, sizeof(out)); TIME_ZONE_INFORMATION plain; WinTzi(zone, year, plain);
    Copy(&out, &plain, sizeof(plain)); CopyText(out.TimeZoneKeyName, 128, zone.id);
    out.DynamicDaylightTimeDisabled = FALSE;
}
void ToNative(const TIME_ZONE_INFORMATION& input, NativeTzi& out) {
    Zero(&out, sizeof(out)); out.bias = input.Bias; out.standard_bias = input.StandardBias; out.daylight_bias = input.DaylightBias;
    Copy(out.standard_name, input.StandardName, sizeof(out.standard_name)); Copy(out.daylight_name, input.DaylightName, sizeof(out.daylight_name));
    Fields(input.StandardDate, out.standard_start); Fields(input.DaylightDate, out.daylight_start);
}
void NativeDynamic(const DYNAMIC_TIME_ZONE_INFORMATION& input, NativeDynamicTzi& out) {
    Zero(&out, sizeof(out)); TIME_ZONE_INFORMATION plain; Copy(&plain, &input, sizeof(plain)); ToNative(plain, out.tzi);
    Copy(out.key_name, input.TimeZoneKeyName, sizeof(out.key_name)); out.daylight_disabled = input.DynamicDaylightTimeDisabled;
}
bool ToTicks(const SYSTEMTIME& input, LONGLONG& out) {
    if (input.wYear < 1601 || input.wYear > 30827) return false;
    TimeFields fields; Fields(input, fields); LARGE_INTEGER ticks;
    if (!RtlTimeFieldsToTime(&fields, &ticks) || ticks.QuadPart < 0) return false;
    out = ticks.QuadPart; return true;
}
bool ToSystemTime(LONGLONG ticks, SYSTEMTIME& out) {
    if (ticks < 0) return false;
    LARGE_INTEGER value; value.QuadPart = ticks; TimeFields fields;
    RtlTimeToTimeFields(&value, &fields);
    if (fields.year < 1601 || fields.year > 30827) return false;
    out.wYear = static_cast<WORD>(fields.year); out.wMonth = static_cast<WORD>(fields.month); out.wDay = static_cast<WORD>(fields.day);
    out.wHour = static_cast<WORD>(fields.hour); out.wMinute = static_cast<WORD>(fields.minute); out.wSecond = static_cast<WORD>(fields.second);
    out.wMilliseconds = static_cast<WORD>(fields.milliseconds); out.wDayOfWeek = static_cast<WORD>(fields.weekday); return true;
}
bool BiasAt(const Zone& zone, LONGLONG utc, LONG& bias, DWORD& zone_id) {
    SYSTEMTIME date; if (!ToSystemTime(utc, date)) return false;
    int year = date.wYear;
    for (int i = 0; i < 2; ++i) {
        const RegTzi& rule = Rule(zone, year); LONGLONG local = 0;
        if (!AddTicks(utc, -static_cast<LONGLONG>(rule.bias + rule.standard_bias) * ticks_minute, local) || !ToSystemTime(local, date)) return false;
        if (year == date.wYear) break; year = date.wYear;
    }
    const RegTzi& rule = Rule(zone, year);
    bias = rule.bias + rule.standard_bias; zone_id = TIME_ZONE_ID_UNKNOWN;
    if (!rule.standard_date.wMonth || !rule.daylight_date.wMonth) return true;
    LONGLONG standard = 0, daylight = 0;
    if (!Transition(rule.standard_date, year, standard) || !Transition(rule.daylight_date, year, daylight) ||
        !AddTicks(standard, static_cast<LONGLONG>(rule.bias + rule.daylight_bias) * ticks_minute, standard) ||
        !AddTicks(daylight, static_cast<LONGLONG>(rule.bias + rule.standard_bias) * ticks_minute, daylight)) return false;
    const bool dst = daylight < standard ? utc >= daylight && utc < standard : utc >= daylight || utc < standard;
    if (dst) bias = rule.bias + rule.daylight_bias;
    zone_id = dst ? TIME_ZONE_ID_DAYLIGHT : TIME_ZONE_ID_STANDARD; return true;
}
bool UtcToLocal(const Zone& zone, LONGLONG utc, LONGLONG& local) {
    LONG bias = 0; DWORD id = 0;
    return BiasAt(zone, utc, bias, id) && AddTicks(utc, -static_cast<LONGLONG>(bias) * ticks_minute, local);
}
bool LocalToUtc(const Zone& zone, LONGLONG local, LONGLONG& utc) {
    SYSTEMTIME date; if (!ToSystemTime(local, date)) return false;
    const RegTzi& rule = Rule(zone, date.wYear);
    const LONG biases[2] = {rule.bias + rule.daylight_bias, rule.bias + rule.standard_bias};
    // Windows Ex conversions choose daylight time in a repeated hour.
    for (LONG bias : biases) {
        LONGLONG candidate = 0, roundtrip = 0;
        if (AddTicks(local, static_cast<LONGLONG>(bias) * ticks_minute, candidate) &&
            UtcToLocal(zone, candidate, roundtrip) && roundtrip == local) { utc = candidate; return true; }
    }
    // Windows maps the spring gap using the standard bias, even though it
    // cannot round-trip to the nonexistent local time.
    return AddTicks(local, static_cast<LONGLONG>(rule.bias + rule.standard_bias) * ticks_minute, utc);
}
}
