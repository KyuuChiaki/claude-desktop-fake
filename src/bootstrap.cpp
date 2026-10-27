#include "verifier_abi.h"

namespace {
cdf::verifier::DllDescriptor no_dlls[] = {{}};
cdf::verifier::ProviderDescriptor provider = {
    sizeof(cdf::verifier::ProviderDescriptor), no_dlls,
    nullptr, nullptr, nullptr, 0, 0, nullptr, nullptr, nullptr, nullptr};
DWORD state = 0;
}  // namespace

extern "C" __declspec(dllexport) DWORD WINAPI CdfBootstrapQueryState() {
    return state;
}

extern "C" __declspec(dllexport) DWORD WINAPI CdfBootstrapQueryVerifierFlags() {
    return provider.verifier_flags;
}

extern "C" BOOL WINAPI CdfBootstrapEntry(HINSTANCE, DWORD reason, LPVOID reserved) {
    if (reason == cdf::verifier::process_verifier) {
        if (reserved == nullptr) {
            return FALSE;
        }
        *static_cast<cdf::verifier::ProviderDescriptor**>(reserved) = &provider;
        state |= 0x1;
    } else if (reason == DLL_PROCESS_ATTACH) {
        state |= 0x2;
    }
    return TRUE;
}
