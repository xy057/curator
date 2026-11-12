// A LilyPond project: opened as LilyPond engraved it, saved and opened again without LilyPond,
// put in place of another score and back; and the dialog that gets LilyPond first, then engraves
// (here with a stand-in that answers every score with the engine's fixture).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:curated_score/app_colors.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/lilypond.dart';
import 'package:curated_score/lilypond_dialog.dart';
import 'package:curated_score/project_file.dart';
import 'package:curated_score/project_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';

/// The engine's fixture: a score LilyPond 2.26.0 engraved with Curator's settings (its .ly, .svg
/// and .jsonl).
const _fixture = '../packages/score_engine/test/lilypond/fixture';

LilyPondProject _project({String folder = '', Map<String, Uint8List> files = const {}}) => LilyPondProject(
    folder: folder,
    files: files,
    svg: File('$_fixture.svg').readAsStringSync(),
    data: File('$_fixture.jsonl').readAsStringSync(),
    version: LilyPond.version);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('lilypond-project-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a LilyPond score opens as LilyPond engraved it, and saved, opens again without LilyPond', () async {
    final c = EditorController(vsync: const TestVSync());
    addTearDown(c.dispose);
    final project = _project(folder: 'score', files: {'global.ily': Uint8List.fromList(utf8.encode('x = 1\n'))});
    await c.openLilyPond('fixture.ly', File('$_fixture.ly').readAsBytesSync(), project);
    expect((c.isLilyPond, c.isPdf, c.projectState.kind), (true, false, ProjectKind.lilypond));
    expect(c.score!.lilypond, isNotNull);
    expect([for (final p in c.score!.metadata.parts) p.name], ['Flute', 'Clarinet in B♭', 'Piano', 'Voice', 'Drums']);
    // Its staves are LilyPond's: none for two players to share. Its notes are there to curate by.
    expect(c.condensable, isEmpty);
    expect(c.canAutoCurate, isTrue);
    expect(c.projectState.lilypond, same(project));

    final path = '${dir.path}/song.ccs';
    await ProjectFile.write(path, ProjectContents(scoreName: c.source!.name, scoreBytes: c.source!.bytes, state: c.projectState));
    final zip = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
    expect(jsonDecode(utf8.decode(zip.findFile('modules/lilypond.json')!.content)),
        {'version': LilyPond.version, 'settings': 1, 'folder': 'score', 'files': ['global.ily']});
    expect(utf8.decode(zip.findFile('lilypond/files/global.ily')!.content), 'x = 1\n');
    expect(zip.findFile('lilypond/score.svg'), isNotNull);

    final opened = await ProjectFile.read(path, mediaDirectory: '${dir.path}/media');
    expect(opened.state.kind, ProjectKind.lilypond);
    final again = EditorController(vsync: const TestVSync());
    addTearDown(again.dispose);
    await again.openProject(name: opened.scoreName, scoreBytes: opened.scoreBytes, state: opened.state);
    expect((again.isLilyPond, again.fileName), (true, 'fixture.ly'));
    expect((again.lilypond!.folder, again.lilypond!.svg == project.svg), ('score', true));
    expect(again.lilypond!.files.keys, ['global.ily']);
    expect(again.score!.timeline.measureStarts, c.score!.timeline.measureStarts);
  });

  test('a project naming a LilyPond file outside its folder, or missing one, is damaged', () async {
    final path = '${dir.path}/files.ccs';
    await ProjectFile.write(
        path,
        ProjectContents(
            scoreName: 'a.ly', scoreBytes: Uint8List(1), state: ProjectState(lilypond: _project(files: {'a.ily': Uint8List(2)}))));
    final good = File(path).readAsBytesSync();
    for (final files in [
      ['../a.ily'],
      ['/a.ily'],
      ['b.ily'], // not in the project
    ]) {
      final archive = Archive();
      for (final f in ZipDecoder().decodeBytes(good).files) {
        archive.addFile(f.name == 'modules/lilypond.json'
            ? ArchiveFile.string(f.name, jsonEncode({'version': LilyPond.version, 'files': files}))
            : ArchiveFile.bytes(f.name, f.content));
      }
      File(path).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
      await expectLater(ProjectFile.read(path, mediaDirectory: '${dir.path}/media'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', startsWith('The project is damaged'))),
          reason: '$files');
    }
  });

  test('Replace… puts a LilyPond score in place of a MusicXML one, and one back, the project its kind', () async {
    final c = EditorController(vsync: const TestVSync());
    addTearDown(c.dispose);
    await c.openFile(demoScore.path);
    await c.replaceScore(await c.prepareReplacementWith('fixture.ly', File('$_fixture.ly').readAsBytesSync(), lilypond: _project()));
    expect((c.isLilyPond, c.projectState.kind, c.fileName), (true, ProjectKind.lilypond, 'fixture.ly'));
    expect(c.score!.lilypond, isNotNull);
    await c.replaceScore(await c.prepareReplacement(demoScore.path));
    expect((c.isLilyPond, c.projectState.kind, c.lilypond, c.score!.lilypond), (false, ProjectKind.score, null, null));
  });

  group('the dialog', () {
    LilyPondRun? run;
    var done = false, hub = 0;
    Future<void> open(WidgetTester tester) async {
      run = null;
      done = false;
      hub = 0;
      await tester.pumpWidget(MaterialApp(
        theme: AppColors.theme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                run = await engraveWithLilyPond(context, const LilySource(name: 'song.ly', text: '{ c }'), downloadHub: () => hub++);
                done = true;
              },
              child: const Text('Engrave'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Engrave'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    testWidgets('LilyPond not here: it is asked for, its size said; Cancel engraves nothing, Open Download Hub goes there', (tester) async {
      LilyPond.debugFolder = Directory('${dir.path}/none');
      addTearDown(() => LilyPond.debugFolder = null);
      await open(tester);
      expect(find.text('Download LilyPond?'), findsOneWidget);
      expect(find.text('Download'), findsNothing); // downloaded in the Download Hub only
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((done, run, hub), (true, null, 0));
      expect(find.byType(LilyPondDialog), findsNothing);

      final package = LilyPond.package;
      if (package == null) return; // none for this computer: nothing to download
      await open(tester);
      expect(find.text('“song.ly” is engraved with LilyPond (${(package.size / 1e6).round()} MB).'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Open Download Hub'));
      await tester.pumpAndSettle();
      expect((done, run, hub), (true, null, 1));
      expect(find.byType(LilyPondDialog), findsNothing);
    });

    testWidgets('LilyPond here: the score is engraved at once, and the dialog goes with its run', (tester) async {
      // A stand-in for LilyPond: answers with the fixture, where LilyPond would write it.
      final svg = File('$_fixture.svg').absolute.path, data = File('$_fixture.jsonl').absolute.path;
      final script = File('${dir.path}/lilypond')
        ..writeAsStringSync('#!/bin/sh\nout=""\nwhile [ \$# -gt 0 ]; do\n  if [ "\$1" = "-o" ]; then out="\$2"; shift; fi\n  shift\ndone\n'
            'cp \'$svg\' "\$out.svg"\ncp \'$data\' "\$CURATOR_LILYPOND_DATA"\n');
      Process.runSync('chmod', ['+x', script.path]);
      LilyPond.debugExecutable = script;
      addTearDown(() => LilyPond.debugExecutable = null);
      await open(tester);
      expect(find.text('Engraving “song.ly”'), findsOneWidget);
      for (var i = 0; i < 400 && !done; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect((done, run?.engraved), (true, true));
      expect(find.byType(LilyPondDialog), findsNothing);
      expect(run!.svg, contains('data-c='));
    }, skip: Platform.isWindows);
  });
}
