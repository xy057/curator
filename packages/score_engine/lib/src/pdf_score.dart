import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'display_list.dart';
import 'engraving.dart';
import 'pdf_layout.dart';
import 'pdf_pages.dart';
import 'score_metadata.dart';

/// Where a PDF score's systems are drawn from: its PDF read here ([PdfPagesSource]), or pictures
/// of them written beforehand (a web page's).
abstract class PdfPartSource {
  /// System [system] of [layout] as printed ([PdfPages.picture]), and the part of its page it
  /// covers (points).
  Future<({ui.Image image, ui.Rect area})> system(PdfScoreLayout layout, int system);

  void close();
}

/// Systems drawn from the PDF itself, by PDFium.
class PdfPagesSource implements PdfPartSource {
  PdfPagesSource(this.pages, {this.pixelsPerSpace = 24});

  final PdfPages pages;

  /// How sharp they are: pixels a staff space (a 1440p video draws some 25).
  final double pixelsPerSpace;

  @override
  Future<({ui.Image image, ui.Rect area})> system(PdfScoreLayout layout, int system) async {
    final p = await pages.picture(layout.systems[system], pixelsPerSpace: pixelsPerSpace);
    return (image: await decodePicture(p), area: p.area);
  }

  /// [picture] as an image, its pixels as they are.
  static Future<ui.Image> decodePicture(PdfPicture picture) {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(picture.rgba, picture.width, picture.height, ui.PixelFormat.rgba8888, done.complete);
    return done.future;
  }

  /// The pages are their owner's to close.
  @override
  void close() {}
}

/// A PDF score as the scene draws it: [layout], and each system as printed, as a picture, read
/// when a frame first asks for it and kept while they fit in [budget] bytes (the least recently
/// drawn go first, never those a frame is drawn with: [load]). Nothing in it is changed: each staff's bar is a rectangle of its system's
/// picture (where it meets its staff's region, [PdfSystem.regionOf]), the masks cut out. It notifies when one is
/// ready, so a view can draw again; a video waits for them ([load]).
class PdfScoreArt extends ChangeNotifier {
  PdfScoreArt(this.layout, this._source, {this.budget = 384 << 20});

  final PdfScoreLayout layout;
  final PdfPartSource _source;
  final int budget;

  final _systems = <int, ({ui.Image image, ui.Rect area})>{}; // least recently used first
  final _loading = <int, Future<void>>{};
  final _failed = <int>{};
  int _bytes = 0;
  bool _disposed = false;

  /// System [system] as a picture, with the part of its page it covers (points); null while it
  /// is read (asking starts that) or when it couldn't be.
  ({ui.Image image, ui.Rect area})? picture(int system) {
    final picture = _systems.remove(system);
    if (picture == null) {
      if (!_failed.contains(system)) _wanted(system);
      _request(system);
      return null;
    }
    _systems[system] = picture;
    return picture;
  }

  /// Whether a system drawn isn't ready yet: what is drawn has holes until it is (a view says
  /// so). Notifies as it changes.
  bool get isWaiting => _waiting.isNotEmpty;
  final _waiting = <int>{};

  /// [system] was drawn before it was ready. (Said a moment later: it is asked while drawing.)
  void _wanted(int system) {
    if (!_waiting.add(system) || _waiting.length > 1) return;
    scheduleMicrotask(() {
      if (!_disposed) notifyListeners();
    });
  }

  /// Reads [systems]' pictures, if they aren't ready. They are what [holder] (a scene; this,
  /// when none says) draws together, so none of them goes to make room until it asks for others
  /// or lets go ([release]), whatever the [budget]: a frame never waits for one only to find
  /// another gone.
  Future<void> load(Iterable<int> systems, {Object? holder}) {
    final wanted = systems.toSet();
    _held[holder ?? this] = wanted;
    return Future.wait([for (final s in wanted) _request(s)]);
  }

  /// [holder]'s systems ([load]) may go again.
  void release(Object holder) => _held.remove(holder);

  /// What each holder last asked for together.
  final _held = <Object, Set<int>>{};

  Future<void> _request(int system) {
    if (_disposed || _systems.containsKey(system) || _failed.contains(system)) return Future.value();
    // (A block: the removed future returned from whenComplete's callback would be waited for.)
    return _loading[system] ??= _read(system).whenComplete(() {
      _loading.remove(system);
    });
  }

  Future<void> _read(int system) async {
    final ui.Image image;
    final ui.Rect area;
    try {
      (:image, :area) = await _source.system(layout, system);
    } on Object catch (e) {
      debugPrint('Couldn’t read system ${system + 1} of the PDF: $e');
      _failed.add(system);
      if (_waiting.remove(system) && _waiting.isEmpty && !_disposed) notifyListeners();
      return;
    }
    if (_disposed) return image.dispose();
    _waiting.remove(system);
    _systems[system] = (image: image, area: area);
    _bytes += image.width * image.height * 4;
    // The oldest go, but never the one just read, nor one a frame is drawn with ([load]).
    while (_bytes > budget) {
      final oldest = _systems.keys.where((k) => k != system && !_held.values.any((held) => held.contains(k))).firstOrNull;
      if (oldest == null) break;
      final gone = _systems.remove(oldest)!;
      _bytes -= gone.image.width * gone.image.height * 4;
      gone.image.dispose();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final p in _systems.values) {
      p.image.dispose();
    }
    _systems.clear();
    _held.clear();
    _source.close();
    super.dispose();
  }
}

/// A system's picture, as a [PictureItem] draws it.
class _SystemPicture implements PictureSource {
  _SystemPicture(this.art, this.system);
  final PdfScoreArt art;
  final int system;

  @override
  ui.Image? get image => art.picture(system)?.image;
}

/// A rectangle of a system's picture: [from] (points on its page) drawn into [dst] (device
/// units), [masks] (points) left out.
class _PdfPiece extends PictureItem {
  _PdfPiece(_SystemPicture source, this.from, ui.Rect dst, ui.Rect bounds, this.masks) : super(source, ui.Rect.zero, dst, bounds);

  final ui.Rect from;
  final List<ui.Rect> masks;

  static final _paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;

  @override
  void paint(ui.Canvas canvas) {
    final source = this.source as _SystemPicture;
    final picture = source.art.picture(source.system);
    if (picture == null) return;
    final (:image, :area) = picture;
    final cover = area.intersect(from);
    if (cover.width <= 0 || cover.height <= 0) return;
    final sx = dst.width / from.width, sy = dst.height / from.height;
    ui.Rect onScreen(ui.Rect r) => ui.Rect.fromLTRB(dst.left + (r.left - from.left) * sx, dst.top + (r.top - from.top) * sy,
        dst.left + (r.right - from.left) * sx, dst.top + (r.bottom - from.top) * sy);
    final px = image.width / area.width, py = image.height / area.height;
    canvas.save();
    canvas.clipRect(onScreen(cover));
    for (final m in masks) {
      if (m.overlaps(cover)) canvas.clipRect(onScreen(m), clipOp: ui.ClipOp.difference);
    }
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTRB(
          (cover.left - area.left) * px, (cover.top - area.top) * py, (cover.right - area.left) * px, (cover.bottom - area.top) * py),
      onScreen(cover),
      _paint,
    );
    canvas.restore();
  }
}

/// How a PDF score is laid out as an engraving: [unit] device units a staff space, its bars end
/// to end as wide as printed (each system's staff space made one [unit]), each instrument's
/// staves stacked in score order.
abstract final class PdfEngraving {
  static const unit = 20.0;
  static const _lead = 2 * unit;
  static const _staffGap = 24 * unit;

  /// The engraving [layout] is drawn as, its staves [metadata]'s (the score written for it, with
  /// any spacers' parts after its own): bars, staves, and the clef, key and time signatures the
  /// frozen zone shows. It records no drawing: [displayList] draws the PDF.
  static EngravingData of(PdfScoreLayout layout, ScoreMetadata metadata) {
    final measures = <MeasureLayout>[];
    var x = _lead;
    for (final (bar, pieces) in layout.bars.indexed) {
      final width = pieces.fold(0.0, (w, p) => w + (p.right - p.left) / layout.systems[p.system].space * unit);
      measures.add(MeasureLayout(
          left: x, right: x + width, duration: layout.quartersOf(bar), onsetTimes: Float64List(0), onsetXs: Float64List(0)));
      x += width;
    }
    final staves = <StaffInfo>[];
    final signatures = <Signature>[];
    for (final part in metadata.parts) {
      final instrument = layout.playerOf(part.id)?.$1;
      for (final (k, n) in part.staffNumbers.indexed) {
        staves.add(StaffInfo(n: n, top: (n - 1) * _staffGap, height: 4 * unit, lines: 5));
        if (instrument == null || instrument.blank) continue; // a spacer, a blank lane
        final clef = instrument.clefAt(0, k + 1);
        for (final bar in [0, for (final (b, staff) in instrument.clefs.keys) if (staff == k + 1 && b > 0 && b < measures.length) b]) {
          final c = instrument.clefAt(bar, k + 1);
          signatures.add(ClefSignature(
              staff: n,
              x: bar == 0 ? 0 : measures[bar].left,
              commandStart: 0,
              commandCount: 0,
              shape: c.shape,
              line: c.line,
              octave: c.octave));
        }
        if (clef != PdfClef.percussion) {
          signatures.add(KeySignature(staff: n, x: 0, commandStart: 0, commandCount: 0, fifths: instrument.key.keyOf(layout.fifths)));
          for (final MapEntry(key: bar, value: fifths) in layout.keys.entries) {
            if (bar > 0 && bar < measures.length) {
              signatures.add(KeySignature(
                  staff: n, x: measures[bar].left, commandStart: 0, commandCount: 0, fifths: instrument.key.keyOf(fifths)));
            }
          }
        }
        // The score's meter, or the instrument's own where it has one.
        for (final bar in {0, ...layout.meters.keys, ...instrument.meters.keys}.where((b) => b < measures.length)) {
          final meter = layout.meterOf(instrument, bar);
          final summands = [for (final b in meter.beats.split('+')) int.tryParse(b) ?? 0];
          signatures.add(TimeSignature(
              staff: n,
              x: bar == 0 ? 0 : measures[bar].left,
              commandStart: 0,
              commandCount: 0,
              count: summands.fold(0, (a, b) => a + b),
              unit: meter.unit,
              summands: summands));
        }
      }
    }
    signatures.sort((a, b) => a.x.compareTo(b.x));
    return EngravingData(
      width: x + _lead,
      staffSpace: unit,
      staves: staves,
      measures: measures,
      commandBytes: Uint8List(0),
      pathBytes: Uint8List(0),
      text: Uint8List(0),
      classNames: const [],
      fontNames: const [],
      signatures: signatures,
      sourceIds: const [],
      warnings: const [],
    );
  }

  /// [data] ([of]) as drawable staves: each bar of each staff a piece of its system's picture,
  /// placed so its lines are the staff's; where an instrument has no staff in a system (hidden
  /// there, as printed) nothing is drawn, no lines or rests the PDF doesn't have. [spacers]: staff
  /// numbers of vertical spacers, as [ScoreDisplayList.build] takes them.
  static ScoreDisplayList displayList(PdfScoreArt art, EngravingData data, ScoreMetadata metadata,
      {Map<int, ({double height, bool lines})> spacers = const {}}) {
    final layout = art.layout;
    final info = {for (final s in data.staves) s.n: s};
    final items = <int, List<DisplayItem>>{};
    final staffOf = <String, List<int>>{for (final p in metadata.parts) p.id: p.staffNumbers};
    const thickness = 0.13 * unit;
    final masks = <int, List<PdfMask>>{};
    for (final m in layout.masks) {
      masks.putIfAbsent(m.page, () => []).add(m);
    }
    final strokes = <({double x, double width})>[];
    for (final (bar, pieces) in layout.bars.indexed) {
      if (bar >= data.measures.length) break;
      var x = data.measures[bar].left;
      for (final piece in pieces) {
        final system = layout.systems[piece.system];
        final width = (piece.right - piece.left) / system.space * unit;
        final segment = layout.barOfSegment[piece.system].indexOf(bar);
        for (final (s, staff) in system.staves.indexed) {
          final part = layout.partOf(staff);
          final numbers = staffOf[part], k = layout.staffInPart(staff);
          if (numbers == null || k > numbers.length) continue;
          final n = numbers[k - 1];
          final top = info[n]!.top;
          final ink = system.ink;
          final reach = ink == null || segment < 0 || segment >= ink[s].length
              ? (above: 4.0, below: 4.0, played: true)
              : ink[s][segment];
          double yOf(double pageY) => top + (pageY - staff.top) / staff.space * unit;
          double xOf(double pageX) => x + (pageX - piece.left) / system.space * unit;
          // The bar where it meets the staff's region, cut straight: what the import set, nothing
          // worked out here. A region that ends before the bar does leaves the rest of it blank.
          final region = system.regionOf(s);
          final l = math.max(piece.left, region.left), r = math.min(piece.right, region.right);
          if (r <= l) continue;
          final from = ui.Rect.fromLTRB(l, region.top, r, region.bottom);
          items.putIfAbsent(n, () => []).add(_PdfPiece(
                _SystemPicture(art, piece.system),
                from,
                ui.Rect.fromLTRB(xOf(l), yOf(region.top), xOf(r), yOf(region.bottom)),
                ui.Rect.fromLTRB(xOf(l), math.max(yOf(region.top), top - reach.above * unit), xOf(r),
                    math.min(yOf(region.bottom), top + 4 * unit + reach.below * unit)),
                [for (final m in masks[system.page] ?? const <PdfMask>[]) if (m.covers(part)) m.rect],
              ));
        }
        x += width;
      }
      strokes.add((x: data.measures[bar].right, width: 0.16 * unit));
    }
    final binWidth = data.staffSpace * 16;
    // The tempo marks, where their bars start: what the frame's left says of the speed (their
    // words are the score's texts, [PdfScoreLayout.tempoId]); nothing of them is drawn.
    final apart = [
      for (final MapEntry(key: bar, value: mark) in layout.tempos.entries)
        if (mark.words.trim().isNotEmpty && bar < data.measures.length)
          (
            id: PdfScoreLayout.tempoId(bar),
            items: const <DisplayItem>[],
            bounds: ui.Rect.fromLTWH(data.measures[bar].left, -2 * unit, unit, unit),
            baseline: -unit,
          ),
    ];
    return ScoreDisplayList.of(
      data,
      [
        for (final staff in data.staves)
          switch (spacers[staff.n]) {
            null => StaffLayer(staff, items[staff.n] ?? [], binWidth: binWidth),
            (:final height, lines: true) => StaffLayer(staff, const [],
                binWidth: binWidth,
                lines: [
                  for (var k = 0; k < 5; k++) (y: staff.top + k * unit, left: _lead, right: data.width - _lead, thickness: thickness),
                ],
                reach: math.max(0.0, height * unit - staff.height) / 2),
            (:final height, lines: false) => StaffLayer(
                StaffInfo(n: staff.n, top: staff.top + (staff.height - height * unit) / 2, height: height * unit, lines: 0), const [],
                binWidth: binWidth),
          },
      ],
      strokes: strokes,
      apart: apart,
    );
  }

  /// The systems whose music is drawn between [left] and [right] (device units of [of]'s
  /// engraving): what a frame showing them needs read ([PdfScoreArt.load]).
  static Set<int> systemsIn(PdfScoreLayout layout, EngravingData data, double left, double right) {
    final out = <int>{};
    for (final (bar, pieces) in layout.bars.indexed) {
      if (bar >= data.measures.length) break;
      final m = data.measures[bar];
      if (m.right < left || m.left > right) continue;
      for (final p in pieces) {
        out.add(p.system);
      }
    }
    return out;
  }
}
