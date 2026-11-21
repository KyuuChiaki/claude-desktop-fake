// Verifier alone does not rewrite every cached system-library call on 19045.
// Retarget import cells, never instruction bytes. The DLL remains loaded until
// exit.
extern verifier::DllDescriptor dlls[];
PVOID self_module = nullptr;
struct ImportFailure {
  ULONG step;
  NTSTATUS status;
  ULONG_PTR cell;
  WCHAR module[128];
};
ImportFailure import_failure{};
struct ImportMapping {
  PVOID original, hook;
};
ImportMapping import_mappings[256]{};
volatile LONG mapping_count = 0;
bool SkipImportModule(PVOID address, const WCHAR *name) {
  if (address == self_module)
    return true;
  const WCHAR *excluded[] = {L"CdfProxyTransport64.dll",
                             L"CdfTimeZone64.dll",
                             L"CdfClaudeTimeZone64.dll",
                             L"CdfClaudeTimeZoneTest64.dll",
                             L"CdfBootstrap64.dll",
                             L"verifier.dll",
                             L"vrfcore.dll",
                             L"vfbasics.dll",
                             L"verifierbase.dll"};
  for (const auto *text : excluded) {
    const WCHAR *a = name;
    const WCHAR *b = text;
    bool same = true;
    while (*a && *b) {
      WCHAR x = *a++, y = *b++;
      if (x >= L'A' && x <= L'Z')
        x += 32;
      if (y >= L'A' && y <= L'Z')
        y += 32;
      if (x != y) {
        same = false;
        break;
      }
    }
    if (same && !*a && !*b)
      return true;
  }
  return false;
}
void RefreshImportMappings() {
  for (auto *d = dlls; d->name; ++d)
    for (auto *t = d->thunks; t && t->name; ++t) {
      PVOID raw = Raw(d->name, t->name);
      if (!raw || !t->new_address)
        continue;
      bool present = false;
      for (LONG i = 0; i < mapping_count; ++i)
        if (import_mappings[i].original == raw) {
          present = true;
          break;
        }
      if (!present && mapping_count < 256) {
        const LONG index = mapping_count;
        import_mappings[index] = {raw, t->new_address};
        _InterlockedExchange(&mapping_count, index + 1);
      }
    }
}
PVOID ImportReplacement(PVOID address) {
  const LONG count = mapping_count;
  for (LONG i = 0; i < count; ++i)
    if (import_mappings[i].original == address)
      return import_mappings[i].hook;
  return address;
}
bool WriteImport(PVOID *cell, PVOID replacement) {
  auto protect = reinterpret_cast<NTSTATUS(NTAPI *)(HANDLE, PVOID *, PSIZE_T,
                                                    ULONG, PULONG)>(
      Raw(L"ntdll.dll", "NtProtectVirtualMemory"));
  if (!protect)
    return false;
  PVOID page = cell;
  SIZE_T bytes = sizeof(*cell);
  ULONG old = 0;
  import_failure.cell = reinterpret_cast<ULONG_PTR>(cell);
  import_failure.step = 1;
  import_failure.status = protect(reinterpret_cast<HANDLE>(-1), &page, &bytes,
                                  PAGE_READWRITE, &old);
  if (import_failure.status < 0)
    return false;
  _InterlockedExchangePointer(cell, replacement);
  ULONG ignored = 0;
  import_failure.step = 2;
  import_failure.status =
      protect(reinterpret_cast<HANDLE>(-1), &page, &bytes, old, &ignored);
  return import_failure.status >= 0;
}
bool PatchModuleImports(PVOID address) {
  __try {
    auto *base = static_cast<BYTE *>(address);
    auto *dos = reinterpret_cast<IMAGE_DOS_HEADER *>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < 0)
      return false;
    auto *pe = reinterpret_cast<IMAGE_NT_HEADERS64 *>(base + dos->e_lfanew);
    if (pe->Signature != IMAGE_NT_SIGNATURE)
      return false;
    if (pe->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
      // Windows can map an x86 /NOENTRY resource DLL into an x64 process.
      // It has no executable sections or imports, so there is no network IAT.
      auto *resource = reinterpret_cast<IMAGE_NT_HEADERS32 *>(pe);
      if (resource->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC ||
          resource->FileHeader.Machine != IMAGE_FILE_MACHINE_I386 ||
          resource->OptionalHeader.AddressOfEntryPoint ||
          resource->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT]
              .VirtualAddress)
        return false;
      auto *section = IMAGE_FIRST_SECTION(resource);
      for (WORD i = 0; i < resource->FileHeader.NumberOfSections; ++i)
        if (section[i].Characteristics & IMAGE_SCN_MEM_EXECUTE)
          return false;
      return true;
    }
    const DWORD image_size = pe->OptionalHeader.SizeOfImage;
    const auto &directory =
        pe->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (directory.VirtualAddress) {
      if (directory.VirtualAddress >= image_size ||
          directory.Size > image_size - directory.VirtualAddress)
        return false;
      auto *imports = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR *>(
          base + directory.VirtualAddress);
      const DWORD descriptors =
          directory.Size / sizeof(IMAGE_IMPORT_DESCRIPTOR);
      for (DWORD i = 0; i < descriptors && imports[i].Name; ++i) {
        const DWORD rva = imports[i].FirstThunk;
        if (!rva || rva >= image_size)
          return false;
        auto *import_cells = reinterpret_cast<PVOID *>(base + rva);
        const SIZE_T capacity = (image_size - rva) / sizeof(PVOID);
        for (SIZE_T n = 0; n < capacity && import_cells[n]; ++n) {
          PVOID replacement = ImportReplacement(import_cells[n]);
          if (replacement != import_cells[n] &&
              !WriteImport(&import_cells[n], replacement))
            return false;
        }
      }
    }
    struct DelayDirectory {
      DWORD attributes, name, module, iat, names, bound, unload, timestamp;
    };
    static_assert(sizeof(DelayDirectory) == 32);
    const auto &delayed =
        pe->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT];
    if (delayed.VirtualAddress) {
      if (delayed.VirtualAddress >= image_size ||
          delayed.Size > image_size - delayed.VirtualAddress)
        return false;
      auto *entries =
          reinterpret_cast<DelayDirectory *>(base + delayed.VirtualAddress);
      for (DWORD i = 0;
           i < delayed.Size / sizeof(DelayDirectory) && entries[i].name; ++i) {
        if (!(entries[i].attributes & 1) || entries[i].iat >= image_size)
          return false;
        auto *cells = reinterpret_cast<PVOID *>(base + entries[i].iat);
        const SIZE_T capacity = (image_size - entries[i].iat) / sizeof(PVOID);
        for (SIZE_T n = 0; n < capacity && cells[n]; ++n) {
          PVOID replacement = ImportReplacement(cells[n]);
          if (replacement != cells[n] && !WriteImport(&cells[n], replacement))
            return false;
        }
      }
    }
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}
void FatalImportFailure() {
  diagnostic.error_stage = 4;
  diagnostic.error_code = ERROR_INVALID_ADDRESS;
  diagnostic.state |= CdfNetworkFailed;
  if (NtCurrentTeb()->ProcessEnvironmentBlock->BeingDebugged)
    __debugbreak();
  NtTerminateProcess(reinterpret_cast<HANDLE>(-1),
                     static_cast<NTSTATUS>(0xE0CDF701u));
}
using ResolveDelayed = PVOID(NTAPI *)(PVOID, PVOID, PVOID, PVOID,
                                      PIMAGE_THUNK_DATA, ULONG);
PVOID NTAPI HookLdrResolveDelayLoadedAPI(PVOID parent, PVOID descriptor,
                                         PVOID dll_failure, PVOID failure,
                                         PIMAGE_THUNK_DATA thunk, ULONG flags) {
  const auto original =
      Original<ResolveDelayed>(native_thunks, "LdrResolveDelayLoadedAPI");
  PVOID result =
      original(parent, descriptor, dll_failure, failure, thunk, flags);
  RefreshImportMappings();
  PVOID replacement = ImportReplacement(result);
  if (result != replacement && thunk) {
    if (!WriteImport(reinterpret_cast<PVOID *>(&thunk->u1.Function),
                     replacement))
      FatalImportFailure();
  }
  return replacement;
}
void PatchAllImports() {
  using Lock = NTSTATUS(NTAPI *)(ULONG, ULONG *, ULONG_PTR *);
  using Unlock = NTSTATUS(NTAPI *)(ULONG, ULONG_PTR);
  auto lock = reinterpret_cast<Lock>(Raw(L"ntdll.dll", "LdrLockLoaderLock"));
  auto unlock =
      reinterpret_cast<Unlock>(Raw(L"ntdll.dll", "LdrUnlockLoaderLock"));
  ULONG disposition = 0;
  ULONG_PTR cookie = 0;
  if (!lock || !unlock || lock(0, &disposition, &cookie) < 0) {
    FatalImportFailure();
    return;
  }
  RefreshImportMappings();
  auto *ldr = NtCurrentTeb()->ProcessEnvironmentBlock->Ldr;
  if (ldr) {
    auto *head = &ldr->InMemoryOrderModuleList;
    for (auto *item = head->Flink; item != head; item = item->Flink) {
      auto *entry =
          CONTAINING_RECORD(item, LDR_DATA_TABLE_ENTRY, InMemoryOrderLinks);
      WCHAR name[128]{};
      const auto &full = entry->FullDllName;
      USHORT start = 0;
      for (USHORT i = 0; i < full.Length / 2; ++i)
        if (full.Buffer[i] == L'\\')
          start = i + 1;
      unsigned k = 0;
      while (start < full.Length / 2 && k < 127)
        name[k++] = full.Buffer[start++];
      if (!SkipImportModule(entry->DllBase, name)) {
        Copy(import_failure.module, name, sizeof(name));
        import_failure.step = 3;
        import_failure.status = 0;
        import_failure.cell = reinterpret_cast<ULONG_PTR>(entry->DllBase);
        if (!PatchModuleImports(entry->DllBase)) {
          unlock(0, cookie);
          FatalImportFailure();
          return;
        }
      }
    }
  }
  unlock(0, cookie);
}
HINTERNET WINAPI HookWinHttpOpen(LPCWSTR agent, DWORD access, LPCWSTR proxy,
                                 LPCWSTR bypass, DWORD flags) {
  (void)access;
  (void)proxy;
  (void)bypass;
  Api(14);
  PatchAllImports();
  return Original<decltype(&WinHttpOpen)>(http_thunks, "WinHttpOpen")(
      agent, WINHTTP_ACCESS_TYPE_NO_PROXY, nullptr, nullptr, flags);
}
BOOL WINAPI HookWinHttpGetProxyForUrl(HINTERNET, LPCWSTR,
                                      WINHTTP_AUTOPROXY_OPTIONS *,
                                      WINHTTP_PROXY_INFO *) {
  RtlSetLastWin32Error(ERROR_WINHTTP_AUTODETECTION_FAILED);
  Count(diagnostic.denied_calls);
  return FALSE;
}
DWORD WINAPI HookWinHttpGetProxyForUrlEx(HINTERNET, PCWSTR,
                                         WINHTTP_AUTOPROXY_OPTIONS *,
                                         DWORD_PTR) {
  Count(diagnostic.denied_calls);
  return ERROR_WINHTTP_AUTODETECTION_FAILED;
}
BOOL WINAPI HookWinHttpDetectAutoProxyConfigUrl(DWORD, LPWSTR *output) {
  if (output)
    *output = nullptr;
  RtlSetLastWin32Error(ERROR_WINHTTP_AUTODETECTION_FAILED);
  Count(diagnostic.denied_calls);
  return FALSE;
}
HINTERNET WINAPI HookInternetOpenW(LPCWSTR agent, DWORD access, LPCWSTR proxy,
                                   LPCWSTR bypass, DWORD flags) {
  using Open = HINTERNET(WINAPI *)(LPCWSTR, DWORD, LPCWSTR, LPCWSTR, DWORD);
  (void)access;
  (void)proxy;
  (void)bypass;
  return Original<Open>(inet_thunks, "InternetOpenW")(agent, 1, nullptr,
                                                      nullptr, flags);
}
HINTERNET WINAPI HookInternetOpenA(LPCSTR agent, DWORD access, LPCSTR proxy,
                                   LPCSTR bypass, DWORD flags) {
  using Open = HINTERNET(WINAPI *)(LPCSTR, DWORD, LPCSTR, LPCSTR, DWORD);
  (void)access;
  (void)proxy;
  (void)bypass;
  return Original<Open>(inet_thunks, "InternetOpenA")(agent, 1, nullptr,
                                                      nullptr, flags);
}
HINTERNET WINAPI HookWinHttpConnect(HINTERNET session, LPCWSTR server,
                                    INTERNET_PORT port, DWORD reserved) {
  Api(15);
  PatchAllImports();
  return Original<decltype(&WinHttpConnect)>(http_thunks, "WinHttpConnect")(
      session, server, port, reserved);
}
BOOL WINAPI HookWinHttpSendRequest(HINTERNET request, LPCWSTR headers,
                                   DWORD header_size, PVOID data,
                                   DWORD data_size, DWORD total,
                                   DWORD_PTR context) {
  Api(16);
  PatchAllImports();
  return Original<decltype(&WinHttpSendRequest)>(
      http_thunks, "WinHttpSendRequest")(request, headers, header_size, data,
                                         data_size, total, context);
}
