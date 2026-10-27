#pragma once
#include "locale_provider.h"
#include "runtime_status.h"
namespace cdf {
PVOID RedirectRuntimeAddress(PVOID address);
void PrepareRuntime(const Config& config,bool parsed,bool time_active);
bool RuntimePreflight(const Config& config);
void AppendRuntimeThunks(verifier::ThunkDescriptor* base,verifier::ThunkDescriptor* kernel,verifier::ThunkDescriptor* native);
verifier::ThunkDescriptor* RuntimeComThunks();
bool RuntimePrepared();
const Config& RuntimeConfigSnapshot();
bool RuntimeLocaleEnabled();
bool RuntimeRegionEnabled();
bool RuntimeTimeEnabled();
bool RuntimePassthrough();
PVOID ResolveLoaded(const WCHAR* module,const char* symbol);
void RuntimeEvent(DWORD reason);
void NTAPI RuntimeDllLoaded(PWSTR name,PVOID address,SIZE_T size,PVOID reserved);
HRESULT WrapRuntimeFactory(void* class_id,REFIID iid,void** output);
HRESULT ActivateRuntimeInstance(void* class_id,void** output);
ULONGLONG WinrtLanguageCalls();
ULONGLONG WinrtFormatCalls();
}
