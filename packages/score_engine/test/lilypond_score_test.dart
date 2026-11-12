import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';
import 'package:score_engine/src/display_list.dart' show ParagraphItem, ScoreDisplayList;
import 'package:score_engine/src/engraving.dart' show Cmd;
import 'package:score_engine/src/native/constants.dart' show VBKind;

/// LilyPond's engraving of test/lilypond/fixture.ly with Curator's settings (how it was made is
/// in that file): a flute with an upbeat, a B♭ clarinet, a piano (a note crossing to the lower
/// staff, two voices, a treble clef an octave down), a voice with lyrics and drums, a repeat
/// with two endings, a tempo mark, a rehearsal mark, "rit." and a change to cut time in F.
LilyPondScore _fixture() => LilyPondScore.read(
    File('test/lilypond/fixture.svg').readAsStringSync(), File('test/lilypond/fixture.jsonl').readAsStringSync());

void main() {
  final score = _fixture();
  final data = score.engraving;
  final metadata = ScoreMetadata.read(score.musicXML);

  test('the staves are numbered in score order, a piano one part of two', () {
    expect([for (final p in metadata.parts) p.name], ['Flute', 'Clarinet in B♭', 'Piano', 'Voice', 'Drums']);
    expect([for (final p in metadata.parts) p.staffNumbers], [
      [1],
      [2],
      [3, 4],
      [5],
      [6],
    ]);
    expect(metadata.parts.last.isUnpitchedPercussion, isTrue);
    expect([for (final s in data.staves) s.n], [1, 2, 3, 4, 5, 6]);
    for (final s in data.staves) {
      expect(s.lines, 5);
      expect(s.height, closeTo(4 * LilyPondScore.unit, 0.01));
    }
    final tops = [for (final s in data.staves) s.top];
    expect(tops, orderedEquals([...tops]..sort()));
  });

  test('bars: the upbeat, then six, each where its barline is drawn', () {
    expect([for (final m in data.measures) m.duration], [1, 3, 3, 3, 3, 3, 4]);
    expect(metadata.pickups, {0});
    expect(metadata.barNumbers.take(3), [null, '1', '2']);
    for (final (i, m) in data.measures.indexed) {
      expect(m.right, greaterThan(m.left), reason: 'bar $i');
      if (i > 0) expect(m.left, data.measures[i - 1].right);
      // Every note starts inside its bar.
      for (final x in m.onsetXs) {
        expect(x, inInclusiveRange(m.left, m.right), reason: 'bar $i');
      }
    }
    expect(data.measures[1].onsetTimes, [0, 1, 2]); // the flute's half note and crotchet, the drums' crotchets
    expect([for (final m in metadata.meters.take(7)) m?.label], ['3/4', '3/4', '3/4', '3/4', '3/4', '3/4', '2/2']);
  });

  test('clefs, keys and times as music, the opening ones for the frozen zone', () {
    List<Signature> of<T extends Signature>(int staff) => [for (final s in data.signatures) if (s is T && s.staff == staff) s];
    final flute = of<ClefSignature>(1).cast<ClefSignature>();
    expect(flute.single.shape, ClefShape.g);
    expect(flute.single.line, 2);
    final lower = of<ClefSignature>(4).cast<ClefSignature>();
    expect([for (final c in lower) (c.shape, c.line, c.octave)], [(ClefShape.f, 4, 0), (ClefShape.g, 2, -1), (ClefShape.f, 4, 0)]);
    expect(of<ClefSignature>(6).cast<ClefSignature>().single.shape, ClefShape.percussion);
    expect([for (final k in of<KeySignature>(1).cast<KeySignature>()) k.fifths], [1, -1]);
    expect([for (final k in of<KeySignature>(2).cast<KeySignature>()) k.fifths], [3, 1]);
    expect(of<KeySignature>(6), isEmpty);
    final times = of<TimeSignature>(1).cast<TimeSignature>();
    expect([for (final t in times) (t.count, t.unit, t.symbol)], [(3, 4, null), (2, 2, 0xE08B)]);
    // The opening ones are drawn before the first note, and hidden for the frozen zone.
    final zone = FrozenZone(data, const RenderStyle());
    final opening = of<ClefSignature>(1).single;
    expect(opening.commandCount, greaterThan(0));
    expect(zone.openingCommands, containsAll([for (var i = opening.commandStart; i < opening.commandStart + opening.commandCount; i++) i]));
    // The tenor's 8 goes with its clef.
    final tenor = lower[1];
    expect([for (var i = tenor.commandStart; i < tenor.commandStart + tenor.commandCount; i++) data.classNames[data.commandInts[i * Cmd.words + Cmd.classIndex]]],
        containsAll(['Clef', 'ClefModifier']));
  });

  test('drawn as an engraving: staff lines, barlines and the music on its staff', () {
    final display = ScoreDisplayList.build(data, const RenderStyle());
    for (final layer in display.staves) {
      expect(layer.lines, hasLength(5), reason: 'staff ${layer.info.n}');
      expect(layer.lines.first.right - layer.lines.first.left, greaterThan(data.measures.last.right - data.measures.first.left));
      expect(layer.items, isNotEmpty);
      for (final item in layer.items) {
        // Nothing drawn far from its staff (lyrics under the voice's, marks over the flute's).
        expect(item.bounds.center.dy, inInclusiveRange(layer.info.top - 12 * LilyPondScore.unit, layer.info.top + 16 * LilyPondScore.unit));
      }
    }
    expect(display.barlines.items, isNotEmpty);
    // The lyrics are the voice's (staff 5), the tempo mark the flute's.
    final texts = [for (final layer in display.staves) for (final item in layer.items) if (item is ParagraphItem) (layer.info.n, item)];
    expect(texts.where((t) => t.$1 == 5), isNotEmpty);
    final tempo = data.sourceIds.indexOf('ly-tempo-52');
    expect(tempo, isNonNegative);
    final staffOfTempo = {
      for (var i = 0; i < data.commandCount; i++)
        if (data.commandInts[i * Cmd.words + Cmd.source] == tempo) data.commandInts[i * Cmd.words + Cmd.staff],
    };
    expect(staffOfTempo, {1});
    display.dispose();
  });

  test('a run of text is drawn no wider than LilyPond spaced it: the tempo mark’s word keeps clear of its "("', () async {
    // The fixture's text was spaced in Times, LilyPond's own serif with the SVG backend on a Mac
    // (Curator's settings give it Academico now); drawn in Academico, "Allegro" is wider.
    final academico = FontLoader('packages/score_engine/Academico');
    for (final face in ['Regular', 'Bold']) {
      academico.addFont(File('assets/fonts/Academico-$face.otf').readAsBytes().then(ByteData.sublistView));
    }
    await academico.load();
    double at(int i, int word) => data.commandFloats[i * Cmd.words + word];
    final tempo = data.sourceIds.indexOf('ly-tempo-52');
    // "Allegro", " (", the note, " = 120)".
    final runs = [
      for (var i = 0; i < data.commandCount; i++)
        if (data.commandInts[i * Cmd.words + Cmd.kind] == VBKind.text && data.commandInts[i * Cmd.words + Cmd.source] == tempo) i,
    ];
    expect(runs, hasLength(3));
    final [allegro, open, rest] = runs;
    expect(at(allegro, Cmd.fitWidth), closeTo(at(open, Cmd.x) - at(allegro, Cmd.x), 1e-3));
    expect(at(open, Cmd.fitWidth), inExclusiveRange(0, at(rest, Cmd.x) - at(open, Cmd.x))); // as far as the note
    expect(at(rest, Cmd.fitWidth), 0); // nothing after it
    final natural = (ui.ParagraphBuilder(ui.ParagraphStyle())
          ..pushStyle(ui.TextStyle(fontFamily: 'packages/score_engine/Academico', fontSize: at(allegro, Cmd.size), fontWeight: ui.FontWeight.bold))
          ..addText('Allegro'))
        .build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    expect(natural.maxIntrinsicWidth, greaterThan(at(allegro, Cmd.fitWidth) * 1.05));

    final display = ScoreDisplayList.build(data, const RenderStyle());
    final drawn = [
      for (final layer in display.staves)
        for (final item in layer.items)
          if (item is ParagraphItem && item.sourceId == 'ly-tempo-52') item,
    ];
    expect(drawn, hasLength(3));
    final word = drawn.singleWhere((p) => (p.bounds.left - at(allegro, Cmd.x)).abs() < 1e-3);
    expect(word.bounds.right, lessThanOrEqualTo(at(open, Cmd.x) + 1e-3));
    expect(word.bounds.width, greaterThan(at(allegro, Cmd.fitWidth) * 0.98)); // set closer, as wide as it was spaced
    display.dispose();
  });

  test('the score written for it plays: pitches, transposition, ties and the piano\'s voices', () {
    final starts = [0.0];
    for (final m in data.measures) {
      starts.add(starts.last + m.duration);
    }
    final notes = soundingNotes(score.musicXML, starts).toList();
    final flute = [for (final n in notes) if (n.partId == 'P1') n];
    expect((flute.first.midi, flute.first.start, flute.first.end), (74, 0.0, 1.0)); // d''
    // e2.~ e4: tied on into the next bar.
    final tied = flute.singleWhere((n) => n.tied);
    expect(flute.where((n) => n.midi == tied.midi && n.end == tied.start), hasLength(1));
    expect(tied.start, 13);
    // The B♭ clarinet's written a' sounds g'.
    final clarinet = [for (final n in notes) if (n.partId == 'P2') n];
    expect(clarinet.first.midi, 67);
    // The piano: the crossing note is the upper staff's voice drawn on the lower staff.
    final piano = [for (final n in notes) if (n.partId == 'P3') n];
    final crossing = piano.where((n) => n.start >= 11 && n.start < 13 && n.staff == 2).toList();
    expect(crossing.map((n) => n.midi), [43, 45]); // g,, a (from d')
    expect(piano.where((n) => n.start == 4 && n.staff == 2).map((n) => n.midi).toSet(), {48, 36}); // the two voices' c and C
    // The tuplet's notes a third of a crotchet each.
    final tuplet = piano.where((n) => n.start >= 4 && n.start < 5 && n.staff == 1).toList();
    expect([for (final n in tuplet) n.end - n.start], [for (final _ in tuplet) closeTo(1 / 3, 1e-9)]);
    expect(metadata.tempo, 120);
  });

  test('repeats and endings, marks and texts', () {
    final form = metadata.form;
    expect(form.bars[1].forward, isTrue);
    expect(form.bars[2].backward, 2);
    expect(form.bars[2].endings, {1});
    expect(form.bars[3].endings, {2});
    expect(form.playedOrder(), [0, 1, 2, 1, 3, 4, 5, 6]);
    final texts = PreparedScore.prepare(ScoreMetadata.parse(score.musicXML), const {}).texts;
    expect([for (final t in texts) (t.id, t.text, t.kind)], containsAll([
      ('ly-tempo-52', 'Allegro', ScoreTextKind.tempo),
      ('ly-mark-481-reh', 'A', ScoreTextKind.rehearsal),
      ('ly-text-618', 'rit.', ScoreTextKind.direction),
    ]));
    // What sets them apart finds them drawn.
    final display = ScoreDisplayList.build(data, const RenderStyle(), apart: {'ly-tempo-52': 'ly-tempo-52', 'ly-mark-481-reh': 'ly-mark-481-reh'});
    expect([for (final a in display.apart) a.id], ['ly-tempo-52', 'ly-mark-481-reh']);
    display.dispose();
  });

  test('a click finds where in the source a note is', () {
    final first = data.measures.first.onsetXs.first;
    final staff = data.staves.first;
    final link = score.linkAt(Offset(first + LilyPondScore.unit / 2, staff.top + LilyPondScore.unit), staff: 1);
    expect(link, isNotNull);
    expect((link!.file, link.line), ('/score/fixture.ly', 14)); // \partial 4 d4
    expect(score.links.map((l) => l.bounds.left), orderedEquals([...score.links.map((l) => l.bounds.left)]..sort()));
  });

  test('loads as a score, and a vertical spacer gets a staff of its own', () async {
    const spacer = VerticalSpacer(id: 'spacer-1', key: SpacerKey.bFlat, lines: true);
    final loaded = LilyPondScore.read(File('test/lilypond/fixture.svg').readAsStringSync(), File('test/lilypond/fixture.jsonl').readAsStringSync());
    final plain = LoadedScore.fromLilyPond(loaded, const EngraveRequest());
    expect(plain.duration, greaterThan(0));
    expect(plain.lilypond, same(loaded));
    expect(plain.condensed, isEmpty);
    final spaced = LoadedScore.fromLilyPond(loaded, const EngraveRequest(spacers: [spacer]));
    final n = spaced.metadata.parts.last.staffNumbers.single;
    expect(spaced.metadata.parts.last.id, 'spacer-1');
    expect([for (final s in spaced.engraving.staves) s.n], [1, 2, 3, 4, 5, 6, n]);
    final keys = [for (final s in spaced.engraving.signatures) if (s is KeySignature && s.staff == n) s.fifths];
    expect(keys, [3, 1]); // the flute's G and F majors, for a B♭ instrument
    final display = ScoreDisplayList.build(spaced.engraving, const RenderStyle());
    expect(display.staves.last.lines, hasLength(5));
    display.dispose();
    final again = await plain.withRequest(const EngraveRequest(spacers: [spacer]));
    expect(again.engraving.staves.length, 7);
    expect(again.lilypond, same(loaded));
  });
}
