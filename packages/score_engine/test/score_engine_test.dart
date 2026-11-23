import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';
import 'package:score_engine/src/engraving.dart' show Cmd;

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

  test('the demo engraves: its parts, a scroll map under every onset that never runs backwards, a phrase found, a video frame; the same as a MIDI file, in rows', () async {
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
    final numbered = ScoreMetadata.read(xml);
    expect(numbered.barNumbers, [null, '1', '2', null, '3a', '4']);
    // A first bar number moves them all as far, the letters kept; the grid counts its bars from it.
    expect((numbered.firstBarNumber, numbered.barNumbersFrom(null)), (1, numbered.barNumbers));
    expect(numbered.barNumbersFrom(145), [null, '145', '146', null, '147a', '148']);
    final counted = score.beats.countedFrom(145), bar3 = score.timeline.measureStarts[2];
    expect((score.beats.format(bar3, compact: true), counted.format(bar3, compact: true), counted.format(bar3)), ('3', '147', '147.1'));
    expect((counted.parse('147'), counted.parse('147.2'), counted.parse('3'), counted.parse('144')), (bar3, bar3 + 1.5, null, null));
    expect((counted.barNumber(0), counted.measureAt(bar3)), (145, 2));
    expect(score.beats.countedFrom(1), same(score.beats));

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
    // A note stepped past the highest or the lowest stays: B8 a step up was C8, C0 a step down B0.
    const top = PhraseNote(step: 6, octave: 8, value: NoteValue.quarter), bottom = PhraseNote(step: 0, octave: 0, value: NoteValue.quarter);
    expect([top.stepped(1), top.stepped(7), bottom.stepped(-1), bottom.stepped(-7)], [top, top, bottom, bottom]);
    expect((top.stepped(-1).diatonic, bottom.stepped(7).diatonic), (top.diatonic - 1, 7));

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
      final flute = grown.sections.firstWhere((s) => s.name == 'Flute');
      expect([for (final s in flute.seats) s.link?.part], ['P2', 'P3', null, null, null, null]);
      expect([for (final s in flute.withoutSeat(0).seats) s.link?.part], ['P3', null, null, null, null], reason: 'the rest keep what they play');
      expect((flute.hasUnlinked, grown.sections.first.hasUnlinked), (true, false));
      // A section added where another is (another of it) is put where there is room, on the stage.
      final timpani = seated.sections.firstWhere((s) => s.name == 'Timpani'), copied = seated.adding(timpani);
      expect(copied.sections.last, isNot(timpani));
      tidy(copied, 'another timpani');
      // A section set over another by hand stays there when that one grows, and a map with a
      // section past the stage's edge isn't pulled in (nor reaches further off).
      final fl = seated.sections.indexWhere((s) => s.name == 'Flute'), pc = seated.sections.indexWhere((s) => s.name == 'Piccolo');
      final to = seated.sections[fl].center, from = seated.sections[pc].center;
      final over = seated.sections[pc].moved(to.x - from.x, to.y - from.y), out = seated.sections.last.moved(0, 1.05 - seated.sections.last.bounds().bottom);
      final byHand = seated.withSection(pc, over).withSection(seated.sections.length - 1, out);
      final more = byHand.roomFor(fl, byHand.sections[fl].withCount(4));
      expect(byHand.bounds!.bottom, greaterThan(1));
      expect((more.sections[pc], more.sections.last, more.bounds), (over, out, byHand.bounds));
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
      // Dragged, it stops at the stage's edge, a player alone too; a place saved far off the stage
      // (as a held arrow once left it) is read as one just off it, not refused.
      expect(old.dragged(-3, 0).bounds().left, closeTo(0, 1e-9));
      expect(old.dragged(0, 3, seat: 1).seats.map((s) => s.y), [0.5, closeTo(1 - old.size / 2, 1e-9)]);
      final far = old.toJson()..['seats'] = [[9, 0.5]];
      expect(MapSection.fromJson(far, 'section').seats.single.x, 2);
      // Counted from names and staves; a contrabassoon is no bass, nor a contrabass clarinet;
      // tubular bells are no tuba; a harp named in Chinese is known by its sound, and a guitar is
      // no section of violins.
      ScorePart part(String id, String name, [int staves = 1, String? sound]) =>
          ScorePart(id: id, name: name, abbreviation: '', sound: sound, staffNumbers: [for (var i = 1; i <= staves; i++) i]);
      final band = PlayerMap.smart([
        part('a', 'Horn in F 1-4', 2), part('b', 'Trumpets I–III'), part('c', 'Contrabassoon'), part('d', 'Violin'), //
        part('e', 'Contrabass Clarinet'), part('f', 'Tubular Bells'), part('g', '竖琴', 1, 'pluck.harp'), part('i', 'Guitar', 1, 'pluck.guitar'),
      ]);
      expect({for (final s in band.sections) s.name: (s.color, s.seats.length)}, containsPair('Contrabass Clarinet', (MapColors.woodwinds, 1)));
      expect({for (final s in band.sections) s.name: (s.color, s.seats.length)},
          allOf(containsPair('Tubular Bells', (MapColors.percussion, 1)), containsPair('竖琴', (MapColors.keyboards, 1)), containsPair('Guitar', (MapColors.other, 1))));
      final seats = {for (final s in band.sections) s.name: [for (var i = 0; i < s.seats.length; i++) s.linkOf(i)?.key]};
      expect(seats['Horn in F 1-4'], ['a', 'a', 'a', 'a']);
      expect(seats['Trumpets I–III'], ['b', 'b', 'b']);
      expect(seats['Contrabassoon'], ['c']);
      expect(PlayerMap.smart([part('h', 'Horns 1.2', 2)]).sections.single.seats.map((s) => s.link?.key), ['h#1', 'h#2']);
      // A name is as wide as its characters are drawn: a Chinese one about twice a Latin one's.
      expect([SeatPlan.labelEms('第一小提琴'), SeatPlan.labelEms('Viola')], [5, closeTo(2.9, 1e-9)]);

      final text = seated.encode();
      expect(PlayerMap.decode(text).encode(), text);
      expect(() => PlayerMap.decode('{"format": "something else"}'), throwsFormatException);
      // A section with no seat at all is damage, said as such (drawn, it threw).
      final seatless = jsonDecode(text) as Map<String, Object?>;
      (((seatless['map'] as Map)['sections'] as List).first as Map)['seats'] = <Object?>[];
      expect(() => PlayerMap.decode(jsonEncode(seatless)), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('seats is not a list of seats'))));
      expect(() => PlayerMap.decode(text.replaceFirst('"version": 1', '"version": 2')), throwsFormatException);
      final other = [part('X9', 'Flute 2'), part('P2', 'Oboe')];
      final moved = PlayerMap.decode(text).relinked(other);
      expect([for (final s in moved.sections.firstWhere((s) => s.name == 'Flute').seats) s.link?.part], [null, 'X9'],
          reason: 'by name; P2 is an oboe there, so no flute');

      final dynamics = ScoreDynamics.read(score.musicXML, starts);
      final pulses = PlayerPulses.of(soundingNotes(score.musicXML, starts), score.timeline, dynamics: dynamics);
      final violins = seated.sections.first.link!;
      final first = soundingNotes(score.musicXML, starts).firstWhere((n) => n.partId == violins.part);
      final on = score.timeline.secondsAtQuarter(first.start);
      expect(pulses.level(violins, on - 0.001), 0);
      expect(pulses.level(violins, on + PlayerPulses.attack), closeTo(PlayerPulses.strengthOf(dynamics.at(violins.part, first.start)), 1e-9),
          reason: 'as far as it is loud');
      expect(PlayerPulses.strengthOf(ScoreDynamics.levels['pp']!), lessThan(PlayerPulses.strengthOf(ScoreDynamics.levels['ff']!)));
      // Whatever a map links asks the same pulses: the violins' one staff as all of them, a part
      // the score hasn't nothing.
      expect(pulses.level(violins.withStaff(1), on + PlayerPulses.attack), pulses.level(violins, on + PlayerPulses.attack));
      expect(pulses.level(const PlayerLink('none'), on + PlayerPulses.attack), 0);

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

    // The demo as a MIDI file is the same music drawn in rows: a part for each track, by its
    // name; the bars its time signature's; every note it plays, written so the score's readers
    // read it; each a bar in its instrument's row, with no clef or key to keep at the left.
    {
      final bytes = demoMidi(), file = MidiFile.read(bytes);
      expect((file.division, file.title, file.voices.length), (480, 'Intro', 21));
      expect(file.meters, [(tick: 0, count: 6, unit: 8)]);
      expect([for (final v in file.voices) if (v.isDrums) v.name], ['Snare Drum'], reason: 'on the drum channel');
      expect(MidiTempoMap.read(bytes).tempos.single.quartersPerMinute, closeTo(93, 1e-3));

      final midi = MidiScore.read(bytes);
      List<(int, int, int, int)> played(String xml, {required bool pitches}) => [
            for (final n in soundingNotes(xml, starts, unpitched: true))
              (int.parse(n.partId.substring(1)), (n.start * 480).round(), (n.end * 480).round(), pitches ? n.midi : 0),
          ]..sort((a, b) {
              for (final d in [a.$1 - b.$1, a.$2 - b.$2, a.$4 - b.$4, a.$3 - b.$3]) {
                if (d != 0) return d;
              }
              return 0;
            });
      final unpitched = {for (final (i, p) in parts.indexed) if (p.isUnpitchedPercussion) i + 1};
      bool pitched((int, int, int, int) n) => !unpitched.contains(n.$1);
      expect((midi.rowCount, midi.noteCount), (21, played(score.musicXML, pitches: false).length));
      expect(midi.barLengths, List.filled(44, 3.0));
      expect(played(midi.musicXML, pitches: true).where(pitched), played(score.musicXML, pitches: true).where(pitched));
      expect(played(midi.musicXML, pitches: false), played(score.musicXML, pitches: false), reason: 'the drums too, when they sound');

      final rows = await LoadedScore.engrave('', const EngraveRequest(), midi: midi, measure: true);
      expect((rows.isRoll, rows.isDrawn, rows.metadata.tempo), (true, true, 93));
      expect([for (final p in rows.metadata.parts) p.name], [for (final p in parts) p.name]);
      expect((rows.metadata.parts.first.family, rows.metadata.parts.last.family), (InstrumentFamily.woodwinds, InstrumentFamily.strings));
      expect(rows.timeline.measureStarts, starts);
      expect(rows.scrollMap.duration, closeTo(map.duration, 1e-6));
      final drawn = rows.engraving;
      expect((drawn.staves.length, drawn.measures.length), (21, 44));
      expect(drawn.signatures, isEmpty);
      expect(drawn.staves.every((s) => s.lines == 0), isTrue);
      // Its bars end to end, each as wide as it is long: three quarters of four staff spaces.
      expect(drawn.measures[1].left - drawn.measures[0].left, closeTo(3 * 4 * MidiScore.unit, 1e-3));
      // A row's notes and its bars' lines, nothing else: one command a note, and a line a bar a row (and its end).
      expect(drawn.commandCount, midi.noteCount + 21 * 45);

      // A look lays the rows out again: beats a step wider, rows a step taller; kept as JSON.
      const look = MidiLook(sharedRange: true, velocity: false);
      final wider = await rows.withRequest(EngraveRequest(midi: look.beats(1).rows(1)));
      expect(wider.engraving.measures[1].left - wider.engraving.measures[0].left, closeTo(3 * 5 * MidiScore.unit, 1e-3));
      expect(wider.engraving.staves.first.height, closeTo(2.5 * 1.25 * MidiScore.unit, 1e-3));
      expect((wider.isRoll, wider.request.midi), (true, look.beats(1).rows(1)));
      expect(look.beats(1).beats(-1), look);
      expect(MidiLook.fromJson(look.toJson()), look);
      expect(MidiLook.fromJson({'rowHeight': 99, 'beatWidth': 'wide'}), const MidiLook(rowHeight: 8));

      // A score that is notation has the same view of its own notes, beside its engraving: a row
      // for each staff, a note from where it starts to where what is tied to it ends, the bars
      // and the timeline the engraving's own (one sync and one curation show both); a MIDI
      // project's score is rows already.
      expect((score.hasRows, rows.hasRows), (true, false));
      final own = score.rows(look), ownNotes = MidiScore.ofScore(score.musicXML, score.metadata, starts);
      expect((own.isRoll, own.hasNotes, own.request.midi, own.condensed.isEmpty), (true, true, look, true));
      expect((identical(own.metadata, score.metadata), identical(own.timeline, score.timeline)), (true, true));
      expect([for (final s in own.engraving.staves) s.n], [for (final p in parts) ...p.staffNumbers]);
      expect(ownNotes.noteCount, soundingNotes(score.musicXML, starts, unpitched: true).where((n) => !n.tied).length);
      expect(ownNotes.barLengths, midi.barLengths);
      expect(own.engraving.commandCount, ownNotes.noteCount + ownNotes.rowCount * 45);
      expect((await score.rowsApart(look)).engraving.commandCount, own.engraving.commandCount, reason: 'read on another isolate, the same');
      // Drawn as the score is, by a scene of its own with the score's settings: the same bar under the pointer.
      final ownScene = CuratedScene(own)..settings = const SceneSettings(barNumbers: true, sections: true);
      final shown = Curation(parts.map((p) => p.id))..setLanes({for (final p in parts.take(6)) p.id: [Region(0, starts.last)]});
      ownScene.renderFrame(400, 240, time: 12, curation: shown, devicePixelRatio: 1).dispose();
      expect(ownScene.axis.quarterAt(ownScene.scrollMap.xAt(12)), closeTo(score.timeline.quarterAtSeconds(12), 0.5));
      ownScene.dispose();
      shown.dispose();

      // The web page's: the rows read back from an engraving file, drawn in their instruments' colours.
      final page = LoadedScore.engraved(rows.musicXML, rows.request, EngravingFile.read(EngravingFile.write(drawn)), roll: true);
      expect((page.isRoll, page.engraving.commandCount), (true, drawn.commandCount));
      final scene = CuratedScene(page)..nameColors = {parts.first.id: const ui.Color(0xFF4A6FA5)};
      final curation = Curation(parts.map((p) => p.id))..setLane(parts.first.id, [Region(0, starts.last)]);
      final frame = scene.renderFrame(400, 120, time: 2, curation: curation, devicePixelRatio: 1, paper: const ui.Color(0xFFFFFFFF), ink: const ui.Color(0xFF000000));
      final pixels = (await frame.toByteData())!;
      var blue = 0, black = 0;
      for (var i = 0; i < pixels.lengthInBytes; i += 4) {
        final r = pixels.getUint8(i), b = pixels.getUint8(i + 2);
        if (b > r + 40) blue++;
        if (r < 40 && b < 40) black++;
      }
      expect((blue > 50, black), (true, 0), reason: 'the piccolo’s notes in its colour, on white');
      scene.dispose();

      // A key struck again while held, with no note-off between, isn't held to the track's end:
      // its note-off lets go of both. One whose notes overlap and are each let go keeps them.
      final struck = <int>[
        0, 0x90, 60, 80, 0, 0x90, 62, 80, 0x83, 0x60, 0x90, 60, 80, 0, 0x90, 62, 80, // at 0 and at 480
        0x83, 0x60, 0x80, 60, 0, 0, 0x80, 62, 0, 0x83, 0x60, 0x80, 62, 0, // at 960 and 1440
        0x83, 0x60, 0x90, 60, 80, 0x83, 0x60, 0x80, 60, 0, 0xa5, 0x40, 0x90, 64, 80, 0x83, 0x60, 0x80, 64, 0, // 1920 to 2400; 7200 to 7680
        0, 0xff, 0x2f, 0,
      ];
      final again = MidiFile.read(Uint8List.fromList([...'MThd'.codeUnits, 0, 0, 0, 6, 0, 0, 0, 1, 1, 0xe0, ...'MTrk'.codeUnits, 0, 0, 0, struck.length, ...struck]));
      expect([for (final n in again.voices.single.notes) (n.key, n.start, n.end)],
          [(62, 0, 960), (60, 0, 960), (62, 480, 1440), (60, 480, 960), (60, 1920, 2400), (64, 7200, 7680)]);

      // Many instruments over many bars are refused before each one's every bar is written out:
      // 500 tracks of a note each, the last four hours in.
      final one = <int>[0, 0x90, 60, 80, 0x83, 0x60, 0x80, 60, 0, 0, 0xff, 0x2f, 0], far = <int>[0x87, 0xd4, 0xc0, 0x00, 0x90, 60, 80, 0x83, 0x60, 0x80, 60, 0, 0, 0xff, 0x2f, 0];
      final wide = Uint8List.fromList([
        ...'MThd'.codeUnits, 0, 0, 0, 6, 0, 1, 500 >> 8, 500 & 0xff, 1, 0xe0, //
        for (var t = 0; t < 500; t++) ...[...'MTrk'.codeUnits, 0, 0, 0, (t == 499 ? far : one).length, ...(t == 499 ? far : one)],
      ]);
      expect(() => MidiScore.read(wide), throwsA(isA<FormatException>().having((e) => e.message, 'message', 'This MIDI file is too long.')));

      // A file that plays nothing is no score.
      final silent = Uint8List.fromList([...'MThd'.codeUnits, 0, 0, 0, 6, 0, 0, 0, 1, 1, 0xe0, ...'MTrk'.codeUnits, 0, 0, 0, 4, 0, 0xff, 0x2f, 0]);
      expect(() => MidiScore.read(silent), throwsA(isA<FormatException>().having((e) => e.message, 'message', 'This MIDI file has no notes.')));
    }

    // A motion curve typed a character at a time: "0." on the way to "0.5" is a number, and a point
    // that is in none is said, never thrown past the field.
    expect([for (final text in ['0.', '0.5*t', '2.t', '.5t', 't^1.']) MotionCurve.problemWith(text)], [for (var i = 0; i < 5; i++) isNot(contains('Null'))]);
    expect([MotionCurve.problemWith('0.5*t'), MotionCurve.problemWith('.'), MotionCurve.problemWith('t*.')], [null, 'Unexpected “.”.', 'Unexpected “.”.']);
  });

  test('curation: regions drawn and erased, a region leaving out a staff, auto-curate only where staves would run off; a piano’s dynamics between its staves', () async {
    // Drawing joins regions; erasing trims, splits and removes them.
    final c = Curation(['vn', 'va'])..setLane('vn', const [Region(0, 8), Region(12, 16)]);
    c.paint(['vn', 'va'], const Region(6, 14));
    expect([c.lane('vn'), c.lane('va')], const [[Region(0, 16)], [Region(6, 14)]]);
    c.paint(['vn'], const Region(4, 13), shown: false);
    expect(c.lane('vn'), const [Region(0, 4), Region(13, 16)]);
    c.paint(['vn'], const Region(0, 5), shown: false);
    expect(c.lane('vn'), const [Region(13, 16)]);

    // A script curates as the tools do: a statement a line, names in quotes, bars as they are numbered.
    {
      final host = _ScriptLanes(
        [('fl', 'Flute 1', 1), ('fl2', 'Flute 2', 1), ('pf', 'Piano', 2), ('v1', 'Violin', 1), ('v2', 'Violin', 1)],
        BeatGrid([for (var m = 0; m <= 12; m++) m * 4.0]),
      );
      final lanes = host.curation;
      List<String> run(String source) => [for (final p in LaneScript.parse(source).run(host)) '$p'];
      // Draw and Erase: whole bars, beats, names however they are cased and spaced.
      expect(run('# The flutes.\nshow "Flute 1", "flute  2" bars 1-2, 5\nHIDE "Flute 2" 2.3-2.4 # its last two beats'), isEmpty);
      expect([lanes.lane('fl'), lanes.lane('fl2')], const [[Region(0, 8), Region(16, 20)], [Region(0, 6), Region(16, 20)]]);
      // A group, a wildcard, a rehearsal mark; only hides the others there.
      lanes.setLane('v1', const [Region(0, 48)]);
      expect(run('let winds = "Flute*"\nonly winds from 3 until mark A'), isEmpty);
      expect([lanes.lane('fl'), lanes.lane('fl2'), lanes.lane('v1')], const [[Region(0, 20)], [Region(0, 6), Region(8, 20)], [Region(0, 8), Region(16, 48)]]);
      // A stretch with its own transitions that leaves out a staff; shown whole over it, it gives way.
      expect(run('show "Piano" 1-4 transition in 0.5 out 1 without staff 2\nshow "Piano" 3-6'), isEmpty);
      expect(lanes.lane('pf'), const [Region(0, 8, transitionIn: 0.5, transitionOut: 1, hiddenStaves: [2]), Region(8, 24)]);
      expect(run('show "Piano" 1 without staves 1, 2'), ['Line 1: That leaves “Piano” no staff.']);
      // A staff's lane, once its instrument is split.
      expect(run('show "Piano"/2 1-2'), ['Line 1: “Piano” isn’t split: write split "Piano" first.']);
      expect(run('split "Piano"\nshow "Piano"/2 1-2\nshow "Piano"/3'), ['Line 3: “Piano” is on 2 staves.']);
      expect([host.split, lanes.lane('pf/2')], [{'pf'}, const [Region(0, 24)]]);
      expect(run('split "Flute 1"'), ['Line 1: “Flute 1” is on one staff.']);
      expect([run('join all'), host.split], [isEmpty, isEmpty]);
      // The project's transition, and regions' own at the edges inside a range.
      expect(run('transition 0.4\ntransition "Flute 2" 3-5 in 1 out default'), isEmpty);
      expect([lanes.transition, lanes.lane('fl2')], [0.4, const [Region(0, 6), Region(8, 20, transitionIn: 1)]]);
      // One of two lanes of a name; Tidy; Auto-Curate; moving.
      expect(run('copy "Violin" to "Flute 1"'), ['Line 1: One lane is copied, and that names 2.']);
      expect(run('copy "Flute 1" to "Violin"[2]\nbridge rests 1 in "Flute 2"\nremove short 6 in "Flute 2"\nauto "Flute*"'), isEmpty);
      expect([lanes.lane('v2'), lanes.lane('fl2'), host.autoCurated], [const [Region(0, 20)], isEmpty, ['fl', 'fl2']]);
      expect(run('move "Violin"[2] to top\nmove "Flute 1" after "Piano"'), isEmpty);
      expect([for (final lane in host.lanes) lane.id], ['v2', 'fl2', 'pf', 'fl', 'v1']);
      expect([run('restore order'), host.lanes.first.id], [isEmpty, 'fl']);
      host.auto = false;
      expect(run('auto'), ['Line 1: This score’s lanes can’t be auto-curated.']);
      // What doesn't read is said with its line, and nothing runs; what can't be done is left out.
      final before = lanes.lanes;
      expect(run('clear\nshw "Flute 1"\nshow "Flute 1\nshow "Flute 1" 1 2'), [
        'Line 2: A line starts with what it does (show, hide, auto…), not “shw”.',
        'Line 3: A name’s closing quote is missing.',
        'Line 4: “2” isn’t expected here.',
      ]);
      expect(lanes.lanes, before);
      expect(run('show Flute 1-8\nshow "Oboe"\nshow "Flute 1" 13\nshow "Flute 1" 4-2\nshow all except all'), [
        'Line 1: There is no group “Flute”. A lane’s name goes in quotes: "Flute".',
        'Line 2: There is no lane named “Oboe”.',
        'Line 3: There is no bar 13.',
        'Line 4: The range ends before it starts.',
        'Line 5: That leaves no lane.',
      ]);
      // A check finds the same and changes nothing, a split and what follows it included.
      expect([for (final p in LaneScript.parse('split "Piano"\nclear\nshow "Piano"/1 1\nshow "Oboe"\nshw').check(host)) '$p'],
          ['Line 4: There is no lane named “Oboe”.', 'Line 5: A line starts with what it does (show, hide, auto…), not “shw”.']);
      expect([host.split, lanes.lanes], [isEmpty, before]);
      // The lanes written as a script make themselves again: a place off the beats in quarters.
      lanes.setLanes({'v1': const [Region(4 / 3, 9)], 'fl2': const [Region(1.25, 48)]});
      host.setSplit('pf', true);
      final written = LaneScript.write(host), kept = lanes.lanes;
      expect(written.split('\n'), containsAll(['join all', 'split "Piano"', 'transition 0.4', 'show "Flute 1" 1-5', 'show "Flute 2" from 1.2.25',
        'show "Violin"[1] from @${4 / 3} until 3.2', 'show "Piano"/2 1-6 transition in 0.5 out 1']));
      lanes.transition = 1;
      expect([run('show all\njoin all\n$written'), lanes.lanes, lanes.transition, host.split], [isEmpty, kept, 0.4, {'pf'}]);
      // Each run coloured, the language's words whatever their case.
      expect(LaneScript.tokens('Show "A"[2]/1 1-8.2 # all'), [('keyword', 'Show'), (null, ' '), ('string', '"A"'), (null, '['), ('number', '2'), (null, ']'), (null, '/'),
        ('number', '1'), (null, ' '), ('number', '1'), (null, '-'), ('number', '8.2'), (null, ' '), ('comment', '# all')]);
      expect({for (final s in LaneScript.statements) s.word}.difference(LaneScript.keywords), isEmpty);
      expect([for (final s in LaneScript.statements) ...LaneScript.parse(s.example).problems], isEmpty);

      // A macro is steps put together from choices, written as a script for the moment: the lanes selected, where the
      // playhead is, the bars of what is selected, bars asked for; a line a step.
      const macro = LaneMacro(name: 'Solo', steps: [
        MacroStep(MacroAction.only, range: MacroRange.fromPlayhead),
        MacroStep(MacroAction.show, lanes: MacroLanes.named, names: ['Flute*'], range: MacroRange.ask),
        MacroStep(MacroAction.hide, lanes: MacroLanes.others, range: MacroRange.playheadBar),
        MacroStep(MacroAction.transition, lanes: MacroLanes.all, range: MacroRange.selection, number: 2),
        MacroStep(MacroAction.bridge, lanes: MacroLanes.all),
        MacroStep(MacroAction.moveTop),
      ]);
      final asScript = macro.script(MacroContext.of(host, selected: ['v2', 'pf/1'], playhead: 18, span: (8, 16), asked: '1-2, 9'));
      expect(asScript.problems, isEmpty);
      expect(asScript.script.split('\n'), [
        'only "Piano"/1, "Violin"[2] from 5.3',
        'show "Flute*" 1-2, 9',
        'hide all except "Piano"/1, "Violin"[2] 5',
        'transition all 3-4 in 2 out 2',
        'bridge rests 1 in all',
        'move "Piano"/1, "Violin"[2] to top',
      ]);
      expect(run(asScript.script), isEmpty);
      expect([lanes.lane('fl'), lanes.lane('v2'), host.lanes.first.id], [const [Region(0, 16, transitionOut: 2), Region(32, 36)], const [Region(0, 48)], 'pf/1']);
      // What a step needs and isn't there is said by its step, and so is what its script gets wrong.
      final nothing = macro.script(const MacroContext(asked: '1 # 2'));
      expect([for (final p in nothing.problems) '$p'], ['Step 1: lanes', 'Step 2: bars', 'Step 3: bars', 'Step 4: regions', 'Step 6: lanes']);
      expect(nothing.script.split('\n')[4], 'bridge rests 1 in all');
      expect(const LaneMacro(name: '', steps: [MacroStep(MacroAction.clear, lanes: MacroLanes.named, names: [' '])]).script(const MacroContext()).problems.single.fault, MacroFault.names);
      expect('${LaneMacro.problemsOf(LaneScript.parse('clear\nshow "Oboe"').check(host)).single}', 'Step 2: There is no lane named “Oboe”.');
      // Auto-Curate in its two halves: a lane follows its notes (through a rest of a bar; over a range only; one that plays
      // nothing stays), then gives up what the frame has no room for. The example macro is those two, on every lane.
      host.plays = {'fl': [for (var m = 0; m < 12; m++) const [0, 1, 3, 6, 7].contains(m)]};
      lanes.setLane('fl2', const [Region(0, 4)]);
      expect(run('follow "Flute*" bridge 1'), isEmpty);
      expect([lanes.lane('fl'), lanes.lane('fl2')], const [[Region(0, 16), Region(24, 32)], [Region(0, 4)]]);
      expect([run('follow "Flute 1"'), lanes.lane('fl')], [isEmpty, const [Region(0, 8), Region(12, 16), Region(24, 32)]]);
      expect([run('clear "Flute 1"\nfollow "Flute 1" 2-4'), lanes.lane('fl')], [isEmpty, const [Region(4, 8), Region(12, 16)]]);
      // Fitting is three steps, each a statement (the host's to find: here a thin hides bar 4, a refill shows it again, a
      // lone bar goes), and `fit` is the three, in their order.
      host.fits = {FitStep.thin: {'fl': const [Region(12, 16)]}, FitStep.refill: {'fl': const [Region(12, 14)]}, FitStep.lone: {'fl': const [Region(4, 8)]}};
      expect([run('thin "Flute*" phrase 2'), lanes.lane('fl'), host.fitted], [isEmpty, const [Region(4, 8)], ['thin fl,fl2 2']]);
      expect([run('refill "Flute 1"'), lanes.lane('fl'), host.fitted.last], [isEmpty, const [Region(4, 8), Region(12, 14)], 'refill fl 4']);
      expect([run('remove lone in "Flute 1"'), lanes.lane('fl'), host.fitted.last], [isEmpty, const [Region(12, 14)], 'lone fl 4']);
      host.fitted.clear();
      expect([run('follow "Flute 1" 2-4\nfit "Flute 1" phrase 3'), lanes.lane('fl'), host.fitted], [isEmpty, const [Region(12, 14)], ['thin fl 3', 'refill fl 3', 'lone fl 3']]);
      expect(LaneMacro.examples.first.script(const MacroContext()).script.split('\n'),
          ['follow all bridge 1', 'thin all phrase 4', 'refill all', 'remove lone in all']);
      host.follows = false;
      expect([for (final p in LaneScript.parse('follow\nfit\nthin\nrefill\nremove lone').check(host)) '$p'],
          [for (var line = 1; line <= 5; line++) 'Line $line: This score’s lanes can’t be auto-curated.']);
      host.follows = true;
      // Kept as JSON; what isn't a step, or a macro, is left out.
      expect(LaneMacro.read(LaneMacro.write([macro.copyWith(icon: 'tidy'), ...LaneMacro.examples])), [macro.copyWith(icon: 'tidy'), ...LaneMacro.examples]);
      expect([macro.copyWith(icon: 'tidy') == macro, macro.toJson().containsKey('icon')], [false, false]);
      expect(LaneMacro.read('[{"name": "x", "steps": [{"do": "fly"}, {"do": "hide", "lanes": "all", "range": "bars", "bars": "1-2"}, 3]}, {"steps": []}, 7]'),
          const [LaneMacro(name: 'x', steps: [MacroStep(MacroAction.hide, lanes: MacroLanes.all, range: MacroRange.bars, bars: '1-2')])]);
      expect([LaneMacro.read('{'), LaneMacro.read(null)], [isEmpty, isEmpty]);
      expect([for (final m in LaneMacro.examples) ...LaneScript.parse(m.script(MacroContext.of(host, selected: ['fl'], playhead: 4, asked: '2')).script).check(host)], isEmpty);
    }

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
    // In the MIDI view its hands are a row each, as they are written, named as one and not braced.
    {
      final rows = piano.rows(const MidiLook()), scene = CuratedScene(rows);
      final lanes = Curation(['P1', 'P2'])..setLanes({'P1': [const Region(0, 8)], 'P2': [const Region(0, 8)]});
      final laid = scene.layoutAt(at(1), lanes, tall);
      expect([for (final s in rows.engraving.staves) s.n], [1, 2, 3]);
      expect((laid.placements.length, laid.labels.length, laid.braces.isEmpty, laid.joins.isEmpty), (3, 2, true, true));
      scene.renderFrame(400, 200, time: at(1), curation: lanes, devicePixelRatio: 1).dispose();
      scene.dispose();
    }
    // A staff's own room is its lane's, numbered among all its instrument's staves: with a
    // first staff that never plays (left out of the view), room under the second is between the
    // two shown, not under the third.
    {
      final three = await LoadedScore.load(flutePianoScore
          .replaceFirst('<staves>2</staves>', '<staves>3</staves>')
          .replaceFirst('<clef number="2">', '<clef number="3">')
          .replaceFirst('<clef number="1">', '<clef number="2">')
          .replaceAll('<staff>2</staff>', '<staff>3</staff>')
          .replaceAll('<staff>1</staff>', '<staff>2</staff>'));
      expect(three.metadata.parts[1].shownStaffNumbers, hasLength(2));
      final scene = CuratedScene(three);
      final shown = Curation(['P1', 'P2'])..setLanes({'P1': [const Region(0, 8)], 'P2': [const Region(0, 8)]});
      double apart() {
        final y = [for (final p in scene.layoutAt(0.5, shown, tall).placements) p.y];
        return y[2] - y[1];
      }
      final before = apart();
      scene.instrumentSpacing = {Curation.staffLaneId('P2', 2): (above: 0, below: 6)};
      expect(apart(), greaterThan(before + 20));
      scene.dispose();
    }

    // Under the right hand ("p") or over the left ("f"), centred between them; under the left
    // hand ("pp"), where it was.
    final marked = flutePianoScore
        .replaceFirst('<note><pitch><step>E</step>',
            '<direction placement="below"><direction-type><dynamics><p/></dynamics></direction-type><staff>1</staff></direction><note><pitch><step>E</step>')
        .replaceFirst('<note><pitch><step>C</step><octave>3</octave>',
            '<direction placement="above"><direction-type><dynamics><f/></dynamics></direction-type><offset>4</offset><staff>2</staff></direction>'
            '<direction placement="below"><direction-type><dynamics><pp/></dynamics></direction-type><offset>6</offset><staff>2</staff></direction>'
            '<note><pitch><step>C</step><octave>3</octave>');
    // Each dynamic's centre, from the middle between the staves in staff spaces.
    Future<List<double>> dynamicsIn(bool between) async {
      final e = (await LoadedScore.load(marked, request: EngraveRequest(dynamicsBetween: between))).engraving;
      final (upper, lower, dynam) = (e.staves[1], e.staves[2], e.classNames.indexOf('dynam'));
      final middle = (upper.top + upper.height + lower.top) / 2;
      return [
        for (var i = 0; i < e.commandCount; i++)
          if (e.commandInts[i * Cmd.words + Cmd.classIndex] == dynam)
            (e.commandFloats[i * Cmd.words + Cmd.bounds + 1] + e.commandFloats[i * Cmd.words + Cmd.bounds + 3] / 2 - middle) / e.staffSpace,
      ];
    }
    final (apart, between) = (await dynamicsIn(false), await dynamicsIn(true));
    expect([for (final y in apart.take(2)) y.abs() > 1], [true, true], reason: '$apart');
    expect([for (final y in between.take(2)) y.abs() < 0.5], [true, true], reason: '$between');
    expect(between.last, greaterThan(4), reason: 'under the left hand');
    // A dynamic written back under a note of a beam that crosses the staves (Dorico's way: a
    // backup, the dynamic, a forward) leaves the beam whole: no note of it flagged on its own.
    {
      const steps = '<backup><duration>1</duration></backup><direction placement="below"><direction-type><dynamics><f/></dynamics></direction-type><staff>1</staff></direction><forward><duration>1</duration></forward>';
      final e = (await LoadedScore.load(flutePianoScore.replaceFirst('<beam number="1">begin</beam></note>', '<beam number="1">begin</beam></note>$steps'))).engraving;
      final classes = {for (var i = 0; i < e.commandCount; i++) e.classNames[e.commandInts[i * Cmd.words + Cmd.classIndex]]};
      expect((classes.contains('dynam'), classes.contains('flag')), (true, false));
    }

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
    // A step at a time (what a script's follow, thin, refill and remove lone do, and a macro of them): the lanes as they
    // play, then each step's stretches taken off or drawn on, what was hidden kept between them, leaves the same; and
    // each of the three has something to do here.
    final stepped = Curation(ids)..setLanes(playing);
    final cuts = FrameCuts();
    for (final step in FitStep.values) {
      final changed = scene.fitStep(stepped, wide, step, lanes: stepped.lanes, salience: score.salience, cuts: cuts);
      expect(changed.values.any((stretches) => stretches.isNotEmpty), isTrue, reason: '$step');
      stepped.setLanes({
        for (final id in ids) id: changed[id]!.fold(stepped.lane(id), (regions, r) => Curation.painted(regions, r, shown: step == FitStep.refill)),
      });
      expect(scene.overflowing(stepped, wide), isEmpty, reason: 'fits from the thinning on ($step)');
    }
    expect(stepped.lanes, (Curation(ids)..setLanes(fitted)).lanes);
    // (A refill by itself, with nothing hidden before it, shows nothing.)
    expect(scene.fitStep(stepped, wide, FitStep.refill, lanes: stepped.lanes, salience: score.salience, cuts: FrameCuts()).values.expand((s) => s), isEmpty);
    // Upright there is room for the opening's few: none goes.
    final tallFit = scene.curatedToFit(base, upright, partIds: ids, activeMeasures: score.metadata.activeMeasures, salience: score.salience);
    for (var m = 0; m < 5; m++) {
      expect(shownAt(tallFit, m), shownAt(playing, m));
    }
    scene.dispose();
  });
}

/// Lanes for a script to run over: [parts] (id, name, staves) top to bottom.
class _ScriptLanes extends LaneScriptHost {
  _ScriptLanes(this.parts, this.beats) : curation = Curation([for (final (id, _, _) in parts) id]) {
    _original = [...parts];
  }
  List<(String, String, int)> parts;
  late final List<(String, String, int)> _original;
  final split = <String>{}, autoCurated = <String>[];
  bool auto = true, follows = true;

  /// The bars each instrument plays in (none: it plays nothing of its own), what each step of
  /// a fit is to change, and what was asked of them.
  Map<String, List<bool>> plays = {};
  Map<FitStep, Map<String, List<Region>>> fits = {};
  final fitted = <String>[];

  @override
  bool get curates => follows;
  @override
  List<bool>? playing(String id) => plays[Curation.staffOfLane(id)?.$1 ?? id];
  @override
  Map<String, List<Region>> fit(List<String> ids, FitStep step, {int phrase = 4}) {
    fitted.add('${step.name} ${ids.join(',')} $phrase');
    return fits[step] ?? const {};
  }

  @override
  final BeatGrid beats;
  @override
  final Curation curation;
  @override
  List<(String, double)> get marks => const [('A', 16)];
  @override
  List<ScriptLane> get lanes => [
        for (final (id, name, staves) in parts)
          if (split.contains(id))
            for (var n = 1; n <= staves; n++) ScriptLane(id: Curation.staffLaneId(id, n), name: name, instrument: id, staff: n, staves: staves)
          else
            ScriptLane(id: id, name: name, staves: staves),
      ];
  @override
  bool autoCurate(List<String> ids) {
    if (auto) autoCurated.addAll(ids);
    return auto;
  }

  @override
  void setSplit(String instrument, bool on) {
    on ? split.add(instrument) : split.remove(instrument);
    curation.setSplit({for (final (id, _, staves) in parts) if (split.contains(id)) id: staves});
  }

  @override
  void moveLanes(List<String> ids, {String? before}) {
    final moving = {for (final id in ids) Curation.staffOfLane(id)?.$1 ?? id};
    final rest = [for (final p in parts) if (!moving.contains(p.$1)) p];
    final target = before == null ? null : Curation.staffOfLane(before)?.$1 ?? before;
    parts = rest..insertAll(target == null ? rest.length : rest.indexWhere((p) => p.$1 == target), [for (final p in parts) if (moving.contains(p.$1)) p]);
  }

  @override
  void restoreOrder() => parts = [..._original];
}
