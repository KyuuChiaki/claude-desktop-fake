// Copyright (c) 2026 claude-desktop-fake contributors. MIT license.
#include "network_transport_abi.h"
#include <Windows.h>
#include <cstdio>
#include <filesystem>

namespace {
int CDF_NET_CALL Authorize(uintptr_t, uint32_t kind) {
    return kind == 1 || kind == 2;
}
int CDF_NET_CALL Configure(const uint8_t* address, uint16_t port) {
    return address && port;
}
int64_t CDF_NET_CALL Clock() {
    FILETIME now{};
    GetSystemTimePreciseAsFileTime(&now);
    return static_cast<int64_t>((static_cast<uint64_t>(now.dwHighDateTime) << 32) | now.dwLowDateTime);
}
using Check = uint32_t(CDF_NET_CALL*)(char*, uint32_t);
}

int wmain(int argc, wchar_t** argv) {
    if (argc != 3) return 2;
    wchar_t path[32768]{};
    const DWORD length = GetModuleFileNameW(nullptr, path, static_cast<DWORD>(_countof(path)));
    if (length == 0 || length == _countof(path)) return 2;
    const auto transport = std::filesystem::path(path).parent_path() / L"CdfProxyTransport64.dll";
    HMODULE module = LoadLibraryExW(transport.c_str(), nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) {
        std::puts(R"({"ok":false,"stage":"load-transport"})");
        return 1;
    }
    const auto initialize = reinterpret_cast<CdfTransportStartFn>(GetProcAddress(module, "CdfTransportStart"));
    const auto check = reinterpret_cast<Check>(GetProcAddress(module, "CdfTransportCheck"));
    if (!initialize || !check) {
        std::puts(R"({"ok":false,"stage":"transport-version"})");
        return 1;
    }
    const CdfNetworkHostApi api{sizeof(api), 1, Authorize, Clock, Configure};
    const int status = initialize(&api, reinterpret_cast<const uint16_t*>(argv[1]),
        reinterpret_cast<const uint16_t*>(argv[2]));
    if (status != 0) {
        std::printf(R"({"ok":false,"stage":"initialize","code":%d})", status);
        return 1;
    }
    char result[2048]{};
    const uint32_t used = check(result, sizeof(result));
    if (!used || used > sizeof(result)) return 1;
    return std::fwrite(result, 1, used, stdout) == used ? 0 : 1;
}
