/// What a page plays its sound with, and its clock: seconds into one [WebRecording]'s file.
abstract class PageAudio {
  /// Seconds into the sound, smooth between the browser's updates.
  double get position;
  bool get playing;
  Future<void> play();
  void pause();
  void seek(double seconds);

  /// Playback speed, pitch kept.
  set speed(double value);
  void dispose();
}

/// A page without a recording: a clock alone.
class SilentAudio implements PageAudio {
  final _clock = Stopwatch();
  double _at = 0, _speed = 1;

  @override
  double get position => _at + _clock.elapsedMicroseconds / 1e6 * _speed;

  @override
  bool get playing => _clock.isRunning;

  @override
  Future<void> play() async => _clock.start();

  @override
  void pause() {
    _at = position;
    _clock
      ..stop()
      ..reset();
  }

  @override
  void seek(double seconds) {
    _at = seconds;
    _clock.reset();
  }

  @override
  set speed(double value) {
    _at = position;
    _clock.reset();
    _speed = value;
  }

  @override
  void dispose() => _clock.stop();
}
