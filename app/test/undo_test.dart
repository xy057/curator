
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:curated_score/audio_track.dart';
import 'package:curated_score/daw_link.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/file_names.dart';
import 'package:curated_score/project_file.dart';
import 'package:curated_score/project_modules.dart';
import 'package:curated_score/project_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late EditorController c;

  /// The demo opened in a controller of its own, the one before let go.
  Future<void> open() async {
    c.dispose();
    c = EditorController(vsync: const TestVSync());
    await c.openFile(demoScore.path);
  }

  setUp(() async {
    c = EditorController(vsync: const TestVSync());
    await c.openFile(demoScore.path);
  });
  tearDown(() => c.dispose());

  test('Undo: one history through every kind of edit, whichever tab; anchors to a tempo map and back; recordings in lanes; a DAW followed through Attacca, its recording marked and one a project, its tracks kept as stems, an Attacca Capturer capturing in its place', () async {
    // One history steps back through every kind of edit, in order, whichever tab is showing; a new edit drops the redo; nothing open, nothing to undo.
    {
      expect(c.canUndo, isFalse, reason: 'opening is not an edit');
      final part = c.score!.metadata.parts.first;
      final lanes = c.curation!.lanes;
      final vivo = c.score!.texts.firstWhere((t) => t.text == 'Vivo');

      c.curation!.clearAll(); // lanes
      c.sync!.addAnchor(const SyncAnchor(0, 1.5)); // sync
      c.renamePart(part, name: 'Solo Piccolo', abbreviation: 'Picc.'); // names
      await c.editText(vivo.id, 'Presto'); // texts
      c.setTransition(0.8); // the staff transition
      c.setStaffSpace(6); // the view: not an Undo step
      c.playerMap.set(c.playerMap.smart(SeatingPreset.ensemble)); // the player map
      c.tab = BottomTab.video;
      c.automation.draw(0, 8); // a view: the map, selected
      expect(c.automation.selected, 0);
      c.commands.delete(); // and removed

      c.tab = BottomTab.audio; // the tab doesn't decide what Undo undoes
      c.undo();
      expect(c.automation.views.stretches.single.value, SceneView.map);
      c.undo();
      expect(c.automation.views.isEmpty, isTrue);
      c.undo();
      expect(c.playerMap.map, isNull);
      c.undo();
      expect(c.curation!.transition, 0.3);
      c.undo();
      expect(c.textById(vivo.id)!.current, 'Vivo');
      c.undo();
      expect(c.partName(part), 'Piccolo');
      c.undo();
      expect(c.sync!.anchors, isEmpty);
      c.undo();
      expect(c.curation!.lanes, lanes);
      expect(c.canUndo, isFalse);
      expect(c.staffSpace, 6);

      for (var i = 0; i < 8; i++) {
        c.redo();
      }
      expect(c.automation.views.isEmpty, isTrue);
      expect(c.curation!.transition, 0.8);
      expect(c.partName(part), 'Solo Piccolo');
      expect(c.textById(vivo.id)!.current, 'Presto');
      expect(c.canRedo, isFalse);

      // A new edit after Undo drops what could be redone.
      c.undo();
      expect(c.canRedo, isTrue);
      c.setTransition(0.5);
      expect(c.canRedo, isFalse);

      // With nothing open (⌘Z on the start screen), Undo and Redo do nothing.
      await c.close();
      expect(c.canUndo, isFalse);
      c.undo();
      c.redo();
      expect(c.score, isNull);
    }

    // Anchors convert to a tempo map and back, one Undo step each; arrows move and retune the change selected.
    {
      await open();
      // With no anchors (and no MIDI file), the score's own tempo, from where bar 1 sounds.
      c.convertToTempoMap();
      expect(c.midiTempo!.tempos, [(quarter: 0.0, quartersPerMinute: c.sync!.defaultTempo)]);
      expect(c.sync!.secondsAtQuarter(12), closeTo(12 * 60 / c.sync!.defaultTempo, 1e-9));
      c.undo();
      expect(c.usesMidiTempo, isFalse);

      const hand = [SyncAnchor(0, 1), SyncAnchor(12, 6), SyncAnchor(24, 10.5), SyncAnchor(36, 16)];
      c.sync!.load(hand, leadIn: 1);
      c.convertToTempoMap();
      expect(c.usesMidiTempo, isTrue);
      for (final a in hand) {
        expect(c.sync!.secondsAtQuarter(a.quarter), closeTo(a.seconds, 1e-9));
      }

      // 6/8: a beat is a dotted quarter. The change at bar 3 (quarter 12, ♩ = 160) a beat on, then
      // 106⅔ beats a minute up to 107.
      c.anchors.selectTempo(1);
      c.anchors.moveTempo(1);
      expect(c.midiTempo!.tempos[1].quarter, 13.5);
      c.anchors.retune(1);
      expect(c.midiTempo!.tempos[1].quartersPerMinute, closeTo(107 * 1.5, 1e-9));
      c.undo();
      c.undo();
      expect(c.midiTempo!.tempos[1].quarter, 12);
      expect(c.midiTempo!.tempos[1].quartersPerMinute, closeTo(160, 1e-9));

      final followed = c.sync!.anchors;
      c.convertToAnchors();
      expect(c.usesMidiTempo, isFalse);
      expect(c.sync!.anchors, followed, reason: 'the anchors it followed, now set by hand');
      c.undo();
      expect(c.usesMidiTempo, isTrue);
      c.undo();
      expect(c.usesMidiTempo, isFalse);
      expect(c.sync!.anchors, hand);
    }

    // Recordings in lanes: one heard at a time, a region drawn takes its stretch from the others; picking one edits its sync and keeps the place; Undo keeps the takes.
    {
      await open();
      final waveform = await Waveform.analyze(Float32List(100), 100);
      AudioTrack take(String name) => AudioTrack.forTesting(name: name, length: 60, waveform: waveform);
      await c.debugAddTake(take('Karajan.flac'));
      final total = c.sync!.totalQuarters;
      expect(c.takes.single.regions, [Region(0, total)], reason: 'the first is heard throughout');
      c.sync!.addAnchor(const SyncAnchor(0, 1));
      c.sync!.addAnchor(const SyncAnchor(8, 5));
      await c.debugAddTake(take('Bernstein.flac'));
      expect([for (final t in c.takes) t.label], ['Karajan', 'Bernstein']);
      expect((c.focus, c.syncedTake, c.editsSync), ('take-2', 'take-2', true), reason: 'a new one is picked');
      expect(c.takes.last.regions, isEmpty);
      expect(c.sync!.anchors, isEmpty, reason: 'a new recording has a sync of its own');
      c.sync!.addAnchor(const SyncAnchor(0, 2));
      c.sync!.addAnchor(const SyncAnchor(8, 6));

      c.playback.seek(3); // quarter 2 in Bernstein’s
      c.editSyncOf('take-1');
      expect(c.sync!.anchors, const [SyncAnchor(0, 1), SyncAnchor(8, 5)]);
      expect(c.playback.time.value, closeTo(2, 1e-9), reason: 'quarter 2 in Karajan’s');

      // Undo goes back through Bernstein's edits, whichever is picked, and never switches.
      c.undo();
      expect(c.focus, 'take-1');
      expect(c.sync!.anchors, const [SyncAnchor(0, 1), SyncAnchor(8, 5)]);
      expect(c.projectState.edits.take('take-2')!.anchors, const [SyncAnchor(0, 2)]);
      c.redo();

      // None picked: spliced. Bernstein's region in bars 2–3 is cut out of Karajan's lane.
      c.editSyncOf('take-1');
      expect(c.editsSync, isFalse);
      c.setTakeRegions('take-2', [Region(4, 8)]);
      expect(c.takes.first.regions, [Region(0, 4), Region(8, total)]);
      expect(c.timeline.secondsAtQuarter(4), closeTo(3, 1e-9), reason: 'Karajan’s time to bar 2');
      expect(c.timeline.secondsAtQuarter(8), closeTo(5, 1e-9), reason: 'then 2 s at Bernstein’s');
      c.undo();
      expect([for (final t in c.takes) t.regions], [[Region(0, total)], isEmpty]);
      c.redo();

      // Saved and read back: the focus's sync in the sync module, the other's in its take.
      final saved = ProjectModules.toJson(c.projectState);
      final read = ProjectModules.takes.read(JsonReader(saved['takes'], 'takes'), const ProjectState(), (_, {required limit}) => null);
      expect(read.edits.focus, 'take-1');
      expect(read.edits.take('take-2')!.anchors, const [SyncAnchor(0, 2), SyncAnchor(8, 6)]);
      expect(read.edits.take('take-2')!.regions, [Region(4, 8)]);

      // Removing the focus leaves the other, with its anchors, its sync edited again.
      await c.removeTake('take-1');
      expect((c.focus, c.editsSync), ('take-2', true));
      expect(c.sync!.anchors, const [SyncAnchor(0, 2), SyncAnchor(8, 6)]);
    }

    // A DAW followed through Attacca, the plug-in's end played here over a socket: only one
    // saying the token back is heard; its tempo where the recording is placed becomes the sync's
    // (one Undo step), again as the DAW changes it; its transport moves the playhead; a recording
    // is asked for; a tempo map chosen here ends it, as the DAW going does.
    {
      await open();
      final folder = await Directory.systemTemp.createTemp('daw-link');
      final link = DawLink(folder);
      await link.start();
      final discovery = jsonDecode(File('${folder.path}/daw-link.json').readAsStringSync()) as Map<String, Object?>;
      Future<void> until(bool Function() done) async {
        for (var i = 0; i < 200 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(done(), isTrue);
      }

      final impostor = await Socket.connect(InternetAddress.loopbackIPv4, discovery['port']! as int);
      impostor.write('{"t":"hello","token":"guess","protocol":1}\n{"t":"document","id":"x"}\n');
      await impostor.drain<void>().timeout(const Duration(seconds: 2));
      expect(link.sessions, isEmpty, reason: 'a wrong token is let go');

      final daw = await Socket.connect(InternetAddress.loopbackIPv4, discovery['port']! as int);
      final heard = StreamIterator(daw.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()));
      void say(Map<String, Object?> message) => daw.write('${jsonEncode(message)}\n');
      final part = c.score!.metadata.parts.first, partName = c.partNameOf(part.id);
      Map<String, Object?> song(List<List<num>> tempo) => {
            't': 'document', 'id': 'doc', 'name': 'Symphony',
            'contexts': [{'id': 'c', 'tempo': tempo, 'bars': [[6, 8, 0]]}],
            'tracks': [
              {'id': 't', 'name': 'Strings', 'context': 'c', 'color': '#ff8000'},
              {'id': 'p', 'name': partName.toUpperCase(), 'context': 'c'},
            ],
            'sources': [{'id': 'take-1', 'name': 'Take 1', 'rate': 48000, 'frames': 48000 * 60, 'channels': 2}],
            'regions': [{'id': 'r', 'track': 't', 'source': 'take-1', 'start': 1, 'length': 59, 'from': 0.5, 'span': 59}],
          };
      say({'t': 'hello', 'token': discovery['token'], 'protocol': 1, 'host': 'Cubase 15', 'plugin': '0.9.0'});
      say(song([[0, 0], [3, 6], [9, 15]]));
      await until(() => link.find('doc') != null);
      final (session, document) = link.find('doc')!;
      expect(session.host, 'Cubase 15');
      // Supported DAWs, by their process's name; any other is told of, and not followed but by ⌥.
      expect(session.supported, isTrue);
      expect([for (final h in ['Nuendo 14', 'Studio One 6', 'REAPER', 'Logic Pro', 'Live', 'Bitwig Studio', '']) DawLink.supports(h)],
          [true, true, true, false, false, false, false]);

      final region = document.regions.single, context = document.contexts.single;
      c.daw.name = 'Ode';
      expect(c.daw.follow(link, (document: 'doc', source: 'take-1', region: null, bar: 2, transport: true)), isTrue);
      expect(await heard.moveNext(), isTrue);
      expect(jsonDecode(heard.current), {'t': 'followers', 'names': 'Ode'}, reason: 'the DAW is told who follows it');
      final pickup = c.score!.metadata.pickups.contains(0) ? c.score!.timeline.measureStarts[1] : 0.0;
      final expected = context.tempoFor(region, name: 'Cubase 15 · Strings', bar: 2, pickup: pickup)!;
      expect(c.midiTempo, expected.map);
      expect(c.sync!.startSeconds, closeTo(expected.start, 1e-9));
      c.undo();
      expect(c.usesMidiTempo, isFalse, reason: 'taking the DAW’s tempo is one Undo step');
      c.redo();

      say(song([[0, 0], [3, 6], [8, 15]])); // a faster end, as the DAW's tempo track was edited
      await until(() => c.midiTempo!.tempos.last.quartersPerMinute == 108);

      say({'t': 'transport', 'playing': true, 'seconds': 3.0, 'quarters': 6, 'tempo': 120});
      await until(() => c.playback.followsDaw);
      say({'t': 'transport', 'playing': false, 'seconds': 4.0, 'quarters': 8, 'tempo': 120});
      await until(() => !c.playback.followsDaw);
      expect(c.playback.time.value, closeTo(3.5, 1e-9), reason: 'song 4 s is 3.5 s into the recording');

      final asked = link.recording(session, 'doc', 'take-1');
      expect(await heard.moveNext(), isTrue);
      expect(jsonDecode(heard.current), {'t': 'export', 'document': 'doc', 'source': 'take-1'});
      say({'t': 'exported', 'document': 'doc', 'source': 'take-1', 'path': '/tmp/Take 1.wav'});
      expect(await asked, '/tmp/Take 1.wav');

      // Attacca's recording, loaded: its take marked as Attacca's, one a project: taken again
      // (another take picked by then) it goes back into that take; a file's goes into the
      // focus, unmarked.
      final silence = await Waveform.analyze(Float32List(100), 100);
      AudioTrack track(String name) => AudioTrack.forTesting(name: name, length: 60, waveform: silence);
      const fromDaw = (host: 'Cubase 15', source: 'take-1', name: 'Take 1');
      await c.debugLoadTrack(track('Take 1.wav'), daw: fromDaw);
      final attacca = c.attaccaTake!;
      expect((attacca.daw, attacca.label, c.focus), (fromDaw, 'Take 1', attacca.id));
      await c.debugAddTake(track('Karajan.flac'));
      await c.debugLoadTrack(track('Take 1.wav'), daw: fromDaw);
      expect([for (final t in c.takes) if (t.daw != null) t.id], [attacca.id], reason: 'one Attacca recording a project');
      expect(c.focus, isNot(attacca.id));
      await c.debugLoadTrack(track('Bernstein.flac'));
      expect([for (final t in c.takes) (t.label, t.daw != null)], [('Take 1', true), ('Bernstein', false)]);

      // Its tracks kept as stems: each asked for from where the recording starts in the song for
      // as long as it lasts; the file the plug-in writes kept as FLAC, named by the track, in its
      // colour, its part found by name (a track named after one); saved in the project, each in
      // a folder of its own, and opened again.
      Future<void> stem(String track, String name) async {
        expect(await heard.moveNext(), isTrue);
        final message = jsonDecode(heard.current) as Map<String, Object?>;
        expect((message['t'], message['track'], message['from']), ('stem', track, 0.5), reason: 'the recording’s start: song 0.5 s');
        expect(message['length'] as num, greaterThan(0));
        // A second of 16-bit mono, as any WAV the plug-in might write.
        final wav = File('${folder.path}/$name.wav');
        final data = ByteData(44 + 48000 * 2)
          ..setUint32(0, 0x52494646)
          ..setUint32(4, 36 + 48000 * 2, Endian.little)
          ..setUint32(8, 0x57415645)
          ..setUint32(12, 0x666d7420)
          ..setUint32(16, 16, Endian.little)
          ..setUint16(20, 1, Endian.little)
          ..setUint16(22, 1, Endian.little)
          ..setUint32(24, 48000, Endian.little)
          ..setUint32(28, 96000, Endian.little)
          ..setUint16(32, 2, Endian.little)
          ..setUint16(34, 16, Endian.little)
          ..setUint32(36, 0x64617461)
          ..setUint32(40, 48000 * 2, Endian.little);
        wav.writeAsBytesSync(data.buffer.asUint8List());
        say({'t': 'progress', 'document': 'doc', 'track': track, 'done': 0.5});
        say({'t': 'stemmed', 'document': 'doc', 'track': track, 'path': wav.path});
      }

      final progress = <double>[];
      final capturing = c.stems.capture(link, document.tracks, progress: progress.add);
      await stem('t', 'Strings');
      await stem('p', 'Part');
      expect(await capturing, isEmpty);
      expect(progress.last, 1);
      final [strings, played] = c.stems.list;
      expect((strings.id, strings.name, strings.color, strings.take, strings.part), ('stem-1', 'Strings', 0xffff8000, attacca.id, null),
          reason: 'in time with the Attacca take, not the focus');
      expect((played.name, played.part), (partName.toUpperCase(), part.id));
      expect(c.stems.fileOf('stem-1'), endsWith('.flac'));
      expect(File('${folder.path}/Strings.wav').existsSync(), isFalse, reason: 'the plug-in’s file is let go');
      c.undo();
      expect(c.stems.list, hasLength(2), reason: 'not an Undo step');
      c.redo();
      c.stems.setPart('stem-1', part.id);
      final saved = '${folder.path}/stems.ccs';
      await ProjectFile.write(saved, ProjectContents(
        scoreName: c.source!.name,
        scoreBytes: c.source!.bytes,
        state: c.projectState,
        stems: {for (final s in c.stems.list) s.id: ProjectMedia(name: fileNameOf(c.stems.fileOf(s.id)!), embedFrom: c.stems.fileOf(s.id)!)},
      ));
      final media = await Directory.systemTemp.createTemp('stems-media');
      final opened = await ProjectFile.read(saved, mediaDirectory: media.path);
      expect(opened.state.edits.stems, c.stems.list);
      expect(opened.state.edits.attaccaTake?.daw, fromDaw, reason: 'the mark saved');
      expect(opened.stems.keys, ['stem-1', 'stem-2']);
      expect(opened.stems['stem-1'], '${media.path}/stems/stem-1/Strings.flac');
      expect(File(opened.stems['stem-1']!).lengthSync(), File(c.stems.fileOf('stem-1')!).lengthSync());
      await media.delete(recursive: true);
      c.stems.remove('stem-2');
      expect(c.stems.list.map((s) => s.id), ['stem-1']);

      // An Attacca Capturer in the DAW: told of, the recording asked of it over the span the
      // recording plays (heard as the DAW plays it), and a capture under way cancelled.
      say({'t': 'capturers', 'list': [{'id': 'cap', 'channels': 2, 'rate': 48000}]});
      await until(() => session.capturers.isNotEmpty);
      final capturer = session.capturers.single;
      expect((capturer.id, capturer.channels, capturer.rate), ('cap', 2, 48000));
      final heardSoFar = <double>[];
      final mix = link.capture(session, 'doc', capturer, from: 0.5, length: 60, name: 'Take 1', progress: heardSoFar.add);
      expect(await heard.moveNext(), isTrue);
      expect(jsonDecode(heard.current), {'t': 'capture', 'document': 'doc', 'capturer': 'cap', 'from': 0.5, 'length': 60, 'name': 'Take 1'});
      say({'t': 'progress', 'document': 'doc', 'capturer': 'cap', 'done': 0.25});
      say({'t': 'captured', 'document': 'doc', 'capturer': 'cap', 'path': '/tmp/Mix.wav'});
      expect(await mix, '/tmp/Mix.wav');
      expect(heardSoFar, [0.25]);
      final cancelled = link.capture(session, 'doc', capturer, from: 0.5, length: 60, name: 'Take 1');
      expect(await heard.moveNext(), isTrue);
      link.cancelCapture(session, 'doc', capturer);
      expect(await heard.moveNext(), isTrue);
      expect(jsonDecode(heard.current), {'t': 'cancel', 'document': 'doc', 'capturer': 'cap'});
      say({'t': 'captured', 'document': 'doc', 'capturer': 'cap', 'error': 'cancelled'});
      await expectLater(cancelled, throwsA(isA<DawLinkException>().having((e) => e.reason, 'reason', 'cancelled')));
      say({'t': 'capturers', 'list': <Object>[]});
      await until(() => session.capturers.isEmpty);

      c.useMidiTempo(null);
      expect(c.daw.following, isNull, reason: 'another tempo chosen here ends it');
      c.daw.follow(link, (document: 'doc', source: 'take-1', region: null, bar: 1, transport: true));
      say({'t': 'transport', 'playing': true, 'seconds': 5.0, 'quarters': 10, 'tempo': 120});
      await until(() => c.playback.followsDaw);
      daw.destroy();
      await until(() => link.sessions.isEmpty && !c.playback.followsDaw);
      await link.stop();
      expect(File('${folder.path}/daw-link.json').existsSync(), isFalse, reason: 'its discovery file goes with it');

      // The plug-ins installed from the zip the app bundles: each bundle in its folder, replacing
      // what was there (and one by its former name, Curator Link), its program executable; nothing
      // outside them; uninstalled, both removed.
      final plugIns = '${folder.path}/Plug-Ins';
      File('$plugIns/VST3/Attacca.vst3/Contents/old.txt').createSync(recursive: true);
      File('$plugIns/Components/Curator Link.component/Contents/Info.plist').createSync(recursive: true);
      final zip = Archive()
        ..add(ArchiveFile.string('Attacca.vst3/Contents/Info.plist',
            '<key>CFBundleShortVersionString</key>\n\t<string>0.9.0</string>\n<key>CFBundleVersion</key><string>468</string>'))
        ..add(ArchiveFile.string('Attacca.vst3/Contents/MacOS/Attacca', 'program'))
        ..add(ArchiveFile.string('Attacca.component/Contents/MacOS/Attacca', 'program'))
        ..add(ArchiveFile.string('Elsewhere/stray.txt', 'no'));
      await AttaccaPlugIns.install(Uint8List.fromList(ZipEncoder().encode(zip)), folder: plugIns);
      expect(AttaccaPlugIns.installed(folder: plugIns), '0.9.0 (468)');
      expect(File('$plugIns/VST3/Attacca.vst3/Contents/old.txt').existsSync(), isFalse);
      expect(Directory('$plugIns/Components/Curator Link.component').existsSync(), isFalse, reason: 'its former name goes');
      expect(File('$plugIns/Components/Attacca.component/Contents/MacOS/Attacca').statSync().modeString(), 'rwxr-xr-x');
      expect(Directory('$plugIns/Elsewhere').existsSync() || File('${folder.path}/Elsewhere/stray.txt').existsSync(), isFalse);
      await AttaccaPlugIns.uninstall(folder: plugIns);
      expect(AttaccaPlugIns.installed(folder: plugIns), isNull);
      expect(Directory('$plugIns/Components/Attacca.component').existsSync(), isFalse, reason: 'uninstalled, both go');
      await folder.delete(recursive: true);
    }
  });
}
