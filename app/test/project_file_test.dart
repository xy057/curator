import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:archive/archive.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/image_patch.dart';
import 'package:curated_score/project_document.dart';
import 'package:curated_score/project_file.dart';
import 'package:curated_score/project_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'image_patch_test.dart' show png;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('ccs-test-'));
  tearDown(() => dir.deleteSync(recursive: true));

  ProjectContents contents({ProjectMedia? media}) => ProjectContents(
        scoreName: 'Score.musicxml',
        scoreBytes: Uint8List.fromList(utf8.encode('<score-partwise/>')),
        state: const ProjectState(edits: EditState(textEdits: {'d1': 'hello'}, mediaStorage: MediaStorage.link)),
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
    final manifest = jsonDecode(utf8.decode(archive.findFile('project.json')!.content)) as Map;
    expect(manifest['version'], ProjectState.version, reason: 'always written in the newest format');

    final opened = await ProjectFile.read(path, mediaDirectory: '${dir.path}/media');
    expect(opened.scoreName, 'Score.musicxml');
    expect(utf8.decode(opened.scoreBytes), '<score-partwise/>');
    expect(opened.state.edits.textEdits, {'d1': 'hello'});
    expect(opened.state.edits.mediaStorage, MediaStorage.link, reason: "the project's own");
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

  test('a link reaches only a recording, wherever it is', () async {
    Directory('${dir.path}/projects/p').createSync(recursive: true);
    File('${dir.path}/secret.txt').writeAsStringSync('not a recording');
    final take = recording('take.wav');
    Future<String?> open(Map<String, Object?> media) async {
      final path = '${dir.path}/projects/p/link.ccs';
      File(path).writeAsBytesSync(ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.string('project.json', jsonEncode({
          'format': ProjectFile.mimeType,
          'version': ProjectFile.formatVersion,
          'score': {'name': 'S.musicxml', 'entry': 'score/S.musicxml'},
          'media': media,
          'state': const ProjectState().toJson(),
        })))
        ..add(ArchiveFile.string('score/S.musicxml', '<score-partwise/>'))));
      return (await ProjectFile.read(path, mediaDirectory: '${dir.path}/m')).media!.path;
    }

    expect(await open({'name': 'take.wav', 'relativePath': '../../take.wav'}), endsWith('take.wav'));
    expect(await open({'name': 'take.wav', 'path': take.path}), take.path);
    expect(await open({'name': 'secret.wav', 'relativePath': '../../secret.txt'}), isNull);
    expect(await open({'name': 'secret.wav', 'path': '${dir.path}/secret.txt'}), isNull);
  });

  test('what a project unpacks is limited, and only what it uses is unpacked', () async {
    String project(String name, Map<String, Object?> manifest, List<ArchiveFile> files) {
      final path = '${dir.path}/$name.ccs';
      final archive = Archive()
        ..add(ArchiveFile.string('project.json', jsonEncode({
          'format': ProjectFile.mimeType,
          'version': ProjectFile.formatVersion,
          'score': {'name': 'S.musicxml', 'entry': 'score/S.musicxml'},
          'state': const ProjectState().toJson(),
          ...manifest,
        })))
        ..add(ArchiveFile.string('score/S.musicxml', '<score-partwise/>'));
      files.forEach(archive.add);
      File(path).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
      return path;
    }

    // Zeros: a few hundred KB in the zip, past any limit unpacked.
    ArchiveFile bomb(String name) =>
        ArchiveFile.bytes(name, Uint8List(ProjectFile.maxFontBytes * 2 + 1))..compression = CompressionType.deflate;

    final unusedFont = project('font', {}, [bomb('fonts/Junk.font')]);
    expect((await ProjectFile.read(unusedFont, mediaDirectory: '${dir.path}/m1')).state.edits.fonts.music, MusicFont.bravura);

    final media = project('media', {'media': {'name': 'take.wav', 'entry': 'media/take.wav'}}, [bomb('media/take.wav')]);
    await expectLater(ProjectFile.read(media, mediaDirectory: '${dir.path}/m2'), throwsFormatException);
    final unpacked = File('${dir.path}/m2/take.wav');
    expect(unpacked.existsSync() ? unpacked.lengthSync() : 0, lessThanOrEqualTo(4 * File(media).lengthSync() + (64 << 20)));

    final manifest = project('manifest', {'padding': ' ' * (ProjectFile.maxManifestBytes + 1)}, []);
    await expectLater(ProjectFile.read(manifest, mediaDirectory: '${dir.path}/m3'), throwsFormatException);
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

  test('a project that is not ours, or from the future, is refused', () async {
    final path = '${dir.path}/future.ccs';
    final archive = Archive()
      ..add(ArchiveFile.string('project.json', jsonEncode({'format': ProjectFile.mimeType, 'version': 99})));
    File(path).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
    await expectLater(ProjectFile.read(path, mediaDirectory: dir.path), throwsA(isA<FormatException>()));
  });

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
      final vivo = c.score!.texts.firstWhere((t) => t.text == 'Vivo');
      await c.editText(vivo.id, 'Presto');
      c.moveLane('P17', 0);
      final parts = c.score!.metadata.parts;
      // The snare drum back with the timpani, the piccolo alone, the horns in a bracket of their own.
      c.setGroupSections(true);
      c.setBarNumbers(false); // on for a new project
      c.setColorNames(true);
      c.setNameGroupColor('brass', const Color(0xFFE0B000));
      final solo = c.addNameGroup('Solo');
      c.setNameGroupColor(solo, const Color(0xFF123456));
      c.setNameGroup(parts[0], solo); // the piccolo in a group of its own
      c.setNameGroup(parts[15], null); // the snare drum in the ink
      c.setSections({parts[15].id: 'percussion', parts[0].id: null, 'P10': 'bracket-1', 'P11': 'bracket-1'});
      final starts = c.score!.timeline.measureStarts;
      c.sync!.addAnchor(SyncAnchor(starts[8], 20, jumpTo: starts[4])); // a warp: back to bar 5
      c.useMidiTempo(MidiTempoMap('tempo.mid', const [(quarter: 0, quartersPerMinute: 96), (quarter: 24, quartersPerMinute: 80)]));
      await c.setFonts(const ScoreFonts(music: MusicFont.leland));
      c.images.enabled = true;
      c.captions.enabled = true;
      await c.images.add(ImageKind.raster, png, quarter: starts[2], top: 2);
      c.images.update(0, c.images.patches[0].copyWith(ink: true));
      c.captions.add(Caption(starts[1], starts[5], 'The horns answer'));
      c.captions.setFont(TextFonts.academico);
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
      expect(c2.textById(vivo.id)!.current, 'Presto');
      expect(c2.partOrder.first, 'P17');
      expect((c2.scene!.sections, c2.scene!.barNumbers), (true, false));
      expect(c2.scene!.nameColors['P10'], const Color(0xFFE0B000), reason: 'a horn: brass, recoloured');
      expect(c2.scene!.nameColors[parts[0].id], const Color(0xFF123456));
      expect(c2.scene!.nameColors.containsKey(parts[15].id), isFalse);
      expect(c2.scene!.nameColors[parts.last.id], defaultNameColors[InstrumentFamily.strings]);
      expect(c2.scene!.sectionOverrides, {'P16': 'percussion', 'P1': null, 'P10': 'bracket-1', 'P11': 'bracket-1'});
      expect(c2.midiTempo!.name, 'tempo.mid');
      expect(c2.projectState.edits.anchors.where((a) => a.isWarp), hasLength(1), reason: 'the anchors kept behind the MIDI file');
      expect(c2.score!.fonts.music, MusicFont.leland);
      expect(c2.images.patches.single.ink, isTrue);
      expect(c2.images.stored, hasLength(1), reason: 'the image file travels in the project');
      expect(c2.captions.captions, [Caption(starts[1], starts[5], 'The horns answer')]);
      expect(c2.captions.font, TextFonts.academico);
      expect(c2.source!.bytes, demoScore.readAsBytesSync());
      expect(doc2.isDirty, isFalse);
      expect(doc2.title, 'round.ccs');
      expect(c2.canUndo, isFalse, reason: 'a freshly opened project has no history');
    });

    test('edits make the project dirty; saving makes it clean; autosave writes a saved project with changes, not an untitled one', () async {
      expect(doc.isDirty, isFalse, reason: 'importing is not an edit');
      expect(doc.suggestedFileName, 'WI275 - 01 Intro.ccs');
      c.curation!.clearAll();
      expect(doc.isDirty, isTrue);
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
      expect(opened.state.edits.lanes![c.score!.metadata.parts.first.id], [const Region(0, 8)]);
    });
  });
}
