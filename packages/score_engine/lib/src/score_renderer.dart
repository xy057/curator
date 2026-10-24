import 'dart:math' as math;
import 'dart:ui' as ui;

import 'display_list.dart';
import 'engraving.dart';
import 'frozen_zone.dart';

/// Where a staff is drawn in the current frame.
class StaffPlacement {
  const StaffPlacement({required this.staffIndex, required this.y, required this.opacity});
  final int staffIndex; // index into ScoreDisplayList.staves
  final double y; // top staff line, logical pixels from the top of the frame
  final double opacity;
}

/// One instrument's staves (a piano's two) joined by a brace at the left: each staff's top
/// line and height, logical pixels, top to bottom.
class StaffBrace {
  const StaffBrace({required this.staves, required this.opacity});
  final List<({double top, double height})> staves;
  final double opacity;
}

/// A section's bracket (the woodwinds, the strings…), from its first staff's top line to its
/// last staff's bottom line, logical pixels (a staff of fewer lines taken as five).
class StaffBracket {
  const StaffBracket({required this.top, required this.bottom, required this.opacity, this.outset = false});
  final double top, bottom;
  final double opacity;

  /// Further left, clear of the braces: an instrument of the section is on more than one staff.
  final bool outset;
}

/// Two staves shown one above the other, of different instruments: the starting line runs on
/// between them, and with [barlines] (the same section) the barlines too.
class StaffJoin {
  const StaffJoin({required this.above, required this.below, required this.barlines});
  final StaffPlacement above, below;
  final bool barlines;
  double get opacity => math.min(above.opacity, below.opacity);
}

class StaffLabel {
  const StaffLabel(
      {required this.text,
      this.shortText = '',
      required this.centerY,
      required this.opacity,
      this.partId = '',
      this.color});
  final String text;
  final String partId;

  /// Drawn in this instead of the ink (its instrument's group's, [CuratedScene.nameColors]).
  final ui.Color? color;

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
  ScoreRenderer(this.display, this.style,
      {this.frozen, this.barlinesThrough = const {}, this.tileWidth = 512, this.maxTileBytes = 256 << 20});

  final ScoreDisplayList display;
  final RenderStyle style;

  /// Clef, key and time signature column beside the names (Dorico-style); null to leave it out.
  final FrozenZone? frozen;

  /// Staff index → the staff index below it in the same instrument (a piano's left hand): the
  /// barlines run on from one to the other, which an instrument's staves keep a fixed distance
  /// apart for (see SpacingPlan).
  final Map<int, int> barlinesThrough;
  final double tileWidth;

  /// How much the tile images may hold, in bytes (RGBA). The least recently drawn go first,
  /// but never one the frame being painted uses, so a frame that needs more than this still
  /// draws whole (and the cache shrinks back on the next).
  final int maxTileBytes;

  final _tiles = <(int, int), _Tile>{}; // insertion-ordered: LRU: (staff index, tile index)
  final _emptyTiles = <(int, int)>{};
  double _tileDpr = 0;
  int _tileBytes = 0;
  int _frame = 0; // counts paint calls: a tile drawn in this one stays

  /// What the tile images hold now, in bytes.
  int get tileBytes => _tileBytes;

  /// Logical pixels per device unit.
  double get scale => style.staffSpace / display.data.staffSpace;
  double get _tileUnits => tileWidth / scale;

  static const _fade = 24.0;

  /// Where the music starts, right of the names and the frozen zone, with a key column
  /// [keyColumn] staff spaces wide (see [FrozenZone]).
  double musicLeftFor(double keyColumn) => style.headerWidth + (frozen?.widthFor(keyColumn) ?? 0);

  /// Where the music starts when the frozen zone is at its widest.
  double get musicLeft => style.headerWidth + (frozen?.maxWidth ?? 0);

  /// The fixed pointer, kept clear of the frozen zone at its widest on narrow frames (so it
  /// never moves as the zone widens or narrows).
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
    List<StaffBrace> braces = const [],
    List<StaffBracket> brackets = const [],
    List<StaffJoin> joins = const [],
    bool outsetBrackets = false,
    required double devicePixelRatio,
    double? keyColumn,
    ui.Color? paper,
    ui.Color? ink,
    void Function(ui.Canvas canvas, double musicLeft)? overlay,
  }) {
    _frame++;
    final column = keyColumn ?? frozen?.maxKeyColumn ?? 0;
    final musicLeft = musicLeftFor(column);
    if (devicePixelRatio != _tileDpr) {
      _dropTiles(); // rasterised for another screen
      _tileDpr = devicePixelRatio;
    }
    final paperColor = paper ?? style.paper;
    // Everything recorded is ink; this recolours it, keeping its coverage (anti-aliasing).
    final inkFilter = ui.ColorFilter.mode(ink ?? style.ink, ui.BlendMode.srcIn);
    canvas.drawRect(ui.Offset.zero & size, ui.Paint()..color = paperColor);
    // See-through paper (a video with a transparent background) can't hide the music under the
    // names by covering it: the music goes on a layer of its own and that part is cut out of it.
    final clear = paperColor.a < 1;
    if (clear) canvas.saveLayer(ui.Offset.zero & size, ui.Paint());

    // Snap the scroll to whole device pixels: tiles then land on the pixel grid, the ink stays
    // crisp like print, and neighbouring tiles meet without seams.
    final pointerX = this.pointerX(size.width);
    final originX = _snap(pointerX - scrollX * scale, devicePixelRatio);
    final (left, right) = visibleRange(scrollX, size.width);
    final firstTile = math.max(0, (left / _tileUnits).floor());
    final lastTile = (right / _tileUnits).floor() + 1; // one ahead, so new tiles are ready early

    // The staff lines start where the frozen zone's stop, past the fade: drawn there twice (the
    // music's, faded, under the zone's), a line came out heavier on the pixel rows it only
    // partly covers, plainly so in light ink on dark paper. On a whole device pixel, so the two
    // meet without a seam.
    final linesFrom =
        frozen == null ? -double.infinity : ((musicLeft + _fade) * devicePixelRatio).ceilToDouble() / devicePixelRatio;
    final paint = ui.Paint()
      ..filterQuality = ui.FilterQuality.low
      ..colorFilter = inkFilter;
    // Drawn as the zone draws its own, in the ink on a layer tinted with it: drawn straight on
    // the canvas, Impeller anti-aliases them differently, and the lines changed weight there.
    final linePaint = ui.Paint()..color = style.ink;
    final lineLayer = ui.Paint()..colorFilter = inkFilter;
    final lines = <ui.Rect>[];
    for (final placement in placements) {
      if (placement.opacity <= 0.001) continue;
      final opacity = placement.opacity.clamp(0.0, 1.0);
      final y = _snap(placement.y, devicePixelRatio);
      final staff = display.staves[placement.staffIndex];
      final tiles = <(double, _Tile)>[];
      var top = y, bottom = y + staff.info.height * scale;
      for (var t = firstTile; t <= lastTile; t++) {
        final tile = _tile(placement.staffIndex, t);
        if (tile == null) continue;
        final x = originX + t * tileWidth;
        if (x > size.width || x + tileWidth < 0) continue; // prepared, but off screen
        tiles.add((x, tile));
        top = math.min(top, y + tile.top);
        bottom = math.max(bottom, y + tile.top + tile.image.height / devicePixelRatio);
      }
      // A staff fading in or out fades as one: lines and notes over them blend as they do at full.
      final faded = opacity < 0.999;
      if (faded) {
        canvas.saveLayer(
            ui.Rect.fromLTRB(0, top - 1, size.width, bottom + 1), ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, opacity));
      }
      for (final (x, tile) in tiles) {
        canvas.drawImageRect(
          tile.image,
          ui.Rect.fromLTWH(0, 0, tile.image.width.toDouble(), tile.image.height.toDouble()),
          ui.Rect.fromLTWH(x, y + tile.top, tileWidth, tile.image.height / devicePixelRatio),
          paint,
        );
      }
      final first = lines.length;
      for (final line in staff.lines) {
        final left = math.max(math.max(originX + line.left * scale, linesFrom), 0.0);
        final right = math.min(originX + line.right * scale, size.width);
        if (right <= left) continue;
        final lineY = y + (line.y - staff.info.top) * scale, half = line.thickness * scale / 2;
        lines.add(ui.Rect.fromLTRB(left, lineY - half, right, lineY + half));
      }
      if (faded) {
        _paintLines(canvas, lines.sublist(first), linePaint, lineLayer);
        lines.length = first;
        canvas.restore();
      }
    }

    // Barlines run on between the staves of a section. The room between them changes as staves
    // come and go, so unlike an instrument's they are drawn each frame, each barline's strokes
    // from where the staff above's end to where the staff below's begin.
    for (final join in joins) {
      final opacity = join.opacity;
      if (!join.barlines || opacity <= 0.001) continue;
      final above = display.staves[join.above.staffIndex].info, below = display.staves[join.below.staffIndex].info;
      final top = _snap(join.above.y, devicePixelRatio) + (above.height + _bleed(above)) * scale;
      final bottom = _snap(join.below.y, devicePixelRatio) - _bleed(below) * scale;
      if (bottom <= top) continue;
      final first = lines.length;
      for (var i = _firstStrokeFrom(left); i < _barlineStrokes.length && _barlineStrokes[i].x - _barlineStrokes[i].width <= right; i++) {
        final (:x, :width) = _barlineStrokes[i];
        final centre = originX + x * scale, half = width * scale / 2;
        lines.add(ui.Rect.fromLTRB(centre - half, top, centre + half, bottom));
      }
      if (opacity < 0.999 && lines.length > first) {
        canvas.saveLayer(null, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, opacity));
        _paintLines(canvas, lines.sublist(first), linePaint, lineLayer);
        lines.length = first;
        canvas.restore();
      }
    }
    _paintLines(canvas, lines, linePaint, lineLayer);

    // Over the music, under the names, the frozen zone and the pointer (images on the score).
    overlay?.call(canvas, musicLeft);
    if (clear) {
      _coverHeader(canvas, size, musicLeft, ui.Paint()..blendMode = ui.BlendMode.dstOut, const ui.Color(0xFF000000));
      canvas.restore();
    }

    // Names stop short of a bracket set out past the braces.
    final nameRight = math.min(style.headerWidth - 14,
        style.headerWidth - (outsetBrackets ? frozen?.bracketReach(outset: true) ?? 0 : 0) - 4);
    _paintHeader(canvas, size, labels, musicLeft, clear ? null : paperColor, inkFilter, nameRight: nameRight);
    final zone = frozen;
    if (zone != null) {
      canvas.saveLayer(ui.Offset.zero & size, ui.Paint()..colorFilter = inkFilter);
      // Score position at the zone's right edge: a change takes over the zone as it passes here.
      final edgeX = scrollX - (pointerX - musicLeft) / scale;
      // Until the music reaches the zone, the zone's staff lines run on to meet the staff's
      // own, and stop there: drawn twice, a line would come out heavier wherever it doesn't
      // fall on whole pixels.
      for (final placement in placements) {
        if (placement.opacity <= 0.001) continue;
        final faded = placement.opacity < 0.999;
        if (faded) canvas.saveLayer(null, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, placement.opacity));
        final staff = display.staves[placement.staffIndex];
        final inkLeft = staff.inkLeft;
        zone.paintStaff(canvas, staff.info,
            left: style.headerWidth,
            top: _snap(placement.y, devicePixelRatio),
            scoreX: edgeX,
            keyColumn: column,
            fadeWidth: _fade,
            linesTo: math.max(linesFrom, inkLeft == null ? 0 : originX + inkLeft * scale));
        if (faded) canvas.restore();
      }
      for (final brace in braces) {
        if (brace.opacity <= 0.001) continue;
        final faded = brace.opacity < 0.999;
        if (faded) canvas.saveLayer(null, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, brace.opacity));
        zone.paintBrace(canvas,
            left: style.headerWidth,
            staves: [for (final s in brace.staves) (top: _snap(s.top, devicePixelRatio), height: s.height)]);
        if (faded) canvas.restore();
      }
      for (final join in joins) {
        final opacity = join.opacity;
        if (opacity <= 0.001) continue;
        final faded = opacity < 0.999;
        if (faded) canvas.saveLayer(null, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, opacity));
        zone.paintJoin(canvas,
            left: style.headerWidth,
            top: _snap(join.above.y, devicePixelRatio) + display.staves[join.above.staffIndex].info.height * scale,
            bottom: _snap(join.below.y, devicePixelRatio));
        if (faded) canvas.restore();
      }
      for (final bracket in brackets) {
        if (bracket.opacity <= 0.001) continue;
        final faded = bracket.opacity < 0.999;
        if (faded) canvas.saveLayer(null, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, bracket.opacity));
        zone.paintBracket(canvas,
            left: style.headerWidth,
            top: _snap(bracket.top, devicePixelRatio),
            bottom: _snap(bracket.bottom, devicePixelRatio),
            outset: bracket.outset);
        if (faded) canvas.restore();
      }
      canvas.restore();
    }
    canvas.drawRect(
      ui.Rect.fromLTWH(pointerX - style.pointerWidth / 2, 0, style.pointerWidth, size.height),
      ui.Paint()..color = style.pointer,
    );
  }

  /// Cuts see-through paper's header out once, tiny and offscreen ([paint] on paper that isn't
  /// opaque), so the GPU has made what that needs before a frame does: the first frame to do it
  /// (turning a video's background transparent) took some 60 ms, a dropped frame and the engine's
  /// "Reported frame time is older than the last one". Call it while nothing moves; once is enough.
  static Future<void> warmUp() async {
    if (_warm) return;
    _warm = true;
    const size = ui.Size(_fade * 2, 8);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)..saveLayer(ui.Offset.zero & size, ui.Paint());
    canvas.drawRect(ui.Offset.zero & size, ui.Paint()..color = const ui.Color(0xFF000000));
    _coverHeader(canvas, size, 1, ui.Paint()..blendMode = ui.BlendMode.dstOut, const ui.Color(0xFF000000));
    canvas.restore();
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.toInt(), size.height.toInt());
    picture.dispose();
    image.dispose();
  }

  static bool _warm = false;

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
    _tileBytes = 0;
  }

  static void _paintLines(ui.Canvas canvas, List<ui.Rect> lines, ui.Paint paint, ui.Paint layer) {
    if (lines.isEmpty) return;
    canvas.saveLayer(lines.reduce((a, b) => a.expandToInclude(b)).inflate(1), layer);
    for (final line in lines) {
      canvas.drawRect(line, paint);
    }
    canvas.restore();
  }

  static double _snap(double v, double dpr) => (v * dpr).roundToDouble() / dpr;

  /// How far a staff's barlines reach past its outer lines, device units: one-line
  /// (percussion) staves' a staff space.
  double _bleed(StaffInfo staff) => display.data.staffSpace * (staff.lines <= 1 ? 1.0 : 0.08);

  /// Every barline's vertical strokes (centre and width, device units) in x order, once each:
  /// what a join between two staves draws of them.
  late final List<({double x, double width})> _barlineStrokes = () {
    final strokes = <(double, double)>{};
    for (final item in display.barlines.items) {
      if (item is! ShapeItem) continue;
      final b = item.path.getBounds();
      final stroke = item.stroke?.strokeWidth;
      if (stroke != null && b.width < 1e-3 && b.height > 0) {
        strokes.add((b.left, stroke));
      } else if (stroke == null && item.fill != null && b.height > 4 * b.width) {
        strokes.add((b.center.dx, b.width));
      }
    }
    return [for (final (x, width) in strokes) (x: x, width: width)]..sort((a, b) => a.x.compareTo(b.x));
  }();

  /// The first of [_barlineStrokes] reaching past [x].
  int _firstStrokeFrom(double x) {
    var low = 0, high = _barlineStrokes.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_barlineStrokes[mid].x + _barlineStrokes[mid].width < x) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  _Tile? _tile(int staffIndex, int index) {
    final key = (staffIndex, index);
    final cached = _tiles.remove(key);
    if (cached != null) return _tiles[key] = cached..frame = _frame; // mark as recently used
    if (_emptyTiles.contains(key)) return null;
    final tile = _render(staffIndex, index);
    if (tile == null) {
      _emptyTiles.add(key);
      return null;
    }
    _tiles[key] = tile..frame = _frame;
    _tileBytes += tile.bytes;
    // Oldest first; once the oldest is this frame's, so is every later one.
    while (_tileBytes > maxTileBytes && _tiles.values.first.frame != _frame) {
      final old = _tiles.remove(_tiles.keys.first)!;
      _tileBytes -= old.bytes;
      old.image.dispose();
    }
    return tile;
  }

  _Tile? _render(int staffIndex, int index) {
    final staff = display.staves[staffIndex];
    final s = scale, dpr = _tileDpr;
    final left = index * _tileUnits, right = left + _tileUnits;
    final items = staff.itemsIn(left, right).toList();
    if (items.isEmpty && !staff.hasLinesIn(left, right)) return null; // lines alone: still its barlines

    // Vertical extent: the staff lines plus whatever ink reaches outside them in this tile.
    // One-line (percussion) staves get barlines a staff space above and below the line.
    final bleed = _bleed(staff.info);
    // Barlines run on to the next staff of the instrument, to its top line: from there on
    // that staff draws them.
    final through = barlinesThrough[staffIndex];
    final barlinesTo = through == null ? staff.info.top + staff.info.height + bleed : display.staves[through].info.top;
    var top = staff.info.top, bottom = math.max(staff.info.top + staff.info.height, barlinesTo);
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
    // Barlines: only the slice crossing this staff's own lines, and on through its instrument.
    canvas.clipRect(ui.Rect.fromLTRB(left, staff.info.top - bleed, right, barlinesTo));
    for (final item in display.barlines.itemsIn(left, right)) {
      item.paint(canvas);
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(width, height);
    picture.dispose();
    return _Tile(image, offsetPx / dpr);
  }

  final _labelCache = <String, ui.Paragraph>{};

  /// Covers the names' and frozen zone's room left of [left] with [paint] in [color], and the
  /// [_fade] after it with [color] fading out.
  static void _coverHeader(ui.Canvas canvas, ui.Size size, double left, ui.Paint paint, ui.Color color) {
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, left, size.height), paint..color = color);
    canvas.drawRect(
      ui.Rect.fromLTWH(left, 0, _fade, size.height),
      paint
        ..shader = ui.Gradient.linear(
          ui.Offset(left, 0),
          ui.Offset(left + _fade, 0),
          [color, color.withValues(alpha: 0)],
        ),
    );
  }

  /// [paper]: null when the music under the header was cut out instead (see-through paper).
  /// [nameRight]: where the names end, right-aligned.
  void _paintHeader(ui.Canvas canvas, ui.Size size, List<StaffLabel> labels, double left, ui.Color? paper,
      ui.ColorFilter ink, {required double nameRight}) {
    // Names and the frozen zone sit on paper; the music fades out as it slides underneath.
    if (paper != null) _coverHeader(canvas, size, left, ui.Paint(), paper);
    for (final label in labels) {
      if (label.opacity <= 0.001) continue;
      final width = nameRight - 4;
      var paragraph = _label(label.text, width);
      if (paragraph.maxIntrinsicWidth > width && label.shortText.isNotEmpty) {
        paragraph = _label(label.shortText, width);
      }
      final color = label.color;
      canvas.saveLayer(
          null,
          ui.Paint()
            ..color = ui.Color.fromRGBO(0, 0, 0, label.opacity)
            ..colorFilter = color == null ? ink : ui.ColorFilter.mode(color, ui.BlendMode.srcIn));
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
  int get bytes => image.width * image.height * 4;

  /// The paint call that last drew it.
  int frame = 0;

  /// Offset of the image's top edge from the staff's top line, logical pixels.
  final double top;
}
