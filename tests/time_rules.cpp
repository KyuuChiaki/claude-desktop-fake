#include "test_support.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <climits>

namespace {
unsigned checks = 0;
std::vector<std::string> failures;
void Check(bool ok, const std::string& label) { ++checks; if (!ok) failures.push_back(label); }
std::string Read(const WCHAR* path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) return {};
    return std::string(std::istreambuf_iterator<char>(file), {});
}
bool Validate(const char* data, ULONG size, cdf::Config& config, DWORD& error) {
    if (!cdf::ParseConfig(data, size, config, error)) return false;
    static cdf::Zone zone; NTSTATUS status = 0;
    if (!cdf::LoadZone(config.zone_id, zone, error, status)) return false;
    LARGE_INTEGER now; SYSTEMTIME output; LONGLONG adjusted = 0, local = 0;
    if (NtQuerySystemTime(&now) < 0 || !cdf::AddTicks(now.QuadPart, config.offset_ticks, adjusted) || !cdf::ToSystemTime(adjusted, output) ||
        !cdf::UtcToLocal(zone, adjusted, local) || !cdf::ToSystemTime(local, output)) {
        error = ERROR_ARITHMETIC_OVERFLOW; return false;
    }
    if (config.schema_version>=2 && !cdf::ValidateLocale(config.locale,error,status)) return false;
    if (config.schema_version==3 && !cdf::ValidateRegion(config.region,error)) return false;
    return true;
}
void ParserTests() {
    const char* valid = "{\"schemaVersion\":1,\"enabled\":true,\"timeZoneId\":\"Pacific Standard Time\",\"utcOffsetSeconds\":-3600}";
    cdf::Config config; DWORD error = 0;
    Check(cdf::ParseConfig(valid, static_cast<ULONG>(std::strlen(valid)), config, error) && config.enabled && config.offset_ticks == -3600 * cdf::ticks_second, "valid JSON");
    const std::string input(valid);
    std::vector<std::string> invalid = {
        "", "{}", "[]", input + " true", input + input,
        "{\"schemaVersion\":1 \"enabled\":true,\"timeZoneId\":\"UTC\",\"utcOffsetSeconds\":0}",
        "{\"schemaVersion\":1,\"enabled\":true,\"timeZoneId\":\"UTC\",\"utcOffsetSeconds\":0,}",
        "{\"schemaVersion\":1,\"schemaVersion\":1,\"timeZoneId\":\"UTC\",\"utcOffsetSeconds\":0}",
        "{\"schemaVersion\":1,\"enabled\":1,\"timeZoneId\":\"UTC\",\"utcOffsetSeconds\":0}",
        "{\"schemaVersion\":2,\"enabled\":true,\"timeZoneId\":\"UTC\",\"utcOffsetSeconds\":0}",
        "{\"schemaVersion\":1,\"enabled\":true,\"timeZoneId\":\"UTC\",\"utcOffsetSeconds\":1.5}",
        "{\"schemaVersion\":1,\"enabled\":true,\"timeZoneId\":\"UTC\",\"utcOffsetSeconds\":01}",
        "{\"schemaVersion\":1,\"enabled\":true,\"timeZoneId\":\"UTC\",\"utcOffsetSeconds\":9223372036854775807}",
        "{\"schemaVersion\":1,\"enabled\":true,\"timeZoneId\":\"UTC\",\"utcOffsetSeconds\":-9223372036854775808}",
        "{\"schemaVersion\":1,\"enabled\":true,\"timeZoneId\":\"\",\"utcOffsetSeconds\":0}",
        "{\"schemaVersion\":1,\"enabled\":true,\"timeZoneId\":\"UTC\\\\Other\",\"utcOffsetSeconds\":0}"
    };
    for (size_t i = 0; i < invalid.size(); ++i)
        Check(!cdf::ParseConfig(invalid[i].data(), static_cast<ULONG>(invalid[i].size()), config, error), "invalid JSON " + std::to_string(i));
    const std::string bom = std::string("\xEF\xBB\xBF") + valid;
    Check(cdf::ParseConfig(bom.data(), static_cast<ULONG>(bom.size()), config, error), "UTF-8 BOM");
    LONGLONG out = 0;
    Check(!cdf::AddTicks(0, -1, out) && !cdf::AddTicks(cdf::max_ticks, 1, out), "checked tick arithmetic");
}
void ZoneTests() {
    const WCHAR* ids[] = {L"Pacific Standard Time", L"Eastern Standard Time", L"UTC", L"India Standard Time", L"W. Europe Standard Time", L"Lord Howe Standard Time"};
    static cdf::Zone zone;
    for (const WCHAR* id : ids) {
        DWORD error = 0; NTSTATUS status = 0; DYNAMIC_TIME_ZONE_INFORMATION reference{};
        const std::string label = cdf::test::Utf8(id);
        const bool loaded = cdf::LoadZone(id, zone, error, status) && cdf::test::FindZone(id, reference);
        Check(loaded, label + " load"); if (!loaded) continue;
        for (int year : {0, 1, 1600, 1999, 2006, 2007, 2024, 2026, 2038, 2099, 30828, 65535}) {
            TIME_ZONE_INFORMATION expected{}, actual{};
            Check(GetTimeZoneInformationForYear(static_cast<USHORT>(year), &reference, &expected) != FALSE, label + " oracle year");
            cdf::WinTzi(zone, static_cast<SHORT>(year), actual);
            Check(cdf::test::SameRule(actual, expected), label + " yearly rule " + std::to_string(year));
            if (year < 1601 || year > 30827) continue;
            for (int month = 1; month <= 12; ++month) {
                SYSTEMTIME utc{static_cast<WORD>(year), static_cast<WORD>(month), 0, 15, 20, 0, 0, 0};
                SYSTEMTIME win{}, own{}, reverse{}; LONGLONG ticks = 0, local = 0, restored = 0;
                const bool ok = cdf::ToTicks(utc, ticks) && cdf::UtcToLocal(zone, ticks, local) && cdf::ToSystemTime(local, own) &&
                    SystemTimeToTzSpecificLocalTimeEx(&reference, &utc, &win);
                Check(ok && cdf::test::SameDate(win, own), label + " UTC/local " + std::to_string(year) + "/" + std::to_string(month));
                Check(cdf::LocalToUtc(zone, local, restored) && cdf::ToSystemTime(restored, reverse) && restored == ticks,
                    label + " local/UTC roundtrip");
            }
        }
        for (const SYSTEMTIME utc : {
                SYSTEMTIME{2026,3,0,8,6,59,59,0}, SYSTEMTIME{2026,3,0,8,7,0,0,0},
                SYSTEMTIME{2026,3,0,8,9,59,59,0}, SYSTEMTIME{2026,3,0,8,10,0,0,0},
                SYSTEMTIME{2026,11,0,1,5,59,59,0}, SYSTEMTIME{2026,11,0,1,6,0,0,0},
                SYSTEMTIME{2026,11,0,1,8,59,59,0}, SYSTEMTIME{2026,11,0,1,9,0,0,0},
                SYSTEMTIME{2024,2,0,29,23,59,59,999}, SYSTEMTIME{2026,1,0,1,0,0,0,0}}) {
            SYSTEMTIME win{}, own{}; LONGLONG ticks = 0, local = 0;
            Check(cdf::ToTicks(utc, ticks) && cdf::UtcToLocal(zone, ticks, local) && cdf::ToSystemTime(local, own) &&
                SystemTimeToTzSpecificLocalTimeEx(&reference, &utc, &win) && cdf::test::SameDate(win, own), label + " transition/boundary");
        }
        if (_wcsicmp(id, L"Pacific Standard Time") == 0 || _wcsicmp(id, L"Eastern Standard Time") == 0) {
            for (const SYSTEMTIME local : {SYSTEMTIME{2026,11,0,1,1,30,0,0}, SYSTEMTIME{2026,3,0,8,2,30,0,0}}) {
                LONGLONG ticks = 0, own = 0, expected = 0; SYSTEMTIME win{};
                cdf::ToTicks(local, ticks);
                const bool win_ok = TzSpecificLocalTimeToSystemTimeEx(&reference, &local, &win) != FALSE;
                const bool own_ok = cdf::LocalToUtc(zone, ticks, own);
                if (win_ok) cdf::ToTicks(win, expected);
                Check(win_ok == own_ok && (!win_ok || expected == own), label + " repeated/missing local hour=" + std::to_string(local.wMonth) +
                    " windows=" + std::to_string(win_ok) + "/" + std::to_string(expected) + " actual=" + std::to_string(own_ok) + "/" + std::to_string(own));
            }
        }
    }
}
}
int wmain(int argc, WCHAR** argv) {
    if (argc == 3 && std::wstring(argv[1]) == L"--validate-config") {
        const std::string input = Read(argv[2]); cdf::Config config{}; DWORD error = 0;
        const bool ok = Validate(input.data(), static_cast<ULONG>(input.size()), config, error);
        std::cout << "{\"valid\":" << (ok ? "true" : "false") << ",\"error\":" << error
            << ",\"configVersion\":" << config.schema_version << ",\"formatLocale\":" << cdf::test::Json(std::wstring(config.locale.format_locale))
            << ",\"uiLanguage\":" << cdf::test::Json(std::wstring(config.locale.ui_language)) << ",\"timeZoneId\":" << cdf::test::Json(std::wstring(config.zone_id)) << ",\"utcOffsetSeconds\":" << config.offset_seconds << "}\n";
        return ok ? 0 : 1;
    }
    if (argc != 1) return 2;
    ParserTests(); ZoneTests();
    std::cout << "{\"passed\":" << (failures.empty() ? "true" : "false") << ",\"checks\":" << checks << ",\"failures\":[";
    for (size_t i = 0; i < failures.size(); ++i) { if (i) std::cout << ','; std::cout << cdf::test::Json(failures[i]); }
    std::cout << "]}\n"; return failures.empty() ? 0 : 1;
}
