import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'basic_pitch_model.dart';

void main() {
  test('a window is heard as the release hears it', () {
    // An A (440 Hz) from sample 8000, a C (261.6 Hz) from 20000, a G (196 Hz) from 30000 to
    // 38000, over a little noise (an integer generator, so the samples are the reference's).
    var state = 12345;
    final samples = Float32List.fromList([
      for (var i = 0; i < BasicPitch.windowLength; i++)
        () {
          state = (state * 1103515245 + 12345) % 2147483648;
          var v = 0.002 * (state / 2147483648 - 0.5);
          if (i >= 8000) v += 0.25 * math.sin(2 * math.pi * 440 * i / 22050);
          if (i >= 20000) v += 0.2 * math.sin(2 * math.pi * 261.6256 * i / 22050);
          if (i >= 30000 && i < 38000) v += 0.15 * math.sin(2 * math.pi * 196.0 * i / 22050);
          return v;
        }(),
    ]);
    final heard = basicPitch.run(samples);
    expect(heard.notes.length, BasicPitch.windowFrames * BasicPitch.keys);
    // What onnxruntime 1.31 gives for basic-pitch 0.4.0's nmp.onnx on these samples.
    for (final (kind, frame, key, value) in const [
      ('note', 10, 48, 0.099076),
      ('note', 50, 48, 0.581154),
      ('note', 100, 39, 0.455335),
      ('note', 100, 48, 0.560055),
      ('note', 130, 34, 0.372847),
      ('note', 160, 34, 0.102945),
      ('onset', 31, 48, 0.683163),
      ('onset', 32, 48, 0.402466),
      ('onset', 78, 39, 0.722253),
      ('onset', 79, 39, 0.368422),
      ('onset', 117, 34, 0.600328),
      ('onset', 118, 34, 0.298878),
      ('onset', 100, 48, 0.142678),
    ]) {
      final values = kind == 'note' ? heard.notes : heard.onsets;
      expect(values[frame * BasicPitch.keys + key], closeTo(value, 5e-4), reason: '$kind, frame $frame, key $key');
    }
    expect(heard.notes.fold(0.0, (a, b) => a + b), closeTo(1650.5273, 0.5));
    expect(heard.onsets.fold(0.0, (a, b) => a + b), closeTo(1572.6978, 0.5));
  });

  group('AudioNotes', () {
    // An A (440 Hz, three harmonics) from 3 s to 5 s, then middle C from 5.5 s to 7 s.
    Float32List tones(double rate) => Float32List.fromList([
          for (var i = 0; i < (8 * rate).round(); i++)
            () {
              final t = i / rate;
              double tone(double hz) => math.sin(2 * math.pi * hz * t) + math.sin(4 * math.pi * hz * t) / 2 + math.sin(6 * math.pi * hz * t) / 3;
              return (t >= 3 && t < 5 ? 0.2 * tone(440) : 0.0) + (t >= 5.5 && t < 7 ? 0.2 * tone(261.6256) : 0.0);
            }(),
        ]);

    for (final rate in [48000.0, 22050.0]) { // resampled, and not (Align's test is at 11025 Hz)
      test('at $rate Hz, notes are heard on their keys, starting on time', () {
        final frames = heardFrames(tones(rate), rate);
        const v = AudioNotes.values, keys = BasicPitch.keys;
        int loudest(int frame, {bool onset = false}) {
          var best = 0;
          for (var k = 1; k < keys; k++) {
            if (frames[frame * v + (onset ? keys : 0) + k] > frames[frame * v + (onset ? keys : 0) + best]) best = k;
          }
          return best;
        }

        int frameAt(double seconds) => (seconds * AudioNotes.frameRate).round();
        expect(loudest(frameAt(4)), 69 - BasicPitch.lowestKey);
        expect(loudest(frameAt(6.2)), 60 - BasicPitch.lowestKey);
        // Each note's onset is strongest within a frame of when it starts.
        for (final (seconds, key) in [(3.0, 69 - BasicPitch.lowestKey), (5.5, 60 - BasicPitch.lowestKey)]) {
          var at = frameAt(seconds - 0.5);
          for (var f = at; f <= frameAt(seconds + 0.5); f++) {
            if (frames[f * v + keys + key] > frames[at * v + keys + key]) at = f;
          }
          expect(at, inInclusiveRange(frameAt(seconds) - 1, frameAt(seconds) + 1), reason: 'onset at $seconds s');
        }
        // The last number is the samples' mean square: silence before, a tone's after.
        expect(frames[frameAt(1) * v + v - 1], 0);
        expect(frames[frameAt(4) * v + v - 1], closeTo(0.04 * (1 + 1 / 4 + 1 / 9) / 2, 0.002));
      });
    }

    test('a chunk heard from only the samples about it is the chunk heard from them all', () {
      const rate = 44100.0;
      final samples = Float32List.fromList([for (var i = 0; i < 40 * rate; i++) 0.1 * math.sin(2 * math.pi * (220 + i / rate * 20) * i / rate)]);
      final range = AudioNotes.sourceRange(1, rate);
      final whole = AudioNotes.chunk(basicPitch, 1, samples, from: 0, sampleRate: rate);
      final part = AudioNotes.chunk(basicPitch, 1, Float32List.sublistView(samples, range.from, range.to), from: range.from, sampleRate: rate);
      expect(part, whole);
      expect(AudioNotes.chunks(40), 3); // 16.5 s each
    });
  });
}
