#pragma once
#include "verifier_abi.h"

namespace cdf::browser_consent {
// Only the Claude identity-gated build uses these two web-link consent checks.
extern verifier::ThunkDescriptor shell[];

inline constexpr char shell_open_name[] = "ShellExecuteW";
inline constexpr char shell_open_ex_name[] = "ShellExecuteExW";

PVOID RedirectShellOpenAddress(PVOID address);
enum class ConsentDecision { Approved, Declined, Unavailable };
ConsentDecision Confirm(HWND owner, PCWSTR url, size_t length);
#if defined(CDF_BROWSER_CONSENT_FIXTURE)
void SetFixtureIconSource(HMODULE module);
void SetFixtureWorkArea(RECT bounds);
#endif
}
