import 'dart:math' as math;
import 'dart:ui' as ui;

import 'display_list.dart';
import 'frozen_zone.dart';

/// Where a staff is drawn in the current frame.
class StaffPlacement {
  const StaffPlacement({required this.staffIndex, required this.y, required this.opacity});
  final int staffIndex; // index into ScoreDisplayList.staves
  final double y; // top staff line, logical pixels from the top of the frame
  final double opacity;
}

class StaffLabel {
  const StaffLabel(
      {required this.text, this.shortText = '', required this.centerY, required this.opacity, this.partId = ''});
  final String text;
  final String partId;

  /// Used instead of [text] when the full name does not fit the name column.
  final String shortText;
  final double centerY;
  final double opacity;
}

/// Draws the curated score by compositing cached staff tiles.
///
/// Each staff is rasterised once into image tiles ([tileWidth] logical pixels wide) at the
/// screen's pixel density. A frame only positions and fades those images, which the GPU does
/// almost for free, so scrolling and staff animations stay smooth however dense the score is.
///
/// The engraving is only ever ink on a transparent ground, so the colours are chosen when a
/// frame is drawn ([paint]'s `paper` and `ink`): tiles, names and the frozen zone are tinted
/// with the ink, and nothing is rasterised again when the colours change (a dark theme's
/// light ink on dark paper, even while the theme cross-fades).
/// The same painter serves the live preview and video export ([CuratedScene.renderFrame]),
/// so a video looks exactly like the preview.
class ScoreRenderer {
  ScoreRenderer(this.display, this.style, {this.frozen, this.tileWidth = 512, this.maxTiles = 600});

  final ScoreDisplayList display;
  final RenderStyle style;

  /// Clef, key and time signature column beside the names (Dorico-style); null to leave it out.
  final FrozenZone? frozen;
  final double tileWidth;
  final int maxTiles;

  final _tiles = <(int, int), _Tile>{}; // insertion-ordered: LRU: (staff index, tile index)
  final _emptyTiles = <(int, int)>{};
  double _tileDpr = 0;

  /// Logical pixels per device unit.
  double get scale => style.staffSpace / display.data.staffSpace;
  double get _tileUnits => tileWidth / scale;

  static const _fade = 24.0;

  /// Where the music starts: right of the names and the frozen zone.
  double get musicLeft => style.headerWidth + (frozen?.width ?? 0);

  /// The fixed pointer, kept clear of the frozen zone on narrow frames.
  double pointerX(double width) => math.max(width * style.pointerFraction, musicLeft + _fade + 24);

  /// Score x range (device units) visible in a frame of [width].
  (double, double) visibleRange(double scrollX, double width) {
    final pointerX = this.pointerX(width);
    return (scrollX - pointerX / scale, scrollX + (width - pointerX) / scale);
  }

  void paint(
    ui.Canvas canvas,
    ui.Size size, {
    required double scrollX,
    required List<StaffPlacement> placements,
    required List<StaffLabel> labels,
    required double devicePixelRatio,
    ui.Color? paper,
    ui.Color? ink,
  }) {
    if (devicePixelRatio != _tileDpr) {
      _dropTiles(); // rasterised for another screen
      _tileDpr = devicePixelRatio;
    }
    final paperColor = paper ?? style.paper;
    // Everything recorded is ink; this recolours it, keeping its coverage (anti-aliasing).
    final inkFilter = ui.ColorFilter.mode(ink ?? style.ink, ui.BlendMode.srcIn);
    canvas.drawRect(ui.Offset.zero & size, ui.Paint()..color = paperColor);

    // Snap the scroll to whole device pixels: tiles then land on the pixel grid, the ink stays
    // crisp like print, and neighbouring tiles meet without seams.
    final pointerX = this.pointerX(size.width);
    final originX = _snap(pointerX - scrollX * scale, devicePixelRatio);
    final (left, right) = visibleRange(scrollX, size.width);
    final firstTile = math.max(0, (left / _tileUnits).floor());
    final lastTile = (right / _tileUnits).floor() + 1; // one ahead, so new tiles are ready early

    final paint = ui.Paint()
      ..filterQuality = ui.FilterQuality.low
      ..colorFilter = inkFilter;
    for (final placement in placements) {
      if (placement.opacity <= 0.001) continue;
      paint.color = ui.Color.fromRGBO(0, 0, 0, placement.opacity.clamp(0.0, 1.0));
      final y = _snap(placement.y, devicePixelRatio);
      for (var t = firstTile; t <= lastTile; t++) {
        final tile = _tile(placement.staffIndex, t);
        if (tile == null) continue;
        final x = originX + t * tileWidth;
        if (x > size.width || x + tileWidth < 0) continue; // prepared, but off screen
        canvas.drawImageRect(
          tile.image,
          ui.Rect.fromLTWH(0, 0, tile.image.width.toDouble(), tile.image.height.toDouble()),
          ui.Rect.fromLTWH(x, y + tile.top, tileWidth, tile.image.height / devicePixelRatio),
          paint,
        );
      }
    }

    _paintHeader(canvas, size, labels, paperColor, inkFilter);
    final zone = frozen;
    if (zone != null) {
      canvas.saveLayer(ui.Offset.zero & size, ui.Paint()..colorFilter = inkFilter);
      // Score position at the zone's right edge: a change takes over the zone as it passes here.
      final edgeX = scrollX - (pointerX - musicLeft) / scale;
      // Until the music reaches the zone, the zone's staff lines run on to meet it.
      final measures = display.data.measures;
      final staffStart = measures.isEmpty ? 0.0 : originX + measures.first.left * scale;
      for (final placement in placements) {
        if (placement.opacity <= 0.001) continue;
        final faded = placement.opacity < 0.999;
        if (faded) canvas.saveLayer(null, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, placement.opacity));
        zone.paintStaff(canvas, display.staves[placement.staffIndex].info,
            left: style.headerWidth,
            top: _snap(placement.y, devicePixelRatio),
            scoreX: edgeX,
            fadeWidth: _fade,
            linesTo: staffStart);
        if (faded) canvas.restore();
      }
      canvas.restore();
    }
    canvas.drawRect(
      ui.Rect.fromLTWH(pointerX - style.pointerWidth / 2, 0, style.pointerWidth, size.height),
      ui.Paint()..color = style.pointer,
    );
  }

  /// Releases the tile images, the name labels and the frozen zone's glyphs.
  void dispose() {
    _dropTiles();
    for (final label in _labelCache.values) {
      label.dispose();
    }
    _labelCache.clear();
    frozen?.dispose();
  }

  void _dropTiles() {
    for (final tile in _tiles.values) {
      tile.image.dispose();
    }
    _tiles.clear();
    _emptyTiles.clear();
  }

  static double _snap(double v, double dpr) => (v * dpr).roundToDouble() / dpr;

  _Tile? _tile(int staffIndex, int index) {
    final key = (staffIndex, index);
    final cached = _tiles.remove(key);
    if (cached != null) return _tiles[key] = cached; // mark as recently used
    if (_emptyTiles.contains(key)) return null;
    final tile = _render(display.staves[staffIndex], index);
    if (tile == null) {
      _emptyTiles.add(key);
      return null;
    }
    _tiles[key] = tile;
    while (_tiles.length > maxTiles) {
      _tiles.remove(_tiles.keys.first)!.image.dispose();
    }
    return tile;
  }

  _Tile? _render(StaffLayer staff, int index) {
    final s = scale, dpr = _tileDpr;
    final left = index * _tileUnits, right = left + _tileUnits;
    final items = staff.itemsIn(left, right).toList();
    if (items.isEmpty) return null;

    // Vertical extent: the staff lines plus whatever ink reaches outside them in this tile.
    var top = staff.info.top, bottom = staff.info.top + staff.info.height;
    for (final item in items) {
      top = math.min(top, item.bounds.top);
      bottom = math.max(bottom, item.bounds.bottom);
    }
    final pad = display.data.staffSpace * 0.5;
    top -= pad;
    bottom += pad;
    // Start the image on a whole device pixel from the staff's top line: placed at the
    // (snapped) staff position it then sits on the pixel grid, and lines stay crisp instead
    // of being resampled across two extra pixels.
    final offsetPx = ((top - staff.info.top) * s * dpr).floorToDouble();
    top = staff.info.top + offsetPx / (s * dpr);

    final width = (tileWidth * dpr).round();
    final height = ((bottom - top) * s * dpr).ceil();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..scale(s * dpr)
      ..translate(-left, -top)
      ..clipRect(ui.Rect.fromLTRB(left, top, right, bottom));
    for (final item in items) {
      item.paint(canvas);
    }
    // Barlines: only the slice crossing this staff's own lines.
    // One-line (percussion) staves get barlines a staff space above and below the line.
    final bleed = display.data.staffSpace * (staff.info.lines <= 1 ? 1.0 : 0.08);
    canvas.clipRect(ui.Rect.fromLTRB(left, staff.info.top - bleed, right, staff.info.top + staff.info.height + bleed));
    for (final item in display.barlines.itemsIn(left, right)) {
      item.paint(canvas);
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(width, height);
    picture.dispose();
    return _Tile(image, offsetPx / dpr);
  }

  final _labelCache = <String, ui.Paragraph>{};

  void _paintHeader(ui.Canvas canvas, ui.Size size, List<StaffLabel> labels, ui.Color paper, ui.ColorFilter ink) {
    // Names and the frozen zone sit on paper; the music fades out as it slides underneath.
    final left = musicLeft;
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, left, size.height), ui.Paint()..color = paper);
    canvas.drawRect(
      ui.Rect.fromLTWH(left, 0, _fade, size.height),
      ui.Paint()
        ..shader = ui.Gradient.linear(
          ui.Offset(left, 0),
          ui.Offset(left + _fade, 0),
          [paper, paper.withValues(alpha: 0)],
        ),
    );
    for (final label in labels) {
      if (label.opacity <= 0.001) continue;
      final width = style.headerWidth - 18;
      var paragraph = _label(label.text, width);
      if (paragraph.maxIntrinsicWidth > width && label.shortText.isNotEmpty) {
        paragraph = _label(label.shortText, width);
      }
      canvas.saveLayer(
          null,
          ui.Paint()
            ..color = ui.Color.fromRGBO(0, 0, 0, label.opacity)
            ..colorFilter = ink);
      canvas.drawParagraph(paragraph, ui.Offset(4, label.centerY - paragraph.height / 2));
      canvas.restore();
    }
  }
}

extension on ScoreRenderer {
  ui.Paragraph _label(String text, double width) => _labelCache.putIfAbsent(text, () {
        final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
          fontFamily: style.textFontFamily,
          fontSize: style.labelFontSize,
          textAlign: ui.TextAlign.right,
          maxLines: 1,
          ellipsis: '…',
        ))
          ..pushStyle(ui.TextStyle(color: style.ink))
          ..addText(text);
        return builder.build()..layout(ui.ParagraphConstraints(width: width));
      });
}

class _Tile {
  _Tile(this.image, this.top);
  final ui.Image image;

  /// Offset of the image's top edge from the staff's top line, logical pixels.
  final double top;
}
