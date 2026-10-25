import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/image_patch.dart';
import 'package:curated_score/project_file.dart';
import 'package:curated_score/project_state.dart';
import 'package:archive/archive.dart' show ArchiveFile, ZipDecoder, ZipEncoder, getCrc32;
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart' show HorizontalSpacer;

import 'demo_project.dart';

/// 4 × 2 red pixels.
final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEklEQVR4nGP4z8DwHxkzoAsAAA8hD/EEN8afAAAAAElFTkSuQmCC');
final svg = utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" width="30" height="10"><rect width="30" height="10" fill="blue"/></svg>');

/// A plain grey PNG of [width] × [height] (8-bit grey, or 1-bit: far smaller), compressed
/// as any PNG is: a few kilobytes even when huge.
Uint8List greyPng(int width, int height, {bool oneBit = false}) {
  List<int> chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    final crc = getCrc32(body);
    int b(int v, int s) => (v >> s) & 0xff;
    return [b(data.length, 24), b(data.length, 16), b(data.length, 8), b(data.length, 0), ...body, b(crc, 24), b(crc, 16), b(crc, 8), b(crc, 0)];
  }

  int b(int v, int s) => (v >> s) & 0xff;
  final row = 1 + (oneBit ? (width + 7) ~/ 8 : width);
  final raw = Uint8List(row * height); // filter 0, all black
  return Uint8List.fromList([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    ...chunk('IHDR', [b(width, 24), b(width, 16), b(width, 8), b(width, 0), b(height, 24), b(height, 16), b(height, 8), b(height, 0), oneBit ? 1 : 8, 0, 0, 0, 0]),
    ...chunk('IDAT', zlib.encode(raw)),
    ...chunk('IEND', const []),
  ]);
}

void main() {
  late EditorController c;

  Future<void> open(WidgetTester tester) async {
    c = EditorController(vsync: const TestVSync());
    await tester.runAsync(() => c.openFile(demoScore.path));
  }

  testWidgets('a project saves the images on the score, and opens them again', (tester) async {
    await open(tester);
    c.setExtension('attachImage', true); // the project's: saved with it
    await tester.runAsync(() async {
      await c.images.add(ImageKind.raster, png, quarter: 3, top: 2, extension: 'png');
      await c.images.add(ImageKind.vector, svg, quarter: 12, top: 5);
    });
    c.images.update(1, c.images.patches[1].copyWith(crop: const Rect.fromLTRB(0, 0.5, 0.5, 1), ink: true));
    c.images.remove(0); // its file is left out of the save
    final state = c.projectState;
    expect(state.images.keys, [state.edits.patches.single.image]);

    final dir = Directory.systemTemp.createTempSync('ccs-images-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/a.ccs';
    final opened = await tester.runAsync(() async {
      await ProjectFile.write(path,
          ProjectContents(scoreName: 'demo.musicxml', scoreBytes: demoScore.readAsBytesSync(), state: state));
      // An unreadable image no patch shows is never read: the project still opens.
      final zip = ZipDecoder().decodeBytes(File(path).readAsBytesSync())
        ..add(ArchiveFile.bytes('images/junk.png', Uint8List.fromList([1, 2, 3])));
      File(path).writeAsBytesSync(ZipEncoder().encodeBytes(zip));
      return ProjectFile.read(path, mediaDirectory: '${dir.path}/media');
    });
    expect(opened!.state.edits.patches, state.edits.patches);
    expect(opened.state.images.values.single.bytes, svg);

    final again = EditorController(vsync: const TestVSync());
    await tester.runAsync(
        () => again.openProject(name: 'demo.musicxml', scoreBytes: opened.scoreBytes, state: opened.state));
    expect(again.images.patches, state.edits.patches);
    expect(again.images.enabled, isTrue, reason: 'Attach Image on in the project, though off in the app');
    expect(again.scene!.patches.single.crop, const Rect.fromLTRB(0, 0.5, 0.5, 1));
    expect(again.scene!.patches.single.ink, isTrue);
    again.dispose();

    // Saved before projects kept their extensions: one it uses takes the app's old switch when
    // that was on; else it stays unchosen (the open dialog asks), and once kept it is stored off.
    final old = ProjectState(edits: opened.state.edits.copyWith(extensions: const {}), images: opened.state.images);
    for (final legacy in [true, false]) {
      final o = EditorController(vsync: const TestVSync())..legacyExtensions = {'attachImage': legacy};
      await tester.runAsync(() => o.openProject(name: 'demo.musicxml', scoreBytes: opened.scoreBytes, state: old));
      expect((o.images.enabled, o.extensionChosen('attachImage')), (legacy, legacy));
      if (!legacy) {
        final revision = o.editRevision.value;
        o.keepExtensions(['attachImage']);
        expect(o.projectState.edits.extensions, {'attachImage': false});
        expect((o.canUndo, o.editRevision.value), (false, revision + 1), reason: 'saved with it, nothing to undo');
      }
      o.dispose();
    }
    c.dispose();
  });

  testWidgets('spacers: a vertical one is a lane of its own, a horizontal one a stretch widened; moved, saved, undone, off with the extension', (tester) async {
    await open(tester);
    final first = c.score!.metadata.parts.first.id;
    await tester.runAsync(() => c.spacers.addVertical(below: first));
    expect(c.spacers.vertical, isEmpty, reason: 'Attach Image off');
    c.setExtension('attachImage', true);
    await tester.runAsync(() => c.spacers.addVertical(below: first));
    expect(c.partOrder.indexOf('spacer-1'), c.partOrder.indexOf(first) + 1);
    expect(c.laneParts.map((p) => p.id), contains('spacer-1'));
    final beat = c.score!.timeline.measureStarts[4] + 1;
    await tester.runAsync(() => c.spacers.addHorizontal(beat, beat + 4)); // across a barline
    expect(c.spacers.horizontal, [const HorizontalSpacer(bar: 4, offset: 1, length: 4)]);
    expect(c.scene!.gapRects(c.timeline.secondsAtQuarter(beat), const Size(960, 540)), isNotEmpty);

    final state = ProjectState.fromJson(jsonDecode(jsonEncode(c.projectState.toJson())) as Map<String, Object?>);
    expect(state.edits.spacers, c.spacers.vertical);
    expect(state.edits.gaps, c.spacers.horizontal);

    await tester.runAsync(() async => c.undo());
    expect(c.spacers.horizontal, isEmpty);
    await tester.runAsync(() async => c.redo());
    expect(c.spacers.horizontal, hasLength(1));

    // Moved (the selection with it), to the top, then removed by Delete.
    expect(c.spacers.selectedHorizontal, 0, reason: 'a new one is selected');
    await tester.runAsync(() => c.spacers.moveHorizontal(0, beat + 1));
    expect((c.spacers.horizontal.single.offset, c.spacers.horizontal.single.length, c.spacers.selectedHorizontal), (2.0, 4.0, 0));
    c.spacers.moveVertical('spacer-1', 0);
    expect(c.laneParts.first.id, 'spacer-1');
    c.commands.delete();
    expect(c.spacers.horizontal, isEmpty);
    c.spacers.selectVertical('spacer-1');
    await tester.runAsync(() async => c.commands.delete());
    expect(c.spacers.vertical, isEmpty);
    await tester.runAsync(() async => c.undo());
    expect(c.spacers.vertical, hasLength(1));

    c.setExtension('attachImage', false); // kept, not engraved
    while (c.isReengraving) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    expect(c.score!.metadata.parts.map((p) => p.id), isNot(contains('spacer-1')));
    expect(c.spacers.vertical, hasLength(1));
    c.dispose();
  });

  testWidgets('an image too big to decode is refused, and a big one is scaled down', (tester) async {
    final bomb = greyPng(9000, 9000, oneBit: true); // 81 megapixels, about 10 KB
    expect(bomb.length, lessThan(100000));
    Future<Object?> decodeError(PatchImage image) => tester.runAsync<Object?>(() async {
          try {
            await image.decode();
            return null;
          } catch (e) {
            return e;
          }
        });

    expect(await decodeError(PatchImage('a.png', ImageKind.raster, bomb)),
        isA<FormatException>().having((e) => e.message, 'message', 'Use an image under 64 MB.'));
    final inSvg = utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10" height="10">'
        '<image width="10" height="10" xlink:href="data:image/png;base64,${base64Encode(bomb)}"/></svg>');
    expect(await decodeError(PatchImage('a.svg', ImageKind.vector, inSvg)),
        isA<FormatException>().having((e) => e.message, 'message', 'Use an image under 64 MB.'));
    expect(await decodeError(PatchImage('a.png', ImageKind.raster, Uint8List(PatchImage.maxBytes + 1))),
        isA<FormatException>().having((e) => e.message, 'message', 'Use an image under 64 MB.'));

    final art = await tester.runAsync(() => PatchImage('b.png', ImageKind.raster, greyPng(8192, 16)).decode()) as RasterArt;
    expect(art.size, const Size(4096, 8), reason: 'scaled to the longest side kept, its shape kept');
    art.dispose();
  });
}
