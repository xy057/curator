// The Attach Image extension (assets/extensions/attachImage): a package, written in Lua, that
// keeps where the pictures on the score are, as the images written in the app did. Before
// those were taken out, they were put through everything in images_cases.dart (edits, damaged
// projects, replaced scores, the switch with the spacers it turns on, a page) and what they
// gave was written down; the package is held to it, as digests. The preview with its handles
// and menus, the assets and the spacers were compared pixel for pixel.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/assets_dialog.dart';
import 'package:curated_score/dialog_kit.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/extensions/extension_reader.dart';
import 'package:curated_score/image_patch.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/project_document.dart';
import 'package:curated_score/project_modules.dart';
import 'package:curated_score/project_state.dart';
import 'package:curated_score/score_view.dart';
import 'package:curated_score/web_export.dart';
import 'package:curated_score/web_page.dart';
import 'package:curated_score/web_player/page_loader.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'images_cases.dart';
import 'test_fonts.dart';
import 'window.dart';

/// Where what the package gives is written in full, to set beside what the app's own gave.
final transcripts = Platform.environment['TRANSCRIPT_DIR'];

/// [text] is what the app's own gave: [length] long, with the digest [sha].
void held(String name, String text, int length, String sha) {
  if (transcripts case final dir?) return File('$dir/$name.txt').writeAsStringSync(text);
  expect((text.length, '${sha256.convert(utf8.encode(text))}'), (length, sha), reason: name);
}


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('edits made at random, damaged projects and replaced scores give what the app’s own images gave', () async {
    final c = EditorController(vsync: const TestVSync());
    final doc = ProjectDocument(c, AppSettings.memory()..autosave = Duration.zero);
    addTearDown(() {
      doc.dispose();
      c.dispose();
    });
    await doc.importScore(demoScore.path);
    c.setExtension('attachImage', true);
    held('edits', await imageEdits(c, Random(33), 900), 4313324, '53c7ac4597df8154ef17ddc7a406bebc75731293a27e146ca2f44a5abbec50a7');
    held('load', [for (final json in imageModules(Random(5))) readImages(json)].join('\n'), 32336, '6feff48aa32d75de6e3517f3173ec671d5955e931948e68bd08f2f9ecffecea1');
    held('carry', carriedImages(Random(6), (state) => carriedExtensionData(state, carriedQuarter, end: barsAfter.last)), 14011,
        'f609ecaee0daa639d7c578960037402a16560efc00b911ae7b16a9f13d5aadbc');
  });

  test('its switch turns the spacers on and off; a page has the images, or none', () async {
    final c = EditorController(vsync: const TestVSync());
    addTearDown(c.dispose);
    await c.openFile(demoScore.path);
    held('spacers', await spacerSwitch(c), 4758, '7a582f2f99042984e3ef47a08f2f315f8980d7e26f89ab63e52fa42e6bb932cc');

    // A page with the images, and one without.
    c.setExtension('attachImage', true);
    final starts = c.timeline.measureStarts;
    await c.images.add(ImageKind.vector, svgBytes, quarter: starts[4], top: 1, extension: 'svg');
    c.images.update(1, c.images.patches[1].copyWith(ink: true, crop: const ui.Rect.fromLTRB(0.25, 0, 1, 0.5)));
    final folder = Directory.systemTemp.createTempSync('images-page-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final player = Uint8List.fromList(ZipEncoder().encodeBytes(Archive()..add(ArchiveFile.string('index.html', '<html><head><title>Curator</title></head></html>'))));
    final page = WebPage(
      title: 'Images',
      staffSpace: c.staffSpace,
      ratio: 16 / 9,
      firstBar: 1,
      lastBar: starts.length - 1,
      recordings: const [],
      captionStyle: const CaptionStyle(),
      speed: const WebChoice(1),
      barNumbers: const WebChoice(false),
    );
    final out = StringBuffer();
    for (final images in [true, false]) {
      final path = '${folder.path}/page-$images';
      await WebExport.write(c, path, page: page, player: player, images: images);
      final loaded = await LoadedPage.load((file) => File('$path/${WebPage.folder}/$file').readAsBytes());
      final names = ImageNames();
      loaded.arts.keys.forEach(names.see);
      final archive = ZipDecoder().decodeBytes(File('$path/${WebPage.folder}/${WebPage.projectFile}').readAsBytesSync());
      out.writeln(names.plain('images $images\n'
          '  drawn ${[for (final p in loaded.settings(captions: true, barNumbers: true).patches) '(${p.quarter}, ${p.top}, ${p.width}, ${p.height}, ${p.crop}, ${p.ink}, ${p.art.size})']}\n'
          '  arts ${loaded.arts.keys.toList()} spacers ${loaded.score.request.spacers.length} on ${loaded.edits.extensions}\n'
          '  files ${[for (final f in archive.files) if (f.name.contains('images')) '${f.name} ${f.name.endsWith('.json') ? String.fromCharCodes(f.content) : f.size}']}'));
    }
    held('page', '$out', 717, '95fd5e4d758896bedf5c3020eb0467ddf7b171033046a1c9106b0fc87a2e42b9');
  });

  test('the files another extension’s pictures show are kept beside Attach Image’s own', () {
    final own = PatchImage('a.png', ImageKind.raster, widePng), other = PatchImage('b.svg', ImageKind.vector, svgBytes);
    final state = ProjectState(
      edits: const EditState(extensionData: {
        'attachImage': {
          'patches': [
            {'image': 'a.png', 'quarter': 4.0, 'top': 2.0, 'width': 8.0, 'height': 4.0},
          ],
        },
      }),
      images: {'a.png': own, 'b.svg': other},
    );
    final files = <String, Uint8List>{};
    final json = ProjectModules.images.write(state, (entry, bytes, {compress = true}) => files[entry] = bytes);
    expect(json['files'], ['b.svg'], reason: 'named, as no patch of Attach Image’s does');
    expect(files.keys, ['images/a.png', 'images/b.svg']);
    final read = ProjectModules.images.read(JsonReader(jsonDecode(jsonEncode(json)), 'images'), const ProjectState(), (entry, {required limit}) => files[entry]);
    expect(read.images.keys, ['a.png', 'b.svg']);
    expect(read.edits.extensionData['attachImage'], state.edits.extensionData['attachImage'], reason: 'the extension’s data is its own: no list of files in it');
    // With only its own, the module is as it always was.
    expect(jsonEncode(ProjectModules.images.write(state.copyWith(images: {'a.png': own}), (entry, bytes, {compress = true}) {})),
        '{"patches":[{"image":"a.png","quarter":4.0,"top":2.0,"width":8.0,"height":4.0}]}');
  });

  testWidgets('pictures in the window: a click selects one, its menu, a drag, the assets, spacers, off', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    final settings = AppSettings.memory()..addRecent(demoProject.absolute.path);
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Open Sample'));
    await tester.pump();
    final state = tester.state(find.byType(ProjectPage)) as dynamic;
    for (var i = 0; i < 100 && state.controller.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500));
    final c = state.controller as EditorController;
    final context = tester.element(find.byType(ProjectPage));
    final starts = c.timeline.measureStarts;
    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));
      await screenshot(tester, name, outermost: true);
    }

    c.playback.seek(c.timeline.secondsAtQuarter(starts[2]));
    await shot('off');
    c.setExtension('attachImage', true);
    await tester.runAsync(() async {
      await c.images.add(ImageKind.raster, bigPng, quarter: starts[2], top: 4, extension: 'png');
      await c.images.add(ImageKind.vector, svgBytes, quarter: starts[3], top: 14, extension: 'svg');
    });
    c.images.update(1, c.images.patches[1].copyWith(ink: true));
    await shot('added');

    // Where the first image is: a click on it selects it.
    c.images.select(null);
    final view = tester.getRect(find.byType(ScoreView));
    Offset? on;
    for (var y = view.top + 20; y < view.bottom && on == null; y += 24) {
      for (var x = view.left + 20; x < view.right && on == null; x += 24) {
        final gesture = await tester.startGesture(Offset(x, y));
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 400));
        if (c.images.selected == 0) on = Offset(x, y);
      }
    }
    final seen = StringBuffer('first image at ${on! - view.topLeft} of ${view.size}\n');
    expect(c.images.selected, 0);
    await shot('selected');
    c.images.select(0, crop: true);
    c.images.update(0, c.images.patches[0].copyWith(crop: const ui.Rect.fromLTRB(0.25, 0.25, 1, 0.75), width: 18, height: 6));
    await shot('cropping');
    await tester.tapAt(on + const Offset(4, 4), buttons: kSecondaryButton);
    await shot('image-menu');
    for (final item in ['Done', 'Score Ink', 'Remove']) {
      expect(find.text(item), findsOneWidget, reason: 'the menu of an image being cropped');
    }
    await tester.tap(find.text('Done'));
    await shot('image-menu-done');
    await tester.tapAt(on + const Offset(4, 4), buttons: kSecondaryButton);
    await shot('image-menu-again');
    await tester.tap(find.text('Score Ink'));
    await shot('inked');
    expect(c.images.patches[0].ink, isTrue);
    await tester.tapAt(view.bottomRight - const Offset(40, 40), buttons: kSecondaryButton);
    await shot('preview-menu');
    for (final item in ['Add Image…', 'Paste']) {
      expect(find.text(item), findsOneWidget, reason: 'the menu of the score, away from an image');
    }
    await tester.tapAt(view.topLeft + const Offset(3, 3));
    await shot('menu-closed');

    // A drag by the image's body, then by a corner.
    c.images.select(0);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.dragFrom(on + const Offset(4, 4), const Offset(60, 30));
    await shot('dragged');
    seen.writeln('dragged ${c.images.patches[0].quarter} ${c.images.patches[0].top} ${c.images.patches[0].width} ${c.images.patches[0].height} undo ${c.canUndo}');
    expect(c.images.patches[0].top, 9, reason: 'moved 30 points down: 5 staff spaces');
    c.undo();
    seen.writeln('undone ${c.images.patches[0].quarter} ${c.images.patches[0].top} selected ${c.images.selected}');
    expect((c.images.patches[0].quarter, c.images.patches[0].top), (starts[2], 4), reason: 'the whole drag is one Undo step');

    unawaited(showAssetsDialog(context, c));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await screenshot(tester, 'assets', inside: find.byType(AppDialog), outermost: true);
    c.images.remove(1);
    await tester.pump(const Duration(milliseconds: 300));
    await screenshot(tester, 'assets-unused', inside: find.byType(AppDialog), outermost: true);
    await tester.tap(find.text('Remove Unused'));
    await tester.pump(const Duration(milliseconds: 300));
    await screenshot(tester, 'assets-purged', inside: find.byType(AppDialog), outermost: true);
    seen.writeln('purged: undo ${c.canUndo} unused ${c.images.unused.length} patches ${c.images.patches.length}');
    expect(c.images.unused, isEmpty);
    held('view', '$seen', 174, 'c85694c8cb4e6e66048a92b6c3c600b98c3a9d64dc7c90299a033eaa56496187');
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.runAsync(() async {
      await c.spacers.addVertical(below: c.laneParts[1].id);
      await c.spacers.addHorizontal(starts[2] + 1.5, starts[3]);
      for (var i = 0; i < 300 && c.isReengraving; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await shot('spacers');
    c.setExtension('attachImage', false);
    await tester.runAsync(() async {
      for (var i = 0; i < 300 && c.isReengraving; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await shot('off-again');
    expect((c.images.enabled, c.spacers.enabled, c.images.selected, c.sceneSettings.patches.length, c.sceneSettings.spacers.length), (false, false, null, 0, 0));
    expect((c.images.patches.length, c.spacers.vertical.length), (1, 1), reason: 'kept in the project while it is off');
  });
}
