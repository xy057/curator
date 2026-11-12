import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'basic_pitch_model.dart';
import 'demo_score.dart';

void main() {
  test('a recording of the demo, its first eight bars repeated and quickening throughout, aligns to every bar', () {
    final starts = [for (var i = 0; i <= 44; i++) i * 3.0];
    final notes = soundingNotes(demoScore(), starts).toList();
    const passes = [ScorePass(0, 24), ScorePass(0, 132)];

    // Played: 1.5 s of silence, then 70 quarters a minute quickening to 110 by the end.
    const rate = 11025, played = 156.0;
    double secondsAt(double p) {
      const a = 70 / 60, k = (110 / 60 - a) / played;
      return 1.5 + math.log((a + k * p) / a) / k;
    }

    // Each note a tone of three harmonics, struck and settling to a sustain (a tie holds it).
    final samples = Float32List(((secondsAt(played) + 1) * rate).ceil());
    var offset = 0.0;
    for (final pass in passes) {
      final struck = <(String, int), double>{};
      for (final n in notes.where((n) => n.start >= pass.start && n.start < pass.end)) {
        final origin = n.tied ? struck[(n.partId, n.midi)] ?? n.start : n.start;
        struck[(n.partId, n.midi)] = origin;
        final hz = 440 * math.pow(2, (n.midi - 69) / 12), from = secondsAt(offset + origin), end = secondsAt(offset + n.end);
        for (var i = (secondsAt(offset + n.start) * rate).round(); i < math.min(samples.length, (end + 0.1) * rate); i++) {
          final t = i / rate;
          final level = (0.4 + 0.6 * math.exp(-2 * (t - from))) * (t > end ? math.exp(-30 * (t - end)) : 1);
          samples[i] += 0.02 * level * (math.sin(2 * math.pi * hz * t) + math.sin(4 * math.pi * hz * t) / 2 + math.sin(6 * math.pi * hz * t) / 3);
        }
      }
      offset += pass.end - pass.start;
    }

    final anchors = AudioAlignment.anchors(
      audio: heardFrames(samples, rate.toDouble()),
      notes: notes,
      measureStarts: starts,
      passes: passes,
    );

    expect([for (final a in anchors) if (a.isWarp) (a.quarter, a.jumpTo)], [(24.0, 0.0)]);
    final sync = SyncMap(measureStarts: starts, defaultTempo: 100)..load(anchors);
    for (final (k, (from, to, at)) in [(0.0, 24.0, 0.0), (0.0, 132.0, 24.0)].indexed) {
      for (final q in starts.where((q) => q >= from && q <= to)) {
        expect(sync.secondsAtQuarter(q, pass: k), closeTo(secondsAt(at + q - from), 0.1), reason: 'pass ${k + 1}, bar ${q ~/ 3 + 1}');
      }
    }
  });

  test("the demo's recording aligns to the anchors set by hand, its pizzicato chord held over bars 41–43 too", () async {
    // Its FLAC as 16-bit mono WAV (afconvert is macOS's).
    final archive = ZipDecoder().decodeBytes(demoProject.readAsBytesSync());
    final temp = Directory.systemTemp.createTempSync('align-demo-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final flac = File('${temp.path}/demo.flac')..writeAsBytesSync(archive.files.firstWhere((f) => f.isFile && f.name.startsWith('media/')).content);
    final wav = '${temp.path}/demo.wav';
    expect((await Process.run('/usr/bin/afconvert', ['-f', 'WAVE', '-d', 'LEI16', '-c', '1', flac.path, wav])).exitCode, 0);
    final bytes = File(wav).readAsBytesSync(), data = ByteData.sublistView(bytes);
    var at = 12, rate = 0;
    late Float32List samples;
    while (at + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes, at, at + 4), size = data.getUint32(at + 4, Endian.little);
      if (id == 'fmt ') rate = data.getUint32(at + 12, Endian.little);
      if (id == 'data') {
        samples = Float32List.fromList([for (var i = 0; i < size ~/ 2; i++) data.getInt16(at + 8 + 2 * i, Endian.little) / 32768]);
        break;
      }
      at += 8 + size + (size & 1);
    }

    final starts = [for (var i = 0; i <= 44; i++) i * 3.0];
    final anchors = AudioAlignment.anchors(
      audio: heardFrames(samples, rate.toDouble()),
      notes: soundingNotes(demoScore(), starts).toList(),
      measureStarts: starts,
      passes: const [ScorePass(0, 132)],
    );
    final project = jsonDecode(utf8.decode(archive.files.firstWhere((f) => f.name == 'project.json').content)) as Map<String, dynamic>;
    final byHand = SyncMap(measureStarts: starts, defaultTempo: 100)
      ..load([
        for (final a in (project['state']['sync']['anchors'] as List).cast<Map<String, dynamic>>())
          SyncAnchor((a['quarter'] as num).toDouble(), (a['seconds'] as num).toDouble()),
      ]);
    final heard = SyncMap(measureStarts: starts, defaultTempo: 100)..load(anchors);
    // Every bar but the final barline (where a held chord is heard to end is a matter of taste).
    final errors = [for (final q in starts.take(44)) (heard.secondsAtQuarter(q) - byHand.secondsAtQuarter(q)).abs()];
    for (final (bar, error) in errors.indexed) {
      expect(error, lessThan(0.2), reason: 'bar ${bar + 1}');
    }
    expect((errors.toList()..sort())[errors.length ~/ 2], lessThan(0.05), reason: 'the median');
  }, skip: !Platform.isMacOS);
}
