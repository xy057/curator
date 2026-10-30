import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/web_export.dart';
import 'package:curated_score/web_page.dart';
import 'package:curated_score/web_player/page_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a page shows the score as the editor does, the viewer’s choices as exported; an earlier page is replaced, other files never', () async {
    final c = EditorController(vsync: const TestVSync());
    addTearDown(c.dispose);
    await c.openFile(demoScore.path);
    final folder = Directory.systemTemp.createTempSync('web-export-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final player = Uint8List.fromList(ZipEncoder().encodeBytes(Archive()
      ..add(ArchiveFile.string('index.html', '<html><head><title>Curator</title></head></html>'))));
    final out = '${folder.path}/Intro';
    final page = WebPage(
      title: 'Intro <1>',
      staffSpace: c.staffSpace,
      ratio: 16 / 9,
      firstBar: 1,
      lastBar: c.score!.timeline.measureStarts.length - 1,
      recordings: const [],
      captionStyle: const CaptionStyle(),
      speed: const WebChoice(0.75, open: true),
      barNumbers: const WebChoice(false),
    );
    await WebExport.write(c, out, page: page, player: player);
    expect(File('$out/index.html').readAsStringSync(), contains('<title>Intro &lt;1&gt;</title>'));

    final loaded = await LoadedPage.load((path) => File('$out/${WebPage.folder}/$path').readAsBytes());
    expect(loaded.page.recordings.single.audio, isNull, reason: 'no recording: silent');
    expect((loaded.page.speed.value, loaded.page.speed.open, loaded.page.barNumbers.open), (0.75, true, false));

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
    final hidden = loaded.curation({c.score!.metadata.parts.first.id: PartShown.hidden});
    expect(hidden.lane(c.score!.metadata.parts.first.id), isEmpty, reason: 'the viewer hid it');

    // Again over it: replaced. A folder of anything else: refused, untouched.
    await WebExport.write(c, out, page: page, player: player);
    final other = Directory('${folder.path}/Other')..createSync();
    File('${other.path}/notes.txt').writeAsStringSync('mine');
    await expectLater(WebExport.write(c, other.path, page: page, player: player), throwsA(isA<Exception>()));
    expect(other.listSync().map((e) => e.path.split('/').last), ['notes.txt']);
  });
}
