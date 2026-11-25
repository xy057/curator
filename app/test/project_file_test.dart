import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/file_names.dart';
import 'package:curated_score/image_patch.dart';
import 'package:curated_score/project_document.dart';
import 'package:archive/archive_io.dart';
import 'package:curated_score/legacy_project.dart';
import 'package:curated_score/project_archive.dart';
import 'package:curated_score/project_file.dart';
import 'package:curated_score/project_modules.dart';
import 'package:curated_score/settings_file.dart';
import 'package:curated_score/project_state.dart';
import 'package:curated_score/score_replacement.dart';
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
        state: const ProjectState(edits: EditState(textEdits: {'d1': 'hello'}, split: {'P2'})),
        media: media,
      );

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

  /// [path]'s file in CuraScript, read.
  CuraDocument cura(String path, [String entry = 'project.cura']) =>
      CuraData.read(utf8.decode(ZipDecoder().decodeBytes(File(path).readAsBytesSync()).findFile(entry)!.content));

  /// What [path]'s module [id] holds.
  Map<String, Object?> module(String path, String id) => cura(path).modules.firstWhere((m) => m.id == id).data;

  /// [path] with its project.cura as [fields] and [modules] write it.
  void recura(String path, Map<String, Object?> fields, List<CuraModule> modules) =>
      rewrite(path, {'project.cura': utf8.encode(CuraData.write(fields, modules: modules))});

  Future<OpenedProject> open(String path) => ProjectFile.read(path, mediaDirectory: '${dir.path}/media');

  /// The demo imported into a controller and its document, let go after the test.
  Future<(EditorController, ProjectDocument)> demo() async {
    final c = EditorController(vsync: const TestVSync());
    final doc = ProjectDocument(c, AppSettings.memory()..autosave = Duration.zero);
    addTearDown(() {
      doc.dispose();
      c.dispose();
    });
    await doc.importScore(demoScore.path);
    return (c, doc);
  }

  test('saved and opened: every edit survives, a failed save leaves the file as it was, every recording travels in its own folder', () async {
    // A recent file's folder is "~" where it is home or in it, not where its name starts as home's.
    expect([for (final f in ['/Users/ann', '/Users/ann/Scores', '/Users/anna/Scores', '/tmp']) underHome(f, '/Users/ann/')], ['~', '~/Scores', '/Users/anna/Scores', '/tmp']);
    expect((underHome(r'C:\Users\ann\Scores', r'C:\Users\ann'), underHome('/a', null)), (r'~\Scores', '/a'));

    final (c, doc) = await demo();
    {
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
      expect((c.firstBar, c.shownFirstBar, c.beats.format(0, compact: true)), (null, 1, '1'));
      c.setFirstBar(145);
      c.setPlayheadColor(const Color(0xFFCC3300));
      c.setColorNames(true);
      c.setNameGroupColor('brass', const Color(0xFFE0B000));
      final solo = c.addNameGroup('Solo');
      c.setNameGroupColor(solo, const Color(0xFF123456));
      c.setNameGroup(parts[0], solo); // the piccolo in a group of its own
      c.setNameGroup(parts[15], null); // the snare drum in the ink
      c.setSections({parts[15].id: 'percussion', parts[0].id: null, 'P10': 'bracket-1', 'P11': 'bracket-1'});
      c.curation!.setLane(parts[1].id, [const Region(0, 6, hiddenStaves: [2]), const Region(6, 9)]); // meeting, not merged
      c.setSpacing(parts[2].id, (above: 2.5, below: -1));
      final starts = c.score!.timeline.measureStarts;
      c.sync!.addAnchor(SyncAnchor(starts[8], 20, jumpTo: starts[4])); // a warp: back to bar 5
      c.useMidiTempo(MidiTempoMap('tempo.mid', const [(quarter: 0, quartersPerMinute: 96), (quarter: 24, quartersPerMinute: 80)]));
      await c.setFonts(const ScoreFonts(music: MusicFont.leland));
      c.setExtension('attachImage', true);
      c.setExtension('captions', true);
      await c.images.add(ImageKind.raster, png, quarter: starts[2], top: 2);
      c.images.update(0, c.images.patches[0].copyWith(ink: true));
      c.extensions.runtime('captions')!.run('require("captions").add({from = ${starts[1]}, to = ${starts[5]}, text = "The horns answer"})');
      c.captions.setFont(TextFonts.academico);
      c.setExtension('chapters', true);
      c.extensions.runtime('chapters')!.run('local lane = require("lane")\nlane.create(${starts[4]}, "Second theme")\nlane.create(${starts[0]}, "Opening")');
      c.setExtension('tonality', true);
      c.extensions.runtime('tonality')!.run('local lane = require("lane")\n'
          'lane.add({from = ${starts[0]}, to = ${starts[16]}, tonic = 3, minor = true})\n' // A minor
          'lane.add({from = ${starts[8]}, to = ${starts[12]}, tonic = -1, minor = false, label = "(F major)"})'); // over it: cut in two
      final typography = ScoreTypography.standard.withValue('names.size', 1.2).withValue('lyrics.face', TextFace.bold);
      await c.setTypography(typography);
      // A player map: seated smartly, one player of the violins I playing the violas.
      final seated = c.playerMap.smart(SeatingPreset.american);
      final violins = seated.sections.indexWhere((s) => s.link?.part == 'P17');
      final firsts = seated.sections[violins];
      c.playerMap.set(seated.withSection(violins, firsts.withSeat(0, firsts.seats.first.linked(const PlayerLink('P19', name: 'Viola')))));
      // The Video tab: the map from bar 3 to 9, the two side by side over bars 5–6 (the map below), cut in.
      c.automation.draw(starts[2], starts[8]);
      c.automation.drawing = const SceneView(ViewKind.split, side: MapSide.bottom, size: 0.3);
      c.automation.draw(starts[4], starts[6]);
      c.automation.setSelectedFade(0);
      // …and over bars 11–12 the score's notes in rows (the MIDI view), the rows a step taller:
      // the look is the project's, and no part of the engraving.
      final engraved = c.score;
      expect((c.hasMidiView, c.rowsScene), (true, null));
      c.automation.drawing = SceneView.midi;
      c.automation.draw(starts[10], starts[12]);
      await c.setMidiLook(const MidiLook().rows(1));
      expect((identical(c.score, engraved), c.isReengraving), (true, false));
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
      expect(c2.automation.views.stretches.map((s) => (s.start, s.value.kind, s.fade)),
          [(starts[2], ViewKind.map, 0.5), (starts[4], ViewKind.split, 0.0), (starts[6], ViewKind.map, 0.5), (starts[10], ViewKind.midi, 0.5)]);
      // The rows are laid out beside the score for the view that shows them (off this isolate),
      // as the look has them, the same parts and bars; the toolbar's switch shows them throughout.
      for (var i = 0; c2.rowsScene == null && i < 500; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final rows = c2.rowsScene!.score;
      expect((rows.isRoll, rows.request.midi, identical(rows.metadata, c2.score!.metadata), identical(c2.rows, rows)),
          (true, const MidiLook().rows(1), true, true));
      expect((c2.automation.shown.from.kind, c2.automation.scoreInPlace.value), (ViewKind.score, true));
      // An image goes in, and is handled, on the toolbar's Score page alone: on another none is
      // added or pasted, and the one selected is let go of (Delete would take what nobody sees).
      final images = c2.images.patches.length;
      c2.images.select(0);
      expect((c2.images.canInsert, c2.commands.pastesImage, c2.images.selected), (true, true, 0));
      c2.showsMidiView = true;
      expect((c2.automation.shown.from.kind, c2.automation.scoreInPlace.value), (ViewKind.midi, false));
      await c2.images.add(ImageKind.raster, png, quarter: starts[2], top: 2);
      expect((c2.images.canInsert, c2.commands.pastesImage, c2.images.selected, c2.images.patches.length), (false, false, null, images));
      // …until the music plays: then the lane's views show, on the toolbar's MIDI View and its
      // Player Map alike (the score in bar 1, the map in bar 4), and the rows again once it stops.
      c2.showsPlayerMap = true;
      expect(c2.automation.playsViews, false);
      c2.playback.play();
      // (The score shows, on a page that isn't Score: still nothing of it is handled.)
      expect((c2.automation.playsViews, c2.automation.shown.from.kind, c2.automation.scoreInPlace.value), (true, ViewKind.score, false));
      c2.playback.seek(c2.timeline.secondsAtQuarter(starts[3]));
      expect((c2.automation.shown.from.kind, c2.automation.scoreInPlace.value), (ViewKind.map, false));
      c2.playback.pause();
      expect((c2.automation.playsViews, c2.automation.shown.from.kind), (false, ViewKind.midi));
      c2.playback.seek(0);
      c2.showsPlayerMap = false;
      expect(c2.images.canInsert, false); // MIDI View still
      c2.showsMidiView = false;
      expect((c2.automation.scoreInPlace.value, c2.images.canInsert), (true, true));
      expect(c2.curation!.lane(parts[1].id), const [Region(0, 6, hiddenStaves: [2]), Region(6, 9)]);
      expect(c2.spacingOf(parts[2].id), (above: 2.5, below: -1.0));
      expect(c2.condensed, {'cond-P2-P3', 'cond-P6-P12'});
      expect(c2.pairs, const [PlayerPair('P6', 'P12')]);
      expect(c2.score!.condensed.map((g) => g.id), contains('cond-P6-P12'));
      expect(c2.scene!.condensed, {'cond-P2-P3', 'cond-P6-P12'});
      expect(c2.textById(vivo.id)!.current, 'Presto');
      expect(c2.partOrder.first, 'P17');
      expect((c2.scene!.sections, c2.scene!.barNumbers), (true, false));
      // The first bar's number: the score's row starts at it, and every bar typed counts from it.
      expect((c2.firstBar, c2.shownFirstBar, c2.scene!.firstBar), (145, 145, 145));
      expect((c2.beats.format(starts[2], compact: true), c2.beats.parse('147'), c2.beats.parse('2')), ('147', starts[2], null));
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
      expect(c2.extensions.data('captions'), {
        'captions': [
          [starts[1], starts[5], 'The horns answer'],
        ],
      });
      expect(c2.scene!.captions, [Caption(starts[1], starts[5], 'The horns answer')]);
      expect(c2.captions.font, TextFonts.academico);
      expect(c2.extensions.data('chapters'), {
        'chapters': [
          [starts[0], 'Opening'],
          [starts[4], 'Second theme'],
        ],
      });
      expect(c2.extensions.data('tonality'), {
        'areas': [
          [starts[0], starts[8], 3, 'minor'],
          [starts[8], starts[12], -1, 'major', '(F major)'],
          [starts[12], starts[16], 3, 'minor'],
        ],
      });
      expect((c2.typography, c2.scene!.typography, c2.score!.typography), (typography, typography, typography));
      expect(c2.source!.bytes, demoScore.readAsBytesSync());
      expect(doc2.isDirty, isFalse);
      expect(doc2.title, 'round.ccs');
      expect(c2.canUndo, isFalse, reason: 'a freshly opened project has no history');

      // The player map came back whole, piccolo by its new name; its notes are read on an
      // isolate, and then the violins swell as their first note starts and calm down after.
      final map = c2.playerMap.map!;
      expect(map.encode(), c.playerMap.map!.encode(), reason: "as written: places to 4 decimals");
      expect(map.sections.expand((s) => [s.link, ...s.seats.map((x) => x.link)]).any((l) => l?.name == 'Solo Piccolo'), isTrue);
      expect(map.sections[violins].linkOf(0)!.part, 'P19');
      final pulses = await () async {
        for (var i = 0; i < 500 && identical(c2.playerMap.pulses, PlayerPulses.none); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return c2.playerMap.pulses;
      }();
      final link = map.sections[violins].link!, tl = c2.timeline;
      final xml = c2.score!.musicXML;
      final first = soundingNotes(xml, tl.measureStarts).where((n) => n.partId == link.part).first;
      final on = tl.secondsAtQuarter(first.start);
      expect(pulses.level(link, on - 0.01), lessThan(0.05));
      final loud = PlayerPulses.strengthOf(ScoreDynamics.read(xml, tl.measureStarts).at(link.part, first.start));
      expect(pulses.level(link, on + PlayerPulses.attack), closeTo(loud, 1e-9), reason: 'as far as its dynamic says');
      expect(pulses.level(link, on + 0.1), greaterThan(pulses.level(link, on + 0.2)));
    }

    // A failed save leaves the previous file untouched.
    {
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
    }

    // Every recording travels in the project, each in a folder of its own.
    {
      File('${dir.path}/a.wav').writeAsBytesSync([1, 2, 3]);
      File('${dir.path}/b.wav').writeAsBytesSync([4, 5]);
      final path = '${dir.path}/takes.ccs';
      await ProjectFile.write(
          path,
          ProjectContents(
            scoreName: 'Score.musicxml',
            scoreBytes: Uint8List.fromList(utf8.encode('<score-partwise/>')),
            state: const ProjectState(
                edits: EditState(focus: 'take-1', crossfade: 0.5, takes: [
              Take('take-1', 'Karajan', regions: [Region(0, 4)]),
              Take('take-2', 'Bernstein', regions: [Region(4, 8)], anchors: [SyncAnchor(0, 2)], leadIn: 2),
            ])),
            // The same name twice: each take's is its own.
            media: ProjectMedia(name: 'Take.wav', embedFrom: '${dir.path}/a.wav'),
            takes: {'take-2': ProjectMedia(name: 'Take.wav', embedFrom: '${dir.path}/b.wav')},
          ));
      final opened = await ProjectFile.read(path, mediaDirectory: '${dir.path}/media');
      expect(File(opened.media!.path!).readAsBytesSync(), [1, 2, 3]);
      expect(File(opened.takes['take-2']!).readAsBytesSync(), [4, 5]);
      expect(opened.state.edits.take('take-2')!.anchors, const [SyncAnchor(0, 2)]);
      expect(opened.state.edits.focus, 'take-1');
      expect(opened.state.edits.crossfade, 0.5);
      expect([for (final t in opened.state.edits.takes) t.regions], [[Region(0, 4)], [Region(4, 8)]]);
    }

    // A recording a project linked to and couldn't find is still named once the project is saved
    // (opened in a document, saved, opened again), and found beside the project once it is back.
    {
      final path = '${dir.path}/linked.ccs';
      await ProjectFile.write(path, ProjectContents(
        scoreName: demoScore.uri.pathSegments.last,
        scoreBytes: demoScore.readAsBytesSync(),
        state: const ProjectState(),
        missingMedia: (name: 'Concert.wav', path: '${dir.path}/elsewhere/Concert.wav', relativePath: 'Concert.wav'),
      ));
      final (_, linked) = await demo();
      expect(await linked.open(path), contains('${dir.path}/elsewhere/Concert.wav'));
      await linked.save();
      final again = await open(path);
      expect((again.media!.path, again.media!.missingPath, again.media!.link?.relativePath), (null, '${dir.path}/elsewhere/Concert.wav', 'Concert.wav'));
      File('${dir.path}/Concert.wav').writeAsBytesSync([1, 2, 3]);
      expect(((await open(path)).media!.path, (await open(path)).media!.missingPath), ('${dir.path}/Concert.wav', null));
    }
  });

  test('older formats and modules: a project in CuraScript, Curator 0.1 to 0.11 ask for an update, a project or settings file saved before modules or in JSON opens, a module unknown here kept or refused, a kind, a MIDI project, damage said where', () async {
    // A project is in CuraScript: its fields, then every module. Curator 0.1 to 0.6.1 know a
    // project in modules, and 0.7 to 0.11 one in a later layout, and ask for an update.
    {
      final path = '${dir.path}/new.ccs';
      await ProjectFile.write(path, contents());
      final zip = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
      expect(zip.files.first.name, 'mimetype');
      // What they read: project.json's format, then its version above theirs (26 at most);
      // manifest.json's format, then its layout above theirs (2).
      expect(json(path, 'project.json'), {'format': ProjectFile.mimeType, 'version': LegacyProject.lastVersion + 1});
      expect(json(path, 'manifest.json'), {'format': ProjectFile.mimeType, 'layout': 3});
      expect(zip.files.where((f) => f.name.startsWith('modules/')), isEmpty);
      final document = cura(path);
      expect([document.fields['format'], document.fields['layout'], document.fields['writer']], [ProjectFile.mimeType, 3, ProjectArchive.writer]);
      expect([for (final m in document.modules) (m.id, m.version, m.optional)], [for (final m in ProjectModules.all) (m.id, m.version, m.optional)]);
      // A field a line, what is in a field under it.
      final text = utf8.decode(zip.findFile('project.cura')!.content);
      expect(text, contains('\nmodule texts version 1\n  edits\n    d1 "hello"\n'));
      expect(text, contains('\nmodule curation version 2\n  split ["P2"]\n'));
      final opened = (await open(path)).state.edits;
      expect([opened.textEdits, opened.split], [{'d1': 'hello'}, {'P2'}]);
    }

    // A project of Curator 0.7 to 0.11, its modules in JSON, opens and says it is older, a
    // module of a newer build's kept as it came (but one CuraScript couldn't write again: a
    // version that isn't one, a number past a double's, fields too deep); saved here, all of it
    // is in CuraScript, the same.
    {
      final path = '${dir.path}/json.ccs';
      List<int> encoded(Object? json) => utf8.encode(jsonEncode(json));
      // Whatever JSON holds: a whole number and one with a point apart, text of lines, escapes.
      final harmony = <String, Object?>{
        'keys': [1, 2.0, -0.5, 1e-7, 1e21],
        'text': 'two\n  lines\n\n# not a comment\n',
        'quoted': 'a "b" \\ c\td',
        'odd': 'x\u0001\u2028\r\n',
        'deep': [[1, [2, [3]]], {}, [], {'x': null, 'y': true}, 'a\nb'],
        'module': 'a field so called',
        '': 'no name',
        'é😀 key': 'ü',
      };
      File(path).writeAsBytesSync(ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.string('mimetype', ProjectFile.mimeType))
        ..add(ArchiveFile.bytes('project.json', encoded({'format': ProjectFile.mimeType, 'version': LegacyProject.lastVersion + 1})))
        ..add(ArchiveFile.bytes('manifest.json', encoded({
          'format': ProjectFile.mimeType,
          'layout': 2,
          'writer': 'Curator 0.11.0-beta1 (687)',
          'kind': 'score',
          'score': {'name': 'Score.musicxml', 'entry': 'score/Score.musicxml'},
          'modules': {
            'texts': {'version': 1},
            'curation': {'version': 1},
            'sync': {'version': 1},
            'harmony': {'version': 3, 'optional': true},
            'odd': {'version': -1, 'optional': true},
            'huge': {'version': 2, 'optional': true},
            'deep': {'version': 2, 'optional': true},
          },
        })))
        ..add(ArchiveFile.bytes('modules/odd.json', encoded({'a': 1})))
        ..add(ArchiveFile.string('modules/huge.json', '{"n": 1e400}'))
        ..add(ArchiveFile.string('modules/deep.json', '{"a": ${'[' * CuraData.maxDepth}${']' * CuraData.maxDepth}}'))
        ..add(ArchiveFile.bytes('modules/texts.json', encoded({'edits': {'d1': 'hello'}})))
        ..add(ArchiveFile.bytes('modules/curation.json', encoded({'lanes': {'P1': [[1, 2, 0.3, null]]}})))
        ..add(ArchiveFile.bytes('modules/sync.json', encoded({'leadIn': 1.5, 'anchors': [[8, 4.0, 0], [4, 2]]})))
        ..add(ArchiveFile.bytes('modules/harmony.json', encoded(harmony)))
        ..add(ArchiveFile.bytes('harmony/bar-1.bin', [1, 2, 3]))
        ..add(ArchiveFile.string('score/Score.musicxml', '<score-partwise/>'))));
      final opened = await open(path);
      expect(opened.olderFormat, isTrue);
      final e = opened.state.edits;
      expect([e.textEdits, e.lanes, e.leadIn, e.anchors], [
        {'d1': 'hello'},
        {'P1': [const Region(1, 2, transitionIn: 0.3)]},
        1.5,
        [const SyncAnchor(4, 2), const SyncAnchor(8, 4, jumpTo: 0)],
      ]);
      expect(opened.state.foreign.keys, ['harmony']);

      final again = '${dir.path}/again.ccs';
      await ProjectFile.write(again, ProjectContents(scoreName: 'Score.musicxml', scoreBytes: Uint8List(1), state: opened.state));
      final zip = ZipDecoder().decodeBytes(File(again).readAsBytesSync());
      expect(zip.files.where((f) => f.name.startsWith('modules/')), isEmpty);
      final kept = cura(again).modules.firstWhere((m) => m.id == 'harmony');
      expect((kept.version, kept.optional, jsonEncode(kept.data)), (3, true, jsonEncode(harmony)));
      expect(zip.findFile('harmony/bar-1.bin')!.content, [1, 2, 3]);
      final saved = await open(again);
      expect(saved.olderFormat, isFalse);
      expect(jsonEncode(ProjectModules.toJson(saved.state)), jsonEncode(ProjectModules.toJson(opened.state)));
      expect(jsonEncode(saved.state.foreign['harmony']!.json), jsonEncode(harmony));
    }

    // A project saved before modules opens with every field in its module.
    {
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

      final opened = await open(path);
      expect(opened.olderFormat, isTrue);
      final state = opened.state;
      final e = state.edits;
      expect(e.barNumbers, isFalse, reason: 'saved before bar numbers (format 18): off, as it was made');
      expect(e.partNames, {'P1': (name: 'Solo Piccolo', abbreviation: '')});
      expect(e.sections, {'P2': null, 'P3': 'bracket-1'});
      expect(e.centeredLyrics, isTrue);
      expect((e.transition, e.leadIn), (0.5, 1));
      expect(e.lanes, {'P1': [const Region(1, 2, transitionIn: 0.3)]});
      expect(e.anchors, [const SyncAnchor(4, 2), const SyncAnchor(8, 4, jumpTo: 0)]);
      expect(e.extensionData['captions'], {
        'captions': [
          [1, 2, 'Hi'],
        ],
      });
      expect(state.view.time, 3);

      // Saved again: in modules, the same.
      await ProjectFile.write(path, ProjectContents(scoreName: 'Score.musicxml', scoreBytes: Uint8List(1), state: state));
      final saved = await open(path);
      expect(saved.olderFormat, isFalse);
      expect(json(path, 'project.json')['version'], LegacyProject.lastVersion + 1);
      expect(jsonEncode(ProjectModules.toJson(saved.state)), jsonEncode(ProjectModules.toJson(state)));
    }

    // A module this version can't read is kept when it may go unread, refused when not.
    {
      final path = '${dir.path}/later.ccs';
      await ProjectFile.write(path, contents());
      final (:fields, :modules) = cura(path);
      List<CuraModule> plus(CuraModule extra) => [...modules.where((m) => m.id != extra.id), extra];

      recura(path, fields, plus((id: 'harmony', version: 3, optional: true, data: {'keys': [1, 2]})));
      rewrite(path, {'harmony/bar-1.bin': [1, 2, 3]});
      final opened = await open(path);
      expect(opened.state.edits.textEdits, {'d1': 'hello'});
      expect(opened.state.foreign.keys, ['harmony']);
      // Saved here: still there, as it came.
      final again = '${dir.path}/again.ccs';
      await ProjectFile.write(again, ProjectContents(scoreName: 'Score.musicxml', scoreBytes: Uint8List(1), state: opened.state));
      final kept = cura(again).modules.firstWhere((m) => m.id == 'harmony');
      expect([kept.version, kept.optional, kept.data], [3, true, {'keys': [1, 2]}]);
      expect(ZipDecoder().decodeBytes(File(again).readAsBytesSync()).findFile('harmony/bar-1.bin')!.content, [1, 2, 3]);

      for (final extra in <CuraModule>[
        (id: 'harmony', version: 1, optional: false, data: {}), // a module of a newer version, needed
        (id: 'sync', version: 99, optional: false, data: {}), // a newer version of one known here
      ]) {
        recura(path, fields, plus(extra));
        await expectLater(open(path), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('newer Curator'))));
      }
      // So is a file of a later layout.
      recura(path, {...fields, 'layout': 4}, modules);
      await expectLater(open(path), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('newer Curator'))));
    }

    // A project keeps its kind in the manifest; one without a kind is its score's.
    {
      final path = '${dir.path}/kind.ccs';
      await ProjectFile.write(path, ProjectContents(
          scoreName: 'Score.pdf', scoreBytes: Uint8List(1), state: const ProjectState(kind: ProjectKind.pdf)));
      final (:fields, :modules) = cura(path);
      expect(fields['kind'], 'pdf');
      expect((await open(path)).state.kind, ProjectKind.pdf);
      // Carried to its score read again (Edit… done), it is still a PDF's.
      const none = ScoreMetadata(title: '', parts: [], tempo: null, activeMeasures: {});
      final carried = ScoreSwap(before: none, after: none, textsBefore: const [], textsAfter: const [])
          .carry(const ProjectState(kind: ProjectKind.pdf), condensable: const [], measuresBefore: const [0, 4], measuresAfter: const [0, 4]);
      expect(carried.state.kind, ProjectKind.pdf);

      for (final kind in [null, 'tablature']) { // older than kinds; a newer Curator's kind
        recura(path, {...fields..remove('kind'), 'kind': ?kind}, modules);
        expect((await open(path)).state.kind, ProjectKind.score);
      }
      await ProjectFile.write(path, contents());
      expect(cura(path).fields['kind'], 'score');
    }

    // A MIDI file is a project of its own kind: its notes in rows, in the MIDI view, playing by
    // the file's tempo; how the rows look is an edit, saved in a module of its own.
    {
      final file = File('${dir.path}/duet.mid')..writeAsBytesSync(duetMidi);
      final c = EditorController(vsync: const TestVSync());
      final doc = ProjectDocument(c, AppSettings.memory()..autosave = Duration.zero);
      addTearDown(() {
        doc.dispose();
        c.dispose();
      });
      await doc.importMidi(file.path);
      expect((c.isMidi, c.projectState.kind, c.score!.isRoll, c.fileName), (true, ProjectKind.midi, true, 'duet.mid'));
      expect([for (final p in c.score!.metadata.parts) (p.name, p.family)],
          [('Flute', InstrumentFamily.woodwinds), ('Cello', InstrumentFamily.strings)]);
      expect(c.score!.timeline.measureStarts, [0, 3, 6]);
      expect((c.colorNames, c.hasNotes, c.followsFileTempo), (true, true, true));
      expect(c.condensable, isEmpty);
      // The file's tempo left, and put back (MIDI ▸ Use File’s Tempo): nothing to do once it is.
      c.useMidiTempo(null);
      expect((c.followsFileTempo, c.useFileTempo(), c.followsFileTempo, c.useFileTempo()), (false, true, true, false));

      // A look is one Undo step, the rows laid out again each way.
      Future<void> laidOut() async {
        for (var i = 0; c.isReengraving && i < 2000; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      final look = const MidiLook(velocity: false).rows(1);
      final rowHeight = c.score!.engraving.staves.first.height;
      await c.setMidiLook(look);
      expect((c.midiLook, c.score!.request.midi), (look, look));
      expect(c.score!.engraving.staves.first.height, closeTo(rowHeight * MidiLook.step, 1e-3));
      c.undo();
      await laidOut();
      expect((c.midiLook, c.score!.engraving.staves.first.height), (const MidiLook(), rowHeight));
      c.redo();
      await laidOut();
      expect(c.score!.request.midi, look);

      final path = '${dir.path}/duet.ccs';
      await doc.save(path);
      expect(cura(path).fields['kind'], 'midi');
      expect(jsonEncode(module(path, 'midi')), jsonEncode({'look': look.toJson()}));
      final again = EditorController(vsync: const TestVSync());
      final opened = ProjectDocument(again, AppSettings.memory()..autosave = Duration.zero);
      addTearDown(() {
        opened.dispose();
        again.dispose();
      });
      await opened.open(path);
      expect((again.isMidi, again.midiLook, again.score!.isRoll, again.followsFileTempo), (true, look, true, true));
      expect(again.score!.engraving.staves.first.height, c.score!.engraving.staves.first.height);

      // In place of a score (Replace…), the project becomes a MIDI one; a score has no look to keep.
      final (score, scoreDoc) = await demo();
      final scorePath = '${dir.path}/score.ccs';
      await scoreDoc.save(scorePath);
      expect(module(scorePath, 'midi'), isEmpty);
      await scoreDoc.replaceScore(await scoreDoc.prepareReplacementWith('duet.mid', duetMidi, midi: true));
      expect((score.isMidi, score.score!.isRoll, score.score!.metadata.parts.length), (true, true, 2));
    }

    // File ▸ New Project: a blank score, one staff of empty bars, unsaved from the start; saved, a score project.
    {
      final c = EditorController(vsync: const TestVSync());
      final doc = ProjectDocument(c, AppSettings.memory()..autosave = Duration.zero);
      addTearDown(() {
        doc.dispose();
        c.dispose();
      });
      await doc.newScore('Untitled.musicxml', 'Melody');
      expect((c.score!.metadata.parts.single.name, c.score!.timeline.measureStarts.length, doc.isDirty, doc.title),
          ('Melody', 5, true, 'Untitled.musicxml')); // 4 bars and the end
      final path = '${dir.path}/Untitled.ccs';
      await doc.save(path);
      expect((doc.isDirty, cura(path).fields['kind']), (false, 'score'));
    }

    // A damaged module says where; CuraScript that doesn't read, its line.
    {
      final path = '${dir.path}/damaged.ccs';
      await ProjectFile.write(path, contents());
      final (:fields, :modules) = cura(path);
      recura(path, fields, [
        for (final m in modules) m.id == 'sync' ? (id: 'sync', version: 1, optional: false, data: {'anchors': [[1, 'x']]}) : m,
      ]);
      await expectLater(open(path), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('sync.anchors[0]'))));
      final lines = CuraData.write(fields, modules: modules).split('\n');
      final at = lines.indexWhere((l) => l.trimLeft().startsWith('leadIn '));
      lines[at] = '  leadIn zero';
      rewrite(path, {'project.cura': utf8.encode(lines.join('\n'))});
      await expectLater(
          open(path),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', 'The project is damaged: project.cura, line ${at + 1}: “zero” isn’t a value: text goes in quotes.')));
    }

    // Settings files are in CuraScript too; one saved before modules still imports, and exports in CuraScript.
    {
      final path = '${dir.path}/look.ccf';
      const settings = EditState(barNumbers: false, colorNames: true, transition: 0.8, extensions: {'captions': true});
      await SettingsFile.write(path, settings);
      expect(json(path, 'settings.json'), {'format': SettingsFile.mimeType, 'version': LegacyProject.lastVersion + 1});
      expect([for (final m in cura(path, 'settings.cura').modules) m.id], [for (final m in ProjectModules.settings) m.id]);
      final (settings: read, :olderFormat) = await SettingsFile.read(path);
      expect(olderFormat, isFalse);
      expect((read.barNumbers, read.colorNames, read.transition), (false, true, 0.8));
      expect(read.extensions, {'captions': true});
    }
    {
      // One of Curator 0.7 to 0.11, its modules in JSON.
      final path = '${dir.path}/json.ccf';
      File(path).writeAsBytesSync(ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.string('mimetype', SettingsFile.mimeType))
        ..add(ArchiveFile.string('settings.json', jsonEncode({'format': SettingsFile.mimeType, 'version': LegacyProject.lastVersion + 1})))
        ..add(ArchiveFile.string('manifest.json', jsonEncode({'format': SettingsFile.mimeType, 'layout': 2, 'modules': {'display': {'version': 1}}})))
        ..add(ArchiveFile.string('modules/display.json', jsonEncode({'barNumbers': false, 'transition': 0.8})))));
      final (:settings, :olderFormat) = await SettingsFile.read(path);
      expect([olderFormat, settings.barNumbers, settings.transition], [true, false, 0.8]);
    }
    {
      final path = '${dir.path}/old.ccf';
      final zip = Archive()
        ..add(ArchiveFile.string('settings.json', jsonEncode({
          'format': SettingsFile.mimeType,
          'version': 25,
          'state': {
            'barNumbers': false,
            'flags': {'centredLyrics': true},
            'curation': {'transition': 0.8, 'lanes': {'P1': []}},
            'partNames': {'P1': {'name': 'Not a setting'}},
          },
        })));
      File(path).writeAsBytesSync(ZipEncoder().encodeBytes(zip));
      final (:settings, :olderFormat) = await SettingsFile.read(path);
      expect(olderFormat, isTrue);
      expect((settings.barNumbers, settings.centeredLyrics, settings.transition), (false, true, 0.8));
      expect(settings.lanes, isNull, reason: 'only the score-wide settings');
      expect(settings.partNames, isEmpty);

      final again = '${dir.path}/again.ccf';
      await SettingsFile.write(again, settings);
      expect(json(again, 'settings.json')['version'], LegacyProject.lastVersion + 1);
      final reread = await SettingsFile.read(again);
      expect(reread.olderFormat, isFalse);
      expect(reread.settings.centeredLyrics, isTrue);
    }

    // The demo, saved by Curator 0.6.1 or before, opens, and saves in the new format.
    {
      final (c, doc) = await demo();
      final path = '${dir.path}/older.ccs';
      demoProject.copySync(path);
      await doc.open(path);
      expect(doc.isOlderFormat, isTrue);
      final before = jsonEncode(ProjectModules.toJson(c.projectState));
      expect(json(path, 'project.json')['version'], lessThanOrEqualTo(LegacyProject.lastVersion), reason: 'untouched until saved');

      await doc.save();
      expect(doc.isOlderFormat, isFalse);
      expect(cura(path).fields['format'], ProjectFile.mimeType);
      await doc.open(path);
      expect(doc.isOlderFormat, isFalse);
      expect(jsonEncode(ProjectModules.toJson(c.projectState)), before);
    }
  });
}
