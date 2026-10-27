#pragma once
#include <Windows.h>

enum CdfTimeHook : DWORD {
    CdfGetLocalTime, CdfGetSystemTime, CdfGetSystemTimeAsFileTime,
    CdfGetSystemTimePreciseAsFileTime, CdfGetTimeZoneInformation,
    CdfGetDynamicTimeZoneInformation, CdfGetTimeZoneInformationForYear,
    CdfNtQuerySystemTime, CdfRtlGetSystemTimePrecise, CdfRtlTimeToTimeFields,
    CdfRtlQueryTimeZoneInformation, CdfRtlQueryDynamicTimeZoneInformation,
    CdfNtQuerySystemInformation, CdfRtlSystemTimeToLocalTime, CdfRtlLocalTimeToSystemTime,
    CdfSystemTimeToTzSpecificLocalTime, CdfTzSpecificLocalTimeToSystemTime,
    CdfSystemTimeToTzSpecificLocalTimeEx, CdfTzSpecificLocalTimeToSystemTimeEx,
    CdfFileTimeToLocalFileTime, CdfLocalFileTimeToFileTime,
    CdfLocalFileTimeToLocalSystemTime, CdfLocalSystemTimeToLocalFileTime,
    CdfTimeHookCount
};
inline constexpr const char* cdf_time_hook_names[CdfTimeHookCount] = {
    "GetLocalTime", "GetSystemTime", "GetSystemTimeAsFileTime", "GetSystemTimePreciseAsFileTime",
    "GetTimeZoneInformation", "GetDynamicTimeZoneInformation", "GetTimeZoneInformationForYear",
    "NtQuerySystemTime", "RtlGetSystemTimePrecise", "RtlTimeToTimeFields",
    "RtlQueryTimeZoneInformation", "RtlQueryDynamicTimeZoneInformation", "NtQuerySystemInformation",
    "RtlSystemTimeToLocalTime", "RtlLocalTimeToSystemTime", "SystemTimeToTzSpecificLocalTime",
    "TzSpecificLocalTimeToSystemTime", "SystemTimeToTzSpecificLocalTimeEx", "TzSpecificLocalTimeToSystemTimeEx",
    "FileTimeToLocalFileTime", "LocalFileTimeToFileTime", "LocalFileTimeToLocalSystemTime", "LocalSystemTimeToLocalFileTime"
};
struct CdfTimeZoneStatus {
    DWORD size, version, state, verifier_flags;
    DWORD error_stage, error_code; LONG native_status; DWORD resolved_hooks;
    LONGLONG utc_offset_seconds;
    WCHAR time_zone_id[128];
    ULONGLONG calls[CdfTimeHookCount];
    DWORD resolved_bridges, reserved;
    ULONGLONG bridge_calls[5];
};
// State: 1 handshake, 2 attach, 4 valid configuration, 8 enabled snapshot,
// 16 all 23 time thunks and 5 address resolver bridges resolved. Ready = 31.
static_assert(sizeof(CdfTimeZoneStatus) == 528);
using CdfTimeZoneQuery = DWORD(WINAPI*)(CdfTimeZoneStatus*, DWORD);
