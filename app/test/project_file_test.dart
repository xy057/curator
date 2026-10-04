import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/media_converter.dart';
import 'package:curated_score/project_document.dart';
import 'package:curated_score/project_file.dart';
import 'package:curated_score/project_state.dart';
import 'package:curated_score/scratch_space.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('ccs-test-'));
  tearDown(() => dir.deleteSync(recursive: true));

  ProjectContents contents({ProjectMedia? media}) => ProjectContents(
        scoreName: 'Score.musicxml',
        scoreBytes: Uint8List.fromList(utf8.encode('<score-partwise/>')),
        state: const ProjectState(textEdits: {'d1': 'hello'}),
        media: media,
      );

  File recording(String name, [int size = 4096]) =>
      File('${dir.path}/$name')..writeAsBytesSync(List.generate(size, (i) => i % 251));

  test('a project keeps the source score byte for byte, and the app state', () async {
    final path = '${dir.path}/a.ccs';
    await ProjectFile.write(path, contents());

    final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
    expect(archive.files.first.name, 'mimetype', reason: 'identifies the file type without unzipping');
    expect(archive.findFile('score/Score.musicxml'), isNotNull);

    final opened = await ProjectFile.read(path, mediaDirectory: '${dir.path}/media');
    expect(opened.scoreName, 'Score.musicxml');
    expect(utf8.decode(opened.scoreBytes), '<score-partwise/>');
    expect(opened.state.textEdits, {'d1': 'hello'});
    expect(opened.media, isNull);
  });

  test('embedded media travels inside the project', () async {
    final rec = recording('take 1.wav');
    final path = '${dir.path}/embed.ccs';
    await ProjectFile.write(path, contents(
      media: ProjectMedia(name: 'take 1.wav', storage: MediaStorage.embed, embedFrom: rec.path, originalPath: rec.path),
    ));
    rec.deleteSync(); // the project no longer needs it

    final opened = await ProjectFile.read(path, mediaDirectory: '${dir.path}/unpacked');
    final media = opened.media!;
    expect(media.path, '${dir.path}/unpacked/take 1.wav');
    expect(File(media.path!).readAsBytesSync(), List.generate(4096, (i) => i % 251));
    expect(media.originalPath, isNull, reason: 'the original is gone');
    expect(media.missingPath, isNull);
  });

  test('linked media is found next to the project after moving both, and reported when missing', () async {
    Directory('${dir.path}/one').createSync();
    final rec = recording('one/take.wav');
    await ProjectFile.write('${dir.path}/one/p.ccs', contents(
      media: ProjectMedia(name: 'take.wav', storage: MediaStorage.link, originalPath: rec.path),
    ));
    expect(File('${dir.path}/one/p.ccs').lengthSync(), lessThan(4096), reason: 'nothing embedded');

    Directory('${dir.path}/one').renameSync('${dir.path}/two'); // move the folder as a whole
    var opened = await ProjectFile.read('${dir.path}/two/p.ccs', mediaDirectory: '${dir.path}/m');
    expect(opened.media!.path, '${dir.path}/two/take.wav');

    File('${dir.path}/two/take.wav').deleteSync();
    opened = await ProjectFile.read('${dir.path}/two/p.ccs', mediaDirectory: '${dir.path}/m');
    expect(opened.media!.path, isNull);
    expect(opened.media!.missingPath, '${dir.path}/one/take.wav');
  });

  test('a failed save leaves the previous file untouched', () async {
    final path = '${dir.path}/safe.ccs';
    await ProjectFile.write(path, contents());
    final before = File(path).readAsBytesSync();

    await expectLater(
      ProjectFile.write(path, contents(
        media: const ProjectMedia(name: 'gone.wav', storage: MediaStorage.embed, embedFrom: '/nowhere/gone.wav'),
      )),
      throwsA(anything),
    );
    expect(File(path).readAsBytesSync(), before);
    expect(File('$path.saving').existsSync(), isFalse);
  });

  test('a damaged project says which field is wrong', () {
    ProjectState read(Map<String, Object?> json) => ProjectState.fromJson(json);
    expect(read(const {}).lanes, isNull, reason: 'nothing saved: the lanes are auto-curated');
    Matcher damaged(String where) => throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(where)));
    expect(() => read({'partNames': {'P1': 5}}), damaged('state.partNames.P1 is not an object'));
    expect(() => read({'sync': {'anchors': [{'quarter': 0, 'seconds': 'soon'}]}}), damaged('state.sync.anchors[0].seconds is not a number'));
    expect(() => read({'sync': {'anchors': [{'quarter': 0, 'seconds': 1, 'jumpTo': 'bar 1'}]}}), damaged('state.sync.anchors[0].jumpTo is not a number'));
    expect(() => read({'curation': {'lanes': {'P1': [{'start': 4, 'end': 2}]}}}), damaged('state.curation.lanes.P1[0] ends before it starts'));
    expect(() => read({'curation': {'lanes': {'P1': [{'start': 0, 'end': 2, 'transitionIn': -1}]}}}),
        damaged('state.curation.lanes.P1[0].transitionIn is not a length of time'));
    expect(() => read({'curation': {'lanes': {'P1': [{'start': 0, 'end': 2, 'transitionOut': 'slow'}]}}}),
        damaged('state.curation.lanes.P1[0].transitionOut is not a number'));
    expect(() => read({'view': {'grid': 'minute'}}), damaged('state.view.grid'));
    expect(() => read(jsonDecode('{"sync": {"leadIn": 1e999}}') as Map<String, Object?>), damaged('state.sync.leadIn is out of range'));
    expect(() => read({'view': {'staffSpace': -1e300}}), damaged('state.view.staffSpace is out of range'));
    expect(() => read({'curation': {'transition': -2}}), damaged('state.curation.transition is not a length of time'));
    expect(() => read({'curation': {'lanes': {'P1': [{'start': 0, 'end': 2, 'transitionIn': 1e6}]}}}),
        damaged('state.curation.lanes.P1[0].transitionIn is not a length of time'));
    expect(() => read({'curation': {'lanes': {'P1': [{'start': -4, 'end': 2}]}}}), damaged('state.curation.lanes.P1[0] starts before the score'));
    expect(() => read({'condensed': [3]}), damaged('state.condensed[0] is not text'));
    expect(() => read({'pairs': [['P1']]}), damaged('state.pairs[0] is not two part ids'));
    expect(() => read({'partOrder': ['P17', 2]}), damaged('state.partOrder[1] is not text'));
  });

  test('the instruments\' order is saved when moved; older projects keep the score\'s', () {
    final json = jsonDecode(jsonEncode(const ProjectState(partOrder: ['P17', 'P1']).toJson())) as Map<String, Object?>;
    expect(ProjectState.fromJson(json).partOrder, ['P17', 'P1']);
    expect(ProjectState.fromJson({'textEdits': <String, Object?>{}}, savedVersion: 4).partOrder, isEmpty);
  });

  test('a project keeps its fonts, and an added music font travels inside it', () async {
    final leland = File('../packages/score_engine/assets/fonts/Leland.otf').readAsBytesSync();
    final added = MusicFont.added(family: 'My Leland', file: leland, metadata: utf8.encode('{"fontName": "My Leland"}'));
    final path = '${dir.path}/fonts.ccs';
    await ProjectFile.write(
        path,
        ProjectContents(
          scoreName: 'Score.musicxml',
          scoreBytes: Uint8List.fromList(utf8.encode('<score-partwise/>')),
          state: ProjectState(fonts: ScoreFonts(music: added, text: 'Helvetica')),
        ));
    final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
    expect(archive.findFile('fonts/My Leland.font')!.content, leland);
    expect(archive.findFile('fonts/My Leland.json'), isNotNull);
    final opened = await ProjectFile.read(path, mediaDirectory: '${dir.path}/media');
    expect(opened.state.fonts, ScoreFonts(music: added, text: 'Helvetica'));

    final bundled = jsonDecode(jsonEncode(const ProjectState(fonts: ScoreFonts(music: MusicFont.petaluma)).toJson()));
    expect(bundled['fonts'], {'music': 'Petaluma'}, reason: 'a bundled font is saved by name only');
    expect(ProjectState.fromJson(bundled as Map<String, Object?>).fonts, const ScoreFonts(music: MusicFont.petaluma));
    expect(const ProjectState().toJson().containsKey('fonts'), isFalse);
    expect(ProjectState.fromJson({'textEdits': <String, Object?>{}}, savedVersion: 8).fonts, ScoreFonts.standard);
    expect(() => ProjectState.fromJson({'fonts': {'music': 'Gone'}}), throwsA(isA<FormatException>()));
  });

  test('a project from before condensing opens with nothing condensed', () {
    final state = ProjectState.fromJson({'textEdits': <String, Object?>{}}, savedVersion: 1);
    expect(state.condensed, isEmpty);
    expect(state.pairs, isEmpty);
    expect(ProjectState.version, 9);
    expect(ProjectState.fromJson({'condensed': ['cond-P2-P3']}, savedVersion: 2).pairs, isEmpty);
  });

  test('a region is saved with its own transitions; one without, and older projects\' regions, use the project\'s', () {
    const lanes = {'P1': [Region(0, 4, transitionIn: 1.2), Region(8, 12), Region(14, 16, transitionIn: 0.5, transitionOut: 2)]};
    final json = jsonDecode(jsonEncode(const ProjectState(lanes: lanes).toJson())) as Map<String, Object?>;
    expect(((json['curation'] as Map)['lanes'] as Map)['P1'], [
      {'start': 0, 'end': 4, 'transitionIn': 1.2},
      {'start': 8, 'end': 12},
      {'start': 14, 'end': 16, 'transitionIn': 0.5, 'transitionOut': 2},
    ]);
    expect(ProjectState.fromJson(json).lanes, lanes);
    final old = ProjectState.fromJson({'curation': {'lanes': {'P1': [{'start': 0, 'end': 4}]}}}, savedVersion: 5);
    expect(old.lanes!['P1']!.single.hasDefaultProperties, isTrue);
  });

  test('warps are saved with their jump; plain anchors without one', () {
    const anchors = [SyncAnchor(0, 1), SyncAnchor(24, 10, jumpTo: 0), SyncAnchor(6, 13)];
    final json = jsonDecode(jsonEncode(const ProjectState(anchors: anchors).toJson())) as Map<String, Object?>;
    expect((json['sync'] as Map)['anchors'], [
      {'quarter': 0, 'seconds': 1},
      {'quarter': 24, 'seconds': 10, 'jumpTo': 0},
      {'quarter': 6, 'seconds': 13},
    ]);
    expect(ProjectState.fromJson(json).anchors, anchors);
    expect(ProjectState.fromJson({'sync': {'anchors': [{'quarter': 0, 'seconds': 1}]}}, savedVersion: 3).anchors.single.isWarp, isFalse);
  });

  test('a project that is not ours, or from the future, is refused', () async {
    final path = '${dir.path}/future.ccs';
    final archive = Archive()
      ..add(ArchiveFile.string('project.json', jsonEncode({'format': ProjectFile.mimeType, 'version': 99})));
    File(path).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
    await expectLater(ProjectFile.read(path, mediaDirectory: dir.path), throwsA(isA<FormatException>()));
  });

  test('media storage: embed when there is nothing to link to, link when too big to embed', () {
    MediaStorage resolve(MediaStorage preferred, {String? original = '/rec.wav', int size = 1000}) =>
        resolveMediaStorage(preferred: preferred, originalPath: original, sizeBytes: size);
    expect(resolve(MediaStorage.embed), MediaStorage.embed);
    expect(resolve(MediaStorage.link), MediaStorage.link);
    expect(resolve(MediaStorage.link, original: null), MediaStorage.embed);
    expect(resolve(MediaStorage.embed, size: embedLimitBytes + 1), MediaStorage.link);
    expect(resolve(MediaStorage.embed, original: null, size: embedLimitBytes + 1), MediaStorage.embed);
  });

  test('a video becomes lossless audio (its soundtrack)', () async {
    final out = await MediaConverter.toFlac('test/fixtures/tiny-video.mp4', '${dir.path}/audio');
    expect(out, '${dir.path}/audio/tiny-video.flac');
    expect(ascii.decode(File(out).readAsBytesSync().sublist(0, 4)), 'fLaC');
    expect(MediaFormats.isVideo('Take.MOV'), isTrue);
    expect(MediaFormats.isVideo('take.m4a'), isFalse);
  }, skip: Platform.isMacOS ? false : 'afconvert is macOS only');

  group('with a score', () {
    late EditorController c;
    late ProjectDocument doc;

    setUp(() async {
      c = EditorController(vsync: const TestVSync());
      doc = ProjectDocument(c, AppSettings.memory()..autosave = Duration.zero);
      await doc.importScore(demoScore.path);
    });

    tearDown(() {
      doc.dispose();
      c.dispose();
    });

    test('every edit survives save and open', () async {
      final part = c.score!.metadata.parts.first;
      c.renamePart(part, name: 'Solo Piccolo', abbreviation: 'Picc.');
      c.curation!.setLane(part.id, [const Region(3, 12), const Region(21, 27, transitionIn: 1.2, transitionOut: 0.15)]);
      c.curation!.transition = 0.5;
      c.sync!.addAnchor(const SyncAnchor(0, 1.25));
      c.sync!.addAnchor(const SyncAnchor(12, 7.5));
      c.setStaffSpace(11);
      c.setCondensed(['cond-P2-P3'], on: true);
      await c.addPair('P6', 'P12'); // Clarinet 1 + Trumpet 1
      final saved = c.projectState;

      final path = '${dir.path}/round.ccs';
      await doc.save(path);

      final c2 = EditorController(vsync: const TestVSync());
      final doc2 = ProjectDocument(c2, AppSettings.memory()..autosave = Duration.zero);
      addTearDown(() {
        doc2.dispose();
        c2.dispose();
      });
      await doc2.open(path);
      expect(jsonEncode(c2.projectState.toJson()), jsonEncode(saved.toJson()));
      expect(c2.partName(part), 'Solo Piccolo');
      expect(c2.condensed, {'cond-P2-P3', 'cond-P6-P12'});
      expect(c2.pairs, const [PlayerPair('P6', 'P12')]);
      expect(c2.score!.condensed.map((g) => g.id), contains('cond-P6-P12'));
      expect(c2.scene!.condensed, {'cond-P2-P3', 'cond-P6-P12'});
      expect(c2.source!.bytes, demoScore.readAsBytesSync());
      expect(doc2.isDirty, isFalse);
      expect(doc2.title, 'round.ccs');
      expect(c2.canUndo, isFalse, reason: 'a freshly opened project has no history');
    });

    test('a project that fails to open leaves the open one exactly as it was', () async {
      // B: readable as a zip, but its state is damaged. A is the project that is open.
      final a = '${dir.path}/A.ccs', b = '${dir.path}/B.ccs';
      await doc.save(b);
      await doc.save(a);
      final archive = ZipDecoder().decodeBytes(File(b).readAsBytesSync());
      final manifest = jsonDecode(utf8.decode(archive.findFile('project.json')!.content)) as Map;
      (manifest['state'] as Map)['partNames'] = {'P1': 5};
      final damaged = Archive();
      for (final f in archive.files) {
        damaged.addFile(f.name == 'project.json' ? ArchiveFile.string('project.json', jsonEncode(manifest)) : f);
      }
      File(b).writeAsBytesSync(ZipEncoder().encode(damaged));

      final score = c.score;
      await expectLater(doc.open(b), throwsA(isA<FormatException>()));
      expect(doc.path, a);
      expect(identical(c.score, score), isTrue);

      // An edit and an autosave now still write A's own project to A.
      c.curation!.clearAll();
      await doc.autosave();
      expect((await ProjectFile.read(a, mediaDirectory: '${dir.path}/m')).state.lanes!.values.every((l) => l.isEmpty), isTrue);
    });

    test('opens asked for at once run one after the other; an autosave meanwhile waits for them', () async {
      final part = c.score!.metadata.parts.first;
      final a = '${dir.path}/A.ccs', b = '${dir.path}/B.ccs';
      c.renamePart(part, name: 'From A', abbreviation: 'A');
      // A opens slowly: its "video" goes through a converter (and fails) after the score is in.
      await ProjectFile.write(
          a,
          ProjectContents(
            scoreName: c.source!.name,
            scoreBytes: c.source!.bytes,
            state: c.projectState,
            media: ProjectMedia(name: 'take.mp4', storage: MediaStorage.embed, embedFrom: recording('take.mp4').path),
          ));
      c.renamePart(part, name: 'From B', abbreviation: 'B');
      await doc.save(b);
      final savedA = File(a).readAsBytesSync();

      final opening = [doc.open(a), doc.open(b)];
      final autosaving = doc.autosave();
      await Future.wait([...opening, autosaving]);
      expect(doc.path, b);
      expect(c.partName(part), 'From B');
      expect(doc.isDirty, isFalse);
      expect(File(a).readAsBytesSync(), savedA, reason: 'nothing of B was written over A');
    });

    test('a recording that cannot be loaded does not stop the project from opening', () async {
      final path = '${dir.path}/bad-recording.ccs';
      await ProjectFile.write(
        path,
        ProjectContents(
          scoreName: 'Intro.musicxml',
          scoreBytes: demoScore.readAsBytesSync(),
          state: const ProjectState(),
          media: ProjectMedia(name: 'take.wav', storage: MediaStorage.embed, embedFrom: recording('take.wav').path),
        ),
      );
      final problem = await doc.open(path);
      expect(problem, contains('could not be loaded'));
      expect(doc.path, path);
      expect(c.fileName, 'Intro.musicxml');
      expect(c.track, isNull);
    });

    test('importing a score lets go of the recording the project before it unpacked', () async {
      final path = '${dir.path}/with-recording.ccs';
      await ProjectFile.write(
        path,
        ProjectContents(
          scoreName: 'Intro.musicxml',
          scoreBytes: demoScore.readAsBytesSync(),
          state: const ProjectState(),
          media: ProjectMedia(name: 'take.wav', storage: MediaStorage.embed, embedFrom: recording('take.wav').path),
        ),
      );
      List<String> unpacked() => [
            for (final e in ScratchSpace.session.listSync())
              if (e is Directory && e.path.split(Platform.pathSeparator).last.startsWith('project-')) e.path,
          ];
      final before = unpacked();
      await doc.open(path);
      final opened = unpacked().where((p) => !before.contains(p)).toList();
      expect(opened, hasLength(1));

      await doc.importScore(demoScore.path);
      expect(Directory(opened.single).existsSync(), isFalse);
    });

    test('Undo keeps as many steps as Settings say', () {
      doc.settings.undoSteps = 3;
      final id = c.score!.metadata.parts.first.id;
      for (var i = 1; i <= 5; i++) {
        c.curation!.setLane(id, [Region(0, i * 3.0)]);
      }
      var steps = 0;
      while (c.canUndo) {
        c.undo();
        steps++;
      }
      expect(steps, 3);
      expect(c.curation!.lane(id), [const Region(0, 6)], reason: 'back 3 of the 5 edits');
      expect(c.canRedo, isTrue);
    });

    test('edits make the project dirty; saving makes it clean', () async {
      expect(doc.isDirty, isFalse, reason: 'importing is not an edit');
      expect(doc.suggestedFileName, 'WI275 - 01 Intro.ccs');
      c.curation!.clearAll();
      expect(doc.isDirty, isTrue);
      await doc.save('${dir.path}/d.ccs');
      expect(doc.isDirty, isFalse);
    });

    test('autosave writes a saved project with changes, and leaves untitled ones alone', () async {
      c.curation!.clearAll();
      await doc.autosave();
      expect(doc.path, isNull);
      expect(dir.listSync(), isEmpty);

      final path = '${dir.path}/auto.ccs';
      await doc.save(path);
      final first = File(path).lastModifiedSync();
      await doc.autosave(); // nothing changed
      expect(File(path).lastModifiedSync(), first);

      c.curation!.setLane(c.score!.metadata.parts.first.id, [const Region(0, 8)]);
      await doc.autosave();
      expect(doc.isDirty, isFalse);
      final opened = await ProjectFile.read(path, mediaDirectory: '${dir.path}/m');
      expect(opened.state.lanes![c.score!.metadata.parts.first.id], [const Region(0, 8)]);
    });
  });
}
