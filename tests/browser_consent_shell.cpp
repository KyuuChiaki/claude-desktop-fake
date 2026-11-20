#include <Windows.h>
#include <shellapi.h>

// These stand-ins never launch a process or open a URL. A successful return
// and distinct error value let the fixture tell when a request reached them.
extern "C" BOOL WINAPI FixtureShellExecuteExW(SHELLEXECUTEINFOW* request) {
    if (!request || request->cbSize != sizeof(*request)) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return FALSE;
    }
    request->hInstApp = reinterpret_cast<HINSTANCE>(42);
    request->hProcess = nullptr;
    SetLastError(ERROR_RETRY);
    return TRUE;
}

extern "C" HINSTANCE WINAPI FixtureShellExecuteW(HWND, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, INT) {
    SetLastError(ERROR_RETRY);
    return reinterpret_cast<HINSTANCE>(42);
}
