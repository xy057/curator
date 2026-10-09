import 'dart:io';
import 'dart:math' as math;

import 'package:curated_score/audio_track.dart';
import 'package:curated_score/project_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

void main() {
  late Waveform waveform;
  late LoadedScore score;
  late SyncMap demo; // the demo project's own sync: where each bar sounds in its recording

  setUpAll(() async {
    waveform = (await demoWaveform())!.waveform;
    final project = await ProjectFile.read(demoProject.path, mediaDirectory: Directory.systemTemp.createTempSync('demo-').path);
    score = await LoadedScore.load(ScoreFile.decodeMusicXML(project.scoreBytes));
    demo = SyncMap(measureStarts: score.timeline.measureStarts, defaultTempo: score.metadata.tempo!, beats: score.beats)
      ..load(project.state.edits.anchors, leadIn: project.state.edits.leadIn);
  });

  final noDecoder = Platform.isMacOS ? false : 'the demo recording is decoded with afconvert (macOS)';

  test('onset detection finds notes of the demo recording, and silence where it ends', () {
    final starts = score.timeline.measureStarts;
    final notes = [
      for (final (i, m) in score.engraving.measures.indexed)
        for (final o in m.onsetTimes) demo.secondsAtQuarter(starts[i] + o),
    ];
    // An orchestra with reverb: not every note is a separate attack, but what is found is real.
    final spurious = waveform.onsets.where((o) => !notes.any((t) => (t - o).abs() < 0.1)).length;
    // ignore: avoid_print
    print('onsets: ${waveform.onsets.length}, score notes: ${notes.length}, spurious: $spurious');
    expect(spurious / waveform.onsets.length, lessThan(0.15));
    expect(waveform.onsets.first, lessThan(0.05)); // the recording starts right on bar 1

    // The envelope is loud in the music and silent once the last chord has died away.
    expect(waveform.peak(0, 1), greaterThan(0.05));
    expect(waveform.peak(94, 99), lessThan(0.01));
  }, skip: noDecoder);

  test('tapping bars (with human timing error) syncs the whole recording, closing rit included', () {
    final starts = score.timeline.measureStarts;
    final sync = SyncMap(measureStarts: starts, defaultTempo: score.metadata.tempo!, beats: score.beats)..beginTapping();

    final random = math.Random(7);
    var taps = 0;
    for (var i = 0; i < starts.length; i++) {
      if (i > 6 && i % 5 == 0) continue; // skip a bar now and then: snapping must still find the right one
      final tap = demo.secondsAtQuarter(starts[i]) + (random.nextDouble() - 0.5) * 0.08; // ±40 ms
      sync.tap(waveform.nearestOnset(tap, 0.08) ?? tap); // what the app does with "snap to onsets"
      taps++;
    }

    // Every tap found its own bar, and the whole map stays with the demo's own sync.
    var worst = 0.0;
    for (final q in starts) {
      worst = math.max(worst, (sync.secondsAtQuarter(q) - demo.secondsAtQuarter(q)).abs());
    }
    double bar(int i) => sync.secondsAtQuarter(starts[i + 1]) - sync.secondsAtQuarter(starts[i]);
    // ignore: avoid_print
    print('anchors: ${sync.anchors.length}, worst bar: ${(worst * 1000).toStringAsFixed(1)} ms, '
        'first bar ${bar(1).toStringAsFixed(2)} s, last bar ${bar(starts.length - 2).toStringAsFixed(2)} s');
    expect(sync.anchors.length, taps);
    expect(sync.anchors.every((a) => starts.contains(a.quarter)), isTrue);
    expect(sync.startSeconds, closeTo(0, 0.05)); // the first tap snaps to the opening attack
    expect(worst, lessThan(0.12));
    expect(bar(starts.length - 2), greaterThan(2.5 * bar(1))); // the poco rit. into the final bar
  }, skip: noDecoder);
}
