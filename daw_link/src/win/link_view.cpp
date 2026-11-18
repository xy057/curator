// Attacca's window in the DAW on Windows (link_view.h; macOS': mac/link_view.mm): a child of
// the window the DAW gives, drawn by hand: its name, whether Curator is connected (or why
// not), and the Curator projects following this DAW; for Attacca, the Capturer menu. Attacca
// Capturer's says whether it is capturing, or that it isn't linked.
#include "../link_view.h"

#include "../link_capture.h"
#include "../link_client.h"
#include "../link_config.h"
#include "../link_system.h"

#include <windows.h>

#include <tlhelp32.h>

#include <algorithm>
#include <cmath>
#include <system_error>
#include <utility>
#include <vector>

namespace attacca {

namespace {

// Curator's program on Windows (app/windows/CMakeLists.txt's BINARY_NAME): whether it is open.
constexpr const wchar_t* curatorProgram = L"curator.exe";
constexpr const wchar_t* className = L"AttaccaStatusView";
constexpr UINT_PTR timerId = 1;
constexpr int capturersId = 100;

constexpr COLORREF green = RGB (52, 199, 89), orange = RGB (255, 149, 0);

// This DLL, whichever of the two bundles it is: its window class is its own.
HINSTANCE thisModule ()
{
    HMODULE module = nullptr;
    ::GetModuleHandleExW (GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, reinterpret_cast<LPCWSTR> (&thisModule), &module);
    return module;
}

std::wstring wide (const std::string& text)
{
    const int n = ::MultiByteToWideChar (CP_UTF8, 0, text.data (), static_cast<int> (text.size ()), nullptr, 0);
    std::wstring out (static_cast<size_t> (n > 0 ? n : 0), L'\0');
    if (n > 0)
        ::MultiByteToWideChar (CP_UTF8, 0, text.data (), static_cast<int> (text.size ()), out.data (), n);
    return out;
}

bool curatorOpen ()
{
    const HANDLE processes = ::CreateToolhelp32Snapshot (TH32CS_SNAPPROCESS, 0);
    if (processes == INVALID_HANDLE_VALUE)
        return false;
    PROCESSENTRY32W entry {};
    entry.dwSize = sizeof entry;
    bool found = false;
    for (BOOL more = ::Process32FirstW (processes, &entry); more && !found; more = ::Process32NextW (processes, &entry))
        found = ::_wcsicmp (entry.szExeFile, curatorProgram) == 0;
    ::CloseHandle (processes);
    return found;
}

bool discoveryFileThere ()
{
    std::error_code error;
    return std::filesystem::exists (fileOf (curatorDataFolder () + "/daw-link.json"), error);
}

struct StatusView {
    HWND window { nullptr }, capturers { nullptr };
    LinkClient* client { nullptr };
    bool capturer { false };
    std::function<int ()> bound;
    std::function<std::string ()> capturerId;

    // What it says now.
    std::wstring status, detail;
    COLORREF dot { 0 };
    // Attacca's: the Capturers its menu lists (after None), as Curator says.
    std::vector<std::pair<std::string, std::string>> listed;

    // Its fonts, made for the size it is drawn at ([scale] pixels a point).
    double scale { 0 };
    HFONT titleFont { nullptr }, statusFont { nullptr }, detailFont { nullptr };

    ~StatusView () { dropFonts (); }

    void dropFonts ()
    {
        for (HFONT* font : { &titleFont, &statusFont, &detailFont })
        {
            if (*font)
                ::DeleteObject (*font);
            *font = nullptr;
        }
    }

    int px (double points) const { return static_cast<int> (std::lround (points * scale)); }

    // The window is [statusViewHeight] points high, however many pixels the DAW made it: the
    // fonts and the layout follow, so what it shows always fits.
    void layout ()
    {
        RECT client {};
        ::GetClientRect (window, &client);
        const double now = std::clamp (static_cast<double> (client.bottom) / statusViewHeight, 0.5, 8.0);
        if (now != scale)
        {
            scale = now;
            dropFonts ();
            NONCLIENTMETRICSW metrics {};
            metrics.cbSize = sizeof metrics;
            LOGFONTW face {};
            if (::SystemParametersInfoW (SPI_GETNONCLIENTMETRICS, sizeof metrics, &metrics, 0))
                face = metrics.lfMessageFont;
            auto font = [&] (double points, bool bold) {
                LOGFONTW f = face;
                f.lfHeight = -px (points);
                f.lfWidth = 0;
                f.lfWeight = bold ? FW_BOLD : FW_NORMAL;
                return ::CreateFontIndirectW (&f);
            };
            titleFont = font (16, true);
            statusFont = font (13, false);
            detailFont = font (12, false);
            if (capturers)
                ::SendMessageW (capturers, WM_SETFONT, reinterpret_cast<WPARAM> (detailFont), TRUE);
        }
        if (capturers)
        {
            // Beside its label, as wide as the window leaves; its height is its list's when open.
            const HDC dc = ::GetDC (window);
            const HGDIOBJ old = ::SelectObject (dc, detailFont);
            SIZE label {};
            ::GetTextExtentPoint32W (dc, L"Capturer", 8, &label);
            ::SelectObject (dc, old);
            ::ReleaseDC (window, dc);
            const int x = px (16) + label.cx + px (8);
            ::MoveWindow (capturers, x, top () + px (22 + 4 + 18 + 4 + 32 + 4), std::max (px (60), static_cast<int> (client.right) - x - px (16)), px (220), TRUE);
        }
    }

    // Where its rows start: title, state, two lines of detail and (Attacca's) the Capturer menu,
    // centred in the window.
    int top () const { return px ((statusViewHeight - (22 + 4 + 18 + 4 + 32 + (capturer ? 0 : 4 + 24))) / 2.0); }

    void chosen ()
    {
        const LRESULT at = ::SendMessageW (capturers, CB_GETCURSEL, 0, 0);
        client->setLinkedCapturer (at > 0 && static_cast<size_t> (at) <= listed.size () ? listed[static_cast<size_t> (at - 1)].first : std::string ());
        update ();
    }

    // The Capturer menu as the DAW's Capturers are now, the linked one chosen (one linked that
    // isn't there now is listed all the same, so the link isn't lost while its insert loads).
    void updateCapturers ()
    {
        // (Left alone while its list is open: the choice would move under the pointer.)
        if (::SendMessageW (capturers, CB_GETDROPPEDSTATE, 0, 0))
            return;
        auto now = client->inserts ();
        const std::string linked = client->linkedCapturer ();
        if (!linked.empty () && std::none_of (now.begin (), now.end (), [&] (const auto& c) { return c.first == linked; }))
            now.emplace_back (linked, "Attacca Capturer (not in the DAW)");
        if (now != listed || ::SendMessageW (capturers, CB_GETCOUNT, 0, 0) == 0)
        {
            listed = now;
            ::SendMessageW (capturers, CB_RESETCONTENT, 0, 0);
            ::SendMessageW (capturers, CB_ADDSTRING, 0, reinterpret_cast<LPARAM> (L"None"));
            for (const auto& c : listed)
            {
                const std::wstring title = c.second.empty () ? std::wstring (L"Attacca Capturer") : wide (c.second);
                ::SendMessageW (capturers, CB_ADDSTRING, 0, reinterpret_cast<LPARAM> (title.c_str ()));
            }
        }
        WPARAM at = 0;
        for (size_t i = 0; i < listed.size (); ++i)
        {
            if (listed[i].first == linked)
                at = i + 1;
        }
        if (static_cast<WPARAM> (::SendMessageW (capturers, CB_GETCURSEL, 0, 0)) != at)
            ::SendMessageW (capturers, CB_SETCURSEL, at, 0);
        ::EnableWindow (capturers, client->connected () || !linked.empty ());
    }

    // Where Curator is: connected (and the projects following this DAW), connecting, open but
    // not listening (no discovery file), or not open.
    void update ()
    {
        std::wstring nowStatus, nowDetail;
        COLORREF nowDot = orange;
        if (client->connected ())
        {
            nowStatus = L"Connected to Curator";
            nowDot = green;
            std::string names = client->followers ();
            if (names.empty ())
            {
                nowDetail = L"No project follows this DAW";
            }
            else
            {
                for (size_t at = 0; (at = names.find ('\n', at)) != std::string::npos; at += 2)
                    names.replace (at, 1, ", ");
                nowDetail = L"Followed by " + wide (names);
            }
            if (capturer && Capturer::busy ())
                nowDetail = L"Capturing for Curator…";
        }
        else if (!curatorOpen ())
        {
            nowStatus = L"Curator isn’t open";
            nowDot = ::GetSysColor (COLOR_GRAYTEXT);
            nowDetail = L"Connects when Curator opens";
        }
        else if (discoveryFileThere ())
        {
            nowStatus = L"Connecting to Curator…";
        }
        else
        {
            nowStatus = L"Curator isn’t listening";
            nowDetail = L"Settings ▸ General ▸ DAW ▸ Listen for Attacca";
        }
        // Attacca on an insert only, never bound to ARA; the Capturer linked or not to the Attacca
        // on a track (chosen in its window), as Curator says.
        if (!capturer && bound && bound () == 0)
        {
            nowDot = orange;
            nowDetail = L"Insert only: add Attacca to a track as an ARA extension";
        }
        if (capturer && capturerId)
        {
            const int linked = client->linked (capturerId ());
            if (linked == 0)
            {
                nowDot = orange;
                nowDetail = L"Not linked: choose it in Attacca’s window";
            }
            else if (linked == 1 && !Capturer::busy ())
            {
                nowDetail = L"Linked to Attacca";
            }
        }
        if (capturers)
            updateCapturers ();
        // Outdated: Curator bundles a newer Attacca. (Windows lets no program replace one a DAW
        // has loaded, so a newer one is never on disk under it, as it can be on macOS.)
        if (const int loaded = LINK_BUILD; loaded > 0 && client->curatorBuild () > loaded)
        {
            nowDot = orange;
            nowDetail = L"Outdated: update it in Curator’s Settings";
        }
        if (nowStatus != status || nowDetail != detail || nowDot != dot)
        {
            status = std::move (nowStatus);
            detail = std::move (nowDetail);
            dot = nowDot;
            ::InvalidateRect (window, nullptr, TRUE);
        }
    }

    // Drawn into [dc]: the window's, or one a DAW gives to take its picture (WM_PRINTCLIENT).
    void draw (HDC dc)
    {
        RECT client {};
        ::GetClientRect (window, &client);
        ::FillRect (dc, &client, ::GetSysColorBrush (COLOR_BTNFACE));
        ::SetBkMode (dc, TRANSPARENT);
        const int left = px (16), right = static_cast<int> (client.right) - px (16);
        int y = top ();
        auto text = [&] (HFONT font, COLORREF color, const std::wstring& what, int x, int height, UINT how) {
            const HGDIOBJ old = ::SelectObject (dc, font);
            ::SetTextColor (dc, color);
            RECT box { x, y, right, y + height };
            ::DrawTextW (dc, what.c_str (), static_cast<int> (what.size ()), &box, how | DT_NOPREFIX);
            SIZE size {};
            ::GetTextExtentPoint32W (dc, what.c_str (), static_cast<int> (what.size ()), &size);
            ::SelectObject (dc, old);
            return static_cast<int> (size.cx);
        };
        const COLORREF ink = ::GetSysColor (COLOR_BTNTEXT), faint = ::GetSysColor (COLOR_GRAYTEXT);
        text (titleFont, ink, capturer ? L"Attacca Capturer" : L"Attacca", left, px (22), DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        y += px (22 + 4);
        const int dotWidth = text (statusFont, dot, L"●", left, px (18), DT_SINGLELINE | DT_VCENTER);
        text (statusFont, ink, status, left + dotWidth + px (5), px (18), DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        y += px (18 + 4);
        text (detailFont, faint, detail, left, px (32), DT_WORDBREAK | DT_EDITCONTROL | DT_END_ELLIPSIS);
        y += px (32 + 4);
        if (capturers)
            text (detailFont, ink, L"Capturer", left, px (24), DT_SINGLELINE | DT_VCENTER);
    }
};

LRESULT CALLBACK statusProc (HWND window, UINT message, WPARAM wParam, LPARAM lParam)
{
    if (message == WM_NCCREATE)
        ::SetWindowLongPtrW (window, GWLP_USERDATA, reinterpret_cast<LONG_PTR> (reinterpret_cast<CREATESTRUCTW*> (lParam)->lpCreateParams));
    auto* view = reinterpret_cast<StatusView*> (::GetWindowLongPtrW (window, GWLP_USERDATA));
    if (view && view->window == window)
    {
        switch (message)
        {
            case WM_PAINT:
            {
                PAINTSTRUCT painting {};
                view->draw (::BeginPaint (window, &painting));
                ::EndPaint (window, &painting);
                return 0;
            }
            case WM_PRINTCLIENT:
                view->draw (reinterpret_cast<HDC> (wParam));
                return 0;
            case WM_ERASEBKGND:
                return 1;
            case WM_SIZE:
                view->layout ();
                ::InvalidateRect (window, nullptr, TRUE);
                return 0;
            case WM_TIMER:
                if (wParam == timerId)
                    view->update ();
                return 0;
            case WM_COMMAND:
                if (LOWORD (wParam) == capturersId && HIWORD (wParam) == CBN_SELCHANGE)
                    view->chosen ();
                return 0;
            default:
                break;
        }
    }
    return ::DefWindowProcW (window, message, wParam, lParam);
}

// The window class, there while a view is (it must be gone before the DLL is: its procedure is
// in it). On the DAW's window thread only.
int views = 0;

}  // namespace

void* attachStatusView (void* parent, bool capturer, std::function<int ()> bound, std::function<std::string ()> capturerId)
{
    const HWND parentWindow = static_cast<HWND> (parent);
    const HINSTANCE module = thisModule ();
    if (views == 0)
    {
        WNDCLASSEXW windowClass {};
        windowClass.cbSize = sizeof windowClass;
        windowClass.lpfnWndProc = &statusProc;
        windowClass.hInstance = module;
        windowClass.hCursor = ::LoadCursorW (nullptr, IDC_ARROW);
        windowClass.lpszClassName = className;
        if (!::RegisterClassExW (&windowClass) && ::GetLastError () != ERROR_CLASS_ALREADY_EXISTS)
            return nullptr;
    }
    auto* view = new StatusView;
    view->client = &LinkClient::retain ();
    view->capturer = capturer;
    view->bound = std::move (bound);
    view->capturerId = std::move (capturerId);
    RECT room {};
    ::GetClientRect (parentWindow, &room);
    if (room.right <= 0 || room.bottom <= 0)
        room = { 0, 0, statusViewWidth, statusViewHeight };
    // (Its procedure takes it up once [window] is set: what it is sent while being made is passed on.)
    const HWND window = ::CreateWindowExW (0, className, L"", WS_CHILD | WS_CLIPCHILDREN, 0, 0, room.right, room.bottom, parentWindow, nullptr, module, view);
    if (!window)
    {
        LinkClient::release ();
        delete view;
        if (views == 0)
            ::UnregisterClassW (className, module);
        return nullptr;
    }
    ++views;
    view->window = window;
    if (!capturer)
    {
        // The Attacca Capturer linked to this DAW's Attacca: Record from DAW… captures with it.
        view->capturers = ::CreateWindowExW (0, L"COMBOBOX", L"", WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_TABSTOP | CBS_DROPDOWNLIST, 0, 0, 10, 10, window,
                                             reinterpret_cast<HMENU> (static_cast<INT_PTR> (capturersId)), module, nullptr);
    }
    view->layout ();
    view->update ();
    // How Curator stands, asked each second while the window is there.
    ::SetTimer (window, timerId, 1000, nullptr);
    ::ShowWindow (window, SW_SHOWNA);
    return view;
}

void resizeStatusView (void* handle, int width, int height)
{
    if (auto* view = static_cast<StatusView*> (handle); view && width > 0 && height > 0)
        ::MoveWindow (view->window, 0, 0, width, height, TRUE);
}

void detachStatusView (void* handle)
{
    auto* view = static_cast<StatusView*> (handle);
    if (!view)
        return;
    const HWND window = view->window;
    view->window = nullptr;  // its procedure lets it be from here
    ::KillTimer (window, timerId);
    ::DestroyWindow (window);
    delete view;
    LinkClient::release ();
    if (--views == 0)
        ::UnregisterClassW (className, thisModule ());
}

}  // namespace attacca
