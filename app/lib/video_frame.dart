import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// A video's shape, width : height: one of the [presets], or any the user types between
/// [min] and [max] (1:4 to 4:1).
@immutable
class VideoRatio {
  const VideoRatio(this.width, this.height);
  final double width, height;

  static const widescreen = VideoRatio(16, 9);
  static const presets = [widescreen, VideoRatio(21, 9), VideoRatio(4, 3), VideoRatio(1, 1), VideoRatio(9, 16)];
  static const min = 1 / 4, max = 4.0;

  double get value => width / height;

  /// "16:9", "2.39:1".
  String get label => '${_number(width)}:${_number(height)}';

  static String _number(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

  /// Reads "16:9", "16/9", "1920x1080" or "1920 × 1080" (both reduced to 16:9), or one
  /// number ("2.39", read as 2.39:1). Null if it isn't a ratio within [min]…[max].
  static VideoRatio? parse(String text) {
    final parts = text.trim().split(RegExp(r'\s*[:/x×X]\s*'));
    if (parts.length > 2) return null;
    final w = double.tryParse(parts.first), h = parts.length == 2 ? double.tryParse(parts.last) : 1.0;
    if (w == null || h == null || !w.isFinite || !h.isFinite || w <= 0 || h <= 0) return null;
    if (w / h < min - 1e-9 || w / h > max + 1e-9) return null;
    // A preset's shape reads as the preset, as it's known ("21:9", not 7:3).
    for (final p in presets) {
      if ((p.value - w / h).abs() < 1e-9) return p;
    }
    if (w == w.roundToDouble() && h == h.roundToDouble()) {
      final d = _gcd(w.round(), h.round());
      return VideoRatio(w / d, h / d);
    }
    return VideoRatio(w, h);
  }

  static int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

  @override
  bool operator ==(Object other) => other is VideoRatio && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => label;
}

/// Where a video's frame sits in a view of any size: centred, as large as fits, and laid out
/// like the video ([layout] points, [layoutShortSide] on the short side) at
/// [scale] view points a layout point. The editor's preview draws through it, so it shows what the video will.
@immutable
class VideoFrame {
  const VideoFrame._(this.rect, this.layout, this.scale);

  /// The frame starts on a whole pixel at [devicePixelRatio], so the renderer's pixel
  /// snapping (crisp staff lines) lands on the screen's pixels.
  factory VideoFrame.fit(ui.Size view, double aspectRatio, {double devicePixelRatio = 1}) {
    final layout = layoutOf(aspectRatio);
    final scale = view.isEmpty ? 0.0 : math.min(view.width / layout.width, view.height / layout.height);
    final size = layout * scale;
    double snap(double v) => (v * devicePixelRatio).floorToDouble() / devicePixelRatio;
    return VideoFrame._(
        ui.Offset(snap((view.width - size.width) / 2), snap((view.height - size.height) / 2)) & size, layout, scale);
  }

  /// The points a video is laid out in on its short side, whatever its size in pixels.
  static const layoutShortSide = 540.0;

  /// The points a video of [aspectRatio] is laid out in.
  static ui.Size layoutOf(double aspectRatio) => aspectRatio >= 1
      ? ui.Size(layoutShortSide * aspectRatio, layoutShortSide)
      : ui.Size(layoutShortSide, layoutShortSide / aspectRatio);

  /// No frame: the whole view, laid out at its own size.
  factory VideoFrame.fill(ui.Size view) => VideoFrame._(ui.Offset.zero & view, view, 1);

  /// The frame, in the view's points.
  final ui.Rect rect;
  final ui.Size layout;
  final double scale;

  /// A point in the view, in layout points.
  ui.Offset toLayout(ui.Offset p) => (p - rect.topLeft) / scale;

  /// A rectangle in layout points, in the view's.
  ui.Rect toView(ui.Rect r) => ui.Rect.fromLTWH(
      rect.left + r.left * scale, rect.top + r.top * scale, r.width * scale, r.height * scale);
}
