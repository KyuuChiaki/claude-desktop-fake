#include "verifier_abi.h"
#include "time_core.h"
#include "time_zone_status.h"
#include "locale_provider.h"
#include "runtime_provider.h"
#if defined(CDF_CLAUDE_IDENTITY_REQUIRED)
#include "claude_identity.h"
#endif
#include <intrin.h>

namespace {
cdf::Config config{};
cdf::Zone zone{};
DWORD state = 0, error_stage = 0, error_code = 0;
NTSTATUS native_error = 0;
bool initialized = false, active = false;
#if defined(CDF_CLAUDE_IDENTITY_REQUIRED)
bool identity_matched = false;
#endif
alignas(8) volatile LONG64 counters[CdfTimeHookCount]{};
alignas(8) volatile LONG64 bridge_counters[5]{};
cdf::verifier::DllDescriptor empty_dlls[] = {{}};
extern cdf::verifier::DllDescriptor dlls[];
void NTAPI ProviderDllLoaded(PWSTR name,PVOID address,SIZE_T size,PVOID reserved) {
    cdf::LocaleDllLoaded(name,address,size,reserved);
    cdf::RuntimeDllLoaded(name,address,size,reserved);
}
cdf::verifier::ProviderDescriptor provider = {
    sizeof(cdf::verifier::ProviderDescriptor), empty_dlls,
    ProviderDllLoaded, nullptr, nullptr, 0, 0, nullptr, nullptr, nullptr, nullptr};
void Count(CdfTimeHook hook) { _InterlockedIncrement64(&counters[hook]); }
// Keep descriptor prefix sizes tied to the diagnostic enum.
constexpr ULONG native_time_count=CdfSystemTimeToTzSpecificLocalTime-CdfNtQuerySystemTime;
constexpr ULONG base_time_count=CdfGetTimeZoneInformationForYear+1+CdfTimeHookCount-CdfSystemTimeToTzSpecificLocalTime;
extern cdf::verifier::ThunkDescriptor native_thunks[],base_thunks[],kernel_thunks[];
template<class Fn> Fn NativeOriginal(CdfTimeHook hook,Fn imported) {
    auto* address=native_thunks[hook-CdfNtQuerySystemTime].old_address;
    // Before Verifier resolves descriptors (during configuration parsing),
    // our own ntdll imports are the deliberately unredirected bootstrap path.
    return address ? reinterpret_cast<Fn>(address) : imported;
}
bool Now(LONGLONG& ticks, bool precise = false) {
    LARGE_INTEGER raw;
    if (precise) raw.QuadPart = static_cast<LONGLONG>(NativeOriginal(CdfRtlGetSystemTimePrecise,&RtlGetSystemTimePrecise)());
    else if (NativeOriginal(CdfNtQuerySystemTime,&NtQuerySystemTime)(&raw) < 0) return false;
    return cdf::AddTicks(raw.QuadPart, config.offset_ticks, ticks);
}
int CurrentYear() {
    LONGLONG now = 0, local = 0; SYSTEMTIME date{};
    if (!Now(now) || !cdf::UtcToLocal(zone, now, local) || !cdf::ToSystemTime(local, date)) return 0;
    return date.wYear;
}
DWORD CurrentZone(LONG* output_bias = nullptr) {
    LONGLONG now = 0; LONG bias = 0; DWORD id = TIME_ZONE_ID_INVALID;
    if (Now(now) && cdf::BiasAt(zone, now, bias, id)) {
        if (output_bias) *output_bias = bias;
        return id;
    }
    RtlSetLastWin32Error(ERROR_ARITHMETIC_OVERFLOW); return TIME_ZONE_ID_INVALID;
}
extern cdf::verifier::ThunkDescriptor base_thunks[];
template<class Fn> Fn Original(CdfTimeHook hook);

void WINAPI HookGetLocalTime(LPSYSTEMTIME output) {
    if (!active) return Original<decltype(&GetLocalTime)>(CdfGetLocalTime)(output);
    Count(CdfGetLocalTime); LONGLONG now = 0, local = 0;
    if (!output || !Now(now) || !cdf::UtcToLocal(zone, now, local) || !cdf::ToSystemTime(local, *output))
        Original<decltype(&GetLocalTime)>(CdfGetLocalTime)(output);
}
void WINAPI HookGetSystemTime(LPSYSTEMTIME output) {
    if (!active) return Original<decltype(&GetSystemTime)>(CdfGetSystemTime)(output);
    Count(CdfGetSystemTime); LONGLONG now = 0;
    if (!output || !Now(now) || !cdf::ToSystemTime(now, *output))
        Original<decltype(&GetSystemTime)>(CdfGetSystemTime)(output);
}
void WINAPI HookGetSystemTimeAsFileTime(LPFILETIME output) {
    if (!active) return Original<decltype(&GetSystemTimeAsFileTime)>(CdfGetSystemTimeAsFileTime)(output);
    Count(CdfGetSystemTimeAsFileTime); LONGLONG now = 0;
    if (output && Now(now)) cdf::ToFileTime(now, *output);
    else Original<decltype(&GetSystemTimeAsFileTime)>(CdfGetSystemTimeAsFileTime)(output);
}
void WINAPI HookGetSystemTimePreciseAsFileTime(LPFILETIME output) {
    if (!active) return Original<decltype(&GetSystemTimePreciseAsFileTime)>(CdfGetSystemTimePreciseAsFileTime)(output);
    Count(CdfGetSystemTimePreciseAsFileTime); LONGLONG now = 0;
    if (output && Now(now, true)) cdf::ToFileTime(now, *output);
    else Original<decltype(&GetSystemTimePreciseAsFileTime)>(CdfGetSystemTimePreciseAsFileTime)(output);
}
DWORD WINAPI HookGetTimeZoneInformation(LPTIME_ZONE_INFORMATION output) {
    if (!active) return Original<decltype(&GetTimeZoneInformation)>(CdfGetTimeZoneInformation)(output);
    Count(CdfGetTimeZoneInformation);
    if (!output) return Original<decltype(&GetTimeZoneInformation)>(CdfGetTimeZoneInformation)(output);
    const DWORD id = CurrentZone(); if (id == TIME_ZONE_ID_INVALID) return id;
    cdf::WinTzi(zone, CurrentYear(), *output); return id;
}
DWORD WINAPI HookGetDynamicTimeZoneInformation(PDYNAMIC_TIME_ZONE_INFORMATION output) {
    if (!active) return Original<decltype(&GetDynamicTimeZoneInformation)>(CdfGetDynamicTimeZoneInformation)(output);
    Count(CdfGetDynamicTimeZoneInformation);
    if (!output) return Original<decltype(&GetDynamicTimeZoneInformation)>(CdfGetDynamicTimeZoneInformation)(output);
    const DWORD id = CurrentZone(); if (id == TIME_ZONE_ID_INVALID) return id;
    cdf::WinDynamicTzi(zone, CurrentYear(), *output); return id;
}
BOOL WINAPI HookGetTimeZoneInformationForYear(USHORT year, PDYNAMIC_TIME_ZONE_INFORMATION explicit_zone, LPTIME_ZONE_INFORMATION output) {
    if (!active) return Original<decltype(&GetTimeZoneInformationForYear)>(CdfGetTimeZoneInformationForYear)(year, explicit_zone, output);
    Count(CdfGetTimeZoneInformationForYear);
    if (explicit_zone || !output)
        return Original<decltype(&GetTimeZoneInformationForYear)>(CdfGetTimeZoneInformationForYear)(year, explicit_zone, output);
    // The Windows yearly-rule lookup uses a signed 16-bit year internally.
    cdf::WinTzi(zone, static_cast<SHORT>(year), *output); return TRUE;
}
NTSTATUS NTAPI HookNtQuerySystemTime(PLARGE_INTEGER output) {
    if (!active) return NativeOriginal(CdfNtQuerySystemTime,&NtQuerySystemTime)(output);
    Count(CdfNtQuerySystemTime); const NTSTATUS status = NativeOriginal(CdfNtQuerySystemTime,&NtQuerySystemTime)(output);
    if (status >= 0) { LONGLONG adjusted = 0; if (cdf::AddTicks(output->QuadPart, config.offset_ticks, adjusted)) output->QuadPart = adjusted; }
    return status;
}
ULONGLONG NTAPI HookRtlGetSystemTimePrecise() {
    if (!active) return NativeOriginal(CdfRtlGetSystemTimePrecise,&RtlGetSystemTimePrecise)();
    Count(CdfRtlGetSystemTimePrecise); const ULONGLONG raw = NativeOriginal(CdfRtlGetSystemTimePrecise,&RtlGetSystemTimePrecise)(); LONGLONG adjusted = 0;
    return cdf::AddTicks(static_cast<LONGLONG>(raw), config.offset_ticks, adjusted) ? static_cast<ULONGLONG>(adjusted) : raw;
}
void NTAPI HookRtlTimeToTimeFields(PLARGE_INTEGER time, cdf::TimeFields* fields) {
    if (!active) return NativeOriginal(CdfRtlTimeToTimeFields,&RtlTimeToTimeFields)(time, fields);
    Count(CdfRtlTimeToTimeFields); NativeOriginal(CdfRtlTimeToTimeFields,&RtlTimeToTimeFields)(time, fields);
}
NTSTATUS NTAPI HookRtlQueryTimeZoneInformation(cdf::NativeTzi* output) {
    if (!active) return NativeOriginal(CdfRtlQueryTimeZoneInformation,&RtlQueryTimeZoneInformation)(output);
    Count(CdfRtlQueryTimeZoneInformation); const NTSTATUS status = NativeOriginal(CdfRtlQueryTimeZoneInformation,&RtlQueryTimeZoneInformation)(output);
    if (status >= 0) { TIME_ZONE_INFORMATION tzi; cdf::WinTzi(zone, CurrentYear(), tzi); cdf::ToNative(tzi, *output); }
    return status;
}
NTSTATUS NTAPI HookRtlQueryDynamicTimeZoneInformation(cdf::NativeDynamicTzi* output) {
    if (!active) return NativeOriginal(CdfRtlQueryDynamicTimeZoneInformation,&RtlQueryDynamicTimeZoneInformation)(output);
    Count(CdfRtlQueryDynamicTimeZoneInformation); const NTSTATUS status = NativeOriginal(CdfRtlQueryDynamicTimeZoneInformation,&RtlQueryDynamicTimeZoneInformation)(output);
    if (status >= 0) { DYNAMIC_TIME_ZONE_INFORMATION tzi; cdf::WinDynamicTzi(zone, CurrentYear(), tzi); cdf::NativeDynamic(tzi, *output); }
    return status;
}
NTSTATUS NTAPI HookNtQuerySystemInformation(SYSTEM_INFORMATION_CLASS information_class, PVOID output, ULONG size, PULONG returned) {
    if (!active) return NativeOriginal(CdfNtQuerySystemInformation,&NtQuerySystemInformation)(information_class, output, size, returned);
    Count(CdfNtQuerySystemInformation);
    const NTSTATUS status = NativeOriginal(CdfNtQuerySystemInformation,&NtQuerySystemInformation)(information_class, output, size, returned);
    if (status < 0 || !output) return status;
    const auto id = static_cast<cdf::TimeInformationClass>(information_class);
    // Class 93 is a set operation on the verified Windows kernel. Leave its
    // query result and probing/ReturnLength behavior entirely to Windows.
    if (id == cdf::TimeInformationClass::CurrentTimeZone && size >= sizeof(cdf::NativeTzi)) {
        TIME_ZONE_INFORMATION tzi; cdf::WinTzi(zone, CurrentYear(), tzi); cdf::ToNative(tzi, *static_cast<cdf::NativeTzi*>(output));
    } else if (id == cdf::TimeInformationClass::DynamicTimeZone && size >= sizeof(cdf::NativeDynamicTzi)) {
        DYNAMIC_TIME_ZONE_INFORMATION tzi; cdf::WinDynamicTzi(zone, CurrentYear(), tzi); cdf::NativeDynamic(tzi, *static_cast<cdf::NativeDynamicTzi*>(output));
    } else if (id == cdf::TimeInformationClass::TimeOfDay) {
        auto* value = static_cast<cdf::TimeOfDay*>(output); LONGLONG adjusted = 0;
        if (size >= 8 && cdf::AddTicks(value->boot.QuadPart, config.offset_ticks, adjusted)) value->boot.QuadPart = adjusted;
        if (size >= 16 && cdf::AddTicks(value->current.QuadPart, config.offset_ticks, adjusted)) value->current.QuadPart = adjusted;
        LONG bias = 0; const DWORD tz_id = CurrentZone(&bias);
        if (tz_id != TIME_ZONE_ID_INVALID) {
            if (size >= 24) value->bias.QuadPart = static_cast<LONGLONG>(bias) * cdf::ticks_minute;
            if (size >= 28) value->zone_id = tz_id;
        }
    }
    return status;
}
NTSTATUS NTAPI HookRtlSystemTimeToLocalTime(PLARGE_INTEGER input, PLARGE_INTEGER output) {
    if (!active) return NativeOriginal(CdfRtlSystemTimeToLocalTime,&RtlSystemTimeToLocalTime)(input, output);
    Count(CdfRtlSystemTimeToLocalTime);
    if (!input || !output) return NativeOriginal(CdfRtlSystemTimeToLocalTime,&RtlSystemTimeToLocalTime)(input, output);
    LONG bias = 0; LONGLONG adjusted = 0;
    if (CurrentZone(&bias) == TIME_ZONE_ID_INVALID || !cdf::AddTicks(input->QuadPart, -static_cast<LONGLONG>(bias) * cdf::ticks_minute, adjusted))
        return cdf::status_invalid_parameter;
    output->QuadPart = adjusted; return 0;
}
NTSTATUS NTAPI HookRtlLocalTimeToSystemTime(PLARGE_INTEGER input, PLARGE_INTEGER output) {
    if (!active) return NativeOriginal(CdfRtlLocalTimeToSystemTime,&RtlLocalTimeToSystemTime)(input, output);
    Count(CdfRtlLocalTimeToSystemTime);
    if (!input || !output) return NativeOriginal(CdfRtlLocalTimeToSystemTime,&RtlLocalTimeToSystemTime)(input, output);
    LONG bias = 0; LONGLONG adjusted = 0;
    if (CurrentZone(&bias) == TIME_ZONE_ID_INVALID || !cdf::AddTicks(input->QuadPart, static_cast<LONGLONG>(bias) * cdf::ticks_minute, adjusted))
        return cdf::status_invalid_parameter;
    output->QuadPart = adjusted; return 0;
}
BOOL Convert(const SYSTEMTIME* input, SYSTEMTIME* output, bool to_local) {
    LONGLONG ticks = 0, converted = 0;
    if (!input || !output || !cdf::ToTicks(*input, ticks) ||
        !(to_local ? cdf::UtcToLocal(zone, ticks, converted) : cdf::LocalToUtc(zone, ticks, converted)) || !cdf::ToSystemTime(converted, *output)) {
        RtlSetLastWin32Error(ERROR_INVALID_PARAMETER); return FALSE;
    }
    return TRUE;
}
BOOL WINAPI HookSystemTimeToTzSpecificLocalTime(const TIME_ZONE_INFORMATION* explicit_zone, const SYSTEMTIME* input, LPSYSTEMTIME output) {
    if (!active) return Original<decltype(&SystemTimeToTzSpecificLocalTime)>(CdfSystemTimeToTzSpecificLocalTime)(explicit_zone, input, output);
    Count(CdfSystemTimeToTzSpecificLocalTime);
    if (explicit_zone || !input || !output)
        return Original<decltype(&SystemTimeToTzSpecificLocalTime)>(CdfSystemTimeToTzSpecificLocalTime)(explicit_zone, input, output);
    return Convert(input, output, true);
}
BOOL WINAPI HookTzSpecificLocalTimeToSystemTime(const TIME_ZONE_INFORMATION* explicit_zone, const SYSTEMTIME* input, LPSYSTEMTIME output) {
    if (!active) return Original<decltype(&TzSpecificLocalTimeToSystemTime)>(CdfTzSpecificLocalTimeToSystemTime)(explicit_zone, input, output);
    Count(CdfTzSpecificLocalTimeToSystemTime);
    if (explicit_zone || !input || !output)
        return Original<decltype(&TzSpecificLocalTimeToSystemTime)>(CdfTzSpecificLocalTimeToSystemTime)(explicit_zone, input, output);
    return Convert(input, output, false);
}
BOOL WINAPI HookSystemTimeToTzSpecificLocalTimeEx(const DYNAMIC_TIME_ZONE_INFORMATION* explicit_zone, const SYSTEMTIME* input, LPSYSTEMTIME output) {
    if (!active) return Original<decltype(&SystemTimeToTzSpecificLocalTimeEx)>(CdfSystemTimeToTzSpecificLocalTimeEx)(explicit_zone, input, output);
    Count(CdfSystemTimeToTzSpecificLocalTimeEx);
    if (explicit_zone || !input || !output)
        return Original<decltype(&SystemTimeToTzSpecificLocalTimeEx)>(CdfSystemTimeToTzSpecificLocalTimeEx)(explicit_zone, input, output);
    return Convert(input, output, true);
}
BOOL WINAPI HookTzSpecificLocalTimeToSystemTimeEx(const DYNAMIC_TIME_ZONE_INFORMATION* explicit_zone, const SYSTEMTIME* input, LPSYSTEMTIME output) {
    if (!active) return Original<decltype(&TzSpecificLocalTimeToSystemTimeEx)>(CdfTzSpecificLocalTimeToSystemTimeEx)(explicit_zone, input, output);
    Count(CdfTzSpecificLocalTimeToSystemTimeEx);
    if (explicit_zone || !input || !output)
        return Original<decltype(&TzSpecificLocalTimeToSystemTimeEx)>(CdfTzSpecificLocalTimeToSystemTimeEx)(explicit_zone, input, output);
    return Convert(input, output, false);
}
BOOL FileConvert(const FILETIME* input, FILETIME* output, bool to_local) {
    LONG bias = 0; LONGLONG adjusted = 0;
    if (!input || !output || CurrentZone(&bias) == TIME_ZONE_ID_INVALID ||
        !cdf::AddTicks(cdf::FileTicks(*input), static_cast<LONGLONG>(bias) * cdf::ticks_minute * (to_local ? -1 : 1), adjusted)) {
        RtlSetLastWin32Error(ERROR_INVALID_PARAMETER); return FALSE;
    }
    cdf::ToFileTime(adjusted, *output); return TRUE;
}
BOOL WINAPI HookFileTimeToLocalFileTime(const FILETIME* input, LPFILETIME output) {
    if (!active) return Original<decltype(&FileTimeToLocalFileTime)>(CdfFileTimeToLocalFileTime)(input, output);
    Count(CdfFileTimeToLocalFileTime);
    if (!input || !output) return Original<decltype(&FileTimeToLocalFileTime)>(CdfFileTimeToLocalFileTime)(input, output);
    return FileConvert(input, output, true);
}
BOOL WINAPI HookLocalFileTimeToFileTime(const FILETIME* input, LPFILETIME output) {
    if (!active) return Original<decltype(&LocalFileTimeToFileTime)>(CdfLocalFileTimeToFileTime)(input, output);
    Count(CdfLocalFileTimeToFileTime);
    if (!input || !output) return Original<decltype(&LocalFileTimeToFileTime)>(CdfLocalFileTimeToFileTime)(input, output);
    return FileConvert(input, output, false);
}
BOOL WINAPI HookLocalFileTimeToLocalSystemTime(const TIME_ZONE_INFORMATION* explicit_zone, const FILETIME* input, SYSTEMTIME* output) {
    if (!active) return Original<decltype(&LocalFileTimeToLocalSystemTime)>(CdfLocalFileTimeToLocalSystemTime)(explicit_zone, input, output);
    Count(CdfLocalFileTimeToLocalSystemTime);
    if (explicit_zone || !input || !output)
        return Original<decltype(&LocalFileTimeToLocalSystemTime)>(CdfLocalFileTimeToLocalSystemTime)(explicit_zone, input, output);
    TIME_ZONE_INFORMATION current; cdf::WinTzi(zone, CurrentYear(), current);
    return Original<decltype(&LocalFileTimeToLocalSystemTime)>(CdfLocalFileTimeToLocalSystemTime)(&current, input, output);
}
BOOL WINAPI HookLocalSystemTimeToLocalFileTime(const TIME_ZONE_INFORMATION* explicit_zone, const SYSTEMTIME* input, FILETIME* output) {
    if (!active) return Original<decltype(&LocalSystemTimeToLocalFileTime)>(CdfLocalSystemTimeToLocalFileTime)(explicit_zone, input, output);
    Count(CdfLocalSystemTimeToLocalFileTime);
    if (explicit_zone || !input || !output)
        return Original<decltype(&LocalSystemTimeToLocalFileTime)>(CdfLocalSystemTimeToLocalFileTime)(explicit_zone, input, output);
    TIME_ZONE_INFORMATION current; cdf::WinTzi(zone, CurrentYear(), current);
    return Original<decltype(&LocalSystemTimeToLocalFileTime)>(CdfLocalSystemTimeToLocalFileTime)(&current, input, output);
}
extern cdf::verifier::ThunkDescriptor native_thunks[];
extern cdf::verifier::ThunkDescriptor kernel_thunks[];
PVOID RedirectTimeAddress(PVOID address) {
    // Verifier rewrites imports, but this Windows build returns raw export
    // addresses from dynamic lookup. Only redirect our known time targets.
    if (!address) return address;
    cdf::verifier::ThunkDescriptor* tables[]={native_thunks,base_thunks,kernel_thunks};
    for (auto* table:tables) for (auto* p=table;p->name;++p)
        if (p->old_address && address==p->old_address) return p->new_address;
    if(cdf::RuntimePrepared())for(auto* p=cdf::RuntimeComThunks();p->name;++p)
        if(p->old_address&&address==p->old_address)return p->new_address;
    address=cdf::RedirectRuntimeAddress(address);
    return address;
}
FARPROC WINAPI HookGetProcAddress(HMODULE module, LPCSTR name) {
    _InterlockedIncrement64(&bridge_counters[0]);
    const auto original = reinterpret_cast<decltype(&GetProcAddress)>(base_thunks[base_time_count].old_address);
    if (original) return reinterpret_cast<FARPROC>(RedirectTimeAddress(reinterpret_cast<PVOID>(original(module,name))));
    ANSI_STRING symbol{}; PVOID address=nullptr; const auto ordinal=reinterpret_cast<ULONG_PTR>(name);
    if (ordinal>0xffff) RtlInitAnsiString(&symbol,name);
    const NTSTATUS s=cdf::OriginalProcedure(module,ordinal>0xffff ? &symbol : nullptr,ordinal>0xffff ? 0 : static_cast<ULONG>(ordinal),&address);
    if (s<0) { RtlSetLastWin32Error(RtlNtStatusToDosError(s)); return nullptr; }
    return reinterpret_cast<FARPROC>(RedirectTimeAddress(address));
}
FARPROC WINAPI HookKernelGetProcAddress(HMODULE module, LPCSTR name) {
    _InterlockedIncrement64(&bridge_counters[1]);
    const auto original = reinterpret_cast<decltype(&GetProcAddress)>(kernel_thunks[0].old_address);
    if (original) return reinterpret_cast<FARPROC>(RedirectTimeAddress(reinterpret_cast<PVOID>(original(module,name))));
    ANSI_STRING symbol{}; PVOID address=nullptr; const auto ordinal=reinterpret_cast<ULONG_PTR>(name);
    if (ordinal>0xffff) RtlInitAnsiString(&symbol,name);
    const NTSTATUS s=cdf::OriginalProcedure(module,ordinal>0xffff ? &symbol : nullptr,ordinal>0xffff ? 0 : static_cast<ULONG>(ordinal),&address);
    if (s<0) { RtlSetLastWin32Error(RtlNtStatusToDosError(s)); return nullptr; }
    return reinterpret_cast<FARPROC>(RedirectTimeAddress(address));
}
NTSTATUS NTAPI HookLdrGetProcedureAddress(PVOID module, const ANSI_STRING* name, ULONG ordinal, PVOID* address) {
    _InterlockedIncrement64(&bridge_counters[2]);
    const auto original = native_thunks[native_time_count].old_address ? reinterpret_cast<decltype(&LdrGetProcedureAddress)>(native_thunks[native_time_count].old_address) : &LdrGetProcedureAddress;
    const NTSTATUS status = original(module, name, ordinal, address);
    if (status >= 0 && address) *address = RedirectTimeAddress(*address);
    return status;
}
NTSTATUS NTAPI HookLdrGetProcedureAddressEx(PVOID module, const ANSI_STRING* name, ULONG ordinal, PVOID* address, ULONG flags) {
    _InterlockedIncrement64(&bridge_counters[3]);
    const auto original = native_thunks[native_time_count+1].old_address ? reinterpret_cast<decltype(&LdrGetProcedureAddressEx)>(native_thunks[native_time_count+1].old_address) : &LdrGetProcedureAddressEx;
    const NTSTATUS status = original(module, name, ordinal, address, flags);
    if (status >= 0 && address) *address = RedirectTimeAddress(*address);
    return status;
}
NTSTATUS NTAPI HookLdrGetProcedureAddressForCaller(PVOID module, const ANSI_STRING* name, ULONG ordinal, PVOID* address, ULONG flags, PVOID caller) {
    _InterlockedIncrement64(&bridge_counters[4]);
    const auto original = native_thunks[native_time_count+2].old_address ? reinterpret_cast<decltype(&LdrGetProcedureAddressForCaller)>(native_thunks[native_time_count+2].old_address) : &LdrGetProcedureAddressForCaller;
    const NTSTATUS status = original(module, name, ordinal, address, flags, caller);
    if (status >= 0 && address) *address = RedirectTimeAddress(*address);
    return status;
}
#define THUNK(name) {const_cast<PCHAR>(#name), nullptr, reinterpret_cast<PVOID>(&Hook##name)}
cdf::verifier::ThunkDescriptor native_thunks[96] = {
    THUNK(NtQuerySystemTime), THUNK(RtlGetSystemTimePrecise), THUNK(RtlTimeToTimeFields),
    THUNK(RtlQueryTimeZoneInformation), THUNK(RtlQueryDynamicTimeZoneInformation), THUNK(NtQuerySystemInformation),
    THUNK(RtlSystemTimeToLocalTime), THUNK(RtlLocalTimeToSystemTime),
    THUNK(LdrGetProcedureAddress), THUNK(LdrGetProcedureAddressEx), THUNK(LdrGetProcedureAddressForCaller), {}};
cdf::verifier::ThunkDescriptor base_thunks[128] = {
    THUNK(GetLocalTime), THUNK(GetSystemTime), THUNK(GetSystemTimeAsFileTime), THUNK(GetSystemTimePreciseAsFileTime),
    THUNK(GetTimeZoneInformation), THUNK(GetDynamicTimeZoneInformation), THUNK(GetTimeZoneInformationForYear),
    THUNK(SystemTimeToTzSpecificLocalTime), THUNK(TzSpecificLocalTimeToSystemTime),
    THUNK(SystemTimeToTzSpecificLocalTimeEx), THUNK(TzSpecificLocalTimeToSystemTimeEx),
    THUNK(FileTimeToLocalFileTime), THUNK(LocalFileTimeToFileTime),
    THUNK(LocalFileTimeToLocalSystemTime), THUNK(LocalSystemTimeToLocalFileTime), THUNK(GetProcAddress), {}};
cdf::verifier::ThunkDescriptor kernel_thunks[128] = {
    {const_cast<PCHAR>("GetProcAddress"), nullptr, reinterpret_cast<PVOID>(&HookKernelGetProcAddress)}, {}};
#undef THUNK
cdf::verifier::DllDescriptor dlls[] = {
    {const_cast<PWSTR>(L"ntdll.dll"), 0, nullptr, native_thunks},
    {const_cast<PWSTR>(L"kernelbase.dll"), 0, nullptr, base_thunks},
    {const_cast<PWSTR>(L"kernel32.dll"), 0, nullptr, kernel_thunks},
    {const_cast<PWSTR>(L"combase.dll"), 0, nullptr, nullptr},
    {}};
template<class Fn> Fn Original(CdfTimeHook hook) {
    const ULONG index = hook <= CdfGetTimeZoneInformationForYear ? hook : hook - CdfSystemTimeToTzSpecificLocalTime + CdfGetTimeZoneInformationForYear+1;
    return reinterpret_cast<Fn>(base_thunks[index].old_address);
}
void Initialize() {
    if (initialized) return; initialized=true;
    error_stage=1;
    const bool parsed=cdf::ReadConfig(config,error_code,native_error);
    if(parsed&&!cdf::RuntimePreflight(config))return;
    cdf::PrepareLocale(config,error_code,native_error);
    if (!parsed) return;
    state|=4;
    if (config.enabled) {
        error_stage=2;
        if (cdf::LoadZone(config.zone_id,zone,error_code,native_error)) {
            error_stage=3; LONGLONG now=0,local=0; SYSTEMTIME date{};
            if (!Now(now) || !cdf::ToSystemTime(now,date) || !cdf::UtcToLocal(zone,now,local) || !cdf::ToSystemTime(local,date)) error_code=ERROR_ARITHMETIC_OVERFLOW;
            else { active=true; state|=8; error_stage=error_code=0; native_error=0; }
        }
    } else error_stage=0;
    if (cdf::LocalePrepared()) cdf::AppendLocaleThunks(base_thunks+base_time_count+1,kernel_thunks+1,native_thunks+native_time_count+3);
    cdf::PrepareRuntime(config,parsed,active);
    if(cdf::RuntimePrepared())cdf::AppendRuntimeThunks(base_thunks,kernel_thunks,native_thunks);
    if(cdf::RuntimePrepared())dlls[3].thunks=cdf::RuntimeComThunks();else dlls[3].name=nullptr;
    if (active || cdf::LocalePrepared()
        ||cdf::RuntimePrepared()
        ) provider.dlls=dlls;
}
}

extern "C" __declspec(dllexport) DWORD WINAPI CdfTimeZoneQueryStatus(CdfTimeZoneStatus* output, DWORD size) {
    if (!output || size != sizeof(*output)) return ERROR_INVALID_PARAMETER;
    cdf::Zero(output, sizeof(*output)); output->size = sizeof(*output); output->version = 1;
    output->state = state; output->verifier_flags = provider.verifier_flags;
    output->error_stage = error_stage; output->error_code = error_code; output->native_status = native_error;
    output->utc_offset_seconds = config.offset_seconds; cdf::CopyText(output->time_zone_id, 128, config.zone_id);
    if (active) {
        for (ULONG i = 0; i < native_time_count; ++i) if (native_thunks[i].old_address) ++output->resolved_hooks;
        for (ULONG i = 0; i < base_time_count; ++i) if (base_thunks[i].old_address) ++output->resolved_hooks;
        for (ULONG i = native_time_count; i < native_time_count+3; ++i) if (native_thunks[i].old_address) ++output->resolved_bridges;
        if (base_thunks[base_time_count].old_address) ++output->resolved_bridges;
        if (kernel_thunks[0].old_address) ++output->resolved_bridges;
        if (output->resolved_hooks == CdfTimeHookCount && output->resolved_bridges == 5) output->state |= 16;
    }
    for (DWORD i = 0; i < CdfTimeHookCount; ++i) output->calls[i] = static_cast<ULONGLONG>(_InterlockedCompareExchange64(&counters[i], 0, 0));
    for (DWORD i = 0; i < 5; ++i) output->bridge_calls[i] = static_cast<ULONGLONG>(_InterlockedCompareExchange64(&bridge_counters[i], 0, 0));
    return ERROR_SUCCESS;
}
extern "C" BOOL WINAPI CdfTimeZoneEntry(HINSTANCE, DWORD reason, LPVOID reserved) {
    if (reason == cdf::verifier::process_verifier) {
        if (!reserved) return FALSE;
        state |= 1;
#if defined(CDF_CLAUDE_IDENTITY_REQUIRED)
        identity_matched=cdf::claude::MatchesCurrentImage();
        if(!identity_matched&&cdf::claude::BlockUnverifiedImage())return FALSE;
        if (identity_matched) Initialize();
#else
        Initialize();
#endif
        *static_cast<cdf::verifier::ProviderDescriptor**>(reserved) = &provider;
    } else {
        if (reason==DLL_PROCESS_ATTACH) state|=2;
#if defined(CDF_CLAUDE_IDENTITY_REQUIRED)
        if (identity_matched) cdf::LocaleEvent(reason);
#else
        cdf::LocaleEvent(reason);
#endif
        cdf::RuntimeEvent(reason);
    }
    return TRUE;
}

namespace cdf {
bool VirtualLocalTime(SYSTEMTIME& output) {
    if (!active) return false;
    LONGLONG now=0,local=0;
    return Now(now) && UtcToLocal(zone,now,local) && ToSystemTime(local,output);
}
DWORD ProviderVerifierFlags() { return provider.verifier_flags; }
NTSTATUS OriginalProcedure(PVOID module,const ANSI_STRING* name,ULONG ordinal,PVOID* address) {
    const auto p=native_thunks[native_time_count].old_address;
    const auto raw=p ? reinterpret_cast<decltype(&LdrGetProcedureAddress)>(p) : &LdrGetProcedureAddress;
    return raw(module,name,ordinal,address);
}
}
