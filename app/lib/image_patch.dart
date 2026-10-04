import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:score_engine/score_engine.dart';

/// Vector images are SVG; raster images PNG or JPEG.
enum ImageKind {
  vector(['svg']),
  raster(['png', 'jpg', 'jpeg']);

  const ImageKind(this.extensions);
  final List<String> extensions;

  /// What Add Image… offers: either kind.
  static const types = XTypeGroup(label: 'Image', extensions: ['svg', 'png', 'jpg', 'jpeg']);

  static ImageKind? ofPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    return values.where((k) => k.extensions.contains(ext)).firstOrNull;
  }
}

/// An image file added to a project (Attach Image): its bytes, kept as they came, and
/// which kind they are. Saved in the project as `images/<id>`.
@immutable
class PatchImage {
  const PatchImage(this.id, this.kind, this.bytes);

  /// Unique in the project; ends in the file type (`3f9a…c1.svg`).
  final String id;
  final ImageKind kind;
  final Uint8List bytes;

  static int _counter = 0;

  /// A new image with an id of its own.
  factory PatchImage.create(ImageKind kind, Uint8List bytes, {String extension = ''}) {
    final r = math.Random();
    final id = [
      DateTime.now().microsecondsSinceEpoch.toRadixString(16),
      (_counter++).toRadixString(16),
      r.nextInt(1 << 32).toRadixString(16),
    ].join('-');
    final ext = kind.extensions.contains(extension.toLowerCase()) ? extension.toLowerCase() : kind.extensions.first;
    return PatchImage('$id.$ext', kind, bytes);
  }

  /// The kind of a saved image, from its id's file type; null when it is neither.
  static ImageKind? kindOfId(String id) => ImageKind.ofPath(id);

  /// Whether [id] can be one: a plain file name (letters, digits, `-`, `_`, `.`, not
  /// starting with a dot) of a known file type, the same in a zip and on every file system.
  static bool isId(String id) => id.length <= 100 && _id.hasMatch(id) && kindOfId(id) != null;
  static final _id = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9._-]*$');

  /// The largest image file taken, bytes.
  static const maxBytes = 64 << 20;

  /// The most pixels a PNG or JPEG may have (one in an SVG too): decoding takes 4 bytes a
  /// pixel, so a small file of a huge plain image could take gigabytes.
  static const maxPixels = 64000000;

  /// The longest side a PNG or JPEG is kept at; a bigger one is scaled down to it (sharp
  /// enough for a 4K video).
  static const maxSide = 4096;

  /// Draws the image. Throws a [FormatException] when the bytes are not an image of [kind],
  /// or one too big.
  Future<PatchArt> decode() async {
    if (bytes.length > maxBytes) throw const FormatException('The image is too big.');
    try {
      switch (kind) {
        case ImageKind.vector:
          await _checkEmbedded(bytes);
          return VectorArt(await vg.loadPicture(SvgBytesLoader(bytes), null));
        case ImageKind.raster:
          return RasterArt(await _decodeRaster(bytes));
      }
    } on _TooBig {
      throw const FormatException('The image is too big.');
    } catch (e) {
      throw FormatException('This is not ${kind == ImageKind.vector ? 'an SVG' : 'a PNG or JPEG'} image that can be read.');
    }
  }

  /// The size of the PNG or JPEG in [bytes], read from its header (nothing is decoded).
  static Future<ui.ImageDescriptor> _describe(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width * descriptor.height > maxPixels) {
        descriptor.dispose();
        throw const _TooBig();
      }
      return descriptor;
    } finally {
      buffer.dispose();
    }
  }

  static Future<ui.Image> _decodeRaster(Uint8List bytes) async {
    final descriptor = await _describe(bytes);
    final w = descriptor.width, h = descriptor.height, scale = math.min(1.0, maxSide / math.max(w, h));
    final codec = await descriptor.instantiateCodec(
        targetWidth: scale < 1 ? math.max(1, (w * scale).round()) : null,
        targetHeight: scale < 1 ? math.max(1, (h * scale).round()) : null);
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
      descriptor.dispose();
    }
  }

  /// SVG may carry PNGs and JPEGs of its own (base64 `data:` URLs), which flutter_svg decodes
  /// whole: each is held to [maxPixels] too.
  static Future<void> _checkEmbedded(Uint8List svg) async {
    final text = utf8.decode(svg, allowMalformed: true);
    for (final m in _embedded.allMatches(text)) {
      final Uint8List data;
      try {
        data = base64Decode(m[1]!.replaceAll(RegExp(r'\s'), ''));
      } on FormatException {
        continue; // not drawn either
      }
      final ui.ImageDescriptor descriptor;
      try {
        descriptor = await _describe(data);
      } on _TooBig {
        rethrow;
      } catch (_) {
        continue; // not an image flutter_svg draws
      }
      descriptor.dispose();
    }
  }

  static final _embedded = RegExp(r'data:image/[a-z0-9.+-]+;base64,([A-Za-z0-9+/=\s]+)', caseSensitive: false);
}

class _TooBig implements Exception {
  const _TooBig();
}

/// A PNG or JPEG, drawn smoothly at any size.
class RasterArt implements PatchArt {
  RasterArt(this.image);
  final ui.Image image;

  @override
  ui.Size get size => ui.Size(image.width.toDouble(), image.height.toDouble());

  @override
  void paint(ui.Canvas canvas, ui.Rect source, ui.Rect destination, {double opacity = 1}) {
    canvas.drawImageRect(
      image,
      source,
      destination,
      ui.Paint()
        ..filterQuality = ui.FilterQuality.medium
        ..color = ui.Color.fromRGBO(0, 0, 0, opacity),
    );
  }

  void dispose() => image.dispose();
}

/// An SVG, drawn as vectors: sharp at any size, in the preview and in a video.
class VectorArt implements PatchArt {
  VectorArt(this.info);
  final PictureInfo info;

  @override
  ui.Size get size => ui.Size(math.max(1, info.size.width), math.max(1, info.size.height));

  @override
  void paint(ui.Canvas canvas, ui.Rect source, ui.Rect destination, {double opacity = 1}) {
    if (source.isEmpty || destination.isEmpty) return;
    canvas.save();
    canvas.clipRect(destination);
    if (opacity < 1) canvas.saveLayer(destination, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, opacity));
    canvas
      ..translate(destination.left, destination.top)
      ..scale(destination.width / source.width, destination.height / source.height)
      ..translate(-source.left, -source.top)
      ..drawPicture(info.picture);
    if (opacity < 1) canvas.restore();
    canvas.restore();
  }

  void dispose() => info.picture.dispose();
}

/// An image placed on the score (see [ScenePatch]): which [image], the score quarter its
/// left edge is pinned to, its top below the frame's and its size in staff spaces, and the
/// part of the image shown ([crop], fractions 0–1).
@immutable
class ImagePatch {
  const ImagePatch({
    required this.image,
    required this.quarter,
    required this.top,
    required this.width,
    required this.height,
    this.crop = full,
  });

  static const full = ui.Rect.fromLTRB(0, 0, 1, 1);

  /// A [PatchImage.id].
  final String image;
  final double quarter, top, width, height;
  final ui.Rect crop;

  ImagePatch copyWith({double? quarter, double? top, double? width, double? height, ui.Rect? crop}) => ImagePatch(
        image: image,
        quarter: quarter ?? this.quarter,
        top: top ?? this.top,
        width: width ?? this.width,
        height: height ?? this.height,
        crop: crop ?? this.crop,
      );

  @override
  bool operator ==(Object other) =>
      other is ImagePatch &&
      other.image == image &&
      other.quarter == quarter &&
      other.top == top &&
      other.width == width &&
      other.height == height &&
      other.crop == crop;

  @override
  int get hashCode => Object.hash(image, quarter, top, width, height, crop);
}

/// What can be pasted: an image on the clipboard (a PNG), SVG text, or a copied file of
/// either kind (from Finder). Null when there is none.
Future<({ImageKind kind, Uint8List bytes, String extension})?> readClipboardImage() async {
  try {
    for (final path in await Pasteboard.files()) {
      final kind = ImageKind.ofPath(path);
      if (kind != null && File(path).existsSync()) {
        return (kind: kind, bytes: await File(path).readAsBytes(), extension: path.split('.').last);
      }
    }
    final text = (await Pasteboard.text)?.trim();
    if (text != null && looksLikeSvg(text)) {
      return (kind: ImageKind.vector, bytes: Uint8List.fromList(utf8.encode(text)), extension: 'svg');
    }
    final png = await Pasteboard.image;
    if (png != null && png.isNotEmpty) return (kind: ImageKind.raster, bytes: png, extension: 'png');
  } catch (_) {
    // No clipboard here (tests), or nothing readable on it.
  }
  return null;
}

/// Whether [text] is SVG markup.
bool looksLikeSvg(String text) {
  final head = text.substring(0, math.min(text.length, 2000)).toLowerCase();
  return head.contains('<svg') && (head.startsWith('<svg') || head.startsWith('<?xml') || head.startsWith('<!--') || head.startsWith('<!doctype'));
}
