import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'editor_controller.dart';
import 'lanes_common.dart';
import 'package:score_engine/score_engine.dart';
import 'l10n/l10n.dart';

/// Project Settings ▸ Sections: the instruments top to bottom as a score's staves, bracketed as
/// the score brackets them ([CuratedScene.sections]). A bracket's end is dragged to take in or
/// let go of instruments, and one is drawn by dragging down the bracket column; instruments are
/// selected as lanes are (a click, ⌘-click a range, ⇧-click adds) for Bracket and Unbracket.
/// While a bracket is dragged the score shows it ([EditorController.previewSections]); letting go
/// is one Undo step.
class SectionsEditor extends StatefulWidget {
  const SectionsEditor({super.key, required this.controller});
  final EditorController controller;

  @override
  State<SectionsEditor> createState() => _SectionsEditorState();
}

/// What a drag is doing: moving one end of the bracket over rows [start]–[end], or drawing one
/// from row [start].
typedef _Drag = ({int start, int end, bool top, bool drawing});

class _SectionsEditorState extends State<SectionsEditor> {
  static const _rowHeight = 36.0, _sp = 4.0, _nameWidth = 150.0, _gutter = 24.0;
  static const _staffHeight = 4 * _sp;
  static const _staffLeft = _nameWidth + _gutter;

  EditorController get controller => widget.controller;

  Set<String> _selected = {};
  String? _anchor; // where a ⌘-click range starts
  _Drag? _drag;
  List<String?>? _draft; // the sections while a drag lasts
  MouseCursor _cursor = MouseCursor.defer;

  List<ScorePart> get _rows => controller.laneParts;

  /// Each row's section, as the score has them.
  List<String?> get _keys => [for (final p in _rows) controller.sectionOf(p)];

  /// The parts a row stands for: a condensed pair's two players.
  List<String> _idsOf(ScorePart part) => controller.condensedGroupOf(part.id)?.partIds ?? [part.id];

  /// The bracketed runs of [keys] (one per row), as the score brackets them: rows in a row of
  /// one section, two or more, or one the user put in it.
  List<({int start, int end})> _runs(List<String?> keys) {
    final rows = _rows, runs = <({int start, int end})>[];
    bool own(int i) => keys[i] != null && keys[i] != rows[i].section?.name;
    var start = 0;
    for (var i = 1; i <= keys.length; i++) {
      if (i < keys.length && keys[i] != null && keys[i] == keys[start]) continue;
      if (keys[start] != null && (i - 1 > start || own(start))) runs.add((start: start, end: i - 1));
      start = i;
    }
    return runs;
  }

  /// A section no instrument is in yet.
  String _freshKey(Iterable<String?> keys) {
    var n = 1;
    for (final k in keys) {
      if (k case final k? when k.startsWith('bracket-')) n = math.max(n, (int.tryParse(k.substring(8)) ?? 0) + 1);
    }
    return 'bracket-$n';
  }

  /// [keys] as [EditorController.setSections] takes them: only rows that differ from now.
  Map<String, String?> _changes(List<String?> keys) {
    final rows = _rows, now = _keys;
    return {
      for (var i = 0; i < rows.length; i++)
        if (keys[i] != now[i])
          for (final id in _idsOf(rows[i])) id: keys[i],
    };
  }

  @override
  void dispose() {
    // Closing the window mid-drag ends the drag first (an edit, as a cancelled one is); should
    // it not, the score still lets go of the bracket it was showing.
    if (_draft != null) controller.previewSections(null);
    super.dispose();
  }

  int _rowAt(double y) => (y / _rowHeight).floor().clamp(0, _rows.length - 1);

  // MARK: Pointer

  /// The run whose end is under [p] (in the bracket column), and which end.
  ({int run, bool top})? _endAt(Offset p, List<({int start, int end})> runs) {
    if (p.dx < _nameWidth || p.dx > _staffLeft + 4) return null;
    ({int run, bool top})? nearest;
    var distance = 8.0;
    for (final (i, run) in runs.indexed) {
      for (final (top, y) in [(true, _staffTop(run.start)), (false, _staffTop(run.end) + _staffHeight)]) {
        if ((p.dy - y).abs() <= distance) {
          distance = (p.dy - y).abs();
          nearest = (run: i, top: top);
        }
      }
    }
    return nearest;
  }

  bool _inGutter(Offset p) => p.dx >= _nameWidth && p.dx <= _staffLeft;

  void _hover(PointerHoverEvent e) {
    final p = e.localPosition;
    final cursor = _endAt(p, _runs(_keys)) != null
        ? SystemMouseCursors.resizeUpDown
        : _inGutter(p)
            ? SystemMouseCursors.precise
            : SystemMouseCursors.click;
    if (cursor != _cursor) setState(() => _cursor = cursor);
  }

  void _panStart(DragStartDetails d) {
    final p = d.localPosition;
    final runs = _runs(_keys);
    if (_endAt(p, runs) case (:final run, :final top)) {
      _drag = (start: runs[run].start, end: runs[run].end, top: top, drawing: false);
    } else if (_inGutter(p)) {
      final row = _rowAt(p.dy);
      _drag = (start: row, end: row, top: false, drawing: true);
    }
  }

  void _panUpdate(DragUpdateDetails d) {
    final drag = _drag;
    if (drag == null) return;
    final keys = [..._keys], row = _rowAt(d.localPosition.dy);
    if (drag.drawing) {
      final (a, b) = (math.min(drag.start, row), math.max(drag.start, row));
      final key = _freshKey(keys);
      for (var i = a; i <= b; i++) {
        keys[i] = key;
      }
    } else {
      final key = keys[drag.start];
      final (a, b) = drag.top ? (math.min(row, drag.end), drag.end) : (drag.start, math.max(row, drag.start));
      for (var i = drag.start; i <= drag.end; i++) {
        keys[i] = null; // let go of, unless still within
      }
      for (var i = a; i <= b; i++) {
        keys[i] = key;
      }
      // Down to one instrument in its own family's: one of its own, or the bracket would go.
      if (a == b && key == _rows[a].section?.name) keys[a] = _freshKey(keys);
    }
    setState(() => _draft = keys);
    controller.previewSections(_changes(keys));
  }

  void _panEnd() {
    final draft = _draft;
    _drag = null;
    setState(() => _draft = null);
    if (draft == null) return controller.previewSections(null);
    controller.setSections(_changes(draft));
  }

  void _tapUp(TapUpDetails d) {
    final p = d.localPosition;
    final rows = _rows;
    if (_inGutter(p)) {
      // A bracket: its instruments.
      final row = _rowAt(p.dy);
      for (final run in _runs(_keys)) {
        if (row >= run.start && row <= run.end) {
          setState(() => _selected = {for (var i = run.start; i <= run.end; i++) rows[i].id});
          _anchor = rows[run.start].id;
          return;
        }
      }
      return setState(() => _selected = {});
    }
    final id = rows[_rowAt(p.dy)].id;
    setState(() {
      if (isCommandPressed) {
        final ids = [for (final r in rows) r.id];
        final from = ids.indexOf(_anchor ?? id), to = ids.indexOf(id);
        final (a, b) = from < 0 ? (to, to) : (math.min(from, to), math.max(from, to));
        _selected = {...ids.sublist(a, b + 1)};
      } else if (HardwareKeyboard.instance.isShiftPressed) {
        _selected = {..._selected, id};
        _anchor = id;
      } else {
        _selected = {id};
        _anchor = id;
      }
    });
  }

  // MARK: Buttons

  List<int> get _selectedRows => [for (final (i, r) in _rows.indexed) if (_selected.contains(r.id)) i];

  /// The selected rows, those next to each other together.
  List<({int start, int end})> get _selectedRuns {
    final rows = _selectedRows, runs = <({int start, int end})>[];
    for (var i = 0; i < rows.length;) {
      var j = i;
      while (j + 1 < rows.length && rows[j + 1] == rows[j] + 1) {
        j++;
      }
      runs.add((start: rows[i], end: rows[j]));
      i = j + 1;
    }
    return runs;
  }

  void _bracket() {
    final keys = [..._keys];
    for (final run in _selectedRuns) {
      final key = _freshKey(keys);
      for (var i = run.start; i <= run.end; i++) {
        keys[i] = key;
      }
    }
    controller.setSections(_changes(keys));
  }

  bool get _canUnbracket {
    final runs = _runs(_keys);
    return _selectedRows.any((i) => runs.any((r) => i >= r.start && i <= r.end));
  }

  void _unbracket() {
    final keys = [..._keys];
    for (final i in _selectedRows) {
      keys[i] = null;
    }
    controller.setSections(_changes(keys));
  }

  double _staffTop(int row) => row * _rowHeight + (_rowHeight - _staffHeight) / 2;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final rows = _rows;
    final keys = _draft ?? _keys;
    _selected = {for (final r in rows) if (_selected.contains(r.id)) r.id}; // lanes come and go
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 4),
        child: Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
          OutlinedButton(onPressed: _selectedRuns.isEmpty ? null : _bracket, child: Text('Bracket'.tr)),
          OutlinedButton(onPressed: _canUnbracket ? _unbracket : null, child: Text('Unbracket'.tr)),
          OutlinedButton(onPressed: controller.hasOwnSections ? controller.resetSections : null, child: Text('Reset'.tr)),
        ]),
      ),
      Expanded(
          child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(4, 4, 16, 12),
        child: MouseRegion(
          cursor: _cursor,
          onHover: _hover,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down, // from where it was pressed: a bracket's end
            onTapUp: _tapUp,
            // Up and down only: taking the drag before the page's scrolling would.
            onVerticalDragStart: _panStart,
            onVerticalDragUpdate: _panUpdate,
            onVerticalDragEnd: (_) => _panEnd(),
            onVerticalDragCancel: _panEnd,
            child: CustomPaint(
              size: Size(double.infinity, rows.length * _rowHeight),
              painter: _SectionsPainter(
                names: [for (final p in rows) controller.laneName(p)],
                runs: _runs(keys),
                selected: [for (final p in rows) _selected.contains(p.id)],
                ink: colors.text,
                selection: colors.accentSoft,
                textStyle: DefaultTextStyle.of(context).style.copyWith(fontSize: 13, color: colors.text),
              ),
            ),
          ),
        ),
      )),
    ]);
  }
}

/// The staves: names right-aligned beside them, the starting line through every one, brackets
/// (thick lines with the font's hooks) and barlines joined through each bracket, as the score has them.
class _SectionsPainter extends CustomPainter {
  _SectionsPainter({
    required this.names,
    required this.runs,
    required this.selected,
    required this.ink,
    required this.selection,
    required this.textStyle,
  });

  final List<String> names;
  final List<({int start, int end})> runs;
  final List<bool> selected;
  final Color ink, selection;
  final TextStyle textStyle;

  static const _rowHeight = _SectionsEditorState._rowHeight, _sp = _SectionsEditorState._sp;
  static const _staffHeight = _SectionsEditorState._staffHeight, _left = _SectionsEditorState._staffLeft;
  static const _line = 0.13 * _sp, _thin = 0.16 * _sp, _bracket = 0.5 * _sp, _bracketGap = 0.25 * _sp;

  double _top(int row) => row * _rowHeight + (_rowHeight - _staffHeight) / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = ink;
    final right = size.width - 2;
    for (var i = 0; i < names.length; i++) {
      if (selected[i]) {
        canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromLTRB(0, i * _rowHeight + 1, size.width, (i + 1) * _rowHeight - 1),
                const Radius.circular(5)),
            Paint()..color = selection);
      }
      final top = _top(i);
      for (var l = 0; l < 5; l++) {
        canvas.drawRect(Rect.fromLTRB(_left, top + l * _sp - _line / 2, right, top + l * _sp + _line / 2), paint);
      }
      // The barline at the end, run on through a bracket.
      final through = runs.any((r) => i >= r.start && i < r.end);
      canvas.drawRect(Rect.fromLTRB(right - _thin, top, right, top + _staffHeight + (through ? _rowHeight - _staffHeight : 0)), paint);
      final name = TextPainter(
        text: TextSpan(text: names[i], style: textStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: _SectionsEditorState._nameWidth - 12);
      name.paint(canvas, Offset(_SectionsEditorState._nameWidth - 12 - name.width, top + _staffHeight / 2 - name.height / 2));
      name.dispose();
    }
    if (names.isEmpty) return;
    // The starting line, through every staff.
    canvas.drawRect(Rect.fromLTRB(_left, _top(0), _left + _thin, _top(names.length - 1) + _staffHeight), paint);
    for (final run in runs) {
      final top = _top(run.start), bottom = _top(run.end) + _staffHeight;
      final x = _left - _bracketGap - _bracket;
      canvas.drawRect(Rect.fromLTRB(x, top, x + _bracket, bottom), paint);
      _glyph(canvas, 0xE003, x, top); // bracketTop: its ink above the baseline
      _glyph(canvas, 0xE004, x, bottom); // bracketBottom: below it
    }
  }

  void _glyph(Canvas canvas, int codepoint, double x, double baseline) {
    final glyph = TextPainter(
      text: TextSpan(
          text: String.fromCharCode(codepoint),
          style: TextStyle(fontFamily: 'packages/score_engine/Bravura', fontSize: 4 * _sp, color: ink, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    glyph.paint(canvas, Offset(x, baseline - glyph.computeDistanceToActualBaseline(TextBaseline.alphabetic)));
    glyph.dispose();
  }

  @override
  bool shouldRepaint(_SectionsPainter old) =>
      !listEquals(old.runs, runs) ||
      !listEquals(old.names, names) ||
      !listEquals(old.selected, selected) ||
      old.ink != ink ||
      old.selection != selection ||
      old.textStyle != textStyle;

}
