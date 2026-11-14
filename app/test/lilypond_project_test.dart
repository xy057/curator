// A LilyPond project: opened as LilyPond engraved it (the engine's fixture), saved and opened
// again without LilyPond; one whose files are not where they should be is damaged.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/lilypond.dart';
import 'package:curated_score/project_file.dart';
import 'package:curated_score/project_state.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

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
  tearDown(() {
    // Read again by the next test: the bundle keeps what it read as a future of this test's
    // clock, which nothing moves after it.
    rootBundle.evict(LilyPond.settingsAsset);
    dir.deleteSync(recursive: true);
  });

  test('a LilyPond project: opened as LilyPond engraved it, saved and opened again without LilyPond; one naming a file outside its folder, or missing one, damaged', () async {
    // A LilyPond score opens as LilyPond engraved it, and saved, opens again without LilyPond.
    {
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
    }

    // A project naming a LilyPond file outside its folder, or missing one, is damaged.
    {
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
    }
  });
}
