// Included inside cdf::network. All DNS wire traffic is carried by
// transport_dns.
constexpr unsigned dns_capacity = 65535;
PVOID Heap() { return *reinterpret_cast<void **>(__readgsqword(0x60) + 0x30); }
ULONG text_length(const char *s) {
  ULONG n = 0;
  while (s && s[n])
    ++n;
  return n;
}
bool AsciiHost(const WCHAR *input, char (&output)[256]) {
  if (!input)
    return false;
  bool colon = false;
  unsigned ascii_length = 0;
  for (; input[ascii_length] && ascii_length < 255; ++ascii_length) {
    if (input[ascii_length] > 127)
      break;
    if (input[ascii_length] == L':')
      colon = true;
    output[ascii_length] = static_cast<char>(input[ascii_length]);
  }
  if (colon && !input[ascii_length]) {
    output[ascii_length] = 0;
    return true;
  }
  WCHAR ascii[256]{};
  auto idn = System<decltype(&IdnToAscii)>("IdnToAscii");
  if (!idn || idn(IDN_USE_STD3_ASCII_RULES, input, -1, ascii, 256) == 0)
    return false;
  ULONG n = 0;
  while (ascii[n] && n < 255) {
    if (ascii[n] > 127)
      return false;
    output[n] = static_cast<char>(ascii[n]);
    ++n;
  }
  output[n] = 0;
  return n > 0 && n < 255;
}
USHORT Read16(const BYTE *p) { return static_cast<USHORT>((p[0] << 8) | p[1]); }
void Write16(BYTE *p, USHORT n) {
  p[0] = static_cast<BYTE>(n >> 8);
  p[1] = static_cast<BYTE>(n);
}
volatile LONG query_sequence = 0;
int QueryWire(const char *name, USHORT type, BYTE *response, ULONG capacity,
              ULONG &received) {
  if (!name || !response || !EnsureTransport())
    return WSATRY_AGAIN;
  if (type == DNS_TYPE_AAAA && !transport_dns_ipv4)
    return WSANO_DATA;
  const ULONG n = text_length(name);
  if (n == 0 || n > 253)
    return WSAHOST_NOT_FOUND;
  BYTE request[272]{};
  Write16(request, static_cast<USHORT>(_InterlockedIncrement(&query_sequence)));
  request[2] = 1;
  request[5] = 1;
  ULONG cursor = 12, start = 0;
  for (ULONG i = 0; i <= n; ++i) {
    if (name[i] == '.' || i == n) {
      const ULONG size = i - start;
      if (size == 0) {
        if (i == n && i > 0 && name[i - 1] == '.')
          break;
        return WSAHOST_NOT_FOUND;
      }
      if (size > 63)
        return WSAHOST_NOT_FOUND;
      request[cursor++] = static_cast<BYTE>(size);
      for (ULONG k = start; k < i; ++k) {
        const auto c = static_cast<BYTE>(name[k]);
        if (c < 33 || c > 126)
          return WSAHOST_NOT_FOUND;
        request[cursor++] = c;
      }
      start = i + 1;
    }
  }
  request[cursor++] = 0;
  Write16(request + cursor, type);
  Write16(request + cursor + 2, 1);
  cursor += 4;
  Count(diagnostic.dns_queries);
  uint32_t actual = 0;
  const int error = transport_dns(request, cursor, response, capacity, &actual);
  received = actual;
  if (error)
    return error;
  if (received < 12 || Read16(response) != Read16(request) ||
      (response[2] & 0x80) == 0)
    return WSATRY_AGAIN;
  const unsigned rcode = response[3] & 15;
  if (rcode == 3)
    return WSAHOST_NOT_FOUND;
  if (rcode != 0)
    return WSATRY_AGAIN;
  return 0;
}
bool SkipName(const BYTE *data, ULONG size, ULONG &cursor) {
  for (unsigned labels = 0; labels < 128 && cursor < size; ++labels) {
    const BYTE n = data[cursor++];
    if (n == 0)
      return true;
    if ((n & 0xc0) == 0xc0) {
      if (cursor >= size)
        return false;
      const ULONG destination = ((n & 0x3f) << 8) | data[cursor++];
      return destination < size;
    }
    if (n > 63 || cursor + n > size)
      return false;
    cursor += n;
  }
  return false;
}
int CollectIPv4(const char *host, IN_ADDR *addresses, unsigned &count) {
  auto *response =
      static_cast<BYTE *>(RtlAllocateHeap(Heap(), 0, dns_capacity));
  if (!response)
    return WSA_NOT_ENOUGH_MEMORY;
  ULONG size = 0;
  int error = QueryWire(host, DNS_TYPE_A, response, dns_capacity, size);
  if (error == 0) {
    ULONG cursor = 12;
    const ULONG questions = Read16(response + 4),
                answers = Read16(response + 6);
    for (ULONG i = 0; i < questions; ++i) {
      if (!SkipName(response, size, cursor) || cursor + 4 > size) {
        error = WSANO_RECOVERY;
        break;
      }
      cursor += 4;
    }
    for (ULONG i = 0; error == 0 && i < answers && count < 32; ++i) {
      if (!SkipName(response, size, cursor) || cursor + 10 > size) {
        error = WSANO_RECOVERY;
        break;
      }
      const USHORT record_type = Read16(response + cursor),
                   record_class = Read16(response + cursor + 2),
                   length = Read16(response + cursor + 8);
      cursor += 10;
      if (cursor + length > size) {
        error = WSANO_RECOVERY;
        break;
      }
      if (record_class == 1 && record_type == DNS_TYPE_A &&
          length == sizeof(IN_ADDR))
        Copy(&addresses[count++], response + cursor, length);
      cursor += length;
    }
  }
  RtlFreeHeap(Heap(), 0, response);
  return error;
}
struct AddrNodeA {
  ADDRINFOA info;
  sockaddr_storage address;
  char canonical[256];
};
struct AddrNodeW {
  ADDRINFOW info;
  sockaddr_storage address;
  WCHAR canonical[256];
};
struct Allocation {
  void *pointer;
  ULONG type;
};
Allocation address_allocations[1024]{};
SRWLOCK allocation_lock{};
bool TrackAllocation(void *pointer, ULONG type) {
  bool ok = false;
  RtlAcquireSRWLockExclusive(&allocation_lock);
  for (auto &a : address_allocations)
    if (!a.pointer) {
      a = {pointer, type};
      ok = true;
      break;
    }
  RtlReleaseSRWLockExclusive(&allocation_lock);
  return ok;
}
bool OwnAllocation(void *pointer, ULONG type) {
  bool found = false;
  RtlAcquireSRWLockExclusive(&allocation_lock);
  for (auto &a : address_allocations)
    if (a.pointer == pointer && (type == 0 || a.type == type)) {
      a.pointer = nullptr;
      found = true;
      break;
    }
  RtlReleaseSRWLockExclusive(&allocation_lock);
  return found;
}
bool ServicePort(const char *service, USHORT &port) {
  port = 0;
  if (!service)
    return true;
  if (Equal(service, "https")) {
    port = 443;
    return true;
  }
  if (Equal(service, "http")) {
    port = 80;
    return true;
  }
  if (Equal(service, "domain")) {
    port = 53;
    return true;
  }
  ULONG n = 0;
  for (unsigned i = 0; service[i]; ++i) {
    if (service[i] < '0' || service[i] > '9' || i > 4)
      return false;
    n = n * 10 + static_cast<ULONG>(service[i] - '0');
    if (n > 65535)
      return false;
  }
  port = static_cast<USHORT>(n);
  return true;
}
int WSAAPI HookGetAddrInfoA(PCSTR host, PCSTR service, const ADDRINFOA *hints,
                            PADDRINFOA *output) {
  Api(3, hints ? static_cast<ULONG>(hints->ai_flags) : 0,
      hints ? static_cast<ULONG>(hints->ai_family) : 0,
      hints ? static_cast<ULONG>(hints->ai_socktype) : 0);
  if (!output)
    return WSAEFAULT;
  *output = nullptr;
  const int family = hints ? hints->ai_family : AF_UNSPEC,
            flags = hints ? hints->ai_flags : 0;
  const int allowed = AI_PASSIVE | AI_CANONNAME | AI_NUMERICHOST |
                      AI_NUMERICSERV | AI_ADDRCONFIG | AI_V4MAPPED | AI_ALL |
                      AI_DNS_ONLY | AI_FQDN | AI_BYPASS_DNS_CACHE |
                      AI_DISABLE_IDN_ENCODING;
  if ((flags & ~allowed) != 0)
    return WSAEINVAL;
  if (family != AF_UNSPEC && family != AF_INET)
    return WSAEAFNOSUPPORT;
  if (hints &&
      ((hints->ai_socktype != 0 && hints->ai_socktype != SOCK_STREAM) ||
       (hints->ai_protocol != 0 && hints->ai_protocol != IPPROTO_TCP)))
    return WSAESOCKTNOSUPPORT;
  USHORT port = 0;
  if (!ServicePort(service, port))
    return WSATYPE_NOT_FOUND;
  if ((flags & AI_NUMERICSERV) && service)
    for (unsigned i = 0; service[i]; ++i)
      if (service[i] < '0' || service[i] > '9')
        return WSATYPE_NOT_FOUND;
  IN_ADDR addresses[32]{};
  unsigned count = 0;
  int error = 0;
  auto parse =
      reinterpret_cast<decltype(&InetPtonA)>(Raw(L"ws2_32.dll", "inet_pton"));
  if (!host) {
    if (!(flags & AI_PASSIVE))
      addresses[0].S_un.S_addr = 0x0100007f;
    count = 1;
  } else if (parse && parse(AF_INET, host, &addresses[0]) == 1) {
    count = 1;
  } else {
    // An IPv6 literal, including scoped and v4-mapped forms, cannot be a
    // hostname. Keep it out of the upstream DNS resolver.
    for (const char *p = host; *p; ++p)
      if (*p == ':')
        return WSAEAFNOSUPPORT;
    if (flags & AI_NUMERICHOST)
      return WSAHOST_NOT_FOUND;
    error = CollectIPv4(host, addresses, count);
  }
  if (count == 0)
    return error ? error : WSANO_DATA;
  auto *nodes = static_cast<AddrNodeA *>(
      RtlAllocateHeap(Heap(), HEAP_ZERO_MEMORY, sizeof(AddrNodeA) * count));
  if (!nodes)
    return WSA_NOT_ENOUGH_MEMORY;
  if (!TrackAllocation(nodes, 1)) {
    RtlFreeHeap(Heap(), 0, nodes);
    return WSA_NOT_ENOUGH_MEMORY;
  }
  for (unsigned i = 0; i < count; ++i) {
    auto &n = nodes[i];
    n.info.ai_family = AF_INET;
    n.info.ai_socktype = SOCK_STREAM;
    n.info.ai_protocol = IPPROTO_TCP;
    n.info.ai_addr = reinterpret_cast<sockaddr *>(&n.address);
    n.info.ai_next = i + 1 < count ? &nodes[i + 1].info : nullptr;
    auto *a = reinterpret_cast<sockaddr_in *>(&n.address);
    a->sin_family = AF_INET;
    a->sin_port = _byteswap_ushort(port);
    a->sin_addr = addresses[i];
    n.info.ai_addrlen = sizeof(*a);
    if (i == 0 && (flags & (AI_CANONNAME | AI_FQDN))) {
      const ULONG length = text_length(host);
      Copy(n.canonical, host, length < 255 ? length : 255);
      n.info.ai_canonname = n.canonical;
    }
  }
  *output = &nodes[0].info;
  return 0;
}
void WSAAPI HookFreeAddrInfoA(PADDRINFOA pointer) {
  if (!pointer)
    return;
  if (OwnAllocation(pointer, 0)) {
    RtlFreeHeap(Heap(), 0, pointer);
    return;
  }
  Original<decltype(&freeaddrinfo)>(winsock_thunks, "freeaddrinfo")(pointer);
}
int WSAAPI HookGetAddrInfoW(PCWSTR host, PCWSTR service, const ADDRINFOW *hints,
                            PADDRINFOW *output) {
  Api(4);
  if (!output)
    return WSAEFAULT;
  *output = nullptr;
  char ascii[256]{}, service_ascii[64]{};
  if (host && !AsciiHost(host, ascii))
    return WSAHOST_NOT_FOUND;
  if (service) {
    unsigned i = 0;
    for (; service[i] && i < 63; ++i) {
      if (service[i] > 127)
        return WSATYPE_NOT_FOUND;
      service_ascii[i] = static_cast<char>(service[i]);
    }
    if (service[i])
      return WSATYPE_NOT_FOUND;
  }
  ADDRINFOA narrow_hints{};
  if (hints) {
    narrow_hints.ai_flags = hints->ai_flags;
    narrow_hints.ai_family = hints->ai_family;
    narrow_hints.ai_socktype = hints->ai_socktype;
    narrow_hints.ai_protocol = hints->ai_protocol;
  }
  ADDRINFOA *narrow = nullptr;
  const int error = HookGetAddrInfoA(host ? ascii : nullptr,
                                     service ? service_ascii : nullptr,
                                     hints ? &narrow_hints : nullptr, &narrow);
  if (error)
    return error;
  unsigned count = 0;
  for (auto *p = narrow; p; p = p->ai_next)
    ++count;
  auto *nodes = static_cast<AddrNodeW *>(
      RtlAllocateHeap(Heap(), HEAP_ZERO_MEMORY, sizeof(AddrNodeW) * count));
  if (!nodes) {
    HookFreeAddrInfoA(narrow);
    return WSA_NOT_ENOUGH_MEMORY;
  }
  if (!TrackAllocation(nodes, 2)) {
    RtlFreeHeap(Heap(), 0, nodes);
    HookFreeAddrInfoA(narrow);
    return WSA_NOT_ENOUGH_MEMORY;
  }
  auto *source = narrow;
  for (unsigned i = 0; i < count; ++i, source = source->ai_next) {
    auto &n = nodes[i];
    n.info.ai_flags = source->ai_flags;
    n.info.ai_family = source->ai_family;
    n.info.ai_socktype = source->ai_socktype;
    n.info.ai_protocol = source->ai_protocol;
    n.info.ai_addrlen = source->ai_addrlen;
    Copy(&n.address, source->ai_addr, source->ai_addrlen);
    n.info.ai_addr = reinterpret_cast<sockaddr *>(&n.address);
    n.info.ai_next = i + 1 < count ? &nodes[i + 1].info : nullptr;
    if (source->ai_canonname) {
      for (unsigned j = 0; source->ai_canonname[j] && j < 255; ++j)
        n.canonical[j] =
            static_cast<WCHAR>(static_cast<BYTE>(source->ai_canonname[j]));
      n.info.ai_canonname = n.canonical;
    }
  }
  HookFreeAddrInfoA(narrow);
  *output = &nodes[0].info;
  return 0;
}
void WSAAPI HookFreeAddrInfoW(PADDRINFOW pointer) {
  if (!pointer)
    return;
  if (OwnAllocation(pointer, 0)) {
    RtlFreeHeap(Heap(), 0, pointer);
    return;
  }
  Original<decltype(&FreeAddrInfoW)>(winsock_thunks, "FreeAddrInfoW")(pointer);
}
struct AddrNodeExW {
  ADDRINFOEXW info;
  sockaddr_storage address;
  WCHAR canonical[256];
};
int ResolveExW(PCWSTR host, PCWSTR service, const ADDRINFOEXW *hints,
               PADDRINFOEXW *result) {
  if (!result)
    return WSAEFAULT;
  *result = nullptr;
  ADDRINFOW plain_hints{};
  if (hints) {
    plain_hints.ai_flags = hints->ai_flags;
    plain_hints.ai_family = hints->ai_family;
    plain_hints.ai_socktype = hints->ai_socktype;
    plain_hints.ai_protocol = hints->ai_protocol;
  }
  ADDRINFOW *plain = nullptr;
  const int error =
      HookGetAddrInfoW(host, service, hints ? &plain_hints : nullptr, &plain);
  if (error)
    return error;
  unsigned count = 0;
  for (auto *p = plain; p; p = p->ai_next)
    ++count;
  auto *nodes = static_cast<AddrNodeExW *>(
      RtlAllocateHeap(Heap(), HEAP_ZERO_MEMORY, sizeof(AddrNodeExW) * count));
  if (!nodes) {
    HookFreeAddrInfoW(plain);
    return WSA_NOT_ENOUGH_MEMORY;
  }
  if (!TrackAllocation(nodes, 3)) {
    RtlFreeHeap(Heap(), 0, nodes);
    HookFreeAddrInfoW(plain);
    return WSA_NOT_ENOUGH_MEMORY;
  }
  auto *p = plain;
  for (unsigned i = 0; i < count; ++i, p = p->ai_next) {
    auto &n = nodes[i];
    n.info.ai_flags = p->ai_flags;
    n.info.ai_family = p->ai_family;
    n.info.ai_socktype = p->ai_socktype;
    n.info.ai_protocol = p->ai_protocol;
    n.info.ai_addrlen = p->ai_addrlen;
    Copy(&n.address, p->ai_addr, p->ai_addrlen);
    n.info.ai_addr = reinterpret_cast<sockaddr *>(&n.address);
    n.info.ai_next = i + 1 < count ? &nodes[i + 1].info : nullptr;
    if (p->ai_canonname) {
      for (unsigned k = 0; p->ai_canonname[k] && k < 255; ++k)
        n.canonical[k] = p->ai_canonname[k];
      n.info.ai_canonname = n.canonical;
    }
  }
  HookFreeAddrInfoW(plain);
  *result = &nodes[0].info;
  return 0;
}
struct ResolveJob {
  bool used;
  ULONG id;
  volatile LONG cancelled;
  WCHAR host[256], service[64];
  bool has_host, has_service, has_hints;
  ADDRINFOEXW hints;
  PADDRINFOEXW *output;
  LPOVERLAPPED overlapped;
  LPLOOKUPSERVICE_COMPLETION_ROUTINE completion;
};
ResolveJob resolve_jobs[128]{};
SRWLOCK resolve_lock{};
ULONG resolve_sequence = 0;
DWORD WINAPI ResolveWorker(void *context) {
  auto *job = static_cast<ResolveJob *>(context);
  int error =
      job->cancelled
          ? WSA_OPERATION_ABORTED
          : ResolveExW(job->has_host ? job->host : nullptr,
                       job->has_service ? job->service : nullptr,
                       job->has_hints ? &job->hints : nullptr, job->output);
  if (job->cancelled) {
    if (*job->output) {
      if (OwnAllocation(*job->output, 3))
        RtlFreeHeap(Heap(), 0, *job->output);
      *job->output = nullptr;
    }
    error = WSA_OPERATION_ABORTED;
  }
  job->overlapped->Internal = static_cast<ULONG_PTR>(error);
  job->overlapped->InternalHigh = 0;
  if (job->overlapped->hEvent) {
    auto set = System<decltype(&SetEvent)>("SetEvent");
    if (set)
      set(job->overlapped->hEvent);
  }
  if (job->completion)
    job->completion(static_cast<DWORD>(error), 0, job->overlapped);
  RtlAcquireSRWLockExclusive(&resolve_lock);
  job->used = false;
  RtlReleaseSRWLockExclusive(&resolve_lock);
  return 0;
}
INT WSAAPI HookGetAddrInfoExW(PCWSTR host, PCWSTR service, DWORD space,
                              LPGUID provider, const ADDRINFOEXW *hints,
                              PADDRINFOEXW *result, timeval *timeout,
                              LPOVERLAPPED ov,
                              LPLOOKUPSERVICE_COMPLETION_ROUTINE completion,
                              LPHANDLE name_handle) {
  Api(6, space, provider ? 1 : 0, ov ? 1 : 0);
  if (!result)
    return WSAEFAULT;
  *result = nullptr;
  if (provider || (space != NS_DNS && space != NS_ALL))
    return WSAEOPNOTSUPP;
  if (!ov) {
    if (completion)
      return WSAEINVAL;
    return ResolveExW(host, service, hints, result);
  }
  if (LoaderLocked())
    return WSATRY_AGAIN;
  (void)timeout;
  ResolveJob *job = nullptr;
  RtlAcquireSRWLockExclusive(&resolve_lock);
  for (auto &item : resolve_jobs)
    if (!item.used) {
      job = &item;
      Zero(job, sizeof(*job));
      job->used = true;
      job->id = ++resolve_sequence;
      break;
    }
  RtlReleaseSRWLockExclusive(&resolve_lock);
  if (!job)
    return WSA_NOT_ENOUGH_MEMORY;
  unsigned i = 0;
  if (host) {
    for (; host[i] && i < 255; ++i)
      job->host[i] = host[i];
    if (host[i]) {
      job->used = false;
      return WSAHOST_NOT_FOUND;
    }
    job->has_host = true;
  }
  if (service) {
    for (i = 0; service[i] && i < 63; ++i)
      job->service[i] = service[i];
    if (service[i]) {
      job->used = false;
      return WSATYPE_NOT_FOUND;
    }
    job->has_service = true;
  }
  if (hints) {
    job->hints = *hints;
    job->has_hints = true;
  }
  job->output = result;
  job->overlapped = ov;
  job->completion = completion;
  ov->Internal = WSA_IO_PENDING;
  ov->InternalHigh = 0;
  if (name_handle)
    *name_handle = reinterpret_cast<HANDLE>(0xcdf7000000000000ULL | job->id);
  auto create = System<decltype(&CreateThread)>("CreateThread");
  HANDLE thread =
      create ? create(nullptr, 0, ResolveWorker, job, 0, nullptr) : nullptr;
  if (!thread) {
    job->used = false;
    return WSA_NOT_ENOUGH_MEMORY;
  }
  NtClose(thread);
  return WSA_IO_PENDING;
}
INT WSAAPI HookGetAddrInfoExA(PCSTR, PCSTR, DWORD, LPGUID, const ADDRINFOEXA *,
                              PADDRINFOEXA *result, timeval *, LPOVERLAPPED,
                              LPLOOKUPSERVICE_COMPLETION_ROUTINE, LPHANDLE) {
  Api(5);
  if (result)
    *result = nullptr;
  return WSAEOPNOTSUPP;
}
void WSAAPI HookFreeAddrInfoExW(PADDRINFOEXW pointer) {
  if (!pointer)
    return;
  if (OwnAllocation(pointer, 0)) {
    RtlFreeHeap(Heap(), 0, pointer);
    return;
  }
  auto original = reinterpret_cast<decltype(&FreeAddrInfoExW)>(
      Raw(L"ws2_32.dll", "FreeAddrInfoExW"));
  if (original)
    original(pointer);
}
INT WSAAPI HookGetAddrInfoExCancel(LPHANDLE handle) {
  if (!handle)
    return WSA_INVALID_HANDLE;
  bool found = false;
  const auto value = reinterpret_cast<ULONG_PTR>(*handle);
  RtlAcquireSRWLockExclusive(&resolve_lock);
  if ((value & 0xffffffff00000000ULL) == 0xcdf7000000000000ULL)
    for (auto &job : resolve_jobs)
      if (job.used && job.id == static_cast<ULONG>(value)) {
        _InterlockedExchange(&job.cancelled, 1);
        found = true;
        break;
      }
  RtlReleaseSRWLockExclusive(&resolve_lock);
  return found ? 0 : WSA_INVALID_HANDLE;
}
INT WSAAPI HookGetAddrInfoExOverlappedResult(LPOVERLAPPED ov) {
  return ov ? static_cast<INT>(ov->Internal) : WSAEFAULT;
}
hostent *WSAAPI HookGetHostByName(const char *) {
  Api(12);
  Fail(WSAEOPNOTSUPP);
  return nullptr;
}
hostent *WSAAPI HookGetHostByAddr(const char *, int, int) {
  Api(13);
  Fail(WSAEOPNOTSUPP);
  return nullptr;
}
HANDLE WSAAPI HookWSAAsyncGetHostByName(HWND, u_int, const char *, char *,
                                        int) {
  Fail(WSAEOPNOTSUPP);
  return nullptr;
}
HANDLE WSAAPI HookWSAAsyncGetHostByAddr(HWND, u_int, const char *, int, int,
                                        char *, int) {
  Fail(WSAEOPNOTSUPP);
  return nullptr;
}
INT WSAAPI HookWSALookupServiceBeginW(LPWSAQUERYSETW query, DWORD flags,
                                      LPHANDLE output) {
  Api(11);
  if (query && query->dwNameSpace == NS_NLA)
    return Original<decltype(&WSALookupServiceBeginW)>(
        winsock_thunks, "WSALookupServiceBeginW")(query, flags, output);
  if (output)
    *output = nullptr;
  return Fail(WSAEOPNOTSUPP);
}
INT WSAAPI HookWSALookupServiceBeginA(LPWSAQUERYSETA, DWORD, LPHANDLE output) {
  Api(10);
  if (output)
    *output = nullptr;
  return Fail(WSAEOPNOTSUPP);
}
DNS_STATUS WINAPI HookDnsQueryW(PCWSTR name, WORD type, DWORD options,
                                PVOID extra, PDNS_RECORDW *result,
                                PVOID *reserved) {
  Api(8);
  if (!result || !name || extra || reserved)
    return ERROR_INVALID_PARAMETER;
  *result = nullptr;
  if (options & (DNS_QUERY_NO_WIRE_QUERY | DNS_QUERY_MULTICAST_ONLY |
                 DNS_QUERY_NO_RECURSION))
    return DNS_ERROR_RCODE_REFUSED;
  char ascii[256]{};
  if (!AsciiHost(name, ascii))
    return DNS_ERROR_INVALID_NAME_CHAR;
  auto *response =
      static_cast<BYTE *>(RtlAllocateHeap(Heap(), 0, dns_capacity));
  if (!response)
    return ERROR_NOT_ENOUGH_MEMORY;
  ULONG size = 0;
  const int error = QueryWire(ascii, type, response, dns_capacity, size);
  DNS_STATUS status = error == WSANO_DATA ? DNS_INFO_NO_RECORDS
                      : error == WSAHOST_NOT_FOUND ? DNS_ERROR_RCODE_NAME_ERROR
                      : error ? DNS_ERROR_RCODE_SERVER_FAILURE
                              : ERROR_SUCCESS;
  if (status == 0) {
    DNS_BYTE_FLIP_HEADER_COUNTS(reinterpret_cast<DNS_HEADER *>(response));
    auto extract = reinterpret_cast<decltype(&DnsExtractRecordsFromMessage_W)>(
        Raw(L"dnsapi.dll", "DnsExtractRecordsFromMessage_W"));
    if (!extract)
      status = ERROR_PROC_NOT_FOUND;
    else
      status = extract(reinterpret_cast<PDNS_MESSAGE_BUFFER>(response),
                       static_cast<WORD>(size), result);
  }
  RtlFreeHeap(Heap(), 0, response);
  return status;
}
DNS_STATUS WINAPI HookDnsQueryA(PCSTR name, WORD type, DWORD options,
                                PVOID extra, PDNS_RECORDA *result,
                                PVOID *reserved) {
  Api(7);
  if (!result || !name || extra || reserved)
    return ERROR_INVALID_PARAMETER;
  *result = nullptr;
  if (options & (DNS_QUERY_NO_WIRE_QUERY | DNS_QUERY_MULTICAST_ONLY |
                 DNS_QUERY_NO_RECURSION))
    return DNS_ERROR_RCODE_REFUSED;
  auto *response =
      static_cast<BYTE *>(RtlAllocateHeap(Heap(), 0, dns_capacity));
  if (!response)
    return ERROR_NOT_ENOUGH_MEMORY;
  ULONG size = 0;
  const int error = QueryWire(name, type, response, dns_capacity, size);
  DNS_STATUS status = error == WSANO_DATA ? DNS_INFO_NO_RECORDS
                      : error == WSAHOST_NOT_FOUND ? DNS_ERROR_RCODE_NAME_ERROR
                      : error ? DNS_ERROR_RCODE_SERVER_FAILURE
                              : ERROR_SUCCESS;
  if (status == 0) {
    DNS_BYTE_FLIP_HEADER_COUNTS(reinterpret_cast<DNS_HEADER *>(response));
    auto extract =
        reinterpret_cast<decltype(&DnsExtractRecordsFromMessage_UTF8)>(
            Raw(L"dnsapi.dll", "DnsExtractRecordsFromMessage_UTF8"));
    if (!extract)
      status = ERROR_PROC_NOT_FOUND;
    else
      status = extract(reinterpret_cast<PDNS_MESSAGE_BUFFER>(response),
                       static_cast<WORD>(size),
                       reinterpret_cast<PDNS_RECORD *>(result));
  }
  RtlFreeHeap(Heap(), 0, response);
  return status;
}
struct DnsJob {
  bool used;
  ULONG id;
  volatile LONG cancelled;
  WCHAR name[256];
  WORD type;
  DWORD options;
  PDNS_QUERY_COMPLETION_ROUTINE callback;
  PVOID context;
  PDNS_QUERY_RESULT result;
};
DnsJob dns_jobs[128]{};
SRWLOCK dns_job_lock{};
ULONG dns_job_sequence = 0;
DWORD WINAPI DnsWorker(PVOID pointer) {
  auto *job = static_cast<DnsJob *>(pointer);
  PDNS_RECORDW records = nullptr;
  DNS_STATUS status = HookDnsQueryW(job->name, job->type, job->options, nullptr,
                                    &records, nullptr);
  RtlAcquireSRWLockExclusive(&dns_job_lock);
  if (job->cancelled) {
    if (records) {
      auto free = reinterpret_cast<VOID(WINAPI *)(PVOID, DNS_FREE_TYPE)>(
          Raw(L"dnsapi.dll", "DnsFree"));
      if (free)
        free(records, DnsFreeRecordList);
      records = nullptr;
    }
    status = ERROR_CANCELLED;
  }
  job->result->QueryStatus = status;
  job->result->QueryOptions = job->options;
  job->result->pQueryRecords = records;
  RtlReleaseSRWLockExclusive(&dns_job_lock);
  job->callback(job->context, job->result);
  RtlAcquireSRWLockExclusive(&dns_job_lock);
  job->used = false;
  RtlReleaseSRWLockExclusive(&dns_job_lock);
  return 0;
}
DNS_STATUS WINAPI HookDnsCancelQuery(PDNS_QUERY_CANCEL cancel) {
  if (!cancel)
    return ERROR_INVALID_PARAMETER;
  const auto *token = reinterpret_cast<const ULONG *>(cancel);
  bool found = false;
  RtlAcquireSRWLockExclusive(&dns_job_lock);
  if (token[0] == 0x43444644)
    for (auto &job : dns_jobs)
      if (job.used && job.id == token[1]) {
        _InterlockedExchange(&job.cancelled, 1);
        found = true;
        break;
      }
  RtlReleaseSRWLockExclusive(&dns_job_lock);
  return found ? ERROR_SUCCESS : ERROR_INVALID_PARAMETER;
}
DNS_STATUS WINAPI HookDnsQueryEx(PDNS_QUERY_REQUEST request,
                                 PDNS_QUERY_RESULT result,
                                 PDNS_QUERY_CANCEL cancel) {
  Api(9, request ? static_cast<ULONG>(request->QueryOptions) : 0,
      request && request->pQueryCompletionCallback ? 1 : 0,
      request ? request->InterfaceIndex : 0);
  if (!request || !result || request->Version != DNS_QUERY_REQUEST_VERSION1 ||
      result->Version != DNS_QUERY_RESULTS_VERSION1)
    return ERROR_INVALID_PARAMETER;
  if (request->pDnsServerList || request->InterfaceIndex ||
      (request->QueryOptions >> 32)) {
    return ERROR_NOT_SUPPORTED;
  }
  if (!request->QueryName)
    return ERROR_INVALID_PARAMETER;
  if (request->pQueryCompletionCallback) {
    if (LoaderLocked())
      return ERROR_ACCESS_DENIED;
    DnsJob *job = nullptr;
    RtlAcquireSRWLockExclusive(&dns_job_lock);
    for (auto &item : dns_jobs)
      if (!item.used) {
        job = &item;
        Zero(job, sizeof(*job));
        job->used = true;
        job->id = ++dns_job_sequence;
        break;
      }
    if (!job) {
      RtlReleaseSRWLockExclusive(&dns_job_lock);
      return ERROR_NOT_ENOUGH_MEMORY;
    }
    unsigned n = 0;
    while (request->QueryName[n] && n < 255) {
      job->name[n] = request->QueryName[n];
      ++n;
    }
    if (request->QueryName[n]) {
      job->used = false;
      RtlReleaseSRWLockExclusive(&dns_job_lock);
      return DNS_ERROR_INVALID_NAME;
    }
    job->type = request->QueryType;
    job->options = static_cast<DWORD>(request->QueryOptions);
    job->callback = request->pQueryCompletionCallback;
    job->context = request->pQueryContext;
    job->result = result;
    if (cancel) {
      Zero(cancel, sizeof(*cancel));
      auto *token = reinterpret_cast<ULONG *>(cancel);
      token[0] = 0x43444644;
      token[1] = job->id;
    }
    result->QueryStatus = DNS_REQUEST_PENDING;
    result->pQueryRecords = nullptr;
    RtlReleaseSRWLockExclusive(&dns_job_lock);
    auto create = System<decltype(&CreateThread)>("CreateThread");
    HANDLE thread =
        create ? create(nullptr, 0, DnsWorker, job, 0, nullptr) : nullptr;
    if (!thread) {
      job->used = false;
      return ERROR_NOT_ENOUGH_MEMORY;
    }
    NtClose(thread);
    return DNS_REQUEST_PENDING;
  }
  result->QueryStatus = HookDnsQueryW(request->QueryName, request->QueryType,
                                      static_cast<DWORD>(request->QueryOptions),
                                      nullptr, &result->pQueryRecords, nullptr);
  return result->QueryStatus;
}
#define DNST(name, fn)                                                         \
  {const_cast<PCHAR>(name), nullptr, reinterpret_cast<PVOID>(&fn)}
verifier::ThunkDescriptor dns_thunks[] = {
    DNST("DnsQuery_W", HookDnsQueryW),
    DNST("DnsQuery_A", HookDnsQueryA),
    DNST("DnsQuery_UTF8", HookDnsQueryA),
    DNST("DnsQueryEx", HookDnsQueryEx),
    DNST("DnsCancelQuery", HookDnsCancelQuery),
    {}};
#undef DNST
