#pragma once
#include "time_core.h"
#include "verifier_abi.h"
namespace cdf {
void PrepareLocale(const Config& config, DWORD error, NTSTATUS native_error);
bool LocalePrepared();
void AppendLocaleThunks(verifier::ThunkDescriptor* base, verifier::ThunkDescriptor* kernel, verifier::ThunkDescriptor* native);
void LocaleEvent(DWORD reason);
void NTAPI LocaleDllLoaded(PWSTR name, PVOID address, SIZE_T size, PVOID reserved);
PVOID RedirectLocaleAddress(PVOID address);
bool VirtualLocalTime(SYSTEMTIME& output);
DWORD ProviderVerifierFlags();
bool LocaleProcessLanguages(WCHAR* buffer,ULONG capacity);
NTSTATUS OriginalProcedure(PVOID module,const ANSI_STRING* name,ULONG ordinal,PVOID* address);
}
