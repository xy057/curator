#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <commdlg.h>
#include <flutter_windows.h>

#include <cwchar>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "utils.h"

namespace {

// Below this (logical pixels) the editor's panels would overflow (WindowChrome.minimumSize in Dart).
constexpr int kMinimumWidth = 960;
constexpr int kMinimumHeight = 620;

std::wstring Utf16FromUtf8(const std::string& text) {
  if (text.empty()) return std::wstring();
  int length = ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
                                     static_cast<int>(text.size()), nullptr, 0);
  std::wstring result(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                        result.data(), length);
  return result;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  if (big_icon_) ::DestroyIcon(big_icon_);
  if (small_icon_) ::DestroyIcon(small_icon_);
}

void FlutterWindow::SetAppIcon(const std::vector<uint8_t>* png) {
  HINSTANCE instance = ::GetModuleHandle(nullptr);
  auto make = [&](int size) -> HICON {
    if (png == nullptr || png->empty()) {
      return static_cast<HICON>(::LoadImage(instance, MAKEINTRESOURCE(IDI_APP_ICON),
                                            IMAGE_ICON, size, size, 0));
    }
    // PNG data is an icon image as Vista and later read them.
    return ::CreateIconFromResourceEx(const_cast<PBYTE>(png->data()),
                                      static_cast<DWORD>(png->size()), TRUE,
                                      0x00030000, size, size, LR_DEFAULTCOLOR);
  };
  HICON big = make(::GetSystemMetrics(SM_CXICON));
  HICON little = make(::GetSystemMetrics(SM_CXSMICON));
  if (big == nullptr || little == nullptr) {
    if (big) ::DestroyIcon(big);
    if (little) ::DestroyIcon(little);
    return;
  }
  HWND window = GetHandle();
  ::SendMessage(window, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(big));
  ::SendMessage(window, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(little));
  if (big_icon_) ::DestroyIcon(big_icon_);
  if (small_icon_) ::DestroyIcon(small_icon_);
  big_icon_ = big;
  small_icon_ = little;
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "curated_score/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (call.method_name() == "setAppIcon" && args != nullptr) {
          auto png = args->find(flutter::EncodableValue("png"));
          SetAppIcon(png == args->end()
                         ? nullptr
                         : std::get_if<std::vector<uint8_t>>(&png->second));
          result->Success();
          return;
        }
        if (call.method_name() != "setDocument" || args == nullptr) {
          result->NotImplemented();
          return;
        }
        auto title = args->find(flutter::EncodableValue("title"));
        if (title != args->end()) {
          if (const auto* text = std::get_if<std::string>(&title->second)) {
            ::SetWindowTextW(GetHandle(), Utf16FromUtf8(*text).c_str());
          }
        }
        result->Success();
      });

  // The Font dialog, starting at the font in use: answers the family chosen, or null.
  font_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "curated_score/fonts",
          &flutter::StandardMethodCodec::GetInstance());
  font_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "pickFont") {
          result->NotImplemented();
          return;
        }
        LOGFONTW font = {};
        font.lfCharSet = DEFAULT_CHARSET;
        DWORD flags = CF_SCREENFONTS | CF_NOSIZESEL | CF_NOSTYLESEL |
                      CF_NOSCRIPTSEL | CF_NOVERTFONTS;
        if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
          auto family = args->find(flutter::EncodableValue("family"));
          if (family != args->end()) {
            if (const auto* text = std::get_if<std::string>(&family->second)) {
              std::wstring name = Utf16FromUtf8(*text);
              if (!name.empty() && name.size() < LF_FACESIZE) {
                wcsncpy_s(font.lfFaceName, name.c_str(), _TRUNCATE);
                flags |= CF_INITTOLOGFONTSTRUCT;
              }
            }
          }
        }
        CHOOSEFONTW dialog = {};
        dialog.lStructSize = sizeof(dialog);
        dialog.hwndOwner = GetHandle();
        dialog.lpLogFont = &font;
        dialog.Flags = flags;
        if (::ChooseFontW(&dialog) && font.lfFaceName[0] != L'\0') {
          result->Success(flutter::EncodableValue(Utf8FromUtf16(font.lfFaceName)));
        } else {
          result->Success();
        }
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_GETMINMAXINFO: {
      HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = static_cast<LONG>(kMinimumWidth * scale);
      info->ptMinTrackSize.y = static_cast<LONG>(kMinimumHeight * scale);
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
