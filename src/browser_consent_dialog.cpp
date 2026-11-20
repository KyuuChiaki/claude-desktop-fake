#include "browser_consent.h"
#include "browser_consent_ids.h"
#include "runtime_provider.h"

extern "C" IMAGE_DOS_HEADER __ImageBase;

namespace cdf::browser_consent {
namespace {
template<class Fn>
Fn Loaded(PCWSTR module, const char* name) {
    return reinterpret_cast<Fn>(ResolveLoaded(module, name));
}

#define UI(name) decltype(&::name) name = Loaded<decltype(&::name)>(L"user32.dll", #name)
#define GDI(name) decltype(&::name) name = Loaded<decltype(&::name)>(L"gdi32.dll", #name)
struct DialogApi {
    UI(DialogBoxParamW);
    UI(EndDialog);
    UI(GetDlgItem);
    UI(SetDlgItemTextW);
    UI(SetWindowTextW);
    UI(GetWindowTextW);
    UI(GetWindowTextLengthW);
    UI(SetFocus);
    UI(SendMessageW);
    UI(SetWindowLongPtrW);
    UI(GetProcessWindowStation);
    UI(GetUserObjectInformationW);
    UI(GetClientRect);
    UI(GetWindowRect);
    UI(MapWindowPoints);
    UI(SetWindowPos);
    UI(GetForegroundWindow);
    UI(GetWindowThreadProcessId);
    UI(GetCursorPos);
    UI(MonitorFromWindow);
    UI(MonitorFromPoint);
    UI(GetMonitorInfoW);
    UI(LoadImageW);
    UI(DestroyIcon);
    UI(SystemParametersInfoW);
    UI(FillRect);
    UI(DrawIconEx);
    UI(DrawTextW);
    UI(DrawFocusRect);
    UI(MapDialogRect);
    UI(GetDpiForWindow);
    UI(SetWindowRgn);
};

constexpr COLORREF surface = RGB(255, 255, 255);
constexpr COLORREF url_surface = RGB(248, 246, 241);
constexpr COLORREF outline = RGB(226, 221, 212);
constexpr COLORREF ink = RGB(39, 36, 32);
constexpr COLORREF link_ink = RGB(64, 59, 53);
constexpr COLORREF terracotta = RGB(184, 83, 57);
constexpr int full_scale = 1024;
constexpr int controls[] = {IDC_BROWSER_LOGO, IDC_BROWSER_TITLE, IDC_BROWSER_URL, IDOK, IDCANCEL};

struct Appearance {
    GDI(CreateSolidBrush);
    GDI(CreatePen);
    GDI(CreateFontIndirectW);
    GDI(DeleteObject);
    GDI(SelectObject);
    GDI(SetBkColor);
    GDI(SetBkMode);
    GDI(SetTextColor);
    GDI(RoundRect);
    GDI(CreateRoundRectRgn);
    HBRUSH card = nullptr, field = nullptr, reject = nullptr;
    HPEN edge = nullptr, emphasis = nullptr;
    HFONT title = nullptr, url = nullptr, button = nullptr, native = nullptr;
    UINT dpi = 96;
    int scale = full_scale;
    bool ready = false;

    int scaled(int value) const { return (value*scale + full_scale/2)/full_scale; }
    int px(int value) const { return scaled((value*static_cast<int>(dpi)+48)/96); }
    HFONT font(int height, LONG weight, PCWSTR family) const {
        LOGFONTW spec{};
        spec.lfHeight = -px(height);
        spec.lfWeight = weight;
        spec.lfCharSet = DEFAULT_CHARSET;
        for (int i = 0; i + 1 < LF_FACESIZE && family[i]; ++i) spec.lfFaceName[i] = family[i];
        return CreateFontIndirectW(&spec);
    }
    ~Appearance() {
        if (!DeleteObject) return;
        const HGDIOBJ objects[] = {title, url, button, native, edge, emphasis, card, field, reject};
        for (auto object : objects) if (object) DeleteObject(object);
    }
    void rounded(HDC dc, const RECT& bounds, int diameter, HBRUSH brush, HPEN pen) const {
        const auto saved_fill = SelectObject(dc, brush);
        const auto saved_edge = SelectObject(dc, pen);
        RoundRect(dc, bounds.left, bounds.top, bounds.right, bounds.bottom, diameter, diameter);
        SelectObject(dc, saved_edge);
        SelectObject(dc, saved_fill);
    }
};
#undef UI
#undef GDI

struct Dialog {
    const DialogApi& api;
    PCWSTR text;
    size_t length;
    HWND owner;
    Appearance appearance{};
    HWND edit = nullptr;
    HICON logo = nullptr;
    RECT url_field{CDF_CONSENT_URL_LEFT, CDF_CONSENT_URL_TOP, CDF_CONSENT_URL_RIGHT, CDF_CONSENT_URL_BOTTOM};
};

#if defined(CDF_BROWSER_CONSENT_FIXTURE)
RECT fixture_work_area{};
#endif

HMONITOR SelectMonitor(const DialogApi& api, HWND owner) {
    if (!api.MonitorFromWindow) return nullptr;
    if (owner) {
        if (const auto monitor = api.MonitorFromWindow(owner, MONITOR_DEFAULTTONULL)) return monitor;
    }
    if (api.GetForegroundWindow && api.GetWindowThreadProcessId) {
        const auto current_pid = Loaded<decltype(&GetCurrentProcessId)>(L"kernel32.dll", "GetCurrentProcessId");
        const HWND foreground = api.GetForegroundWindow();
        DWORD pid = 0;
        if (current_pid && foreground && api.GetWindowThreadProcessId(foreground, &pid) && pid == current_pid()) {
            return api.MonitorFromWindow(foreground, MONITOR_DEFAULTTONEAREST);
        }
    }
    POINT cursor{};
    return api.GetCursorPos && api.MonitorFromPoint && api.GetCursorPos(&cursor)
        ? api.MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST) : nullptr;
}

void FitDialog(HWND window, Dialog& dialog) {
    const auto& api = dialog.api;
    auto& appearance = dialog.appearance;
    constexpr UINT position_flags = SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER;
    MONITORINFO monitor_info{sizeof(monitor_info)};
    const auto monitor = SelectMonitor(api, dialog.owner);
    const auto initial_monitor = api.MonitorFromWindow ? api.MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST) : nullptr;
    if (api.GetMonitorInfoW) api.GetMonitorInfoW(monitor ? monitor : initial_monitor, &monitor_info);
    RECT work = monitor_info.rcWork;
#if defined(CDF_BROWSER_CONSENT_FIXTURE)
    if (fixture_work_area.right > fixture_work_area.left) work = fixture_work_area;
#endif
    // Let the dialog manager update its template metrics before measuring on another display.
    if (monitor && initial_monitor && monitor != initial_monitor && api.SetWindowPos &&
        work.right > work.left && work.bottom > work.top) {
        api.SetWindowPos(window, nullptr, work.left, work.top, 0, 0, position_flags | SWP_NOSIZE);
    }
    if (api.GetDpiForWindow) {
        const UINT dpi = api.GetDpiForWindow(window);
        if (dpi) appearance.dpi = dpi;
    }
    if (api.MapDialogRect) api.MapDialogRect(window, &dialog.url_field);
    RECT bounds{};
    if (!api.GetWindowRect || !api.SetWindowPos || !api.GetWindowRect(window, &bounds)) return;
    const int width = bounds.right - bounds.left;
    const int height = bounds.bottom - bounds.top;
    const int work_width = work.right - work.left;
    const int work_height = work.bottom - work.top;
    if (width <= 0 || height <= 0 || work_width <= 0 || work_height <= 0) return;
    const int margin = appearance.px(12);
    const int available_width = work_width > 2*margin ? work_width - 2*margin : work_width;
    const int available_height = work_height > 2*margin ? work_height - 2*margin : work_height;
    const int fit_x = available_width < width ? available_width*full_scale/width : full_scale;
    const int fit_y = available_height < height ? available_height*full_scale/height : full_scale;
    const int scale = fit_x < fit_y ? fit_x : fit_y;
    if (!scale) return;
    const bool compact = scale < full_scale;
    RECT items[ARRAYSIZE(controls)]{};
    HWND children[ARRAYSIZE(controls)]{};
    if (compact) {
        if (!api.MapWindowPoints) return;
        for (size_t i = 0; i < ARRAYSIZE(controls); ++i) {
            children[i] = api.GetDlgItem(window, controls[i]);
            if (!children[i] || !api.GetWindowRect(children[i], &items[i])) return;
            api.MapWindowPoints(nullptr, window, reinterpret_cast<POINT*>(&items[i]), 2);
        }
    }
    appearance.scale = scale;
    const int fit_width = appearance.scaled(width), fit_height = appearance.scaled(height);
    if (!api.SetWindowPos(window, nullptr, work.left + (work_width-fit_width)/2,
                          work.top + (work_height-fit_height)/2, fit_width, fit_height, position_flags)) {
        appearance.scale = full_scale;
        return;
    }
    if (!compact) return;
    const auto scaled = [&appearance](RECT rect) -> RECT {
        return {appearance.scaled(rect.left), appearance.scaled(rect.top),
                appearance.scaled(rect.right), appearance.scaled(rect.bottom)};
    };
    for (size_t i = 0; i < ARRAYSIZE(controls); ++i) {
        const auto item = scaled(items[i]);
        api.SetWindowPos(children[i], nullptr, item.left, item.top,
                         item.right-item.left, item.bottom-item.top, position_flags);
    }
    dialog.url_field = scaled(dialog.url_field);
}

struct IconLoad {
    const DialogApi& api;
    int size;
    HICON icon;
};

BOOL CALLBACK FindAppIcon(HMODULE module, LPCWSTR, LPWSTR name, LONG_PTR parameter) {
    auto& operation = *reinterpret_cast<IconLoad*>(parameter);
    operation.icon = static_cast<HICON>(operation.api.LoadImageW(module, name, IMAGE_ICON,
                                                                 operation.size, operation.size, 0));
    return !operation.icon;
}

#if defined(CDF_BROWSER_CONSENT_FIXTURE)
HMODULE fixture_icon_source = nullptr;
#endif

void SetAppLogo(HWND window, Dialog& dialog) {
    const auto& api = dialog.api;
    if (!api.LoadImageW || !api.DestroyIcon || !api.GetClientRect) return;
    const auto get_module = Loaded<decltype(&GetModuleHandleW)>(L"kernel32.dll", "GetModuleHandleW");
    const auto enumerate = Loaded<decltype(&EnumResourceNamesW)>(L"kernel32.dll", "EnumResourceNamesW");
    if (!get_module || !enumerate) return;
    HMODULE executable = get_module(nullptr);
#if defined(CDF_BROWSER_CONSENT_FIXTURE)
    if (fixture_icon_source) executable = fixture_icon_source;
#endif
    const auto logo = api.GetDlgItem(window, IDC_BROWSER_LOGO);
    RECT bounds{};
    if (!executable || !logo || !api.GetClientRect(logo, &bounds)) return;
    const int size = bounds.right < bounds.bottom ? bounds.right : bounds.bottom;
    if (size <= 0) return;
    IconLoad operation{api, size, nullptr};
    // Read the icon group from the host executable's loaded resources.
    enumerate(executable, MAKEINTRESOURCEW(14), FindAppIcon, reinterpret_cast<LONG_PTR>(&operation));
    dialog.logo = operation.icon;
    if (dialog.logo) api.SendMessageW(logo, STM_SETICON, reinterpret_cast<WPARAM>(dialog.logo), 0);
}

void ApplyAppearance(HWND window, Dialog& dialog) {
    const auto& api = dialog.api;
    auto& appearance = dialog.appearance;
    HIGHCONTRASTW contrast{sizeof(contrast)};
    if (api.SystemParametersInfoW && api.SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0) &&
        (contrast.dwFlags & HCF_HIGHCONTRASTON)) return;
    if (!api.FillRect || !api.DrawTextW || !api.DrawFocusRect || !api.GetWindowTextW ||
        !api.GetClientRect || !appearance.CreateSolidBrush || !appearance.CreatePen || !appearance.CreateFontIndirectW ||
        !appearance.DeleteObject || !appearance.SelectObject || !appearance.SetBkColor || !appearance.SetBkMode ||
        !appearance.SetTextColor || !appearance.RoundRect) return;
    appearance.card = appearance.CreateSolidBrush(surface);
    appearance.field = appearance.CreateSolidBrush(url_surface);
    appearance.reject = appearance.CreateSolidBrush(terracotta);
    appearance.edge = appearance.CreatePen(PS_SOLID, 1, outline);
    appearance.emphasis = appearance.CreatePen(PS_SOLID, 1, terracotta);
    appearance.title = appearance.font(24, FW_BOLD, L"SimSun");
    appearance.url = appearance.font(16, FW_NORMAL, L"Consolas");
    appearance.button = appearance.font(18, FW_SEMIBOLD, L"Microsoft YaHei UI");
    if (!appearance.card || !appearance.field || !appearance.reject || !appearance.edge || !appearance.emphasis ||
        !appearance.title || !appearance.url || !appearance.button) return;
    appearance.ready = true;
    api.SendMessageW(api.GetDlgItem(window, IDC_BROWSER_TITLE), WM_SETFONT, reinterpret_cast<WPARAM>(appearance.title), TRUE);
    api.SendMessageW(dialog.edit, WM_SETFONT, reinterpret_cast<WPARAM>(appearance.url), TRUE);
    const int buttons[] = {IDOK, IDCANCEL};
    for (const int id : buttons) {
        api.SendMessageW(api.GetDlgItem(window, id), BM_SETSTYLE, BS_OWNERDRAW, TRUE);
    }
    if (dialog.logo && api.DrawIconEx) {
        const HWND logo = api.GetDlgItem(window, IDC_BROWSER_LOGO);
        const auto get = Loaded<decltype(&GetWindowLongPtrW)>(L"user32.dll", "GetWindowLongPtrW");
        if (get) {
            api.SetWindowLongPtrW(logo, GWL_STYLE, (get(logo, GWL_STYLE) & ~SS_TYPEMASK) | SS_OWNERDRAW);
        }
    }
    if (appearance.CreateRoundRectRgn && api.SetWindowRgn) {
        RECT rect{};
        api.GetClientRect(window, &rect);
        const int diameter = appearance.px(48);
        const auto region = appearance.CreateRoundRectRgn(0, 0, rect.right+1, rect.bottom+1, diameter, diameter);
        if (region && !api.SetWindowRgn(window, region, TRUE)) appearance.DeleteObject(region);
    }
}

void PositionUrl(Dialog& dialog) {
    const auto& api = dialog.api;
    const auto& appearance = dialog.appearance;
    if (!appearance.ready ||
        api.SendMessageW(dialog.edit, EM_GETLINECOUNT, 0, 0) != 1) return;
    RECT text{};
    if (api.GetClientRect(dialog.edit, &text)) {
        const int center = (text.bottom-appearance.px(20))/2;
        if (center > 0) text.top = center;
        api.SendMessageW(dialog.edit, EM_SETRECT, 0, reinterpret_cast<LPARAM>(&text));
    }
}

void PaintCard(HWND window, HDC dc, const Dialog& dialog) {
    RECT bounds{};
    const auto& appearance = dialog.appearance;
    dialog.api.GetClientRect(window, &bounds);
    appearance.rounded(dc, bounds, appearance.px(48), appearance.card, appearance.edge);
    appearance.rounded(dc, dialog.url_field, appearance.px(28), appearance.field, appearance.edge);
}

void PaintButton(const DRAWITEMSTRUCT& item, const Dialog& dialog) {
    const auto& appearance = dialog.appearance;
    const auto& api = dialog.api;
    const bool decline = item.CtlID == IDCANCEL;
    api.FillRect(item.hDC, &item.rcItem, appearance.card);
    RECT shape = item.rcItem;
    if (item.itemState & ODS_SELECTED) {
        ++shape.left; ++shape.top; --shape.right; --shape.bottom;
    }
    appearance.rounded(item.hDC, shape, shape.bottom-shape.top,
        decline ? appearance.reject : appearance.card,
        decline ? appearance.emphasis : appearance.edge);
    WCHAR label[20]{};
    api.GetWindowTextW(item.hwndItem, label, ARRAYSIZE(label));
    const auto previous_font = appearance.SelectObject(item.hDC, appearance.button);
    const auto previous_mode = appearance.SetBkMode(item.hDC, TRANSPARENT);
    const auto previous_color = appearance.SetTextColor(item.hDC, decline ? surface : ink);
    api.DrawTextW(item.hDC, label, -1, &shape, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    appearance.SetTextColor(item.hDC, previous_color);
    appearance.SetBkMode(item.hDC, previous_mode);
    appearance.SelectObject(item.hDC, previous_font);
    if ((item.itemState & ODS_FOCUS) && !(item.itemState & ODS_NOFOCUSRECT)) {
        const int inset = appearance.px(9);
        shape.left += inset; shape.right -= inset;
        shape.top += inset; shape.bottom -= inset;
        api.DrawFocusRect(item.hDC, &shape);
    }
}

INT_PTR CALLBACK DialogProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
    if (message == WM_INITDIALOG) {
        auto& dialog = *reinterpret_cast<Dialog*>(lp);
        const auto& api = dialog.api;
        api.SetWindowLongPtrW(window, DWLP_USER, lp);
        if (api.SetWindowTextW) api.SetWindowTextW(window, L"打开默认浏览器前确认");
        dialog.edit = api.GetDlgItem(window, IDC_BROWSER_URL);
        if (!dialog.edit) {
            api.EndDialog(window, 0);
            return FALSE;
        }
        FitDialog(window, dialog);
        SetAppLogo(window, dialog);
        api.SetFocus(api.GetDlgItem(window, IDCANCEL));
        ApplyAppearance(window, dialog);
        auto& appearance = dialog.appearance;
        if (!appearance.ready && appearance.scale < full_scale && appearance.CreateFontIndirectW &&
            appearance.DeleteObject) {
            appearance.native = appearance.font(12, FW_NORMAL, L"Microsoft YaHei UI");
            if (appearance.native) {
                for (int id : controls) api.SendMessageW(api.GetDlgItem(window, id), WM_SETFONT,
                                                         reinterpret_cast<WPARAM>(appearance.native), TRUE);
            }
        }
        // Fill the edit control once it has its final font and wrap width.
        if (!api.SetDlgItemTextW(window, IDC_BROWSER_URL, dialog.text) ||
            static_cast<size_t>(api.GetWindowTextLengthW(dialog.edit)) != dialog.length) {
            api.EndDialog(window, 0);
        } else {
            PositionUrl(dialog);
        }
        return FALSE;
    }
    if (message != WM_CLOSE && message != WM_COMMAND && message != WM_ERASEBKGND && message != WM_CTLCOLORDLG &&
        message != WM_CTLCOLORSTATIC && message != WM_CTLCOLOREDIT && message != WM_DRAWITEM) return FALSE;
    const auto get = Loaded<decltype(&GetWindowLongPtrW)>(L"user32.dll", "GetWindowLongPtrW");
    const auto* dialog = get ? reinterpret_cast<const Dialog*>(get(window, DWLP_USER)) : nullptr;
    if (!dialog) return FALSE;
    if (message == WM_CLOSE || (message == WM_COMMAND && LOWORD(wp) == IDCANCEL)) {
        dialog->api.EndDialog(window, IDCANCEL);
        return TRUE;
    }
    if (message == WM_COMMAND && LOWORD(wp) == IDOK) {
        dialog->api.EndDialog(window, IDOK);
        return TRUE;
    }
    const auto& appearance = dialog->appearance;
    if (!appearance.ready) return FALSE;
    if (message == WM_ERASEBKGND) {
        PaintCard(window, reinterpret_cast<HDC>(wp), *dialog);
        return TRUE;
    }
    if (message == WM_CTLCOLORDLG) return reinterpret_cast<INT_PTR>(appearance.card);
    if (message == WM_CTLCOLORSTATIC || message == WM_CTLCOLOREDIT) {
        const bool field = reinterpret_cast<HWND>(lp) == dialog->edit;
        const auto dc = reinterpret_cast<HDC>(wp);
        appearance.SetTextColor(dc, field ? link_ink : ink);
        appearance.SetBkColor(dc, field ? url_surface : surface);
        return reinterpret_cast<INT_PTR>(field ? appearance.field : appearance.card);
    }
    if (message == WM_DRAWITEM && (wp == IDOK || wp == IDCANCEL)) {
        PaintButton(*reinterpret_cast<const DRAWITEMSTRUCT*>(lp), *dialog);
        return TRUE;
    }
    if (message == WM_DRAWITEM && wp == IDC_BROWSER_LOGO && dialog->logo && dialog->api.DrawIconEx) {
        const auto& item = *reinterpret_cast<const DRAWITEMSTRUCT*>(lp);
        const RECT rect = item.rcItem;
        const int width = rect.right-rect.left;
        const int height = rect.bottom-rect.top;
        const int size = (width < height ? width : height)-2;
        dialog->api.FillRect(item.hDC, &rect, appearance.card);
        if (size > 0) {
            dialog->api.DrawIconEx(item.hDC, rect.left+(width-size)/2, rect.top+(height-size)/2,
                dialog->logo, size, size, 0, nullptr, DI_NORMAL);
        }
        return TRUE;
    }
    return FALSE;
}
} // namespace

#if defined(CDF_BROWSER_CONSENT_FIXTURE)
void SetFixtureIconSource(HMODULE module) { fixture_icon_source = module; }
void SetFixtureWorkArea(RECT bounds) { fixture_work_area = bounds; }
#endif

ConsentDecision Confirm(HWND owner, PCWSTR url, size_t length) {
    const DialogApi api{};
    USEROBJECTFLAGS flags{};
    DWORD bytes = 0;
    if (!api.GetProcessWindowStation || !api.GetUserObjectInformationW ||
        !api.GetUserObjectInformationW(api.GetProcessWindowStation(), UOI_FLAGS, &flags, sizeof(flags), &bytes) ||
        !(flags.dwFlags & WSF_VISIBLE)) return ConsentDecision::Unavailable;
    if (!api.DialogBoxParamW || !api.EndDialog || !api.GetDlgItem || !api.SetDlgItemTextW || !api.GetWindowTextLengthW ||
        !api.SetFocus || !api.SendMessageW || !api.SetWindowLongPtrW) return ConsentDecision::Unavailable;
    Dialog dialog{api, url, length, owner};
    const auto result = api.DialogBoxParamW(reinterpret_cast<HINSTANCE>(&__ImageBase),
        MAKEINTRESOURCEW(IDD_BROWSER_CONSENT), owner, DialogProc, reinterpret_cast<LPARAM>(&dialog));
    if (dialog.logo) api.DestroyIcon(dialog.logo);
    if (result == IDOK) return ConsentDecision::Approved;
    if (result == IDCANCEL) return ConsentDecision::Declined;
    return ConsentDecision::Unavailable;
}
} // namespace cdf::browser_consent
