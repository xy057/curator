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

  testWidgets('nothing works, and nothing is drawn, while Attach Image is off', (tester) async {
    await open(tester);
    await tester.runAsync(() => c.images.add(ImageKind.raster, png, quarter: 3, top: 2));
    expect(c.images.patches, isEmpty, reason: 'off by default');

    c.images.enabled = true;
    await tester.runAsync(() => c.images.add(ImageKind.raster, png, quarter: 3, top: 2));
    expect(c.images.patches, hasLength(1));
    expect(c.scene!.patches, hasLength(1));
    expect(c.images.selected, 0, reason: 'a new image is selected');

    c.images.enabled = false;
    expect(c.scene!.patches, isEmpty, reason: 'hidden, so not exported either');
    expect(c.images.selected, isNull);
    c.images.remove(0);
    expect(c.images.patches, hasLength(1), reason: 'and kept in the project');
    expect(c.projectState.patches, hasLength(1));
    c.dispose();
  });

  testWidgets('an image comes in at its own shape, and adding, moving and removing are Undo steps', (tester) async {
    await open(tester);
    c.images.enabled = true;
    await tester.runAsync(() => c.images.add(ImageKind.vector, svg, quarter: 6, top: 3, extension: 'svg'));
    final added = c.images.patches.single;
    expect(added.height, 12);
    expect(added.width, 36, reason: '3:1 like the SVG');
    expect(added.image, endsWith('.svg'));

    c.beginEdit();
    c.images.update(0, added.copyWith(quarter: 7));
    c.images.update(0, added.copyWith(quarter: 8, crop: const Rect.fromLTRB(0.25, 0, 1, 1)));
    c.endEdit();
    c.images.remove();
    expect(c.images.patches, isEmpty);

    c.undo();
    expect(c.images.patches.single.quarter, 8);
    expect(c.images.patches.single.crop.left, 0.25);
    c.undo();
    expect(c.images.patches.single, added, reason: 'the whole drag was one step');
    c.undo();
    expect(c.images.patches, isEmpty);
    c.redo();
    expect(c.images.patches.single, added);
    expect(c.scene!.patches, hasLength(1));
    c.dispose();
  });

  testWidgets('a project saves the images on the score, and opens them again', (tester) async {
    await open(tester);
    c.images.enabled = true;
    await tester.runAsync(() async {
      await c.images.add(ImageKind.raster, png, quarter: 3, top: 2, extension: 'png');
      await c.images.add(ImageKind.vector, svg, quarter: 12, top: 5);
    });
    c.images.update(1, c.images.patches[1].copyWith(crop: const Rect.fromLTRB(0, 0.5, 0.5, 1)));
    c.images.remove(0); // its file is left out of the save
    final state = c.projectState;
    expect(state.images.keys, [state.patches.single.image]);

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
    expect(opened!.state.patches, state.patches);
    expect(opened.state.images.values.single.bytes, svg);

    final again = EditorController(vsync: const TestVSync())..images.enabled = true;
    await tester.runAsync(
        () => again.openProject(name: 'demo.musicxml', scoreBytes: opened.scoreBytes, state: opened.state));
    expect(again.images.patches, state.patches);
    expect(again.scene!.patches.single.crop, const Rect.fromLTRB(0, 0.5, 0.5, 1));
    again.dispose();
    c.dispose();
  });

  test('a damaged image entry says what is wrong', () {
    Map<String, Object?> state(Object patch) => {'patches': [patch]};
    final image = PatchImage('a.png', ImageKind.raster, png);
    expect(
      () => ProjectState.fromJson(state({'image': 'a.png', 'quarter': 0, 'top': 0, 'width': 1, 'height': 1})),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('image of state.patches[0] is missing'))),
    );
    expect(
      () => ProjectState.fromJson(state({'image': 'a.png', 'quarter': 0, 'top': 0, 'width': 1, 'height': 1, 'crop': [0.5, 0, 0.2, 1]}),
          images: {'a.png': image}),
      throwsA(isA<FormatException>()),
    );
    for (final id in ['a:b.png', 'a/b.png', '../a.png', '.png', 'a.gif']) {
      expect(
        () => ProjectState.fromJson(state({'image': id, 'quarter': 0, 'top': 0, 'width': 1, 'height': 1}),
            images: {id: PatchImage(id, ImageKind.raster, png)}),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('not a file name'))),
        reason: '$id would be saved under another name',
      );
    }
    expect(PatchImage.isId(PatchImage.create(ImageKind.vector, svg, extension: 'SVG').id), isTrue);
    expect(ProjectState.fromJson(const {}, savedVersion: 7).patches, isEmpty, reason: 'older projects have none');
    expect(
      ProjectState.fromJson(state({'image': 'a.png', 'quarter': 0, 'top': 0, 'width': 1, 'height': 1}),
          images: {'a.png': image, 'b.png': PatchImage('b.png', ImageKind.raster, png)}).images.keys,
      ['a.png'],
      reason: 'an image on no patch is left out',
    );
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
        isA<FormatException>().having((e) => e.message, 'message', 'The image is too big.'));
    final inSvg = utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10" height="10">'
        '<image width="10" height="10" xlink:href="data:image/png;base64,${base64Encode(bomb)}"/></svg>');
    expect(await decodeError(PatchImage('a.svg', ImageKind.vector, inSvg)),
        isA<FormatException>().having((e) => e.message, 'message', 'The image is too big.'));
    expect(await decodeError(PatchImage('a.png', ImageKind.raster, Uint8List(PatchImage.maxBytes + 1))),
        isA<FormatException>().having((e) => e.message, 'message', 'The image is too big.'));

    final art = await tester.runAsync(() => PatchImage('b.png', ImageKind.raster, greyPng(8192, 16)).decode()) as RasterArt;
    expect(art.size, const Size(4096, 8), reason: 'scaled to the longest side kept, its shape kept');
    art.dispose();
  });

  test('SVG text is told from other text', () {
    expect(looksLikeSvg('<svg xmlns="http://www.w3.org/2000/svg"/>'), isTrue);
    expect(looksLikeSvg('<?xml version="1.0"?>\n<svg/>'), isTrue);
    expect(looksLikeSvg('Use an <svg> here'), isFalse);
    expect(ImageKind.ofPath('/a/B.JPG'), ImageKind.raster);
    expect(ImageKind.ofPath('/a/b.gif'), isNull);
    expect(ImageKind.types.extensions, containsAll([for (final k in ImageKind.values) ...k.extensions]));
  });
}
