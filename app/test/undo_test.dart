
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/attacca_version.dart';
import 'package:curated_score/audio_track.dart';
import 'package:curated_score/daw_follow_dialog.dart' show attaccaMissing;
import 'package:curated_score/daw_link.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/file_names.dart';
import 'package:curated_score/project_file.dart';
import 'package:curated_score/project_modules.dart';
import 'package:curated_score/project_state.dart';
import 'package:curated_score/toolbar_layout.dart';
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

  test('Undo: one history through every kind of edit, whichever tab; anchors to a tempo map and back; recordings in lanes; a DAW followed through Attacca, its recording marked and one a project, its tracks kept as stems, the mix recorded through an Attacca Capturer', () async {
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
      // Out of sight on another tab it isn't selected: Delete there is that tab's.
      c.tab = BottomTab.instruments;
      expect(c.automation.hasSelection, isFalse);
      c.tab = BottomTab.video;
      c.automation.select(0);
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

    // A script curates as the tools do, as one Undo step; one with something wrong changes nothing; the lanes written
    // as a script make themselves again; the script is kept with the project, and typing it is no edit.
    {
      await open();
      final names = c.lanes.scriptNames, before = c.curation!.lanes, starts = c.timeline.measureStarts;
      final ran = c.lanes.runScript('clear\nshow ${LaneScript.quoted(names.first)} 1-4\nonly ${LaneScript.quoted(names.last)} 9\ntransition 0.6');
      expect([ran.problems, ran.changed], [isEmpty, true]);
      expect(c.curation!.lane(c.laneRows.first.id), [Region(starts[0], starts[4])]);
      expect(c.curation!.lane(c.laneRows.last.id), [Region(starts[8], starts[9])]);
      expect(c.curation!.transition, 0.6);
      c.undo();
      expect([c.curation!.lanes, c.curation!.transition, c.canUndo], [before, 0.3, false], reason: 'one step');
      final wrong = c.lanes.runScript('clear\nshow "No Such Lane" 1');
      expect(['${wrong.problems.single}', wrong.changed, c.curation!.lanes, c.canRedo], ['Line 2: There is no lane named “No Such Lane”.', false, before, true]);
      expect([for (final p in c.lanes.checkScript('show all 99')) '$p'], ['Line 1: There is no bar 99.']);

      final written = c.lanes.asScript;
      c.lanes.clear();
      expect(c.lanes.runScript(written).problems, isEmpty);
      expect(c.curation!.lanes, before);

      final revision = c.editRevision.value;
      c.undo();
      c.lanes.script = written;
      expect([c.editRevision.value > revision, c.canRedo], [true, true], reason: 'saved, and no edit');
      final saved = ProjectModules.toJson(c.projectState);
      expect(ProjectModules.script.read(JsonReader(saved['script'], 'script'), const ProjectState(), (_, {required limit}) => null).script, written);

      // A macro runs as the script it is for now (the lanes selected, from the playhead): one Undo step, its lanes still
      // selected; a step that needs what isn't there changes nothing; the bars it asks for are checked; the app keeps macros.
      const solo = LaneMacro(name: 'Solo', steps: [MacroStep(MacroAction.only, range: MacroRange.fromPlayhead), MacroStep(MacroAction.bridge, lanes: MacroLanes.all)]);
      final kept = c.curation!.lanes, top = c.laneRows.first.id;
      c.clearSelection();
      final none = c.lanes.runMacro(solo);
      expect(['${none.problems.single}', none.changed, c.curation!.lanes], ['Step 1: lanes', false, kept]);
      c.lanes.selectLane(top);
      expect([c.lanes.runMacro(solo).changed, c.lanes.selectedPartIds], [true, {top}]);
      expect([c.curation!.lane(top), c.curation!.lane(c.laneRows.last.id)], [[Region(0, starts.last)], isEmpty]);
      c.undo();
      expect(c.curation!.lanes, kept, reason: 'one step');
      const asks = LaneMacro(name: 'Show', steps: [MacroStep(MacroAction.show, lanes: MacroLanes.all, range: MacroRange.ask)]);
      expect([for (final p in c.lanes.checkMacro(asks, asked: '99')) '$p'], ['Step 1: There is no bar 99.']);
      expect([asks.asks, c.lanes.checkMacro(asks, asked: '1-2')], [true, isEmpty]);
      // The app keeps them; a macro's own toolbar button follows it as the list changes, and goes with it.
      final settings = AppSettings.memory()..macros = [solo, asks.copyWith(icon: 'tidy')];
      expect([settings.macros.last.icon, LaneMacro.read(LaneMacro.write(settings.macros))], ['tidy', settings.macros]);
      final bar = ToolbarLayout.standard(BarKind.instruments);
      expect([bar.bar.contains(BarItem.script), bar.bar.contains(BarItem.macros), bar.palette.contains(BarItem.script)], [false, false, true]);
      final pinned = bar.added(BarItem.macro2);
      expect([pinned.bar.indexOf(BarItem.macro2), pinned.added(BarItem.macro2), pinned.without(BarItem.macro2)], [bar.bar.indexOf(BarItem.zoomOut), pinned, bar]);
      expect(pinned.added(BarItem.macro5).bar.length, pinned.bar.length + 1, reason: 'one rule sets the macros apart');
      expect(pinned.macrosMoved((at) => at == 1 ? 0 : 1).bar.contains(BarItem.macro1), isTrue);
      expect(pinned.macrosMoved((at) => at == 1 ? null : at), bar);
      expect(ToolbarLayout.read(BarKind.instruments, pinned.write()), pinned);
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
      say({'t': 'hello', 'token': discovery['token'], 'protocol': 1, 'host': 'Cubase 15', 'plugin': '0.9.0', 'pid': 4242});
      say(song([[0, 0], [3, 6], [9, 15]]));
      await until(() => link.find('doc') != null);
      final (session, document) = link.find('doc')!;
      expect(session.host, 'Cubase 15');
      // A DAW is supported by the ARA interfaces it gives Attacca (its song, its transport), never
      // by its name: one that leaves one out is told of, and not followed but by ⌥. A plug-in
      // that doesn't say which the DAW gives (an older one, as here) is taken to give them.
      expect(session.supported, isTrue);
      DawDocument given(List<String>? interfaces) => DawDocument.fromJson({'id': 'd', 'interfaces': ?interfaces});
      expect([for (final i in [null, ['audio', 'archiving', 'content', 'updates', 'playback'], ['audio', 'archiving', 'content'], ['audio', 'archiving']]) given(i).missing],
          [<String>[], <String>[], ['playback'], ['content', 'playback']]);
      say({'t': 'document', 'id': 'bare', 'name': 'Bare', 'interfaces': ['audio', 'archiving', 'content']});
      await until(() => link.find('bare') != null);
      expect(session.missing, ['playback']);
      expect((session.supported, attaccaMissing(session.missing)), (false, 'It doesn’t let plug-ins run its transport.'));
      say({'t': 'closed', 'id': 'bare'});
      await until(() => link.find('bare') == null);
      expect(session.supported, isTrue, reason: 'by what its documents say now');
      // The version of the Attacca Curator bundles in its discovery file: Attacca's own, apart
      // from Curator's build. A plug-in older than it is outdated; one of that version isn't,
      // whatever Curator's build (nor is one that doesn't say its version).
      expect((discovery['build'], session.outdated), (attaccaVersion, false));
      Future<Socket> connecting(int version) async {
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, discovery['port']! as int);
        // (Its name not UTF-8, a byte astray: read as it can be, the connection kept.)
        final hello = utf8.encode('${jsonEncode({'t': 'hello', 'token': discovery['token'], 'protocol': 1, 'host': 'Cubase 15', 'build': version})}\n');
        final astray = utf8.decode(hello).indexOf('Cubase') + 6;
        socket.add([...hello.take(astray), 0xff, ...hello.skip(astray)]);
        return socket;
      }
      final older = await connecting(attaccaVersion - 1);
      await until(() => link.sessions.length == 2);
      final same = await connecting(attaccaVersion);
      await until(() => link.sessions.length == 3);
      expect([for (final s in link.sessions) s.outdated], [false, true, false]);
      older.destroy();
      same.destroy();
      await until(() => link.sessions.length == 1);

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

      // The DAW letting Attacca drive its transport: Curator's seek, play and pause drive it, in
      // song time (2 s into the recording is song 2.5 s), Curator itself silent.
      expect(c.daw.drives, isFalse, reason: 'not until the DAW says it lets it');
      say({...song([[0, 0], [3, 6], [8, 15]]), 'playback': true});
      await until(() => c.daw.drives);
      Future<Object?> next() async => (await heard.moveNext()) ? jsonDecode(heard.current) : null;
      c.playback.seek(2);
      expect(await next(), {'t': 'seek', 'document': 'doc', 'at': 2.5});
      // Where the DAW says it stands a moment after is its answer to a seek before: the playhead
      // stays where it was put. Later it is the DAW's own move, followed; and the place it was
      // last asked to be is asked again, now that it is elsewhere.
      say({'t': 'transport', 'playing': false, 'seconds': 1.0, 'quarters': 2, 'tempo': 120});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(c.playback.time.value, 2);
      say({'t': 'transport', 'playing': false, 'seconds': 4.5, 'quarters': 9, 'tempo': 120});
      await until(() => c.playback.time.value == 4);
      c.playback.seek(2);
      expect(await next(), {'t': 'seek', 'document': 'doc', 'at': 2.5});
      c.playback.togglePlay();
      expect(await next(), {'t': 'play', 'document': 'doc', 'at': 2.5});
      expect(c.playback.isPlaying, isFalse, reason: 'the DAW plays, not Curator');
      say({'t': 'transport', 'playing': true, 'seconds': 2.5, 'quarters': 5, 'tempo': 120});
      await until(() => c.playback.followsDaw);
      c.playback.togglePlay();
      expect(await next(), {'t': 'stop', 'document': 'doc'});
      say({'t': 'transport', 'playing': false, 'seconds': 3.0, 'quarters': 6, 'tempo': 120});
      await until(() => !c.playback.followsDaw);

      // A recording asked of a document the DAW closes before it is written: told it is gone,
      // never waited on.
      final lost = link.recording(session, 'other', 'take-9');
      expect(await heard.moveNext(), isTrue);
      say({'t': 'closed', 'id': 'other'});
      await expectLater(lost, throwsA(isA<DawLinkException>().having((e) => e.reason, 'reason', 'gone')));
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
      expect(c.canExport, isFalse, reason: 'an ARA clip isn’t what the DAW plays: not exported');
      await c.debugAddTake(track('Karajan.flac'));
      await c.debugLoadTrack(track('Take 1.wav'), daw: fromDaw);
      expect([for (final t in c.takes) if (t.daw != null) t.id], [attacca.id], reason: 'one Attacca recording a project');
      expect(c.focus, isNot(attacca.id));
      await c.debugLoadTrack(track('Bernstein.flac'));
      expect([for (final t in c.takes) (t.label, t.daw != null)], [('Take 1', true), ('Bernstein', false)]);
      // A recording read as its window closed is held by nothing.
      final closed = AudioEngine();
      await closed.close();
      await closed.put('late', track('Late.wav'));
      expect(closed.trackOf('late'), isNull);

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

      // An Attacca Capturer in the DAW, on a connection of its own (a bundle of its own, the same
      // process): listed to the DAW's Attacca (its window's Capturer menu), linked once chosen
      // there and told so; the mix asked of it over the span the recording plays, the document's
      // Attacca asked to have the DAW play and stop; a capture under way cancelled.
      final mixer = await Socket.connect(InternetAddress.loopbackIPv4, discovery['port']! as int);
      final toMixer = StreamIterator(mixer.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()));
      void mixerSays(Map<String, Object?> message) => mixer.write('${jsonEncode(message)}\n');
      Future<Object?> told(StreamIterator<String> lines) async => (await lines.moveNext()) ? jsonDecode(lines.current) : null;
      mixerSays({'t': 'hello', 'token': discovery['token'], 'protocol': 1, 'host': 'Cubase 15', 'pid': 4242});
      mixerSays({'t': 'capturers', 'list': [{'id': 'cap', 'name': 'Stereo Out', 'channels': 2, 'rate': 48000}]});
      await until(() => link.capturersOf(session).isNotEmpty);
      final capturer = link.capturersOf(session).single;
      expect((capturer.id, capturer.name, capturer.channels, capturer.rate, capturer.session != session), ('cap', 'Stereo Out', 2, 48000, true));
      final listed = {'t': 'inserts', 'ids': 'cap', 'names': 'Stereo Out'};
      expect([await told(toMixer), await told(toMixer)], [listed, {'t': 'linked', 'ids': ''}]);
      expect(await told(heard), listed);
      expect(link.linkedCapturerOf(session), isNull, reason: 'not until chosen in Attacca’s window');
      // An Attacca that connects after them and says nothing more (on an insert only: no document,
      // no link kept) is told of them too, as it connects.
      final insert = await Socket.connect(InternetAddress.loopbackIPv4, discovery['port']! as int);
      final toInsert = StreamIterator(insert.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()));
      insert.write('${jsonEncode({'t': 'hello', 'token': discovery['token'], 'protocol': 1, 'host': 'Cubase 15', 'pid': 4242})}\n');
      expect(await told(toInsert), listed);
      insert.destroy();
      await until(() => link.sessions.length == 2);
      say({'t': 'link', 'capturer': 'cap'});
      expect(await told(toMixer), {'t': 'linked', 'ids': 'cap'});
      expect(link.linkedCapturerOf(session)?.id, 'cap');
      final heardSoFar = <double>[];
      // The whole recording's length (lined up with it), only the region the DAW plays to be heard.
      final mix = link.capture(session, 'doc', capturer,
          from: 0.5, length: 60, played: (start: 1, end: 60), name: 'Take 1', progress: heardSoFar.add);
      expect(await told(toMixer),
          {'t': 'capture', 'document': 'doc', 'capturer': 'cap', 'from': 0.5, 'length': 60, 'name': 'Take 1', 'start': 1, 'end': 60});
      expect(await told(heard), {'t': 'stop', 'document': 'doc'}, reason: 'what rings from before isn’t the mix');
      mixerSays({'t': 'ready', 'document': 'doc', 'capturer': 'cap'});
      expect(await told(heard), {'t': 'play', 'document': 'doc', 'at': 0}, reason: 'once ready, a second before the region');
      mixerSays({'t': 'progress', 'document': 'doc', 'capturer': 'cap', 'done': 0.25});
      mixerSays({'t': 'captured', 'document': 'doc', 'capturer': 'cap', 'path': '/tmp/Mix.wav'});
      expect(await mix, '/tmp/Mix.wav');
      expect(heardSoFar, [0.25]);
      expect(await told(heard), {'t': 'stop', 'document': 'doc'});
      final cancelled = link.capture(session, 'doc', capturer, from: 0.5, length: 60, name: 'Take 1');
      expect(await told(toMixer), containsPair('t', 'capture'));
      expect(await told(heard), containsPair('t', 'stop'));
      link.cancelCapture('doc', capturer);
      expect(await told(toMixer), {'t': 'cancel', 'document': 'doc', 'capturer': 'cap'});
      mixerSays({'t': 'captured', 'document': 'doc', 'capturer': 'cap', 'error': 'cancelled'});
      await expectLater(cancelled, throwsA(isA<DawLinkException>().having((e) => e.reason, 'reason', 'cancelled')));
      expect(await told(heard), {'t': 'stop', 'document': 'doc'}, reason: 'cancelled before ready: never played, stopped');
      // The document closing under a capture: it fails as gone, and the Capturer is told to let it go.
      final orphan = link.capture(session, 'doc', capturer, from: 0.5, length: 60, name: 'Take 1');
      expect(await told(toMixer), containsPair('t', 'capture'));
      expect(await told(heard), containsPair('t', 'stop'));
      say({'t': 'closed', 'id': 'doc'});
      await expectLater(orphan, throwsA(isA<DawLinkException>().having((e) => e.reason, 'reason', 'gone')));
      expect(await told(toMixer), {'t': 'cancel', 'document': 'doc', 'capturer': 'cap'});
      expect([await told(heard), await told(heard)], [{'t': 'followers', 'names': ''}, {'t': 'stop', 'document': 'doc'}]);
      expect(c.daw.following, isNull, reason: 'its document closed, following ends: one opened again has a new id');
      Future<void> followAgain() async {
        say(song([[0, 0], [3, 6], [8, 15]]));
        await until(() => link.find('doc')?.$2.regions.isNotEmpty ?? false);
        c.daw.follow(link, (document: 'doc', source: 'take-1', region: null, bar: 2, transport: true));
        expect(await told(heard), {'t': 'followers', 'names': 'Ode'});
      }

      await followAgain();
      say({...song([[0, 0], [3, 6], [8, 15]]), 'regions': const []});
      expect(await told(heard), {'t': 'followers', 'names': ''}, reason: 'its track removed in the DAW: following ends');
      expect(c.daw.following, isNull);
      await followAgain();
      mixer.destroy();
      await until(() => link.capturersOf(session).isEmpty);
      // The mix recorded goes in place of the Attacca take, an ordinary recording from then on.
      final focused = c.focus;
      await c.debugLoadTrack(track('Mix.wav'), intoAttacca: true);
      expect((c.attaccaTake, c.takes.firstWhere((t) => t.id == attacca.id).label, c.focus), (null, 'Mix', focused));
      expect(c.canExport, isTrue, reason: 'the DAW’s mix recorded is exported');

      c.useMidiTempo(null);
      expect(c.daw.following, isNull, reason: 'another tempo chosen here ends it');
      c.daw.follow(link, (document: 'doc', source: 'take-1', region: null, bar: 1, transport: true));
      say({'t': 'transport', 'playing': true, 'seconds': 5.0, 'quarters': 10, 'tempo': 120});
      await until(() => c.playback.followsDaw);
      daw.destroy();
      await until(() => link.sessions.isEmpty && !c.playback.followsDaw && c.daw.following == null); // the DAW quit
      // One that connected and never said hello is let go as listening stops: it can't say it
      // after, to a link that listens no more.
      final mute = await Socket.connect(InternetAddress.loopbackIPv4, discovery['port']! as int);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await link.stop();
      await mute.drain<void>().timeout(const Duration(seconds: 2));
      mute.destroy();
      expect(File('${folder.path}/daw-link.json').existsSync(), isFalse, reason: 'its discovery file goes with it');
      // Asked to listen and, before it does, to stop (the switch flicked on and off): it ends off.
      unawaited(link.start());
      await link.stop();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((link.listening, File('${folder.path}/daw-link.json').existsSync()), (false, false), reason: 'the last asked holds');

      // The plug-ins installed from the zip the app bundles: each bundle in its folder, replacing
      // what was there (and one by its former name, Curator Link), its program executable; nothing
      // outside them; uninstalled, both removed.
      final plugIns = '${folder.path}/Plug-Ins';
      File('$plugIns/VST3/Attacca.vst3/Contents/old.txt').createSync(recursive: true);
      File('$plugIns/Components/Curator Link.component/Contents/Info.plist').createSync(recursive: true);
      final zip = Archive()
        ..add(ArchiveFile.string('Attacca.vst3/Contents/Info.plist',
            '<key>CFBundleShortVersionString</key>\n\t<string>$attaccaVersion</string>\n<key>CFBundleVersion</key><string>$attaccaVersion</string>'))
        ..add(ArchiveFile.string('Attacca.vst3/Contents/MacOS/Attacca', 'program'))
        ..add(ArchiveFile.string('Attacca.component/Contents/MacOS/Attacca', 'program'))
        ..add(ArchiveFile.string('Attacca Capturer.vst3/Contents/MacOS/Attacca Capturer', 'program'))
        ..add(ArchiveFile.string('Elsewhere/stray.txt', 'no'));
      await AttaccaPlugIns.install(Uint8List.fromList(ZipEncoder().encode(zip)), folder: plugIns);
      expect((AttaccaPlugIns.installed(folder: plugIns), AttaccaPlugIns.installedVersion(folder: plugIns)), ('$attaccaVersion', attaccaVersion), reason: 'its own version, a whole number');
      expect(File('$plugIns/VST3/Attacca.vst3/Contents/old.txt').existsSync(), isFalse);
      expect(Directory('$plugIns/Components/Curator Link.component').existsSync(), isFalse, reason: 'its former name goes');
      expect(File('$plugIns/Components/Attacca.component/Contents/MacOS/Attacca').statSync().modeString(), 'rwxr-xr-x');
      expect(File('$plugIns/VST3/Attacca Capturer.vst3/Contents/MacOS/Attacca Capturer').existsSync(), isTrue, reason: 'Attacca Capturer, a VST3 of its own');
      expect(Directory('$plugIns/Elsewhere').existsSync() || File('${folder.path}/Elsewhere/stray.txt').existsSync(), isFalse);
      await AttaccaPlugIns.uninstall(folder: plugIns);
      expect(AttaccaPlugIns.installed(folder: plugIns), isNull);
      expect(Directory('$plugIns/Components/Attacca.component').existsSync() || Directory('$plugIns/VST3/Attacca Capturer.vst3').existsSync(), isFalse,
          reason: 'uninstalled, all go');

      // On Windows: the user's own VST3 folder (no administrator), the two VST3s as Windows has
      // them (a DLL in a folder for its processor), the version from the file the bundle says it
      // in: one from before Attacca had its own (Curator's version and build), then its own.
      expect(AttaccaPlugIns.plugInsFolderFor('windows', {'LocalAppData': r'C:\Users\me\AppData\Local', 'HOME': '/Users/me'}), r'C:\Users\me\AppData\Local\Programs\Common');
      expect(AttaccaPlugIns.plugInsFolderFor('windows', {'USERPROFILE': r'D:\me'}), r'D:\me\AppData\Local\Programs\Common');
      expect((AttaccaPlugIns.plugInsFolderFor('windows', {'HOME': '/Users/me'}), AttaccaPlugIns.plugInsFolderFor('macos', {})), (null, null), reason: 'no home: nowhere');
      expect(AttaccaPlugIns.plugInsFolderFor('macos', {'HOME': '/Users/me'}), '/Users/me/Library/Audio/Plug-Ins');
      final windowsZip = Archive()
        ..add(ArchiveFile.string('Attacca.vst3/Contents/Resources/version.txt', '0.9.621+621\n'))
        ..add(ArchiveFile.string('Attacca.vst3/Contents/x86_64-win/Attacca.vst3', 'program'))
        ..add(ArchiveFile.string('Attacca Capturer.vst3/Contents/x86_64-win/Attacca Capturer.vst3', 'program'));
      await AttaccaPlugIns.install(Uint8List.fromList(ZipEncoder().encode(windowsZip)), folder: plugIns);
      expect((AttaccaPlugIns.installed(folder: plugIns), AttaccaPlugIns.installedVersion(folder: plugIns)), ('0.9.621 (621)', 621));
      File('$plugIns/VST3/Attacca.vst3/Contents/Resources/version.txt').writeAsStringSync('$attaccaVersion\n');
      expect((AttaccaPlugIns.installed(folder: plugIns), AttaccaPlugIns.installedVersion(folder: plugIns)), ('$attaccaVersion', attaccaVersion));
      expect(File('$plugIns/VST3/Attacca Capturer.vst3/Contents/x86_64-win/Attacca Capturer.vst3').existsSync(), isTrue);
      await AttaccaPlugIns.uninstall(folder: plugIns);
      expect((AttaccaPlugIns.installed(folder: plugIns), Directory('$plugIns/VST3/Attacca Capturer.vst3').existsSync()), (null, false));

      // Attacca's cache cleared (Settings ▸ General ▸ DAW): the files the plug-in wrote go, one
      // half written too, and the folders left empty; one a recording open still plays stays.
      final cache = Directory('${folder.path}/DAW Link');
      for (final file in ['a1/Take 1.wav', 'Captures/b2/Mix.wav', 'Stems/c3/Strings.wav.part']) {
        File('${cache.path}/$file')
          ..createSync(recursive: true)
          ..writeAsBytesSync(Uint8List(1000));
      }
      expect(await AttaccaCache.size(folder: cache), 3000);
      await AttaccaCache.clear(folder: cache, keep: ['${cache.path}/Captures/b2/Mix.wav']);
      expect([for (final e in cache.listSync(recursive: true)) e.path.substring(cache.path.length + 1)]..sort(), ['Captures', 'Captures/b2', 'Captures/b2/Mix.wav']);
      await AttaccaCache.clear(folder: cache);
      expect(cache.listSync(), isEmpty);
      expect(await AttaccaCache.size(folder: Directory('${folder.path}/none')), 0, reason: 'no cache yet: nothing');
      await folder.delete(recursive: true);
    }
  });
}
