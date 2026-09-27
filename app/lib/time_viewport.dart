import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// The horizontal view shared by the bottom panel's tabs: which seconds are on screen and how
/// zoomed in. Instrument lanes and the audio lanes stay aligned because they share this.
class TimeViewport extends ChangeNotifier {
  double _pxPerSec = 40;
  double _origin = 0; // seconds at the left edge of the lanes
  double _width = 800; // lane width in pixels
  double _duration = 1;

  double get pxPerSec => _pxPerSec;
  double get origin => _origin;
  double get width => _width;

  double x(double seconds) => (seconds - _origin) * _pxPerSec;
  double seconds(double x) => _origin + x / _pxPerSec;

  bool _fitPending = true;

  /// True while the view shows the whole piece; it then refits when the window resizes.
  bool _fitted = false;

  /// Fits the whole piece once the lanes know their width (after a score or recording loads).
  void requestFit() {
    _fitPending = true;
    notifyListeners();
  }

  /// Called by the panels on layout; does not notify (it happens during build).
  void setWidth(double width, double duration) {
    _width = math.max(100, width);
    _duration = math.max(1, duration);
    if (_fitPending || _fitted) {
      _fitPending = false;
      _fitted = true;
      _pxPerSec = (_width / _duration).clamp(4.0, 1200.0);
      _origin = 0;
    }
  }

  void fit() {
    _pxPerSec = (_width / _duration).clamp(4.0, 1200.0);
    _origin = 0;
    _fitted = true;
    notifyListeners();
  }

  /// Zooms by [factor] keeping the time under [anchorX] (pixels from the lanes' left edge) fixed.
  void zoom(double factor, [double? anchorX]) {
    final ax = anchorX ?? _width / 2;
    final anchor = seconds(ax);
    _fitted = false;
    _pxPerSec = (_pxPerSec * factor).clamp(4.0, 1200.0);
    _origin = anchor - ax / _pxPerSec;
    _clamp();
    notifyListeners();
  }

  void pan(double pixels) {
    _fitted = false;
    _origin += pixels / _pxPerSec;
    _clamp();
    notifyListeners();
  }

  /// Keeps [time] in view while playing, paging ahead like a DAW.
  void follow(double time) {
    final px = x(time);
    if (px < 0 || px > _width * 0.9) {
      _fitted = false;
      _origin = time - (_width * 0.1) / _pxPerSec;
      _clamp();
      notifyListeners();
    }
  }

  void _clamp() {
    final visible = _width / _pxPerSec;
    _origin = _origin.clamp(-visible * 0.1, math.max(0.0, _duration - visible * 0.9));
  }
}
