#pragma once
#include "time_native.h"
#include "time_zone_status.h"
#include <cstring>

namespace cdf::test {
struct Observation {
    BOOL loaded, query_found; DWORD query_result; CdfTimeZoneStatus status;
    ULONGLONG utc[5]; SYSTEMTIME local; TIME_ZONE_INFORMATION tzi; DWORD zone_result;
    DYNAMIC_TIME_ZONE_INFORMATION dynamic_tzi; DWORD dynamic_result;
    NativeTzi native_tzi; NativeDynamicTzi native_dynamic;
    NTSTATUS time_status, native_zone_status, native_dynamic_status, tod_status;
    TimeOfDay tod; DWORD last_error_before, last_error_after;
};
inline void Capture(Observation& out) {
    const HMODULE module = GetModuleHandleW(L"CdfTimeZone64.dll"); out.loaded = module != nullptr;
    if (module) {
        const FARPROC address = GetProcAddress(module, "CdfTimeZoneQueryStatus"); CdfTimeZoneQuery query = nullptr;
        std::memcpy(&query, &address, sizeof(query)); out.query_found = query != nullptr;
        if (query) out.query_result = query(&out.status, sizeof(out.status));
    }
    SetLastError(0xCDF12345); out.last_error_before = GetLastError();
    SYSTEMTIME system; FILETIME file; GetSystemTime(&system); SystemTimeToFileTime(&system, &file);
    out.utc[0] = (static_cast<ULONGLONG>(file.dwHighDateTime) << 32) | file.dwLowDateTime;
    GetSystemTimeAsFileTime(&file); out.utc[1] = (static_cast<ULONGLONG>(file.dwHighDateTime) << 32) | file.dwLowDateTime;
    GetSystemTimePreciseAsFileTime(&file); out.utc[2] = (static_cast<ULONGLONG>(file.dwHighDateTime) << 32) | file.dwLowDateTime;
    LARGE_INTEGER native; out.time_status = NtQuerySystemTime(&native); out.utc[3] = static_cast<ULONGLONG>(native.QuadPart);
    out.utc[4] = RtlGetSystemTimePrecise();
    GetLocalTime(&out.local); out.zone_result = GetTimeZoneInformation(&out.tzi);
    out.dynamic_result = GetDynamicTimeZoneInformation(&out.dynamic_tzi);
    out.native_zone_status = RtlQueryTimeZoneInformation(&out.native_tzi);
    out.native_dynamic_status = RtlQueryDynamicTimeZoneInformation(&out.native_dynamic);
    out.tod_status = NtQuerySystemInformation(static_cast<SYSTEM_INFORMATION_CLASS>(TimeInformationClass::TimeOfDay), &out.tod, sizeof(out.tod), nullptr);
    out.last_error_after = GetLastError();
}
}
