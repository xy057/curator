part of '../editor_controller.dart';

/// The playback clock and the transport.
///
/// While a recording plays, the audio engine's position is the master clock; everything
/// downstream only asks "what does the frame look like at time t".
class Playback {
  Playback._(this._editor, TickerProvider vsync) {
    _ticker = vsync.createTicker(_onTick)..start();
  }

  final EditorController _editor;

  /// Runs while playing, or for one frame after something needs repainting; idle otherwise,
  /// so an open project that isn't playing costs no frames.
  late final Ticker _ticker;

  /// The clock (the ticker's own time restarts whenever it wakes).
  final _clock = Stopwatch()..start();
  Duration get _now => _clock.elapsed;

  /// Playback position in seconds; the score view repaints whenever it or a fade changes.
  final time = ValueNotifier<double>(0);
  final repaint = RepaintSignal();

  bool _playing = false;
  bool get isPlaying => _playing;
  Duration _playAnchor = Duration.zero;
  double _timeAnchor = 0;

  AudioEngine get _audio => _editor.audio;

  /// Whole recording, or the whole piece (after any repeats; the score then comes to rest
  /// and fades out: [CuratedScene.endOf]), whichever is longer.
  double get duration {
    if (_editor.score == null) return 0;
    return math.max(CuratedScene.endOf(_editor.timeline), _editor.track?.length ?? 0);
  }

  /// Playback speed (0.5 = half speed, lower pitch): handy for tapping fast passages.
  double get speed => _audio.speed;
  set speed(double value) {
    _audio.speed = value;
    _timeAnchor = time.value;
    _playAnchor = _now;
    _editor._changed();
  }

  void play() {
    if (_editor.score == null) return;
    if (time.value >= duration) seek(0);
    _playing = true;
    _wake();
    _playAnchor = _now;
    _timeAnchor = time.value;
    _audio.play(time.value);
    _editor._changed();
  }

  void pause() {
    _playing = false;
    _audio.stop();
    _editor._changed();
  }

  void togglePlay() => _playing ? pause() : play();

  void seek(double seconds) {
    time.value = seconds.clamp(0, math.max(0, duration));
    _playAnchor = _now;
    _timeAnchor = time.value;
    if (_playing) _audio.play(time.value);
    _markDirty();
  }

  void skip(double seconds) => seek(time.value + seconds);

  // MARK: Frame loop

  bool _dirty = true;

  /// Something on screen changed: paint one more frame.
  void _markDirty() {
    _dirty = true;
    _wake();
  }

  void _wake() {
    if (!_ticker.isActive) _ticker.start();
  }

  void _onTick(Duration _) {
    final elapsed = _now;
    if (_playing) {
      var t = _timeAnchor + (elapsed - _playAnchor).inMicroseconds / 1e6 * _audio.speed;
      // Follow the audio engine's clock: jump if far off, otherwise glide towards it.
      final heard = _audio.position;
      if (heard != null) {
        final error = heard - t;
        if (error.abs() > 0.06) {
          _timeAnchor = heard;
          _playAnchor = elapsed;
          t = heard;
        } else {
          _timeAnchor += error * 0.05;
        }
      }
      if (t >= duration) {
        time.value = duration;
        pause();
      } else {
        time.value = t;
      }
      _editor.viewport.follow(time.value);
      _dirty = true;
    }
    if (_dirty) {
      _dirty = false;
      repaint.ping();
    }
    if (!_playing) _ticker.stop();
  }

  void _dispose() {
    _ticker.dispose();
    time.dispose();
    repaint.dispose();
  }
}

class RepaintSignal extends ChangeNotifier {
  void ping() => notifyListeners();
}
