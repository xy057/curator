import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The native window's title: the open document, and whether it has unsaved changes.
///
/// macOS shows the name with the edited dot in the close button and a proxy icon for the
/// saved file; Windows and Linux show "• name — Curated Score". The runners implement the
/// `curated_score/window` channel; without it (tests) this does nothing.
abstract final class WindowChrome {
  static const _channel = MethodChannel('curated_score/window');
  static const appName = 'Curated Score';

  /// The smallest window the editor's panels fit in. The runners set it natively (so it holds
  /// before Flutter starts): macos/Runner/MainFlutterWindow.swift,
  /// windows/runner/flutter_window.cpp and linux/runner/my_application.cc; a test keeps them
  /// in step with this.
  static const minimumSize = Size(960, 620);

  static ({String? name, bool edited, String? path})? _shown;

  static Future<void> showDocument({String? name, bool edited = false, String? path}) async {
    final next = (name: name, edited: edited, path: path);
    if (next == _shown) return;
    _shown = next;
    try {
      await _channel.invokeMethod<void>('setDocument', {
        'title': titleFor(name: name, edited: edited, platform: defaultTargetPlatform),
        'edited': edited,
        'path': path,
      });
    } on MissingPluginException {
      // no native window (tests)
    } on PlatformException {
      // an older runner: the title just stays as it was
    }
  }

  /// Calls [onOpen] with files the system asks the app to open (macOS: double-clicking a
  /// project in the Finder, Open With, dropping on the Dock icon), including the one that
  /// launched it. Elsewhere (and in tests) there are none.
  static Future<void> listenForOpenedFiles(void Function(List<String> paths) onOpen) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openFiles') onOpen([...(call.arguments as List).cast<String>()]);
    });
    try {
      final pending = await _channel.invokeListMethod<String>('takePendingFiles');
      if (pending != null && pending.isNotEmpty) onOpen(pending);
    } on MissingPluginException {
      // no native window (tests), or a runner without it
    } on PlatformException {
      // the same
    }
  }

  /// The title text for [platform]: macOS marks edits with the close button's dot instead.
  static String titleFor({String? name, required bool edited, required TargetPlatform platform}) {
    if (name == null) return appName;
    if (platform == TargetPlatform.macOS) return name;
    return '${edited ? '• ' : ''}$name — $appName';
  }
}
