#include <WinSock2.h>
#include <WS2tcpip.h>
#include <MSWSock.h>
#include <WinDNS.h>
#include "network_status.h"
#include "time_zone_status.h"
#include "claude_identity.h"
#include <Windows.h>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <winhttp.h>
#include <winternl.h>

using Query = DWORD(WINAPI *)(CdfNetworkStatus *, DWORD);
struct DnsAsyncContext {
  HANDLE event;
  volatile LONG calls;
};
void WINAPI DnsFinished(PVOID context, PDNS_QUERY_RESULT) {
  auto *value = static_cast<DnsAsyncContext *>(context);
  InterlockedIncrement(&value->calls);
  SetEvent(value->event);
}
extern "C" __declspec(dllimport) DWORD WINAPI CdfNetworkEarlyState();
static CdfNetworkStatus tls_state{};
static bool tls_loaded = false;
void NTAPI NetworkTls(PVOID, DWORD reason, PVOID) {
  if (reason != DLL_PROCESS_ATTACH)
    return;
  auto module = GetModuleHandleW(L"CdfNetwork64.dll");
  if(!module)module=GetModuleHandleW(L"CdfClaudeNetwork64.dll");
  tls_loaded = module != nullptr;
  if (module) {
    const auto query = reinterpret_cast<Query>(
        GetProcAddress(module, "CdfNetworkQueryStatus"));
    if (query)
      query(&tls_state, sizeof(tls_state));
  }
}
#pragma const_seg(".CRT$XLB")
extern "C" const PIMAGE_TLS_CALLBACK CdfNetworkTlsCallback = NetworkTls;
#pragma const_seg()
#pragma comment(linker, "/INCLUDE:_tls_used")
#pragma comment(linker, "/INCLUDE:CdfNetworkTlsCallback")
std::string Escape(const std::string &value) {
  std::ostringstream o;
  o << '"';
  for (const auto c : value) {
    const auto b = static_cast<unsigned char>(c);
    if (c == '"' || c == '\\')
      o << '\\' << c;
    else if (b >= 32 && b < 127)
      o << c;
    else
      o << "\\u" << std::hex << std::setw(4) << std::setfill('0')
        << static_cast<unsigned>(b);
  }
  return o.str() + '"';
}
struct Internet {
  HINTERNET handle;
  ~Internet() {
    if (handle) {
      std::cerr << "WinHttpCloseHandle begin\n";
      WinHttpCloseHandle(handle);
      std::cerr << "WinHttpCloseHandle end\n";
    }
  }
};
int wmain(int argc, wchar_t **argv) {
  const bool signed_deny = argc > 1 && std::wstring(argv[1]) == L"--signed-deny";
  const bool baseline = signed_deny || (argc > 1 && std::wstring(argv[1]) == L"--baseline");
  bool ok = baseline ? !tls_loaded
                     : tls_loaded && (tls_state.state & 15) == 15 &&
                           (CdfNetworkEarlyState() & 15) == 15;
  if(signed_deny){
    const auto module=GetModuleHandleW(L"CdfClaudeNetwork64.dll");
    using IdentityQuery=DWORD(WINAPI*)(cdf::claude::IdentityStatus*,DWORD);
    const auto query=module?reinterpret_cast<IdentityQuery>(GetProcAddress(module,"CdfClaudeQueryIdentityStatus")):nullptr;
    cdf::claude::IdentityStatus identity{};
    ok=tls_loaded&&tls_state.state==0&&query&&query(&identity,sizeof(identity))==0&&identity.reason==static_cast<DWORD>(cdf::claude::Reason::ImageNotListed);
  }
  std::string mode = baseline ? "baseline" : "policy";
  if(argc>1&&std::wstring(argv[1])==L"--combo"){
    const auto time=GetModuleHandleW(L"CdfTimeZone64.dll");
    const auto query=time?reinterpret_cast<CdfTimeZoneQuery>(GetProcAddress(time,"CdfTimeZoneQueryStatus")):nullptr;
    CdfTimeZoneStatus status{};DYNAMIC_TIME_ZONE_INFORMATION zone{};WCHAR locale[85]{};
    ok=ok&&query&&query(&status,sizeof(status))==0&&status.state==31;
    GetDynamicTimeZoneInformation(&zone);GetUserDefaultLocaleName(locale,85);
    ok=ok&&std::wstring(zone.TimeZoneKeyName)==L"Pacific Standard Time"&&std::wstring(locale)==L"en-US";
  }
  DWORD http_error = 0, http_status = 0;
  std::string body;
  WSADATA data{};
  WSAStartup(MAKEWORD(2, 2), &data);
  SOCKET udp = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  const int udp_error = udp == INVALID_SOCKET ? WSAGetLastError() : 0;
  if (udp != INVALID_SOCKET)
    closesocket(udp);
  if (!baseline)
    ok = ok && udp == INVALID_SOCKET &&
         (udp_error == WSAEACCES || udp_error == WSAEPROTONOSUPPORT);
  if (argc > 1 && std::wstring(argv[1]) == L"--ipv4-only") {
    mode = "ipv4-only";
    const SOCKET v6 = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
    const int socket_error = v6 == INVALID_SOCKET ? WSAGetLastError() : 0;
    if (v6 != INVALID_SOCKET)
      closesocket(v6);
    ADDRINFOW hints{};
    hints.ai_flags = AI_NUMERICHOST;
    hints.ai_socktype = SOCK_STREAM;
    ADDRINFOW *addresses = nullptr;
    const int literal_error = GetAddrInfoW(L"::ffff:203.0.113.4", L"443", &hints, &addresses);
    if (addresses)
      FreeAddrInfoW(addresses);
    hints.ai_family = AF_INET6;
    hints.ai_flags |= AI_V4MAPPED;
    addresses = nullptr;
    const int family_error = GetAddrInfoW(L"203.0.113.4", L"443", &hints, &addresses);
    if (addresses)
      FreeAddrInfoW(addresses);
    hints.ai_family = AF_UNSPEC;
    hints.ai_flags = AI_NUMERICHOST;
    addresses = nullptr;
    const int ipv4_error = GetAddrInfoW(L"203.0.113.4", L"443", &hints, &addresses);
    const bool ipv4_result = ipv4_error == 0 && addresses &&
        addresses->ai_family == AF_INET && !addresses->ai_next;
    if (addresses)
      FreeAddrInfoW(addresses);
    PDNS_RECORDW rec = nullptr;
    const auto aaaa = DnsQuery_W(L"example.invalid", DNS_TYPE_AAAA,
                                DNS_QUERY_STANDARD, nullptr, &rec, nullptr);
    if (rec)
      DnsRecordListFree(reinterpret_cast<PDNS_RECORD>(rec), DnsFreeRecordList);
    body = "{\"socketError\":" + std::to_string(socket_error) +
           ",\"literalError\":" + std::to_string(literal_error) +
           ",\"familyError\":" + std::to_string(family_error) +
           ",\"aaaaStatus\":" + std::to_string(aaaa) + "}";
    ok = ok && (tls_state.state & CdfNetworkIPv4Only) &&
         socket_error == WSAEAFNOSUPPORT && literal_error == WSAEAFNOSUPPORT &&
         family_error == WSAEAFNOSUPPORT && ipv4_result &&
         aaaa == DNS_INFO_NO_RECORDS && rec == nullptr;
  }
  if (argc > 2 && std::wstring(argv[1]) == L"--resolve") {
    mode = "resolve";
    ADDRINFOW hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    ADDRINFOW *addresses = nullptr;
    const int error = GetAddrInfoW(argv[2], L"443", &hints, &addresses);
    unsigned count = 0;
    for (auto *a = addresses; a; a = a->ai_next)
      ++count;
    if (addresses)
      FreeAddrInfoW(addresses);
    body = "{\"resolveError\":" + std::to_string(error) +
           ",\"addressCount\":" + std::to_string(count) + "}";
    ok = ok && error == 0 && count > 0;
  }
  if (argc > 1 && std::wstring(argv[1]) == L"--denials") {
    mode = "denials";
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    struct ConnectInput {
      BYTE san;
      BYTE pad[7];
      HANDLE root;
      HANDLE endpoint;
      sockaddr_in target;
    };
    static_assert(offsetof(ConnectInput, target) == 24 &&
                  sizeof(ConnectInput) == 40);
    ConnectInput input{};
    input.endpoint = reinterpret_cast<HANDLE>(s);
    input.target.sin_family = AF_INET;
    input.target.sin_port = htons(53);
    InetPtonW(AF_INET, L"1.1.1.1", &input.target.sin_addr);
    using NativeIo =
        NTSTATUS(NTAPI *)(HANDLE, HANDLE, PVOID, PVOID, PIO_STATUS_BLOCK, ULONG,
                          PVOID, ULONG, PVOID, ULONG);
    const auto native = reinterpret_cast<NativeIo>(GetProcAddress(
        GetModuleHandleW(L"ntdll.dll"), "NtDeviceIoControlFile"));
    IO_STATUS_BLOCK io{};
    const auto status =
        native(reinterpret_cast<HANDLE>(s), nullptr, nullptr, nullptr, &io,
               0x12007, &input, sizeof(input), nullptr, 0);
    closesocket(s);
    Internet session{WinHttpOpen(L"CdfDeny/1", WINHTTP_ACCESS_TYPE_NO_PROXY,
                                 nullptr, nullptr, 0)};
    WINHTTP_AUTOPROXY_OPTIONS options{};
    options.dwFlags = WINHTTP_AUTOPROXY_AUTO_DETECT;
    options.dwAutoDetectFlags =
        WINHTTP_AUTO_DETECT_TYPE_DHCP | WINHTTP_AUTO_DETECT_TYPE_DNS_A;
    WINHTTP_PROXY_INFO proxy{};
    const BOOL autoProxy = WinHttpGetProxyForUrl(
        session.handle, L"https://cdf-network-canary.invalid/", &options,
        &proxy);
    const auto proxyError = GetLastError();
    body = "{\"nativeStatus\":" + std::to_string(static_cast<ULONG>(status)) +
           ",\"autoProxyError\":" + std::to_string(proxyError) + "}";
    ok = ok && status == static_cast<NTSTATUS>(0xc0000022u) && !autoProxy &&
         proxyError == ERROR_WINHTTP_AUTODETECTION_FAILED;
    const auto iphelper = LoadLibraryW(L"iphlpapi.dll");
    using IcmpCreate = HANDLE(WINAPI *)();
    const auto createIcmp =
        iphelper ? reinterpret_cast<IcmpCreate>(
                       GetProcAddress(iphelper, "IcmpCreateFile"))
                 : nullptr;
    const HANDLE icmp = createIcmp ? createIcmp() : nullptr;
    const auto icmpError = GetLastError();
    ok = ok && icmp == INVALID_HANDLE_VALUE && icmpError == ERROR_ACCESS_DENIED;
    if (iphelper)
      FreeLibrary(iphelper);
  }
  if (argc > 1 && (std::wstring(argv[1]) == L"--async" ||
                   std::wstring(argv[1]) == L"--async-cancel" ||
                   std::wstring(argv[1]) == L"--async-event" ||
                   std::wstring(argv[1]) == L"--async-event-skip-port")) {
    const bool cancel = std::wstring(argv[1]) == L"--async-cancel";
    const bool event_mode = std::wstring(argv[1]).find(L"--async-event") == 0;
    const bool skip_port = std::wstring(argv[1]) == L"--async-event-skip-port";
    mode = skip_port    ? "async-event-skip-port"
           : event_mode ? "async-event"
           : cancel     ? "async-cancel"
                        : "async";
    SOCKET s = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, nullptr, 0,
                          WSA_FLAG_OVERLAPPED);
    sockaddr_in local{};
    local.sin_family = AF_INET;
    bind(s, reinterpret_cast<sockaddr *>(&local), sizeof(local));
    HANDLE port =
        CreateIoCompletionPort(reinterpret_cast<HANDLE>(s), nullptr, 1234, 0);
    GUID id = WSAID_CONNECTEX;
    LPFN_CONNECTEX connect_ex = nullptr;
    DWORD received = 0;
    WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER, &id, sizeof(id),
             &connect_ex, sizeof(connect_ex), &received, nullptr, nullptr);
    sockaddr_in target{};
    target.sin_family = AF_INET;
    target.sin_port = htons(443);
    InetPtonW(AF_INET, L"1.1.1.1", &target.sin_addr);
    OVERLAPPED ov{};
    const HANDLE event =
        event_mode ? CreateEventW(nullptr, TRUE, TRUE, nullptr) : nullptr;
    if (event)
      ov.hEvent = reinterpret_cast<HANDLE>(reinterpret_cast<ULONG_PTR>(event) |
                                           (skip_port ? 1 : 0));
    const auto start = GetTickCount64();
    BOOL initiated = connect_ex(s, reinterpret_cast<sockaddr *>(&target),
                                sizeof(target), nullptr, 0, nullptr, &ov);
    const int start_error = initiated ? 0 : WSAGetLastError();
    const auto elapsed = GetTickCount64() - start;
    const bool reset_ok = !event ||
                          WaitForSingleObject(event, 0) == WAIT_TIMEOUT ||
                          static_cast<NTSTATUS>(ov.Internal) != STATUS_PENDING;
    if (cancel)
      CancelIoEx(reinterpret_cast<HANDLE>(s), &ov);
    ULONG_PTR key = 0;
    LPOVERLAPPED completed = nullptr;
    DWORD bytes = 0;
    DWORD flags = 0;
    const BOOL result =
        skip_port
            ? (WaitForSingleObject(event, 20000) == WAIT_OBJECT_0 &&
               WSAGetOverlappedResult(s, &ov, &bytes, TRUE, &flags))
            : GetQueuedCompletionStatus(port, &bytes, &key, &completed, 20000);
    const DWORD error = result ? 0 : GetLastError();
    body = "{\"pendingError\":" + std::to_string(start_error) +
           ",\"submitMilliseconds\":" + std::to_string(elapsed) +
           ",\"completionError\":" + std::to_string(error) +
           ",\"completionKey\":" + std::to_string(key) +
           ",\"overlappedMatched\":" + (completed == &ov ? "true" : "false") +
           "}";
    const auto total = GetTickCount64() - start;
    body.pop_back();
    body += ",\"totalMilliseconds\":" + std::to_string(total) + "}";
    ok = ok && reset_ok && !initiated && start_error == ERROR_IO_PENDING &&
         elapsed < 500 &&
         (cancel ? (!result && error == ERROR_OPERATION_ABORTED) : !!result) &&
         (skip_port ? (key == 0 && completed == nullptr)
                    : (key == 1234 && completed == &ov));
    if (event)
      ok = ok && WaitForSingleObject(event, 0) == WAIT_OBJECT_0;
    completed = nullptr;
    const BOOL duplicate =
        GetQueuedCompletionStatus(port, &bytes, &key, &completed, 100);
    ok = ok && !duplicate && GetLastError() == WAIT_TIMEOUT &&
         completed == nullptr;
    closesocket(s);
    if (event)
      CloseHandle(event);
    CloseHandle(port);
  }
  if (argc > 1 && std::wstring(argv[1]) == L"--dns-contracts") {
    mode = "dns-contracts";
    DNS_RECORDW *wide = nullptr;
    DNS_RECORDA *narrow = nullptr;
    const auto w = DnsQuery_W(L"cleanip.io", DNS_TYPE_A, DNS_QUERY_STANDARD,
                              nullptr, &wide, nullptr);
    const auto a =
        DnsQuery_A("cleanip.io", DNS_TYPE_A, DNS_QUERY_STANDARD, nullptr,
                   reinterpret_cast<PDNS_RECORD *>(&narrow), nullptr);
    DNS_QUERY_REQUEST request{};
    request.Version = DNS_QUERY_REQUEST_VERSION1;
    request.QueryName = L"cleanip.io";
    request.QueryType = DNS_TYPE_A;
    DNS_QUERY_RESULT output{};
    output.Version = DNS_QUERY_RESULTS_VERSION1;
    const auto ex = DnsQueryEx(&request, &output, nullptr);
    body = "{\"DnsQueryW\":" + std::to_string(w) +
           ",\"DnsQueryA\":" + std::to_string(a) +
           ",\"DnsQueryEx\":" + std::to_string(ex) + "}";
    ok = ok && w == 0 && a == 0 && ex == 0 && wide && narrow &&
         output.pQueryRecords;
    if (wide)
      DnsRecordListFree(wide, DnsFreeRecordList);
    if (narrow)
      DnsRecordListFree(narrow, DnsFreeRecordList);
    if (output.pQueryRecords)
      DnsRecordListFree(output.pQueryRecords, DnsFreeRecordList);
    for (unsigned cancel = 0; cancel < 2; ++cancel) {
      DnsAsyncContext context{CreateEventW(nullptr, TRUE, FALSE, nullptr), 0};
      DNS_QUERY_RESULT asynchronous{};
      asynchronous.Version = DNS_QUERY_RESULTS_VERSION1;
      request.pQueryCompletionCallback = DnsFinished;
      request.pQueryContext = &context;
      DNS_QUERY_CANCEL token{};
      const auto start = DnsQueryEx(&request, &asynchronous, &token);
      DNS_STATUS cancellation = ERROR_SUCCESS;
      if (cancel)
        cancellation = DnsCancelQuery(&token);
      const auto wait = WaitForSingleObject(context.event, 15000);
      ok = ok && start == DNS_REQUEST_PENDING && wait == WAIT_OBJECT_0 &&
           context.calls == 1 &&
           (cancel ? (asynchronous.QueryStatus == ERROR_CANCELLED ||
                      (cancellation != 0 && asynchronous.QueryStatus == 0))
                   : asynchronous.QueryStatus == 0);
      if (asynchronous.pQueryRecords)
        DnsRecordListFree(asynchronous.pQueryRecords, DnsFreeRecordList);
      CloseHandle(context.event);
    }
  }
  if (argc > 2 && (std::wstring(argv[1]) == L"--https"||std::wstring(argv[1]) == L"--combo")) {
    mode = "https";
    const std::wstring url = argv[2];
    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof(parts);
    parts.dwHostNameLength = static_cast<DWORD>(-1);
    parts.dwUrlPathLength = static_cast<DWORD>(-1);
    parts.dwExtraInfoLength = static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &parts)) {
      http_error = GetLastError();
      ok = false;
    } else {
      const std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
      std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
      if (parts.dwExtraInfoLength)
        path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
      if (path.empty())
        path = L"/";
      Internet session{
          WinHttpOpen(L"CdfNetworkProbe/1", WINHTTP_ACCESS_TYPE_NO_PROXY,
                      WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0)};
      if (session.handle)
        WinHttpSetTimeouts(session.handle, 15000, 15000, 15000, 15000);
      Internet connection{
          session.handle
              ? WinHttpConnect(session.handle, host.c_str(), parts.nPort, 0)
              : nullptr};
      Internet request{
          connection.handle
              ? WinHttpOpenRequest(
                    connection.handle, L"GET", path.c_str(), nullptr,
                    WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                    parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE
                                                           : 0)
              : nullptr};
      std::cerr << "WinHttpSendRequest begin\n";
      if (!request.handle ||
          !WinHttpSendRequest(request.handle, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                              WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
          !WinHttpReceiveResponse(request.handle, nullptr)) {
        http_error = GetLastError();
        ok = false;
      } else {
        std::cerr << "WinHttpReceiveResponse completed\n";
        DWORD length = sizeof(http_status);
        WinHttpQueryHeaders(request.handle,
                            WINHTTP_QUERY_STATUS_CODE |
                                WINHTTP_QUERY_FLAG_NUMBER,
                            WINHTTP_HEADER_NAME_BY_INDEX, &http_status, &length,
                            WINHTTP_NO_HEADER_INDEX);
        char buffer[4096];
        DWORD read = 0;
        while (body.size() < 65536 &&
               WinHttpReadData(request.handle, buffer, sizeof(buffer), &read) &&
               read)
          body.append(buffer, read);
        ok = ok && http_status >= 200 && http_status < 400;
        std::cerr << "WinHttpReadData completed\n";
      }
    }
  }
  CdfNetworkStatus state{};
  if (tls_loaded) {
    auto module=GetModuleHandleW(L"CdfNetwork64.dll");
    if(!module)module=GetModuleHandleW(L"CdfClaudeNetwork64.dll");
    const auto query = reinterpret_cast<Query>(GetProcAddress(
        module, "CdfNetworkQueryStatus"));
    if (query)
      query(&state, sizeof(state));
  }
  std::cout << "{\"passed\":" << (ok ? "true" : "false")
            << ",\"mode\":" << Escape(mode)
            << ",\"tlsLoaded\":" << (tls_loaded ? "true" : "false")
            << ",\"tlsState\":" << tls_state.state
            << ",\"state\":" << state.state
            << ",\"errorStage\":" << state.error_stage
            << ",\"errorCode\":" << state.error_code
            << ",\"hooks\":" << state.installed_hooks
            << ",\"udpError\":" << udp_error << ",\"httpError\":" << http_error
            << ",\"httpStatus\":" << http_status
            << ",\"connectCalls\":" << state.connect_calls
            << ",\"proxiedConnections\":" << state.proxied_connections
            << ",\"dnsQueries\":" << state.dns_queries
            << ",\"nativeDenials\":" << state.native_denials
            << ",\"lastNativeIoctl\":" << state.last_native_ioctl
            << ",\"lastConnectIoctl\":" << state.last_connect_ioctl
            << ",\"lastConnectInput\":\"";
  for (unsigned i = 0; i < state.last_connect_input_size && i < 96; ++i)
    std::cout << std::hex << std::setw(2) << std::setfill('0')
              << static_cast<unsigned>(state.last_connect_input[i]);
  std::cout << "\",\"deniedIoctl\":" << std::dec << state.denied_ioctl
            << ",\"deniedInput\":\"";
  for (unsigned i = 0; i < state.denied_input_size && i < 64; ++i)
    std::cout << std::hex << std::setw(2) << std::setfill('0')
              << static_cast<unsigned>(state.denied_input[i]);
  std::cout << "\",\"lastApi\":" << std::dec << state.last_api
            << ",\"arguments\":[" << state.argument1 << ',' << state.argument2
            << ',' << state.argument3 << "],\"apiCalls\":[";
  for (unsigned i = 0; i < 32; ++i) {
    if (i)
      std::cout << ',';
    std::cout << state.api_calls[i];
  }
  std::cout << "],\"body\":" << Escape(body) << "}\n";
  WSACleanup();
  return ok ? 0 : 1;
}
