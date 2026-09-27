import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'audio_format.dart';
import 'media_converter.dart';
import 'scratch_space.dart';

/// Amplitude envelope and note onsets of a recording, for drawing and snapping.
class Waveform {
  Waveform._(this.rate, this.levels, this.onsets);

  /// Envelope values per second at level 0.
  final double rate;

  /// Level 0 is |sample|; each next level is the max of two from the level below, so any
  /// zoom draws from a level with about one value per pixel.
  final List<Float32List> levels;

  /// Detected note onsets, seconds.
  final List<double> onsets;

  /// Peak amplitude (0…1) between two times.
  double peak(double t0, double t1) {
    final span = (t1 - t0) * rate;
    // The coarsest level whose buckets are still at most a quarter of the range.
    var level = 0;
    while (level + 1 < levels.length && (2 << level) * 4 <= span) {
      level++;
    }
    final values = levels[level];
    final scale = rate / (1 << level);
    final a = math.max(0, (t0 * scale).floor()), b = math.min(values.length, (t1 * scale).ceil());
    var m = 0.0;
    for (var i = a; i < b; i++) {
      if (values[i] > m) m = values[i];
    }
    return m;
  }

  /// The onset nearest to [t] within [window] seconds, if any.
  double? nearestOnset(double t, double window) {
    double? best;
    for (final o in onsets) {
      if ((o - t).abs() <= window && (best == null || (o - t).abs() < (best - t).abs())) best = o;
      if (o > t + window) break;
    }
    return best;
  }

  static Future<Waveform> analyze(Float32List samples, double rate) =>
      compute(_analyze, (samples: samples, rate: rate));

  static Waveform _analyze(({Float32List samples, double rate}) input) {
    final samples = input.samples, rate = input.rate;
    final levels = <Float32List>[Float32List.fromList([for (final s in samples) s.abs()])];
    while (levels.last.length > 64) {
      final below = levels.last;
      final up = Float32List((below.length + 1) ~/ 2);
      for (var i = 0; i < up.length; i++) {
        up[i] = math.max(below[2 * i], 2 * i + 1 < below.length ? below[2 * i + 1] : 0);
      }
      levels.add(up);
    }

    // Onsets: rises in log energy over 10 ms frames, peak-picked above a local average.
    final frame = math.max(1, (rate * 0.01).round());
    final energy = <double>[];
    for (var i = 0; i + frame <= samples.length; i += frame) {
      var e = 0.0;
      for (var j = i; j < i + frame; j++) {
        e += samples[j] * samples[j];
      }
      energy.add(math.log(1e-6 + e / frame));
    }
    final flux = [for (var i = 0; i < energy.length; i++) i == 0 ? 0.0 : math.max(0.0, energy[i] - energy[i - 1])];
    final onsets = <double>[];
    const half = 25; // ±250 ms local window
    var last = -1.0;
    for (var i = 1; i + 1 < flux.length; i++) {
      if (flux[i] < flux[i - 1] || flux[i] < flux[i + 1]) continue;
      var mean = 0.0, n = 0;
      for (var j = math.max(0, i - half); j < math.min(flux.length, i + half); j++) {
        mean += flux[j];
        n++;
      }
      mean /= n;
      final t = i * frame / rate;
      if (flux[i] > mean * 2.2 + 0.4 && t - last > 0.06) {
        onsets.add(t);
        last = t;
      }
    }
    return Waveform._(rate, levels, onsets);
  }
}

/// A loaded recording. For a video, it is the soundtrack taken out of it.
class AudioTrack {
  AudioTrack._(this.path, this.name, this.source, this.length, this.waveform);

  /// A silent track (no playback) for tests and previews.
  @visibleForTesting
  AudioTrack.forTesting({required this.name, required this.length, required this.waveform})
      : path = name,
        source = null;

  /// The recording's audio file: what a project embeds (a video's extracted soundtrack).
  final String path;
  final String name;
  final AudioSource? source;
  final double length; // seconds
  final Waveform waveform;
}

/// Playback through SoLoud (native, cross-platform). The engine's own position is the master
/// clock, so the score stays locked to what is heard.
class AudioEngine {
  static Future<void>? _initializing;
  SoundHandle? _handle;
  AudioTrack? _track;
  double _speed = 1;

  /// Files converted for the current track; deleted with it.
  Directory? _scratch;

  AudioTrack? get track => _track;

  @visibleForTesting
  set debugTrack(AudioTrack? track) => _track = track;

  static Future<void> _ensureInitialized() =>
      _initializing ??= SoLoud.instance.isInitialized ? Future.value() : SoLoud.instance.init();

  /// Loads a recording: audio, or a video whose soundtrack becomes the track. Anything SoLoud
  /// can't read is converted to FLAC first, into a scratch folder that goes with the track.
  Future<AudioTrack> load(String path) async {
    await _ensureInitialized();
    await unload();
    final scratch = ScratchSpace.folder('recording');
    try {
      final audio = MediaFormats.isVideo(path) ? await MediaConverter.toFlac(path, scratch.path) : path;
      final playable = MediaFormats.isPlayable(audio) ? audio : await MediaConverter.toFlac(audio, scratch.path);
      final source = await SoLoud.instance.loadFile(playable);
      final length = SoLoud.instance.getLength(source).inMicroseconds / 1e6;
      // A whole number of frames between samples, or the waveform drifts from the audio.
      final plan = AudioFormat.samplingPlan(length, AudioFormat.sampleRateOf(playable));
      final samples = await SoLoud.instance.readSamplesFromFile(playable, plan.count);
      final waveform = await Waveform.analyze(samples, plan.rate);
      _scratch = scratch;
      return _track = AudioTrack._(audio, audio.split(RegExp(r'[/\\]')).last, source, length, waveform);
    } catch (_) {
      ScratchSpace.release(scratch);
      rethrow;
    }
  }

  Future<void> unload() async {
    stop();
    final track = _track;
    _track = null;
    final source = track?.source;
    if (source != null) await SoLoud.instance.disposeSource(source);
    ScratchSpace.release(_scratch);
    _scratch = null;
  }

  bool get _valid => _handle != null && SoLoud.instance.getIsValidVoiceHandle(_handle!);

  void play(double fromSeconds) {
    final track = _track;
    final source = track?.source;
    if (track == null || source == null || fromSeconds >= track.length) return;
    stop();
    final handle = SoLoud.instance.play(source, paused: true);
    SoLoud.instance.seek(handle, Duration(microseconds: (math.max(0.0, fromSeconds) * 1e6).round()));
    SoLoud.instance.setRelativePlaySpeed(handle, _speed);
    SoLoud.instance.setPause(handle, false);
    _handle = handle;
  }

  void stop() {
    if (_valid) SoLoud.instance.stop(_handle!);
    _handle = null;
  }

  /// Playback speed (0.5 = half speed, lower pitch): handy for tapping fast passages.
  double get speed => _speed;
  set speed(double value) {
    _speed = value;
    if (_valid) SoLoud.instance.setRelativePlaySpeed(_handle!, value);
  }

  /// Current position in the recording, or null when nothing is playing.
  double? get position => _valid ? SoLoud.instance.getPosition(_handle!).inMicroseconds / 1e6 : null;
}
