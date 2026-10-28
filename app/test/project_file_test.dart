import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/image_patch.dart';
import 'package:curated_score/project_document.dart';
import 'package:archive/archive_io.dart';
import 'package:curated_score/legacy_project.dart';
import 'package:curated_score/project_file.dart';
import 'package:curated_score/project_modules.dart';
import 'package:curated_score/settings_file.dart';
import 'package:curated_score/project_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

/// 4 × 2 red pixels.
final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEklEQVR4nGP4z8DwHxkzoAsAAA8hD/EEN8afAAAAAElFTkSuQmCC');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('ccs-test-'));
  tearDown(() => dir.deleteSync(recursive: true));

  ProjectContents contents({ProjectMedia? media}) => ProjectContents(
        scoreName: 'Score.musicxml',
        scoreBytes: Uint8List.fromList(utf8.encode('<score-partwise/>')),
        state: const ProjectState(edits: EditState(textEdits: {'d1': 'hello'})),
        media: media,
      );

  test('a failed save leaves the previous file untouched', () async {
    final path = '${dir.path}/safe.ccs';
    await ProjectFile.write(path, contents());
    final before = File(path).readAsBytesSync();

    await expectLater(
      ProjectFile.write(path, contents(
        media: const ProjectMedia(name: 'gone.wav', embedFrom: '/nowhere/gone.wav'),
      )),
      throwsA(anything),
    );
    expect(File(path).readAsBytesSync(), before);
    expect(File('$path.saving').existsSync(), isFalse);
  });

  /// [path]'s zip with [change] made to it: entries by name (null removes one).
  void rewrite(String path, Map<String, List<int>?> change) {
    final before = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
    final after = Archive();
    for (final f in before.files) {
      if (!change.containsKey(f.name)) after.add(ArchiveFile.bytes(f.name, f.content));
    }
    for (final MapEntry(key: name, value: bytes) in change.entries) {
      if (bytes != null) after.add(ArchiveFile.bytes(name, bytes));
    }
    File(path).writeAsBytesSync(ZipEncoder().encodeBytes(after));
  }

  Map<String, Object?> json(String path, String entry) =>
      jsonDecode(utf8.decode(ZipDecoder().decodeBytes(File(path).readAsBytesSync()).findFile(entry)!.content)) as Map<String, Object?>;

  Future<OpenedProject> open(String path) => ProjectFile.read(path, mediaDirectory: '${dir.path}/media');

  group('the format', () {
    test('Curator 0.1 to 0.6.1 know a project in modules, and ask for an update', () async {
      final path = '${dir.path}/new.ccs';
      await ProjectFile.write(path, contents());
      final zip = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
      expect(zip.files.first.name, 'mimetype');
      // What they read: project.json's format, then its version above theirs (26 at most).
      expect(json(path, 'project.json'), {'format': ProjectFile.mimeType, 'version': LegacyProject.lastVersion + 1});
      final manifest = json(path, 'manifest.json');
      expect(manifest['modules'], {
        for (final m in ProjectModules.all) m.id: {'version': m.version, if (m.optional) 'optional': true},
      });
      expect((await open(path)).state.edits.textEdits, {'d1': 'hello'});
    });

    test('a project saved before modules opens with every field in its module', () async {
      final path = '${dir.path}/old.ccs';
      final project = {
        'format': ProjectFile.mimeType,
        'version': 17,
        'score': {'name': 'Score.musicxml', 'entry': 'score/Score.musicxml'},
        'state': {
          'textEdits': {'d1': 'hello'},
          'partNames': {'P1': {'name': 'Solo Piccolo'}},
          'sections': {'P2': 'none', 'P3': 'bracket-1'},
          'flags': {'centredLyrics': true},
          'curation': {
            'transition': 0.5,
            'lanes': {
              'P1': [{'start': 1, 'end': 2, 'transitionIn': 0.3}],
            },
          },
          'sync': {
            'leadIn': 1,
            'anchors': [{'quarter': 8, 'seconds': 4, 'jumpTo': 0}, {'quarter': 4, 'seconds': 2}],
          },
          'captions': [{'start': 1, 'end': 2, 'text': 'Hi'}],
          'view': {'time': 3},
        },
      };
      final zip = Archive()
        ..add(ArchiveFile.string('project.json', jsonEncode(project)))
        ..add(ArchiveFile.string('score/Score.musicxml', '<score-partwise/>'));
      File(path).writeAsBytesSync(ZipEncoder().encodeBytes(zip));

      final state = (await open(path)).state;
      final e = state.edits;
      expect(e.barNumbers, isFalse, reason: 'saved before bar numbers (format 18): off, as it was made');
      expect(e.partNames, {'P1': (name: 'Solo Piccolo', abbreviation: '')});
      expect(e.sections, {'P2': null, 'P3': 'bracket-1'});
      expect(e.centeredLyrics, isTrue);
      expect((e.transition, e.leadIn), (0.5, 1));
      expect(e.lanes, {'P1': [const Region(1, 2, transitionIn: 0.3)]});
      expect(e.anchors, [const SyncAnchor(4, 2), const SyncAnchor(8, 4, jumpTo: 0)]);
      expect(e.captions, [const Caption(1, 2, 'Hi')]);
      expect(state.view.time, 3);

      // Saved again, in modules: the same.
      await ProjectFile.write(path, ProjectContents(scoreName: 'Score.musicxml', scoreBytes: Uint8List(1), state: state));
      expect(jsonEncode(ProjectModules.toJson((await open(path)).state)), jsonEncode(ProjectModules.toJson(state)));
    });

    test('a module this version can\'t read is kept when it may go unread, refused when not', () async {
      final path = '${dir.path}/later.ccs';
      await ProjectFile.write(path, contents());
      final manifest = json(path, 'manifest.json');
      final modules = manifest['modules']! as Map<String, Object?>;
      List<int> listing(Map<String, Object?> extra) => utf8.encode(jsonEncode({...manifest, 'modules': {...modules, ...extra}}));

      rewrite(path, {
        'manifest.json': listing({'tonality': {'version': 3, 'optional': true}}),
        'modules/tonality.json': utf8.encode('{"keys":[1,2]}'),
        'tonality/bar-1.bin': [1, 2, 3],
      });
      final opened = await open(path);
      expect(opened.state.edits.textEdits, {'d1': 'hello'});
      expect(opened.state.foreign.keys, ['tonality']);
      // Saved here: still there, as it came.
      final again = '${dir.path}/again.ccs';
      await ProjectFile.write(again, ProjectContents(scoreName: 'Score.musicxml', scoreBytes: Uint8List(1), state: opened.state));
      expect(json(again, 'manifest.json')['modules'], containsPair('tonality', {'version': 3, 'optional': true}));
      expect(json(again, 'modules/tonality.json'), {'keys': [1, 2]});
      expect(ZipDecoder().decodeBytes(File(again).readAsBytesSync()).findFile('tonality/bar-1.bin')!.content, [1, 2, 3]);

      for (final extra in [
        {'tonality': {'version': 1}}, // a module of a newer version, needed
        {'sync': {'version': 99}}, // a newer version of one known here
      ]) {
        rewrite(path, {'manifest.json': listing(extra)});
        await expectLater(open(path), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('newer version'))));
      }
    });

    test('a damaged module says where', () async {
      final path = '${dir.path}/damaged.ccs';
      await ProjectFile.write(path, contents());
      rewrite(path, {'modules/sync.json': utf8.encode('{"anchors":[[1,"x"]]}')});
      await expectLater(open(path), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('sync.anchors[0]'))));
    });

    test('settings files are in modules too', () async {
      final path = '${dir.path}/look.ccf';
      const settings = EditState(barNumbers: false, colorNames: true, transition: 0.8, extensions: {'captions': true});
      await SettingsFile.write(path, settings);
      expect(json(path, 'settings.json'), {'format': SettingsFile.mimeType, 'version': LegacyProject.lastVersion + 1});
      expect((json(path, 'manifest.json')['modules']! as Map).keys, [for (final m in ProjectModules.settings) m.id]);
      final read = await SettingsFile.read(path);
      expect((read.barNumbers, read.colorNames, read.transition), (false, true, 0.8));
      expect(read.extensions, {'captions': true});
    });
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
      c.setPlayheadColor(const Color(0xFFCC3300));
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
      final typography = ScoreTypography.standard.withValue('names.size', 1.2).withValue('lyrics.face', TextFace.bold);
      await c.setTypography(typography);
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
      expect(jsonEncode(ProjectModules.toJson(c2.projectState)), jsonEncode(ProjectModules.toJson(saved)));
      expect(c2.partName(part), 'Solo Piccolo');
      expect(c2.condensed, {'cond-P2-P3', 'cond-P6-P12'});
      expect(c2.pairs, const [PlayerPair('P6', 'P12')]);
      expect(c2.score!.condensed.map((g) => g.id), contains('cond-P6-P12'));
      expect(c2.scene!.condensed, {'cond-P2-P3', 'cond-P6-P12'});
      expect(c2.textById(vivo.id)!.current, 'Presto');
      expect(c2.partOrder.first, 'P17');
      expect((c2.scene!.sections, c2.scene!.barNumbers), (true, false));
      expect(c2.scene!.pointerColor, const Color(0xFFCC3300), reason: 'drawn over the score and in the video');
      expect(c2.playheadColor, const Color(0xFFCC3300));
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
      expect((c2.typography, c2.scene!.typography, c2.score!.typography), (typography, typography, typography));
      expect(c2.source!.bytes, demoScore.readAsBytesSync());
      expect(doc2.isDirty, isFalse);
      expect(doc2.title, 'round.ccs');
      expect(c2.canUndo, isFalse, reason: 'a freshly opened project has no history');
    });
  });
}
