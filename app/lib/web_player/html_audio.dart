import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'page_audio.dart';

/// A recording played by the browser's `<audio>`, its pitch kept at any speed. The element says
/// where it is only every so often; between, the clock runs on from where it last said.
class HtmlAudio implements PageAudio {
  HtmlAudio(String url)
      : _element = web.HTMLAudioElement()
          ..src = url
          ..preload = 'auto'
          ..preservesPitch = true;

  final web.HTMLAudioElement _element;
  final _clock = Stopwatch()..start();
  double _at = 0, _since = 0, _reported = -1;

  double get _now => _clock.elapsedMicroseconds / 1e6;

  void _anchor(double at) {
    _at = at;
    _since = _now;
    _reported = at;
  }

  @override
  double get position {
    final reported = _element.currentTime;
    if (_element.paused) return reported;
    final guess = _at + (_now - _since) * _element.playbackRate;
    // A new report far from where the clock has got: the clock follows it.
    if (reported != _reported) {
      _reported = reported;
      if ((reported - guess).abs() > 0.05) {
        _anchor(reported);
        return reported;
      }
    }
    return guess;
  }

  @override
  bool get playing => !_element.paused && !_element.ended;

  @override
  Future<void> play() async {
    _anchor(_element.currentTime);
    await _element.play().toDart;
    _anchor(_element.currentTime);
  }

  @override
  void pause() => _element.pause();

  @override
  void seek(double seconds) {
    _element.currentTime = seconds;
    _anchor(seconds);
  }

  @override
  set speed(double value) {
    _anchor(position);
    _element.playbackRate = value;
  }

  @override
  void dispose() {
    _element
      ..pause()
      ..removeAttribute('src')
      ..load();
  }
}
