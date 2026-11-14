// The Chapters extension (assets/extensions/chapters): a package, written in Lua, that does
// what the chapters written in the app did. While both were here, every step below was
// compared with the app's own (the project's file, the selection, the lane, a video's
// chapters); what the app's gave is kept as a digest.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/extensions/extension_reader.dart';
import 'package:curated_score/l10n/l10n.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/project_document.dart';
import 'package:curated_score/project_modules.dart';
import 'package:curated_score/project_state.dart';
import 'package:curated_score/score_replacement.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';
import 'window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the package does what the app’s own chapters did, edit for edit', () async {
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
  });

  test('a project’s chapters are checked as it opens, and go with a score that replaces its own', () {
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
          (q) => ScoreSwap.quarterAt(q, before, after));
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
  });

  testWidgets('the Chapters lane: its buttons, its dialog, Delete', (tester) async {
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
    Object? saved() => c.extensions.data('chapters');

    expect(find.byTooltip('Add Chapter'), findsNothing);
    c.setExtension('chapters', true);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Chapters'), findsOneWidget);
    IconButton button(String tooltip) => tester.widget<IconButton>(find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton)).first);
    expect(button('Remove Chapter').onPressed, isNull, reason: 'nothing is selected');

    // Add Chapter: named in a dialog, from the beat the playhead is in.
    c.playback.seek(0);
    await tester.tap(find.byTooltip('Add Chapter'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Add Chapter'), findsOneWidget);
    final add = find.widgetWithText(FilledButton, 'Add');
    expect(tester.widget<FilledButton>(add).onPressed, isNull, reason: 'no name yet');
    await tester.enterText(find.byType(EditableText).first, 'Opening');
    await tester.pump();
    await tester.enterText(find.byType(EditableText).last, 'x');
    await tester.pump();
    expect(find.text('Enter a bar or bar.beat, like 12 or 12.3'), findsOneWidget);
    expect(tester.widget<FilledButton>(add).onPressed, isNull);
    await tester.enterText(find.byType(EditableText).last, '${c.timeline.measureStarts.length}'); // the bar after the last
    await tester.pump();
    expect(find.text('Set From before the end'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).last, '5');
    await tester.pump();
    await screenshot(tester, 'chapter-dialog');
    await tester.tap(add);
    await tester.pump(const Duration(milliseconds: 300));
    final starts = c.timeline.measureStarts;
    expect(saved(), {
      'chapters': [
        [starts[4], 'Opening'],
      ],
    });
    expect(c.extensions.selectedIn('chapters', 'lane'), 0, reason: 'a new chapter is selected');
    expect(button('Remove Chapter').onPressed, isNotNull);
    await screenshot(tester, 'chapter-lane');

    // Another can't start where one does.
    await tester.tap(find.byTooltip('Add Chapter'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(EditableText).first, 'Again');
    await tester.enterText(find.byType(EditableText).last, '5');
    await tester.pump();
    expect(find.text('Another chapter starts here'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump(const Duration(milliseconds: 300));

    // Delete removes the selected one; Undo brings it back.
    expect(c.commands.canDelete, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump(const Duration(milliseconds: 50));
    expect(saved(), {'chapters': <Object?>[]});
    c.undo();
    await tester.pump(const Duration(milliseconds: 50));
    expect((saved()! as Map)['chapters'], hasLength(1));
    expect(c.extensions.problems.value, isEmpty);
    expect('Start'.tr, isNotEmpty);
  });
}
