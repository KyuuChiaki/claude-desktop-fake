#include "browser_consent.h"
#include "runtime_provider.h"
#include "locale_native.h"
#include <shellapi.h>

namespace cdf::browser_consent {
namespace {
constexpr size_t max_file = 32767;
constexpr WCHAR preferences[] = L"Software\\ClaudeDesktopFake\\Preferences";
constexpr WCHAR setting[] = L"ConfirmBrowserLinks";
// A dismissal handles the request without dispatching it to the browser.
constexpr INT_PTR shell_handled = 33;

bool StartsWithI(PCWSTR value, PCWSTR lower) {
    for (; *lower; ++value, ++lower) {
        WCHAR c = *value;
        if (c >= L'A' && c <= L'Z') c += L'a' - L'A';
        if (c != *lower) return false;
    }
    return true;
}

bool IsWebOpen(PCWSTR verb, PCWSTR file) {
    if (!file || (verb && *verb && !(StartsWithI(verb, L"open") && !verb[4]))) return false;
    while (*file == L' ' || *file == L'\t') ++file;
    if (*file == L'"') ++file; // Electron quotes its entire escaped URL on Windows.
    return StartsWithI(file, L"https://") || StartsWithI(file, L"http://");
}

bool PromptRequired() {
    auto read = reinterpret_cast<decltype(&RegGetValueW)>(ResolveLoaded(L"kernelbase.dll", "RegGetValueW"));
    if (!read) return true;
    DWORD value = 0, bytes = sizeof(value);
    const LSTATUS status = read(HKEY_CURRENT_USER, preferences, setting, RRF_RT_REG_DWORD, nullptr, &value, &bytes);
    if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND) return false;
    return status != ERROR_SUCCESS || bytes != sizeof(value) || value != 0;
}

// Freeze the shell argument while the user reads it. The dialog exposes the
// entire URL, and an approval can only dispatch that same immutable argument.
class WebRequest {
    HANDLE heap_ = nullptr;
    WCHAR* file_ = nullptr;
    size_t count_ = 0;
public:
    WebRequest() = default;
    WebRequest(const WebRequest&) = delete;
    WebRequest& operator=(const WebRequest&) = delete;
    ~WebRequest() {
        if (file_) {
            const DWORD last = RtlGetLastWin32Error();
            RtlSecureZeroMemory(file_, (count_ + 1) * sizeof(WCHAR));
            RtlFreeHeap(heap_, 0, file_);
            RtlSetLastWin32Error(last);
        }
    }
    PCWSTR file() const { return file_; }
    ConsentDecision Ask(HWND owner, PCWSTR source) {
        while (count_ <= max_file && source[count_]) ++count_;
        if (!count_ || count_ > max_file) return ConsentDecision::Unavailable;
        const auto heap = reinterpret_cast<decltype(&GetProcessHeap)>(ResolveLoaded(L"kernelbase.dll","GetProcessHeap"));
        if (!heap || !(heap_ = heap())) return ConsentDecision::Unavailable;
        file_ = static_cast<WCHAR*>(RtlAllocateHeap(heap_, 0, (count_ + 1) * sizeof(WCHAR)));
        if (!file_) return ConsentDecision::Unavailable;
        for (size_t i = 0; i < count_; ++i) file_[i] = source[i];
        file_[count_] = 0;
        size_t first = 0, end = count_;
        while (first < end && (file_[first] == L' ' || file_[first] == L'\t')) ++first;
        while (end > first && (file_[end-1] == L' ' || file_[end-1] == L'\t')) --end;
        if (first == end) return ConsentDecision::Unavailable;
        if (file_[first] == L'"') {
            if (end-first < 2 || file_[end-1] != L'"') return ConsentDecision::Unavailable;
            ++first;
            --end;
        }
        if (!StartsWithI(file_+first, L"https://") && !StartsWithI(file_+first, L"http://")) return ConsentDecision::Unavailable;
        for (size_t i = first; i < end; ++i) {
            const auto c = file_[i];
            if (c < 0x20 || (c >= 0x7f && c <= 0x9f) || c == L'"' || c == 0x061c ||
                (c >= 0x200e && c <= 0x200f) || (c >= 0x2028 && c <= 0x202e) ||
                (c >= 0x2066 && c <= 0x2069)) return ConsentDecision::Unavailable;
        }
        const WCHAR delimiter = file_[end];
        file_[end] = 0;
        const auto decision = Confirm(owner, file_+first, end-first);
        file_[end] = delimiter;
        return decision;
    }
};

HINSTANCE WINAPI Open(HWND owner, PCWSTR verb, PCWSTR file, PCWSTR params, PCWSTR dir, INT show) {
    const DWORD last = RtlGetLastWin32Error();
    const auto original = reinterpret_cast<decltype(&ShellExecuteW)>(shell[0].old_address);
    WebRequest request;
    if (IsWebOpen(verb, file) && PromptRequired()) {
        const auto decision = request.Ask(owner, file);
        if (decision == ConsentDecision::Declined) {
            RtlSetLastWin32Error(last);
            return reinterpret_cast<HINSTANCE>(shell_handled);
        }
        if (decision == ConsentDecision::Unavailable) {
            RtlSetLastWin32Error(ERROR_CANCELLED);
            return reinterpret_cast<HINSTANCE>(SE_ERR_ACCESSDENIED);
        }
        file = request.file();
    }
    RtlSetLastWin32Error(last);
    return original(owner, verb, file, params, dir, show);
}

BOOL WINAPI OpenEx(SHELLEXECUTEINFOW* input) {
    const DWORD last = RtlGetLastWin32Error();
    const auto original = reinterpret_cast<decltype(&ShellExecuteExW)>(shell[1].old_address);
    if (!input || input->cbSize != sizeof(*input) || (input->fMask & (SEE_MASK_IDLIST | SEE_MASK_CLASSKEY)) ||
        !IsWebOpen(input->lpVerb, input->lpFile) || !PromptRequired()) {
        RtlSetLastWin32Error(last);
        return original(input);
    }
    auto call = *input;
    WebRequest request;
    const auto decision = request.Ask(call.hwnd, call.lpFile);
    if (decision != ConsentDecision::Approved) {
        const bool handled = decision == ConsentDecision::Declined;
        input->hInstApp = reinterpret_cast<HINSTANCE>(handled ? shell_handled : SE_ERR_ACCESSDENIED);
        input->hProcess = nullptr;
        RtlSetLastWin32Error(handled ? last : ERROR_CANCELLED);
        return handled;
    }
    call.lpFile = request.file();
    RtlSetLastWin32Error(last);
    const BOOL result = original(&call);
    input->hInstApp = call.hInstApp;
    input->hProcess = call.hProcess;
    return result;
}
} // namespace

verifier::ThunkDescriptor shell[] = {
    {const_cast<PCHAR>(shell_open_name), nullptr, reinterpret_cast<PVOID>(&Open)},
    {const_cast<PCHAR>(shell_open_ex_name), nullptr, reinterpret_cast<PVOID>(&OpenEx)}, {}};

PVOID RedirectShellOpenAddress(PVOID address) {
    if (address) {
        for (auto* entry = shell; entry->name; ++entry) {
            if (entry->old_address == address) return entry->new_address;
        }
    }
    return address;
}
} // namespace cdf::browser_consent
