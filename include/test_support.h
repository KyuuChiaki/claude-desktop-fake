#pragma once
#include "time_core.h"
#include "time_zone_status.h"
#include <cstring>
#include <string>
#include <sstream>
#include <iomanip>
#include <vector>

namespace cdf::test {
template<class Fn> Fn Resolve(HMODULE module, const char* name) {
    const FARPROC address = GetProcAddress(module, name); Fn fn = nullptr;
    static_assert(sizeof(fn) == sizeof(address)); std::memcpy(&fn, &address, sizeof(fn)); return fn;
}
inline std::string Utf8(const std::wstring& value) {
    const int n = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(n), '\0');
    if (n) WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), out.data(), n, nullptr, nullptr);
    return out;
}
inline std::string Json(const std::string& value) {
    std::ostringstream out; out << '"';
    for (const unsigned char c : value) {
        if (c == '"') out << "\\\"";
        else if (c == '\\') out << "\\\\";
        else if (c < 32) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<unsigned>(c) << std::dec;
        else out << static_cast<char>(c);
    }
    out << '"'; return out.str();
}
inline std::string Json(const std::wstring& value) { return Json(Utf8(value)); }
inline std::wstring ModulePath(HMODULE module) {
    std::vector<WCHAR> buffer(32768); const DWORD n = GetModuleFileNameW(module, buffer.data(), static_cast<DWORD>(buffer.size()));
    return n && n < buffer.size() ? std::wstring(buffer.data(), n) : L"";
}
inline bool FindZone(const WCHAR* id, DYNAMIC_TIME_ZONE_INFORMATION& output) {
    for (DWORD i = 0; i < 1024; ++i) {
        if (EnumDynamicTimeZoneInformation(i, &output) != ERROR_SUCCESS) return false;
        if (_wcsicmp(id, output.TimeZoneKeyName) == 0) return true;
    }
    return false;
}
inline bool SameDate(const SYSTEMTIME& a, const SYSTEMTIME& b) { return std::memcmp(&a, &b, sizeof(a)) == 0; }
inline bool SameRule(const TIME_ZONE_INFORMATION& a, const TIME_ZONE_INFORMATION& b) {
    return a.Bias == b.Bias && a.StandardBias == b.StandardBias && a.DaylightBias == b.DaylightBias &&
        SameDate(a.StandardDate, b.StandardDate) && SameDate(a.DaylightDate, b.DaylightDate);
}
inline void PrintDate(std::ostream& out, const SYSTEMTIME& value) {
    out << '[' << value.wYear << ',' << value.wMonth << ',' << value.wDay << ',' << value.wHour << ','
        << value.wMinute << ',' << value.wSecond << ',' << value.wMilliseconds << ']';
}
}
