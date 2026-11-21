#include "browser_consent.h"
#include "browser_consent_ids.h"
#include "runtime_provider.h"
#include <shellapi.h>
#include <delayimp.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

// This fixture only dispatches to counters in its own process. It never calls
// the real ShellExecute functions or changes a Windows protocol association.
namespace cdf {
PVOID ResolveLoaded(const WCHAR* module, const char* name) {
    return reinterpret_cast<PVOID>(GetProcAddress(GetModuleHandleW(module), name));
}
}
namespace {
unsigned checks, failures, prompts, opened, delay_lookups;
DWORD forwarded_error;
bool expect_app_icon, shell_fails;
RECT simulated_work_area{};
SIZE normal_size{};
std::wstring expected, received;
std::wstring* changing_input;
enum class Answer { Open, Cancel, Close, Enter, Escape };
enum class Outcome { Opened, Declined, Unavailable, ShellFailure };
Answer answer;
void Check(bool ok, const char* what) {
    ++checks;
    if (!ok) { ++failures; std::fprintf(stderr,"FAILED: %s\n",what); }
}
BOOL WINAPI SinkEx(SHELLEXECUTEINFOW* call) {
    forwarded_error = GetLastError();
    ++opened;
    received = call->lpFile;
    if (shell_fails) {
        call->hProcess = nullptr;
        call->hInstApp = reinterpret_cast<HINSTANCE>(SE_ERR_NOASSOC);
        SetLastError(ERROR_NO_ASSOCIATION);
        return FALSE;
    }
    call->hProcess = reinterpret_cast<HANDLE>(0x4321);
    call->hInstApp = reinterpret_cast<HINSTANCE>(42);
    SetLastError(812);
    return TRUE;
}
HINSTANCE WINAPI SinkW(HWND, PCWSTR, PCWSTR file, PCWSTR, PCWSTR, INT) {
    forwarded_error = GetLastError();
    ++opened;
    received = file;
    if (shell_fails) {
        SetLastError(ERROR_NO_ASSOCIATION);
        return reinterpret_cast<HINSTANCE>(SE_ERR_NOASSOC);
    }
    SetLastError(812);
    return reinterpret_cast<HINSTANCE>(42);
}

FARPROC WINAPI PreviousShellLookup(HMODULE module, LPCSTR name) {
    const auto address = reinterpret_cast<PVOID>(GetProcAddress(module, name));
    return reinterpret_cast<FARPROC>(cdf::browser_consent::RedirectShellOpenAddress(address));
}

FARPROC WINAPI ForwardFixtureDelay(unsigned notification, PDelayLoadInfo info) {
    using namespace cdf::browser_consent;
    if (notification != dliNotePreGetProcAddress || !info->dlp.fImportByName ||
        std::strcmp(info->szDll, "CdfBrowserConsentShellFixture64.dll") != 0) return nullptr;
    ++delay_lookups;
    shell[0].old_address = reinterpret_cast<PVOID>(GetProcAddress(info->hmodCur, shell_open_name));
    shell[1].old_address = reinterpret_cast<PVOID>(GetProcAddress(info->hmodCur, shell_open_ex_name));
    FARPROC result = nullptr;
    ForwardShellLookup(PreviousShellLookup, info->hmodCur, info->dlp.szProcName, result);
    return result;
}

void InspectLayout(HWND dialog) {
    Check((GetWindowLongPtrW(dialog, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0, "dialog stays above normal windows");
    RECT outer{};
    Check(GetWindowRect(dialog, &outer) != FALSE, "read dialog bounds");
    const SIZE size{outer.right-outer.left, outer.bottom-outer.top};
    RECT work = simulated_work_area;
    if (work.right > work.left) {
        Check(size.cx < normal_size.cx && size.cy < normal_size.cy, "compact layout shrinks both dimensions");
    } else {
        MONITORINFO monitor{sizeof(monitor)};
        Check(GetMonitorInfoW(MonitorFromWindow(dialog, MONITOR_DEFAULTTONEAREST), &monitor) != FALSE,
              "read monitor work area");
        work = monitor.rcWork;
        normal_size = size;
    }
    Check(outer.left >= work.left && outer.top >= work.top && outer.right <= work.right && outer.bottom <= work.bottom,
          "dialog fits within monitor work area");
    Check(std::abs(outer.left-work.left-(work.right-outer.right)) <= 1 &&
          std::abs(outer.top-work.top-(work.bottom-outer.bottom)) <= 1, "dialog is centered within the work area");
    RECT client{};
    GetClientRect(dialog, &client);
    for (int id : {IDC_BROWSER_LOGO, IDC_BROWSER_TITLE, IDC_BROWSER_URL, IDOK, IDCANCEL}) {
        RECT item{};
        const auto control = GetDlgItem(dialog, id);
        const BOOL measured = control && GetWindowRect(control, &item);
        MapWindowPoints(nullptr, dialog, reinterpret_cast<POINT*>(&item), 2);
        Check(measured && IsWindowVisible(control) && item.left >= 0 && item.top >= 0 &&
              item.right <= client.right && item.bottom <= client.bottom && !IsRectEmpty(&item),
              "each control remains visible and inside the dialog");
    }
}

BOOL CALLBACK InspectDialog(HWND dlg, LPARAM) {
    const HWND edit = GetDlgItem(dlg, IDC_BROWSER_URL);
    if (!edit || !IsWindowVisible(dlg)) return TRUE;
    std::wstring text(static_cast<size_t>(GetWindowTextLengthW(edit))+1, L'\0');
    text.resize(GetWindowTextW(edit,text.data(),static_cast<int>(text.size())));
    ++prompts;
    InspectLayout(dlg);
    Check(text == expected, "visible URL includes complete path, query and fragment");
    if (expect_app_icon) {
        const HWND logo = GetDlgItem(dlg, IDC_BROWSER_LOGO);
        const bool owner_drawn = (GetWindowLongPtrW(logo, GWL_STYLE) & SS_TYPEMASK) == SS_OWNERDRAW;
        Check(owner_drawn || SendMessageW(logo, STM_GETICON, 0, 0) != 0,
              "dialog reads the real application icon from the supplied image");
    }
    const auto style = GetWindowLongPtrW(edit,GWL_STYLE);
    Check((style & (WS_VSCROLL|ES_MULTILINE|ES_READONLY))==(WS_VSCROLL|ES_MULTILINE|ES_READONLY),"URL field is read-only and scrollable");
    Check(LOWORD(SendMessageW(dlg,DM_GETDEFID,0,0))==IDCANCEL,"default button is Cancel");
    Check(GetFocus()==GetDlgItem(dlg,IDCANCEL),"initial keyboard focus is Cancel");
    if (changing_input) (*changing_input)[10]=L'X';
    if (answer==Answer::Enter || answer==Answer::Escape) {
        MSG key{};
        key.hwnd=GetFocus(); key.message=WM_KEYDOWN;
        key.wParam=answer==Answer::Enter ? VK_RETURN : VK_ESCAPE;
        IsDialogMessageW(dlg,&key);
    } else if(answer==Answer::Close) {
        PostMessageW(dlg,WM_CLOSE,0,0);
    } else {
        const int button=answer==Answer::Open ? IDOK : IDCANCEL;
        PostMessageW(dlg,WM_COMMAND,MAKEWPARAM(button,BN_CLICKED),reinterpret_cast<LPARAM>(GetDlgItem(dlg,button)));
    }
    return FALSE;
}
void CALLBACK Timer(HWND,UINT,UINT_PTR,DWORD) {
    EnumThreadWindows(GetCurrentThreadId(),InspectDialog,0);
}

struct RegFixture {
    std::wstring path = L"Software\\CdfBrowserConsentFixture-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64());
    HKEY root = nullptr, prefs = nullptr;
    bool created = false, overridden = false;
    bool start() {
        DWORD disposition = 0;
        if (RegCreateKeyExW(HKEY_CURRENT_USER,path.c_str(),0,nullptr,REG_OPTION_VOLATILE,KEY_ALL_ACCESS,
                            nullptr,&root,&disposition)!=ERROR_SUCCESS || disposition!=REG_CREATED_NEW_KEY) return false;
        created = true;
        if (RegOverridePredefKey(HKEY_CURRENT_USER,root)!=ERROR_SUCCESS) return false;
        overridden = true;
        return true;
    }
    void enable(DWORD value) {
        if (!prefs) Check(RegCreateKeyExW(root,L"Software\\ClaudeDesktopFake\\Preferences",0,nullptr,REG_OPTION_VOLATILE,
                         KEY_ALL_ACCESS,nullptr,&prefs,nullptr)==ERROR_SUCCESS,"create isolated preference");
        Check(RegSetValueExW(prefs,L"ConfirmBrowserLinks",0,REG_DWORD,reinterpret_cast<const BYTE*>(&value),sizeof(value))==ERROR_SUCCESS,"set test policy");
    }
    ~RegFixture() {
        if (prefs) RegCloseKey(prefs);
        if (overridden) RegOverridePredefKey(HKEY_CURRENT_USER,nullptr);
        if (root) RegCloseKey(root);
        if (created) RegDeleteTreeW(HKEY_CURRENT_USER,path.c_str());
    }
};
void Exercise(bool extended, PCWSTR verb, std::wstring file, const std::wstring& display,
              Answer choice, bool shouldAsk, Outcome outcome, bool changeSource=false, DWORD extraMask=0) {
    const std::wstring original = file;
    expected = display;
    answer = choice;
    changing_input = changeSource ? &file : nullptr;
    const auto before = prompts;
    const auto calls = opened;
    received.clear();
    const bool opened_ok = outcome == Outcome::Opened;
    const bool declined = outcome == Outcome::Declined;
    shell_fails = outcome == Outcome::ShellFailure;
    const bool should_dispatch = opened_ok || shell_fails;
    const bool should_succeed = opened_ok || declined;
    const INT_PTR failure = shell_fails ? SE_ERR_NOASSOC : SE_ERR_ACCESSDENIED;
    const DWORD expected_error = opened_ok ? 812 : declined ? 527 : shell_fails ? ERROR_NO_ASSOCIATION : ERROR_CANCELLED;
    SetLastError(527);
    bool succeeded;
    DWORD error;
    if (extended) {
        SHELLEXECUTEINFOW call{sizeof(SHELLEXECUTEINFOW)};
        call.lpFile=file.c_str(); call.lpVerb=verb; call.fMask=SEE_MASK_NOASYNC|SEE_MASK_FLAG_NO_UI|extraMask; call.nShow=SW_SHOWNORMAL;
        if (extraMask & SEE_MASK_CLASSNAME) call.lpClass=L"FixtureExplicitClass";
        auto fn=reinterpret_cast<decltype(&ShellExecuteExW)>(cdf::browser_consent::shell[1].new_address);
        succeeded=fn(&call) != FALSE;
        error=GetLastError();
        Check(call.hProcess==(opened_ok ? reinterpret_cast<HANDLE>(0x4321) : nullptr),"extended process handle");
        const auto rc=reinterpret_cast<INT_PTR>(call.hInstApp);
        Check(declined ? rc > 32 : rc==(opened_ok ? 42 : failure),"extended shell result");
    } else {
        auto fn=reinterpret_cast<decltype(&ShellExecuteW)>(cdf::browser_consent::shell[0].new_address);
        const auto rc=fn(nullptr,verb,file.c_str(),nullptr,nullptr,SW_SHOWNORMAL);
        error=GetLastError();
        succeeded=reinterpret_cast<INT_PTR>(rc)>32;
        if (!should_succeed) Check(reinterpret_cast<INT_PTR>(rc)==failure, "simple shell error");
    }
    changing_input=nullptr;
    shell_fails=false;
    Check(succeeded==should_succeed,"caller result");
    Check(prompts-before==(shouldAsk ? 1u : 0u),"one consent dialog per covered request");
    Check(opened-calls==(should_dispatch ? 1u : 0u),"original operation invoked exactly as approved");
    Check(error==expected_error,"last error");
    if(should_dispatch){
        Check(received==original,"exact original URL passed to shell");
        Check(forwarded_error==527,"shell receives unmodified entry last error");
    }
}

void ExerciseDelayImports(RegFixture& config, const std::wstring& url) {
    using cdf::browser_consent::ForwardShellLookup;
    Check(GetModuleHandleW(L"CdfBrowserConsentShellFixture64.dll") == nullptr, "test shell DLL is actually delay-loaded");
    FARPROC result = nullptr;
    Check(!ForwardShellLookup(PreviousShellLookup, nullptr, "ShellExecuteA", result) && !result,
          "another export stays on the regular lookup path");
    Check(!ForwardShellLookup(PreviousShellLookup, nullptr, MAKEINTRESOURCEA(1), result) && !result,
          "ordinal queries stay on the regular lookup path");
    const std::wstring quoted = L"\""+url+L"\"";
    expected = url;
    config.enable(1);
    auto before = prompts;
    answer = Answer::Cancel;
    SHELLEXECUTEINFOW call{sizeof(call)};
    call.lpVerb = L"open";
    call.lpFile = quoted.c_str();
    call.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI | SEE_MASK_NOCLOSEPROCESS;
    call.nShow = SW_SHOWNORMAL;
    call.hProcess = reinterpret_cast<HANDLE>(0x4321);
    const BOOL dismissed = ShellExecuteExW(&call);
    Check(delay_lookups == 1 && prompts == before+1 && dismissed && !call.hProcess &&
          reinterpret_cast<INT_PTR>(call.hInstApp) > 32 && reinterpret_cast<INT_PTR>(call.hInstApp) != 42,
          "first delayed dismissal is handled without reaching the fake shell");

    before = prompts;
    answer = Answer::Open;
    const BOOL accepted = ShellExecuteExW(&call);
    const DWORD accepted_error = GetLastError();
    Check(delay_lookups == 1 && prompts == before+1 && accepted && accepted_error == ERROR_RETRY,
          "cached delay import still asks and forwards one approved open");

    config.enable(0);
    before = prompts;
    const auto direct = ShellExecuteW(nullptr, nullptr, url.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    const DWORD direct_error = GetLastError();
    Check(delay_lookups == 2 && prompts == before && reinterpret_cast<INT_PTR>(direct) == 42 && direct_error == ERROR_RETRY,
          "disabled consent passes through the other delayed open");

    config.enable(1);
    answer = Answer::Escape;
    SetLastError(527);
    const auto denied = ShellExecuteW(nullptr, nullptr, url.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    const DWORD denied_error = GetLastError();
    Check(delay_lookups == 2 && prompts == before+1 &&
          reinterpret_cast<INT_PTR>(denied) > 32 && reinterpret_cast<INT_PTR>(denied) != 42 && denied_error == 527,
          "cached simple open handles dismissal without dispatch or a shell failure");
}
}

extern "C" const PfnDliHook __pfnDliNotifyHook2 = ForwardFixtureDelay;

int wmain(int argc, wchar_t** argv) {
    HMODULE app_image = nullptr;
    if (argc == 3 && std::wstring(argv[1]) == L"--icon-source") {
        app_image = LoadLibraryExW(argv[2], nullptr, LOAD_LIBRARY_AS_DATAFILE_EXCLUSIVE | LOAD_LIBRARY_AS_IMAGE_RESOURCE);
        if (!app_image) return 2;
        cdf::browser_consent::SetFixtureIconSource(app_image);
        expect_app_icon = true;
    } else if (argc != 1) {
        return 2;
    }
    RegFixture config;
    if (!config.start()) return 2;
    cdf::browser_consent::shell[0].old_address=reinterpret_cast<PVOID>(&SinkW);
    cdf::browser_consent::shell[1].old_address=reinterpret_cast<PVOID>(&SinkEx);
    USEROBJECTFLAGS stationFlags{};
    DWORD returned=0;
    if (!GetUserObjectInformationW(GetProcessWindowStation(),UOI_FLAGS,&stationFlags,sizeof(stationFlags),&returned)) return 3;
    if (!(stationFlags.dwFlags & WSF_VISIBLE)) {
        config.enable(1);
        Exercise(true,L"open",L"https://example.invalid/interactive-only",L"",Answer::Cancel,false,Outcome::Unavailable);
        std::printf("checks=%u failures=%u non-interactive denial only; interactive dialogs not exercised\n",checks,failures);
        return failures ? 1 : 0;
    }
    auto previous=GetThreadDesktop(GetCurrentThreadId());
    auto desktop=CreateDesktopW((L"CdfConsent-"+std::to_wstring(GetCurrentProcessId())).c_str(),nullptr,nullptr,0,GENERIC_ALL,nullptr);
    if (!desktop || !SetThreadDesktop(desktop)) return 3;
    UINT_PTR timer=SetTimer(nullptr,0,40,Timer);
    if (!timer) return 4;
    const std::wstring url=L"https://example.invalid/login/路径?state=fixture%2Bcode&lang=zh#片段";
    const auto quoted=L"\""+url+L"\"";
    Exercise(true,L"open",quoted,url,Answer::Cancel,false,Outcome::Opened); // missing user setting
    config.enable(1);
    Exercise(true,L"open",quoted,url,Answer::Open,true,Outcome::Opened,true);
    Exercise(false,nullptr,url,url,Answer::Cancel,true,Outcome::Declined);
    Exercise(true,L"OPEN",quoted,url,Answer::Escape,true,Outcome::Declined,false,SEE_MASK_NOCLOSEPROCESS);
    Exercise(true,nullptr,quoted,url,Answer::Enter,true,Outcome::Declined);
    Exercise(false,L"open",url,url,Answer::Close,true,Outcome::Declined);
    Exercise(true,L"open",quoted,url,Answer::Open,true,Outcome::ShellFailure);
    Exercise(false,L"open",url,url,Answer::Open,true,Outcome::ShellFailure);
    const auto before_bad_dialog = prompts;
    Check(cdf::browser_consent::Confirm(nullptr,url.c_str(),url.size()-1) ==
          cdf::browser_consent::ConsentDecision::Unavailable && prompts == before_bad_dialog,
          "failure to display the full URL is distinct from dismissal");
    const auto longURL = L"HTTP://example.invalid/path?q="+std::wstring(9000,L'x')+L"&z=END#complete";
    Exercise(false,L"open",longURL,longURL,Answer::Open,true,Outcome::Opened);
    const auto wrappedURL = L"https://example.invalid/path?q="+std::wstring(650,L'x')+L"&z=END#complete";
    const RECT compact_areas[] = {
        {-880, 34, -880 + normal_size.cx*2/3, 34 + normal_size.cy*2}, // narrow secondary screen to the left
        {52, 71, 52 + normal_size.cx*2, 71 + normal_size.cy*2/3},    // reduced height at elevated DPI
    };
    for (const auto area : compact_areas) {
        simulated_work_area = area;
        cdf::browser_consent::SetFixtureWorkArea(area);
        Exercise(true,L"open",wrappedURL,wrappedURL,Answer::Cancel,true,Outcome::Declined);
    }
    simulated_work_area = {};
    cdf::browser_consent::SetFixtureWorkArea({});
    Exercise(true,L"open",L"mailto:test@example.invalid",L"",Answer::Close,false,Outcome::Opened);
    Exercise(false,L"open",L"C:\\sample.txt",L"",Answer::Close,false,Outcome::Opened);
    Exercise(true,L"properties",url,L"",Answer::Close,false,Outcome::Opened);
    Exercise(true,L"open",url,L"",Answer::Close,false,Outcome::Opened,false,SEE_MASK_CLASSNAME);
    Exercise(true,L"open",L"https://example.invalid/a\u202e/hidden",L"",Answer::Close,false,Outcome::Unavailable);
    Exercise(false,L"open",L"https://example.invalid/"+std::wstring(33000,L'x'),L"",Answer::Close,false,Outcome::Unavailable);
    config.enable(2); // unrecognized policy still requires consent
    Exercise(true,L"open",quoted,url,Answer::Cancel,true,Outcome::Declined);
    config.enable(0);
    Exercise(false,L"open",url,url,Answer::Cancel,false,Outcome::Opened);
    ExerciseDelayImports(config, url);
    KillTimer(nullptr,timer);
    SetThreadDesktop(previous);
    CloseDesktop(desktop);
    if (app_image) FreeLibrary(app_image);
    std::printf("checks=%u failures=%u nativeDialogs=%u delayLookups=%u realBrowserLaunches=0\n",checks,failures,prompts,delay_lookups);
    return failures ? 1 : 0;
}
