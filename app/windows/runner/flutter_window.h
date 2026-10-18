#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <vector>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The window's icon (title bar, taskbar, Alt-Tab): |png|'s image, or the exe's icon when null.
  void SetAppIcon(const std::vector<uint8_t>* png);

  // The icons SetAppIcon made, destroyed when replaced.
  HICON big_icon_ = nullptr;
  HICON small_icon_ = nullptr;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Sets the window title and icon from Dart (window_chrome.dart).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;

  // The system's Font dialog, for a music font that isn't embedded (font_settings.dart).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> font_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
