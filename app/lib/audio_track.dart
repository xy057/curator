import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
// The binding its readSamplesFromFile wraps: that keeps the buffer it reads into (never freed),
// fine for a waveform's few samples, not for a recording read whole (Align).
// ignore: implementation_imports
import 'package:flutter_soloud/src/bindings/flutter_soloud_ffigen.dart' as soloud;
import 'package:score_engine/score_engine.dart';

import 'audio_format.dart';
import 'file_names.dart';
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
  AudioTrack._(this.path, this.name, this.source, this.length, this.waveform, this._samples, this._sampleRate, this._scratch,
      {required this.decodedBytes});

  /// A silent track (no playback) for tests and previews.
  @visibleForTesting
  AudioTrack.forTesting({required this.name, required this.length, required this.waveform})
      : path = name,
        source = null,
        _samples = name,
        _sampleRate = null,
        _scratch = null,
        decodedBytes = 0;

  /// Files converted for it; deleted with it.
  final Directory? _scratch;

  /// What it holds in memory, decoded (0: read from disk as it plays).
  final int decodedBytes;

  /// Lets go of its sound and its converted files.
  Future<void> _dispose() async {
    if (source case final source?) await SoLoud.instance.disposeSource(source);
    ScratchSpace.release(_scratch);
  }

  /// The recording's audio file: what a project embeds (a video's extracted soundtrack).
  final String path;
  final String name;
  final AudioSource? source;
  final double length; // seconds
  final Waveform waveform;

  /// The file SoLoud reads (FLAC where [path] is a format it can't), and its sample rate when
  /// its header says.
  final String _samples;
  final int? _sampleRate;

  /// The recording heard as Align hears it ([AudioChroma]'s frames), read on an isolate half a
  /// minute at a time, so it is never held whole; [progress] hears how far it has got (0–1).
  /// Null when there is no sound to read, or its sample rate isn't known.
  Future<({Float32List frames, double frameRate})?> chroma({void Function(double done)? progress}) async {
    final rate = _sampleRate;
    if (source == null || rate == null) return null;
    final port = ReceivePort();
    final heard = port.listen((done) => progress?.call(done as double));
    try {
      return await _readChroma(_samples, rate, length, port.sendPort);
    } finally {
      await heard.cancel();
      port.close();
    }
  }

  /// On an isolate, from a static function: a closure made beside one that uses the track
  /// would take it along.
  static Future<({Float32List frames, double frameRate})> _readChroma(String path, int rate, double length, SendPort progress) =>
      Isolate.run(() {
        const block = 30; // seconds
        // As miniaudio works out a time's frame: in single precision.
        int frameAt(double seconds) => (Float32List.fromList([Float32List.fromList([seconds])[0] * rate])[0]).floor();
        final chroma = AudioChroma(rate.toDouble());
        final parts = <Float32List>[];
        final capacity = block * rate + 64;
        final buffer = malloc<Float>(capacity), name = path.toNativeUtf8();
        try {
          for (var start = 0; start < length; start += block) {
            final last = start + block >= length;
            final from = frameAt(start.toDouble());
            final count = math.min(capacity, (last ? (length * rate).round() : frameAt(start + block.toDouble())) - from);
            if (count <= 0) break;
            final samples = buffer.asTypedList(count)..fillRange(0, count, 0);
            final error = soloud.readSamplesFromFile(name.cast(), start.toDouble(), last ? -1 : start + block.toDouble(), count, false, buffer);
            if (error != soloud.ReadSamplesErrors.readSamplesNoError) {
              throw SoLoudCppException.fromReadSampleError(ReadSamplesErrors.fromValue(error.value));
            }
            parts.add(chroma.add(Float32List.fromList(samples)));
            progress.send(math.min(1.0, (start + block) / length));
          }
          parts.add(chroma.finish());
        } finally {
          malloc
            ..free(buffer)
            ..free(name);
        }
        final frames = Float32List(parts.fold(0, (sum, p) => sum + p.length));
        var at = 0;
        for (final p in parts) {
          frames.setAll(at, p);
          at += p.length;
        }
        return (frames: frames, frameRate: chroma.frameRate);
      });
}

/// Playback through SoLoud (native, cross-platform). The engine's own position is the master
/// clock, so the score stays locked to what is heard.
///
/// It holds every recording of the score at once (its takes, by id), so another can be
/// heard at once ([hear]), fading across while playing.
class AudioEngine {
  static Future<void>? _initializing;
  SoundHandle? _handle;
  final _tracks = <String, AudioTrack>{};
  String? _heard;
  AudioTrack? _debugTrack;
  double _speed = 1;

  /// The recording heard.
  AudioTrack? get track => _debugTrack ?? _tracks[_heard];

  /// The recording of take [id]; null when it has none.
  AudioTrack? trackOf(String id) => _tracks[id];

  @visibleForTesting
  set debugTrack(AudioTrack? track) => _debugTrack = track;

  static Future<void> _ensureInitialized() =>
      _initializing ??= SoLoud.instance.isInitialized ? Future.value() : SoLoud.instance.init();

  /// What the recordings held may take in memory, decoded, together; past it a recording is
  /// read from disk as it plays (a 70-minute symphony decoded is about 1.5 GB).
  static const memoryBudget = 2 << 30;

  /// Reads a recording: audio, or a video whose soundtrack becomes the track. Anything SoLoud
  /// can't read is converted to FLAC first, into a scratch folder that goes with the track.
  /// Nothing changes until it is [put] in.
  Future<AudioTrack> read(String path) async {
    final scratch = ScratchSpace.folder('recording');
    AudioSource? source;
    try {
      final audio = MediaFormats.isVideo(path) ? await MediaConverter.toFlac(path, scratch.path) : path;
      final playable = MediaFormats.isPlayable(audio) ? audio : await MediaConverter.toFlac(audio, scratch.path);
      await _ensureInitialized();
      source = await SoLoud.instance.loadFile(playable, mode: LoadMode.disk);
      final length = SoLoud.instance.getLength(source).inMicroseconds / 1e6;
      // A whole number of frames between samples, or the waveform drifts from the audio.
      final rate = AudioFormat.sampleRateOf(playable);
      // Decoded in memory while the others leave room (two channels of floats a frame).
      final decoded = (length * (rate ?? 48000) * 2 * 4).ceil();
      final held = _tracks.values.fold(0, (sum, t) => sum + t.decodedBytes);
      final inMemory = held + decoded <= memoryBudget;
      if (inMemory) {
        await SoLoud.instance.disposeSource(source);
        source = null;
        source = await SoLoud.instance.loadFile(playable);
      }
      final plan = AudioFormat.samplingPlan(length, rate);
      final samples = await SoLoud.instance.readSamplesFromFile(playable, plan.count);
      final waveform = await Waveform.analyze(samples, plan.rate);
      return AudioTrack._(audio, fileNameOf(audio), source, length, waveform, playable, rate, scratch,
          decodedBytes: inMemory ? decoded : 0);
    } catch (_) {
      if (source != null) await SoLoud.instance.disposeSource(source);
      ScratchSpace.release(scratch);
      rethrow;
    }
  }

  /// Makes [track] take [id]'s recording, letting go of the one it had. Heard while [id] is.
  Future<void> put(String id, AudioTrack track) async {
    if (id == _heard) stop();
    final before = _tracks[id];
    _tracks[id] = track;
    if (before != null && before != track) await before._dispose();
  }

  /// Lets go of take [id]'s recording (it is no longer heard).
  Future<void> remove(String id) async {
    if (id == _heard) {
      stop();
      _heard = null;
    }
    await _tracks.remove(id)?._dispose();
  }

  /// Lets go of every recording.
  Future<void> unload() async {
    stop();
    _heard = null;
    final all = [..._tracks.values];
    _tracks.clear();
    for (final t in all) {
      await t._dispose();
    }
  }

  /// How long a switch fades from one recording to the other while playing.
  static const crossfade = Duration(milliseconds: 300);

  /// Hears take [id] from now on. Playing, it goes on from [fromSeconds] in its recording, faded
  /// in over [crossfade] as the one heard before fades out.
  void hear(String? id, {double? fromSeconds}) {
    if (id == _heard) return;
    final before = _valid ? _handle : null;
    _handle = null;
    _heard = id;
    if (before == null) return;
    if (fromSeconds != null) play(fromSeconds, volume: 0);
    if (_valid) SoLoud.instance.fadeVolume(_handle!, 1, crossfade);
    SoLoud.instance
      ..fadeVolume(before, 0, crossfade)
      ..scheduleStop(before, crossfade);
  }

  bool get _valid => _handle != null && SoLoud.instance.getIsValidVoiceHandle(_handle!);

  /// Plays from [fromSeconds]. Past the end of the recording nothing sounds, and whatever
  /// was playing stops (the clock then runs on alone, through the score's last bars).
  void play(double fromSeconds, {double volume = 1}) {
    stop();
    final track = this.track;
    final source = track?.source;
    if (track == null || source == null || fromSeconds >= track.length) return;
    final handle = SoLoud.instance.play(source, volume: volume, paused: true);
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

  // MARK: Metronome

  /// The metronome's two clicks (a bar's first beat, the others), made once, on first use.
  Future<({AudioSource accent, AudioSource beat})>? _clicks;

  /// Stands in for the sound in tests: called with each click instead.
  @visibleForTesting
  void Function({required bool accent})? debugClick;

  /// Loads the clicks ahead of the first beat, so it isn't late.
  void prepareClicks() {
    if (debugClick != null) return;
    _clicks ??= () async {
      await _ensureInitialized();
      return (
        accent: await SoLoud.instance.loadMem('click-accent.wav', clickWav(1760)),
        beat: await SoLoud.instance.loadMem('click-beat.wav', clickWav(1320)),
      );
    }();
    _clicks!.ignore();
  }

  /// One click now, at full speed whatever the playback's; none while the clicks are loading.
  void click({required bool accent}) {
    if (debugClick case final debug?) return debug(accent: accent);
    prepareClicks();
    unawaited(_clicks!.then((clicks) {
      SoLoud.instance.play(accent ? clicks.accent : clicks.beat, volume: 0.6);
    }, onError: (_) {}));
  }

  /// A 16-bit mono WAV: a sine at [hertz] struck and dying away over 40 ms.
  @visibleForTesting
  static Uint8List clickWav(double hertz) {
    const rate = 44100, length = rate * 40 ~/ 1000;
    final data = ByteData(44 + length * 2);
    void text(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    text(0, 'RIFF');
    data.setUint32(4, 36 + length * 2, Endian.little);
    text(8, 'WAVE');
    text(12, 'fmt ');
    data
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little) // PCM
      ..setUint16(22, 1, Endian.little) // mono
      ..setUint32(24, rate, Endian.little)
      ..setUint32(28, rate * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little);
    text(36, 'data');
    data.setUint32(40, length * 2, Endian.little);
    for (var i = 0; i < length; i++) {
      final t = i / rate;
      final attack = math.min(1.0, t / 0.001);
      final v = math.sin(2 * math.pi * hertz * t) * attack * math.exp(-t / 0.008);
      data.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
    }
    return data.buffer.asUint8List();
  }
}
