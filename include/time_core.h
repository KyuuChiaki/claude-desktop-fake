#pragma once
#include "time_native.h"

namespace cdf {
struct LocaleConfig {
    bool enabled; WCHAR format_locale[LOCALE_NAME_MAX_LENGTH], ui_language[LOCALE_NAME_MAX_LENGTH];
    LCID format_lcid, ui_lcid;
};
struct RegionConfig { bool enabled; WCHAR home_region[3]; GEOID geo_id; };
struct RuntimeConfig { bool enabled, passthrough, capture; };
struct Config {
    bool enabled; WCHAR zone_id[128]; LONGLONG offset_seconds, offset_ticks;
    DWORD schema_version; LocaleConfig locale; RegionConfig region; RuntimeConfig runtime;
};
struct RegTzi { LONG bias, standard_bias, daylight_bias; SYSTEMTIME standard_date, daylight_date; };
static_assert(sizeof(RegTzi) == 44);
inline constexpr ULONG max_year_rules = 512;
struct Zone {
    WCHAR id[128], standard_name[32], daylight_name[32]; RegTzi base;
    ULONG first_year, last_year, year_count; RegTzi years[max_year_rules];
};
void Zero(void* data, SIZE_T size);
void Copy(void* to, const void* from, SIZE_T size);
bool CopyText(WCHAR* to, SIZE_T capacity, const WCHAR* from);
bool AddTicks(LONGLONG value, LONGLONG delta, LONGLONG& output);
bool ParseConfig(const char* json, ULONG size, Config& config, DWORD& error);
bool ReadConfig(Config& config, DWORD& error, NTSTATUS& native_status);
bool ValidateLocale(LocaleConfig& config, DWORD& error, NTSTATUS& native_status);
bool ValidateRegion(RegionConfig& config, DWORD& error);
bool LoadZone(const WCHAR* id, Zone& zone, DWORD& error, NTSTATUS& native_status);
const RegTzi& Rule(const Zone& zone, int year);
void WinTzi(const Zone& zone, int year, TIME_ZONE_INFORMATION& out);
void WinDynamicTzi(const Zone& zone, int year, DYNAMIC_TIME_ZONE_INFORMATION& out);
void ToNative(const TIME_ZONE_INFORMATION& input, NativeTzi& out);
void NativeDynamic(const DYNAMIC_TIME_ZONE_INFORMATION& input, NativeDynamicTzi& out);
bool ToTicks(const SYSTEMTIME& input, LONGLONG& out);
bool ToSystemTime(LONGLONG ticks, SYSTEMTIME& out);
bool BiasAt(const Zone& zone, LONGLONG utc, LONG& bias, DWORD& zone_id);
bool UtcToLocal(const Zone& zone, LONGLONG utc, LONGLONG& local);
bool LocalToUtc(const Zone& zone, LONGLONG local, LONGLONG& utc);
inline LONGLONG FileTicks(const FILETIME& input) {
    return static_cast<LONGLONG>((static_cast<ULONGLONG>(input.dwHighDateTime) << 32) | input.dwLowDateTime);
}
inline void ToFileTime(LONGLONG ticks, FILETIME& out) {
    out.dwLowDateTime = static_cast<DWORD>(ticks);
    out.dwHighDateTime = static_cast<DWORD>(static_cast<ULONGLONG>(ticks) >> 32);
}
}
