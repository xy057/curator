// Curator's own extensions are packages, written in Lua, that do what the code written in the app
// did before each was ported: Chapters, Tonality, Captions and Attach Image. While both were
// here, every step below was compared with the app's own (the project's file, the selection, the
// lane, what a damaged project says, what Replace Score keeps, a video's chapters and subtitles,
// what Find Keys hears); what the app's own gave is kept as digests, the package held to them.
// The generators of the edits are captions_cases.dart and images_cases.dart, and those below.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/controller_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/extensions/bundled.dart';
import 'package:curated_score/extensions/extension_lane.dart';
import 'package:curated_score/extensions/extension_reader.dart';
import 'package:curated_score/image_patch.dart';
import 'package:curated_score/l10n/l10n.dart';
import 'package:curated_score/project_document.dart';
import 'package:curated_score/project_modules.dart';
import 'package:curated_score/project_state.dart';
import 'package:curated_score/score_replacement.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show Color;
import 'package:score_engine/score_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'captions_cases.dart';
import 'demo_project.dart';
import 'images_cases.dart' hide barsBefore, barsAfter, carriedQuarter;

/// Where what the package gives is written in full, to set beside what the app's own gave.
final transcripts = Platform.environment['TRANSCRIPT_DIR'];

/// [text] is what the app's own gave: [length] long, with the digest [sha].
void held(String name, String text, int length, String sha) {
  if (transcripts case final dir?) return File('$dir/$name.txt').writeAsStringSync(text);
  expect((text.length, '${sha256.convert(utf8.encode(text))}'), (length, sha), reason: name);
}

LuaTable caption(Cap c) => LuaTable.map({'from': c.$1, 'to': c.$2, 'text': c.$3});
Cap cap(Object? t) => (((t! as LuaTable)['from']! as num).toDouble(), ((t as LuaTable)['to']! as num).toDouble(), t['text']! as String);

/// The package's own functions, and its lane as the editor drives it.
class PackageSide implements CaptionSide {
  PackageSide(this.c) : runtime = c.extensions.runtime('captions')!;
  final EditorController c;
  final ExtensionRuntime runtime;
  late final _captions = runtime.module('captions.lua')! as LuaTable;
  late final model = ExtensionSpans(c, runtime, runtime.graph.node('lane')!);

  List<Object?> _call(String fn, List<Object?> args) => runtime.lua.call(_captions[fn]! as LuaFunction, args, ExtensionRuntime.eventSteps);

  @override
  void add(Cap c) => _call('add', [caption(c)]);
  @override
  void update(int index, Cap c) => _call('update', [index + 1, caption(c)]);
  @override
  void replaceAll(List<Cap> captions) => _call('replace_all', [LuaTable.list([for (final c in captions) caption(c)])]);
  @override
  void remove([int? index]) => _call('remove', [index == null ? null : index + 1]);
  @override
  int? get selected => c.extensions.selectedIn('captions', 'lane');
  @override
  void select(int? index) => model.select(index);
  @override
  (double, double)? draft(double quarter, [List<(double, double)>? among]) {
    final d = _call('draft', [quarter, among == null ? null : LuaTable.list([for (final (a, b) in among) caption((a, b, ''))])]).firstOrNull;
    return d == null ? null : (cap(d).$1, cap(d).$2);
  }

  @override
  void laneBegin() => model.begin();
  @override
  void laneUpdate(int index, double start, double end) => model.update(index, start, end);
  @override
  void laneReplaceAll(List<({int from, double start, double end})> pieces) => model.replaceAll(pieces);
  @override
  List<String> lane() => [for (final (i, s) in model.spans.indexed) '${s.start}–${s.end} ${model.label(i)}'];
}

class PackageSubtitles implements SubtitleSide {
  PackageSubtitles(this.runtime);
  final ExtensionRuntime runtime;
  late final _subtitles = runtime.module('subtitles.lua')! as LuaTable;

  Object? _call(String fn, List<Object?> args) => runtime.lua.call(_subtitles[fn]! as LuaFunction, args, ExtensionRuntime.eventSteps).firstOrNull;
  LuaTable _cues(List<Cue> cues) => LuaTable.list([for (final c in cues) caption(c)]);

  @override
  List<Cue> parse(String source) {
    try {
      return [for (final c in (_call('parse', [source])! as LuaTable).array) cap(c)];
    } on LuaError catch (e) {
      throw FormatException(e.message);
    }
  }

  @override
  String write(List<Cue> cues, String format) => _call('write', [_cues(cues), format])! as String;
  @override
  List<Cap> fromCues(List<Cue> cues) => [for (final c in (_call('to_captions', [_cues(cues)])! as LuaTable).array) cap(c)];
  @override
  List<Cue> cues(List<Cap> captions, {double from = 0, double? to}) => [for (final c in (_call('cues', [_cues(captions), from, to])! as LuaTable).array) cap(c)];
}

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

  test('Curator’s own extensions do what the app’s own did: Chapters, Tonality and Find Keys, Captions and subtitle files, Attach Image', () async {
    // Chapters: the package does what the app’s own chapters did, edit for edit.
    {
      final c = EditorController(vsync: const TestVSync());
      final doc = ProjectDocument(c, AppSettings.memory()..autosave = Duration.zero);
      addTearDown(() {
        doc.dispose();
        c.dispose();
      });
      await doc.importScore(demoScore.path);
      c.setExtension('chapters', true);
      final runtime = c.extensions.runtime('chapters')!;
      expect(c.extensions.problems.value, isEmpty);
      final module = runtime.module('lane.lua')! as LuaTable, lane = runtime.graph.node('lane')!;
      void lua(String fn, List<Object?> args) => runtime.lua.call(module[fn]! as LuaFunction, args, ExtensionRuntime.eventSteps);
      List<LaneItem> chapters() => c.extensions.items(runtime, lane);
      int? selected() => c.extensions.selectedIn('chapters', 'lane');

      final starts = c.score!.timeline.measureStarts, total = starts.last;
      final random = Random(7);
      const names = [
        'Opening', '  Second   theme ', '', '   ', 'A\tB\nC', 'é 　name', '\u0085x\u0085', 'Coda', 'Trio', 'B = 2; #x\\',
        'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx😀yyyyyyyyyyyy',
      ];
      double place() => switch (random.nextInt(10)) {
            0 => -3.0,
            1 => total,
            2 => total + 5,
            3 => total - 0.1,
            4 => double.infinity,
            5 => starts[random.nextInt(starts.length)] + random.nextDouble(),
            6 => starts[random.nextInt(starts.length)] + 1e-7,
            _ => starts[random.nextInt(starts.length)],
          };

      final seen = StringBuffer();
      void see() {
        final end = c.timeline.endSeconds;
        final ranges = [(0.0, end), (3.0, end - 2), (end / 2, end / 2 + 4), (0.0, end + 10)];
        final readers = c.extensions.readers();
        seen.writeln([
          jsonEncode(ProjectModules.chapters.write(c.projectState, (entry, bytes, {compress = true}) {})),
          selected(),
          c.extensions.canRun(runtime, runtime.graph.node('marks')!),
          c.extensions.canRun(runtime, runtime.graph.node('remove')!),
          [for (final item in chapters()) (item.at, item.label)],
          [for (final s in c.extensions.spans(runtime, lane, end: end + 1)) s],
          for (final (from, to) in ranges) readers.chapters(from, to),
          for (final (from, to) in ranges) chapterMetadata(readers.chapters(from, to)),
          chapterTimestamps(readers.chapters(0, end)),
        ].join('\n'));
      }

      see();
      for (var step = 0; step < 400; step++) {
        final count = chapters().length;
        final what = random.nextInt(count == 0 ? 2 : 9);
        switch (what) {
          case 0 || 1 || 2:
            final at = place(), name = names[random.nextInt(names.length)];
            lua('create', [at, name]);
          case 3 || 4:
            final i = random.nextInt(count + 1), at = random.nextBool() ? place() : (i < count ? chapters()[i].at : 0.0);
            lua('change', [i + 1, at, names[random.nextInt(names.length)]]);
          case 5:
            lua('delete', [random.nextInt(count + 1) + 1]);
          case 6:
            c.extensions.select('chapters', 'lane', random.nextInt(count));
          case 7:
            final i = random.nextInt(count), at = chapters()[i].at + random.nextDouble() - 0.5;
            lua('move', [i + 1, at]);
          case 8:
            if (selected() != null) {
              c.extensions.removeSelected();
            } else {
              lua('add_marks', const []);
            }
        }
        see();
      }
      expect(c.extensions.problems.value, isEmpty);
      expect(chapters(), isNotEmpty);
      expect(seen.length, 1036613);
      expect('${sha256.convert(utf8.encode(seen.toString()))}', 'a47df1a3d7fb171651e9b70e1979afb3ff373d16ddc108cf935b49f627ad44e5');

      // Each edit is one Undo step, and Undo tells the lane.
      final before = chapters();
      lua('create', [starts[3] + 0.5, 'One more']);
      expect(chapters().length, before.length + 1);
      c.undo();
      expect(chapters(), before);
      expect(selected(), isNull, reason: 'what was selected may be gone');
      c.redo();
      expect(chapters().map((item) => item.label), contains('One more'));
    }

    // Chapters: a project’s chapters are checked as it opens, and go with a score that replaces its own.
    {
      const state = ProjectState();
      String read(Object? json) {
        try {
          final s = ProjectModules.chapters.read(JsonReader(json, 'chapters'), state, (entry, {required limit}) => null);
          return jsonEncode(checkedExtensionData(s).edits.extensionData['chapters']);
        } on FormatException catch (e) {
          return e.message;
        }
      }

      expect(read(null), 'null', reason: 'a project without the module');
      expect(read({'chapters': <Object?>[]}), '{"chapters":[]}');
      expect(read({'chapters': [[0, 'A'], [8.5, ' B  b '], [8.5, 'C'], [4, '  ']]}), '{"chapters":[[0.0,"A"],[8.5,"C"]]}');
      expect(read({'chapters': [[12, 'Late'], [3, 'Early']]}), '{"chapters":[[3.0,"Early"],[12.0,"Late"]]}');
      expect(read({'chapters': 5}), 'The project is damaged: chapters.chapters is not a list.');
      expect(read({'chapters': [[0, 'A'], [-1, 'B']]}), 'The project is damaged: chapters.chapters[1] starts before the score.');
      for (final entry in <Object?>[['x', 'B'], [1, 2], [1, 'B', 3], null, 5, {'at': 1}, [1e12, 'A'], [double.infinity, 'A']]) {
        expect(read({'chapters': [[0, 'A'], entry]}), 'The project is damaged: chapters.chapters[1] is not a place and a name.', reason: '$entry');
      }

      // Bars of 4 quarters become bars of 3, and the score ends at bar 6: a chapter keeps its bar
      // and how far into it it is, no further than the bar's end; one past the end is lost.
      final before = [for (var i = 0; i <= 12; i++) i * 4.0], after = [for (var i = 0; i <= 6; i++) i * 3.0];
      ({String data, List<String> lost}) carried(List<List<Object>> chapters) {
        final r = carriedExtensionData(state.copyWith(edits: state.edits.copyWith(extensionData: {'chapters': {'chapters': chapters}})),
            (q) => ScoreSwap.quarterAt(q, before, after), end: after.last);
        return (data: jsonEncode(r.state.edits.extensionData['chapters']), lost: r.lost);
      }

      var r = carried([[0.0, 'A'], [9.0, 'B'], [11.5, 'C'], [20.0, 'D']]);
      expect(r.data, '{"chapters":[[0.0,"A"],[7.0,"B"],[9.0,"C"],[15.0,"D"]]}');
      expect(r.lost, isEmpty);
      r = carried([[0.0, 'A'], [30.0, 'B'], [40.0, 'C']]);
      expect(r.data, '{"chapters":[[0.0,"A"]]}');
      expect(r.lost, ['2 chapters']);
      expect(carried([[26.0, 'A']]).lost, ['1 chapter']);
      expect(carried([]).data, '{"chapters":[]}');
    }

    // Tonality: the package does what the app’s own key areas did, edit for edit.
    {
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
      Strings.use(AppLanguage.english); // the edits switched to Chinese now and then
    }

    // Tonality: Find Keys hears what the app’s own did.
    {
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
    }

    // Tonality: a project’s key areas are checked as it opens, and go with a score that replaces its own.
    {
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
    }

    // Tonality: a key is named and coloured by its tonic; areas are kept in order, one over another.
    {
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
    }

    // Captions: edits, subtitle files, damaged projects, replaced scores.
    {
      final c = EditorController(vsync: const TestVSync());
      final doc = ProjectDocument(c, AppSettings.memory()..autosave = Duration.zero);
      addTearDown(() {
        doc.dispose();
        c.dispose();
      });
      await doc.importScore(demoScore.path);
      c.setExtension('captions', true);
      expect(c.extensions.problems.value, isEmpty);
      final runtime = c.extensions.runtime('captions')!;

      final edits = captionEdits(PackageSide(c), c, Random(21), 700);
      expect(c.extensions.problems.value, isEmpty);
      held('edits', edits, 413513, 'b3688fbbf4cf7c49dea26308c2454a013cab9d1c890259209bf2f9d02c6fa231');

      // A video's subtitles: the captions as a SubRip file, those the video shows.
      final side = PackageSide(c), subtitles = PackageSubtitles(runtime);
      side.replaceAll([(0, 4, 'One'), (8, 12, '*Two*')]);
      final end = c.timeline.endSeconds, now = savedCaptions(c);
      expect(c.extensions.exportsSubtitles, isTrue);
      expect(c.extensions.readers().subtitles(0, end), subtitles.write(subtitles.cues(now), 'srt'));
      expect(c.extensions.readers().subtitles(0, end), startsWith('1\n00:00:00,000 --> '));
      expect(c.extensions.readers().subtitles(1, 3), subtitles.write(subtitles.cues(now, from: 1, to: 3), 'srt'));
      expect(c.extensions.readers().captions, c.sceneSettings.captions);
      // A project uses Captions once it has a caption, or a font chosen for them.
      expect(c.extensions.uses('captions'), isTrue);
      side.replaceAll(const []);
      expect(c.extensions.exportsSubtitles, isFalse);
      expect(c.extensions.readers().subtitles(0, end), isNull);
      expect(c.extensions.uses('captions'), isFalse);
      c.captions.setFont(TextFonts.academico);
      expect(c.extensions.uses('captions'), isTrue);
      expect(c.captions.style.fontFamily, TextFonts.familyOf(TextFonts.academico));

      final files = subtitleFiles(PackageSubtitles(runtime), Random(8), 300, end: c.timeline.endSeconds);
      held('subtitles', files, 188909, '58f49f86be8aabfa2ef9ccbcdbef40c1d8e6e6df7a61aca6b7240f11727296be');

      final random = Random(4);
      final loaded = [for (final json in captionModules(random)) readCaptions(json)].join('\n');
      held('load', loaded, 5800, 'b52705171e93454b0e7c6b45d4df4029b01a657a02814dd673fa06ba9eace7f4');

      // A score replaced by another: the captions go where their places are, cut at its end.
      final package = BundledExtensions.byId('captions')!;
      final module = ExtensionRuntime(package, ReadingHost(package, null)).module('captions.lua')! as LuaTable;
      final lua = Lua();
      final carried = StringBuffer();
      for (final list in captionsToCarry(random)) {
        final apart = lua.call(module['separate']! as LuaFunction, [LuaTable.list([for (final cap in list) caption(cap)])], 100000).single;
        final stored = LuaJson.fromLua(lua.call(module['data']! as LuaFunction, [apart], 100000).single);
        const state = ProjectState();
        final r = carriedExtensionData(state.copyWith(edits: state.edits.copyWith(extensionData: {'captions': stored})), carriedQuarter, end: barsAfter.last);
        final kept = [
          for (final row in ((r.state.edits.extensionData['captions']! as Map)['captions']! as List<Object?>).cast<List<Object?>>())
            ((row[0]! as num).toDouble(), (row[1]! as num).toDouble(), row[2]! as String),
        ];
        carried.writeln('$kept ${r.lost}');
      }
      held('carry', '$carried', 2667, '5768a930df44a7b598d9698a377bc7a94ff82a71eec97f75128fac947632e5c9');
    }

    // Captions: how captions looked before Captions was a package is how they look after.
    {
      SharedPreferences.setMockInitialValues({'captionCountdown': 'ring', 'captionPlate': true, 'captionFont': 'Academico'});
      final settings = await AppSettings.load();
      expect(settings.extensionSettings('captions'), {'font': 'Academico', 'countdown': 'ring', 'plate': true});
      final c = EditorController(vsync: const TestVSync())
        ..extensionSettings = settings.extensionSettings
        ..saveExtensionSettings = settings.setExtensionSettings;
      final doc = ProjectDocument(c, settings..autosave = Duration.zero);
      addTearDown(() {
        doc.dispose();
        c.dispose();
      });
      await doc.importScore(demoScore.path);
      c.setExtension('captions', true);
      expect(c.captions.style, CaptionStyle(fontFamily: TextFonts.familyOf(TextFonts.academico), countdown: CaptionCountdown.ring, plate: true));
      // Kept as the extension's own from then on.
      c.extensions.runtime('captions')!.run('local s = require("settings").get()\ns.size = "small"\ncurator.save_settings(s)');
      expect(settings.extensionSettings('captions'), {'font': 'Academico', 'countdown': 'ring', 'size': 'small', 'align': 'center', 'plate': true});
      c.takeSettings(settings);
      expect(c.captions.style.size, CaptionSize.small);
    }

    // Attach Image: edits made at random, damaged projects and replaced scores.
    {
      final c = EditorController(vsync: const TestVSync());
      final doc = ProjectDocument(c, AppSettings.memory()..autosave = Duration.zero);
      addTearDown(() {
        doc.dispose();
        c.dispose();
      });
      await doc.importScore(demoScore.path);
      c.setExtension('attachImage', true);
      held('edits', await imageEdits(c, Random(33), 900), 4313324, '53c7ac4597df8154ef17ddc7a406bebc75731293a27e146ca2f44a5abbec50a7');
      held('load', [for (final json in imageModules(Random(5))) readImages(json)].join('\n'), 32336, '6feff48aa32d75de6e3517f3173ec671d5955e931948e68bd08f2f9ecffecea1');
      held('carry', carriedImages(Random(6), (state) => carriedExtensionData(state, carriedQuarter, end: barsAfter.last)), 14011,
          'f609ecaee0daa639d7c578960037402a16560efc00b911ae7b16a9f13d5aadbc');
    }

    // Attach Image: the files another extension’s pictures show are kept beside its own.
    {
      final own = PatchImage('a.png', ImageKind.raster, widePng), other = PatchImage('b.svg', ImageKind.vector, svgBytes);
      final state = ProjectState(
        edits: const EditState(extensionData: {
          'attachImage': {
            'patches': [
              {'image': 'a.png', 'quarter': 4.0, 'top': 2.0, 'width': 8.0, 'height': 4.0},
            ],
          },
        }),
        images: {'a.png': own, 'b.svg': other},
      );
      final files = <String, Uint8List>{};
      final json = ProjectModules.images.write(state, (entry, bytes, {compress = true}) => files[entry] = bytes);
      expect(json['files'], ['b.svg'], reason: 'named, as no patch of Attach Image’s does');
      expect(files.keys, ['images/a.png', 'images/b.svg']);
      final read = ProjectModules.images.read(JsonReader(jsonDecode(jsonEncode(json)), 'images'), const ProjectState(), (entry, {required limit}) => files[entry]);
      expect(read.images.keys, ['a.png', 'b.svg']);
      expect(read.edits.extensionData['attachImage'], state.edits.extensionData['attachImage'], reason: 'the extension’s data is its own: no list of files in it');
      // With only its own, the module is as it always was.
      expect(jsonEncode(ProjectModules.images.write(state.copyWith(images: {'a.png': own}), (entry, bytes, {compress = true}) {})),
          '{"patches":[{"image":"a.png","quarter":4.0,"top":2.0,"width":8.0,"height":4.0}]}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
