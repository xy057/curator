import 'dart:io';
import 'dart:typed_data';

import 'package:curated_score/audio_format.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';

void main() {
  /// What SoLoud's readSamplesFromFile does: whole-frame steps of `frames ~/ count`.
  double coveredSeconds(int frames, int sampleRate, int count) => count * (frames ~/ count) / sampleRate;

  test('asking for "3000 a second" of a 44.1 kHz file drifts; the sampling plan does not', () {
    const rate = 44100, seconds = 600.0;
    const frames = 26460000;
    // The old way: 1.8 M samples, trusted to span the file, only span 95 % of it.
    final naive = (seconds * 3000).round();
    expect(seconds - coveredSeconds(frames, rate, naive), greaterThan(25));

    final plan = AudioFormat.samplingPlan(seconds, rate);
    expect(frames ~/ plan.count, rate / plan.rate); // SoLoud's step is exactly the planned one
    expect((plan.count / plan.rate - seconds).abs(), lessThan(1 / plan.rate));
    expect(plan.rate, closeTo(3000, 150));
  });

  test('the plan is exact for the usual rates, and falls back without one', () {
    for (final rate in const [8000, 22050, 32000, 44100, 48000, 88200, 96000, 192000]) {
      final plan = AudioFormat.samplingPlan(123.456, rate);
      final frames = (123.456 * rate).round();
      expect(frames ~/ plan.count * plan.rate, rate, reason: '$rate Hz');
    }
    final fallback = AudioFormat.samplingPlan(10, null);
    expect(fallback.count, 30000);
    expect(fallback.rate, 3000);
  });

  test('sample rates are read from FLAC, WAV, MP3 and Ogg headers', () async {
    expect(AudioFormat.sampleRateOf(demoRecording.path), 48000); // the demo's FLAC

    final dir = Directory.systemTemp.createTempSync('audio-format-');
    // WAV with a LIST chunk before fmt, as some editors write it.
    final wav = BytesBuilder()
      ..add('RIFF'.codeUnits)
      ..add(_u32(4 + 18 + 24))
      ..add('WAVE'.codeUnits)
      ..add('LIST'.codeUnits)
      ..add(_u32(10))
      ..add(List.filled(10, 0))
      ..add('fmt '.codeUnits)
      ..add(_u32(16))
      ..add([1, 0, 2, 0])
      ..add(_u32(44100))
      ..add(List.filled(8, 0));
    final wavFile = File('${dir.path}/a.wav')..writeAsBytesSync(wav.toBytes());
    expect(AudioFormat.sampleRateOf(wavFile.path), 44100);

    // MP3 behind an ID3v2 tag: MPEG-1 layer III, 128 kb/s, 44.1 kHz; then MPEG-2 at 22.05 kHz.
    final id3 = [...'ID3'.codeUnits, 4, 0, 0, 0, 0, 1, 0, ...List.filled(128, 0)];
    final mp3File = File('${dir.path}/a.mp3')..writeAsBytesSync([...id3, 0xff, 0xfb, 0x90, 0x64, 0, 0]);
    expect(AudioFormat.sampleRateOf(mp3File.path), 44100);
    expect(AudioFormat.fromHeader(Uint8List.fromList([0xff, 0xf3, 0x90, 0x64])), 22050);

    // Ogg Vorbis identification header.
    final ogg = Uint8List(27 + 1 + 30);
    ogg.setAll(0, 'OggS'.codeUnits);
    ogg[26] = 1;
    ogg.setAll(28, '\x01vorbis'.codeUnits);
    ByteData.sublistView(ogg).setUint32(28 + 12, 32000, Endian.little);
    expect(AudioFormat.fromHeader(ogg), 32000);

    expect(AudioFormat.fromHeader(Uint8List.fromList('not audio'.codeUnits)), isNull);
    dir.deleteSync(recursive: true);
  });
}

List<int> _u32(int v) => (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
