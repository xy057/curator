// The Captions extension (assets/extensions/captions): a package, written in Lua, that does
// what the captions written in the app did. Before those were taken out, they were put through
// everything in captions_cases.dart (edits, subtitle files, damaged projects, replaced scores)
// and what they gave was written down; the package is held to it, as digests. The lane, the
// dialogs, the sheet and the settings were compared pixel for pixel.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/controller_settings.dart';
import 'package:curated_score/dialog_kit.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/extensions/bundled.dart';
import 'package:curated_score/extensions/extension_lane.dart';
import 'package:curated_score/extensions/extension_reader.dart';
import 'package:curated_score/extensions/extension_settings.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/project_document.dart';
import 'package:curated_score/project_state.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'captions_cases.dart';
import 'demo_project.dart';
import 'test_fonts.dart';
import 'window.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the package does what the app’s own captions did: edits, subtitle files, damaged projects, replaced scores', () async {
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
  });

  test('how captions looked before Captions was a package is how they look after', () async {
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
  });

  testWidgets('the Captions lane, its dialog, the sheet and the settings', (tester) async {
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
    final context = tester.element(find.byType(ProjectPage));
    final starts = c.timeline.measureStarts;
    c.setExtension('captions', true);
    final runtime = c.extensions.runtime('captions')!, side = PackageSide(c);
    List<Object?> saved() => (c.extensions.data('captions')! as Map)['captions']! as List<Object?>;
    side.replaceAll(const []);
    side.add((starts[0], starts[2], 'The *horns* answer'));
    side.add((starts[2], starts[4], '**Loud** and clear'));
    side.add((starts[6], starts[8], 'Plain'));
    c.playback.seek(c.timeline.secondsAtQuarter(starts[1]));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ExtensionSpanLane), findsOneWidget);
    expect(find.byTooltip('Pinned'), findsWidgets);
    expect(c.scene!.captions, hasLength(3));
    expect(c.scene!.captionShowingAt(c.playback.time.value), 0);
    await screenshot(tester, 'window');
    await screenshot(tester, 'lane', inside: find.byType(ExtensionSpanLane));
    c.extensions.select('captions', 'lane', 1);
    await tester.pump(const Duration(milliseconds: 100));
    await screenshot(tester, 'lane-selected', inside: find.byType(ExtensionSpanLane));

    // A caption double-clicked (in the lane, or where it shows): its text and bars.
    c.extensions.openCaption(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Caption'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
    await screenshot(tester, 'caption-edit', inside: find.byType(AppDialog), outermost: true);
    await tester.enterText(find.byType(EditableText).at(2), '4');
    await tester.pump();
    expect(find.text('Overlaps another caption'), findsOneWidget);
    await screenshot(tester, 'caption-overlap', inside: find.byType(AppDialog), outermost: true);
    await tester.enterText(find.byType(EditableText).at(2), 'x');
    await tester.pump();
    expect(find.text('Enter a bar or bar.beat, like 12 or 12.3'), findsOneWidget);
    await screenshot(tester, 'caption-bad', inside: find.byType(AppDialog), outermost: true);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));

    // Add Caption…, from the preview's menu: from the place clicked.
    final add = c.extensions.menu('preview').single;
    expect(c.extensions.canRun(add.runtime, add.command, starts[4]), isTrue);
    add.runtime.fire(add.command.id, 'run', args: [starts[4]]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Add Caption'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Add')).onPressed, isNull, reason: 'no text yet');
    await screenshot(tester, 'caption-add', inside: find.byType(AppDialog), outermost: true);
    await tester.enterText(find.byType(EditableText).at(0), 'New *one*');
    await tester.pump();
    await screenshot(tester, 'caption-add-typed', inside: find.byType(AppDialog), outermost: true);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));

    // The sheet (double-click the lane's name): a row each, checked as they are typed.
    runtime.call((runtime.module('sheet.lua')! as LuaTable)['open']! as LuaFunction, args: [2], where: 'test');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    await screenshot(tester, 'sheet', inside: find.byType(AppDialog), outermost: true);
    await tester.enterText(find.byType(EditableText).at(3), '1');
    await tester.pump();
    expect(find.text('2: Overlaps the caption in row 1'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Done')).onPressed, isNull);
    await screenshot(tester, 'sheet-overlap', inside: find.byType(AppDialog), outermost: true);
    await tester.enterText(find.byType(EditableText).at(3), 'q');
    await tester.pump();
    await screenshot(tester, 'sheet-bad', inside: find.byType(AppDialog), outermost: true);
    await tester.enterText(find.byType(EditableText).at(3), c.beats.format(starts[2]));
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(EditableText), findsNWidgets(12));
    await screenshot(tester, 'sheet-added', inside: find.byType(AppDialog), outermost: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Discard Your Changes?'), findsOneWidget);
    await screenshot(tester, 'sheet-discard', inside: find.byType(AppDialog).last, outermost: true);
    await tester.tap(find.text('Discard'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AppDialog), findsNothing);
    expect(saved(), hasLength(3));

    // Typed in the sheet, then Done: one Undo step.
    await tester.tap(find.text('Captions'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Captions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(EditableText), findsNWidgets(9), reason: 'the lane’s name double-clicked opens the sheet');
    await tester.enterText(find.byType(EditableText).at(8), '');
    await tester.enterText(find.byType(EditableText).at(2), 'The horns');
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved(), [
      [starts[0], starts[2], 'The horns'],
      [starts[2], starts[4], '**Loud** and clear'],
    ]);
    c.undo();
    await tester.pump(const Duration(milliseconds: 50));
    expect(saved(), hasLength(3));

    // Import… and Export…: a subtitle file's cues as rows, the rows as a file. (The panels that
    // ask for a file are the system's: the file is handed over here.)
    final at = [for (final q in [starts[4], starts[5], starts[1], starts[3]]) c.timeline.secondsAtQuarter(q)];
    String stamp(double t) => '00:${(t ~/ 60).toString().padLeft(2, '0')}:${(t % 60).toStringAsFixed(3).padLeft(6, '0')}';
    final srt = '1\n${stamp(at[0])} --> ${stamp(at[1])}\n<i>Imported</i> &amp; placed\n\n2\n${stamp(at[2])} --> ${stamp(at[3])}\nInto another\n';
    runtime.run('ui.open_file = function(spec) spec.done({name = "a.srt", text = ${jsonEncode(srt)}}) end\n'
        'ui.save_file = function(spec)\n'
        '  local file = {name = "out.vtt", extension = "vtt"}\n'
        '  print(spec.name)\n  print(spec.write(file))\n  spec.done(file)\nend');
    runtime.fire('lane', 'details');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Import…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Replace the old captions?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Add').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1 imported, 1 overlapping left out'), findsOneWidget);
    expect(find.byType(EditableText), findsNWidgets(12));
    expect(tester.widget<EditableText>(find.byType(EditableText).at(8)).controller.text, '*Imported* & placed', reason: 'in the score’s order');
    await tester.tap(find.text('Export…'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Exported “out.vtt”'), findsOneWidget);
    expect(c.extensions.log.value.first, endsWith('.srt'));
    expect(c.extensions.log.value.last, startsWith('WEBVTT\n\n00:'));
    expect(c.extensions.log.value.last, contains('<i>Imported</i> &amp; placed'));
    await tester.tap(find.text('Import…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2 imported'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(milliseconds: 300));
    // Each where the sync has its music (a file's times are to the millisecond), in the score's order.
    expect(saved(), [
      [closeTo(starts[1], 1e-3), closeTo(starts[3], 1e-3), 'Into another'],
      [closeTo(starts[4], 1e-3), closeTo(starts[5], 1e-3), '*Imported* & placed'],
    ]);
    expect(c.extensions.problems.value, isEmpty);
    c.undo();
    await tester.pump(const Duration(milliseconds: 50));

    side.replaceAll(const []);
    await tester.pump(const Duration(milliseconds: 50));
    runtime.fire('lane', 'details');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No captions'), findsOneWidget);
    await screenshot(tester, 'sheet-empty', inside: find.byType(AppDialog), outermost: true);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));

    // Its settings, for every project: the captions follow them at once.
    unawaited(showExtensionSettings(context, runtime));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 100));
    await screenshot(tester, 'settings', inside: find.byType(AppDialog), outermost: true);
    await tester.tap(find.text('Ring'));
    await tester.tap(find.text('L'));
    await tester.tap(find.text('Left'));
    await tester.tap(find.byType(AppSwitch).last);
    await tester.pump(const Duration(milliseconds: 300));
    await screenshot(tester, 'settings-changed', inside: find.byType(AppDialog), outermost: true);
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(settings.extensionSettings('captions'), {'font': '', 'countdown': 'ring', 'size': 'large', 'align': 'left', 'plate': true});
    expect(c.captions.style, const CaptionStyle(countdown: CaptionCountdown.ring, size: CaptionSize.large, align: CaptionAlign.left, plate: true));
    expect(c.scene!.captionStyle, c.captions.style);
    await screenshot(tester, 'window-styled');
    expect(c.extensions.problems.value, isEmpty);

    // Off: no lane, no caption; the captions stay in the project.
    c.undo();
    c.setExtension('captions', false);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(ExtensionSpanLane), findsNothing);
    expect(c.scene!.captions, isEmpty);
    expect(saved(), hasLength(3));
  });
}
