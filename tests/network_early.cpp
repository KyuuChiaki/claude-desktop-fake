#include "network_status.h"
#include <Windows.h>
static CdfNetworkStatus early{};
extern "C" __declspec(dllexport) DWORD WINAPI CdfNetworkEarlyState() {
  return early.state;
}
BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_ATTACH) {
    const auto module = GetModuleHandleW(L"CdfNetwork64.dll");
    if (module) {
      using Query = DWORD(WINAPI *)(CdfNetworkStatus *, DWORD);
      const auto query = reinterpret_cast<Query>(
          GetProcAddress(module, "CdfNetworkQueryStatus"));
      if (query)
        query(&early, sizeof(early));
    }
  }
  return TRUE;
}
