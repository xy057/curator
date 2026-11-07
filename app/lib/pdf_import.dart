import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'dialog_kit.dart';
import 'l10n/l10n.dart';
import 'lanes_common.dart';
import 'menu_kit.dart';
import 'pdf_import_changes.dart';
import 'pdf_ocr.dart';
import 'ui_kit.dart';

/// Opening a PDF score, or Project Info ▸ Score ▸ Edit… for one: its pages over the window, what
/// was found on them drawn over each (systems, the cuts between their staves, barlines, where the
/// music starts, masks), each staff's instrument at its left, and the score's instruments, meter
/// and key at the right. Everything found can be moved, added or taken away here; this is the
/// only place the PDF is worked on (the score shows it as printed, cut along what is set here).
/// [layout] is the one to edit; none: the PDF is read first ([PdfPages.read]). Returns the
/// layout, each system's bars measured ([PdfPages.measure]); null when cancelled.
Future<PdfScoreLayout?> showPdfImport(BuildContext context, PdfPages pages, {required String name, PdfScoreLayout? layout}) =>
    Navigator.of(context, rootNavigator: true).push<PdfScoreLayout>(PageRouteBuilder(
      opaque: true,
      transitionDuration: motion(context, 200),
      reverseTransitionDuration: motion(context, 160),
      pageBuilder: (_, _, _) => PdfImport(pages: pages, name: name, layout: layout),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic), child: child),
    ));

/// What the pointer does on a page.
enum _Tool { select, mask }

/// The import's steps, in order: the systems found on the pages, the instruments, whose each
/// staff is, what changes where, then the score's own fields.
enum _Step {
  pages('Pages'),
  instruments('Instruments'),
  staves('Staves'),
  changes('Changes'),
  review('Review');

  const _Step(this.label);
  final String label;
}

/// What is selected on the page.
sealed class _Selection {
  const _Selection();
}

/// A bar: system [system], its [segment]th bar ([PdfSystem.segments]), on its [staff]th staff
/// (null: between the system's edges, on none).
class _BarSelection extends _Selection {
  const _BarSelection(this.system, this.segment, [this.staff]);
  final int system, segment;
  final int? staff;
}

class _BarlineSelection extends _Selection {
  const _BarlineSelection(this.system, this.barline);
  final int system, barline;
}

class _MaskSelection extends _Selection {
  const _MaskSelection(this.mask);
  final int mask;
}

/// The gap below system [system]'s cut [cut] ([PdfSystem.gaps]).
class _GapSelection extends _Selection {
  const _GapSelection(this.system, this.cut);
  final int system, cut;

  @override
  bool operator ==(Object other) => other is _GapSelection && other.system == system && other.cut == cut;

  @override
  int get hashCode => Object.hash(system, cut);
}

/// What a drag moves: a system's top (-1), bottom (-2) or a cut (0…), a gap's bottom, its
/// music's start, or a barline.
sealed class _Drag {
  const _Drag(this.system);
  final int system;
}

class _EdgeDrag extends _Drag {
  const _EdgeDrag(super.system, this.edge);
  final int edge;
}

/// The bottom of the gap below cut [cut] (its top is the cut).
class _GapDrag extends _Drag {
  const _GapDrag(super.system, this.cut);
  final int cut;
}

class _StartDrag extends _Drag {
  const _StartDrag(super.system);
}

class _BarlineDrag extends _Drag {
  const _BarlineDrag(super.system, this.barline);
  final int barline;
}

class PdfImport extends StatefulWidget {
  const PdfImport({super.key, required this.pages, required this.name, this.layout});
  final PdfPages pages;
  final String name;
  final PdfScoreLayout? layout;

  @override
  State<PdfImport> createState() => _PdfImportState();
}

class _PdfImportState extends State<PdfImport> {
  PdfPages get pages => widget.pages;

  PdfScoreLayout? _layout;
  final _undo = <PdfScoreLayout>[], _redo = <PdfScoreLayout>[];

  /// The field being typed in: its edits are one Undo step.
  String? _typing;

  /// Counts edits made other than by typing in the panel's fields (a dialog's, Undo): their
  /// fields are made again to show them.
  int _rev = 0;

  /// Pages read so far, while reading; then null.
  int? _read;

  /// Systems measured so far, while Done measures them.
  int? _measured;
  String? _error;

  int _page = 0;
  double _zoom = 1.4; // view points a page point
  _Tool _tool = _Tool.select;
  _Selection? _selection;
  int _instrument = 0; // the one the panel edits
  bool _edited = false;
  _Step _step = _Step.pages;

  /// Each page's words, read so far ([PdfOcr]): its own text, or recognised in a scan.
  final _text = <int, List<PdfTextRun>>{};

  /// The page whose words are being read; null when none is.
  int? _readingText;

  /// A new import's "Staff 1"… named from the pages once, by themselves.
  bool _namedByText = false;

  /// Bars whose tempo mark read off the page was dismissed.
  final _dismissed = <int>{};

  _Drag? _drag;
  Rect? _drawing; // a mask being drawn, page points
  Offset? _drawFrom;

  final _focus = FocusNode(debugLabel: 'PDF import');
  final _horizontal = ScrollController(), _vertical = ScrollController();
  final _images = <int, ({ui.Image image, double scale})>{};
  final _rendering = <int>{};

  static const _gutter = 132.0, _margin = 24.0, _grab = 6.0;

  @override
  void initState() {
    super.initState();
    if (widget.layout case final layout?) {
      _layout = layout;
      _namedByText = true; // named already
      WidgetsBinding.instance.addPostFrameCallback((_) => _readText());
    } else {
      _readAll();
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _horizontal.dispose();
    _vertical.dispose();
    for (final i in _images.values) {
      i.image.dispose();
    }
    super.dispose();
  }

  Future<void> _readAll() async {
    setState(() => _read = 0);
    try {
      final layout = await pages.read(
          title: widget.name.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), ''),
          onPage: (done, _) {
            if (mounted) setState(() => _read = done);
          });
      if (!mounted) return;
      setState(() {
        _layout = layout;
        _read = null;
        _edited = true;
      });
      unawaited(_readText());
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  // MARK: Text

  /// The page of the system with the most staves: the one the instruments are named from.
  int get _namesPage =>
      layout.systems.fold<PdfSystem?>(null, (best, s) => best == null || s.staves.length > best.staves.length ? s : best)?.page ?? 0;

  /// Reads every page's words in turn ([PdfOcr]), the page the instruments are named from and the
  /// next first (their names and abbreviations), naming a new import's instruments from them.
  Future<void> _readText() async {
    if (_readingText != null) return;
    final first = _namesPage;
    final order = {first, if (first + 1 < pages.length) first + 1, for (var p = 0; p < pages.length; p++) p};
    for (final p in order) {
      if (_text.containsKey(p)) continue;
      if (!mounted) return;
      setState(() => _readingText = p);
      List<PdfTextRun> runs;
      try {
        runs = await PdfOcr.runsOf(pages, p);
      } on Object {
        runs = const [];
      }
      if (!mounted) return;
      setState(() => _text[p] = runs);
      if (!_namedByText && _text.containsKey(first) && (first + 1 >= pages.length || _text.containsKey(first + 1))) {
        _namedByText = true;
        _nameFromText(onlyUnnamed: true);
      }
    }
    if (mounted) setState(() => _readingText = null);
  }

  /// "Staff 3": an instrument the PDF didn't name.
  static final _unnamed = RegExp(r'^Staff \d+$');

  /// The instruments named as the pages read so far name them ([PdfText.names]): with
  /// [onlyUnnamed], only those still "Staff 1"…. Whether any changed.
  bool _nameFromText({bool onlyUnnamed = false}) {
    if (_layout == null) return false;
    final found = PdfText.names(layout, _text);
    final next = [
      for (final i in layout.instruments)
        switch (found[i.id]) {
          final f? when !onlyUnnamed || _unnamed.hasMatch(i.name) => () {
              final named = i.renamed(_titled(f.name)).copyWith(abbreviation: f.abbreviation == null ? null : _titled(f.abbreviation!));
              return _unnamed.hasMatch(i.name) ? named.copyWith(clef: PdfClef.forName(f.name)) : named;
            }(),
          _ => i,
        },
    ];
    if (listEquals(next, layout.instruments)) return false;
    _changed(layout.copyWith(instruments: next));
    return true;
  }

  /// A name printed in capitals ("PETITE FLÛTE") as a name is written; roman numerals kept.
  static String _titled(String name) {
    if (!RegExp(r'[A-ZÀ-Þ]{4}').hasMatch(name)) return name;
    return name.replaceAllMapped(RegExp(r'[A-ZÀ-Þ]{2,}'), (m) {
      final w = m[0]!;
      return RegExp(r'^[IVX]+$').hasMatch(w) ? w : w[0] + w.substring(1).toLowerCase();
    });
  }

  /// The tempo marks read off the pages ([PdfText.tempos]) the score hasn't, nor dismissed.
  Map<int, PdfTempo> get _suggested {
    final key = (layout, _text.length, _dismissed.length);
    if (_suggestedFor != key) {
      _suggestedFor = key;
      _suggestedCache = {
        for (final MapEntry(:key, :value) in PdfText.tempos(layout, _text).entries)
          if (!layout.tempos.containsKey(key) && !_dismissed.contains(key)) key: value,
      };
    }
    return _suggestedCache;
  }

  Object? _suggestedFor;
  Map<int, PdfTempo> _suggestedCache = const {};

  /// [marks] put in the score, one Undo step: the first bar's speed is the score's.
  void _accept(Map<int, PdfTempo> marks) {
    if (marks.isEmpty) return;
    final tempos = {...layout.tempos};
    double? first;
    for (final MapEntry(key: bar, value: mark) in marks.entries) {
      tempos[bar] = bar == 0 ? PdfTempo(mark.words) : mark;
      if (bar == 0) first = mark.bpm;
    }
    _changed(layout.copyWith(tempos: tempos, tempo: first));
  }

  /// Bar [bar] shown and selected, on its first system.
  void _showBar(int bar) {
    if (bar >= layout.bars.length) return;
    final system = layout.bars[bar].first.system;
    _goTo(layout.systems[system].page);
    setState(() => _selection = _BarSelection(system, layout.barOfSegment[system].indexOf(bar)));
  }

  /// "Bar 12", counted as printed (an upbeat is bar 0).
  String _barName(int bar) => 'Bar {n}'.fill({'n': bar + 1 - (layout.pickup > 0 ? 1 : 0)});

  // MARK: Steps

  void _goToStep(_Step step) {
    if (_layout == null || _measured != null) return;
    setState(() {
      _step = step;
      _selection = null;
      _tool = _Tool.select;
      _drag = null;
      _drawFrom = null;
      _drawing = null;
    });
    _focus.requestFocus();
  }

  /// Staves no instrument has.
  int get _unassigned => layout.systems.fold(0, (n, s) => n + s.staves.where((t) => t.part == null).length);

  /// The next page, from the one showing on, with a staff no instrument has.
  void _showUnassigned() {
    for (var k = 1; k <= pages.length; k++) {
      final p = (_page + k) % pages.length;
      if (layout.systems.any((s) => s.page == p && s.staves.any((t) => t.part == null))) return _goTo(p);
    }
  }

  // MARK: Editing

  PdfScoreLayout get layout => _layout!;

  /// [next] in place of the layout, one Undo step (or, typing in field [typing], one with the
  /// step before while it is the same field).
  void _edit(PdfScoreLayout next, {String? typing}) {
    if (typing == null || typing != _typing) {
      _undo.add(layout);
      _redo.clear();
    }
    _typing = typing;
    setState(() {
      _layout = next;
      _edited = true;
    });
  }

  void _undoStep() {
    if (_undo.isEmpty) return;
    _typing = null;
    setState(() {
      _redo.add(layout);
      _layout = _undo.removeLast();
      _selection = null;
      _rev++;
    });
  }

  void _redoStep() {
    if (_redo.isEmpty) return;
    _typing = null;
    setState(() {
      _undo.add(layout);
      _layout = _redo.removeLast();
      _selection = null;
      _rev++;
    });
  }

  void _setSystem(int index, PdfSystem system, {String? typing}) =>
      _edit(layout.copyWith(systems: [...layout.systems]..[index] = system.copyWith(ink: () => null)), typing: typing);

  /// [masks] in place of the layout's, one Undo step: the bars on the pages one changed on
  /// measured again.
  void _setMasks(List<PdfMask> masks) {
    final changed = {...layout.masks, ...masks}.difference(layout.masks.toSet().intersection(masks.toSet()));
    final pages = {for (final m in changed) m.page};
    _edit(layout.copyWith(masks: masks, systems: [
      for (final s in layout.systems) pages.contains(s.page) && s.ink != null ? s.copyWith(ink: () => null) : s,
    ]));
  }

  /// The lane whose staff [p] is on, on the page showing; null: none's.
  String? _laneAt(Offset p) {
    for (final (_, s) in _onPage) {
      for (var k = 0; k < s.staves.length; k++) {
        if (s.bandOf(k) case (final top, final bottom) when p.dy >= top && p.dy < bottom && p.dx >= s.left - 4 && p.dx <= s.right + 4) {
          return layout.partOf(s.staves[k]);
        }
      }
    }
    return null;
  }

  /// The systems on the page showing, with their indices.
  Iterable<(int, PdfSystem)> get _onPage => layout.systems.indexed.where((e) => e.$2.page == _page);

  void _remove() {
    switch (_selection) {
      case _BarlineSelection(:final system, :final barline):
        final s = layout.systems[system];
        _setSystem(system, s.copyWith(barlines: [...s.barlines]..removeAt(barline)));
      case _MaskSelection(:final mask):
        _setMasks([...layout.masks]..removeAt(mask));
      case _BarSelection(:final system):
        _edit(layout.copyWith(systems: [...layout.systems]..removeAt(system)));
      case _GapSelection(:final system, :final cut):
        _setSystem(system, _withoutGap(layout.systems[system], cut));
      case null:
        return;
    }
    setState(() => _selection = null);
  }

  /// [s] with the gap below cut [c] gone, the cut in its middle.
  static PdfSystem _withoutGap(PdfSystem s, int c) {
    final cuts = [for (var k = 0; k + 1 < s.staves.length; k++) s.cutAfter(k)];
    cuts[c] = (s.cutAfter(c) + s.resumeAfter(c)) / 2;
    return s.copyWith(cuts: cuts, gaps: {...s.gaps}..remove(c));
  }

  Future<void> _detectAgain() async {
    final found = await pages.detectAgain(_page, [for (final i in layout.instruments) if (!i.blank) i]);
    if (!mounted) return;
    final systems = [...layout.systems.where((s) => s.page < _page), ...found, ...layout.systems.where((s) => s.page > _page)];
    _edit(layout.copyWith(systems: systems));
    setState(() => _selection = null);
  }

  // MARK: Pages

  void _goTo(int page) {
    final p = page.clamp(0, pages.length - 1);
    if (p == _page) return;
    setState(() {
      _page = p;
      _selection = null;
    });
    if (_vertical.hasClients) _vertical.jumpTo(0);
  }

  void _zoomBy(double factor) => setState(() => _zoom = (_zoom * factor).clamp(0.4, 6.0));

  /// The page showing as printed, at the view's resolution, rendered when it isn't yet.
  ui.Image? _imageOf(int page, double devicePixelRatio) {
    final want = math.min(_zoom * devicePixelRatio, 6.0);
    final have = _images[page];
    if ((have == null || (have.scale - want).abs() > want * 0.2) && _rendering.add(page)) {
      pages.page(page, want).then((p) {
        final done = Completer<ui.Image>();
        ui.decodeImageFromPixels(p.rgba, p.width, p.height, ui.PixelFormat.rgba8888, done.complete);
        return done.future;
      }).then((image) {
        _rendering.remove(page);
        if (!mounted) return image.dispose();
        setState(() {
          _images.remove(page)?.image.dispose();
          _images[page] = (image: image, scale: want);
          // Keep a few around.
          while (_images.length > 3) {
            _images.remove(_images.keys.firstWhere((k) => k != page))!.image.dispose();
          }
        });
      }, onError: (Object e) => _rendering.remove(page));
    }
    return have?.image;
  }

  // MARK: Pointer

  Offset _toPage(Offset local) => (local - const Offset(_gutter, _margin)) / _zoom;

  /// What is under [p] (page points) to drag, if anything.
  _Drag? _dragAt(Offset p) {
    final grab = _grab / _zoom;
    for (final (i, s) in _onPage) {
      final handleX = s.right + 10 / _zoom;
      final edges = [(-1, s.top), for (var c = 0; c + 1 < s.staves.length; c++) (c, s.cutAfter(c)), (-2, s.bottom)];
      for (final (edge, y) in edges) {
        if ((p - Offset(handleX, y)).distance <= grab * 1.4) return _EdgeDrag(i, edge);
      }
      for (final c in s.gaps.keys) {
        if ((p - Offset(handleX, s.resumeAfter(c))).distance <= grab * 1.4) return _GapDrag(i, c);
      }
      if (p.dy < s.top || p.dy > s.bottom) continue;
      if ((p.dx - s.left).abs() <= grab) return _StartDrag(i);
      for (final (b, line) in s.barlines.indexed) {
        if ((p.dx - line.x).abs() <= grab) return _BarlineDrag(i, b);
      }
    }
    return null;
  }

  _Selection? _selectionAt(Offset p) {
    for (final (i, m) in layout.masks.indexed) {
      if (m.page == _page && m.rect.contains(p)) return _MaskSelection(i);
    }
    for (final (i, s) in _onPage) {
      if (p.dy < s.top || p.dy > s.bottom || p.dx < s.left - 4 || p.dx > s.right + 4) continue;
      final grab = _grab / _zoom;
      for (final (b, line) in s.barlines.indexed) {
        if ((p.dx - line.x).abs() <= grab) return _BarlineSelection(i, b);
      }
      for (final c in s.gaps.keys) {
        if (s.gapAfter(c) case (final top, final bottom) when p.dy >= top && p.dy <= bottom) return _GapSelection(i, c);
      }
      final staff = [
        for (var k = 0; k < s.staves.length; k++)
          if (s.bandOf(k) case (final top, final bottom) when p.dy >= top && p.dy < bottom) k,
      ].firstOrNull;
      for (final (k, (l, r)) in s.segments.indexed) {
        if (p.dx >= l && p.dx <= r) return _BarSelection(i, k, staff);
      }
      return _BarSelection(i, 0, staff);
    }
    return null;
  }

  void _down(Offset local) {
    _focus.requestFocus();
    final p = _toPage(local);
    if (_step != _Step.pages) {
      // Only the pages' step changes what was found: elsewhere a click picks a bar, or a staff's
      // instrument.
      final hit = _selectionAt(p);
      setState(() {
        if (_step == _Step.changes) _selection = hit is _BarSelection ? hit : null;
        if (hit case _BarSelection(:final system, staff: final k?) when _step != _Step.changes) {
          final at = layout.instruments.indexWhere((i) => i.id == layout.systems[system].staves[k].part);
          if (at >= 0) _instrument = at;
        }
      });
      return;
    }
    if (_tool == _Tool.mask) {
      _drawFrom = p;
      return;
    }
    final drag = _dragAt(p);
    setState(() {
      _drag = drag;
      _selection = drag is _BarlineDrag ? _BarlineSelection(drag.system, drag.barline) : _selectionAt(p);
    });
    if (drag != null) {
      _undo.add(layout);
      _redo.clear();
      _typing = null;
    }
  }

  void _move(Offset local) {
    final p = _toPage(local);
    if (_drawFrom case final from?) {
      setState(() => _drawing = Rect.fromPoints(from, p));
      return;
    }
    final drag = _drag;
    if (drag == null) return;
    final s = layout.systems[drag.system];
    final PdfSystem next;
    switch (drag) {
      case _EdgeDrag(edge: -1):
        next = s.copyWith(top: math.min(p.dy, s.staves.first.top));
      case _EdgeDrag(edge: -2):
        next = s.copyWith(bottom: math.max(p.dy, s.staves.last.bottom));
      case _EdgeDrag(:final edge):
        // A gap's top: no lower than its bottom.
        final cuts = [for (var c = 0; c + 1 < s.staves.length; c++) s.cutAfter(c)];
        final below = s.gaps.containsKey(edge) ? s.resumeAfter(edge) : s.staves[edge + 1].top;
        cuts[edge] = p.dy.clamp(s.staves[edge].bottom, math.max(s.staves[edge].bottom, below));
        next = s.copyWith(cuts: cuts);
      case _GapDrag(:final cut):
        next = s.copyWith(gaps: {...s.gaps, cut: p.dy.clamp(s.cutAfter(cut), math.max(s.cutAfter(cut), s.staves[cut + 1].top))});
      case _StartDrag():
        next = s.copyWith(left: p.dx.clamp(0, s.right - s.space));
      case _BarlineDrag(:final barline):
        final lines = [...s.barlines];
        lines[barline] = PdfBarline(p.dx.clamp(s.left, s.right), lines[barline].kind);
        next = s.copyWith(barlines: lines);
    }
    setState(() {
      _layout = layout.copyWith(systems: [...layout.systems]..[drag.system] = next.copyWith(ink: () => null));
      _edited = true;
    });
  }

  void _up() {
    if (_drawing case final rect? when rect.width > 2 && rect.height > 2) {
      // The selected staff's lane's, else the lane it was drawn from; off the staves, every one's.
      final lane = switch (_selection) {
        _BarSelection(:final system, staff: final k?) when layout.systems[system].page == _page =>
          layout.partOf(layout.systems[system].staves[k]),
        _ => _laneAt(_drawFrom!),
      };
      _setMasks([...layout.masks, PdfMask(_page, rect, lane)]);
      _selection = _MaskSelection(layout.masks.length - 1);
    } else if (_drawFrom case final from?) {
      // A click with the mask tool: selects a mask.
      final hit = _selectionAt(from);
      setState(() => _selection = hit is _MaskSelection ? hit : null);
    }
    // A gap dragged shut is gone.
    if (_drag case _EdgeDrag(:final system, :final edge) || _GapDrag(:final system, cut: final edge) when edge >= 0) {
      final s = layout.systems[system];
      if (s.gaps.containsKey(edge) && s.resumeAfter(edge) - s.cutAfter(edge) < 0.5) {
        _layout = layout.copyWith(systems: [...layout.systems]..[system] = s.copyWith(gaps: {...s.gaps}..remove(edge)));
        if (_selection == _GapSelection(system, edge)) _selection = null;
      }
    }
    if (_drag case _BarlineDrag(:final system)) {
      // Kept in order.
      final s = layout.systems[system];
      final lines = [...s.barlines]..sort((a, b) => a.x.compareTo(b.x));
      _layout = layout.copyWith(systems: [...layout.systems]..[system] = s.copyWith(barlines: lines));
      _selection = null;
    }
    setState(() {
      _drag = null;
      _drawFrom = null;
      _drawing = null;
    });
  }

  /// A double click in a system: on a cut, a gap there, no one's (a third of the room between
  /// the staves, which its edges then change); in a gap, nothing; elsewhere a barline.
  void _doubleClick(Offset local) {
    final p = _toPage(local), grab = _grab / _zoom;
    for (final (i, s) in _onPage) {
      if (p.dx < s.left - grab || p.dx > s.right + 14 / _zoom) continue;
      for (var c = 0; c + 1 < s.staves.length; c++) {
        if (s.gapAfter(c) case (final top, final bottom) when p.dy >= top - grab && p.dy <= bottom + grab) return;
        if ((p.dy - s.cutAfter(c)).abs() > grab) continue;
        final from = s.staves[c].bottom, to = s.staves[c + 1].top, height = (to - from) / 3;
        final top = (s.cutAfter(c) - height / 2).clamp(from, math.max(from, to - height)).toDouble();
        final cuts = [for (var k = 0; k + 1 < s.staves.length; k++) s.cutAfter(k)]..[c] = top;
        _setSystem(i, s.copyWith(cuts: cuts, gaps: {...s.gaps, c: top + height}));
        setState(() => _selection = _GapSelection(i, c));
        return;
      }
    }
    for (final (i, s) in _onPage) {
      if (p.dy < s.top || p.dy > s.bottom || p.dx <= s.left || p.dx > s.right) continue;
      final lines = [...s.barlines, PdfBarline(p.dx)]..sort((a, b) => a.x.compareTo(b.x));
      _setSystem(i, s.copyWith(barlines: lines));
      setState(() => _selection = _BarlineSelection(i, lines.indexWhere((b) => b.x == p.dx)));
      return;
    }
  }

  // MARK: Instruments

  /// Instrument [id] renamed from a staff's chip; the panel then shows it.
  Future<void> _renameInstrument(String? id) async {
    final index = layout.instruments.indexWhere((i) => i.id == id);
    if (index < 0) return;
    final next = await showPdfInstrumentDialog(context, layout.instruments[index]);
    if (next == null || !mounted) return;
    _changedInstrument(next);
    setState(() => _instrument = index);
  }

  /// A new instrument, named in a dialog, for staff [k] of system [system].
  Future<void> _newInstrumentFor(int system, int k) async {
    final ids = {for (final i in layout.instruments) i.id};
    var n = layout.instruments.length + 1;
    while (ids.contains('P$n')) {
      n++;
    }
    final made = await showPdfInstrumentDialog(context, PdfInstrument(id: 'P$n', name: ''), isNew: true);
    if (made == null || !mounted) return;
    final s = layout.systems[system];
    final staves = [...s.staves]..[k] = s.staves[k].copyWith(part: () => made.id, staff: 1);
    _changed(layout.copyWith(
      instruments: [...layout.instruments, made.copyWith(clef: PdfClef.forName(made.name))],
      systems: [...layout.systems]..[system] = s.copyWith(staves: staves, ink: () => null),
    ));
    setState(() => _instrument = layout.instruments.length - 1);
  }

  // MARK: Changes

  /// Staff [k] of system [system]: its instrument and which of its staves it is (from 1).
  (PdfInstrument, int)? _instrumentOf(int system, int? k) {
    final s = layout.systems[system];
    if (k == null || k >= s.staves.length) return null;
    final staff = s.staves[k];
    return switch (layout.instrument(staff.part)) { final i? => (i, layout.staffInPart(staff)), null => null };
  }

  static String _staffName(PdfInstrument i, int n) => i.staves > 1 ? '${i.name} $n' : i.name;

  /// [next] after a dialog: one Undo step, the panel's fields showing it.
  void _changed(PdfScoreLayout next) {
    _edit(next);
    setState(() => _rev++);
  }

  void _changedInstrument(PdfInstrument next) =>
      _changed(layout.copyWith(instruments: [for (final i in layout.instruments) i.id == next.id ? next : i]));

  /// The tempo mark at bar [bar] added, changed or taken away; the first bar's speed is the score's.
  Future<void> _editTempo(int bar) async {
    final change = await showPdfTempoDialog(context, bar: bar, mark: layout.tempos[bar], tempo: layout.tempo);
    if (change == null || !mounted) return;
    final tempos = {...layout.tempos}..remove(bar);
    if (change.value case final mark? when bar > 0 || mark.words.isNotEmpty) tempos[bar] = bar == 0 ? PdfTempo(mark.words) : mark;
    _changed(layout.copyWith(tempos: tempos, tempo: bar == 0 ? change.value?.bpm : null));
  }

  /// The key from bar [bar] on, read as the staff clicked ([system]'s [staff]) shows it.
  Future<void> _editKey(int bar, int system, int? staff) async {
    final change = await showPdfKeyDialog(context,
        bar: bar,
        concert: bar == 0 ? layout.fifths : layout.keys[bar],
        inForce: layout.keyAt(bar),
        readAs: _instrumentOf(system, staff)?.$1.key ?? SpacerKey.c,
        instruments: layout.instruments);
    if (change == null || !mounted) return;
    if (bar == 0) {
      if (change.value case final f?) _changed(layout.copyWith(fifths: f));
      return;
    }
    final keys = {...layout.keys}..remove(bar);
    if (change.value case final f?) keys[bar] = f;
    _changed(layout.copyWith(keys: keys));
  }

  /// The score's meter from bar [bar] on.
  Future<void> _editTime(int bar) async {
    final change = await showPdfTimeDialog(context,
        title: 'Time Signature'.tr,
        meter: bar == 0 ? layout.meter : layout.meters[bar],
        inForce: layout.meterAt(bar),
        removable: bar > 0 && layout.meters.containsKey(bar));
    if (change == null || !mounted) return;
    if (bar == 0) {
      if (change.value case final m?) _changed(layout.copyWith(meter: m));
      return;
    }
    final meters = {...layout.meters}..remove(bar);
    if (change.value case final m?) meters[bar] = m;
    _changed(layout.copyWith(meters: meters));
  }

  /// [i]'s own time signature from bar [bar] on.
  Future<void> _editLocalTime(int bar, PdfInstrument i) async {
    final change = await showPdfTimeDialog(context,
        title: 'Time Signature for {name}'.fill({'name': i.name}),
        meter: i.meters[bar],
        inForce: layout.meterOf(i, bar),
        removable: i.meters.containsKey(bar));
    if (change == null || !mounted) return;
    final meters = {...i.meters}..remove(bar);
    if (change.value case final m?) meters[bar] = m;
    _changedInstrument(i.copyWith(meters: meters));
  }

  /// The clef of [i]'s staff [n] from bar [bar] on; its first staff's at the first bar is its clef.
  Future<void> _editClef(int bar, PdfInstrument i, int n) async {
    final first = bar == 0 && n == 1;
    final change = await showPdfClefDialog(context,
        title: 'Clef for {name}'.fill({'name': _staffName(i, n)}),
        clef: first ? i.clef : i.clefs[(bar, n)],
        inForce: i.clefAt(bar, n),
        removable: !first && i.clefs.containsKey((bar, n)));
    if (change == null || !mounted) return;
    if (first) {
      if (change.value case final c?) _changedInstrument(i.copyWith(clef: c));
      return;
    }
    final clefs = {...i.clefs}..remove((bar, n));
    if (change.value case final c?) clefs[(bar, n)] = c;
    _changedInstrument(i.copyWith(clefs: clefs));
  }

  /// What can be inserted at bar [bar] of system [system], clicked on its staff [staff]: for every
  /// instrument a tempo, key or time signature, and for the staff's its own time signature or clef.
  List<PopupMenuEntry<VoidCallback>> _insertItems(BuildContext context, int bar, int system, int? staff) {
    final at = _instrumentOf(system, staff);
    return [
      menuItem(context, value: () => _editTempo(bar), child: Text('Insert Tempo…'.tr)),
      menuItem(context, value: () => _editKey(bar, system, staff), child: Text('Insert Key Signature…'.tr)),
      menuItem(context, value: () => _editTime(bar), child: Text('Insert Time Signature…'.tr)),
      if (at case (final i, final n)) ...[
        menuDivider(context),
        menuItem(context,
            value: () => _editLocalTime(bar, i), child: Text('Insert Time Signature for {name}…'.fill({'name': i.name}))),
        menuItem(context, value: () => _editClef(bar, i, n), child: Text('Insert Clef for {name}…'.fill({'name': _staffName(i, n)}))),
      ],
    ];
  }

  /// A right click on a bar: it selected, and what can be inserted there.
  Future<void> _contextMenu(Offset local, Offset global) async {
    if (_step != _Step.changes) return;
    final hit = _selectionAt(_toPage(local));
    if (hit is! _BarSelection) return;
    setState(() => _selection = hit);
    final bars = layout.barOfSegment[hit.system];
    if (hit.segment >= bars.length) return;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(global & const Size(1, 1), Offset.zero & overlay.size),
      items: _insertItems(context, bars[hit.segment], hit.system, hit.staff),
    );
    action?.call();
  }

  /// Every change inserted at bar [bar], for its tag on the page and its row in the panel: what
  /// it says, whose it is (null: every instrument's) and the dialog that changes it.
  List<({String text, PdfInstrument? instrument, int staff, VoidCallback edit})> _changesAt(int bar, int system) {
    final out = <({String text, PdfInstrument? instrument, int staff, VoidCallback edit})>[];
    if (layout.tempos[bar] case final mark?) {
      final speed = bar == 0 ? layout.tempo : mark.bpm;
      out.add((
        text: _tempoText(mark, speed),
        instrument: null,
        staff: 0,
        edit: () => _editTempo(bar),
      ));
    }
    if (bar > 0 && layout.keys.containsKey(bar)) {
      out.add((
        text: 'Key {key}'.fill({'key': pdfKeyName(layout.keys[bar]!)}),
        instrument: null,
        staff: 0,
        edit: () => _editKey(bar, system, null),
      ));
    }
    if (bar > 0 && layout.meters.containsKey(bar)) {
      out.add((text: '${layout.meters[bar]}', instrument: null, staff: 0, edit: () => _editTime(bar)));
    }
    for (final i in layout.instruments) {
      if (i.meters[bar] case final m?) out.add((text: '$m', instrument: i, staff: 1, edit: () => _editLocalTime(bar, i)));
      for (var n = 1; n <= i.staves; n++) {
        if (i.clefs[(bar, n)] case final c?) {
          out.add((text: pdfClefName(c).tr, instrument: i, staff: n, edit: () => _editClef(bar, i, n)));
        }
      }
    }
    return out;
  }

  /// A tempo mark as its tag says it: its words and its speed.
  static String _tempoText(PdfTempo mark, double? speed) =>
      [if (mark.words.isNotEmpty) mark.words, if (speed != null) '♩ = ${_ScoreFieldsState._number(speed)}'].join(' ');

  MouseCursor _cursorAt(Offset local) {
    if (_step != _Step.pages) return SystemMouseCursors.basic;
    if (_tool == _Tool.mask) return SystemMouseCursors.precise;
    return switch (_dragAt(_toPage(local))) {
      _EdgeDrag() => SystemMouseCursors.resizeRow,
      _GapDrag() => SystemMouseCursors.resizeRow,
      _StartDrag() || _BarlineDrag() => SystemMouseCursors.resizeColumn,
      null => SystemMouseCursors.basic,
    };
  }

  Offset _hover = Offset.zero;

  // MARK: Keys

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (_layout == null) return KeyEventResult.ignored;
    final meta = HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final key = event.logicalKey;
    if (meta && key == LogicalKeyboardKey.keyZ) {
      shift ? _redoStep() : _undoStep();
    } else if ((key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) && _step == _Step.pages) {
      _remove();
    } else if (key == LogicalKeyboardKey.pageDown || key == LogicalKeyboardKey.arrowRight) {
      _goTo(_page + 1);
    } else if (key == LogicalKeyboardKey.pageUp || key == LogicalKeyboardKey.arrowLeft) {
      _goTo(_page - 1);
    } else if (key == LogicalKeyboardKey.escape) {
      setState(() => _selection = null);
    } else if (key == LogicalKeyboardKey.keyV && _step == _Step.pages) {
      setState(() => _tool = _Tool.select);
    } else if (key == LogicalKeyboardKey.keyM && _step == _Step.pages) {
      setState(() => _tool = _Tool.mask);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // MARK: Leaving

  /// Measures every system's bars (what plays where), then leaves with the layout.
  Future<void> _done() async {
    if (_layout == null || _measured != null) return;
    final systems = [...layout.systems];
    setState(() => _measured = 0);
    try {
      for (var i = 0; i < systems.length; i++) {
        final s = systems[i];
        if (s.ink == null) {
          final masks = layout.masksOf(s);
          systems[i] = s.copyWith(ink: () => null);
          final ink = await pages.measure(s, masks.all, staffMasks: masks.staves);
          systems[i] = s.copyWith(ink: () => ink);
        }
        if (!mounted) return;
        setState(() => _measured = i + 1);
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    } finally {
      if (mounted) setState(() => _measured = null);
    }
    if (mounted) Navigator.of(context).pop(layout.copyWith(systems: systems));
  }

  Future<void> _cancel() async {
    if (!_edited || widget.layout == null && _layout == null) return Navigator.of(context).pop();
    final discard = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: Text('Discard Your Changes?'.tr),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Keep Editing'.tr)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Discard'.tr)),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
    if (mounted) _focus.requestFocus();
  }

  // MARK: Building

  /// Instrument [index]'s colour on the page.
  static Color _colorOf(int index) => const [
        Color(0xFFE5484D),
        Color(0xFF30A46C),
        Color(0xFF3E63DD),
        Color(0xFFF76B15),
        Color(0xFF8E4EC6),
        Color(0xFF12A594),
        Color(0xFFD6409F),
        Color(0xFFA18072),
        Color(0xFF0090FF),
        Color(0xFF46A758),
      ][index % 10];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _cancel();
      },
      child: Material(
        color: colors.surface,
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _key,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _header(context),
            Divider(height: 1, color: colors.line),
            Expanded(
              child: _layout == null
                  ? _reading(context)
                  : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          _viewBar(context),
                          Divider(height: 1, color: colors.line),
                          Expanded(child: _view(context)),
                        ]),
                      ),
                      VerticalDivider(width: 1, color: colors.line),
                      _panel(context),
                    ]),
            ),
            Divider(height: 1, color: colors.line),
            _footer(context),
          ]),
        ),
      ),
    );
  }

  /// The title, the steps and Cancel.
  Widget _header(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    return Container(
      height: style.toolbar + 16,
      color: colors.chrome,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        Expanded(
          child: Row(children: [
            Text('Import PDF'.tr, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
            const SizedBox(width: 10),
            Flexible(child: Text(widget.name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: colors.textMuted))),
          ]),
        ),
        _StepBar(step: _step, enabled: _layout != null && _measured == null, onPick: _goToStep),
        Expanded(
          child: Align(alignment: Alignment.centerRight, child: OutlinedButton(onPressed: _cancel, child: Text('Cancel'.tr))),
        ),
      ]),
    );
  }

  /// Over the page: Undo, the pages' tools (on their step), zoom and the page showing.
  Widget _viewBar(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    final ready = _measured == null;
    final busy = _measured != null || _rendering.isNotEmpty || _readingText != null;
    return Container(
      height: style.toolbar,
      color: colors.chrome,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        ToolbarButton(icon: AppIcon.undo.of(context), tooltip: 'Undo'.tr, onPressed: ready && _undo.isNotEmpty ? _undoStep : null),
        ToolbarButton(icon: AppIcon.redo.of(context), tooltip: 'Redo'.tr, onPressed: ready && _redo.isNotEmpty ? _redoStep : null),
        if (_step == _Step.pages) ...[
          const ToolbarDivider(),
          ToolGroup(children: [
            ToolbarButton(
                icon: AppIcon.pointer.of(context),
                tooltip: 'Select (V)'.tr,
                selected: _tool == _Tool.select,
                onPressed: ready ? () => setState(() => _tool = _Tool.select) : null),
            ToolbarButton(
                icon: AppIcon.erase.of(context),
                tooltip: 'Mask (M)'.tr,
                selected: _tool == _Tool.mask,
                onPressed: ready ? () => setState(() => _tool = _Tool.mask) : null),
          ]),
        ],
        const ToolbarDivider(),
        ToolbarButton(icon: AppIcon.zoomOut.of(context), tooltip: 'Zoom Out'.tr, onPressed: () => _zoomBy(1 / 1.2)),
        ToolbarButton(icon: AppIcon.zoomIn.of(context), tooltip: 'Zoom In'.tr, onPressed: () => _zoomBy(1.2)),
        const ToolbarDivider(),
        ToolbarButton(
            icon: AppIcon.previous.of(context), tooltip: 'Previous Page'.tr, onPressed: _page > 0 ? () => _goTo(_page - 1) : null),
        SizedBox(
          width: 84,
          child: Text('{n} of {count}'.fill({'n': _page + 1, 'count': pages.length}),
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: colors.text)),
        ),
        ToolbarButton(
            icon: AppIcon.next.of(context),
            tooltip: 'Next Page'.tr,
            onPressed: _page < pages.length - 1 ? () => _goTo(_page + 1) : null),
        const Spacer(),
        if (busy) PulsingDot(color: colors.accent, size: 8),
      ]),
    );
  }

  /// How far the import is, Back and Next (on the last step, Import).
  Widget _footer(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    final ready = _layout != null && _measured == null;
    final last = _step == _Step.review;
    return Container(
      height: style.control + 20,
      color: colors.chrome,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        Expanded(child: Text(_status, style: TextStyle(fontSize: 12, color: colors.textMuted), overflow: TextOverflow.ellipsis)),
        if (_step.index > 0) ...[
          OutlinedButton(onPressed: ready ? () => _goToStep(_Step.values[_step.index - 1]) : null, child: Text('Back'.tr)),
          const SizedBox(width: 8),
        ],
        FilledButton(
          onPressed: !ready
              ? null
              : last
                  ? (layout.systems.isNotEmpty ? _done : null)
                  : () => _goToStep(_Step.values[_step.index + 1]),
          child: Text((last ? (widget.layout == null ? 'Import' : 'Done') : 'Next').tr),
        ),
      ]),
    );
  }

  String get _status {
    if (_error case final error? when _layout != null) return 'Couldn’t measure the bars. {error}'.fill({'error': error});
    if (_measured case final n?) {
      return 'Measuring system {n} of {count}…'.fill({'n': math.min(n + 1, layout.systems.length), 'count': layout.systems.length});
    }
    if (_layout == null) return '';
    return '{bars} bars · {systems} systems'.fill({'bars': layout.bars.length, 'systems': layout.systems.length});
  }

  Widget _reading(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_error == null) ...[
          SizedBox(
            width: 240,
            child: LinearProgressIndicator(value: pages.length == 0 ? null : (_read ?? 0) / pages.length),
          ),
          const SizedBox(height: 12),
          Text('Reading page {n} of {count}…'.fill({'n': math.min((_read ?? 0) + 1, pages.length), 'count': pages.length}),
              style: TextStyle(fontSize: 13, color: colors.textMuted)),
        ] else
          Text('Couldn’t read the PDF. {error}'.fill({'error': _error!}), style: TextStyle(fontSize: 13, color: colors.text)),
      ]),
    );
  }

  Widget _view(BuildContext context) {
    final size = pages.sizes[_page];
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final image = _imageOf(_page, dpr);
    final width = _gutter + size.width * _zoom + _margin * 2 + 24, height = size.height * _zoom + _margin * 2;
    final chips = <Widget>[
      if (_step != _Step.pages)
        for (final (i, s) in _onPage)
          for (final (k, staff) in s.staves.indexed)
          Positioned(
            left: 8,
            width: _gutter - 16,
            top: _margin + staff.middle * _zoom - 12,
            height: 24,
            child: _StaffChip(
              layout: layout,
              staff: staff,
              onChanged: (part, number) {
                final staves = [...s.staves];
                staves[k] = staff.copyWith(part: () => part, staff: number);
                _setSystem(i, s.copyWith(staves: staves));
              },
              onRename: () => _renameInstrument(staff.part),
              onNew: () => _newInstrumentFor(i, k),
            ),
          ),
    ];
    // The changes inserted, at the start of their bars: every instrument's above the system, a
    // staff's own above it.
    final tags = <Widget>[];
    final suggested = _step == _Step.changes ? _suggested : const <int, PdfTempo>{};
    for (final (bar, pieces) in layout.bars.indexed) {
      if (_step != _Step.changes && _step != _Step.review) break;
      final piece = pieces.first, s = layout.systems[piece.system];
      if (s.page != _page) continue;
      final changes = _changesAt(bar, piece.system), idea = suggested[bar];
      if (changes.isEmpty && idea == null) continue;
      Widget row(double y, Iterable<Widget> children) =>
          Positioned(left: _gutter + piece.left * _zoom + 2, top: _margin + y * _zoom - 19, child: Row(mainAxisSize: MainAxisSize.min, children: [...children]));
      final all = [
        for (final c in changes)
          if (c.instrument == null) _ChangeTag(text: c.text, color: const Color(0xFF3E63DD), onTap: c.edit),
        if (idea != null) _SuggestedTag(text: _tempoText(idea, idea.bpm), onAccept: () => _accept({bar: idea}), onTap: () => _showBar(bar)),
      ];
      if (all.isNotEmpty) tags.add(row(s.top, all));
      for (final staff in s.staves) {
        final i = layout.instrument(staff.part), n = layout.staffInPart(staff);
        if (i == null || staff.staff > 1 && i.staves == 1) continue; // a division's: the section's
        final own = [
          for (final c in changes)
            if (c.instrument?.id == i.id && c.staff == n)
              _ChangeTag(text: c.text, color: _colorOf(layout.instruments.indexOf(i)), onTap: c.edit),
        ];
        if (own.isNotEmpty) tags.add(row(staff.top - 2, own));
      }
    }
    return ColoredBox(
      color: context.colors.surface,
      child: Scrollbar(
        controller: _vertical,
        child: SingleChildScrollView(
          controller: _vertical,
          child: Scrollbar(
            controller: _horizontal,
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                height: height,
                child: Stack(children: [
                  Positioned.fill(
                    child: MouseRegion(
                      cursor: _drag != null ? MouseCursor.defer : _cursorAt(_hover),
                      onHover: (e) => setState(() => _hover = e.localPosition),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanDown: (d) => _down(d.localPosition),
                        onPanUpdate: (d) => _move(d.localPosition),
                        onPanEnd: (_) => _up(),
                        onPanCancel: _up,
                        onDoubleTapDown: _tool == _Tool.select && _step == _Step.pages ? (d) => _doubleClick(d.localPosition) : null,
                        onSecondaryTapUp: (d) => _contextMenu(d.localPosition, d.globalPosition),
                        onDoubleTap: _tool == _Tool.select && _step == _Step.pages ? () {} : null,
                        child: CustomPaint(
                          painter: _PagePainter(
                            layout: layout,
                            page: _page,
                            image: image,
                            zoom: _zoom,
                            selection: _selection,
                            drawing: _drawing,
                            colors: context.colors,
                            colorOf: (id) => _colorOf(layout.instruments.indexWhere((i) => i.id == id)),
                            editing: _step == _Step.pages,
                            focus: (_step == _Step.instruments || _step == _Step.staves) && _instrument < layout.instruments.length
                                ? layout.instruments[_instrument].id
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                  ...chips,
                  ...tags,
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The step's own fields, at the right.
  Widget _panel(BuildContext context) {
    final colors = context.colors;
    final picked = _instrument < layout.instruments.length ? layout.instruments[_instrument] : null;
    return Container(
      width: 300,
      color: colors.chrome,
      child: ListView(padding: const EdgeInsets.all(16), children: switch (_step) {
        _Step.pages => _selectionFields(context),
        _Step.instruments => [
            _heading(context, 'Instruments'),
            _instrumentList(context, adding: true),
            const SizedBox(height: 14),
            OutlinedButton(onPressed: _text.isEmpty ? null : () => _nameFromText(), child: Text('Read Names from Score'.tr)),
            ?_textStatus(context, found: _text.values.any((r) => r.isNotEmpty)),
            if (picked != null) ...[
              const SizedBox(height: 20),
              _InstrumentFields(
                key: ValueKey((picked.id, _rev)),
                instrument: picked,
                onChanged: (next, field) =>
                    _edit(layout.copyWith(instruments: [...layout.instruments]..[_instrument] = next), typing: '${next.id}.$field'),
              ),
            ],
          ],
        _Step.staves => [
            _heading(context, 'Staves'),
            Text(
                _unassigned == 0
                    ? 'Every staff has an instrument'.tr
                    : '{n} staves without an instrument'.fill({'n': _unassigned}),
                style: TextStyle(fontSize: 13, color: _unassigned == 0 ? colors.textMuted : colors.text)),
            if (_unassigned > 0) ...[
              const SizedBox(height: 10),
              OutlinedButton(onPressed: _showUnassigned, child: Text('Show Next'.tr)),
            ],
            const SizedBox(height: 20),
            _heading(context, 'Instruments'),
            _instrumentList(context, adding: false),
          ],
        _Step.changes => [..._selectionFields(context), ..._suggestionFields(context)],
        _Step.review => [
            _heading(context, 'Score'),
            _ScoreFields(key: ValueKey(_rev), layout: layout, onChanged: (next, field) => _edit(next, typing: field)),
            const SizedBox(height: 24),
            _heading(context, 'Summary'),
            ..._summary(context),
          ],
      }),
    );
  }

  /// Whether the pages' words are still being read, or none were found ([found] false); null
  /// once they are read and some were.
  Widget? _textStatus(BuildContext context, {required bool found}) {
    final colors = context.colors;
    if (_readingText == null && found) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        if (_readingText != null) ...[PulsingDot(color: colors.accent, size: 7), const SizedBox(width: 8)],
        Expanded(
          child: Text(
              _readingText != null
                  ? 'Reading text… {n} of {count}'.fill({'n': math.min(_text.length + 1, pages.length), 'count': pages.length})
                  : 'No text found'.tr,
              style: TextStyle(fontSize: 12, color: colors.textMuted)),
        ),
      ]),
    );
  }

  /// The tempo marks read off the pages, each added or dismissed; all added at once.
  List<Widget> _suggestionFields(BuildContext context) {
    final ideas = _suggested.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return [
      const SizedBox(height: 10),
      _heading(context, 'Read from Score'),
      ?_textStatus(context, found: ideas.isNotEmpty),
      if (ideas.isNotEmpty) const SizedBox(height: 4),
      for (final MapEntry(key: bar, value: mark) in ideas)
        _SuggestionRow(
          text: _tempoText(mark, mark.bpm),
          where: _barName(bar),
          onTap: () => _showBar(bar),
          onAccept: () => _accept({bar: mark}),
          onDismiss: () => setState(() => _dismissed.add(bar)),
        ),
      if (ideas.length > 1) ...[
        const SizedBox(height: 4),
        FilledButton(onPressed: () => _accept(Map.fromEntries(ideas)), child: Text('Add All'.tr)),
      ],
    ];
  }

  /// What will be imported.
  List<Widget> _summary(BuildContext context) {
    final colors = context.colors;
    Widget row(String label, int value, {bool warn = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            Expanded(child: Text(label.tr, style: TextStyle(fontSize: 13, color: colors.textMuted))),
            Text('$value', style: TextStyle(fontSize: 13, color: warn && value > 0 ? colors.erase : colors.text)),
          ]),
        );
    return [
      row('Bars', layout.bars.length),
      row('Systems', layout.systems.length),
      row('Instruments', layout.instruments.where((i) => !i.blank).length),
      row('Blank Lanes', layout.instruments.where((i) => i.blank).length),
      row('Tempo Marks', layout.tempos.length),
      row('Staves without an instrument', _unassigned, warn: true),
    ];
  }

  Widget _heading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text.tr, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.colors.text)),
      );

  /// The instruments, in the score's order: each dragged by its handle to its place, renamed with
  /// a double click; with [adding], tiles that add an instrument or a blank lane.
  Widget _instrumentList(BuildContext context, {required bool adding}) {
    final colors = context.colors;
    final instruments = layout.instruments;
    // Instrument [from] put at [to] (counted with it taken out), the selection going with it.
    void place(int from, int to) {
      if (from == to || from < 0 || from >= instruments.length) return;
      final list = [...instruments];
      list.insert(to, list.removeAt(from));
      final picked = _instrument < instruments.length ? instruments[_instrument].id : null;
      _edit(layout.copyWith(instruments: list));
      setState(() => _instrument = math.max(0, list.indexWhere((i) => i.id == picked)));
    }

    String nextId() {
      final ids = {for (final i in instruments) i.id};
      var n = instruments.length + 1;
      while (ids.contains('P$n')) {
        n++;
      }
      return 'P$n';
    }

    void add() {
      final id = nextId();
      _edit(layout.copyWith(instruments: [...instruments, PdfInstrument(id: id, name: 'Staff {n}'.fill({'n': id.substring(1)}))]));
      setState(() => _instrument = instruments.length);
    }

    // A blank lane, below the instrument selected.
    void addBlank() {
      final at = instruments.isEmpty ? 0 : math.min(_instrument + 1, instruments.length);
      _edit(layout.copyWith(instruments: [...instruments]..insert(at, PdfInstrument.blank(id: nextId(), name: 'Blank'.tr))));
      setState(() => _instrument = at);
    }

    void remove(int index) {
      if (index >= instruments.length) return;
      final id = instruments[index].id;
      final lanes = {for (final p in instruments[index].players) p.id};
      _edit(layout.copyWith(
        instruments: [...instruments]..removeAt(index),
        masks: [for (final m in layout.masks) if (m.part == null || !lanes.contains(m.part)) m],
        systems: [
          for (final s in layout.systems)
            s.staves.any((t) => t.part == id)
                ? s.copyWith(staves: [for (final t in s.staves) t.part == id ? t.copyWith(part: () => null) : t])
                : s,
        ],
      ));
      setState(() => _instrument = math.max(0, math.min(_instrument, instruments.length - 2)));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        itemCount: instruments.length,
        onReorderItem: place,
        proxyDecorator: (child, _, _) => Material(
          color: colors.surface,
          elevation: 3,
          borderRadius: AppStyle.of(context).radius(5),
          child: child,
        ),
        itemBuilder: (context, i) => _InstrumentRow(
          key: ValueKey(instruments[i].id),
          index: i,
          instrument: instruments[i],
          color: _colorOf(i),
          selected: i == _instrument,
          onSelect: () => setState(() => _instrument = i),
          onRename: () => _renameInstrument(instruments[i].id),
          menu: (context) => [
            menuItem<VoidCallback>(context, value: () => _renameInstrument(instruments[i].id), child: Text('Rename…'.tr)),
            menuDivider(context),
            menuItem<VoidCallback>(context, value: () => place(i, i - 1), enabled: i > 0, child: Text('Move Up'.tr)),
            menuItem<VoidCallback>(context,
                value: () => place(i, i + 1), enabled: i < instruments.length - 1, child: Text('Move Down'.tr)),
            menuDivider(context),
            menuItem<VoidCallback>(context, value: () => remove(i), child: Text('Remove'.tr)),
          ],
        ),
      ),
      if (adding) ...[
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _AddTile(icon: AppIcon.add, label: 'Instrument', onTap: add)),
          const SizedBox(width: 8),
          Expanded(child: _AddTile(icon: AppIcon.verticalSpacer, label: 'Blank Lane', onTap: addBlank)),
        ]),
      ],
    ]);
  }

  /// What the selection is, and what can be done to it.
  List<Widget> _selectionFields(BuildContext context) {
    final selection = _selection;
    final pageButtons = _step != _Step.pages
        ? const SizedBox.shrink()
        : Row(children: [
            Expanded(child: OutlinedButton(onPressed: _detectAgain, child: Text('Detect Page Again'.tr))),
          ]);
    final out = <Widget>[];
    switch (selection) {
      case _BarlineSelection(:final system, :final barline):
        final s = layout.systems[system];
        out.addAll([
          _heading(context, 'Barline'),
          AppDropdown<PdfBarlineKind>(
            value: s.barlines[barline].kind,
            isExpanded: true,
            label: 'Kind',
            items: [for (final k in PdfBarlineKind.values) DropdownMenuItem(value: k, child: Text(_kindName(k).tr))],
            onChanged: (k) {
              if (k == null) return;
              final lines = [...s.barlines];
              lines[barline] = PdfBarline(lines[barline].x, k);
              _setSystem(system, s.copyWith(barlines: lines));
            },
          ),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: _remove, child: Text('Remove Barline'.tr)),
        ]);
      case _BarSelection(:final system, :final segment):
        final bars = layout.barOfSegment[system];
        final bar = segment < bars.length ? bars[segment] : null;
        out.addAll([
          _heading(context, bar == null ? 'System' : _barName(bar)),
          if (bar != null && _step == _Step.changes) ...[
            for (final change in _changesAt(bar, system))
              _ChangeRow(
                text: change.text,
                whose: switch (change.instrument) { final i? => _staffName(i, change.staff), null => null },
                color: change.instrument == null ? null : _colorOf(layout.instruments.indexOf(change.instrument!)),
                onTap: change.edit,
              ),
            AppPopupMenuButton<VoidCallback>(
              tooltip: 'Insert',
              padding: EdgeInsets.zero,
              itemBuilder: (context) => _insertItems(context, bar, system, selection.staff),
              onSelected: (action) => action(),
              child: IgnorePointer(child: OutlinedButton(onPressed: () {}, child: Text('Insert'.tr))),
            ),
            const SizedBox(height: 10),
          ],
          if (_step == _Step.pages) OutlinedButton(onPressed: _remove, child: Text('Remove System'.tr)),
        ]);
      case _MaskSelection(:final mask):
        final m = layout.masks[mask];
        final lanes = [
          for (final i in layout.instruments)
            if (!i.blank)
              for (final p in i.players) (id: p.id, name: p.name),
        ];
        out.addAll([
          _heading(context, 'Mask'),
          AppDropdown<String?>(
            value: lanes.any((l) => l.id == m.part) ? m.part : null,
            isExpanded: true,
            label: 'Lane',
            items: [
              DropdownMenuItem(value: null, child: Text('All Lanes'.tr)),
              for (final l in lanes) DropdownMenuItem(value: l.id, child: Text(l.name)),
            ],
            onChanged: (part) => _setMasks([...layout.masks]..[mask] = m.withPart(part)),
          ),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: _remove, child: Text('Remove Mask'.tr)),
        ]);
      case _GapSelection():
        out.addAll([
          _heading(context, 'Gap'),
          OutlinedButton(onPressed: _remove, child: Text('Remove Gap'.tr)),
        ]);
      case null when _step == _Step.changes:
        out.addAll([
          _heading(context, 'Bar'),
          Text('Select a bar'.tr, style: TextStyle(fontSize: 13, color: context.colors.textMuted)),
        ]);
      case null:
        break;
    }
    return [
      ...out,
      if (out.isNotEmpty) const SizedBox(height: 10),
      pageButtons,
      const SizedBox(height: 20),
    ];
  }

  static String _kindName(PdfBarlineKind k) => switch (k) {
        PdfBarlineKind.normal => 'Single',
        PdfBarlineKind.double => 'Double',
        PdfBarlineKind.end => 'Final',
        PdfBarlineKind.repeatStart => 'Start Repeat',
        PdfBarlineKind.repeatEnd => 'End Repeat',
        PdfBarlineKind.repeatBoth => 'End and Start Repeat',
      };
}

/// A row of the panel's instruments: its handle (dragged to move it), its colour, its name. A
/// click picks it for the fields below, a double click renames it.
class _InstrumentRow extends StatefulWidget {
  const _InstrumentRow({
    super.key,
    required this.index,
    required this.instrument,
    required this.color,
    required this.selected,
    required this.onSelect,
    required this.onRename,
    required this.menu,
  });
  final int index;
  final PdfInstrument instrument;
  final Color color;
  final bool selected;
  final VoidCallback onSelect, onRename;

  /// Its ⋯ menu: rename, move, remove.
  final PopupMenuItemBuilder<VoidCallback> menu;

  @override
  State<_InstrumentRow> createState() => _InstrumentRowState();
}

class _InstrumentRowState extends State<_InstrumentRow> {
  final _clicks = DoubleClicks();
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, i = widget.instrument;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons != kPrimaryButton) return;
          _clicks.press(e.timeStamp, e.position) ? widget.onRename() : widget.onSelect();
        },
        child: Container(
          height: 32,
          padding: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
            color: widget.selected ? colors.accentWash : (_hovered ? colors.accentWash.withValues(alpha: 0.5) : null),
            borderRadius: AppStyle.of(context).radius(5),
          ),
          child: Row(children: [
            ReorderableDragStartListener(
              index: widget.index,
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: SizedBox(
                  width: 24,
                  height: 32,
                  child: Icon(AppIcon.grab.of(context), size: 14, color: _hovered || widget.selected ? colors.textMuted : colors.line),
                ),
              ),
            ),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: i.blank ? null : widget.color,
                border: i.blank ? Border.all(color: colors.textMuted) : null,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(i.name,
                  overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: i.blank ? colors.textMuted : colors.text)),
            ),
            if (i.staves > 1 || i.divisi > 1)
              Text('×{n}'.fill({'n': i.staves > 1 ? i.staves : i.divisi}), style: TextStyle(fontSize: 12, color: colors.textMuted)),
            Opacity(
              opacity: _hovered || widget.selected ? 1 : 0,
              child: AppPopupMenuButton<VoidCallback>(
                tooltip: 'More'.tr,
                padding: EdgeInsets.zero,
                iconSize: 16,
                icon: Icon(AppIcon.more.of(context), color: colors.textMuted),
                itemBuilder: widget.menu,
                onSelected: (action) => action(),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A staff's instrument, at its left: a chip in the instrument's colour. A click opens what it
/// can be (another instrument, or none: left out of the score), a double click renames its
/// instrument (no one's: makes it a new one).
class _StaffChip extends StatelessWidget {
  const _StaffChip(
      {required this.layout, required this.staff, required this.onChanged, required this.onRename, required this.onNew});
  final PdfScoreLayout layout;
  final PdfStaff staff;
  final void Function(String? part, int staff) onChanged;

  /// Its instrument renamed, or a new one made for it.
  final VoidCallback onRename, onNew;

  Future<void> _open(BuildContext context, PdfInstrument? instrument) async {
    final box = context.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final at = Rect.fromPoints(box.localToGlobal(box.size.bottomLeft(Offset.zero), ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay));
    final style = AppStyle.of(context);
    final picked = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromRect(at, Offset.zero & overlay.size),
      popUpAnimationStyle: AnimationStyle(
          duration: style.menuOpen, reverseDuration: style.menuClose, curve: style.enterCurve, reverseCurve: style.exitCurve),
      items: [
        if (instrument != null)
          menuItem<Object>(context, value: onRename, child: Text('Rename {name}…'.fill({'name': instrument.name}))),
        menuItem<Object>(context, value: onNew, child: Text('New Instrument…'.tr)),
        menuDivider(context),
        // A piano's staves, or a section's divisi (a blank lane holds none).
        for (final i in layout.instruments)
          if (!i.blank)
            for (var n = 1; n <= (i.staves > 1 ? i.staves : i.divisi); n++)
              checkedMenuItem<Object>(context,
                  value: (i.id, n),
                  checked: staff.part == i.id && staff.staff == n,
                  child: Text(i.staves > 1 || i.divisi > 1 ? '${i.name} $n' : i.name)),
        menuDivider(context),
        checkedMenuItem<Object>(context, value: (null, 1), checked: staff.part == null, child: Text('None'.tr)),
      ],
    );
    switch (picked) {
      case (final String? part, final int n):
        onChanged(part, n);
      case final VoidCallback action:
        action();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final index = layout.instruments.indexWhere((i) => i.id == staff.part);
    final instrument = index < 0 ? null : layout.instruments[index];
    final color = index < 0 ? colors.textMuted : _PdfImportState._colorOf(index);
    final label = instrument == null
        ? 'None'.tr
        : '${instrument.abbreviation.isNotEmpty ? instrument.abbreviation : instrument.name}${instrument.staves > 1 || staff.staff > 1 ? ' ${staff.staff}' : ''}';
    // A click waits a moment for a second (a double click renames), then opens the menu.
    return Tip(
      message: 'Instrument'.tr,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _open(context, instrument),
          onDoubleTap: instrument != null ? onRename : onNew,
          child: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              border: Border.all(color: color.withValues(alpha: 0.7)),
              borderRadius: AppStyle.of(context).radius(6),
            ),
            child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: colors.text)),
          ),
        ),
      ),
    );
  }
}

/// The import's steps across the top: each numbered (a tick once passed), the one showing
/// filled; a click goes to any.
class _StepBar extends StatelessWidget {
  const _StepBar({required this.step, required this.enabled, required this.onPick});
  final _Step step;
  final bool enabled;
  final ValueChanged<_Step> onPick;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    final children = <Widget>[];
    for (final s in _Step.values) {
      if (s.index > 0) {
        children.add(Container(width: 18, height: 1, margin: const EdgeInsets.symmetric(horizontal: 4), color: colors.line));
      }
      final current = s == step, passed = s.index < step.index;
      final tone = current ? colors.accent : (passed ? colors.text : colors.textMuted);
      children.add(MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          onTap: enabled ? () => onPick(s) : null,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(color: current ? colors.accentWash : null, borderRadius: style.radius(14)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 18,
                height: 18,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: current ? colors.accent : null,
                  border: current ? null : Border.all(color: tone),
                  shape: BoxShape.circle,
                ),
                child: passed
                    ? Icon(AppIcon.check.of(context), size: 12, color: tone)
                    : Text('${s.index + 1}',
                        style: TextStyle(
                            fontSize: 11, height: 1, fontWeight: FontWeight.w600, color: current ? const Color(0xFFFFFFFF) : tone)),
              ),
              const SizedBox(width: 6),
              Text(s.label.tr,
                  style: TextStyle(fontSize: 13, fontWeight: current ? FontWeight.w600 : FontWeight.w400, color: tone)),
            ]),
          ),
        ),
      ));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}

/// A tile that adds to the instruments: dashed, in the accent, under the list.
class _AddTile extends StatefulWidget {
  const _AddTile({required this.icon, required this.label, required this.onTap});
  final AppIcon icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_AddTile> createState() => _AddTileState();
}

class _AddTileState extends State<_AddTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: CustomPaint(
          painter: _DashedBorder(color: colors.accent.withValues(alpha: _hovered ? 0.9 : 0.55), radius: 7),
          child: AnimatedContainer(
            duration: motion(context, 120),
            height: 40,
            decoration: BoxDecoration(color: _hovered ? colors.accentWash : colors.accentWash.withValues(alpha: 0.4), borderRadius: style.radius(7)),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(widget.icon.of(context), size: 16, color: colors.accent),
              const SizedBox(width: 6),
              Flexible(
                child: Text(widget.label.tr,
                    overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: colors.accent)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder({required this.color, required this.radius});
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()..addRRect(RRect.fromRectAndRadius((Offset.zero & size).deflate(0.6), Radius.circular(radius)));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 8) {
        canvas.drawPath(metric.extractPath(d, math.min(d + 4, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color || old.radius != radius;
}

/// A tempo mark read off the page, on it at its bar: outlined, not yet the score's; a click
/// on its tick adds it.
class _SuggestedTag extends StatelessWidget {
  const _SuggestedTag({required this.text, required this.onAccept, required this.onTap});
  final String text;
  final VoidCallback onAccept, onTap;

  @override
  Widget build(BuildContext context) {
    const blue = Color(0xFF3E63DD);
    return Padding(
      padding: const EdgeInsets.only(right: 3),
      child: Container(
        height: 16,
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF),
          border: Border.all(color: blue.withValues(alpha: 0.8)),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Text(text, style: const TextStyle(fontSize: 10.5, height: 1, color: blue, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
          Tip(
            message: 'Add'.tr,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: onAccept,
                child: Container(
                  width: 16,
                  alignment: Alignment.center,
                  color: blue,
                  child: Icon(AppIcon.check.of(context), size: 11, color: const Color(0xFFFFFFFF)),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// A tempo mark read off the page, in the panel: where it is (a click shows it), added or
/// dismissed.
class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow(
      {required this.text, required this.where, required this.onTap, required this.onAccept, required this.onDismiss});
  final String text, where;
  final VoidCallback onTap, onAccept, onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.only(left: 10),
        decoration: BoxDecoration(border: Border.all(color: colors.line), borderRadius: style.radius(6)),
        child: Row(children: [
          Expanded(
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(text, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: colors.text)),
                  Text(where, style: TextStyle(fontSize: 11.5, color: colors.textMuted)),
                ]),
              ),
            ),
          ),
          ToolbarButton(icon: AppIcon.check.of(context), tooltip: 'Add'.tr, onPressed: onAccept),
          ToolbarButton(icon: AppIcon.close.of(context), tooltip: 'Dismiss'.tr, onPressed: onDismiss),
        ]),
      ),
    );
  }
}

/// The score's title, meter, key, upbeat and tempo.
class _ScoreFields extends StatefulWidget {
  const _ScoreFields({super.key, required this.layout, required this.onChanged});
  final PdfScoreLayout layout;
  final void Function(PdfScoreLayout next, String field) onChanged;

  @override
  State<_ScoreFields> createState() => _ScoreFieldsState();
}

class _ScoreFieldsState extends State<_ScoreFields> {
  late final _title = TextEditingController(text: widget.layout.title);
  late final _meter = TextEditingController(text: widget.layout.meter.toString());
  late final _pickup = TextEditingController(text: _number(widget.layout.pickup));
  late final _tempo = TextEditingController(text: _number(widget.layout.tempo));
  bool _badMeter = false;

  static String _number(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

  @override
  void dispose() {
    _title.dispose();
    _meter.dispose();
    _pickup.dispose();
    _tempo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layout = widget.layout;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppTextField(controller: _title, label: 'Title', onChanged: (v) => widget.onChanged(layout.copyWith(title: v), 'title')),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: AppTextField(
            controller: _meter,
            label: 'Time',
            bad: _badMeter,
            onChanged: (v) {
              final meter = PdfMeter.parse(v);
              setState(() => _badMeter = meter == null);
              if (meter != null) widget.onChanged(layout.copyWith(meter: meter), 'meter');
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: _KeyField(value: layout.fifths, onChanged: (f) => widget.onChanged(layout.copyWith(fifths: f), 'key'))),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: AppTextField(
            controller: _pickup,
            label: 'Upbeat (beats)',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (v) {
              final n = double.tryParse(v.trim().isEmpty ? '0' : v);
              if (n != null && n >= 0 && n < 64) widget.onChanged(layout.copyWith(pickup: n), 'pickup');
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: AppTextField(
            controller: _tempo,
            label: 'Tempo',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (v) {
              final n = double.tryParse(v);
              if (n != null && n >= 10 && n <= 400) widget.onChanged(layout.copyWith(tempo: n), 'tempo');
            },
          ),
        ),
      ]),
    ]);
  }
}

/// A key signature, by its major key (a concert key).
class _KeyField extends StatelessWidget {
  const _KeyField({required this.value, required this.onChanged});
  final int? value;
  final ValueChanged<int?> onChanged;

  static const _names = ['C♭', 'G♭', 'D♭', 'A♭', 'E♭', 'B♭', 'F', 'C', 'G', 'D', 'A', 'E', 'B', 'F♯', 'C♯'];

  @override
  Widget build(BuildContext context) => AppDropdown<int?>(
        value: value,
        isExpanded: true,
        label: 'Key',
        items: [
          for (var f = -7; f <= 7; f++) DropdownMenuItem(value: f, child: Text(_names[f + 7])),
        ],
        onChanged: (f) => onChanged(f),
      );
}

/// A change inserted at a bar, in the panel: what it says and whose (null: every instrument's),
/// in its instrument's colour; a click changes it.
class _ChangeRow extends StatelessWidget {
  const _ChangeRow({required this.text, required this.whose, required this.color, required this.onTap});
  final String text;
  final String? whose;
  final Color? color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: AppStyle.of(context).radius(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: (color ?? colors.textMuted).withValues(alpha: 0.6)),
            borderRadius: AppStyle.of(context).radius(6),
          ),
          child: Row(children: [
            Expanded(child: Text(text, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: colors.text))),
            const SizedBox(width: 8),
            Text(whose ?? 'All'.tr, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: colors.textMuted)),
          ]),
        ),
      ),
    );
  }
}

/// A change's tag on the page, at the start of its bar: a click changes it.
class _ChangeTag extends StatelessWidget {
  const _ChangeTag({required this.text, required this.color, required this.onTap});
  final String text;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 3),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              height: 16,
              padding: const EdgeInsets.symmetric(horizontal: 5),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
              child: Text(text, style: const TextStyle(fontSize: 10.5, height: 1, color: Color(0xFFFFFFFF), fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      );
}

/// An instrument's name, abbreviation, clef, staves and transposition.
class _InstrumentFields extends StatefulWidget {
  const _InstrumentFields({super.key, required this.instrument, required this.onChanged});
  final PdfInstrument instrument;
  final void Function(PdfInstrument next, String field) onChanged;

  @override
  State<_InstrumentFields> createState() => _InstrumentFieldsState();
}

class _InstrumentFieldsState extends State<_InstrumentFields> {
  late final _name = TextEditingController(text: widget.instrument.name);
  late final _abbreviation = TextEditingController(text: widget.instrument.abbreviation);

  @override
  void dispose() {
    _name.dispose();
    _abbreviation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.instrument;
    final name = AppTextField(
        controller: _name,
        label: 'Name',
        onChanged: (v) {
          if (v.trim().isNotEmpty) widget.onChanged(i.blank ? i.copyWith(name: v) : i.renamed(v), 'name');
        });
    if (i.blank) return name; // a blank lane is only named
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      name,
      const SizedBox(height: 12),
      AppTextField(
          controller: _abbreviation, label: 'Abbreviation', onChanged: (v) => widget.onChanged(i.copyWith(abbreviation: v), 'abbreviation')),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: AppDropdown<PdfClef>(
            value: i.clef,
            isExpanded: true,
            label: 'Clef',
            items: [for (final c in PdfClef.values) DropdownMenuItem(value: c, child: Text(pdfClefName(c).tr))],
            onChanged: (c) => widget.onChanged(i.copyWith(clef: c), 'clef'),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 80,
          child: AppDropdown<int>(
            value: i.staves,
            isExpanded: true,
            label: 'Staves',
            items: [for (final n in [1, 2]) DropdownMenuItem(value: n, child: Text('$n'))],
            onChanged: (n) => widget.onChanged(i.copyWith(staves: n), 'staves'),
          ),
        ),
        if (i.staves == 1) ...[
          const SizedBox(width: 12),
          SizedBox(
            width: 80,
            child: AppDropdown<int>(
              value: i.divisi,
              isExpanded: true,
              label: 'Divisi',
              items: [for (final n in [1, 2, 3, 4]) DropdownMenuItem(value: n, child: Text(n == 1 ? '—' : '$n'))],
              onChanged: (n) => widget.onChanged(i.copyWith(divisi: n), 'divisi'),
            ),
          ),
        ],
      ]),
      const SizedBox(height: 12),
      AppDropdown<SpacerKey>(
        value: i.key,
        isExpanded: true,
        label: 'Transposition',
        items: [
          for (final k in SpacerKey.values) DropdownMenuItem(value: k, child: Text(k == SpacerKey.c ? 'None'.tr : 'in {key}'.fill({'key': k.label}))),
        ],
        onChanged: (k) => widget.onChanged(i.copyWith(key: k), 'key'),
      ),
    ]);
  }
}

/// A page with what was found on it: the systems (dashed), the cuts between their staves with
/// handles at the right (a gap's two edges, hatched between), each staff's band in its
/// instrument's colour, the barlines, where the music starts, and the masks.
class _PagePainter extends CustomPainter {
  _PagePainter({
    required this.layout,
    required this.page,
    required this.image,
    required this.zoom,
    required this.selection,
    required this.drawing,
    required this.colors,
    required this.colorOf,
    required this.editing,
    required this.focus,
  });

  /// Whether what was found can be moved here (the pages' step): its edges' handles, where the
  /// music starts and the barlines drawn to be grabbed.
  final bool editing;

  /// The instrument picked, its staves tinted the more.
  final String? focus;

  final PdfScoreLayout layout;
  final int page;
  final ui.Image? image;
  final double zoom;
  final _Selection? selection;
  final Rect? drawing;
  final AppColors colors;
  final Color Function(String? id) colorOf;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(_PdfImportState._gutter, _PdfImportState._margin);
    final pageSize = layout.pages[page];
    final paper = Offset.zero & (pageSize * zoom);
    canvas.drawRect(paper.shift(const Offset(0, 2)), Paint()..color = const Color(0x22000000));
    canvas.drawRect(paper, Paint()..color = const Color(0xFFFFFFFF));
    if (image case final image?) {
      canvas.drawImageRect(image, Offset.zero & Size(image.width.toDouble(), image.height.toDouble()), paper,
          Paint()..filterQuality = FilterQuality.medium);
    }
    canvas.scale(zoom);
    final px = 1 / zoom;
    for (final (i, s) in layout.systems.indexed) {
      if (s.page != page) continue;
      _system(canvas, i, s, px);
    }
    for (final (i, m) in layout.masks.indexed) {
      if (m.page != page) continue;
      final selected = selection is _MaskSelection && (selection as _MaskSelection).mask == i;
      final lane = switch (m.part) { final p? => layout.playerOf(p)?.$1.id, null => null };
      _mask(canvas, m.rect, px, selected: selected, lane: lane == null ? null : colorOf(lane));
    }
    if (drawing case final rect?) _mask(canvas, rect, px, selected: true);
  }

  /// A mask: grey, or one lane's tinted in its instrument's colour.
  void _mask(Canvas canvas, Rect rect, double px, {required bool selected, Color? lane}) {
    canvas.drawRect(rect, Paint()..color = lane == null ? const Color(0xCCB0B0B0) : Color.alphaBlend(lane.withValues(alpha: 0.35), const Color(0xCCB0B0B0)));
    canvas.save();
    canvas.clipRect(rect);
    final hatch = Paint()
      ..color = const Color(0x55000000)
      ..strokeWidth = px;
    for (var x = rect.left - rect.height; x < rect.right; x += 6 * px) {
      canvas.drawLine(Offset(x, rect.bottom), Offset(x + rect.height, rect.top), hatch);
    }
    canvas.restore();
    canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (selected ? 2 : 1) * px
          ..color = selected ? colors.accent : lane ?? const Color(0xFF707070));
  }

  void _system(Canvas canvas, int index, PdfSystem s, double px) {
    final selectedSystem = switch (selection) {
      _BarSelection(:final system) || _BarlineSelection(:final system) || _GapSelection(:final system) => system == index,
      _ => false,
    };
    // Each staff's band, tinted in its instrument's colour (grey: no one's).
    for (var k = 0; k < s.staves.length; k++) {
      final (top, bottom) = s.bandOf(k);
      final staff = s.staves[k];
      final color = staff.part == null ? const Color(0xFF9E9E9E) : colorOf(staff.part);
      final tint = focus == null ? 0.06 : (staff.part == focus ? 0.2 : 0.03);
      canvas.drawRect(Rect.fromLTRB(s.left, top, s.right, bottom), Paint()..color = color.withValues(alpha: tint));
      canvas.drawLine(Offset(s.left, staff.bottom + 1.5 * px), Offset(s.right, staff.bottom + 1.5 * px),
          Paint()
            ..color = color.withValues(alpha: 0.85)
            ..strokeWidth = 2.5 * px);
    }
    // The gaps, no one's: hatched.
    for (final c in s.gaps.keys) {
      final (top, bottom) = s.gapAfter(c) ?? (0.0, 0.0);
      if (bottom <= top) continue;
      final rect = Rect.fromLTRB(s.left, top, s.right, bottom);
      final selected = selection == _GapSelection(index, c);
      canvas.drawRect(rect, Paint()..color = (selected ? colors.accent : const Color(0xFF9E9E9E)).withValues(alpha: 0.12));
      canvas.save();
      canvas.clipRect(rect);
      final hatch = Paint()
        ..color = const Color(0x40000000)
        ..strokeWidth = px;
      for (var x = rect.left - rect.height; x < rect.right; x += 8 * px) {
        canvas.drawLine(Offset(x, rect.bottom), Offset(x + rect.height, rect.top), hatch);
      }
      canvas.restore();
    }
    // The selected bar.
    if (selection case _BarSelection(:final system, :final segment) when system == index) {
      final segments = s.segments;
      if (segment < segments.length) {
        final (l, r) = segments[segment];
        canvas.drawRect(Rect.fromLTRB(l, s.top, r, s.bottom), Paint()..color = colors.accent.withValues(alpha: 0.1));
      }
    }
    if (!editing) {
      // The bars, to see where the changes go.
      final faint = Paint()
        ..color = const Color(0x55E5484D)
        ..strokeWidth = px;
      for (final line in s.barlines) {
        canvas.drawLine(Offset(line.x, s.top), Offset(line.x, s.bottom), faint);
      }
      return;
    }
    final dashed = Paint()
      ..color = (selectedSystem ? colors.accent : const Color(0xFF3E63DD)).withValues(alpha: 0.8)
      ..strokeWidth = px;
    // Its top, the cuts and its bottom, with their handles at the right.
    final edges = [
      s.top,
      for (var c = 0; c + 1 < s.staves.length; c++) ...[s.cutAfter(c), if (s.gapAfter(c) case (_, final bottom)) bottom],
      s.bottom,
    ];
    for (final y in edges) {
      _dash(canvas, Offset(s.left - 6 * px, y), Offset(s.right + 10 * px, y), dashed, px);
      final handle = Offset(s.right + 10 * px, y);
      canvas.drawCircle(handle, 4 * px, Paint()..color = const Color(0xFFFFFFFF));
      canvas.drawCircle(
          handle,
          4 * px,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2 * px
            ..color = dashed.color);
    }
    // Where the music starts.
    canvas.drawLine(Offset(s.left, s.top), Offset(s.left, s.bottom),
        Paint()
          ..color = const Color(0xFF0090FF)
          ..strokeWidth = 1.5 * px);
    // The barlines.
    for (final (b, line) in s.barlines.indexed) {
      final selected = selection is _BarlineSelection &&
          (selection as _BarlineSelection).system == index &&
          (selection as _BarlineSelection).barline == b;
      final color = selected ? colors.accent : const Color(0xFFE5484D);
      canvas.drawLine(Offset(line.x, s.top), Offset(line.x, s.bottom),
          Paint()
            ..color = color.withValues(alpha: selected ? 1 : 0.75)
            ..strokeWidth = (selected ? 2.5 : 1.5) * px);
      if (line.kind != PdfBarlineKind.normal) {
        canvas.drawCircle(Offset(line.x, s.top), 2.5 * px, Paint()..color = color);
      }
    }
  }

  static void _dash(Canvas canvas, Offset a, Offset b, Paint paint, double px) {
    final length = (b - a).distance, step = 6 * px;
    final d = (b - a) / length;
    for (var t = 0.0; t < length; t += step * 2) {
      canvas.drawLine(a + d * t, a + d * math.min(length, t + step), paint);
    }
  }

  @override
  bool shouldRepaint(_PagePainter old) =>
      old.layout != layout ||
      old.page != page ||
      old.image != image ||
      old.zoom != zoom ||
      old.selection != selection ||
      old.drawing != drawing ||
      old.colors != colors ||
      old.editing != editing ||
      old.focus != focus;
}
