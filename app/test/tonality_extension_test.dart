// The Tonality extension (assets/extensions/tonality): a package, written in Lua, that does
// what the key areas written in the app did. While both were here, every step below was
// compared with the app's own (the project's file, the selection, the lane, the band and its
// colours, the buttons, what Find Keys hears, what a damaged project says, what Replace Score
// keeps), and the lane and its dialog pixel for pixel; what the app's gave is kept as digests.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/extensions/bundled.dart';
import 'package:curated_score/extensions/extension_lane.dart';
import 'package:curated_score/extensions/extension_reader.dart';
import 'package:curated_score/l10n/l10n.dart';
import 'package:curated_score/project_document.dart';
import 'package:curated_score/project_modules.dart';
import 'package:curated_score/project_state.dart';
import 'package:curated_score/score_replacement.dart';
import 'package:curated_score/dialog_kit.dart';
import 'package:curated_score/lanes_common.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/menu_kit.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';
import 'window.dart';

/// A score to hear keys in: [bars] bars of random length in [parts] parts, one of them a B♭
/// instrument, the music wandering from key to key with key signatures that follow some of
/// the changes; chords, ties, rests and a percussion part.
({String xml, List<double> starts}) randomScore(Random random, {required int bars, int parts = 3}) {
  const spell = [('C', 0), ('C', 1), ('D', 0), ('E', -1), ('E', 0), ('F', 0), ('F', 1), ('G', 0), ('A', -1), ('A', 0), ('B', -1), ('B', 0)];
  const major = [0, 2, 4, 5, 7, 9, 11], minor = [0, 2, 3, 5, 7, 8, 11];
  final lengths = [for (var b = 0; b < bars; b++) const [4, 4, 4, 3, 2, 6][random.nextInt(6)]];
  final starts = <double>[0];
  for (final l in lengths) {
    starts.add(starts.last + l);
  }
  // The key of each bar: (pitch class of the tonic, minor), changing now and then.
  final keys = <(int, bool)>[];
  var key = (random.nextInt(12), random.nextBool());
  for (var b = 0; b < bars; b++) {
    if (b > 0 && random.nextInt(9) == 0) key = ((key.$1 + const [7, 5, 3, 9, 2, 6][random.nextInt(6)]) % 12, random.nextInt(3) == 0 ? !key.$2 : key.$2);
    keys.add(key);
  }
  int fifthsOf((int, bool) k) {
    var f = ((k.$2 ? k.$1 + 3 : k.$1) * 7) % 12;
    if (f > 6) f -= 12;
    return f;
  }

  final out = StringBuffer('<score-partwise><part-list>');
  for (var p = 0; p < parts; p++) {
    out.write('<score-part id="P$p"><part-name>Part $p</part-name></score-part>');
  }
  out.write('</part-list>');
  for (var p = 0; p < parts; p++) {
    final transposing = p == 1, percussion = p == parts - 1 && parts > 2 && random.nextBool();
    out.write('<part id="P$p">');
    (int, bool)? signed;
    for (var b = 0; b < bars; b++) {
      out.write('<measure number="${b + 1}">');
      final changeSignature = b == 0 || (keys[b] != signed && random.nextInt(3) > 0 && !(p == 2 && random.nextInt(4) == 0));
      if (b == 0 || changeSignature) {
        signed = keys[b];
        var fifths = fifthsOf(keys[b]);
        if (transposing) fifths += 2;
        final mode = switch (random.nextInt(3)) { 0 => '', 1 => '<mode>${keys[b].$2 ? 'minor' : 'major'}</mode>', _ => '<mode>${random.nextBool() ? 'minor' : 'major'}</mode>' };
        out.write('<attributes>${b == 0 ? '<divisions>2</divisions>' : ''}<key><fifths>$fifths</fifths>$mode</key>'
            '${b == 0 && percussion ? '<clef><sign>percussion</sign></clef>' : ''}'
            '${b == 0 && transposing ? '<transpose><diatonic>-1</diatonic><chromatic>-2</chromatic></transpose>' : ''}</attributes>');
      }
      final scale = keys[b].$2 ? minor : major;
      var left = lengths[b] * 2; // in divisions
      var tied = false;
      while (left > 0) {
        final duration = min(left, const [1, 2, 2, 4, 3][random.nextInt(5)]);
        left -= duration;
        if (random.nextInt(8) == 0) {
          out.write('<note><rest/><duration>$duration</duration></note>');
          tied = false;
          continue;
        }
        final count = p == 0 ? 1 + random.nextInt(3) : 1;
        for (var n = 0; n < count; n++) {
          final degree = random.nextInt(10) < 8 ? const [0, 2, 4, 0, 4, 1, 3, 5, 6][random.nextInt(9)] : random.nextInt(7);
          var pitch = keys[b].$1 + scale[degree] + 12 * (3 + random.nextInt(3)) + (random.nextInt(14) == 0 ? 1 : 0);
          if (transposing) pitch += 2;
          final (step, alter) = spell[pitch % 12];
          out.write('<note>${n > 0 ? '<chord/>' : ''}'
              '${percussion ? '<unpitched><display-step>C</display-step><display-octave>5</display-octave></unpitched>' : '<pitch><step>$step</step>${alter == 0 ? '' : '<alter>$alter</alter>'}<octave>${pitch ~/ 12 - 1}</octave></pitch>'}'
              '<duration>$duration</duration>${tied && n == 0 ? '<tie type="stop"/>' : ''}</note>');
        }
        tied = random.nextInt(10) == 0;
      }
      out.write('</measure>');
    }
    out.write('</part>');
  }
  return (xml: '$out</score-partwise>', starts: starts);
}

/// Every key, as the app's own listed them: each key signature's major and minor, (tonic, minor).
final allKeys = [
  for (var s = -7; s <= 7; s++) ...[(s, false), (s + 3, true)],
];

typedef Area = ({double start, double end, int tonic, bool minor, String? label});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  void noFiles(String entry, List<int> bytes, {bool compress = true}) {}

  test('the package does what the app’s own key areas did, edit for edit', () async {
    final c = EditorController(vsync: const TestVSync());
    final doc = ProjectDocument(c, AppSettings.memory()..autosave = Duration.zero);
    addTearDown(() {
      doc.dispose();
      c.dispose();
      Strings.use(AppLanguage.english);
    });
    await doc.importScore(demoScore.path);
    c.setExtension('tonality', true);
    final runtime = c.extensions.runtime('tonality')!;
    expect(c.extensions.problems.value, isEmpty);
    final lane = runtime.graph.node('lane')!, model = ExtensionSpans(c, runtime, lane);
    final module = runtime.module('lane.lua')! as LuaTable, areasModule = runtime.module('areas.lua')! as LuaTable, keysModule = runtime.module('keys.lua')! as LuaTable;
    List<Object?> lua(String fn, List<Object?> args, [LuaTable? of]) => runtime.lua.call((of ?? module)[fn]! as LuaFunction, args, ExtensionRuntime.eventSteps);
    LuaTable area(Area a) => LuaTable.map({'from': a.start, 'to': a.end, 'tonic': a.tonic, 'minor': a.minor, 'label': ?a.label});
    List<LaneStretch> areas() => c.extensions.stretches(runtime, lane);
    int? selected() => c.extensions.selectedIn('tonality', 'lane');

    final starts = c.score!.timeline.measureStarts, total = starts.last;
    final random = Random(11);
    const labels = [null, null, null, '', '  ', ' (G) ', 'V of  V', 'A\tB\nC', 'é 　name', 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx😀yyyyyy', 'Dominant'];
    double place() => switch (random.nextInt(14)) {
          0 => -3.0,
          1 => total,
          2 => total + 5,
          3 => total - 0.1,
          4 => double.infinity,
          5 => starts[random.nextInt(starts.length)] + random.nextDouble(),
          6 => starts[random.nextInt(starts.length)] + 1e-7,
          7 => double.nan,
          8 => double.negativeInfinity,
          9 => 0.0,
          _ => starts[random.nextInt(starts.length)],
        };
    // One in twelve is a key there may not be.
    (int, bool) key() {
      if (random.nextInt(12) != 0) return allKeys[random.nextInt(allKeys.length)];
      final tonic = random.nextInt(40) - 20;
      return (tonic, random.nextBool());
    }

    Area newArea() {
      final a = place();
      final b = switch (random.nextInt(6)) { 0 => place(), 1 => a, 2 => a + 1e-7, _ => a + 1 + random.nextInt(24) };
      final (tonic, minor) = key();
      return (start: a, end: b, tonic: tonic, minor: minor, label: labels[random.nextInt(labels.length)]);
    }

    String colour(Color c) => '${c.a} ${c.r} ${c.g} ${c.b}';
    final probes = [0.0, 1e-7, starts[3], starts[7] + 0.5, total - 1, total, total + 4];
    final seen = StringBuffer();
    void see() => seen.writeln([
          jsonEncode(ProjectModules.tonality.write(c.projectState, noFiles)),
          selected(),
          [for (final s in areas()) '${s.start} ${s.end} ${s.label} ${colour(s.color!)}'],
          [for (final b in c.extensions.bands) '${b.start} ${b.end} ${b.label} ${colour(b.color)}'],
          c.extensions.canRun(runtime, runtime.graph.node('remove')!),
          c.extensions.canRun(runtime, runtime.graph.node('find')!),
          for (final q in probes)
            switch (lua('key_at', [q], areasModule)) {
              [final int tonic, final bool minor] => 'MusicKey(${lua('name', [tonic, minor], keysModule).single}) ${lua('next_start', [q], areasModule).single}',
              final other => '$other',
            },
        ].join('\n'));

    // Erasing q0–q1 out of stretches, as the lane does it.
    List<({int from, double start, double end})> erased(List<LaneStretch> from, double q0, double q1) => [
          for (final (i, s) in from.indexed)
            if (s.end <= q0 || s.start >= q1)
              (from: i, start: s.start, end: s.end)
            else ...[
              if (s.start < q0 - 0.125) (from: i, start: s.start, end: q0),
              if (s.end > q1 + 0.125) (from: i, start: q1, end: s.end),
            ],
        ];

    see();
    for (var step = 0; step < 600; step++) {
      final count = areas().length;
      final what = random.nextInt(count == 0 ? 3 : 16);
      switch (what) {
        case 0 || 1 || 2:
          lua('add', [area(newArea())]);
        case 3 || 4:
          final i = random.nextInt(count + 1);
          lua('reshape', [i + 1, area(newArea())]);
        case 5:
          lua('delete', [random.nextInt(count + 1) + 1]);
        case 6:
          final i = random.nextInt(count + 1) - 1;
          model.select(i < 0 ? null : i);
        case 7 || 8:
          // ← and →, by bars or beats.
          final direction = random.nextBool() ? 1 : -1, fine = random.nextBool();
          expect(c.extensions.nudgeSelected(direction, fine: fine), selected() != null);
        case 9:
          // [ and ], with the playhead somewhere.
          c.playback.seek(random.nextDouble() * (c.timeline.endSeconds + 2) - 1);
          c.extensions.trimSelected(start: random.nextBool());
        case 10 || 11:
          // A drag: an area moved or trimmed, over the areas as it found them.
          final before = areas(), i = random.nextInt(count);
          model.begin();
          for (var k = 0; k < 4; k++) {
            final was = before[i];
            final (start, end) = switch (random.nextInt(3)) {
              0 => (was.start + random.nextInt(9) - 4, was.end + random.nextInt(9) - 4),
              1 => (starts[random.nextInt(starts.length)], was.end),
              _ => (was.start, starts[random.nextInt(starts.length)]),
            };
            if (end - start < 0.25) continue;
            model.update(i, start, end);
            see();
          }
        case 12:
          // Erasing across the areas.
          final before = areas();
          model.begin();
          final q0 = starts[random.nextInt(starts.length)], q1 = q0 + random.nextInt(20) + 0.5;
          model.replaceAll(erased(before, q0, q1));
        case 13:
          c.extensions.removeSelected(); // Delete
        case 14:
          Strings.use(random.nextBool() ? AppLanguage.chineseSimplified : AppLanguage.english);
        case 15:
          if (c.canUndo) {
            c.undo();
            if (random.nextBool()) c.redo();
          }
      }
      see();
    }
    expect(c.extensions.problems.value, isEmpty);
    expect(areas(), isNotEmpty);
    expect(seen.length, 437272);
    expect('${sha256.convert(utf8.encode(seen.toString()))}', '9f2007f726183f13019a26d0f667a748891ebb5f02a2754a26f8fbecdf2a200d');
  });

  test('Find Keys hears what the app’s own did', () async {
    final c = EditorController(vsync: const TestVSync());
    final doc = ProjectDocument(c, AppSettings.memory()..autosave = Duration.zero);
    addTearDown(() {
      doc.dispose();
      c.dispose();
    });
    await doc.importScore(demoScore.path);
    c.setExtension('tonality', true);
    final runtime = c.extensions.runtime('tonality')!;
    final find = runtime.module('find.lua')! as LuaTable, keys = runtime.module('keys.lua')! as LuaTable;
    List<String> heard(String xml, List<double> starts) {
      final found = runtime.lua.call(find['keys']! as LuaFunction, [scoreMusicTable(readScoreMusic(xml, starts))], ExtensionRuntime.eventSteps).single! as LuaTable;
      return [
        for (final a in found.array.cast<LuaTable>())
          'KeyArea(${(a['from']! as num).toDouble()}–${(a['to']! as num).toDouble()}, ${runtime.lua.call(keys['name']! as LuaFunction, [a['tonic'], a['minor']], 1000).single})',
      ];
    }

    // Twice I IV V I in C, then twice in G with no new key signature, each bar a chord broken in quarters.
    String piece({int shift = 0, int fifths = 0}) {
      const spell = [('C', 0), ('C', 1), ('D', 0), ('D', 1), ('E', 0), ('F', 0), ('F', 1), ('G', 0), ('G', 1), ('A', 0), ('A', 1), ('B', 0)];
      const chords = [[60, 64, 67, 72], [65, 69, 72, 77], [67, 71, 74, 79], [60, 64, 67, 72]];
      final bars = [...chords, ...chords, for (var i = 0; i < 8; i++) [for (final n in chords[i % 4]) n + 7]];
      final out = StringBuffer('<score-partwise><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list><part id="P1">');
      for (final (b, chord) in bars.indexed) {
        out.write('<measure number="${b + 1}">');
        if (b == 0) out.write('<attributes><divisions>1</divisions><key><fifths>$fifths</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time></attributes>');
        for (final n in chord) {
          final (step, alter) = spell[(n + shift) % 12];
          out.write('<note><pitch><step>$step</step><alter>$alter</alter><octave>${(n + shift) ~/ 12 - 1}</octave></pitch><duration>1</duration></note>');
        }
        out.write('</measure>');
      }
      return '$out</part></score-partwise>';
    }

    final sixteen = [for (var b = 0; b <= 16; b++) b * 4.0];
    expect(heard(piece(), sixteen), ['KeyArea(0.0–32.0, C major)', 'KeyArea(32.0–64.0, G major)']);
    // A tritone higher, spelled with the key signature: among six flats G♭ to D♭, among six sharps F♯ to C♯.
    expect(heard(piece(shift: 6, fifths: -6), sixteen), ['KeyArea(0.0–32.0, G♭ major)', 'KeyArea(32.0–64.0, D♭ major)']);
    expect(heard(piece(shift: 6, fifths: 6), sixteen), ['KeyArea(0.0–32.0, F♯ major)', 'KeyArea(32.0–64.0, C♯ major)']);

    // The sample, sixty scores made at random, a score without notes (its key signatures
    // alone) and one without bars (nothing).
    final seen = StringBuffer();
    var changes = 0;
    void hear(String xml, List<double> starts) {
      final found = heard(xml, starts);
      changes += found.length;
      seen.writeln(found.join('\n'));
    }

    hear(c.score!.musicXML, c.score!.timeline.measureStarts);
    final random = Random(5);
    changes = 0;
    for (var i = 0; i < 60; i++) {
      final score = randomScore(random, bars: i == 0 ? 1 : 4 + random.nextInt(i < 50 ? 60 : 400), parts: 1 + random.nextInt(4));
      hear(score.xml, score.starts);
    }
    expect(changes, greaterThan(150), reason: 'the scores change key');
    final silent = randomScore(random, bars: 40).xml.replaceAll(RegExp('<note>.*?</note>'), '');
    hear(silent, [for (var b = 0; b <= 40; b++) b * 4.0]);
    hear(silent, [for (var b = 0; b <= 12; b++) b * 4.0]);
    hear(silent, [0]);
    expect(seen.length, 8711);
    expect('${sha256.convert(utf8.encode(seen.toString()))}', 'f4baec69d6dd9a26c4922d508fc8d5caeb2c1c19855c1ba41c549ed1490c710b');

    // The whole of it, in the editor: the score is read off to the side, then the keys found
    // replace those there are, one found where one was, in the same key, keeping its marking.
    final first = runtime.lua.call(find['keys']! as LuaFunction, [scoreMusicTable(readScoreMusic(c.score!.musicXML, c.score!.timeline.measureStarts))], ExtensionRuntime.eventSteps).single! as LuaTable;
    final home = first.array.first! as LuaTable;
    final add = (runtime.module('lane.lua')! as LuaTable)['add']! as LuaFunction;
    final findNode = runtime.graph.node('find')!, lane = runtime.graph.node('lane')!;
    List<LaneStretch> areas() => c.extensions.stretches(runtime, lane);
    Future<void> findKeys() async {
      expect(c.extensions.canRun(runtime, findNode), isTrue);
      runtime.fire('find', 'run');
      expect(c.extensions.canRun(runtime, findNode), isFalse, reason: 'it is reading the score');
      for (var i = 0; i < 200 && !c.extensions.canRun(runtime, findNode); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(c.extensions.canRun(runtime, findNode), isTrue);
      expect(c.extensions.problems.value, isEmpty);
      expect([for (final s in areas()) (s.start, s.end)], [for (final a in first.array.cast<LuaTable>()) (a['from'], a['to'])]);
    }

    runtime.lua.call(add, [LuaTable.map({'from': home['from'], 'to': home['to'], 'tonic': home['tonic'], 'minor': home['minor'], 'label': 'Home'})], ExtensionRuntime.eventSteps);
    await findKeys();
    expect(areas().first.label, 'Home', reason: 'found where it was, in its key: its marking stays');
    // Another key over its first bars: Find Keys puts back what it hears, in one Undo step.
    runtime.lua.call(add, [LuaTable.map({'from': home['from'], 'to': (home['from']! as num) + 8, 'tonic': (home['tonic']! as int) + 1, 'minor': home['minor'], 'label': 'Away'})],
        ExtensionRuntime.eventSteps);
    expect(areas().map((s) => s.label), ['Away', 'Home']);
    expect(c.extensions.selectedIn('tonality', 'lane'), 0);
    await findKeys();
    expect(areas().map((s) => s.label), isNot(contains('Away')));
    expect(c.extensions.selectedIn('tonality', 'lane'), isNull);
    c.undo();
    expect(areas().map((s) => s.label), ['Away', 'Home'], reason: 'one Undo step');
  });

  test('a project’s key areas are checked as it opens, and go with a score that replaces its own, as the app’s own were', () {
    const state = ProjectState();
    String read(Object? json) {
      try {
        final s = ProjectModules.tonality.read(JsonReader(json, 'tonality'), state, (entry, {required limit}) => null);
        return jsonEncode(checkedExtensionData(s).edits.extensionData['tonality']);
      } on FormatException catch (e) {
        return e.message;
      }
    }

    expect(read({'areas': [[0, 16, 0, 'major'], [4.0, 8.5, 1, 'minor', ' (G)  x '], [2, 3, -4, 'major', '']]}),
        '{"areas":[[0.0,2.0,0,"major"],[2.0,3.0,-4,"major"],[3.0,4.0,0,"major"],[4.0,8.5,1,"minor","(G) x"],[8.5,16.0,0,"major"]]}');
    expect(read({'areas': 5}), 'The project is damaged: tonality.areas is not a list.');
    expect(read({'areas': [[0, 8, 0, 'major'], [-1, 4, 0, 'major']]}), 'The project is damaged: tonality.areas[1] starts before the score.');
    expect(read({'areas': [[0, 8, 0, 'major'], [4, 4, 0, 'major']]}), 'The project is damaged: tonality.areas[1] ends before it starts.');
    expect(read({'areas': [[0, 8, 0, 'major'], [0, 4, 0, 'dorian']]}), 'The project is damaged: tonality.areas[1] is not a key there is.');
    expect(read({'areas': [[0, 8, 0, 'major'], [0, 4, 11, 'minor']]}), 'The project is damaged: tonality.areas[1] is not a key there is.');
    expect(read({'areas': [[0, 8, 0, 'major'], [0, 4, 1.5, 'major']]}), 'The project is damaged: tonality.areas[1] is not a stretch and a key.');

    final random = Random(3);
    final cases = <Object?>[
      {'areas': <Object?>[]},
      {'areas': [[0, 16, 0, 'major'], [4.0, 8.5, 1, 'minor', ' (G)  x '], [2, 3, -4, 'major', '']]},
      {'areas': [[12, 20, 3, 'minor'], [0, 14, -7, 'major', 'x' * 60]]},
      for (final entry in <Object?>[
        [-1, 4, 0, 'major'], [4, 4, 0, 'major'], [5, 4, 0, 'major'], [0, 4, 0, 'dorian'], [0, 4, 20, 'major'], [0, 4, 11, 'minor'], [0, 4, -5, 'minor'], //
        [0, 4, 1.5, 'major'], [0, 4, 0], [0, 4, 0, 'major', 'a', 'b'], [0, 4, 0, 'major', 5], [0, 4, 0, 'major', null], ['0', 4, 0, 'major'], [0, null, 0, 'major'],
        [1e12, 2e12, 0, 'major'], [0, 1e12, 0, 'major'], null, 5, 'x', {'from': 0}, <Object?>[], [0, 4, 0, 5], [-2, -4, 0, 'x'], [3, 1, 30, 'major'],
      ])
        {'areas': [[0, 8, 0, 'major'], entry]},
      for (var i = 0; i < 40; i++)
        {
          'areas': [
            for (var k = random.nextInt(8); k >= 0; k--)
              [random.nextInt(40) * (random.nextBool() ? 1 : 0.5), random.nextInt(60) + 0.25, random.nextInt(18) - 9, random.nextBool() ? 'major' : 'minor', if (random.nextBool()) ' m  $k '],
          ],
        },
    ];
    final seen = StringBuffer();
    for (final json in cases) {
      seen.writeln(read(json));
    }
    expect(seen.length, 4542);
    expect('${sha256.convert(utf8.encode(seen.toString()))}', 'bf43066c457012c4081e10880b6f470519c35664990c31e10d34b4820341f9ab');

    // Bars of 4 quarters become bars of 3, and the score ends at bar 6: an area keeps its bars
    // and how far into them it is, cut at the new end; one past it is lost.
    final before = [for (var i = 0; i <= 12; i++) i * 4.0], after = [for (var i = 0; i <= 6; i++) i * 3.0];
    ({String data, List<String> lost}) carry(List<List<Object>> areas) {
      final r = carriedExtensionData(state.copyWith(edits: state.edits.copyWith(extensionData: {'tonality': {'areas': areas}})),
          (q) => ScoreSwap.quarterAt(q, before, after), end: after.last);
      return (data: jsonEncode(r.state.edits.extensionData['tonality']), lost: r.lost);
    }

    var r = carry([[0.0, 8.0, 0, 'major'], [8.0, 22.0, 1, 'major', 'x'], [22.0, 48.0, 3, 'minor']]);
    expect(r.data, '{"areas":[[0.0,6.0,0,"major"],[6.0,17.0,1,"major","x"],[17.0,18.0,3,"minor"]]}');
    expect(r.lost, isEmpty);
    r = carry([[0.0, 8.0, 0, 'major'], [28.0, 32.0, 1, 'major'], [40.0, 48.0, 3, 'minor']]);
    expect(r.data, '{"areas":[[0.0,6.0,0,"major"]]}');
    expect(r.lost, ['2 keys']);
    expect(carry([[30.0, 48.0, 3, 'minor']]).lost, ['1 key']);

    // Sixty lists of areas made at random, tidied as the package keeps them.
    final package = BundledExtensions.byId('tonality')!;
    final areasModule = ExtensionRuntime(package, ReadingHost(package, null)).module('areas.lua')! as LuaTable;
    final lua = Lua();
    Object? tidied(List<Area> areas) {
      final list = LuaTable.list([for (final a in areas) LuaTable.map({'from': a.start, 'to': a.end, 'tonic': a.tonic, 'minor': a.minor, 'label': ?a.label})]);
      final tidy = lua.call(areasModule['tidy']! as LuaFunction, [list], 100000).single;
      return LuaJson.fromLua(lua.call(areasModule['data']! as LuaFunction, [tidy], 100000).single);
    }

    final carried = StringBuffer();
    for (var i = 0; i < 60; i++) {
      final areas = <Area>[];
      for (var k = random.nextInt(6) - 1; k >= 0; k--) {
        final start = random.nextInt(48) * 1.0;
        final (tonic, minor) = allKeys[random.nextInt(30)];
        final label = random.nextBool() ? 'm$k' : null;
        areas.add((start: start, end: start + 1 + random.nextInt(20), tonic: tonic, minor: minor, label: label));
      }
      final r = carriedExtensionData(state.copyWith(edits: state.edits.copyWith(extensionData: {'tonality': tidied(areas)})), (q) => ScoreSwap.quarterAt(q, before, after),
          end: after.last);
      carried.writeln('${jsonEncode(r.state.edits.extensionData['tonality'])} ${r.lost}');
    }
    expect(carried.length, 2808);
    expect('${sha256.convert(utf8.encode(carried.toString()))}', '16977cb6f7b7148a002e190312cbb7bd8a9c61f0995956178cf70916b8a8229e');
  });

  test('a key is named and coloured by its tonic; areas are kept in order, one over another', () {
    final package = BundledExtensions.byId('tonality')!;
    final runtime = ExtensionRuntime(package, ReadingHost(package, null));
    expect(runtime.problems, isEmpty);
    Object? value(String code) => runtime.run('local keys, areas = require("keys"), require("areas")\nreturn $code').firstOrNull;
    expect(value('#keys.all'), 30);
    expect([for (var i = 1; i <= 4; i++) value('keys.name(keys.all[$i].tonic, keys.all[$i].minor)')], ['C♭ major', 'A♭ minor', 'G♭ major', 'E♭ minor']);
    expect([value('keys.name(6, false)'), value('keys.name(-2, true)'), value('keys.name(13, false)'), value('keys.signature(3, true)'), value('keys.pitch_class(-1)')],
        ['F♯ major', 'B♭ minor', 'F♯♯ major', 0, 5]);
    expect(value('keys.color(6, false) == keys.color(-6, false)'), isTrue, reason: 'F♯ and G♭ major: one key spelled twice');
    expect(value('keys.color(0, false) ~= keys.color(0, true)'), isTrue);
    // One over another cuts it back or in two, as a region drawn over a lane's; empty and unknown keys go.
    expect(
        jsonEncode(LuaJson.fromLua(value('areas.data(areas.tidy({{from = 0, to = 16, tonic = 0, minor = false, label = " "}, {from = 4, to = 8, tonic = 1, minor = false, label = " (G) "}, '
            '{from = 2, to = 2, tonic = 2, minor = false}, {from = 4, to = 6, tonic = 20, minor = false}}))'))),
        '{"areas":[[0.0,4.0,0,"major"],[4.0,8.0,1,"major","(G)"],[8.0,16.0,0,"major"]]}');
  });

  testWidgets('the Tonality lane: its buttons, its dialog, the tools and the keys, the band over the score', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    final settings = AppSettings.memory()..addRecent(demoProject.absolute.path);
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Open Sample'));
    await tester.pump();
    final state = tester.state(find.byType(ProjectPage)) as dynamic;
    for (var i = 0; i < 100 && state.controller.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500));
    final c = state.controller as EditorController;
    List<Object?> saved() => ((c.extensions.data('tonality') ?? const {'areas': <Object?>[]}) as Map)['areas'] as List<Object?>;
    final starts = c.timeline.measureStarts, total = starts.last;

    expect(find.byTooltip('Add Key'), findsNothing);
    expect(c.scene!.bands, isEmpty);
    c.setExtension('tonality', true);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Tonality'), findsOneWidget);
    expect(find.byType(ExtensionSpanLane), findsOneWidget);
    IconButton button(String tooltip) => tester.widget<IconButton>(find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton)).first);
    expect(button('Remove Key').onPressed, isNull, reason: 'nothing is selected');
    expect(button('Find Keys').onPressed, isNotNull);

    // Add Key: from the beat the playhead is in to the end, C major until another is chosen.
    c.playback.seek(0);
    await tester.tap(find.byTooltip('Add Key'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Add Key'), findsOneWidget);
    expect(find.text('C major'), findsNWidgets(2), reason: 'the key chosen, and the marking’s hint');
    final add = find.widgetWithText(FilledButton, 'Add');
    await tester.enterText(find.byType(EditableText).first, 'x');
    await tester.pump();
    expect(find.text('Enter a bar or bar.beat, like 12 or 12.3'), findsOneWidget);
    expect(tester.widget<FilledButton>(add).onPressed, isNull);
    await tester.enterText(find.byType(EditableText).first, '3');
    await tester.enterText(find.byType(EditableText).at(1), '2');
    await tester.pump();
    expect(find.text('Set Until after From'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).at(1), '9');
    await tester.pump();
    // Another key: the hint follows it.
    await tester.tap(find.descendant(of: find.byWidgetPredicate((w) => w is AppDropdown), matching: find.byType(InkWell)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await screenshot(tester, 'key-menu', inside: find.byType(AppDialog), outermost: true);
    await tester.tap(find.text('D minor').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('D minor'), findsNWidgets(2));
    await tester.enterText(find.byType(EditableText).at(2), ' ii ');
    await tester.pump();
    await screenshot(tester, 'key-dialog', inside: find.byType(AppDialog), outermost: true);
    await tester.tap(add);
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved(), [
      [starts[2], starts[8], 2, 'minor', 'ii'],
    ]);
    expect(c.extensions.selectedIn('tonality', 'lane'), 0, reason: 'a new area is selected');
    expect(button('Remove Key').onPressed, isNotNull);
    expect(c.scene!.bands, hasLength(1));
    expect((c.scene!.bands.single.start, c.scene!.bands.single.end, c.scene!.bands.single.label), (starts[2], starts[8], 'ii'));

    // → moves it a bar, ⇧→ a beat; [ and ] trim it to the playhead's beat.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 50));
    expect(saved(), [
      [starts[3], starts[3] + (starts[8] - starts[2]), 2, 'minor', 'ii'],
    ]);
    c.undo();
    await tester.pump(const Duration(milliseconds: 50));
    c.extensions.select('tonality', 'lane', 0);
    c.playback.seek(c.timeline.secondsAtQuarter(starts[5]));
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump(const Duration(milliseconds: 50));
    expect(saved(), [
      [starts[5], starts[8], 2, 'minor', 'ii'],
    ]);

    // Drawn with the Draw tool across bars, over the first: it asks for the key, and what it
    // covers of the other is cut back.
    c.lanes.tool = LaneTool.draw;
    await tester.pump(const Duration(milliseconds: 50));
    final lane = tester.getRect(find.byType(ExtensionSpanLane));
    Offset at(double quarter) => Offset(lane.left + kLaneHeaderWidth + c.viewport.x(c.timeline.secondsAtQuarter(quarter)), lane.center.dy);
    final gesture = await tester.startGesture(at(starts[6] + 0.1), kind: PointerDeviceKind.mouse);
    await gesture.moveTo(at(starts[7]));
    await gesture.moveTo(at(starts[10] - 0.1));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Add Key'), findsOneWidget);
    await screenshot(tester, 'key-drawn', inside: find.byType(AppDialog), outermost: true);
    expect(find.text('D minor'), findsNWidgets(2), reason: 'the key the music is in there');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved(), hasLength(2));
    expect((saved()[0]! as List)[1], (saved()[1]! as List)[0], reason: 'the first ends where the second starts');
    expect(c.extensions.selectedIn('tonality', 'lane'), 1);
    c.lanes.tool = LaneTool.select;
    await screenshot(tester, 'tonality-lane');

    // Double-click opens it: Remove.
    c.extensions.runtime('tonality')!.fire('lane', 'open', args: [2]);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Key'), findsWidgets);
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved(), hasLength(1));

    // Delete removes the selected one; Undo brings it back.
    c.extensions.select('tonality', 'lane', 0);
    expect(c.commands.canDelete, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump(const Duration(milliseconds: 50));
    expect(saved(), isEmpty);
    expect(c.scene!.bands, isEmpty);
    c.undo();
    await tester.pump(const Duration(milliseconds: 50));
    expect(saved(), hasLength(1));

    // Find Keys: the sample is in A minor throughout; named in the interface's language.
    await tester.tap(find.byTooltip('Find Keys'));
    await tester.pump();
    expect(button('Find Keys').onPressed, isNull, reason: 'it is reading the score');
    for (var i = 0; i < 100 && button('Find Keys').onPressed == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(saved(), [
      [0.0, total, 3, 'minor'],
    ]);
    expect(c.scene!.bands.single.label, 'A minor');
    addTearDown(() => Strings.use(AppLanguage.english));
    settings.language = AppLanguage.chineseSimplified;
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(c.scene!.bands.single.label, 'A minor'.tr);
    expect('A minor'.tr, isNot('A minor'));
    // Off: the lane and the band go, the areas stay in the project; Undo turns it on again.
    c.setExtension('tonality', false);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(ExtensionSpanLane), findsNothing);
    expect(c.scene!.bands, isEmpty);
    expect(saved(), hasLength(1));
    c.undo();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(ExtensionSpanLane), findsOneWidget);
    expect(c.scene!.bands, hasLength(1));
    expect(c.extensions.problems.value, isEmpty);
  });
}
