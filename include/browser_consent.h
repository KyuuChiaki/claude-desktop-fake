#pragma once
#include "verifier_abi.h"

namespace cdf::browser_consent {
// Only the Claude identity-gated build uses these two web-link consent checks.
extern verifier::ThunkDescriptor shell[];

inline constexpr char shell_open_name[] = "ShellExecuteW";
inline constexpr char shell_open_ex_name[] = "ShellExecuteExW";

// Preserve the existing provider chain only for the two consent entry points.
inline bool ForwardShellLookup(decltype(&GetProcAddress) previous, HMODULE module,
                               LPCSTR symbol, FARPROC& result) {
    if (!previous || reinterpret_cast<ULONG_PTR>(symbol) <= 0xffff) return false;
    const char* names[] = {shell_open_name, shell_open_ex_name};
    for (const char* name : names) {
        const char* input = symbol;
        while (*name && *name == *input) {
            ++name;
            ++input;
        }
        if (!*name && !*input) {
            result = previous(module, symbol);
            return true;
        }
    }
    return false;
}

PVOID RedirectShellOpenAddress(PVOID address);
enum class ConsentDecision { Approved, Declined, Unavailable };
ConsentDecision Confirm(HWND owner, PCWSTR url, size_t length);
#if defined(CDF_BROWSER_CONSENT_FIXTURE)
void SetFixtureIconSource(HMODULE module);
void SetFixtureWorkArea(RECT bounds);
#endif
}
