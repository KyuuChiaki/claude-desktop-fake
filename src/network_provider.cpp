#include <WinSock2.h>
#include <WS2tcpip.h>
#include <MSWSock.h>
#include <mstcpip.h>
#include "network_status.h"
#include "network_transport_abi.h"
#include "sha256.h"
#include "time_native.h"
#include "verifier_abi.h"
#if defined(CDF_NETWORK_CLAUDE_IDENTITY)
#include "browser_consent.h"
#include "claude_identity.h"
#endif
#include <WinDNS.h>
#include <Windows.h>
#include <intrin.h>
#include <winhttp.h>
#include <winternl.h>

extern "C" {
NTSYSAPI NTSTATUS NTAPI LdrGetDllHandle(PWSTR, PULONG, PUNICODE_STRING,
                                        PVOID *);
NTSYSAPI NTSTATUS NTAPI NtWriteFile(HANDLE, HANDLE, PIO_APC_ROUTINE, PVOID,
                                    PIO_STATUS_BLOCK, PVOID, ULONG,
                                    PLARGE_INTEGER, PULONG);
NTSYSAPI NTSTATUS NTAPI NtTerminateProcess(HANDLE, NTSTATUS);
NTSYSAPI NTSTATUS NTAPI NtSetInformationFile(HANDLE, PIO_STATUS_BLOCK, PVOID,
                                             ULONG, FILE_INFORMATION_CLASS);
NTSYSAPI NTSTATUS NTAPI RtlGetVersion(PRTL_OSVERSIONINFOW);
NTSYSAPI PVOID NTAPI RtlAllocateHeap(PVOID, ULONG, SIZE_T);
NTSYSAPI BOOLEAN NTAPI RtlFreeHeap(PVOID, ULONG, PVOID);
NTSYSAPI VOID NTAPI RtlAcquireSRWLockExclusive(PSRWLOCK);
NTSYSAPI VOID NTAPI RtlReleaseSRWLockExclusive(PSRWLOCK);
}
namespace cdf::network {
constexpr NTSTATUS access_denied = static_cast<NTSTATUS>(0xC0000022u);
constexpr unsigned slots = 4096;
enum Kind : ULONG { App = 1, Upstream = 2, Listener = 3, Accepted = 4 };
struct Socket {
  SOCKET handle;
  ULONG kind, family, generation;
  bool used, connected, nonblocking, closing;
  HANDLE completion_port;
  PVOID completion_key;
  sockaddr_storage logical;
  int logical_size;
  USHORT bridge_port, local_port;
};
Socket sockets[slots]{};
SRWLOCK socket_lock{};
// Serializes only kernel submission versus close. Never held across tunnel I/O.
SRWLOCK connect_issue_lock{};
CdfNetworkStatus diagnostic{sizeof(CdfNetworkStatus), 1};
CdfNetworkPolicy policy{};
BYTE upstream_ip[4]{};
USHORT upstream_port = 0;
volatile LONG transport_state = 0;
CdfTransportOpenFn transport_open = nullptr;
CdfTransportDnsFn transport_dns = nullptr;
bool transport_dns_ipv4 = false;
CdfTransportReleaseFn transport_release = nullptr;
extern verifier::ThunkDescriptor winsock_thunks[], native_thunks[],
    kernel_thunks[], base_thunks[], dns_thunks[], http_thunks[], inet_thunks[],
    icmp_thunks[];
void Zero(void *p, SIZE_T n) {
  auto *b = static_cast<volatile BYTE *>(p);
  while (n--)
    *b++ = 0;
}
void Copy(void *to, const void *from, SIZE_T n) {
  auto *d = static_cast<volatile BYTE *>(to);
  auto *s = static_cast<const volatile BYTE *>(from);
  while (n--)
    *d++ = *s++;
}
bool Equal(const char *a, const char *b) {
  while (*a && *a == *b) {
    ++a;
    ++b;
  }
  return *a == *b;
}
void Count(uint64_t &value) {
  _InterlockedIncrement64(reinterpret_cast<volatile LONG64 *>(&value));
}
void Api(ULONG id, ULONG a = 0, ULONG b = 0, ULONG c = 0) {
  if (id < 32)
    Count(diagnostic.api_calls[id]);
  diagnostic.last_api = id;
  diagnostic.argument1 = a;
  diagnostic.argument2 = b;
  diagnostic.argument3 = c;
}
void *Raw(const WCHAR *module, const char *symbol) {
  UNICODE_STRING dll;
  RtlInitUnicodeString(&dll, module);
  PVOID handle = nullptr, result = nullptr;
  if (LdrGetDllHandle(nullptr, nullptr, &dll, &handle) < 0)
    return nullptr;
  ANSI_STRING name;
  RtlInitAnsiString(&name, symbol);
  if (LdrGetProcedureAddress(handle, &name, 0, &result) < 0)
    return nullptr;
  return result;
}
template <class Fn>
Fn Original(verifier::ThunkDescriptor *table, const char *name) {
  for (auto *t = table; t->name; ++t)
    if (Equal(t->name, name))
      return reinterpret_cast<Fn>(
          t->old_address ? t->old_address
                         : Raw(table == winsock_thunks  ? L"ws2_32.dll"
                               : table == native_thunks ? L"ntdll.dll"
                               : table == dns_thunks    ? L"dnsapi.dll"
                               : table == http_thunks   ? L"winhttp.dll"
                               : table == inet_thunks   ? L"wininet.dll"
                                                        : L"kernelbase.dll",
                               name));
  return nullptr;
}
template <class Fn> Fn System(const char *name) {
  return reinterpret_cast<Fn>(Raw(L"kernelbase.dll", name));
}
int Fail(int code = WSAEACCES, ULONG reason = 0, ULONG detail = 0) {
  Api(21, static_cast<ULONG>(code), reason, detail);
  Count(diagnostic.denied_calls);
  RtlSetLastWin32Error(static_cast<ULONG>(code));
  return SOCKET_ERROR;
}
Socket Snapshot(SOCKET s) {
  Socket result{};
  RtlAcquireSRWLockExclusive(&socket_lock);
  for (auto &entry : sockets)
    if (entry.used && entry.handle == s) {
      result = entry;
      break;
    }
  RtlReleaseSRWLockExclusive(&socket_lock);
  return result;
}
bool Register(SOCKET s, ULONG family, ULONG kind = App) {
  bool result = false;
  RtlAcquireSRWLockExclusive(&socket_lock);
  Socket *free = nullptr;
  for (auto &entry : sockets) {
    if (entry.used && entry.handle == s) {
      free = &entry;
      break;
    }
    if (!entry.used && !free)
      free = &entry;
  }
  if (free) {
    const ULONG generation = free->generation + 1;
    Zero(free, sizeof(*free));
    free->used = true;
    free->handle = s;
    free->family = family;
    free->kind = kind;
    free->generation = generation;
    result = true;
  }
  RtlReleaseSRWLockExclusive(&socket_lock);
  return result;
}
void Forget(SOCKET s, ULONG generation) {
  RtlAcquireSRWLockExclusive(&socket_lock);
  for (auto &entry : sockets)
    if (entry.used && entry.handle == s && entry.generation == generation) {
      entry.used = false;
      break;
    }
  RtlReleaseSRWLockExclusive(&socket_lock);
}
void Connected(SOCKET s, const sockaddr *logical, int size, USHORT bridge,
               USHORT local_port) {
  RtlAcquireSRWLockExclusive(&socket_lock);
  for (auto &entry : sockets)
    if (entry.used && entry.handle == s) {
      entry.connected = true;
      entry.bridge_port = bridge;
      entry.local_port = local_port;
      entry.logical_size = size;
      Copy(&entry.logical, logical, static_cast<SIZE_T>(size));
      break;
    }
  RtlReleaseSRWLockExclusive(&socket_lock);
}
bool LoaderLocked() {
  const auto peb = __readgsqword(0x60);
  auto *lock = *reinterpret_cast<RTL_CRITICAL_SECTION **>(peb + 0x110);
  return lock &&
         reinterpret_cast<ULONG_PTR>(lock->OwningThread) == __readgsqword(0x48);
}
bool ReadNative(const WCHAR *path, void *data, ULONG size,
                ULONG *actual = nullptr) {
  UNICODE_STRING name;
  RtlInitUnicodeString(&name, path);
  OBJECT_ATTRIBUTES oa;
  InitializeObjectAttributes(&oa, &name, OBJ_CASE_INSENSITIVE, nullptr,
                             nullptr);
  HANDLE file = nullptr;
  IO_STATUS_BLOCK io{};
  if (NtOpenFile(&file, FILE_READ_DATA | SYNCHRONIZE, &oa, &io,
                 FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                 0x60) < 0)
    return false;
  LARGE_INTEGER offset{};
  NTSTATUS st = NtReadFile(file, nullptr, nullptr, nullptr, &io, data, size,
                           &offset, nullptr);
  NtClose(file);
  if (actual)
    *actual = static_cast<ULONG>(io.Information);
  return st >= 0 && io.Information == size;
}
bool NativePath(WCHAR (&path)[640], const uint16_t *dos) {
  path[0] = L'\\';
  path[1] = L'?';
  path[2] = L'?';
  path[3] = L'\\';
  unsigned n = 0;
  while (dos[n] && n < 635) {
    path[n + 4] = static_cast<WCHAR>(dos[n]);
    ++n;
  }
  path[n + 4] = 0;
  return n > 3 && n < 635 && dos[1] == ':' && dos[2] == '\\';
}
bool HashFile(const uint16_t *dos, const BYTE *expected) {
  WCHAR path[640];
  if (!NativePath(path, dos))
    return false;
  UNICODE_STRING name;
  RtlInitUnicodeString(&name, path);
  OBJECT_ATTRIBUTES oa;
  InitializeObjectAttributes(&oa, &name, OBJ_CASE_INSENSITIVE, nullptr,
                             nullptr);
  HANDLE file = nullptr;
  IO_STATUS_BLOCK io{};
  if (NtOpenFile(&file, FILE_READ_DATA | SYNCHRONIZE, &oa, &io, FILE_SHARE_READ,
                 0x60) < 0)
    return false;
  BYTE buffer[16384];
  Sha256 hash;
  hash.Init();
  bool good = true;
  LARGE_INTEGER offset{};
  for (;;) {
    NTSTATUS st = NtReadFile(file, nullptr, nullptr, nullptr, &io, buffer,
                             sizeof(buffer), &offset, nullptr);
    if (st == static_cast<NTSTATUS>(0xC0000011u))
      break;
    if (st < 0) {
      good = false;
      break;
    }
    hash.Update(buffer, io.Information);
    offset.QuadPart += static_cast<LONGLONG>(io.Information);
    if (io.Information < sizeof(buffer))
      break;
  }
  NtClose(file);
  BYTE actual[32];
  hash.Finish(actual);
  for (unsigned i = 0; i < 32; ++i)
    if (actual[i] != expected[i])
      good = false;
  return good;
}
bool LoadPolicy() {
  HANDLE key = nullptr;
  UNICODE_STRING name;
  RtlInitUnicodeString(&name, L"\\REGISTRY\\MACHINE\\SOFTWARE\\Microsoft\\Windo"
                              L"ws\\CurrentVersion\\Explorer\\Shell Folders");
  OBJECT_ATTRIBUTES oa;
  InitializeObjectAttributes(&oa, &name, OBJ_CASE_INSENSITIVE, nullptr,
                             nullptr);
  if (NtOpenKey(&key, KEY_QUERY_VALUE, &oa) < 0)
    return false;
  RtlInitUnicodeString(&name, L"Common AppData");
  alignas(8) BYTE data[1200]{};
  ULONG used = 0;
  const NTSTATUS st = NtQueryValueKey(key, &name, 2, data, sizeof(data), &used);
  NtClose(key);
  if (st < 0 || used < 18 || *reinterpret_cast<ULONG *>(data + 4) != REG_SZ)
    return false;
  auto *directory = reinterpret_cast<WCHAR *>(data + 12);
  WCHAR path[640]{L'\\', L'?', L'?', L'\\'};
  unsigned n = 4, i = 0;
  while (directory[i] && n < 550)
    path[n++] = directory[i++];
  const WCHAR suffix[] = L"\\ClaudeDesktopFake\\network\\policy.bin";
  for (i = 0; suffix[i]; ++i)
    path[n++] = suffix[i];
  path[n] = 0;
  if (!ReadNative(path, &policy, sizeof(policy)))
    return false;
  return policy.magic == 0x4e464443 && policy.version == 1 &&
         policy.size == sizeof(policy) && policy.reserved == 0 &&
         policy.transport_path[511] == 0 && policy.profile_path[511] == 0 &&
         policy.interface_guid[39] == 0;
}
int CDF_NET_CALL Authorize(uintptr_t handle, uint32_t kind) {
  Socket s = Snapshot(handle);
  if (!s.used || kind < 1 || kind > 3)
    return 0;
  RtlAcquireSRWLockExclusive(&socket_lock);
  for (auto &entry : sockets)
    if (entry.used && entry.handle == handle) {
      entry.kind = kind == 1 ? Upstream : kind == 2 ? Listener : Accepted;
      break;
    }
  RtlReleaseSRWLockExclusive(&socket_lock);
  return 1;
}
int CDF_NET_CALL Configure(const uint8_t *ip, uint16_t port) {
  if (!ip || !port)
    return 0;
  if (upstream_port) {
    for (unsigned i = 0; i < 4; i++)
      if (upstream_ip[i] != ip[i])
        return 0;
    return port == upstream_port;
  }
  Copy(upstream_ip, ip, 4);
  upstream_port = port;
  return 1;
}
int64_t CDF_NET_CALL RealTicks() {
  // 19045 KUSER_SHARED_DATA.SystemTime. This protocol clock must stay real even
  // when a separate time provider retargets this module's ntdll import cells.
  const auto *parts = reinterpret_cast<const volatile ULONG *>(0x7ffe0014ULL);
  for (unsigned attempt = 0; attempt < 8; ++attempt) {
    const ULONG high = parts[1], low = parts[0];
    if (high == parts[2])
      return static_cast<int64_t>((static_cast<ULONGLONG>(high) << 32) | low);
    _mm_pause();
  }
  return 0;
}
bool EnsureTransport() {
  if (transport_state == 2)
    return true;
  if (transport_state == 3 || !(diagnostic.state & CdfNetworkPolicyReady) ||
      LoaderLocked())
    return false;
  if (_InterlockedCompareExchange(&transport_state, 1, 0) == 0) {
    ++diagnostic.transport_starts;
    bool ok = HashFile(policy.transport_path, policy.transport_sha256) &&
              HashFile(policy.profile_path, policy.profile_sha256);
    HMODULE module = nullptr;
    if (ok) {
      auto load = System<decltype(&LoadLibraryExW)>("LoadLibraryExW");
      module =
          load ? load(reinterpret_cast<const WCHAR *>(policy.transport_path),
                      nullptr,
                      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
                          LOAD_LIBRARY_SEARCH_SYSTEM32)
               : nullptr;
      ok = module != nullptr;
    }
    if (ok) {
      auto start = reinterpret_cast<CdfTransportStartFn>(
          Raw(reinterpret_cast<const WCHAR *>(policy.transport_path),
              "CdfTransportStart"));
      transport_open = reinterpret_cast<CdfTransportOpenFn>(
          Raw(reinterpret_cast<const WCHAR *>(policy.transport_path),
              "CdfTransportOpen"));
      transport_release = reinterpret_cast<CdfTransportReleaseFn>(
          Raw(reinterpret_cast<const WCHAR *>(policy.transport_path),
              "CdfTransportRelease"));
      transport_dns = reinterpret_cast<CdfTransportDnsFn>(
          Raw(reinterpret_cast<const WCHAR *>(policy.transport_path),
              "CdfTransportDnsV4"));
      transport_dns_ipv4 = transport_dns != nullptr;
      if (!transport_dns)
        transport_dns = reinterpret_cast<CdfTransportDnsFn>(
            Raw(reinterpret_cast<const WCHAR *>(policy.transport_path),
                "CdfTransportDns"));
      CdfNetworkHostApi host{sizeof(host), 1, Authorize, RealTicks, Configure};
      const int error =
          start && transport_open && transport_dns && transport_release
              ? start(&host, policy.profile_path, policy.interface_guid)
              : WSASYSNOTREADY;
      ok = error == 0;
      diagnostic.error_code = static_cast<ULONG>(error);
    }
    if (ok) {
      diagnostic.state |= CdfNetworkTransportReady;
      _InterlockedExchange(&transport_state, 2);
    } else {
      diagnostic.error_stage = 3;
      diagnostic.state |= CdfNetworkFailed;
      _InterlockedExchange(&transport_state, 3);
    }
    return ok;
  }
  // First-use contenders wait outside loader lock; initialization has a hard
  // network-free bound.
  auto sleep = System<decltype(&Sleep)>("Sleep");
  for (unsigned i = 0; i < 1000 && transport_state == 1; ++i)
    if (sleep)
      sleep(1);
  return transport_state == 2;
}
bool DestinationAllowed(const Socket &s, const sockaddr *address, int length) {
  if (!address || length < sizeof(sockaddr_in) || address->sa_family != AF_INET)
    return false;
  if (s.kind == Upstream) {
    const auto *a = reinterpret_cast<const sockaddr_in *>(address);
    return a->sin_port == _byteswap_ushort(upstream_port) &&
           *reinterpret_cast<const ULONG *>(&a->sin_addr) ==
               *reinterpret_cast<ULONG *>(upstream_ip);
  }
  return s.kind == App && s.family == AF_INET;
}
SOCKET WSAAPI HookWSASocketW(int af, int type, int protocol,
                             LPWSAPROTOCOL_INFOW info, GROUP group,
                             DWORD flags) {
  Api(0, static_cast<ULONG>(af), static_cast<ULONG>(type), info ? 1 : 0);
  if (info) {
    if (info->dwProviderReserved)
      return static_cast<SOCKET>(Fail(WSAEACCES, 102));
    if (info->ProtocolChain.ChainLen != BASE_PROTOCOL ||
        info->iSocketType != SOCK_STREAM || info->iProtocol != IPPROTO_TCP)
      return static_cast<SOCKET>(Fail(WSAEACCES, 101));
    if (af == FROM_PROTOCOL_INFO)
      af = info->iAddressFamily;
    if (type == FROM_PROTOCOL_INFO)
      type = info->iSocketType;
    if (protocol == FROM_PROTOCOL_INFO)
      protocol = info->iProtocol;
  }
  if (af == AF_INET6 || (info && info->iAddressFamily == AF_INET6))
    return static_cast<SOCKET>(Fail(WSAEAFNOSUPPORT, 100, AF_INET6));
  if (type == SOCK_DGRAM)
    return static_cast<SOCKET>(
        Fail(WSAEPROTONOSUPPORT, 100, static_cast<ULONG>(type)));
  if (af != AF_INET || type != SOCK_STREAM ||
      (protocol != 0 && protocol != IPPROTO_TCP) || group != 0 ||
      (flags & WSA_FLAG_REGISTERED_IO))
    return static_cast<SOCKET>(Fail(WSAEACCES, 100, static_cast<ULONG>(type)));
  auto original = Original<decltype(&WSASocketW)>(winsock_thunks, "WSASocketW");
  SOCKET s = original(af, type, protocol, info, group, flags);
  if (s != INVALID_SOCKET && !Register(s, static_cast<ULONG>(af))) {
    Original<decltype(&closesocket)>(winsock_thunks, "closesocket")(s);
    return static_cast<SOCKET>(Fail(WSAENOBUFS));
  }
  return s;
}
SOCKET WSAAPI HookWSASocketA(int af, int type, int protocol,
                             LPWSAPROTOCOL_INFOA info, GROUP group,
                             DWORD flags) {
  WSAPROTOCOL_INFOW wide{};
  if (info)
    Copy(&wide, info, offsetof(WSAPROTOCOL_INFOW, szProtocol));
  return HookWSASocketW(af, type, protocol, info ? &wide : nullptr, group,
                        flags);
}

SOCKET WSAAPI HookSocket(int af, int type, int protocol) {
  return HookWSASocketW(af, type, protocol, nullptr, 0, WSA_FLAG_OVERLAPPED);
}
void ReleaseSocket(const Socket &s) {
  if (s.used && s.kind == App && s.local_port && transport_release &&
      transport_state == 2 && !LoaderLocked())
    transport_release(s.local_port, s.family);
}
bool CancelPreparing(SOCKET, LPOVERLAPPED);
void BeginSocketClose(const Socket &before) {
  RtlAcquireSRWLockExclusive(&connect_issue_lock);
  RtlAcquireSRWLockExclusive(&socket_lock);
  for (auto &e : sockets)
    if (e.used && e.handle == before.handle &&
        e.generation == before.generation)
      e.closing = true;
  RtlReleaseSRWLockExclusive(&socket_lock);
  RtlReleaseSRWLockExclusive(&connect_issue_lock);
  CancelPreparing(before.handle, nullptr);
}
int WSAAPI HookCloseSocket(SOCKET s) {
  const auto before = Snapshot(s);
  if (before.used)
    BeginSocketClose(before);
  ReleaseSocket(before);
  const int result =
      Original<decltype(&closesocket)>(winsock_thunks, "closesocket")(s);
  if (result == 0 && before.used)
    Forget(s, before.generation);
  return result;
}

int WSAAPI HookIoctlSocket(SOCKET s, long command, u_long *value) {
  const int r = Original<decltype(&ioctlsocket)>(winsock_thunks, "ioctlsocket")(
      s, command, value);
  if (r == 0 && command == FIONBIO && value) {
    RtlAcquireSRWLockExclusive(&socket_lock);
    for (auto &e : sockets)
      if (e.used && e.handle == s)
        e.nonblocking = *value != 0;
    RtlReleaseSRWLockExclusive(&socket_lock);
  }
  return r;
}
int ConnectBridge(SOCKET handle, const sockaddr *target, int length,
                  LPWSAOVERLAPPED overlapped = nullptr,
                  LPFN_CONNECTEX extension = nullptr, void *initial = nullptr,
                  DWORD initial_size = 0, LPDWORD sent = nullptr) {
  Socket s = Snapshot(handle);
  if (!s.used || !target || length > sizeof(sockaddr_storage))
    return Fail(WSAEACCES, 1, s.used ? 1 : 0);
  if (length >= sizeof(ADDRESS_FAMILY) && target->sa_family == AF_INET6)
    return Fail(WSAEAFNOSUPPORT);
  if (s.kind == Upstream) {
    if (!DestinationAllowed(s, target, length))
      return Fail(WSAEACCES, 3, s.kind);
    return extension ? (extension(handle, target, length, initial, initial_size,
                                  sent, overlapped)
                            ? 0
                            : SOCKET_ERROR)
                     : Original<decltype(&connect)>(winsock_thunks, "connect")(
                           handle, target, length);
  }
  if (s.kind != App || !DestinationAllowed(s, target, length) || s.connected)
    return Fail(WSAEISCONN);
  // A duplicated/inherited connected endpoint must never acquire bridge
  // authority.
  sockaddr_storage peer{};
  int peer_length = sizeof(peer);
  if (Original<decltype(&getpeername)>(winsock_thunks, "getpeername")(
          handle, reinterpret_cast<sockaddr *>(&peer), &peer_length) == 0)
    return Fail(WSAEISCONN);
  if (!EnsureTransport())
    return Fail(WSAENETUNREACH);
  sockaddr_in local{};
  int local_length = sizeof(local);
  auto get = reinterpret_cast<decltype(&getsockname)>(
      Raw(L"ws2_32.dll", "getsockname"));
  auto bind_fn = reinterpret_cast<decltype(&bind)>(Raw(L"ws2_32.dll", "bind"));
  auto text =
      reinterpret_cast<decltype(&InetNtopA)>(Raw(L"ws2_32.dll", "inet_ntop"));
  if (!text)
    text = reinterpret_cast<decltype(text)>(Raw(L"ws2_32.dll", "inet_ntop"));
  char host[80]{};
  const auto *a = reinterpret_cast<const sockaddr_in *>(target);
  const USHORT dest_port = _byteswap_ushort(a->sin_port);
  const BYTE *bytes = reinterpret_cast<const BYTE *>(&a->sin_addr);
  if (bytes[0] == 0 || bytes[0] == 10 || bytes[0] == 127 || bytes[0] >= 224 ||
      (bytes[0] == 192 && bytes[1] == 168) ||
      (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
      (bytes[0] == 169 && bytes[1] == 254))
    return Fail(WSAEACCES, 6, bytes[0]);
  if (!text || !text(AF_INET, &a->sin_addr, host, sizeof(host)))
    return Fail();
  sockaddr_in bridge{};
  bridge.sin_family = AF_INET;
  bridge.sin_addr.S_un.S_addr = 0x0100007f;
  constexpr int bridge_size = sizeof(bridge);
  if (get(handle, reinterpret_cast<sockaddr *>(&local), &local_length) != 0 ||
      local.sin_port == 0) {
    if (bind_fn(handle, reinterpret_cast<sockaddr *>(&bridge), bridge_size) !=
        0)
      return Fail(static_cast<int>(RtlGetLastWin32Error()), 8, AF_INET);
    local_length = sizeof(local);
    if (get(handle, reinterpret_cast<sockaddr *>(&local), &local_length) != 0)
      return Fail(static_cast<int>(RtlGetLastWin32Error()), 8, AF_INET);
  }
  char local_text[80]{};
  text(AF_INET, &local.sin_addr, local_text, sizeof(local_text));
  const USHORT port = _byteswap_ushort(local.sin_port);
  RtlAcquireSRWLockExclusive(&socket_lock);
  for (auto &e : sockets)
    if (e.used && e.handle == handle && e.generation == s.generation)
      e.local_port = port;
  RtlReleaseSRWLockExclusive(&socket_lock);
  USHORT bridge_port = 0;
  const int open_error =
      transport_open(host, dest_port, port, AF_INET, local_text, &bridge_port);
  if (open_error)
    return Fail(open_error, 9, AF_INET);
  bridge.sin_port = _byteswap_ushort(bridge_port);
  RtlAcquireSRWLockExclusive(&connect_issue_lock);
  const auto current = Snapshot(handle);
  if (!current.used || current.closing || current.generation != s.generation) {
    RtlReleaseSRWLockExclusive(&connect_issue_lock);
    transport_release(port, AF_INET);
    return Fail(WSA_OPERATION_ABORTED);
  }
  Connected(handle, target, length, bridge_port, port);
  Count(diagnostic.proxied_connections);
  int result;
  if (extension)
    result = extension(handle, reinterpret_cast<sockaddr *>(&bridge),
                       bridge_size, initial, initial_size, sent, overlapped)
                 ? 0
                 : SOCKET_ERROR;
  else
    result = Original<decltype(&connect)>(winsock_thunks, "connect")(
        handle, reinterpret_cast<sockaddr *>(&bridge), bridge_size);
  const ULONG error = RtlGetLastWin32Error();
  if (result != 0 && error != WSA_IO_PENDING && error != WSAEWOULDBLOCK) {
    RtlAcquireSRWLockExclusive(&socket_lock);
    for (auto &e : sockets)
      if (e.used && e.handle == handle && e.generation == s.generation)
        e.connected = false;
    RtlReleaseSRWLockExclusive(&socket_lock);
  }
  RtlReleaseSRWLockExclusive(&connect_issue_lock);
  if (result != 0 && error != WSA_IO_PENDING && error != WSAEWOULDBLOCK)
    transport_release(port, AF_INET);
  RtlSetLastWin32Error(error);
  return result;
}
int WSAAPI HookConnect(SOCKET s, const sockaddr *address, int length) {
  Api(1);
  Count(diagnostic.connect_calls);
  return ConnectBridge(s, address, length);
}
int WSAAPI HookWSAConnect(SOCKET s, const sockaddr *address, int length,
                          LPWSABUF caller, LPWSABUF callee, LPQOS sqos,
                          LPQOS gqos) {
  if (caller || callee || sqos || gqos)
    return Fail(WSAEOPNOTSUPP);
  return HookConnect(s, address, length);
}
LPFN_CONNECTEX real_connect_ex = nullptr;
LPFN_ACCEPTEX real_accept_ex = nullptr;
#include "network_async.inc"
BOOL PASCAL HookConnectEx(SOCKET s, const sockaddr *address, int length,
                          PVOID buffer, DWORD bytes, LPDWORD sent,
                          LPOVERLAPPED ov) {
  Api(2);
  Count(diagnostic.connect_calls);
  if (!real_connect_ex) {
    Fail(WSAEACCES, 120);
    return FALSE;
  }
  if (Snapshot(s).kind == Upstream)
    return ConnectBridge(s, address, length, ov, real_connect_ex, buffer, bytes,
                         sent) == 0;
  // ntdll's thread-pool implementation can associate its private port through
  // an internal syscall that has no import cell. Preserve that kernel-owned
  // completion context instead of synthesizing an unobservable IOCP packet.
  // Authentication stays fail-closed; this path can wait on the calling thread.
  if (!Snapshot(s).completion_port && ov && !ov->hEvent) {
    Count(diagnostic.api_calls[28]);
    return ConnectBridge(s, address, length, ov, real_connect_ex, buffer, bytes,
                         sent) == 0;
  }
  return BeginConnectEx(s, address, length, buffer, bytes, sent, ov);
}
BOOL PASCAL HookAcceptEx(SOCKET listener, SOCKET accepted, PVOID output,
                         DWORD receive, DWORD local, DWORD remote,
                         LPDWORD received, LPOVERLAPPED ov) {
  if (Snapshot(listener).kind != Listener || !real_accept_ex) {
    Fail(WSAEACCES, 110, Snapshot(listener).kind);
    return FALSE;
  }
  if (!Authorize(accepted, 3)) {
    Fail(WSAEACCES, 111);
    return FALSE;
  }
  return real_accept_ex(listener, accepted, output, receive, local, remote,
                        received, ov);
}
int WSAAPI HookWSAIoctl(SOCKET s, DWORD code, LPVOID input, DWORD input_size,
                        LPVOID output, DWORD output_size, LPDWORD returned,
                        LPWSAOVERLAPPED ov,
                        LPWSAOVERLAPPED_COMPLETION_ROUTINE completion) {
  auto original = Original<decltype(&WSAIoctl)>(winsock_thunks, "WSAIoctl");
  if (code == SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER)
    return Fail(WSAEOPNOTSUPP);
  if (code == SIO_GET_EXTENSION_FUNCTION_POINTER && input &&
      input_size == sizeof(GUID) && output && output_size >= sizeof(void *)) {
    const GUID connect_id = WSAID_CONNECTEX, accept_id = WSAID_ACCEPTEX;
    bool connect_match = true, accept_match = true;
    for (unsigned i = 0; i < sizeof(GUID); ++i) {
      connect_match &= static_cast<BYTE *>(input)[i] ==
                       reinterpret_cast<const BYTE *>(&connect_id)[i];
      accept_match &= static_cast<BYTE *>(input)[i] ==
                      reinterpret_cast<const BYTE *>(&accept_id)[i];
    }
    const int result = original(s, code, input, input_size, output, output_size,
                                returned, ov, completion);
    if (result == 0) {
      if (connect_match) {
        real_connect_ex = *reinterpret_cast<LPFN_CONNECTEX *>(output);
        *reinterpret_cast<LPFN_CONNECTEX *>(output) = HookConnectEx;
      }
      if (accept_match) {
        real_accept_ex = *reinterpret_cast<LPFN_ACCEPTEX *>(output);
        *reinterpret_cast<LPFN_ACCEPTEX *>(output) = HookAcceptEx;
      }
    }
    return result;
  }
  return original(s, code, input, input_size, output, output_size, returned, ov,
                  completion);
}
int WSAAPI HookGetPeerName(SOCKET s, sockaddr *address, int *length) {
  Socket e = Snapshot(s);
  if (e.used && e.kind == App && e.connected && e.logical_size) {
    if (!address || !length || *length < e.logical_size)
      return Fail(WSAEFAULT);
    Copy(address, &e.logical, static_cast<SIZE_T>(e.logical_size));
    *length = e.logical_size;
    return 0;
  }
  return Original<decltype(&getpeername)>(winsock_thunks,
                                          "getpeername")(s, address, length);
}
int WSAAPI HookSendTo(SOCKET, const char *, int, int, const sockaddr *, int) {
  return Fail();
}
int WSAAPI HookWSASendTo(SOCKET, LPWSABUF, DWORD, LPDWORD, DWORD,
                         const sockaddr *, int, LPWSAOVERLAPPED,
                         LPWSAOVERLAPPED_COMPLETION_ROUTINE) {
  return Fail();
}
int WSAAPI HookWSADuplicateSocketW(SOCKET, DWORD, LPWSAPROTOCOL_INFOW) {
  return Fail();
}
int WSAAPI HookWSADuplicateSocketA(SOCKET, DWORD, LPWSAPROTOCOL_INFOA) {
  return Fail();
}
int WSAAPI HookListen(SOCKET s, int backlog) {
  if (Snapshot(s).kind != Listener)
    return Fail();
  return Original<decltype(&listen)>(winsock_thunks, "listen")(s, backlog);
}

// Native AFD gate: even a raw ntdll export cannot connect an unapproved handle.
bool HasEndpoint(const Socket &s, const BYTE *input, ULONG size,
                 ULONG operation) {
  if (!input || size > 512)
    return false;
  BYTE wanted[8]{};
  wanted[0] = AF_INET;
  if (s.kind == Upstream) {
    wanted[2] = static_cast<BYTE>(upstream_port >> 8);
    wanted[3] = static_cast<BYTE>(upstream_port);
    Copy(wanted + 4, upstream_ip, 4);
  } else {
    wanted[2] = static_cast<BYTE>(s.bridge_port >> 8);
    wanted[3] = static_cast<BYTE>(s.bridge_port);
    wanted[4] = 127;
    wanted[7] = 1;
  }
  __try {
    // 19045 TLI layouts: CONNECT has two handles before its sockaddr;
    // SUPER_CONNECT has a BOOLEAN and an aligned sockaddr. No payload scan.
    ULONG offset = operation == 1 ? 24u : 2u;
    const ULONG tdi = operation == 1 ? 24u : 4u;
    // A base-provider WSAPROTOCOL_INFO can select TDI rather than TLI.
    // TRANSPORT_ADDRESS must contain exactly one IPv4 address.
    if (size >= tdi + 8 && *reinterpret_cast<const ULONG *>(input + tdi) == 1) {
      const USHORT address_length =
          *reinterpret_cast<const USHORT *>(input + tdi + 4);
      const USHORT type = *reinterpret_cast<const USHORT *>(input + tdi + 6);
      if (type != AF_INET || address_length != 14)
        return false;
      if (size != tdi + 8 + address_length)
        return false;
      offset = tdi + 6;
    }
    if (size < offset + sizeof(sockaddr_in))
      return false;
    input += offset;
    size -= offset;
    for (ULONG i = 0; i == 0 && i + sizeof(wanted) <= size; ++i) {
      bool match = true;
      for (unsigned j = 0; j < sizeof(wanted); ++j)
        match &= input[i + j] == wanted[j];
      if (match)
        return true;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  return false;
}
NTSTATUS NativeDenied(PIO_STATUS_BLOCK io) {
  Count(diagnostic.native_denials);
  Count(diagnostic.denied_calls);
  __try {
    if (io) {
      io->Status = access_denied;
      io->Information = 0;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
  return access_denied;
}
NTSTATUS RejectNative(PIO_STATUS_BLOCK io, ULONG code, const void *input,
                      ULONG length) {
  diagnostic.denied_ioctl = code;
  diagnostic.denied_input_size = length;
  __try {
    if (input)
      Copy(diagnostic.denied_input, input, length < 32 ? length : 32);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
  return NativeDenied(io);
}
// Windows 19045 AFD_TL_IO_CONTROL_INFO. Only non-transmitting socket controls.
struct TransportControl {
  ULONG type, level, code;
  BYTE endpoint;
  BYTE padding[3];
  PVOID input;
  SIZE_T length;
};
static_assert(sizeof(TransportControl) == 32);
bool SafeTransportControl(const void *input, ULONG size) {
  if (!input || size != sizeof(TransportControl))
    return false;
  __try {
    const auto &control = *static_cast<const TransportControl *>(input);
    if (!control.endpoint)
      return false;
    if (control.type == 2)
      return control.level == SOL_SOCKET || control.level == IPPROTO_TCP ||
             control.level == IPPROTO_IP || control.level == IPPROTO_IPV6;
    if (control.type == 3)
      return control.level == 0 &&
             (control.code == FIONBIO || control.code == FIONREAD ||
              control.code == SIOCATMARK ||
              control.code == SIO_ADDRESS_LIST_SORT ||
              (control.code == SIO_KEEPALIVE_VALS &&
               control.length == sizeof(tcp_keepalive)));
    if (control.type != 1)
      return false;
    if (control.level == IPPROTO_TCP)
      return true;
    if (control.level == SOL_SOCKET)
      return control.code == SO_KEEPALIVE || control.code == SO_SNDBUF ||
             control.code == SO_RCVBUF || control.code == SO_SNDTIMEO ||
             control.code == SO_RCVTIMEO || control.code == SO_LINGER ||
             control.code == SO_REUSEADDR ||
             control.code == SO_EXCLUSIVEADDRUSE ||
             control.code == SO_UPDATE_CONNECT_CONTEXT ||
             control.code == SO_UPDATE_ACCEPT_CONTEXT ||
             control.code == SO_REUSE_UNICASTPORT;
    if (control.level == IPPROTO_IP)
      return control.code == IP_UNICAST_IF || control.code == IP_TTL ||
             control.code == IP_TOS || control.code == IP_DONTFRAGMENT;
    if (control.level == IPPROTO_IPV6)
      return control.code == IPV6_UNICAST_IF || control.code == IPV6_V6ONLY;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  return false;
}
NTSTATUS NTAPI HookNtDeviceIoControlFile(HANDLE file, HANDLE event,
                                         PIO_APC_ROUTINE apc, PVOID context,
                                         PIO_STATUS_BLOCK io, ULONG code,
                                         PVOID input, ULONG length,
                                         PVOID output, ULONG capacity) {
  Count(diagnostic.native_calls);
  diagnostic.last_native_ioctl = code;
  if ((code >> 12) == 0x12) {
    const ULONG operation = (code & 0xfff) >> 2;
    Socket socket = Snapshot(reinterpret_cast<SOCKET>(file));
    if (operation == 1 || operation == 49) {
      // Classic connect can be issued on Winsock's AFD helper handle. The
      // endpoint to authorize is ConnectEndpoint, not that helper handle.
      if (operation == 1 && input && length >= 24) {
        __try {
          const SOCKET endpoint = *reinterpret_cast<const SOCKET *>(
              static_cast<const BYTE *>(input) + 16);
          if (endpoint)
            socket = Snapshot(endpoint);
        } __except (EXCEPTION_EXECUTE_HANDLER) {
          return RejectNative(io, code, nullptr, 0);
        }
      }
      diagnostic.last_connect_input_size = length;
      diagnostic.last_connect_ioctl = code;
      __try {
        Copy(diagnostic.last_connect_input, input, length < 32 ? length : 32);
      } __except (EXCEPTION_EXECUTE_HANDLER) {
      }
      if (!socket.used ||
          (socket.kind != Upstream &&
           !(socket.kind == App && socket.connected)) ||
          !HasEndpoint(socket, static_cast<const BYTE *>(input), length,
                       operation))
        return RejectNative(io, code, input, length);
    } else if (operation == 47) {
      if (!SafeTransportControl(input, length))
        return RejectNative(io, code, input, length);
    } else if (operation == 6 || operation == 8)
      return RejectNative(io, code, input, length);
    else if (operation == 2 || operation == 3 || operation == 4 ||
             operation == 32) {
      if (socket.kind != Listener && socket.kind != Accepted)
        return RejectNative(io, code, input, length);
    } else if (operation == 5 || operation == 7 || operation == 10) {
      if (!socket.used ||
          !(socket.kind == Upstream || socket.kind == Accepted ||
            (socket.kind == App && socket.connected)))
        return RejectNative(io, code, input, length);
    } else if (!(operation == 0 || operation == 9 ||
                 (operation >= 11 && operation <= 17) || operation == 30 ||
                 operation == 33 || operation == 34 || operation == 41 ||
                 operation == 42 || operation == 43 || operation == 44 ||
                 operation == 45))
      return RejectNative(io, code, input, length);
  }
  return Original<decltype(&NtDeviceIoControlFile)>(native_thunks,
                                                    "NtDeviceIoControlFile")(
      file, event, apc, context, io, code, input, length, output, capacity);
}
bool AfdName(POBJECT_ATTRIBUTES oa) {
  if (!oa || !oa->ObjectName || !oa->ObjectName->Buffer)
    return false;
  const auto *p = oa->ObjectName->Buffer;
  const auto n = static_cast<unsigned>(oa->ObjectName->Length / 2);
  const WCHAR prefix[] = L"\\device\\afd";
  if (n < 11)
    return false;
  for (unsigned i = 0; i < 11; ++i) {
    WCHAR c = p[i];
    if (c >= L'A' && c <= L'Z')
      c += 32;
    if (c != prefix[i])
      return false;
  }
  return n == 11 || p[11] == L'\\';
}
bool UntrackedAfd(HANDLE file) {
  alignas(8) BYTE storage[1024]{};
  ULONG actual = 0;
  if (NtQueryObject(file, static_cast<OBJECT_INFORMATION_CLASS>(1), storage,
                    sizeof(storage), &actual) < 0)
    return false;
  OBJECT_ATTRIBUTES oa{};
  oa.ObjectName = reinterpret_cast<UNICODE_STRING *>(storage);
  return AfdName(&oa);
}
NTSTATUS NTAPI HookNtCreateFile(PHANDLE file, ACCESS_MASK access,
                                POBJECT_ATTRIBUTES oa, PIO_STATUS_BLOCK io,
                                PLARGE_INTEGER allocation, ULONG attributes,
                                ULONG share, ULONG disposition, ULONG options,
                                PVOID ea, ULONG ea_size) {
  auto original =
      Original<decltype(&NtCreateFile)>(native_thunks, "NtCreateFile");
  const NTSTATUS st = original(file, access, oa, io, allocation, attributes,
                               share, disposition, options, ea, ea_size);
  if (st >= 0 && file && AfdName(oa))
    Register(reinterpret_cast<SOCKET>(*file), 0);
  return st;
}
NTSTATUS NTAPI HookNtOpenFile(PHANDLE file, ACCESS_MASK access,
                              POBJECT_ATTRIBUTES oa, PIO_STATUS_BLOCK io,
                              ULONG share, ULONG options) {
  const NTSTATUS st = Original<decltype(&NtOpenFile)>(
      native_thunks, "NtOpenFile")(file, access, oa, io, share, options);
  if (st >= 0 && file && AfdName(oa))
    Register(reinterpret_cast<SOCKET>(*file), 0);
  return st;
}
NTSTATUS NTAPI HookNtClose(HANDLE file) {
  const auto before = Snapshot(reinterpret_cast<SOCKET>(file));
  if (before.used)
    BeginSocketClose(before);
  ReleaseSocket(before);
  const NTSTATUS st =
      Original<decltype(&NtClose)>(native_thunks, "NtClose")(file);
  if (st >= 0 && before.used)
    Forget(before.handle, before.generation);
  return st;
}
NTSTATUS NTAPI HookNtReadFile(HANDLE file, HANDLE event, PVOID apc,
                              PVOID context, PIO_STATUS_BLOCK io, PVOID buffer,
                              ULONG size, PLARGE_INTEGER offset, PULONG key) {
  Socket s = Snapshot(reinterpret_cast<SOCKET>(file));
  if (s.used && s.kind == App && (!s.connected || s.closing))
    return NativeDenied(io);
  return Original<decltype(&NtReadFile)>(native_thunks, "NtReadFile")(
      file, event, apc, context, io, buffer, size, offset, key);
}
NTSTATUS NTAPI HookNtWriteFile(HANDLE file, HANDLE event, PIO_APC_ROUTINE apc,
                               PVOID context, PIO_STATUS_BLOCK io, PVOID buffer,
                               ULONG size, PLARGE_INTEGER offset, PULONG key) {
  Socket s = Snapshot(reinterpret_cast<SOCKET>(file));
  if (s.used && s.kind == App && (!s.connected || s.closing))
    return NativeDenied(io);
  return Original<decltype(&NtWriteFile)>(native_thunks, "NtWriteFile")(
      file, event, apc, context, io, buffer, size, offset, key);
}

PVOID Redirect(PVOID address) {
  verifier::ThunkDescriptor *tables[] = {
      winsock_thunks, native_thunks, kernel_thunks, base_thunks,
      dns_thunks,     http_thunks,   inet_thunks,   icmp_thunks};
  for (auto *table : tables)
    for (auto *t = table; t->name; ++t)
      if (t->old_address && t->old_address == address)
        return t->new_address;
  const WCHAR *names[] = {L"ws2_32.dll",     L"ntdll.dll",   L"kernel32.dll",
                          L"kernelbase.dll", L"dnsapi.dll",  L"winhttp.dll",
                          L"wininet.dll",    L"iphlpapi.dll"};
  for (unsigned i = 0; i < 8; ++i)
    for (auto *t = tables[i]; t->name; ++t)
      if (t->old_address && Raw(names[i], t->name) == address)
        return t->new_address;
  return address;
}
FARPROC WINAPI HookGetProcAddress(HMODULE module, LPCSTR symbol) {
  Count(diagnostic.dynamic_lookups);
#if defined(CDF_NETWORK_CLAUDE_IDENTITY)
  // The previous Verifier provider owns browser consent. A raw lookup here
  // would bypass its checks when the browser entry point is delay-loaded.
  auto entry = kernel_thunks[0].old_address;
  if (!entry)
    entry = base_thunks[0].old_address;
  const auto previous = reinterpret_cast<decltype(&GetProcAddress)>(entry);
  FARPROC consent_export = nullptr;
  if (previous != &HookGetProcAddress &&
      browser_consent::ForwardShellLookup(previous, module, symbol, consent_export))
    return consent_export;
#endif
  ANSI_STRING name{};
  const auto ordinal = reinterpret_cast<ULONG_PTR>(symbol);
  if (ordinal > 0xffff)
    RtlInitAnsiString(&name, symbol);
  PVOID result = nullptr;
  const NTSTATUS st = LdrGetProcedureAddress(
      module, ordinal > 0xffff ? &name : nullptr,
      ordinal > 0xffff ? 0 : static_cast<ULONG>(ordinal), &result);
  if (st < 0) {
    RtlSetLastWin32Error(RtlNtStatusToDosError(st));
    return nullptr;
  }
  return reinterpret_cast<FARPROC>(Redirect(result));
}
NTSTATUS NTAPI HookLdrGetProcedureAddress(PVOID module, const ANSI_STRING *name,
                                          ULONG ordinal, PVOID *output) {
  Count(diagnostic.dynamic_lookups);
  auto original = Original<decltype(&LdrGetProcedureAddress)>(
      native_thunks, "LdrGetProcedureAddress");
  const NTSTATUS st = original(module, name, ordinal, output);
  if (st >= 0 && output)
    *output = Redirect(*output);
  return st;
}
NTSTATUS NTAPI HookLdrGetProcedureAddressEx(PVOID module,
                                            const ANSI_STRING *name,
                                            ULONG ordinal, PVOID *output,
                                            ULONG flags) {
  auto original = Original<decltype(&LdrGetProcedureAddressEx)>(
      native_thunks, "LdrGetProcedureAddressEx");
  const NTSTATUS st = original(module, name, ordinal, output, flags);
  if (st >= 0 && output)
    *output = Redirect(*output);
  return st;
}
NTSTATUS NTAPI HookLdrGetProcedureAddressForCaller(PVOID module,
                                                   const ANSI_STRING *name,
                                                   ULONG ordinal, PVOID *output,
                                                   ULONG flags, PVOID caller) {
  auto original = Original<decltype(&LdrGetProcedureAddressForCaller)>(
      native_thunks, "LdrGetProcedureAddressForCaller");
  const NTSTATUS st = original(module, name, ordinal, output, flags, caller);
  if (st >= 0 && output)
    *output = Redirect(*output);
  return st;
}

// DNS implementations share only the transport C ABI, not Xray internals.
int WSAAPI HookGetAddrInfoA(PCSTR, PCSTR, const ADDRINFOA *, PADDRINFOA *);
int WSAAPI HookGetAddrInfoW(PCWSTR, PCWSTR, const ADDRINFOW *, PADDRINFOW *);
void WSAAPI HookFreeAddrInfoA(PADDRINFOA);
void WSAAPI HookFreeAddrInfoW(PADDRINFOW);
#include "network_dns.inc"
#include "network_iat.inc"
verifier::ThunkDescriptor http_thunks[] = {
    {const_cast<PCHAR>("WinHttpOpen"), nullptr,
     reinterpret_cast<PVOID>(&HookWinHttpOpen)},
    {const_cast<PCHAR>("WinHttpConnect"), nullptr,
     reinterpret_cast<PVOID>(&HookWinHttpConnect)},
    {const_cast<PCHAR>("WinHttpSendRequest"), nullptr,
     reinterpret_cast<PVOID>(&HookWinHttpSendRequest)},
    {const_cast<PCHAR>("WinHttpGetProxyForUrl"), nullptr,
     reinterpret_cast<PVOID>(&HookWinHttpGetProxyForUrl)},
    {const_cast<PCHAR>("WinHttpGetProxyForUrlEx"), nullptr,
     reinterpret_cast<PVOID>(&HookWinHttpGetProxyForUrlEx)},
    {const_cast<PCHAR>("WinHttpDetectAutoProxyConfigUrl"), nullptr,
     reinterpret_cast<PVOID>(&HookWinHttpDetectAutoProxyConfigUrl)},
    {}};
verifier::ThunkDescriptor inet_thunks[] = {
    {const_cast<PCHAR>("InternetOpenW"), nullptr,
     reinterpret_cast<PVOID>(&HookInternetOpenW)},
    {const_cast<PCHAR>("InternetOpenA"), nullptr,
     reinterpret_cast<PVOID>(&HookInternetOpenA)},
    {}};
#define T(name, hook)                                                          \
  {const_cast<PCHAR>(name), nullptr, reinterpret_cast<PVOID>(&hook)}
HANDLE WINAPI HookIcmpCreate() {
  Api(29);
  Count(diagnostic.denied_calls);
  RtlSetLastWin32Error(ERROR_ACCESS_DENIED);
  return INVALID_HANDLE_VALUE;
}
DWORD WINAPI HookIcmpSend(...) {
  Api(29);
  Count(diagnostic.denied_calls);
  RtlSetLastWin32Error(ERROR_ACCESS_DENIED);
  return 0;
}
verifier::ThunkDescriptor icmp_thunks[] = {T("IcmpCreateFile", HookIcmpCreate),
                                           T("Icmp6CreateFile", HookIcmpCreate),
                                           T("IcmpSendEcho", HookIcmpSend),
                                           T("IcmpSendEcho2", HookIcmpSend),
                                           T("IcmpSendEcho2Ex", HookIcmpSend),
                                           T("Icmp6SendEcho2", HookIcmpSend),
                                           {}};
verifier::ThunkDescriptor winsock_thunks[] = {
    T("socket", HookSocket),
    T("WSASocketW", HookWSASocketW),
    T("WSASocketA", HookWSASocketA),
    T("connect", HookConnect),
    T("WSAConnect", HookWSAConnect),
    T("closesocket", HookCloseSocket),
    T("ioctlsocket", HookIoctlSocket),
    T("WSAIoctl", HookWSAIoctl),
    T("WSAGetOverlappedResult", HookWSAGetOverlappedResult),
    T("getpeername", HookGetPeerName),
    T("sendto", HookSendTo),
    T("WSASendTo", HookWSASendTo),
    T("WSADuplicateSocketW", HookWSADuplicateSocketW),
    T("WSADuplicateSocketA", HookWSADuplicateSocketA),
    T("listen", HookListen),
    T("getaddrinfo", HookGetAddrInfoA),
    T("GetAddrInfoW", HookGetAddrInfoW),
    T("freeaddrinfo", HookFreeAddrInfoA),
    T("FreeAddrInfoW", HookFreeAddrInfoW),
    T("GetAddrInfoExW", HookGetAddrInfoExW),
    T("GetAddrInfoExA", HookGetAddrInfoExA),
    T("FreeAddrInfoExW", HookFreeAddrInfoExW),
    T("GetAddrInfoExCancel", HookGetAddrInfoExCancel),
    T("GetAddrInfoExOverlappedResult", HookGetAddrInfoExOverlappedResult),
    T("gethostbyname", HookGetHostByName),
    T("gethostbyaddr", HookGetHostByAddr),
    T("WSAAsyncGetHostByName", HookWSAAsyncGetHostByName),
    T("WSAAsyncGetHostByAddr", HookWSAAsyncGetHostByAddr),
    T("WSALookupServiceBeginW", HookWSALookupServiceBeginW),
    T("WSALookupServiceBeginA", HookWSALookupServiceBeginA),
    {}};
verifier::ThunkDescriptor native_thunks[] = {
    T("NtSetInformationFile", HookNtSetInformationFile),
    T("ZwSetInformationFile", HookNtSetInformationFile),
    T("NtDeviceIoControlFile", HookNtDeviceIoControlFile),
    T("ZwDeviceIoControlFile", HookNtDeviceIoControlFile),
    T("NtCreateFile", HookNtCreateFile),
    T("ZwCreateFile", HookNtCreateFile),
    T("NtOpenFile", HookNtOpenFile),
    T("ZwOpenFile", HookNtOpenFile),
    T("NtReadFile", HookNtReadFile),
    T("ZwReadFile", HookNtReadFile),
    T("NtWriteFile", HookNtWriteFile),
    T("ZwWriteFile", HookNtWriteFile),
    T("NtClose", HookNtClose),
    T("ZwClose", HookNtClose),
    T("LdrGetProcedureAddress", HookLdrGetProcedureAddress),
    T("LdrGetProcedureAddressEx", HookLdrGetProcedureAddressEx),
    T("LdrGetProcedureAddressForCaller", HookLdrGetProcedureAddressForCaller),
    T("LdrResolveDelayLoadedAPI", HookLdrResolveDelayLoadedAPI),
    {}};
verifier::ThunkDescriptor kernel_thunks[] = {
    T("GetProcAddress", HookGetProcAddress),
    T("GetOverlappedResult", HookGetOverlappedResult),
    T("CancelIoEx", HookCancelIoEx),
    {}};
verifier::ThunkDescriptor base_thunks[] = {
    T("GetProcAddress", HookGetProcAddress),
    T("GetOverlappedResult", HookGetOverlappedResult),
    T("CancelIoEx", HookCancelIoEx),
    {}};
#undef T
verifier::DllDescriptor dlls[] = {
    {const_cast<PWSTR>(L"ntdll.dll"), 0, nullptr, native_thunks},
    {const_cast<PWSTR>(L"kernelbase.dll"), 0, nullptr, base_thunks},
    {const_cast<PWSTR>(L"kernel32.dll"), 0, nullptr, kernel_thunks},
    {const_cast<PWSTR>(L"ws2_32.dll"), 0, nullptr, winsock_thunks},
    {const_cast<PWSTR>(L"dnsapi.dll"), 0, nullptr, dns_thunks},
    {const_cast<PWSTR>(L"winhttp.dll"), 0, nullptr, http_thunks},
    {const_cast<PWSTR>(L"wininet.dll"), 0, nullptr, inet_thunks},
    {const_cast<PWSTR>(L"iphlpapi.dll"), 0, nullptr, icmp_thunks},
    {const_cast<PWSTR>(L"icmp.dll"), 0, nullptr, icmp_thunks},
    {}};
void NTAPI Loaded(PWSTR, PVOID, SIZE_T, PVOID) {
  PatchAllImports();
  ULONG count = 0;
  for (auto *d = dlls; d->name; ++d)
    for (auto *t = d->thunks; t && t->name; ++t)
      if (t->old_address)
        ++count;
  diagnostic.installed_hooks = count;
}
verifier::ProviderDescriptor provider{sizeof(verifier::ProviderDescriptor),
                                      dlls,
                                      Loaded,
                                      nullptr,
                                      nullptr,
                                      0,
                                      0,
                                      nullptr,
                                      nullptr,
                                      nullptr,
                                      nullptr};
} // namespace cdf::network
extern "C" __declspec(dllexport) DWORD WINAPI
CdfNetworkQueryStatus(CdfNetworkStatus *output, DWORD size) {
  using namespace cdf::network;
  if (!output || size < sizeof(*output))
    return ERROR_INSUFFICIENT_BUFFER;
  diagnostic.verifier_flags = provider.verifier_flags;
  ULONG count = 0;
  for (const auto &s : sockets)
    if (s.used)
      ++count;
  diagnostic.socket_count = count;
  Copy(output, &diagnostic, sizeof(diagnostic));
  return ERROR_SUCCESS;
}
extern "C" BOOL WINAPI CdfNetworkEntry(HINSTANCE instance, DWORD reason,
                                       LPVOID reserved) {
  using namespace cdf::network;
#if defined(CDF_NETWORK_CLAUDE_IDENTITY)
  static bool admitted=false;
  static cdf::verifier::DllDescriptor no_dlls[]={{}};
  static cdf::verifier::ProviderDescriptor no_hooks{sizeof(cdf::verifier::ProviderDescriptor),no_dlls,nullptr,nullptr,nullptr,0,0,nullptr,nullptr,nullptr,nullptr};
  if(reason==cdf::verifier::process_verifier){
    if(!reserved)return FALSE;
    admitted=cdf::claude::MatchesCurrentImage();
    if(!admitted){
      if(cdf::claude::BlockUnverifiedImage())return FALSE;
      *static_cast<cdf::verifier::ProviderDescriptor**>(reserved)=&no_hooks;return TRUE;
    }
  }else if(!admitted)return TRUE;
#endif
  self_module = instance;
  if (reason == cdf::verifier::process_verifier) {
    if (!reserved)
      return FALSE;
    *static_cast<cdf::verifier::ProviderDescriptor **>(reserved) = &provider;
    diagnostic.state |= CdfNetworkHandshake;
    RTL_OSVERSIONINFOW version{};
    version.dwOSVersionInfoSize = sizeof(version);
    if (RtlGetVersion(&version) < 0 || version.dwBuildNumber != 19045) {
      diagnostic.state |= CdfNetworkFailed;
      diagnostic.error_stage = 1;
      diagnostic.error_code = ERROR_OLD_WIN_VERSION;
      return FALSE;
    }
    if (LoadPolicy())
      diagnostic.state |= CdfNetworkPolicyReady;
    else {
      diagnostic.state |= CdfNetworkFailed;
      diagnostic.error_stage = 2;
      diagnostic.error_code = ERROR_INVALID_DATA;
    }
    diagnostic.state |= CdfNetworkHooksReady | CdfNetworkIPv4Only;
    PatchAllImports();
  } else if (reason == DLL_PROCESS_ATTACH)
    diagnostic.state |= CdfNetworkAttached;
  return TRUE;
}
