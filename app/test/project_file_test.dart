import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/image_patch.dart';
import 'package:curated_score/project_document.dart';
import 'package:curated_score/project_file.dart';
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
      expect(jsonEncode(c2.projectState.toJson()), jsonEncode(saved.toJson()));
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
