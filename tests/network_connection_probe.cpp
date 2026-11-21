// Isolated transport lifecycle probe. It owns both the socket and process.
#include <WinSock2.h>
#include <WS2tcpip.h>
#include <Windows.h>
#include "network_transport_abi.h"
#include <cstdio>
#include <filesystem>

namespace {
int CDF_NET_CALL Authorize(uintptr_t, uint32_t kind) { return kind == 1 || kind == 2; }
int CDF_NET_CALL Configure(const uint8_t* address, uint16_t port) { return address && port; }
int64_t CDF_NET_CALL Now() {
    FILETIME now{};
    GetSystemTimePreciseAsFileTime(&now);
    return static_cast<int64_t>(static_cast<uint64_t>(now.dwHighDateTime) << 32 | now.dwLowDateTime);
}
void Phase(const char* phase) {
    std::puts(phase);
    std::fflush(stdout);
}
}

int wmain(int argc, wchar_t** argv) {
    const bool check_dns = argc == 4 && std::wstring_view(argv[3]) == L"--dns";
    if ((argc != 3 && !check_dns) || GetModuleHandleW(L"CdfNetwork64.dll") ||
        GetModuleHandleW(L"CdfClaudeNetwork64.dll")) return 2;
    wchar_t path[32768]{};
    DWORD length=GetModuleFileNameW(nullptr,path,static_cast<DWORD>(_countof(path)));
    if (!length || length==_countof(path)) return 3;
    const auto dll = std::filesystem::path(path).parent_path() / L"CdfProxyTransport64.dll";
    const auto module = LoadLibraryExW(dll.c_str(), nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) return 4;
    const auto start = reinterpret_cast<CdfTransportStartFn>(GetProcAddress(module,"CdfTransportStart"));
    const auto open = reinterpret_cast<CdfTransportOpenFn>(GetProcAddress(module,"CdfTransportOpen"));
    const auto release = reinterpret_cast<CdfTransportReleaseFn>(GetProcAddress(module,"CdfTransportRelease"));
    if (!start || !open || !release) return 5;
    const CdfNetworkHostApi host{sizeof(host),1,Authorize,Now,Configure};
    if (const int error=start(&host,reinterpret_cast<const uint16_t*>(argv[1]),
        reinterpret_cast<const uint16_t*>(argv[2]))) {
        std::printf("start-error:%d\n",error);
        return 6;
    }
    if (check_dns) {
        const auto dns=reinterpret_cast<CdfTransportDnsFn>(GetProcAddress(module,"CdfTransportDnsV4"));
        if (!dns) return 14;
        uint8_t query[] = {0x12,0x34,1,0,0,1,0,0,0,0,0,0,
            3,'a','p','i',5,'i','p','i','f','y',3,'o','r','g',0,0,1,0,1};
        uint8_t response[8192]{};
        uint32_t received=0;
        if (dns(query,sizeof(query),response,sizeof(response),&received) != 0 ||
            received < 12 || !(response[2] & 0x80) || (response[3] & 15) ||
            (response[6] == 0 && response[7] == 0)) return 15;
        query[sizeof(query)-3] = 28;
        if (dns(query,sizeof(query),response,sizeof(response),&received) != WSANO_DATA ||
            received != 0) return 16;
    }
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2,2),&data)) return 7;
    SOCKET socketValue=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);
    if (socketValue==INVALID_SOCKET) return 8;
    sockaddr_in address{};
    address.sin_family=AF_INET;
    address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    int size=sizeof(address);
    if (bind(socketValue,reinterpret_cast<sockaddr*>(&address),size) ||
        getsockname(socketValue,reinterpret_cast<sockaddr*>(&address),&size)) return 9;
    uint16_t bridge{};
    const auto port=ntohs(address.sin_port);
    const int result=open("api.ipify.org",443,port,AF_INET,"127.0.0.1",&bridge);
    if (result) {
        std::printf("open-error:%d\n",result);
        return 10;
    }
    address.sin_port=htons(bridge);
    if (connect(socketValue,reinterpret_cast<sockaddr*>(&address),size)) return 11;
    Phase("connected");
    char command[32]{};
    if (!std::fgets(command,sizeof(command),stdin)) return 12;
    release(port,AF_INET);
    closesocket(socketValue);
    Phase("closed");
    if (!std::fgets(command,sizeof(command),stdin)) return 13;
    WSACleanup();
    return 0;
}
