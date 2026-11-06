import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'dialog_kit.dart';
import 'l10n/l10n.dart';
import 'menu_kit.dart';
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

/// What is selected on the page.
sealed class _Selection {
  const _Selection();
}

/// A bar: system [system], its [segment]th bar ([PdfSystem.segments]).
class _BarSelection extends _Selection {
  const _BarSelection(this.system, this.segment);
  final int system, segment;
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
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
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
    });
  }

  void _redoStep() {
    if (_redo.isEmpty) return;
    _typing = null;
    setState(() {
      _undo.add(layout);
      _layout = _redo.removeLast();
      _selection = null;
    });
  }

  void _setSystem(int index, PdfSystem system, {String? typing}) =>
      _edit(layout.copyWith(systems: [...layout.systems]..[index] = system.copyWith(ink: () => null)), typing: typing);

  /// The systems on the page showing, with their indices.
  Iterable<(int, PdfSystem)> get _onPage => layout.systems.indexed.where((e) => e.$2.page == _page);

  void _remove() {
    switch (_selection) {
      case _BarlineSelection(:final system, :final barline):
        final s = layout.systems[system];
        _setSystem(system, s.copyWith(barlines: [...s.barlines]..removeAt(barline)));
      case _MaskSelection(:final mask):
        _edit(layout.copyWith(masks: [...layout.masks]..removeAt(mask)));
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
    final found = await pages.detectAgain(_page, layout.instruments);
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
      for (final (k, (l, r)) in s.segments.indexed) {
        if (p.dx >= l && p.dx <= r) return _BarSelection(i, k);
      }
      return _BarSelection(i, 0);
    }
    return null;
  }

  void _down(Offset local) {
    _focus.requestFocus();
    final p = _toPage(local);
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
      _edit(layout.copyWith(masks: [...layout.masks, PdfMask(_page, rect)]));
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

  MouseCursor _cursorAt(Offset local) {
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
    } else if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
      _remove();
    } else if (key == LogicalKeyboardKey.pageDown || key == LogicalKeyboardKey.arrowRight) {
      _goTo(_page + 1);
    } else if (key == LogicalKeyboardKey.pageUp || key == LogicalKeyboardKey.arrowLeft) {
      _goTo(_page - 1);
    } else if (key == LogicalKeyboardKey.escape) {
      setState(() => _selection = null);
    } else if (key == LogicalKeyboardKey.keyV) {
      setState(() => _tool = _Tool.select);
    } else if (key == LogicalKeyboardKey.keyM) {
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
          final masks = [for (final m in layout.masks) if (m.page == s.page) m.rect];
          systems[i] = s.copyWith(ink: () => null);
          final ink = await pages.measure(s, masks);
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
            _toolbar(context),
            Divider(height: 1, color: colors.line),
            Expanded(
              child: _layout == null
                  ? _reading(context)
                  : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(child: _view(context)),
                      VerticalDivider(width: 1, color: colors.line),
                      _panel(context),
                    ]),
            ),
            Divider(height: 1, color: colors.line),
            _statusBar(context),
          ]),
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    final ready = _layout != null && _measured == null;
    return Container(
      height: style.toolbar + 8,
      color: colors.chrome,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Text('Import PDF'.tr, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
        const SizedBox(width: 10),
        Expanded(
          child: Row(children: [
            Flexible(child: Text(widget.name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: colors.textMuted))),
            const SizedBox(width: 12),
            if (_read != null || _measured != null || _rendering.isNotEmpty) PulsingDot(color: colors.accent, size: 8),
          ]),
        ),
        ToolbarButton(icon: AppIcon.undo.of(context), tooltip: 'Undo'.tr, onPressed: ready && _undo.isNotEmpty ? _undoStep : null),
        ToolbarButton(icon: AppIcon.redo.of(context), tooltip: 'Redo'.tr, onPressed: ready && _redo.isNotEmpty ? _redoStep : null),
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
        const ToolbarDivider(),
        OutlinedButton(onPressed: _cancel, child: Text('Cancel'.tr)),
        const SizedBox(width: 8),
        FilledButton(onPressed: ready && layout.systems.isNotEmpty ? _done : null, child: Text('Done'.tr)),
      ]),
    );
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
            ),
          ),
    ];
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
                        onDoubleTapDown: _tool == _Tool.select ? (d) => _doubleClick(d.localPosition) : null,
                        onDoubleTap: _tool == _Tool.select ? () {} : null,
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
                          ),
                        ),
                      ),
                    ),
                  ),
                  ...chips,
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _panel(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 280,
      color: colors.chrome,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        ..._selectionFields(context),
        _heading(context, 'Score'),
        _ScoreFields(layout: layout, onChanged: (next, field) => _edit(next, typing: field)),
        const SizedBox(height: 20),
        _heading(context, 'Instruments'),
        _instrumentList(context),
        const SizedBox(height: 12),
        if (_instrument < layout.instruments.length)
          _InstrumentFields(
            key: ValueKey(layout.instruments[_instrument].id),
            instrument: layout.instruments[_instrument],
            onChanged: (next, field) =>
                _edit(layout.copyWith(instruments: [...layout.instruments]..[_instrument] = next), typing: '${next.id}.$field'),
          ),
      ]),
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text.tr, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.colors.text)),
      );

  Widget _instrumentList(BuildContext context) {
    final colors = context.colors;
    final instruments = layout.instruments;
    void move(int by) {
      final to = _instrument + by;
      if (to < 0 || to >= instruments.length) return;
      final list = [...instruments];
      list.insert(to, list.removeAt(_instrument));
      _edit(layout.copyWith(instruments: list));
      setState(() => _instrument = to);
    }

    void add() {
      final ids = {for (final i in instruments) i.id};
      var n = instruments.length + 1;
      while (ids.contains('P$n')) {
        n++;
      }
      _edit(layout.copyWith(instruments: [...instruments, PdfInstrument(id: 'P$n', name: 'Staff {n}'.fill({'n': n}))]));
      setState(() => _instrument = instruments.length);
    }

    void remove() {
      if (_instrument >= instruments.length) return;
      final id = instruments[_instrument].id;
      _edit(layout.copyWith(
        instruments: [...instruments]..removeAt(_instrument),
        systems: [
          for (final s in layout.systems)
            s.staves.any((t) => t.part == id)
                ? s.copyWith(staves: [for (final t in s.staves) t.part == id ? t.copyWith(part: () => null) : t])
                : s,
        ],
      ));
      setState(() => _instrument = math.max(0, _instrument - 1));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, instrument) in instruments.indexed)
        InkWell(
          onTap: () => setState(() => _instrument = i),
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: i == _instrument ? colors.accentWash : null,
              borderRadius: AppStyle.of(context).radius(5),
            ),
            child: Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: _colorOf(i), shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(child: Text(instrument.name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: colors.text))),
              if (instrument.staves > 1 || instrument.divisi > 1)
                Text('×{n}'.fill({'n': instrument.staves > 1 ? instrument.staves : instrument.divisi}),
                    style: TextStyle(fontSize: 12, color: colors.textMuted)),
            ]),
          ),
        ),
      const SizedBox(height: 6),
      Row(children: [
        ToolbarButton(icon: AppIcon.add.of(context), tooltip: 'Add Instrument'.tr, onPressed: add),
        ToolbarButton(icon: AppIcon.close.of(context), tooltip: 'Remove Instrument'.tr, onPressed: instruments.isEmpty ? null : remove),
        const Spacer(),
        ToolbarButton(icon: AppIcon.collapse.of(context), tooltip: 'Move Up'.tr, onPressed: _instrument > 0 ? () => move(-1) : null),
        ToolbarButton(
            icon: AppIcon.expand.of(context),
            tooltip: 'Move Down'.tr,
            onPressed: _instrument < instruments.length - 1 ? () => move(1) : null),
      ]),
    ]);
  }

  /// What the selection is, and what can be done to it.
  List<Widget> _selectionFields(BuildContext context) {
    final selection = _selection;
    final pageButtons = Row(children: [
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
          _heading(context, bar == null ? 'System' : 'Bar {n}'.fill({'n': bar + 1 - (layout.pickup > 0 ? 1 : 0)})),
          if (bar != null && bar > 0) ...[
            _ChangeFields(
              key: ValueKey('change $bar'),
              layout: layout,
              bar: bar,
              onChanged: (next, field) => _edit(next, typing: '$bar.$field'),
            ),
            const SizedBox(height: 10),
          ],
          OutlinedButton(onPressed: _remove, child: Text('Remove System'.tr)),
        ]);
      case _MaskSelection():
        out.addAll([
          _heading(context, 'Mask'),
          OutlinedButton(onPressed: _remove, child: Text('Remove Mask'.tr)),
        ]);
      case _GapSelection():
        out.addAll([
          _heading(context, 'Gap'),
          OutlinedButton(onPressed: _remove, child: Text('Remove Gap'.tr)),
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

  Widget _statusBar(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    final muted = TextStyle(fontSize: 12, color: colors.textMuted);
    final String text;
    if (_error case final error? when _layout != null) {
      text = 'Couldn’t measure the bars. {error}'.fill({'error': error});
    } else if (_measured case final n?) {
      text = 'Measuring system {n} of {count}…'.fill({'n': math.min(n + 1, layout.systems.length), 'count': layout.systems.length});
    } else if (_layout != null) {
      text = '{bars} bars · {systems} systems'.fill({'bars': layout.bars.length, 'systems': layout.systems.length});
    } else {
      text = '';
    }
    return Container(
      height: style.control + 4,
      color: colors.chrome,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      child: Text(text, style: muted, overflow: TextOverflow.ellipsis),
    );
  }
}

/// A staff's instrument, at its left: a chip in the instrument's colour that picks another (or
/// none: left out of the score).
class _StaffChip extends StatelessWidget {
  const _StaffChip({required this.layout, required this.staff, required this.onChanged});
  final PdfScoreLayout layout;
  final PdfStaff staff;
  final void Function(String? part, int staff) onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final index = layout.instruments.indexWhere((i) => i.id == staff.part);
    final instrument = index < 0 ? null : layout.instruments[index];
    final color = index < 0 ? colors.textMuted : _PdfImportState._colorOf(index);
    final label = instrument == null
        ? 'None'.tr
        : '${instrument.abbreviation.isNotEmpty ? instrument.abbreviation : instrument.name}${instrument.staves > 1 || staff.staff > 1 ? ' ${staff.staff}' : ''}';
    return AppPopupMenuButton<(String?, int)>(
      tooltip: 'Instrument',
      padding: EdgeInsets.zero,
      onSelected: (v) => onChanged(v.$1, v.$2),
      itemBuilder: (context) => [
        // A piano's staves, or a section's divisi.
        for (final i in layout.instruments)
          for (var n = 1; n <= (i.staves > 1 ? i.staves : i.divisi); n++)
            checkedMenuItem(context,
                value: (i.id, n),
                checked: staff.part == i.id && staff.staff == n,
                child: Text(i.staves > 1 || i.divisi > 1 ? '${i.name} $n' : i.name)),
        menuDivider(context),
        checkedMenuItem(context, value: (null, 1), checked: staff.part == null, child: Text('None'.tr)),
      ],
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
    );
  }
}

/// The score's title, meter, key, upbeat and tempo.
class _ScoreFields extends StatefulWidget {
  const _ScoreFields({required this.layout, required this.onChanged});
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
  const _KeyField({required this.value, required this.onChanged, this.none = false});
  final int? value;
  final ValueChanged<int?> onChanged;

  /// Whether "no change" is a choice (null).
  final bool none;

  static const _names = ['C♭', 'G♭', 'D♭', 'A♭', 'E♭', 'B♭', 'F', 'C', 'G', 'D', 'A', 'E', 'B', 'F♯', 'C♯'];

  @override
  Widget build(BuildContext context) => AppDropdown<int?>(
        value: value,
        isExpanded: true,
        label: 'Key',
        items: [
          if (none) DropdownMenuItem(value: null, child: Text('—')),
          for (var f = -7; f <= 7; f++) DropdownMenuItem(value: f, child: Text(_names[f + 7])),
        ],
        onChanged: (f) => onChanged(f),
      );
}

/// A bar's meter and key, where they change.
class _ChangeFields extends StatefulWidget {
  const _ChangeFields({super.key, required this.layout, required this.bar, required this.onChanged});
  final PdfScoreLayout layout;
  final int bar;
  final void Function(PdfScoreLayout next, String field) onChanged;

  @override
  State<_ChangeFields> createState() => _ChangeFieldsState();
}

class _ChangeFieldsState extends State<_ChangeFields> {
  late final _meter = TextEditingController(text: widget.layout.meters[widget.bar]?.toString() ?? '');
  bool _bad = false;

  @override
  void dispose() {
    _meter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layout = widget.layout, bar = widget.bar;
    return Row(children: [
      Expanded(
        child: AppTextField(
          controller: _meter,
          label: 'Time',
          hint: layout.meterAt(bar).toString(),
          bad: _bad,
          onChanged: (v) {
            final meter = PdfMeter.parse(v);
            setState(() => _bad = v.trim().isNotEmpty && meter == null);
            if (v.trim().isEmpty) {
              widget.onChanged(layout.copyWith(meters: {...layout.meters}..remove(bar)), 'meter');
            } else if (meter != null) {
              widget.onChanged(layout.copyWith(meters: {...layout.meters, bar: meter}), 'meter');
            }
          },
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: _KeyField(
          value: layout.keys[bar],
          none: true,
          onChanged: (f) => widget.onChanged(
              layout.copyWith(keys: f == null ? ({...layout.keys}..remove(bar)) : {...layout.keys, bar: f}), 'key'),
        ),
      ),
    ]);
  }
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

  static String _clefName(PdfClef c) => switch (c) {
        PdfClef.treble => 'Treble',
        PdfClef.treble8vb => 'Treble 8vb',
        PdfClef.alto => 'Alto',
        PdfClef.tenor => 'Tenor',
        PdfClef.bass => 'Bass',
        PdfClef.percussion => 'Percussion',
      };

  @override
  Widget build(BuildContext context) {
    final i = widget.instrument;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppTextField(
          controller: _name,
          label: 'Name',
          onChanged: (v) {
            if (v.trim().isNotEmpty) widget.onChanged(i.copyWith(name: v), 'name');
          }),
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
            items: [for (final c in PdfClef.values) DropdownMenuItem(value: c, child: Text(_clefName(c).tr))],
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
  });

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
      _mask(canvas, m.rect, px, selected: selected);
    }
    if (drawing case final rect?) _mask(canvas, rect, px, selected: true);
  }

  void _mask(Canvas canvas, Rect rect, double px, {required bool selected}) {
    canvas.drawRect(rect, Paint()..color = const Color(0xCCB0B0B0));
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
          ..color = selected ? colors.accent : const Color(0xFF707070));
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
      canvas.drawRect(Rect.fromLTRB(s.left, top, s.right, bottom), Paint()..color = color.withValues(alpha: 0.06));
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
      old.colors != colors;
}
