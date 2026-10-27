#pragma once
#include <Windows.h>
#include <winternl.h>
#include <cstddef>
#include <initializer_list>

namespace cdf {
// These values identify different kernel operations; the similar names do
// not imply the query and set APIs support the same classes. On the verified
// 19041 kernel, TimeZone (93) exists only in the set dispatcher.
enum class TimeInformationClass : ULONG {
    TimeOfDay = 3,
    CurrentTimeZone = 44,
    TimeZone = 93,
    DynamicTimeZone = 102
};
struct TimeFields { SHORT year, month, day, hour, minute, second, milliseconds, weekday; };
struct NativeTzi {
    LONG bias; WCHAR standard_name[32]; TimeFields standard_start; LONG standard_bias;
    WCHAR daylight_name[32]; TimeFields daylight_start; LONG daylight_bias;
};
struct NativeDynamicTzi { NativeTzi tzi; WCHAR key_name[128]; BOOLEAN daylight_disabled; };
struct TimeOfDay {
    LARGE_INTEGER boot, current, bias; ULONG zone_id, reserved;
    ULONGLONG boot_bias, sleep_bias;
};
static_assert(sizeof(TimeFields) == 16);
static_assert(sizeof(NativeTzi) == 172 && offsetof(NativeTzi, daylight_bias) == 168);
static_assert(sizeof(NativeDynamicTzi) == 432 && offsetof(NativeDynamicTzi, key_name) == 172);
static_assert(sizeof(TimeOfDay) == 48 && offsetof(TimeOfDay, zone_id) == 24);
static_assert(sizeof(TIME_ZONE_INFORMATION) == 172 && sizeof(DYNAMIC_TIME_ZONE_INFORMATION) == 432);
inline constexpr NTSTATUS status_success = 0;
inline constexpr NTSTATUS status_invalid_info_class = static_cast<NTSTATUS>(0xC0000003UL);
inline constexpr NTSTATUS status_invalid_parameter = static_cast<NTSTATUS>(0xC000000DUL);
inline constexpr NTSTATUS status_object_name_not_found = static_cast<NTSTATUS>(0xC0000034UL);
inline constexpr NTSTATUS status_object_path_not_found = static_cast<NTSTATUS>(0xC000003AUL);
inline constexpr LONGLONG ticks_second = 10000000;
inline constexpr LONGLONG ticks_minute = 60 * ticks_second;
inline constexpr LONGLONG ticks_day = 86400 * ticks_second;
inline constexpr LONGLONG max_ticks = 0x7fffffffffffffffLL;
}

extern "C" {
NTSYSAPI NTSTATUS NTAPI NtOpenKey(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES);
NTSYSAPI NTSTATUS NTAPI NtQueryValueKey(HANDLE, PUNICODE_STRING, ULONG, PVOID, ULONG, PULONG);
NTSYSAPI NTSTATUS NTAPI NtReadFile(HANDLE, HANDLE, PVOID, PVOID, PIO_STATUS_BLOCK, PVOID, ULONG, PLARGE_INTEGER, PULONG);
NTSYSAPI VOID NTAPI RtlTimeToTimeFields(PLARGE_INTEGER, cdf::TimeFields*);
NTSYSAPI BOOLEAN NTAPI RtlTimeFieldsToTime(cdf::TimeFields*, PLARGE_INTEGER);
NTSYSAPI ULONGLONG NTAPI RtlGetSystemTimePrecise();
NTSYSAPI NTSTATUS NTAPI RtlQueryTimeZoneInformation(cdf::NativeTzi*);
NTSYSAPI NTSTATUS NTAPI RtlQueryDynamicTimeZoneInformation(cdf::NativeDynamicTzi*);
NTSYSAPI NTSTATUS NTAPI RtlSystemTimeToLocalTime(PLARGE_INTEGER, PLARGE_INTEGER);
NTSYSAPI VOID NTAPI RtlSetLastWin32Error(ULONG);
NTSYSAPI ULONG NTAPI RtlGetLastWin32Error();
NTSYSAPI NTSTATUS NTAPI LdrGetProcedureAddress(PVOID, const ANSI_STRING*, ULONG, PVOID*);
NTSYSAPI NTSTATUS NTAPI LdrGetProcedureAddressEx(PVOID, const ANSI_STRING*, ULONG, PVOID*, ULONG);
NTSYSAPI NTSTATUS NTAPI LdrGetProcedureAddressForCaller(PVOID, const ANSI_STRING*, ULONG, PVOID*, ULONG, PVOID);
}
