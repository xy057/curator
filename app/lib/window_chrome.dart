import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_logo.dart';

/// The native window's title: the open document, and whether it has unsaved changes.
///
/// macOS shows the name with the edited dot in the close button and a proxy icon for the
/// saved file; Windows and Linux show "• name — Curator". The runners implement the
/// `curated_score/window` channel; without it (tests) this does nothing.
abstract final class WindowChrome {
  static const _channel = MethodChannel('curated_score/window');
  static const appName = 'Curator';

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

  static var _mascotShown = false;

  /// The running app's icon in the Dock (macOS) or on the window and taskbar (Windows, Linux):
  /// the mascot's tile, or with [mascot] off the bundled icon again. The bundle's own icon
  /// (Finder, the Start menu) stays as it is.
  static Future<void> showAppIcon({required bool mascot}) async {
    if (mascot == _mascotShown) return;
    _mascotShown = mascot;
    try {
      final asset = defaultTargetPlatform == TargetPlatform.macOS ? AppLogo.mascotDock : AppLogo.mascot;
      final png = mascot ? (await rootBundle.load(asset)).buffer.asUint8List() : null;
      await _channel.invokeMethod<void>('setAppIcon', {'png': png});
    } on MissingPluginException {
      // no native window (tests), or a runner without it
    } on PlatformException {
      // the same
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

  /// Windows and Linux: the window goes back to [frame] before it first shows (the runners
  /// show it on Flutter's first frame). macOS restores its own (MainFlutterWindow.swift).
  static Future<void> restoreFrame(WindowFrame? frame) async {
    if (frame == null || !_framesHere) return;
    try {
      await _channel.invokeMethod<void>('setFrame', frame.toMap());
    } on MissingPluginException {
      // no native window (tests), or a runner without it
    } on PlatformException {
      // the same
    }
  }

  /// The window's frame now, for [restoreFrame] next time. While maximised Linux only says so:
  /// the size it had before is kept from [previous].
  static Future<WindowFrame?> currentFrame({WindowFrame? previous}) async {
    if (!_framesHere) return null;
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('getFrame');
      return map == null ? null : WindowFrame.fromMap(map, previous: previous);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static bool get _framesHere =>
      defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux;

  /// The title text for [platform]: macOS marks edits with the close button's dot instead.
  static String titleFor({String? name, required bool edited, required TargetPlatform platform}) {
    if (name == null) return appName;
    if (platform == TargetPlatform.macOS) return name;
    return '${edited ? '• ' : ''}$name — $appName';
  }
}

/// Where the window was and how big, in the runner's own units (Windows: physical pixels of
/// its normal, unmaximised placement; Linux: GTK's logical pixels), and whether maximised.
@immutable
class WindowFrame {
  const WindowFrame(this.x, this.y, this.width, this.height, {this.maximized = false});

  final int x, y, width, height;
  final bool maximized;

  /// `x,y,width,height` and `,max` when maximised.
  String encode() => '$x,$y,$width,$height${maximized ? ',max' : ''}';

  static WindowFrame? parse(String? text) {
    final parts = text?.split(',') ?? const <String>[];
    if (parts.length < 4) return null;
    final n = [for (final p in parts.take(4)) int.tryParse(p)];
    if (n.contains(null) || n[2]! <= 0 || n[3]! <= 0) return null;
    return WindowFrame(n[0]!, n[1]!, n[2]!, n[3]!, maximized: parts.length > 4 && parts[4] == 'max');
  }

  Map<String, Object> toMap() => {'x': x, 'y': y, 'width': width, 'height': height, 'maximized': maximized};

  /// A runner's answer; the numbers it leaves out are [previous]'s.
  static WindowFrame? fromMap(Map<String, Object?> map, {WindowFrame? previous}) {
    int? n(String key) => switch (map[key]) { final num v => v.round(), _ => null };
    final width = n('width') ?? previous?.width, height = n('height') ?? previous?.height;
    if (width == null || height == null || width <= 0 || height <= 0) return null;
    return WindowFrame(n('x') ?? previous?.x ?? 0, n('y') ?? previous?.y ?? 0, width, height,
        maximized: map['maximized'] == true);
  }

  @override
  bool operator ==(Object other) =>
      other is WindowFrame &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.maximized == maximized;

  @override
  int get hashCode => Object.hash(x, y, width, height, maximized);

  @override
  String toString() => 'WindowFrame(${encode()})';
}
