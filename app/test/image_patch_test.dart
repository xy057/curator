import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/image_patch.dart';
import 'package:curated_score/project_file.dart';
import 'package:curated_score/project_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';

/// 4 × 2 red pixels.
final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEklEQVR4nGP4z8DwHxkzoAsAAA8hD/EEN8afAAAAAElFTkSuQmCC');
final svg = utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" width="30" height="10"><rect width="30" height="10" fill="blue"/></svg>');

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
    expect(ProjectState.fromJson(const {}, savedVersion: 7).patches, isEmpty, reason: 'older projects have none');
  });

  test('SVG text is told from other text', () {
    expect(looksLikeSvg('<svg xmlns="http://www.w3.org/2000/svg"/>'), isTrue);
    expect(looksLikeSvg('<?xml version="1.0"?>\n<svg/>'), isTrue);
    expect(looksLikeSvg('Use an <svg> here'), isFalse);
    expect(ImageKind.ofPath('/a/B.JPG'), ImageKind.raster);
    expect(ImageKind.ofPath('/a/b.gif'), isNull);
  });
}
