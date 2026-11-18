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
      expect((midi.partCount, midi.noteCount), (21, played(score.musicXML, pitches: false).length));
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
