#include <Windows.h>
#include <cstring>
#include <cwchar>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {
struct Observation {
    HMODULE module;
    DWORD state;
    DWORD error;
    bool query_found;
    DWORD verifier_flags;
    bool flags_query_found;
};
Observation tls_observation{};

Observation ObserveBootstrap() noexcept {
    Observation result{};
    result.module = GetModuleHandleW(L"CdfBootstrap64.dll");
    if (result.module == nullptr) {
        result.error = GetLastError();
        return result;
    }
    const FARPROC address = GetProcAddress(result.module, "CdfBootstrapQueryState");
    if (address == nullptr) {
        result.error = GetLastError();
        return result;
    }
    using QueryState = DWORD(WINAPI*)();
    QueryState query;
    static_assert(sizeof(query) == sizeof(address));
    std::memcpy(&query, &address, sizeof(query));
    result.query_found = true;
    result.state = query();
    const FARPROC flags_address = GetProcAddress(result.module, "CdfBootstrapQueryVerifierFlags");
    if (flags_address == nullptr) {
        result.error = GetLastError();
        return result;
    }
    std::memcpy(&query, &flags_address, sizeof(query));
    result.flags_query_found = true;
    result.verifier_flags = query();
    return result;
}

std::string Utf8(const std::wstring& value) {
    if (value.empty()) return {};
    const int count = WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
        static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    std::string output(static_cast<size_t>(count), '\0');
    if (count != 0) {
        WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
            output.data(), count, nullptr, nullptr);
    }
    return output;
}

std::string JsonString(const std::wstring& value) {
    std::ostringstream output;
    output << '"';
    for (const unsigned char c : Utf8(value)) {
        switch (c) {
        case '"': output << "\\\""; break;
        case '\\': output << "\\\\"; break;
        case '\n': output << "\\n"; break;
        case '\r': output << "\\r"; break;
        case '\t': output << "\\t"; break;
        default:
            if (c < 0x20) {
                output << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                    << static_cast<unsigned>(c) << std::dec;
            } else {
                output << static_cast<char>(c);
            }
        }
    }
    output << '"';
    return output.str();
}

std::wstring ModulePath(HMODULE module) {
    std::vector<wchar_t> buffer(32768);
    const DWORD length = GetModuleFileNameW(module, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0 || length >= buffer.size()) return {};
    return std::wstring(buffer.data(), length);
}

std::wstring FullPath(const std::wstring& path) {
    std::vector<wchar_t> buffer(32768);
    const DWORD length = GetFullPathNameW(path.c_str(), static_cast<DWORD>(buffer.size()), buffer.data(), nullptr);
    if (length == 0 || length >= buffer.size()) return {};
    return std::wstring(buffer.data(), length);
}

void PrintObservation(const Observation& value) {
    std::cout << "{\"loaded\":" << (value.module != nullptr ? "true" : "false")
        << ",\"queryFound\":" << (value.query_found ? "true" : "false")
        << ",\"state\":" << value.state << ",\"error\":" << value.error
        << ",\"flagsQueryFound\":" << (value.flags_query_found ? "true" : "false")
        << ",\"verifierFlags\":" << value.verifier_flags << '}';
}
}  // namespace

extern "C" void NTAPI CdfProbeTlsCallback(PVOID, DWORD reason, PVOID) {
    if (reason == DLL_PROCESS_ATTACH) tls_observation = ObserveBootstrap();
}

#pragma section(".CRT$XLB", long, read)
extern "C" __declspec(allocate(".CRT$XLB")) PIMAGE_TLS_CALLBACK cdf_probe_tls = CdfProbeTlsCallback;
#pragma comment(linker, "/INCLUDE:_tls_used")
#pragma comment(linker, "/INCLUDE:cdf_probe_tls")

int wmain(int argc, wchar_t** argv) {
    std::wstring expectation;
    std::wstring expected_path;
    for (int index = 1; index < argc; ++index) {
        const std::wstring argument = argv[index];
        if (argument == L"--expect" && index + 1 < argc) {
            expectation = argv[++index];
        } else if (argument == L"--expected-dll" && index + 1 < argc) {
            expected_path = FullPath(argv[++index]);
        } else {
            std::cerr << "Unknown or incomplete argument.\n";
            return 2;
        }
    }
    if ((expectation != L"loaded" && expectation != L"absent") ||
        (expectation == L"loaded" && expected_path.empty())) {
        std::cerr << "Usage: CdfProbe64.exe --expect loaded|absent [--expected-dll ABSOLUTE_PATH]\n";
        return 2;
    }
    const Observation main_observation = ObserveBootstrap();
    const std::wstring actual_path = main_observation.module ? ModulePath(main_observation.module) : L"";
    const bool loaded = tls_observation.module != nullptr && tls_observation.query_found &&
        tls_observation.state == 3 && main_observation.module != nullptr &&
        main_observation.query_found && main_observation.state == 3 &&
        tls_observation.flags_query_found && main_observation.flags_query_found &&
        tls_observation.verifier_flags == 0x80000000UL && main_observation.verifier_flags == 0x80000000UL &&
        !actual_path.empty() && _wcsicmp(actual_path.c_str(), expected_path.c_str()) == 0;
    const bool absent = tls_observation.module == nullptr && main_observation.module == nullptr;
    const bool matched = expectation == L"loaded" ? loaded : absent;
    std::cout << "{\"processId\":" << GetCurrentProcessId()
        << ",\"imagePath\":" << JsonString(ModulePath(nullptr))
        << ",\"expected\":" << JsonString(expectation)
        << ",\"matched\":" << (matched ? "true" : "false") << ",\"tls\":";
    PrintObservation(tls_observation);
    std::cout << ",\"main\":";
    PrintObservation(main_observation);
    std::cout << ",\"modulePath\":" << JsonString(actual_path)
        << ",\"expectedModulePath\":" << JsonString(expected_path) << "}\n";
    return matched ? 0 : 1;
}
