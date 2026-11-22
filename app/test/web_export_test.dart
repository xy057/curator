import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/updater.dart' show appBuild, appRelease, repositoryUrl;
import 'package:curated_score/web_player/player.dart' show pageIcons;
import 'package:curated_score/web_export.dart';
import 'package:curated_score/web_page.dart';
import 'package:curated_score/web_player/page_api.dart';
import 'package:curated_score/web_player/page_audio.dart';
import 'package:curated_score/web_player/page_loader.dart';
import 'package:curated_score/web_player/playing_page.dart';
import 'package:curated_score/web_plugins.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a page shows the score as the editor does, the viewer’s choices as exported; an earlier page is replaced, other files never', () async {
    final c = EditorController(vsync: const TestVSync());
    addTearDown(c.dispose);
    await c.openFile(demoScore.path);
    c.playerMap.set(c.playerMap.smart(SeatingPreset.american));
    final folder = Directory.systemTemp.createTempSync('web-export-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final player = Uint8List.fromList(ZipEncoder().encodeBytes(Archive()
      ..add(ArchiveFile.string('index.html', '<html><head><title>Curator</title></head></html>'))));
    final out = '${folder.path}/Intro';
    final bare = WebPage(
      title: 'Intro <1>',
      staffSpace: c.staffSpace,
      ratio: 16 / 9,
      firstBar: 1,
      lastBar: c.score!.timeline.measureStarts.length - 1,
      recordings: const [],
      captionStyle: const CaptionStyle(),
      speed: const WebChoice(0.75, open: true),
      barNumbers: const WebChoice(false),
      view: const WebChoice(PageShows.map, open: true),
    );
    // Curator's own web plugins, as the app bundles them, and one of someone's, from its file.
    BundledWebPlugins.set({
      for (final folder in Directory('assets/web_plugins').listSync().whereType<Directory>())
        folder.path.split('/').last: {
          for (final file in folder.listSync(recursive: true).whereType<File>()) file.path.substring(folder.path.length + 1): file.readAsBytesSync(),
        },
    });
    final counter = BundledWebPlugins.byId('barCounter')!;
    final theirs = WebPluginPackage.read(WebPluginPackage(
      manifest: const {'id': 'com.example.hello', 'name': 'Hello', 'version': '1.2.0', 'api': 1},
      main: 'export default function (curator) {}\n',
      sources: const {'main.ts': 'export default function (curator: unknown) {}\n'},
      locales: const {'ja': {'Hello': 'こんにちは'}},
      assets: {'hello.txt': Uint8List.fromList('hello'.codeUnits)},
    ).write());
    final plugins = [WebPagePlugin.of(counter, const {'corner': 'bottomLeft', 'beats': 'yes', 'other': 1}), WebPagePlugin.of(theirs)];
    final page = WebPage(
      title: bare.title,
      staffSpace: bare.staffSpace,
      ratio: bare.ratio,
      firstBar: bare.firstBar,
      lastBar: bare.lastBar,
      recordings: const [],
      captionStyle: bare.captionStyle,
      speed: bare.speed,
      barNumbers: bare.barNumbers,
      view: bare.view,
      plugins: plugins,
    );
    await WebExport.write(c, out, page: page, plugins: [counter, theirs], player: player);
    expect(File('$out/index.html').readAsStringSync(), contains('<title>Intro &lt;1&gt;</title>'));
    expect(File('$out/${WebExport.sourceFile}').readAsStringSync(), contains(repositoryUrl), reason: 'where the player’s source is');

    final loaded = await LoadedPage.load((path) => File('$out/${WebPage.folder}/$path').readAsBytes());
    expect(loaded.page.recordings.single.audio, isNull, reason: 'no recording: silent');
    expect((loaded.page.speed.value, loaded.page.speed.open, loaded.page.barNumbers.open), (0.75, true, false));
    // The player map goes with the project, shown first, the viewer free to switch; a page
    // written before it chose among three says the map or not, one before the map nothing: the
    // Video tab's views, kept to.
    expect(loaded.edits.playerMap!.encode(), c.playerMap.map!.encode());
    expect((loaded.page.view.value, loaded.page.view.open), (PageShows.map, true));
    final viewer = {...(page.toJson()['viewer'] as Map<String, Object?>)}..remove('view');
    WebChoice<PageShows> earlier(Map<String, Object?> more) => WebPage.fromJson(page.toJson()..['viewer'] = {...viewer, ...more}).view;
    final (before, mapped) = (earlier(const {}), earlier(const {'playerMap': {'value': true, 'open': true}}));
    expect((before.value, before.open, mapped.value, mapped.open), (PageShows.views, false, PageShows.map, true));

    // The same frame as the editor's preview.
    final heard = loaded.page.recordings.single;
    final scene = CuratedScene(loaded.score, style: RenderStyle(staffSpace: page.staffSpace))
      ..settings = loaded.settings(captions: true, barNumbers: true)
      ..setTimeline(loaded.timeline(heard));
    addTearDown(scene.dispose);
    Future<Uint8List> frame(CuratedScene scene, Curation curation) async {
      final image = scene.renderFrame(960, 540, time: 20, curation: curation, devicePixelRatio: 1); // 540 points high
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      image.dispose();
      return bytes;
    }

    expect(await frame(scene, loaded.curation(const {})), await frame(c.scene!, c.curation!));
    // The MIDI view of the score is the page's too: it lays the notes out in rows itself, as
    // the project's look has them, and can be what the page shows.
    final rows = loaded.score.rows(loaded.edits.midiLook), own = c.rows!;
    expect((loaded.score.hasRows, rows.engraving.commandCount, rows.engraving.width), (true, own.engraving.commandCount, own.engraving.width));
    expect(WebPage.fromJson(page.toJson()..['viewer'] = {...viewer, 'view': {'value': 'midi', 'open': false}}).view.value, PageShows.midi);
    final hidden = loaded.curation({c.score!.metadata.parts.first.id: PartShown.hidden});
    expect(hidden.lane(c.score!.metadata.parts.first.id), isEmpty, reason: 'the viewer hid it');

    // The page's plugins: each in its folder beside the score with what a page runs of it (its
    // code, texts and assets, not its source), listed with its settings as the export had them:
    // one set to what it can't be is the plugin's own; a file that isn't a plugin says so.
    final (first, second) = (loaded.page.plugins.first, loaded.page.plugins.last);
    expect((first.id, second.id, second.version), ('barCounter', 'com.example.hello', '1.2.0'));
    expect(first.settings, {'corner': 'bottomLeft', 'beats': true});
    expect(second.locales, ['ja']);
    final carried = Directory('$out/${WebPage.folder}/${WebPage.pluginFolder(theirs.id)}');
    expect({for (final f in carried.listSync(recursive: true).whereType<File>()) f.path.substring(carried.path.length + 1)}, {'main.js', 'locales/ja.json', 'assets/hello.txt'});
    expect(File('$out/${WebPage.folder}/${WebPage.pluginFolder('barCounter')}/main.js').readAsStringSync(), counter.main);
    expect((loaded.page.release, loaded.page.build), (appRelease, appBuild));
    expect(() => WebPluginPackage.fromFiles({'plugin.json': Uint8List.fromList('{"id": "com.example.x"}'.codeUnits)}),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('main.js'))));
    await expectLater(WebExport.write(c, '${folder.path}/Gone', page: page, player: player), throwsA(isA<Exception>()), reason: 'a plugin listed and not given');
    // Kept by the app: ticked ones go into a page, in the order listed, each as it is set.
    final kept = WebPlugins(AppSettings.memory())..add(theirs);
    kept.turn('barCounter', true);
    kept.set(counter, 'corner', 'topLeft');
    expect([for (final p in kept.chosen) (p.plugin.id, p.plugin.settings['corner'])], [('barCounter', 'topLeft'), ('com.example.hello', null)]);
    kept.remove(theirs.id);
    expect((kept.packages.any((p) => p.id == theirs.id), kept.isOn(theirs.id)), (false, false));
    kept.dispose();

    // What the page's plugins ask of the player, and are told: the page as it plays, with no
    // widget. Times are from the start of what is heard; lists start at 0.
    {
      final playing = PlayingPage(loaded, audioFor: (_) => SilentAudio());
      final api = PageApi(playing);
      addTearDown(() {
        api.dispose();
        playing.dispose();
      });
      final told = <(String, Map<String, Object?>)>[];
      playing.listener = (event, data) {
        told.add((event, data));
        return event == 'click';
      };
      final bars = api.call('score.bars') as List<Object?>, timeline = playing.scene.timeline;
      expect((bars.length, (bars[3] as Map)['index'], (bars[3] as Map)['number']), (c.score!.timeline.measureStarts.length - 1, 3, 4));
      expect(api.call('score.seconds', [(bars[3] as Map)['start']]), closeTo(timeline.secondsAtQuarter(c.score!.timeline.measureStarts[3]) - playing.heard.start, 1e-9));
      expect(api.call('score.format', [api.call('score.parse', ['4.2'])]), '4.2');
      expect((api.call('page') as Map)['player'], {'release': appRelease, 'build': appBuild});
      expect((api.call('page') as Map)['available'], ['score', 'midi', 'map'], reason: 'no views in the Video tab to follow');
      expect((api.call('score.parts') as List).length, c.score!.metadata.parts.length);
      expect((api.call('score.notes', [c.score!.metadata.parts.first.id]) as List), isNotEmpty);
      // Moved, and told of it; the bar that then sounds is told as the frame comes.
      api.call('playback.seek', [20]);
      playing.tick();
      expect([for (final (event, _) in told) event], ['seek', 'time', 'bar']);
      expect((api.call('playback.time'), told.last.$2['index']), (20.0, (api.call('score.barAt', [api.call('score.quarter', [20])]) as Map)['index']));
      api.call('playback.setSpeed', [1.25]);
      api.call('view.setShows', ['midi']);
      api.call('view.setBarNumbers', [true]);
      expect((playing.speed, playing.shows, playing.barNumbers), (1.25, PageShows.midi, true));
      expect([for (final (event, _) in told.skip(3)) event], ['speed', 'view', 'barNumbers']);
      expect(() => api.call('view.setShows', ['views']), throwsArgumentError, reason: 'the page has none to follow');
      expect(() => api.call('playback.seek', ['soon']), throwsArgumentError);
      expect(() => api.call('nothing'), throwsArgumentError);
      // Where a place in the score is drawn, and back, once the frame is laid out.
      playing.setFrame(const ui.Rect.fromLTWH(10, 20, 960, 540), 1);
      api.call('view.setShows', ['score']);
      final at = api.call('view.quarterAt', [300]) as double;
      expect(api.call('view.xOf', [at]), closeTo(300, 1e-6));
      expect((api.call('view.frame') as Map)['x'], 10);
      expect(playing.clicked(300, 100), isTrue, reason: 'a plugin kept the click');
      expect(told.last.$2['quarter'], at);
      // What a plugin adds: a button, an option under its name, a key, room at an edge.
      api.call('ui.button', [{'id': 'a#1', 'title': 'Loop', 'icon': 'loop', 'checked': true}]);
      api.call('ui.button', [{'id': 'a#1', 'title': 'Loop', 'icon': 'loop', 'checked': false}]);
      api.call('ui.option', [{'id': 'a#2', 'group': 'Hello', 'type': 'choice', 'label': 'Side', 'value': 'left', 'options': [{'value': 'left', 'label': 'Left'}, {'value': 'right'}]}]);
      api.call('ui.key', ['a#3', 'shift+l']);
      api.call('ui.insets', [0, 0, 300, 0]);
      expect((api.buttons.single.checked, api.options.single.options.last.label, api.keys.values.single, api.insets[2]), (false, 'right', 'a#3', 300.0));
      expect(pageIcons.keys, contains(api.buttons.single.icon));
      api.changed('a#2', 'right');
      expect((api.options.single.value, told.last.$1), ('right', 'ui.change'));
      expect(told.last.$2, {'id': 'a#2', 'value': 'right'});
      expect(() => api.call('ui.key', ['a#4', 'shift+']), throwsArgumentError);
      api.call('ui.removeButton', ['a#1']);
      expect(api.buttons, isEmpty);
      api.call('ui.hideControls', [true]);
      expect((playing.controlsShown.value, told.last.$1), (false, 'controls'));
    }

    // Served here to try it: the page, a range of a file (Safari's <audio> asks for them), nothing above it.
    final server = await WebPreview.serve(out);
    addTearDown(() => server.close(force: true));
    final client = HttpOverrides.runWithHttpOverrides(HttpClient.new, _Network()); // the binding's answers every request 400
    addTearDown(client.close);
    Future<HttpClientResponse> get(String path, [String? range, String? host]) async {
      final request = await client.get('localhost', server.port, path);
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      if (host != null) request.headers.host = host;
      return request.close();
    }
    final index = await get('/');
    expect((index.statusCode, index.headers.contentType?.mimeType), (200, 'text/html'));
    await index.drain<void>();
    final part = await get('/${WebPage.folder}/${WebPage.pageFile}', 'bytes=0-0');
    expect((part.statusCode, String.fromCharCodes(await part.expand((b) => b).toList())), (206, '{'));
    final outside = await get('/../${File(out).uri.pathSegments.last}/index.html');
    expect(outside.statusCode, 404);
    await outside.drain<void>();
    final past = await get('/${WebPage.folder}/${WebPage.pageFile}', 'bytes=99999999-');
    expect(past.statusCode, 416);
    await past.drain<void>();
    final rebound = await get('/', null, 'example.com'); // a site whose name now points here
    expect(rebound.statusCode, 403);
    await rebound.drain<void>();

    // Again over it: what the export writes replaced, what else is there (a repository) kept.
    // A folder of anything else: refused, untouched.
    File('$out/.git/HEAD').createSync(recursive: true);
    File('$out/${WebPage.folder}/${WebPage.pageFile}').writeAsStringSync('{}');
    await WebExport.write(c, out, page: page, plugins: [counter, theirs], player: player);
    expect(File('$out/.git/HEAD').existsSync(), isTrue);
    expect(File('$out/${WebPage.folder}/${WebPage.pageFile}').readAsStringSync(), isNot('{}'));
    final other = Directory('${folder.path}/Other')..createSync();
    File('${other.path}/notes.txt').writeAsStringSync('mine');
    await expectLater(WebExport.write(c, other.path, page: page, player: player), throwsA(isA<Exception>()));
    expect(other.listSync().map((e) => e.path.split('/').last), ['notes.txt']);
  });
}

/// The network as it is.
class _Network extends HttpOverrides {}
