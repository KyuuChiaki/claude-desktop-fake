#include "time_observation.h"
#include "test_support.h"
#include <iostream>
#include <thread>
#include <atomic>
#include <ctime>
#include <mmsystem.h>
#include <algorithm>

extern "C" __declspec(dllimport) const cdf::test::Observation* WINAPI CdfEarlySnapshot();
namespace {
cdf::test::Observation tls{};
std::vector<std::string> failures;
void Check(bool ok, const std::string& message) { if (!ok) failures.push_back(message); }
void StatusJson(std::ostream& out, const CdfTimeZoneStatus& value) {
    out << "{\"state\":" << value.state << ",\"verifierFlags\":" << value.verifier_flags << ",\"resolvedHooks\":" << value.resolved_hooks
        << ",\"resolvedBridges\":" << value.resolved_bridges
        << ",\"errorStage\":" << value.error_stage << ",\"errorCode\":" << value.error_code << ",\"nativeStatus\":" << value.native_status
        << ",\"timeZoneId\":" << cdf::test::Json(std::wstring(value.time_zone_id)) << ",\"utcOffsetSeconds\":" << value.utc_offset_seconds << ",\"calls\":{";
    for (DWORD i = 0; i < CdfTimeHookCount; ++i) { if (i) out << ','; out << cdf::test::Json(std::string(cdf_time_hook_names[i])) << ':' << value.calls[i]; }
    out << "},\"bridgeCalls\":[";
    for (DWORD i = 0; i < 5; ++i) { if (i) out << ','; out << value.bridge_calls[i]; }
    out << "]}";
}
void ObservationJson(std::ostream& out, const cdf::test::Observation& value) {
    out << "{\"loaded\":" << (value.loaded ? "true" : "false") << ",\"queryFound\":" << (value.query_found ? "true" : "false") << ",\"status\":";
    StatusJson(out, value.status);
    out << ",\"utcTicks\":["; for (int i = 0; i < 5; ++i) { if (i) out << ','; out << value.utc[i]; }
    out << "],\"local\":"; cdf::test::PrintDate(out, value.local);
    out << ",\"zoneResult\":" << value.zone_result << ",\"bias\":" << value.tzi.Bias << ",\"standardBias\":" << value.tzi.StandardBias
        << ",\"daylightBias\":" << value.tzi.DaylightBias << ",\"dynamicKey\":" << cdf::test::Json(std::wstring(value.dynamic_tzi.TimeZoneKeyName))
        << ",\"nativeBias\":" << value.native_tzi.bias << ",\"nativeDynamicKey\":" << cdf::test::Json(std::wstring(value.native_dynamic.key_name))
        << ",\"timeOfDay\":{\"status\":" << value.tod_status << ",\"current\":" << value.tod.current.QuadPart << ",\"boot\":" << value.tod.boot.QuadPart
        << ",\"biasTicks\":" << value.tod.bias.QuadPart << ",\"zoneId\":" << value.tod.zone_id << "},\"lastErrorPreserved\":"
        << (value.last_error_before == value.last_error_after ? "true" : "false") << '}';
}
void CheckObservation(const cdf::test::Observation& value, const std::string& label, const std::wstring& expectation,
    const std::wstring& id, LONGLONG offset, const cdf::Zone& expected_zone) {
    if (expectation == L"absent") { Check(!value.loaded, label + " absent"); return; }
    Check(value.loaded && value.query_found && value.query_result == ERROR_SUCCESS, label + " diagnostic module");
    Check(value.status.verifier_flags == 0x80000000UL, label + " actual verifier flags");
    if (expectation == L"inactive") { Check((value.status.state & 8) == 0, label + " inactive"); return; }
    Check(value.status.state == 31 && value.status.resolved_hooks == CdfTimeHookCount && value.status.resolved_bridges == 5, label + " early ready");
    Check(id == value.status.time_zone_id && offset == value.status.utc_offset_seconds, label + " configuration");
    Check(_wcsicmp(id.c_str(), value.dynamic_tzi.TimeZoneKeyName) == 0 && _wcsicmp(id.c_str(), value.native_dynamic.key_name) == 0, label + " zone key");
    const auto bounds = std::minmax_element(std::begin(value.utc), std::end(value.utc));
    Check(*bounds.second - *bounds.first <= 100 * 10000ULL, label + " UTC sources within 100ms");
    LONGLONG local = 0, actual_local = 0;
    Check(cdf::UtcToLocal(expected_zone, static_cast<LONGLONG>(value.utc[0]), local) && cdf::ToTicks(value.local, actual_local) &&
        actual_local >= local - 100 * 10000LL && actual_local <= local + 100 * 10000LL, label + " local time");
    LONG bias = 0; DWORD zone_id = 0;
    Check(cdf::BiasAt(expected_zone, static_cast<LONGLONG>(value.utc[0]), bias, zone_id) && value.zone_result == zone_id && value.dynamic_result == zone_id, label + " DST result");
    SYSTEMTIME date{}; cdf::ToSystemTime(local, date); TIME_ZONE_INFORMATION expected{}; cdf::WinTzi(expected_zone, date.wYear, expected);
    Check(cdf::test::SameRule(expected, value.tzi), label + " Win32 rule");
    cdf::NativeTzi native{}; cdf::ToNative(expected, native);
    Check(std::memcmp(&native, &value.native_tzi, sizeof(native)) == 0, label + " native rule layout");
    Check(value.tod_status >= 0 && value.tod.bias.QuadPart == static_cast<LONGLONG>(bias) * cdf::ticks_minute && value.tod.zone_id == zone_id, label + " native time of day");
    Check(value.last_error_before == value.last_error_after, label + " LastError");
}
void Exercise(const cdf::Zone& expected_zone) {
    for (int year : {0,1,1600,1999,2006,2007,2024,2026,2038,2099,30828,65535}) {
        TIME_ZONE_INFORMATION actual{}, expected{}; cdf::WinTzi(expected_zone, static_cast<SHORT>(year), expected);
        Check(GetTimeZoneInformationForYear(static_cast<USHORT>(year), nullptr, &actual) && cdf::test::SameRule(actual, expected), "default year " + std::to_string(year));
    }
    DYNAMIC_TIME_ZONE_INFORMATION target{}, tokyo{};
    Check(cdf::test::FindZone(expected_zone.id, target), "target oracle found");
    Check(cdf::test::FindZone(L"Tokyo Standard Time", tokyo), "Tokyo oracle found");
    for (const SYSTEMTIME input : {SYSTEMTIME{2026,1,0,15,20,0,0,0}, SYSTEMTIME{2026,7,0,15,20,0,0,0},
        SYSTEMTIME{2006,3,0,20,12,0,0,0}, SYSTEMTIME{2024,2,0,29,23,59,59,999}, SYSTEMTIME{2026,1,0,1,0,0,0,0},
        SYSTEMTIME{2026,3,0,8,7,0,0,0}, SYSTEMTIME{2026,3,0,8,10,0,0,0}, SYSTEMTIME{2026,11,0,1,6,0,0,0}, SYSTEMTIME{2026,11,0,1,9,0,0,0}}) {
        SYSTEMTIME local{}, expected{}, basic{}, back{}, expected_back{}, tokyo_time{}, independent{};
        Check(SystemTimeToTzSpecificLocalTimeEx(&target, &input, &expected) && SystemTimeToTzSpecificLocalTimeEx(nullptr, &input, &local) &&
            cdf::test::SameDate(local, expected), "default Ex UTC/local");
        Check(SystemTimeToTzSpecificLocalTime(nullptr, &input, &basic) && cdf::test::SameDate(basic, expected), "default UTC/local");
        Check(TzSpecificLocalTimeToSystemTimeEx(&target, &local, &expected_back) && TzSpecificLocalTimeToSystemTimeEx(nullptr, &local, &back) &&
            cdf::test::SameDate(back, expected_back), "default Ex local/UTC");
        Check(TzSpecificLocalTimeToSystemTime(nullptr, &local, &back) && cdf::test::SameDate(back, expected_back), "default local/UTC");
        LONGLONG raw = 0; cdf::ToTicks(input, raw); LARGE_INTEGER value; value.QuadPart = raw; cdf::TimeFields fields;
        RtlTimeToTimeFields(&value, &fields);
        Check(fields.year == input.wYear && fields.month == input.wMonth && fields.day == input.wDay && fields.hour == input.wHour,
            "RtlTimeToTimeFields input is not shifted");
        Check(SystemTimeToTzSpecificLocalTimeEx(&tokyo, &input, &tokyo_time), "explicit Tokyo conversion");
        FILETIME source{}, converted{}, restored{}; SystemTimeToFileTime(&input, &source);
        TIME_ZONE_INFORMATION tokyo_plain{}; GetTimeZoneInformationForYear(input.wYear, &tokyo, &tokyo_plain);
        Check(SystemTimeToTzSpecificLocalTime(&tokyo_plain, &input, &independent) && cdf::test::SameDate(tokyo_time, independent), "explicit Tokyo unchanged");
        Check(FileTimeToLocalFileTime(&source, &converted) && LocalFileTimeToFileTime(&converted, &restored) &&
            cdf::FileTicks(source) == cdf::FileTicks(restored), "current-bias FILETIME roundtrip");
        SYSTEMTIME local_fields{}, expected_fields{}; FILETIME local_file{}, expected_file{};
        TIME_ZONE_INFORMATION current{}; GetTimeZoneInformation(&current);
        Check(LocalFileTimeToLocalSystemTime(nullptr, &converted, &local_fields) && LocalFileTimeToLocalSystemTime(&current, &converted, &expected_fields) &&
            cdf::test::SameDate(local_fields, expected_fields), "local FILETIME/SYSTEMTIME");
        Check(LocalSystemTimeToLocalFileTime(nullptr, &local_fields, &local_file) && LocalSystemTimeToLocalFileTime(&current, &local_fields, &expected_file) &&
            cdf::FileTicks(local_file) == cdf::FileTicks(expected_file), "local SYSTEMTIME/FILETIME");
        LARGE_INTEGER native_local{}, native_back{};
        Check(RtlSystemTimeToLocalTime(&value, &native_local) >= 0 && RtlLocalTimeToSystemTime(&native_local, &native_back) >= 0 && native_back.QuadPart == raw,
            "native current-bias conversion");
    }
    const HMODULE kernel = GetModuleHandleW(L"kernel32.dll"), base = GetModuleHandleW(L"kernelbase.dll"), nt = GetModuleHandleW(L"ntdll.dll");
    for (HMODULE module : {kernel, base}) {
        const auto local_fn = cdf::test::Resolve<decltype(&GetLocalTime)>(module, "GetLocalTime");
        const auto utc_fn = cdf::test::Resolve<decltype(&GetSystemTimeAsFileTime)>(module, "GetSystemTimeAsFileTime");
        const auto zone_fn = cdf::test::Resolve<decltype(&GetDynamicTimeZoneInformation)>(module, "GetDynamicTimeZoneInformation");
        Check(local_fn && utc_fn && zone_fn, "dynamic Win32 functions found");
        if (local_fn && utc_fn && zone_fn) {
            SYSTEMTIME local{}, utc{}, expected{}; FILETIME file{}; DYNAMIC_TIME_ZONE_INFORMATION dynamic{};
            utc_fn(&file); FileTimeToSystemTime(&file, &utc); local_fn(&local); zone_fn(&dynamic);
            LONGLONG local_ticks = 0, expected_ticks = 0; cdf::UtcToLocal(expected_zone, cdf::FileTicks(file), expected_ticks); cdf::ToTicks(local, local_ticks);
            Check(std::llabs(local_ticks - expected_ticks) < 100 * 10000LL && _wcsicmp(dynamic.TimeZoneKeyName, expected_zone.id) == 0, "dynamic Win32 functions hooked");
        }
    }
    const auto nt_fn = cdf::test::Resolve<decltype(&NtQuerySystemTime)>(nt, "NtQuerySystemTime");
    const auto precise_fn = cdf::test::Resolve<decltype(&RtlGetSystemTimePrecise)>(nt, "RtlGetSystemTimePrecise");
    LARGE_INTEGER dynamic_time{}; FILETIME win{}; GetSystemTimeAsFileTime(&win);
    Check(nt_fn && nt_fn(&dynamic_time) >= 0 && std::llabs(dynamic_time.QuadPart - cdf::FileTicks(win)) < 100 * 10000LL, "dynamic Native time hooked");
    Check(precise_fn && std::llabs(static_cast<LONGLONG>(precise_fn()) - cdf::FileTicks(win)) < 100 * 10000LL, "dynamic precise time hooked");
    ANSI_STRING name{}; char nt_name[] = "NtQuerySystemTime";
    name.Buffer = nt_name; name.Length = sizeof(nt_name)-1; name.MaximumLength = sizeof(nt_name);
    for (int resolver = 0; resolver < 3; ++resolver) {
        PVOID address = nullptr; NTSTATUS result;
        SetLastError(0xC0DF1234);
        if (resolver == 0) result = LdrGetProcedureAddress(nt, &name, 0, &address);
        else if (resolver == 1) result = LdrGetProcedureAddressEx(nt, &name, 0, &address, 0);
        else result = LdrGetProcedureAddressForCaller(nt, &name, 0, &address, 0, reinterpret_cast<PVOID>(&Exercise));
        Check(result >= 0 && address && GetLastError() == 0xC0DF1234, "Native resolver status/LastError");
        const auto fn = reinterpret_cast<decltype(&NtQuerySystemTime)>(address);
        Check(fn && fn(&dynamic_time) >= 0 && std::llabs(dynamic_time.QuadPart - cdf::FileTicks(win)) < 100 * 10000LL, "Native resolver time redirection");
    }
    const auto bytes = reinterpret_cast<const BYTE*>(nt);
    const auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(bytes);
    const auto headers = reinterpret_cast<const IMAGE_NT_HEADERS64*>(bytes + dos->e_lfanew);
    const auto exports = reinterpret_cast<const IMAGE_EXPORT_DIRECTORY*>(bytes + headers->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress);
    const auto names = reinterpret_cast<const DWORD*>(bytes + exports->AddressOfNames);
    const auto ordinals = reinterpret_cast<const WORD*>(bytes + exports->AddressOfNameOrdinals);
    WORD ordinal = 0;
    for (DWORD i = 0; i < exports->NumberOfNames; ++i)
        if (std::strcmp(reinterpret_cast<const char*>(bytes + names[i]), nt_name) == 0) ordinal = static_cast<WORD>(exports->Base + ordinals[i]);
    const auto ordinal_fn = cdf::test::Resolve<decltype(&NtQuerySystemTime)>(nt, MAKEINTRESOURCEA(ordinal));
    Check(ordinal && ordinal_fn && ordinal_fn(&dynamic_time) >= 0 && std::llabs(dynamic_time.QuadPart - cdf::FileTicks(win)) < 100 * 10000LL, "ordinal lookup time redirection");
    Check(cdf::test::Resolve<decltype(&GetTickCount64)>(kernel, "GetTickCount64") == &GetTickCount64, "unrelated export unchanged");
    SetLastError(0);
    Check(GetProcAddress(nt, "CdfMissingExport") == nullptr && GetLastError() == ERROR_PROC_NOT_FOUND, "resolver failure behavior");
    cdf::NativeTzi native{}; cdf::NativeDynamicTzi native_dynamic{};
    Check(NtQuerySystemInformation(static_cast<SYSTEM_INFORMATION_CLASS>(cdf::TimeInformationClass::CurrentTimeZone), &native, sizeof(native), nullptr) >= 0 && native.bias == expected_zone.base.bias, "native class 44");
    Check(NtQuerySystemInformation(static_cast<SYSTEM_INFORMATION_CLASS>(cdf::TimeInformationClass::DynamicTimeZone), &native_dynamic, sizeof(native_dynamic), nullptr) >= 0 &&
        _wcsicmp(native_dynamic.key_name, expected_zone.id) == 0, "native class 102");
    _tzset(); const __time64_t now = _time64(nullptr); tm local_tm{}, utc_tm{}; SYSTEMTIME utc_fields{}, local_fields{};
    GetSystemTimeAsFileTime(&win);
    Check(std::llabs(now - (cdf::FileTicks(win)/cdf::ticks_second - 11644473600LL)) <= 1, "UCRT UTC offset applied once");
    _gmtime64_s(&utc_tm, &now); _localtime64_s(&local_tm, &now);
    utc_fields.wYear=static_cast<WORD>(utc_tm.tm_year+1900); utc_fields.wMonth=static_cast<WORD>(utc_tm.tm_mon+1); utc_fields.wDay=static_cast<WORD>(utc_tm.tm_mday);
    utc_fields.wHour=static_cast<WORD>(utc_tm.tm_hour); utc_fields.wMinute=static_cast<WORD>(utc_tm.tm_min); utc_fields.wSecond=static_cast<WORD>(utc_tm.tm_sec);
    Check(SystemTimeToTzSpecificLocalTimeEx(&target, &utc_fields, &local_fields) && local_tm.tm_hour == local_fields.wHour &&
        local_tm.tm_mday == local_fields.wDay && local_tm.tm_mon+1 == local_fields.wMonth, "UCRT localtime/gmtime");
    std::atomic<unsigned> bad{0}; std::vector<std::thread> workers;
    for (int i = 0; i < 8; ++i) workers.emplace_back([&] {
        for (int iteration = 0; iteration < 1000; ++iteration) {
            DYNAMIC_TIME_ZONE_INFORMATION dynamic{}; FILETIME sample{}; GetSystemTimePreciseAsFileTime(&sample);
            if (GetDynamicTimeZoneInformation(&dynamic) == TIME_ZONE_ID_INVALID || _wcsicmp(dynamic.TimeZoneKeyName, expected_zone.id) != 0) ++bad;
        }
    });
    for (auto& worker : workers) worker.join(); Check(bad == 0, "8-thread queries");
}
void PrintContracts(std::ostream& out) {
    bool first = true; out << '[';
    for (ULONG cls : {0UL,3UL,44UL,93UL,102UL,65535UL}) for (ULONG size : {0UL,1UL,8UL,16UL,47UL,48UL,171UL,172UL,431UL,432UL}) {
        alignas(8) BYTE buffer[512]; std::memset(buffer, 0xA5, sizeof(buffer)); ULONG returned = 0xFEFEFEFE;
        const NTSTATUS result = NtQuerySystemInformation(static_cast<SYSTEM_INFORMATION_CLASS>(cls), buffer, size, &returned);
        bool canary = true; for (ULONG i = size; i < sizeof(buffer); ++i) if (buffer[i] != 0xA5) canary = false;
        Check(canary, "native query buffer boundary");
        if (!first) out << ','; first = false;
        out << "{\"class\":" << cls << ",\"size\":" << size << ",\"status\":" << result << ",\"returned\":" << returned << ",\"canary\":" << (canary ? "true" : "false") << '}';
    }
    out << ']';
}
void PrintClass93Contracts(std::ostream& out) {
    const auto resolved = cdf::test::Resolve<decltype(&NtQuerySystemInformation)>(GetModuleHandleW(L"ntdll.dll"), "NtQuerySystemInformation");
    Check(resolved != nullptr, "class 93 dynamic query export");
    bool first = true; out << '[';
    for (bool dynamic : {false, true}) for (unsigned mode : {0U, 1U, 2U})
        for (bool with_length : {false, true}) for (ULONG size : {0UL, 1UL, 171UL, 172UL, 173UL, 432UL, 4096UL}) {
            alignas(8) BYTE storage[4112]; std::memset(storage, 0xA5, sizeof(storage));
            const unsigned offset = mode == 1 ? 1U : 0U;
            PVOID buffer = mode == 2 ? nullptr : storage + offset;
            ULONG returned = 0xFEFEFEFE;
            const auto query = dynamic && resolved ? resolved : &NtQuerySystemInformation;
            SetLastError(0xCDF19301);
            const NTSTATUS status = query(static_cast<SYSTEM_INFORMATION_CLASS>(cdf::TimeInformationClass::TimeZone), buffer, size, with_length ? &returned : nullptr);
            const DWORD last_error = GetLastError();
            bool untouched = true, canary = true;
            for (ULONG i = 0; i < sizeof(storage); ++i) if (storage[i] != 0xA5) {
                untouched = false;
                if (!buffer || i < offset || i >= offset + size) canary = false;
            }
            Check(canary, "class 93 query buffer boundary");
            Check(last_error == 0xCDF19301, "class 93 query LastError");
            if (status == cdf::status_invalid_info_class)
                Check(untouched && returned == 0xFEFEFEFE, "unsupported class 93 preserves output and ReturnLength");
            if (!first) out << ','; first = false;
            out << "{\"class\":93,\"size\":" << size << ",\"call\":\"" << (dynamic ? "GetProcAddress" : "import")
                << "\",\"buffer\":\"" << (mode == 0 ? "aligned" : mode == 1 ? "unaligned" : "null")
                << "\",\"returnLengthSupplied\":" << (with_length ? "true" : "false") << ",\"status\":" << status << ",\"returned\":";
            if (with_length) out << returned; else out << "null";
            out << ",\"bufferUnchanged\":" << (untouched ? "true" : "false") << ",\"canary\":" << (canary ? "true" : "false")
                << ",\"lastError\":" << last_error << '}';
        }
    out << ']';
}
}
extern "C" void NTAPI CdfTimeProbeTls(PVOID, DWORD reason, PVOID) { if (reason == DLL_PROCESS_ATTACH) cdf::test::Capture(tls); }
#pragma section(".CRT$XLB", long, read)
extern "C" __declspec(allocate(".CRT$XLB")) PIMAGE_TLS_CALLBACK cdf_time_tls = CdfTimeProbeTls;
#pragma comment(linker, "/INCLUDE:_tls_used")
#pragma comment(linker, "/INCLUDE:cdf_time_tls")

int wmain(int argc, WCHAR** argv) {
    std::wstring expectation, id, late_path; LONGLONG offset = 0; bool wait_input = false;
    for (int i = 1; i < argc; ++i) {
        const std::wstring arg(argv[i]);
        if (arg == L"--expect" && i+1 < argc) expectation = argv[++i];
        else if (arg == L"--zone" && i+1 < argc) id = argv[++i];
        else if (arg == L"--offset" && i+1 < argc) offset = _wcstoi64(argv[++i], nullptr, 10);
        else if (arg == L"--late" && i+1 < argc) late_path = argv[++i];
        else if (arg == L"--wait-for-input") wait_input = true;
        else return 2;
    }
    if (expectation != L"active" && expectation != L"inactive" && expectation != L"absent") return 2;
    static cdf::Zone expected_zone; DWORD error = 0; NTSTATUS status = 0;
    if (expectation == L"active") Check(cdf::LoadZone(id.c_str(), expected_zone, error, status), "expected zone loaded");
    cdf::test::Observation main{}; cdf::test::Capture(main);
    if (wait_input) {
        std::cout << "{\"ready\":true,\"processId\":" << GetCurrentProcessId() << "}\n" << std::flush;
        std::string command; std::getline(std::cin, command);
    }
    const auto early = *CdfEarlySnapshot();
    CheckObservation(early, "DLL attach", expectation, id, offset, expected_zone);
    CheckObservation(tls, "TLS", expectation, id, offset, expected_zone);
    CheckObservation(main, "main", expectation, id, offset, expected_zone);
    const HMODULE provider_module = GetModuleHandleW(L"CdfTimeZone64.dll");
    const std::wstring module_path = provider_module ? cdf::test::ModulePath(provider_module) : L"";
    if (expectation != L"absent") {
        WCHAR system[MAX_PATH]; GetSystemDirectoryW(system, MAX_PATH);
        Check(_wcsicmp(module_path.c_str(), (std::wstring(system) + L"\\CdfTimeZone64.dll").c_str()) == 0, "System32 deployment path");
    }
    if (expectation == L"active") Exercise(expected_zone);
    cdf::test::Observation late{}; HMODULE late_module = nullptr;
    if (!late_path.empty()) {
        late_module = LoadLibraryW(late_path.c_str()); Check(late_module != nullptr, "late consumer loaded");
        using Query = const cdf::test::Observation*(WINAPI*)();
        const auto query = late_module ? cdf::test::Resolve<Query>(late_module, "CdfLateSnapshot") : nullptr;
        Check(query != nullptr, "late consumer export");
        if (query) { late = *query(); CheckObservation(late, "late DLL", expectation, id, offset, expected_zone); }
    }
    LARGE_INTEGER frequency{}, qpc_before{}, qpc_after{}; QueryPerformanceFrequency(&frequency); QueryPerformanceCounter(&qpc_before);
    const ULONGLONG tick_before = GetTickCount64(); const DWORD tick32_before = GetTickCount(), mm_before = timeGetTime();
    FILETIME clock_before{}, clock_after{}; GetSystemTimePreciseAsFileTime(&clock_before);
    Sleep(150);
    QueryPerformanceCounter(&qpc_after); GetSystemTimePreciseAsFileTime(&clock_after);
    const ULONGLONG tick_elapsed = GetTickCount64() - tick_before;
    const DWORD tick32_elapsed = GetTickCount() - tick32_before, mm_elapsed = timeGetTime() - mm_before;
    const LONGLONG qpc_ms = (qpc_after.QuadPart - qpc_before.QuadPart) * 1000 / frequency.QuadPart;
    const LONGLONG clock_ms = (cdf::FileTicks(clock_after) - cdf::FileTicks(clock_before)) / 10000;
    Check(qpc_ms >= 100 && std::llabs(clock_ms - qpc_ms) < 100 && std::llabs(static_cast<LONGLONG>(tick_elapsed) - qpc_ms) < 100 &&
        std::llabs(static_cast<LONGLONG>(tick32_elapsed) - qpc_ms) < 100 && std::llabs(static_cast<LONGLONG>(mm_elapsed) - qpc_ms) < 100, "real timer rates");
    std::ostringstream contracts; PrintContracts(contracts);
    std::ostringstream class93_contracts; PrintClass93Contracts(class93_contracts);
    CdfTimeZoneStatus final_status{};
    if (provider_module) {
        const auto query = cdf::test::Resolve<CdfTimeZoneQuery>(provider_module, "CdfTimeZoneQueryStatus");
        if (query) query(&final_status, sizeof(final_status));
        if (expectation == L"active") for (DWORD i = 0; i < CdfTimeHookCount; ++i) Check(final_status.calls[i] > 0, std::string("hook hit: ")+cdf_time_hook_names[i]);
    }
    std::cout << "{\"matched\":" << (failures.empty() ? "true" : "false") << ",\"processId\":" << GetCurrentProcessId()
        << ",\"expected\":" << cdf::test::Json(expectation) << ",\"modulePath\":" << cdf::test::Json(module_path) << ",\"early\":";
    ObservationJson(std::cout, early); std::cout << ",\"tls\":"; ObservationJson(std::cout, tls); std::cout << ",\"main\":"; ObservationJson(std::cout, main);
    std::cout << ",\"late\":"; ObservationJson(std::cout, late); std::cout << ",\"finalStatus\":"; StatusJson(std::cout, final_status);
    std::cout << ",\"timers\":{\"qpcMs\":" << qpc_ms << ",\"clockMs\":" << clock_ms << ",\"tickMs\":" << tick_elapsed << ",\"tick32Ms\":" << tick32_elapsed
        << ",\"timeGetTimeMs\":" << mm_elapsed << ",\"tickCount64\":" << GetTickCount64() << "},\"queryContracts\":";
    std::cout << contracts.str();
    std::cout << ",\"class93Contracts\":" << class93_contracts.str();
    std::cout << ",\"failures\":[";
    for (size_t i = 0; i < failures.size(); ++i) { if (i) std::cout << ','; std::cout << cdf::test::Json(failures[i]); }
    std::cout << "]}\n";
    if (late_module) FreeLibrary(late_module);
    return failures.empty() ? 0 : 1;
}
