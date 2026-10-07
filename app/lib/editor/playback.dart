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
    _ranFrom(time.value);
    if (!_scrubbing) _audio.play(time.value);
    _editor._changed();
  }

  void pause() {
    _playing = false;
    _audio.stop();
    _editor._changed();
  }

  void togglePlay() => _playing ? pause() : play();

  // MARK: Metronome

  /// Clicks every beat while playing (C, or the toolbar), the bar's first louder: an aid for
  /// aligning the tempo. Neither saved nor an edit.
  bool get metronome => _metronome;
  bool _metronome = false;
  set metronome(bool on) {
    if (on == _metronome) return;
    _metronome = on;
    _ranFrom(time.value);
    if (on) _audio.prepareClicks();
    _editor._changed();
  }

  /// The beat last clicked (or reached without a click), and the pass it was in.
  ({int pass, double beat})? _clicked;

  /// Where the clock was at the last frame, or ran on from (a play, a seek): a beat begun
  /// since was crossed, and clicks, even in a late frame; one begun before was sought into.
  double _clickedTo = 0;

  void _ranFrom(double t) {
    _clicked = null;
    _clickedTo = t;
  }

  void _clickAt(double t) {
    if (_editor.score == null) return;
    // The clock corrected back towards the audio's: what it crosses again has clicked.
    if (t < _clickedTo) return;
    final from = _clickedTo;
    _clickedTo = t;
    final timeline = _editor.timeline, beats = _editor.beats;
    final q = timeline.quarterAtSeconds(t);
    if (q < -1e-9 || q >= beats.totalQuarters) {
      _clicked = null;
      return;
    }
    final now = (pass: timeline.passAt(t), beat: beats.beatAt(q).start);
    if (now == _clicked) return;
    _clicked = now;
    if (timeline.secondsAtQuarter(now.beat, pass: now.pass) < from - 1e-6) return;
    _audio.click(accent: now.beat == beats.measureStarts[beats.measureAt(now.beat)]);
  }

  void seek(double seconds) {
    time.value = seconds.clamp(0, math.max(0, duration));
    _playAnchor = _now;
    _timeAnchor = time.value;
    _ranFrom(time.value);
    if (_playing) _audio.play(time.value);
    _markDirty();
  }

  void skip(double seconds) => seek(time.value + seconds);

  bool _scrubbing = false;

  /// A drag along the timeline (the ruler, a lane): the playhead follows the pointer and,
  /// playing, the music waits for it to be let go ([endScrub]) and goes on from there: the
  /// recording starts again once, not at every move.
  void scrub(double seconds) {
    if (!_scrubbing && _playing) _audio.stop();
    _scrubbing = true;
    time.value = seconds.clamp(0, math.max(0, duration));
    _playAnchor = _now;
    _timeAnchor = time.value;
    _markDirty();
  }

  /// The drag of [scrub] is over: playing, the music goes on from where it was let go.
  void endScrub() {
    if (!_scrubbing) return;
    _scrubbing = false;
    _ranFrom(time.value);
    _playAnchor = _now;
    _timeAnchor = time.value;
    if (_playing) _audio.play(time.value);
  }

  /// Moves the playhead to [text]: a bar ("12", "12.2", as [BeatGrid.parse] reads it; where it
  /// first sounds) or a time ("1:10", "1:10.5", "1:02:03"). False when it is neither.
  bool goTo(String text) {
    final seconds = secondsOf(text);
    if (seconds == null) return false;
    seek(seconds);
    _editor.viewport.follow(time.value);
    return true;
  }

  /// When [goTo]'s [text] sounds; null when it is no bar or time.
  double? secondsOf(String text) {
    if (_editor.score == null) return null;
    if (_clockOf(text) case final seconds?) return seconds;
    final quarter = _editor.beats.parse(text);
    if (quarter == null) return null;
    final timeline = _editor.timeline;
    return timeline.timesOf(quarter).firstOrNull?.seconds ?? timeline.secondsAtQuarter(quarter);
  }

  /// "m:ss", "m:ss.f" or "h:mm:ss" in seconds.
  static double? _clockOf(String text) {
    final match = RegExp(r'^\s*(?:(\d+):)?(\d+):(\d+(?:\.\d*)?)\s*$').firstMatch(text);
    if (match == null) return null;
    final hours = match[1] == null ? 0 : int.parse(match[1]!);
    final minutes = int.parse(match[2]!), seconds = double.parse(match[3]!);
    if (seconds >= 60 || (match[1] != null && minutes >= 60)) return null;
    return hours * 3600.0 + minutes * 60 + seconds;
  }

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
    if (_playing && !_scrubbing) {
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
      if (_metronome && _playing) _clickAt(time.value);
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
