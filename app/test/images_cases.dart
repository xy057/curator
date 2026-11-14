// What the Attach Image extension is put through, and what is written down of it: edits made
// at random, projects that are damaged, scores that are replaced, its switch and the spacers.
// The app's own images were put through the same before the package took their place; what
// they gave is the digests in attach_image_extension_test.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/extensions/extension.dart';
import 'package:curated_score/extensions/extension_reader.dart';
import 'package:curated_score/image_patch.dart';
import 'package:curated_score/project_modules.dart';
import 'package:curated_score/project_state.dart';
import 'package:curated_score/score_replacement.dart';

// PNGs of 4 × 2, 3 × 9, 40 × 4, 5 × 5, 3 × 3 and 40 × 20 pixels: the same bytes wherever the tests run.
final widePng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAKElEQVR4nAXBAREAMAjEMDgUVMZUvAbkoL5Lqgff4A7eYHXwBTd4wQ+rggtxeKugBwAAAABJRU5ErkJggg==');
final tallPng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAMAAAAJCAYAAAD3s5bZAAAAU0lEQVR4nBXHMRHAIBAAwUyKCLnySyQg4YUgAUFIQBASaC/z2+3zfhgf5ofP2zE6Zq9MjIk5KxtjY+7KxbiYt9IwGmarDIyBOSoLY2GuysE4mAd/ZOIw3GV4r2YAAAAASUVORK5CYII=');
final stripPng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAACgAAAAECAYAAAD8kH0gAAABOklEQVR4nIXNoRKCQABFUWdMO0Sj0Ui80ehsMhqJRiORtGMkEolGItHZZCQaiUYi0fB8f+AHnDmbbUBlQJeAmoAeAU0BrQHtAzoFdAuoC+gZ0CegIiACqgK62w/2b/uv/cH+bF/b9/Yv+8V+Z3+0v9q39qP9bP/v32wjKiO6RNRE9IhoimiNaB/RKaJbRF1Ez4g+ERUREVEV0d1+sH/bf+0P9mf72r63f9kv9jv7o/3VvrUf7Wf7f/9mm1CZ0CWhJqFHQlNCa0L7hE4J3RLqEnom9EmoSIiEqoTu9oP92/5rf7A/29f2vf3LfrHf2R/tr/at/Wg/2//7N9uMyowuGTUZPTKaMloz2md0yuiWUZfRM6NPRkVGZFRldLcf7N/2X/uD/dm+tu/tX/aL/c7+aH+1b+1H+9n+3/8DIjNKkIlqVjwAAAAASUVORK5CYII=');
final squarePng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAUAAAAFCAYAAACNbyblAAAATklEQVR4nBXIMREAIQwAwS8oIwUZV0QAclJGCkIQxsz9sOV+I3AGrsAK3IHfSJyJK7ESd75snI2rsRp3vzw4D66DdXCflxfnxXWxLu6LP6EZNKS/TkL5AAAAAElFTkSuQmCC');
final smallPng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAMAAAADCAYAAABWKLW/AAAALElEQVR4nBXHMREAMAgAMTYUoAMtTEh5FWj+XrMlsrALtzBysAd3fg77cA8fNrARp1LHdvIAAAAASUVORK5CYII=');
final bigPng = base64Decode('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');

final svgBytes = Uint8List.fromList(utf8.encode(
    '<svg xmlns="http://www.w3.org/2000/svg" width="30" height="10" viewBox="0 0 30 10"><rect width="30" height="10" fill="#c03"/></svg>'));

/// The images added: wide, tall, wider than a new one may be, vectors, square.
final testImages = <({String name, ImageKind kind, Uint8List bytes, String extension})>[
  (name: 'wide', kind: ImageKind.raster, bytes: widePng, extension: 'png'),
  (name: 'tall', kind: ImageKind.raster, bytes: tallPng, extension: 'PNG'),
  (name: 'strip', kind: ImageKind.raster, bytes: stripPng, extension: ''),
  (name: 'vector', kind: ImageKind.vector, bytes: svgBytes, extension: 'svg'),
  (name: 'square', kind: ImageKind.raster, bytes: squarePng, extension: 'jpeg'),
];

/// Each image's id is made at random: written down by the order they are first seen in.
class ImageNames {
  final _names = <String, String>{};

  void see(String id) => _names.putIfAbsent(id, () => 'I${_names.length + 1}.${id.split('.').last}');

  String plain(String text) {
    for (final MapEntry(key: id, value: name) in _names.entries) {
      text = text.replaceAll(id, name);
    }
    return text;
  }
}

String _patch(ImagePatch p) => '(${p.image}, ${p.quarter}, ${p.top}, ${p.width}, ${p.height}, ${p.crop}, ${p.ink})';

/// The project's images module as it is saved, with its files.
String imagesModule(ProjectState state) {
  final files = <String>[];
  try {
    final json = jsonEncode(ProjectModules.images.write(state, (entry, bytes, {compress = true}) => files.add('$entry ${bytes.length} $compress')));
    return '$json $files';
  } on FileSystemException catch (e) {
    return 'FileSystemException ${e.message} ${e.path}';
  }
}

/// What there is of the images now: the project as saved, the selection, what the scene draws,
/// the files kept, what uses the extension, what the Edit menu offers.
String imagesNow(EditorController c, ImageNames names) {
  final images = c.images;
  for (final p in images.patches) {
    names.see(p.image);
  }
  for (final i in images.unused) {
    names.see(i.id);
  }
  return names.plain([
    'module ${imagesModule(c.projectState)}',
    'selected ${images.selected} cropping ${images.cropping} enabled ${images.enabled} spacers ${c.spacers.enabled}',
    'patches ${[for (final p in images.patches) _patch(p)]}',
    'stored ${[for (final i in images.stored) '${i.id} ${i.kind.name} ${i.bytes.length} uses ${images.usesOf(i.id)} drawn ${images.artOfImage(i.id)?.size}']}',
    'unused ${[for (final i in images.unused) i.id]}',
    'scene ${[for (final p in c.sceneSettings.patches) '(${p.quarter}, ${p.top}, ${p.width}, ${p.height}, ${p.crop}, ${p.ink}, ${p.art.size})']}',
    'undo ${c.canUndo} redo ${c.canRedo} used ${Extensions.usedBy(c).map((e) => e.id).toList()} delete ${c.commands.canDelete} paste ${c.commands.pastesImage} '
        'time ${c.playback.time.value.toStringAsFixed(6)} revision ${c.editRevision.value}',
  ].join('\n  '));
}

/// [steps] edits made at random, each written down with [imagesNow] after it.
Future<String> imageEdits(EditorController c, Random random, int steps) async {
  final out = StringBuffer(), names = ImageNames();
  final total = c.beats.totalQuarters, starts = c.beats.measureStarts;
  double place() => switch (random.nextInt(4)) {
        0 => random.nextInt(total.ceil() + 4) - 2.0,
        1 => random.nextInt((total * 2).ceil()) / 2,
        2 => random.nextDouble() * total,
        _ => starts[random.nextInt(starts.length)],
      };
  Rect crop() {
    if (random.nextInt(4) == 0) return ImagePatch.full;
    final left = random.nextInt(3) / 4, top = random.nextInt(3) / 4;
    return Rect.fromLTRB(left, top, min(1.0, left + (1 + random.nextInt(3)) / 4), min(1.0, top + (1 + random.nextInt(3)) / 4));
  }

  ImagePatch changed(ImagePatch p) => switch (random.nextInt(7)) {
        0 => p.copyWith(quarter: place()),
        1 => p.copyWith(top: (random.nextInt(81) - 20) / 4),
        2 => p.copyWith(quarter: place(), top: random.nextDouble() * 30),
        3 => switch (0.25 + random.nextDouble() * 2) { final f => p.copyWith(width: p.width * f, height: p.height * f) },
        4 => p.copyWith(crop: crop()),
        5 => p.copyWith(ink: !p.ink),
        _ => p,
      };

  var on = true;
  for (var step = 0; step < steps; step++) {
    final images = c.images, n = images.patches.length;
    int index() => random.nextInt(n + 2) - 1;
    if (!on && random.nextBool()) {
      c.setExtension('attachImage', on = true);
      out.writeln('$step on');
    }
    String did;
    switch (random.nextInt(24)) {
      case 0 || 1 || 2 || 3:
        final image = testImages[random.nextInt(testImages.length)], quarter = place(), top = (random.nextInt(81) - 20) / 4;
        await images.add(image.kind, image.bytes, quarter: quarter, top: top, extension: image.extension);
        did = 'add ${image.name} $quarter $top';
      case 4 || 5 || 6:
        final i = index();
        if (i >= 0 && i < n) {
          final next = changed(images.patches[i]);
          images.update(i, next);
          did = 'update $i ${_patch(next)}';
        } else {
          images.update(i, const ImagePatch(image: 'none.png', quarter: 0, top: 0, width: 1, height: 1));
          did = 'update $i (none)';
        }
      case 7 || 8:
        // A drag: every move of it is one Undo step.
        if (n == 0) {
          did = 'drag (none)';
          break;
        }
        final i = random.nextInt(n), moves = <String>[];
        c.beginEdit();
        for (var k = random.nextInt(5); k >= 0; k--) {
          final next = changed(images.patches[i]);
          images.update(i, next);
          moves.add(_patch(next));
        }
        c.endEdit();
        did = 'drag $i $moves';
      case 9 || 10:
        final i = random.nextInt(4) == 0 ? null : index();
        images.remove(i);
        did = 'remove $i';
      case 11:
        final known = [...images.stored, ...images.unused];
        final id = known.isEmpty || random.nextInt(5) == 0 ? 'none.png' : known[random.nextInt(known.length)].id;
        images.removeImage(id);
        did = 'removeImage $id';
      case 12 || 13:
        final i = random.nextInt(5) == 0 ? null : index(), crop = random.nextBool();
        images.select(i, crop: crop);
        did = 'select $i crop $crop';
      case 14 || 15 || 16:
        c.undo();
        did = 'undo';
      case 17:
        c.redo();
        did = 'redo';
      case 18:
        images.purgeUnused();
        did = 'purge';
      case 19:
        if (random.nextInt(3) == 0) {
          c.setExtension('attachImage', on = false);
          did = 'off';
        } else {
          c.clearSelection();
          did = 'clearSelection';
        }
      case 20:
        final i = index();
        images.locate(i);
        did = 'locate $i';
      case 21:
        c.commands.delete();
        did = 'delete';
      case 22:
        // Not an image at all.
        try {
          await images.add(ImageKind.raster, Uint8List.fromList(utf8.encode('not an image')), quarter: place(), top: 1, extension: 'png');
          did = 'add text: taken';
        } on FormatException catch (e) {
          did = 'add text: ${e.message}';
        }
      default:
        // The same file twice in a row, in two places.
        final image = testImages[random.nextInt(testImages.length)];
        await images.add(image.kind, image.bytes, quarter: place(), top: 2, extension: image.extension);
        await images.add(image.kind, image.bytes, quarter: place(), top: 9, extension: image.extension);
        did = 'add twice ${image.name}';
    }
    final now = imagesNow(c, names);
    out
      ..writeln('$step ${names.plain(did)}')
      ..writeln('  $now');
  }
  return out.toString();
}

/// The files a damaged or random project's images module may name.
final moduleFiles = <String, Uint8List>{
  'images/a.png': widePng,
  'images/b.svg': svgBytes,
  'images/c-1_2.gif': smallPng,
};

/// What a project whose images module is [json] opens as: its images as saved again, or what is
/// said of it when it is damaged.
String readImages(Object? json) {
  try {
    final state = ProjectModules.images.read(JsonReader(json, 'images'), const ProjectState(), (entry, {required limit}) => moduleFiles[entry]);
    return imagesModule(checkedExtensionData(state));
  } on FormatException catch (e) {
    return e.message;
  }
}

Map<String, Object?> _good([Map<String, Object?> more = const {}]) => {'image': 'a.png', 'quarter': 4, 'top': 2, 'width': 8, 'height': 4, ...more};

/// Images modules to open: some as they should be, some damaged, some made at random.
List<Object?> imageModules(Random random) => [
      <String, Object?>{},
      {'patches': <Object?>[]},
      {'patches': 5},
      {'patches': 'x'},
      {'patches': <String, Object?>{}},
      {
        'patches': [
          _good(),
          {'image': 'b.svg', 'quarter': 0.5, 'top': -3.25, 'width': 30.0, 'height': 10, 'crop': [0.25, 0, 1, 0.5], 'ink': true},
          {'ink': false, 'height': 2.5, 'width': 2.5, 'top': 0, 'quarter': 12, 'image': 'c-1_2.gif', 'crop': [0, 0, 1, 1], 'note': 'kept by nobody'},
          _good({'crop': <Object?>[]}),
          _good({'crop': null, 'ink': null}),
        ],
      },
      for (final patch in <Object?>[
        null, 5, 'x', <Object?>[], <String, Object?>{}, //
        _good({'image': null}), _good({'image': 5}), _good({'image': 'a/b.png'}), _good({'image': 'a.txt'}), _good({'image': '.png'}), _good({'image': 'missing.png'}),
        _good({'image': '${'a' * 100}.png'}), _good({'image': 'A.PNG'}), _good({'image': ''}), _good({'image': 'a.png '}),
        _good({'quarter': null}), _good({'quarter': '4'}), _good({'quarter': 1e12}), _good({'quarter': -1e12}), _good({'quarter': -3}), _good({'quarter': true}),
        _good({'top': null}), _good({'top': 'x'}), _good({'top': 2e9}), _good({'top': -40.5}),
        _good({'width': 0}), _good({'width': -1}), _good({'width': null}), _good({'width': 'x'}), _good({'width': 1e10}), _good({'width': 1e-9}),
        _good({'height': 0}), _good({'height': -0.5}), _good({'height': null}), _good({'height': <Object?>[]}), _good({'height': 3e9}),
        _good({'crop': 5}), _good({'crop': 'x'}), _good({'crop': <String, Object?>{}}), _good({'crop': {'left': 0}}), _good({'crop': [0, 0, 1]}), _good({'crop': [0, 0, 1, 1, 1]}),
        _good({'crop': [0.5, 0, 0.5, 1]}), _good({'crop': [0, 0, 1.5, 1]}), _good({'crop': [-0.1, 0, 1, 1]}), _good({'crop': ['a', 0, 1, 1]}), _good({'crop': [0, 0.75, 1, 0.5]}),
        _good({'crop': [0, 0, 1, null]}), _good({'crop': [0.0, 0.0, 1.0, 1.0]}), _good({'crop': [0, 0, 0.5, 1]}),
        _good({'ink': 'yes'}), _good({'ink': 1}), _good({'ink': true}), _good({'ink': false}),
        _good({'width': 0, 'height': 0}), _good({'quarter': null, 'top': null}), _good({'crop': 5, 'quarter': 'x'}), _good({'ink': 5, 'height': 0}),
      ])
        {
          'patches': [_good({'quarter': 8.5}), patch],
        },
      for (var i = 0; i < 60; i++)
        {
          'patches': [
            for (var k = random.nextInt(7); k > 0; k--)
              {
                'image': const ['a.png', 'b.svg', 'c-1_2.gif'][random.nextInt(3)],
                'quarter': random.nextBool() ? random.nextInt(60) - 4 : random.nextDouble() * 60,
                'top': random.nextBool() ? random.nextInt(30) : random.nextDouble() * 30 - 5,
                'width': random.nextBool() ? 1 + random.nextInt(40) : 0.5 + random.nextDouble() * 40,
                'height': random.nextBool() ? 1 + random.nextInt(12) : 0.5 + random.nextDouble() * 12,
                if (random.nextInt(3) == 0)
                  'crop': switch (random.nextInt(3)) {
                    0 => [0, 0, 1, 1],
                    1 => [0.25, 0.5, 0.75, 1],
                    _ => [random.nextDouble() / 2, random.nextDouble() / 2, 0.5 + random.nextDouble() / 2, 0.5 + random.nextDouble() / 2],
                  },
                if (random.nextInt(3) == 0) 'ink': random.nextBool(),
              },
          ],
        },
    ];

/// Bars of 4 quarters that become bars of 3, the score ending at bar 6.
final barsBefore = [for (var i = 0; i <= 12; i++) i * 4.0], barsAfter = [for (var i = 0; i <= 6; i++) i * 3.0];

double? carriedQuarter(double q) => ScoreSwap.quarterAt(q, barsBefore, barsAfter);

/// Projects with images made at random, for a score that is replaced.
List<ProjectState> imagesToCarry(Random random) => [
      for (var i = 0; i < 80; i++)
        ProjectModules.images.read(
            JsonReader({
              'patches': [
                for (var k = random.nextInt(7); k > 0; k--)
                  {
                    'image': const ['a.png', 'b.svg', 'c-1_2.gif'][random.nextInt(3)],
                    'quarter': random.nextInt(4) == 0 ? random.nextDouble() * 52 - 2 : random.nextInt(52) - 2.0,
                    'top': random.nextInt(20) / 2,
                    'width': 1.0 + random.nextInt(20),
                    'height': 1.0 + random.nextInt(10),
                    if (random.nextInt(4) == 0) 'crop': [0.25, 0.0, 1.0, 0.5],
                    if (random.nextInt(4) == 0) 'ink': true,
                  },
              ],
            }, 'images'),
            const ProjectState(),
            (entry, {required limit}) => moduleFiles[entry]),
    ];

/// Each of [imagesToCarry] as [carry] leaves it: the module as saved, and what was lost.
String carriedImages(Random random, ({ProjectState state, List<String> lost}) Function(ProjectState state) carry) => [
      for (final state in imagesToCarry(random))
        switch (carry(checkedExtensionData(state))) {
          (:final state, :final lost) => '${imagesModule(state)} $lost ${state.images.keys.toList()}',
        },
    ].join('\n');

/// The extension's switch and the spacers, which it turns on: what is engraved, drawn and saved
/// as it is turned off and on, and as Undo goes back over it.
Future<String> spacerSwitch(EditorController c) async {
  final out = StringBuffer();
  final starts = c.timeline.measureStarts;
  Future<void> say(String did) async {
    for (var i = 0; i < 600 && c.isReengraving; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final request = c.score!.request, page = c.pageState;
    out.writeln('$did\n  module ${jsonEncode(ProjectModules.spacers.write(c.projectState, (entry, bytes, {compress = true}) {}))}\n'
        '  enabled ${c.spacers.enabled} images ${c.images.enabled} vertical ${[for (final s in c.spacers.vertical) s.id]} horizontal ${c.spacers.horizontal.length} '
        'selected ${c.spacers.selectedVertical} ${c.spacers.selectedHorizontal}\n'
        '  engraved ${request.spacers.length} ${request.gaps.length} drawn ${c.sceneSettings.spacers.length} page ${page.spacers.length} ${page.gaps.length} '
        'order ${c.projectState.edits.partOrder.where((id) => c.spacers.verticalOf(id) != null).toList()} lanes ${c.laneParts.length}\n'
        '  used ${Extensions.usedBy(c).map((e) => e.id).toList()} on ${c.extensionOn('attachImage')} chosen ${c.extensionChosen('attachImage')} undo ${c.canUndo} redo ${c.canRedo}');
  }

  await say('opened');
  await c.spacers.addVertical(below: c.laneParts[2].id);
  await say('addVertical while off');
  c.setExtension('attachImage', true);
  await say('on');
  await c.spacers.addVertical(below: c.laneParts[2].id);
  await say('addVertical');
  await c.spacers.addHorizontal(starts[3] + 1.5, starts[4]);
  await say('addHorizontal');
  await c.spacers.setVertical(c.spacers.vertical.single.copyWith(lines: true, height: 6));
  await say('setVertical');
  c.setExtension('attachImage', false);
  await say('off');
  await c.spacers.addHorizontal(starts[8], starts[9]);
  await c.spacers.removeSelected();
  await say('edits while off');
  c.undo();
  await say('undo (on again)');
  c.undo();
  await say('undo');
  c.redo();
  c.redo();
  await say('redo twice (off)');
  c.setExtension('attachImage', true);
  c.spacers.selectHorizontal(0);
  await say('on, selected');
  c.commands.delete();
  await say('delete');
  c.spacers.selectVertical(c.spacers.vertical.single.id);
  await c.images.add(ImageKind.raster, widePng, quarter: starts[2], top: 3);
  await say('image added over a selected spacer');
  await c.spacers.removeVertical(c.spacers.vertical.single.id);
  await say('removeVertical');
  c.setExtension('attachImage', false);
  await say('off, an image left');
  return out.toString();
}
