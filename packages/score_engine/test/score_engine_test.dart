import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_score.dart';

Future<void> loadFont(String family, String path) async {
  final bytes = await File(path).readAsBytes();
  await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
}

void main() {
  late LoadedScore score;

  setUpAll(() async {
    await loadFont('packages/score_engine/Bravura', 'assets/fonts/Bravura.otf');
    score = await LoadedScore.load(demoScore());
  });

  test('reads the part list', () {
    final parts = score.metadata.parts;
    expect(parts, hasLength(21));
    expect(parts.first.name, 'Piccolo');
    expect(parts.first.family, InstrumentFamily.woodwinds);
    expect(parts.last.name, 'Double Bass');
    expect(parts.last.family, InstrumentFamily.strings);
    expect(parts.last.staffNumbers, [21]);
    expect(score.metadata.tempo, 93);
    expect(score.metadata.barNumbers, [for (var m = 1; m <= 44; m++) '$m']);
    // Numbered as printed: no number on an upbeat or a split bar's second half.
    final measures = ['number="0" implicit="yes"', 'number="1"', 'number="2"', 'number="2" implicit="yes"', 'number="3" text="3a"', ''];
    final xml = '<score-partwise><part-list><score-part id="P1"><part-name>A</part-name></score-part></part-list>'
        '<part id="P1">${measures.map((m) => '<measure $m/>').join()}</part></score-partwise>';
    expect(ScoreMetadata.read(xml).barNumbers, [null, '1', '2', null, '3a', '4']);
  });

  test('scroll map puts every onset under the pointer as it sounds, and never runs backwards', () {
    final map = score.scrollMap;
    final measures = score.engraving.measures, starts = score.timeline.measureStarts;
    expect(map.duration, closeTo(44 * 3 * 60 / 93, 1e-6)); // 44 bars of 6/8 at ♩ = 93
    // An anchor on every onset in every staff (and the final barline), each on its notes.
    expect(map.times, hasLength(measures.fold(0, (n, m) => n + m.onsetTimes.length) + 1));
    for (var i = 0; i < measures.length; i++) {
      for (var j = 0; j < measures[i].onsetTimes.length; j++) {
        final t = score.timeline.secondsAtQuarter(starts[i] + measures[i].onsetTimes[j]);
        expect(map.xAt(t), closeTo(measures[i].onsetXs[j], 0.5), reason: 'bar ${i + 1}, onset $j');
      }
    }
    var previous = double.negativeInfinity;
    for (var t = -2.0; t < map.duration + 2; t += 0.01) {
      final x = map.xAt(t);
      expect(x, greaterThanOrEqualTo(previous - 1e-9));
      previous = x;
    }

    // After the final barline it comes to rest over the settle: by default a third as far as it
    // would go at its last speed; a linear curve keeps that speed all the way, then stops.
    final end = map.duration, v = (map.xAt(end) - map.xAt(end - 1e-3)) / 1e-3;
    expect(map.xAt(end + 10) - map.xAt(end), closeTo(v * 2.5 / 3, 0.05));
    final linear = map.withMotion(const ScoreMotion(settle: 1, settleCurve: MotionCurve.linear));
    expect(linear.xAt(end + 0.5) - linear.xAt(end), closeTo(v * 0.5, 0.05));
    expect(linear.xAt(end + 10) - linear.xAt(end), closeTo(v, 0.05));
    expect(linear.xAt(2), map.xAt(2), reason: 'only the ending moves differently');
  });

  test('finds a phrase exactly, in any key and nearly', () {
    final lines = ScoreLine.read(score.musicXML, score.timeline.measureStarts);
    final cello = lines.reduce((a, b) => a.length >= b.length ? a : b); // the cellos' running sixteenths
    expect(score.metadata.parts.firstWhere((p) => p.id == cello.partId).name, 'Violoncello');
    final notes = [for (var k = 10; k < 16; k++) PhraseNote.ofMidi(cello.pitches[k], value: NoteValue.sixteenth)];
    bool foundAt(List<PhraseMatch> matches) => matches.any((m) => identical(m.line, cello) && m.first == 10);

    final exact = PhraseSearch.find(Phrase(notes), lines);
    expect(foundAt(exact), isTrue);
    expect(exact.every((m) => m.similarity == 1), isTrue);
    for (final m in exact) {
      for (var k = 1; k < notes.length; k++) {
        expect(m.line.pitches[m.first + k] - m.line.pitches[m.first + k - 1], notes[k].midi! - notes[k - 1].midi!);
      }
    }
    // An octave up: only in any key, which says how far; as eighths, only without the rhythm.
    final higher = [for (final n in notes) PhraseNote.ofMidi(n.midi! + 12, value: NoteValue.sixteenth)];
    expect(foundAt(PhraseSearch.find(Phrase(higher), lines, anyKey: false)), isFalse);
    expect(PhraseSearch.find(Phrase(higher), lines).firstWhere((m) => identical(m.line, cello) && m.first == 10).transposition, -12);
    final eighths = [for (final n in notes) n.copyWith(value: NoteValue.eighth)];
    expect(foundAt(PhraseSearch.find(Phrase(eighths), lines)), isFalse);
    expect(foundAt(PhraseSearch.find(Phrase(eighths), lines, rhythm: false)), isTrue);
    // A note a semitone off: not exactly, but nearly.
    final wrong = [...notes]..[3] = PhraseNote.ofMidi(notes[3].midi! + 1, value: NoteValue.sixteenth);
    expect(foundAt(PhraseSearch.find(Phrase(wrong), lines)), isFalse);
    final near = PhraseSearch.find(Phrase(wrong), lines, similar: true).firstWhere((m) => identical(m.line, cello) && m.first == 10);
    expect(near.similarity, inInclusiveRange(PhraseSearch.minSimilarity, 0.99));
    // Each clef's top line: F5, F5, F4 (8vb), G4 (alto), E4 (tenor), A3 (bass); Auto by the notes.
    expect([for (final c in PhraseClef.values) c.topLine], [38, 38, 31, 32, 30, 26]);
    expect(Phrase(notes).shownClef, PhraseClef.bass);
    expect(Phrase(notes, clef: PhraseClef.tenor).musicXML(), contains('<clef><sign>C</sign><line>4</line></clef>'));
  });

  test('auto-curate hides the least salient staves where they would run off the frame, only there', () {
    final scene = CuratedScene(score);
    final ids = [for (final p in score.metadata.parts) p.id];
    final starts = score.timeline.measureStarts;
    final playing = Curation.autoCuratedLanes(ids, score.metadata.activeMeasures, starts);
    final base = Curation(ids)..setLanes(playing);
    bool shownIn(List<Region> lane, int m) => lane.any((r) => r.start <= starts[m] && r.end > starts[m]);
    List<String> shownAt(Map<String, List<Region>> lanes, int m) => [for (final id in ids) if (shownIn(lanes[id]!, m)) id];

    const wide = ui.Size(960, 540), tall = ui.Size(540, 960);
    expect(scene.overflowing(base, wide), isNotEmpty, reason: '21 staves in the tutti');
    final fitted = scene.curatedToFit(base, wide,
        partIds: ids, activeMeasures: score.metadata.activeMeasures, salience: score.salience);
    expect(scene.overflowing(Curation(ids)..setLanes(fitted), wide), isEmpty);
    for (var m = 0; m < starts.length - 1; m++) {
      final now = shownAt(fitted, m), before = shownAt(playing, m);
      expect(before, containsAll(now), reason: 'only hides (bar ${m + 1})');
      if (before.isNotEmpty) expect(now, isNotEmpty, reason: 'someone left (bar ${m + 1})');
    }
    // Upright there is room for the opening's few: none goes.
    final upright = scene.curatedToFit(base, tall,
        partIds: ids, activeMeasures: score.metadata.activeMeasures, salience: score.salience);
    for (var m = 0; m < 5; m++) {
      expect(shownAt(upright, m), shownAt(playing, m));
    }
    scene.dispose();
  });

  test('a video frame is the preview drawn offscreen, at any pixel size', () async {
    final scene = CuratedScene(score);
    final curation = Curation(score.metadata.parts.map((p) => p.id));
    for (final p in score.metadata.parts.skip(16)) {
      curation.setLane(p.id, [Region(0, score.timeline.measureStarts.last)]);
    }
    Future<ByteData> bytes(ui.Image image) async => (await image.toByteData())!;

    // The same pixels as painting the preview at that size and density.
    final frame = scene.renderFrame(1600, 900, time: 30, curation: curation, devicePixelRatio: 2);
    final recorder = ui.PictureRecorder();
    scene.paint(ui.Canvas(recorder)..scale(2), const ui.Size(800, 450),
        time: 30, curation: curation, devicePixelRatio: 2);
    final preview = recorder.endRecording().toImageSync(1600, 900);
    expect((await bytes(frame)).buffer.asUint8List(), (await bytes(preview)).buffer.asUint8List());

    // Engraved beforehand and saved (a web page's score), the same frame.
    final saved = LoadedScore.engraved(score.musicXML, score.request, EngravingFile.read(EngravingFile.write(score.engraving)));
    final savedScene = CuratedScene(saved);
    final again = savedScene.renderFrame(1600, 900, time: 30, curation: curation, devicePixelRatio: 2);
    expect((await bytes(again)).buffer.asUint8List(), (await bytes(frame)).buffer.asUint8List());
    again.dispose();
    savedScene.dispose();

    // 720p laid out like a 540-point-high preview: a fractional density, whole pixels out.
    final hd = scene.renderFrame(1280, 720, time: 30, curation: curation, devicePixelRatio: 720 / 540);
    expect((hd.width, hd.height), (1280, 720));
    final pixels = await bytes(hd);
    final colours = {for (var i = 0; i < pixels.lengthInBytes; i += 4) pixels.getUint32(i)};
    expect(colours, contains(0xFFFFFFFF), reason: 'paper');
    expect(colours, contains(0x14171AFF), reason: 'ink');
    for (final image in [frame, preview, hd]) {
      image.dispose();
    }
    scene.dispose();
  });
}
