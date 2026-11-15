import 'dart:io';
import 'dart:math' as math;
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

  test('the demo engraves: its parts, a scroll map under every onset that never runs backwards, a phrase found, a video frame', () async {
    final parts = score.metadata.parts;
    expect(parts, hasLength(21));
    expect((parts.first.name, parts.first.family), ('Piccolo', InstrumentFamily.woodwinds));
    expect((parts.last.name, parts.last.family), ('Double Bass', InstrumentFamily.strings));
    expect(parts.last.staffNumbers, [21]);
    expect(score.metadata.tempo, 93);
    expect(score.metadata.barNumbers, [for (var m = 1; m <= 44; m++) '$m']);
    // Numbered as printed: no number on an upbeat or a split bar's second half.
    final measures = ['number="0" implicit="yes"', 'number="1"', 'number="2"', 'number="2" implicit="yes"', 'number="3" text="3a"', ''];
    final xml = '<score-partwise><part-list><score-part id="P1"><part-name>A</part-name></score-part></part-list>'
        '<part id="P1">${measures.map((m) => '<measure $m/>').join()}</part></score-partwise>';
    expect(ScoreMetadata.read(xml).barNumbers, [null, '1', '2', null, '3a', '4']);

    // The scroll map: an anchor on every onset in every staff (and the final barline), each on its notes.
    final map = score.scrollMap;
    final bars = score.engraving.measures, starts = score.timeline.measureStarts;
    expect(map.duration, closeTo(44 * 3 * 60 / 93, 1e-6)); // 44 bars of 6/8 at ♩ = 93
    expect(map.times, hasLength(bars.fold(0, (n, m) => n + m.onsetTimes.length) + 1));
    for (var i = 0; i < bars.length; i++) {
      for (var j = 0; j < bars[i].onsetTimes.length; j++) {
        final t = score.timeline.secondsAtQuarter(starts[i] + bars[i].onsetTimes[j]);
        expect(map.xAt(t), closeTo(bars[i].onsetXs[j], 0.5), reason: 'bar ${i + 1}, onset $j');
      }
    }
    var previous = double.negativeInfinity;
    for (var t = -2.0; t < map.duration + 2; t += 0.01) {
      final x = map.xAt(t);
      expect(x, greaterThanOrEqualTo(previous - 1e-9));
      previous = x;
    }
    // After the final barline it comes to rest: a third as far as it would go at its last speed.
    final end = map.duration, v = (map.xAt(end) - map.xAt(end - 1e-3)) / 1e-3;
    expect(map.xAt(end + 10) - map.xAt(end), closeTo(v * 2.5 / 3, 0.05));

    // Find Phrase: the cellos' running sixteenths, exactly, an octave up in any key, nearly.
    final lines = ScoreLine.read(score.musicXML, starts);
    final cello = lines.reduce((a, b) => a.length >= b.length ? a : b);
    expect(parts.firstWhere((p) => p.id == cello.partId).name, 'Violoncello');
    final notes = [for (var k = 10; k < 16; k++) PhraseNote.ofMidi(cello.pitches[k], value: NoteValue.sixteenth)];
    bool foundAt(List<PhraseMatch> matches) => matches.any((m) => identical(m.line, cello) && m.first == 10);
    final exact = PhraseSearch.find(Phrase(notes), lines);
    expect((foundAt(exact), exact.every((m) => m.similarity == 1)), (true, true));
    final higher = [for (final n in notes) PhraseNote.ofMidi(n.midi! + 12, value: NoteValue.sixteenth)];
    expect(foundAt(PhraseSearch.find(Phrase(higher), lines, anyKey: false)), isFalse);
    expect(PhraseSearch.find(Phrase(higher), lines).firstWhere((m) => identical(m.line, cello) && m.first == 10).transposition, -12);
    final wrong = [...notes]..[3] = PhraseNote.ofMidi(notes[3].midi! + 1, value: NoteValue.sixteenth);
    expect(foundAt(PhraseSearch.find(Phrase(wrong), lines)), isFalse);
    expect(PhraseSearch.find(Phrase(wrong), lines, similar: true).firstWhere((m) => identical(m.line, cello) && m.first == 10).similarity,
        inInclusiveRange(PhraseSearch.minSimilarity, 0.99));

    // A video frame is the preview drawn offscreen: the same pixels, engraved now or saved (a web page's score).
    final scene = CuratedScene(score);
    final curation = Curation(parts.map((p) => p.id));
    for (final p in parts.skip(16)) {
      curation.setLane(p.id, [Region(0, starts.last)]);
    }
    Future<List<int>> bytes(ui.Image image) async => (await image.toByteData())!.buffer.asUint8List();
    final frame = scene.renderFrame(1600, 900, time: 30, curation: curation, devicePixelRatio: 2);
    final recorder = ui.PictureRecorder();
    scene.paint(ui.Canvas(recorder)..scale(2), const ui.Size(800, 450), time: 30, curation: curation, devicePixelRatio: 2);
    final preview = recorder.endRecording().toImageSync(1600, 900);
    expect(await bytes(frame), await bytes(preview));
    final saved = CuratedScene(LoadedScore.engraved(score.musicXML, score.request, EngravingFile.read(EngravingFile.write(score.engraving))));
    final again = saved.renderFrame(1600, 900, time: 30, curation: curation, devicePixelRatio: 2);
    expect(await bytes(again), await bytes(frame));
    // 720p laid out like a 540-point-high preview: a fractional density, whole pixels out.
    final hd = scene.renderFrame(1280, 720, time: 30, curation: curation, devicePixelRatio: 720 / 540);
    expect((hd.width, hd.height), (1280, 720));
    for (final image in [frame, preview, again, hd]) {
      image.dispose();
    }
    saved.dispose();
    scene.dispose();

    // The player map: the demo seated as an orchestra (its numbered winds one section of a
    // player each, the strings a fan, everything on the stage, no section on another), as a file
    // and back, found again in another score by name; more or fewer players seated as their
    // section's plan seats them, the rest moved out of their way; each note swells its players,
    // a long one fading slower.
    {
      void tidy(PlayerMap map, String why) {
        for (final (i, s) in map.sections.indexed) {
          for (final seat in [...s.seats.map((x) => (x.x, x.y)), (s.labelX, s.labelY)]) {
            expect(seat.$1 >= 0 && seat.$1 <= 1 && seat.$2 >= 0 && seat.$2 <= 1, isTrue, reason: '$why: ${s.name} on the stage');
          }
          for (final o in map.sections.skip(i + 1)) {
            for (final (p, q) in [for (final p in s.seats) for (final q in o.seats) (p, q)]) {
              final d = math.sqrt(math.pow((p.x - q.x) * map.aspect, 2) + math.pow(p.y - q.y, 2));
              expect(d, greaterThanOrEqualTo((s.size + o.size) / 2), reason: '$why: ${s.name} clear of ${o.name}');
            }
          }
        }
      }

      final seated = PlayerMap.smart(parts);
      final names = [for (final s in seated.sections) s.name];
      expect(names.take(5), ['Violin I', 'Violin II', 'Viola', 'Violoncello', 'Double Bass']);
      expect(names, containsAll(['Piccolo', 'Flute', 'Clarinet in B♭', 'Horn in F', 'Timpani']));
      final flutes = seated.sections.firstWhere((s) => s.name == 'Flute');
      expect(flutes.link, isNull);
      expect([for (final s in flutes.seats) s.link?.part], ['P2', 'P3']);
      for (final preset in SeatingPreset.values) {
        tidy(PlayerMap.smart(parts, preset: preset), preset.name);
      }
      expect(seated.sections.first.plan?.kind, SeatPlanKind.sector, reason: 'the first violins a fan');
      var grown = seated;
      for (final (name, count) in [('Violin I', 18), ('Flute', 6), ('Horn in F', 1)]) {
        final k = grown.sections.indexWhere((s) => s.name == name);
        grown = grown.roomFor(k, grown.sections[k].withCount(count));
        expect(grown.sections[k].seats, hasLength(count));
        expect(grown.sections[k].plan?.kind, seated.sections[k].plan?.kind, reason: '$name seated the same way');
        tidy(grown, '$name ×$count');
      }
      expect([for (final s in grown.sections.firstWhere((s) => s.name == 'Flute').seats) s.link?.part], ['P2', 'P3', null, null, null, null]);
      // Seated in rows, then as Smart Seating seated it again: the fan, its players as many.
      final fan = grown.sections.first, rows = fan.arranged(SeatShape.rows, 18);
      expect((fan.shape, rows.shape, rows.plan?.kind), (SeatShape.auto, SeatShape.rows, SeatPlanKind.rows));
      final back = rows.withCount(17).arranged(SeatShape.auto, 17);
      expect((back.shape, back.plan, back.seats.length), (SeatShape.auto, fan.auto, 17));
      final kept = grown.withSections([rows, ...grown.sections.skip(1)]).encode();
      expect(PlayerMap.decode(kept).encode(), kept, reason: 'a plan and Smart Seating’s apart');
      // A section from before plans: seen as the row it is.
      const old = MapSection(name: 'Old', color: 0xFF000000, labelX: 0.45, labelY: 0.6, seats: [MapSeat(0.4, 0.5), MapSeat(0.5, 0.5)]);
      expect(old.withCount(3).seats.map((s) => s.y).toSet(), hasLength(1));
      // Counted from names and staves; a contrabassoon is no bass.
      ScorePart part(String id, String name, [int staves = 1]) =>
          ScorePart(id: id, name: name, abbreviation: '', sound: null, staffNumbers: [for (var i = 1; i <= staves; i++) i]);
      final band = PlayerMap.smart([part('a', 'Horn in F 1-4', 2), part('b', 'Trumpets I–III'), part('c', 'Contrabassoon'), part('d', 'Violin')]);
      final seats = {for (final s in band.sections) s.name: [for (var i = 0; i < s.seats.length; i++) s.linkOf(i)?.key]};
      expect(seats['Horn in F 1-4'], ['a', 'a', 'a', 'a']);
      expect(seats['Trumpets I–III'], ['b', 'b', 'b']);
      expect(seats['Contrabassoon'], ['c']);
      expect(PlayerMap.smart([part('h', 'Horns 1.2', 2)]).sections.single.seats.map((s) => s.link?.key), ['h#1', 'h#2']);

      final text = seated.encode();
      expect(PlayerMap.decode(text).encode(), text);
      expect(() => PlayerMap.decode('{"format": "something else"}'), throwsFormatException);
      expect(() => PlayerMap.decode(text.replaceFirst('"version": 1', '"version": 2')), throwsFormatException);
      final other = [part('X9', 'Flute 2'), part('P2', 'Oboe')];
      final moved = PlayerMap.decode(text).relinked(other);
      expect([for (final s in moved.sections.firstWhere((s) => s.name == 'Flute').seats) s.link?.part], [null, 'X9'],
          reason: 'by name; P2 is an oboe there, so no flute');

      final dynamics = ScoreDynamics.read(score.musicXML, starts);
      final pulses = PlayerPulses.of(soundingNotes(score.musicXML, starts), score.timeline, seated.links, dynamics: dynamics);
      final violins = seated.sections.first.link!;
      final first = soundingNotes(score.musicXML, starts).firstWhere((n) => n.partId == violins.part);
      final on = score.timeline.secondsAtQuarter(first.start);
      expect(pulses.level(violins, on - 0.001), 0);
      expect(pulses.level(violins, on + PlayerPulses.attack), closeTo(PlayerPulses.strengthOf(dynamics.at(violins.part, first.start)), 1e-9),
          reason: 'as far as it is loud');
      expect(PlayerPulses.strengthOf(ScoreDynamics.levels['pp']!), lessThan(PlayerPulses.strengthOf(ScoreDynamics.levels['ff']!)));

      // Dynamics: a mark holds, a hairpin ramps to the mark it reaches (a step where none), an
      // accent is its moment's, fp an accent then piano; mf before anything.
      String bar(String body) => '<measure><attributes><divisions>1</divisions></attributes>$body</measure>';
      String note(int beats) => '<note><pitch><step>C</step><octave>4</octave></pitch><duration>$beats</duration></note>';
      String dyn(String mark) => '<direction><direction-type><dynamics><$mark/></dynamics></direction-type></direction>';
      String wedge(String type) => '<direction><direction-type><wedge type="$type"/></direction-type></direction>';
      final read = ScoreDynamics.read(
          '<score-partwise><part id="P1">'
          '${bar('${note(1)}${dyn('p')}${wedge('crescendo')}${note(4)}${wedge('stop')}${dyn('f')}${note(1)}')}'
          '${bar('${wedge('diminuendo')}${note(2)}${wedge('stop')}${note(1)}${dyn('sfz')}${note(1)}${note(1)}${dyn('fp')}${note(1)}')}'
          '</part></score-partwise>',
          [0, 6, 12]);
      final levels = ScoreDynamics.levels;
      expect(read.at('P1', 0), ScoreDynamics.standard);
      expect(read.at('P1', 1), levels['p']);
      expect(read.at('P1', 3), closeTo((levels['p']! + levels['f']!) / 2, 1e-9));
      expect(read.at('P1', 5), levels['f']);
      expect(read.at('P1', 7), closeTo(levels['f']! - ScoreDynamics.step / 2, 1e-9));
      expect(read.at('P1', 8), closeTo(levels['f']! - ScoreDynamics.step, 1e-9), reason: 'no mark ends it: a step softer, held');
      expect(read.at('P1', 9), ScoreDynamics.accents['sfz']!.$1);
      expect(read.at('P1', 10), closeTo(levels['f']! - ScoreDynamics.step, 1e-9));
      expect((read.at('P1', 11), read.at('P1', 11.5)), (ScoreDynamics.accents['fp']!.$1, levels['p']));
      expect(read.at('P9', 3), ScoreDynamics.standard);
      expect(PlayerPulses.envelope(0.3, 0.1), lessThan(PlayerPulses.envelope(0.3, 2)), reason: 'a long note fades slower');
      expect(PlayerPulses.envelope(PlayerPulses.attack + PlayerPulses.fadeOf(0.5), 0.5), 0);
      expect(pulses.level(const PlayerLink('nobody'), on), 0);
    }
  });

  test('curation: regions drawn and erased, a region leaving out a staff, auto-curate only where staves would run off', () async {
    // Drawing joins regions; erasing trims, splits and removes them.
    final c = Curation(['vn', 'va'])..setLane('vn', const [Region(0, 8), Region(12, 16)]);
    c.paint(['vn', 'va'], const Region(6, 14));
    expect([c.lane('vn'), c.lane('va')], const [[Region(0, 16)], [Region(6, 14)]]);
    c.paint(['vn'], const Region(4, 13), shown: false);
    expect(c.lane('vn'), const [Region(0, 4), Region(13, 16)]);
    c.paint(['vn'], const Region(0, 5), shown: false);
    expect(c.lane('vn'), const [Region(13, 16)]);

    // The piano's left hand left out in bar 2: a region of its own, meeting bar 1's.
    final piano = await LoadedScore.load(flutePianoScore);
    final pianoScene = CuratedScene(piano);
    final curation = Curation(['P1', 'P2'])
      ..setLanes({
        'P1': [const Region(0, 8)],
        'P2': [const Region(0, 4), const Region(4, 8, hiddenStaves: [2])],
      });
    expect(curation.lane('P2'), hasLength(2), reason: 'never merged');
    const tall = ui.Size(960, 4000);
    double at(double quarter) => piano.timeline.secondsAtQuarter(quarter);
    final both = pianoScene.layoutAt(at(1), curation, tall), one = pianoScene.layoutAt(at(7), curation, tall);
    expect((both.placements.length, both.braces.length), (3, 1));
    expect((one.placements.length, one.braces.length), (2, 0), reason: 'the left hand gone');
    expect(one.labels.last.centerY, lessThan(both.labels.last.centerY - 10), reason: 'named beside the right hand alone');
    // Split, a lane a staff: each shows where its staff is, and setting one sets the piano's.
    final (rh, lh) = (Curation.staffLaneId('P2', 1), Curation.staffLaneId('P2', 2));
    curation.setSplit({'P2': 2});
    expect([curation.lane(rh), curation.lane(lh)], [[const Region(0, 8)], [const Region(0, 4)]]);
    curation.setLanes({rh: [const Region(0, 2)], lh: [const Region(0, 8)]});
    expect([for (final r in curation.lane('P2')) '${r.start}–${r.end} ${r.hiddenStaves}'], ['0.0–2.0 []', '2.0–8.0 [1]']);
    pianoScene.dispose();

    // Auto-curate, worked out on another isolate while opening (from the file's bar lengths).
    final stages = <LoadStage>[];
    final measured = await LoadedScore.engrave(score.musicXML, score.request, measure: true, onStage: stages.add);
    expect(stages, [LoadStage.reading, LoadStage.engraving, LoadStage.measuring]);
    expect(measured.salience.scores, BarSalience.of(score.musicXML, score.metadata, score.timeline.measureStarts).scores);
    final scene = CuratedScene(score);
    final ids = [for (final p in score.metadata.parts) p.id];
    final starts = score.timeline.measureStarts;
    final playing = Curation.autoCuratedLanes(ids, score.metadata.activeMeasures, starts);
    final base = Curation(ids)..setLanes(playing);
    bool shownIn(List<Region> lane, int m) => lane.any((r) => r.start <= starts[m] && r.end > starts[m]);
    List<String> shownAt(Map<String, List<Region>> lanes, int m) => [for (final id in ids) if (shownIn(lanes[id]!, m)) id];
    const wide = ui.Size(960, 540), upright = ui.Size(540, 960);
    expect(scene.overflowing(base, wide), isNotEmpty, reason: '21 staves in the tutti');
    final fitted = scene.curatedToFit(base, wide, partIds: ids, activeMeasures: score.metadata.activeMeasures, salience: score.salience);
    expect(scene.overflowing(Curation(ids)..setLanes(fitted), wide), isEmpty);
    for (var m = 0; m < starts.length - 1; m++) {
      final now = shownAt(fitted, m), before = shownAt(playing, m);
      expect(before, containsAll(now), reason: 'only hides (bar ${m + 1})');
      if (before.isNotEmpty) expect(now, isNotEmpty, reason: 'someone left (bar ${m + 1})');
    }
    // Upright there is room for the opening's few: none goes.
    final tallFit = scene.curatedToFit(base, upright, partIds: ids, activeMeasures: score.metadata.activeMeasures, salience: score.salience);
    for (var m = 0; m < 5; m++) {
      expect(shownAt(tallFit, m), shownAt(playing, m));
    }
    scene.dispose();
  });
}
