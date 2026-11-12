import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, listEquals, mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'dialog_kit.dart';
import 'downloader.dart';
import 'error_text.dart';
import 'l10n/l10n.dart';
import 'lilypond.dart';
import 'lilypond_dialog.dart';
import 'lilypond_language.dart';
import 'ui_kit.dart';

/// What the LilyPond editor gives back: the score as edited, and LilyPond's engraving of it.
typedef LilyPondEdit = ({LilySource source, LilyPondRun run});

/// A LilyPond score's source in an editor of its own, over the window: its files (the main one
/// and those it includes) as code, highlighted, what can be typed offered as it is; under them the
/// score as LilyPond last engraved it (a click on something drawn goes to where it is written, and
/// what the caret's line wrote is marked), and what LilyPond said was wrong (a click goes there).
/// Engrave (⌘R) engraves it again. Done gives back the source with its engraving, engraving it
/// first when it changed since (and staying, its errors shown, when LilyPond found any); null when
/// nothing changed. [run]: an engraving of [source] made already, shown as it opens. Its text
/// is set and drawn in [textFont] (see [LilyPond.textFontFor]). Without LilyPond, Engrave asks
/// for it, [downloadHub] opening Settings ▸ Download Hub over the editor.
Future<LilyPondEdit?> showLilyPondEditor(BuildContext context, LilySource source,
        {LilyPondRun? run, String textFont = TextFonts.academico, required VoidCallback downloadHub}) =>
    Navigator.of(context, rootNavigator: true).push<LilyPondEdit>(PageRouteBuilder(
      opaque: true,
      transitionDuration: motion(context, 200),
      reverseTransitionDuration: motion(context, 160),
      pageBuilder: (_, _, _) => LilyPondEditor(source: source, run: run, textFont: textFont, downloadHub: downloadHub),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic), child: child),
    ));

class LilyPondEditor extends StatefulWidget {
  const LilyPondEditor({super.key, required this.source, this.run, this.textFont = TextFonts.academico, required this.downloadHub});
  final LilySource source;
  final LilyPondRun? run;
  final String textFont;
  final VoidCallback downloadHub;

  @override
  State<LilyPondEditor> createState() => _LilyPondEditorState();
}

class _LilyPondEditorState extends State<LilyPondEditor> {
  LilySource get _source => widget.source;

  /// The score's files by their path under its root, the main one first.
  late final List<String> _paths = [_source.path, ...(_source.files.keys.toList()..sort())];
  late final Map<String, CodeLineEditingController> _code = {
    for (final p in _paths)
      p: CodeLineEditingController.fromText(p == _source.path ? _source.text : utf8.decode(_source.files[p]!, allowMalformed: true)),
  };

  /// Each file's text as it opened.
  late final Map<String, String> _opened = _texts();
  late String _shown = _paths.first;

  /// The latest engraving, what it engraved, and its drawing (once read).
  LilyPondRun? _run;
  Map<String, String>? _runTexts;
  LilyPondDrawing? _drawing;

  /// Why the latest engraving couldn't be read (LilyPond drew something Curator doesn't know).
  String? _unreadable;

  /// The engraving under way.
  DownloadCancel? _engraving;

  final _editorFocus = FocusNode(debugLabel: 'LilyPond code');
  final _hScroll = ScrollController(), _vScroll = ScrollController();

  /// Where what the caret's line wrote is drawn (engraving units).
  final _marked = ValueNotifier<List<Rect>>(const []);

  /// The preview's height: dragged by its top edge.
  double _previewHeight = 220;

  late final _prompts = LilyPondPrompts(() => [for (final c in _code.values) c.text].join('\n'));

  static final _mode = lilyPondMode();
  static final _themes = <Brightness, CodeHighlightTheme>{};

  @override
  void initState() {
    super.initState();
    for (final c in _code.values) {
      c.addListener(_codeChanged);
    }
    if (widget.run case final run?) {
      _run = run;
      _runTexts = _opened;
      if (run.engraved) _read(run);
    }
  }

  @override
  void dispose() {
    _engraving?.cancel();
    for (final f in _findControllers.values) {
      f.dispose();
    }
    for (final c in _code.values) {
      c
        ..removeListener(_codeChanged)
        ..dispose();
    }
    _drawing?.dispose();
    _editorFocus.dispose();
    _hScroll.dispose();
    _vScroll.dispose();
    _marked.dispose();
    super.dispose();
  }

  Map<String, String> _texts() => {for (final MapEntry(:key, :value) in _code.entries) key: value.text};

  bool get _edited => !mapEquals(_texts(), _opened);

  /// Whether the source changed since it was last engraved (or never was).
  bool get _stale => _runTexts == null || !mapEquals(_texts(), _runTexts);

  /// The source as it is now: a file not edited as it came, byte for byte.
  LilySource _current() => LilySource(
        name: _source.name,
        text: _code[_source.path]!.text,
        folder: _source.folder,
        origin: _source.origin,
        files: {
          for (final p in _paths.skip(1)) p: _code[p]!.text == _opened[p] ? _source.files[p]! : utf8.encode(_code[p]!.text),
        },
      );

  /// A file's text or caret moved: the page shows it (Undo, Redo, the file's edited dot, the
  /// caret's notes marked). The editor tells this when it takes a file's controller too, as it is
  /// built: then after that frame.
  void _codeChanged() {
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) return _showChange();
    if (_changePending) return;
    _changePending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) => _showChange());
  }

  bool _changePending = false;

  void _showChange() {
    _changePending = false;
    if (!mounted) return;
    _markCaretLine();
    setState(() {});
  }

  // MARK: Engraving

  /// Engraves the source as it is now (where LilyPond isn't here, it is asked for: see
  /// [engraveWithLilyPond]); its problems shown, its drawing once read.
  Future<void> _engrave() async {
    if (_engraving != null) return;
    final source = _current(), texts = _texts();
    LilyPondRun run;
    if (!LilyPond.installed) {
      final got = await engraveWithLilyPond(context, source, textFont: widget.textFont, downloadHub: widget.downloadHub)
          .then<LilyPondRun?>((r) => r,
          onError: (Object e) => LilyPondRun(problems: [LilyProblem(describeError(e), error: true)]));
      if (got == null || !mounted) return;
      run = got;
    } else {
      final cancel = _engraving = DownloadCancel();
      setState(() {});
      try {
        run = await LilyPond.engrave(source, textFont: widget.textFont, cancel: cancel);
      } on DownloadException {
        return; // cancelled
      } on Object catch (e) {
        run = LilyPondRun(problems: [LilyProblem(describeError(e), error: true)]);
      } finally {
        if (_engraving == cancel) _engraving = null;
        if (mounted) setState(() {});
      }
      if (!mounted || cancel.cancelled) return;
    }
    setState(() {
      _run = run;
      _runTexts = texts;
      _unreadable = null;
    });
    if (run.engraved) await _read(run);
  }

  /// [run]'s engraving read (on another isolate) and drawn, in place of the one before.
  Future<void> _read(LilyPondRun run) async {
    final (svg, data) = (run.svg!, run.data!);
    try {
      final score = await LilyPond.readScore(svg, data);
      if (!mounted || run != _run) return;
      setState(() {
        _drawing?.dispose();
        _drawing = LilyPondDrawing(score, textFontFamily: TextFonts.familyOf(widget.textFont));
      });
      _markCaretLine();
    } on Object catch (e) {
      if (mounted && run == _run) setState(() => _unreadable = describeError(e));
    }
  }

  // MARK: Going to the source

  /// Shows file [path] (one of the score's; another, LilyPond's own, stays unseen) with the caret
  /// on [line] (from 1) at [offset] (characters from its start).
  void _goTo(String? path, int line, int offset) {
    final file = path ?? _shown;
    final c = _code[file];
    if (c == null) return;
    setState(() => _shown = file);
    final index = (line - 1).clamp(0, c.codeLines.length - 1);
    c.selection = CodeLineSelection.collapsed(index: index, offset: offset.clamp(0, c.codeLines[index].length));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      c.makeCursorCenterIfInvisible();
      _editorFocus.requestFocus();
    });
  }

  /// Marks what the caret's line wrote in the preview, and brings the first of it into view.
  void _markCaretLine() {
    final drawing = _drawing, c = _code[_shown]!;
    if (drawing == null) return;
    final line = c.selection.extentIndex + 1;
    final rects = [
      for (final link in drawing.score.links)
        if (link.line == line && link.file == _shown) link.bounds,
    ];
    if (listEquals(rects, _marked.value)) return;
    _marked.value = rects;
    if (rects.isEmpty || !_hScroll.hasClients) return;
    final extent = _extent(drawing);
    final x = (rects.first.left - extent.left) * _scale, view = _hScroll.position.viewportDimension;
    if (x < _hScroll.offset || x > _hScroll.offset + view - 40) {
      _hScroll.animateTo((x - view / 3).clamp(0, _hScroll.position.maxScrollExtent),
          duration: motion(context, 240), curve: Curves.easeOutCubic);
    }
  }

  // MARK: Leaving

  Future<void> _done() async {
    if (!_edited && (widget.run?.engraved ?? false)) return Navigator.of(context).pop();
    if (_stale) {
      await _engrave();
      if (!mounted) return;
      // Engraved just now: its errors are seen before it is taken (Done again takes it).
      if (_stale || (_run?.problems.any((p) => p.error) ?? false)) return;
    }
    final run = _run;
    if (run == null || !run.engraved) return; // LilyPond's errors say why
    Navigator.of(context).pop((source: _current(), run: run));
  }

  Future<void> _cancel() async {
    if (!_edited) {
      _engraving?.cancel();
      return Navigator.of(context).pop();
    }
    final discard = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: Text('Discard Your Changes?'.tr),
        content: Text('The score stays as it was.'.tr),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Keep Editing'.tr)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Discard'.tr)),
        ],
        confirmsOnReturn: false,
      ),
    );
    if (discard == true && mounted) {
      _engraving?.cancel();
      Navigator.of(context).pop();
    } else if (mounted) {
      _editorFocus.requestFocus();
    }
  }

  // MARK: Building

  /// Points a staff space in the preview.
  static const _scale = 5.5 / LilyPondScore.unit;

  /// What the preview shows of [drawing]: its ink, and a margin.
  static Rect _extent(LilyPondDrawing drawing) => drawing.bounds.inflate(2 * LilyPondScore.unit);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _cancel();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyR, meta: true): _engrave,
          const SingleActivator(LogicalKeyboardKey.keyR, control: true): _engrave,
        },
        child: Material(
          color: colors.surface,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _toolbar(context),
            Divider(height: 1, color: colors.line),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (_paths.length > 1) ...[_files(context), VerticalDivider(width: 1, color: colors.line)],
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final preview = _previewHeight.clamp(80.0, math.max(80.0, constraints.maxHeight - 120)).toDouble();
                      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(child: _editor(context)),
                        _divider(context, constraints.maxHeight),
                        SizedBox(height: preview, child: _preview(context)),
                        if (_problems.isNotEmpty) ...[Divider(height: 1, color: colors.line), _problemList(context)],
                      ]);
                    },
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    final c = _code[_shown]!;
    return Container(
      height: style.toolbar + 8,
      color: colors.chrome,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Text('Edit Score'.tr, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
        const SizedBox(width: 10),
        Expanded(
          child: Row(children: [
            Flexible(
                child: Text(_source.name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: colors.textMuted))),
            const SizedBox(width: 12),
            if (_engraving != null) PulsingDot(color: colors.accent, size: 8),
          ]),
        ),
        ToolbarButton(
            icon: AppIcon.undo.of(context), tooltip: 'Undo ({key})'.fill({'key': shortcut('⌘Z')}), onPressed: c.canUndo ? c.undo : null),
        ToolbarButton(
            icon: AppIcon.redo.of(context),
            tooltip: 'Redo ({key})'.fill({'key': shortcut('⇧⌘Z', 'Ctrl+Y')}),
            onPressed: c.canRedo ? c.redo : null),
        ToolbarButton(icon: AppIcon.search.of(context), tooltip: 'Find ({key})'.fill({'key': shortcut('⌘F')}), onPressed: _find),
        const ToolbarDivider(),
        Tip(
          message: 'Engrave ({key})'.fill({'key': shortcut('⌘R')}),
          child: OutlinedButton(onPressed: _engraving == null ? _engrave : null, child: Text('Engrave'.tr)),
        ),
        const ToolbarDivider(),
        OutlinedButton(onPressed: _cancel, child: Text('Cancel'.tr)),
        const SizedBox(width: 8),
        FilledButton(onPressed: _engraving == null ? _done : null, child: Text('Done'.tr)),
      ]),
    );
  }

  /// The files the score is made of, to choose the one shown: the main one first.
  Widget _files(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 200,
      color: colors.chrome,
      child: ListView(padding: const EdgeInsets.all(8), children: [
        for (final p in _paths)
          SidebarTile(
            icon: AppIcon.code.of(context),
            label: p,
            selected: p == _shown,
            onTap: () => setState(() => _shown = p),
            trailing: _code[p]!.text != _opened[p] ? Text('•', style: TextStyle(color: colors.accent)) : null,
          ),
      ]),
    );
  }

  final _findControllers = <String, CodeFindController>{};

  void _find() {
    _findControllers[_shown]?.findMode();
    _findControllers[_shown]?.focusOnFindInput();
  }

  Widget _editor(BuildContext context) {
    final colors = context.colors, theme = Theme.of(context);
    final code = _code[_shown]!;
    final find = _findControllers[_shown] ??= CodeFindController(code);
    final highlight = _themes[theme.brightness] ??= CodeHighlightTheme(
      languages: {'lilypond': CodeHighlightThemeMode(mode: _mode)},
      theme: lilyPondTheme(theme.brightness),
    );
    final gutter = TextStyle(fontSize: 12, color: colors.textMuted.withValues(alpha: 0.7), fontFamily: monospace.fontFamily,
        fontFamilyFallback: monospace.fontFamilyFallback);
    return KeyedSubtree(
      key: ValueKey(_shown),
      child: CodeAutocomplete(
        viewBuilder: (context, notifier, onSelected) => _PromptList(notifier: notifier, onSelected: onSelected),
        promptsBuilder: _prompts,
        child: CodeEditor(
          controller: code,
          findController: find,
          focusNode: _editorFocus,
          wordWrap: false,
          padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
          style: CodeEditorStyle(
            fontSize: 13,
            fontFamily: monospace.fontFamily,
            fontFamilyFallback: monospace.fontFamilyFallback,
            fontHeight: 1.45,
            textColor: colors.text,
            backgroundColor: colors.surface,
            selectionColor: colors.accent.withValues(alpha: 0.25),
            highlightColor: colors.accent.withValues(alpha: 0.3),
            cursorColor: colors.accent,
            cursorLineColor: colors.accentWash.withValues(alpha: 0.5),
            codeTheme: highlight,
          ),
          indicatorBuilder: (context, editing, chunks, notifier) => Row(children: [
            DefaultCodeLineNumber(controller: editing, notifier: notifier, textStyle: gutter, focusedTextStyle: gutter.copyWith(color: colors.text)),
            DefaultCodeChunkIndicator(width: 18, controller: chunks, notifier: notifier),
          ]),
          findBuilder: (context, controller, readOnly) => _FindBar(controller: controller, readOnly: readOnly),
        ),
      ),
    );
  }

  /// The preview's top edge: dragged, the preview is taller or shorter.
  Widget _divider(BuildContext context, double height) {
    final colors = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) =>
            setState(() => _previewHeight = (_previewHeight - d.delta.dy).clamp(80.0, math.max(80.0, height - 120)).toDouble()),
        child: SizedBox(height: 7, child: Center(child: Divider(height: 1, color: colors.line))),
      ),
    );
  }

  Widget _preview(BuildContext context) {
    final colors = context.colors;
    final drawing = _drawing;
    if (drawing == null) {
      final note = _engraving != null
          ? 'Engraving…'.tr
          : _unreadable ??
              (_run == null
                  ? 'Engrave to see the score.'.tr
                  : _run!.engraved
                      ? ''
                      : 'Nothing to show yet.'.tr);
      return ColoredBox(
        color: colors.scorePaper,
        child: Center(child: Text(note, style: TextStyle(color: colors.textMuted))),
      );
    }
    final extent = _extent(drawing);
    final size = Size(extent.width * _scale, extent.height * _scale);
    return ColoredBox(
      color: colors.scorePaper,
      child: LayoutBuilder(
        builder: (context, constraints) => Scrollbar(
          controller: _vScroll,
          child: SingleChildScrollView(
            controller: _vScroll,
            child: Scrollbar(
              controller: _hScroll,
              notificationPredicate: (n) => n.depth == 0,
              child: SingleChildScrollView(
                controller: _hScroll,
                scrollDirection: Axis.horizontal,
                child: GestureDetector(
                  onTapUp: (d) => _clicked(drawing, extent.topLeft + d.localPosition / _scale),
                  child: CustomPaint(
                    key: const ValueKey('LilyPond preview'),
                    size: size,
                    painter: _PreviewPainter(
                      drawing: drawing,
                      extent: extent,
                      ink: colors.scoreInk,
                      mark: colors.accent.withValues(alpha: 0.28),
                      marked: _marked,
                      horizontal: _hScroll,
                      vertical: _vScroll,
                      viewport: constraints.biggest,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A click on the preview at [point] (engraving units): to where what is drawn there is written.
  void _clicked(LilyPondDrawing drawing, Offset point) {
    const near = 4 * LilyPondScore.unit;
    final staff = drawing.score.engraving.staves
        .where((s) => point.dy >= s.top - near && point.dy <= s.top + s.height + near)
        .fold<StaffInfo?>(null, (best, s) => best == null || (point.dy - s.top).abs() < (point.dy - best.top).abs() ? s : best);
    final link = drawing.score.linkAt(point, staff: staff?.n ?? 0);
    if (link != null) _goTo(link.file, link.line, link.column);
  }

  /// LilyPond's problems with the latest engraving: errors first.
  List<LilyProblem> get _problems => [
        ...?_run?.problems.where((p) => p.error),
        ...?_run?.problems.where((p) => !p.error),
      ];

  Widget _problemList(BuildContext context) {
    final colors = context.colors, problems = _problems;
    const row = 26.0;
    return Container(
      height: math.min(problems.length, 5) * row + 8,
      color: colors.chrome,
      child: ListView(padding: const EdgeInsets.symmetric(vertical: 4), itemExtent: row, children: [
        for (final p in problems)
          InkWell(
            onTap: p.line == null ? null : () => _goTo(p.file, p.line!, (p.column ?? 1) - 1),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Icon((p.error ? AppIcon.failed : AppIcon.warning).of(context),
                    size: 15, color: p.error ? Theme.of(context).colorScheme.error : const Color(0xFFD08A1E)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(describeLilyProblem(p),
                      overflow: TextOverflow.ellipsis, style: monospace.copyWith(fontSize: 12.5, color: colors.text)),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Draws the score LilyPond engraved, of it what the preview shows (scrolled to [horizontal] and
/// [vertical]), [marked] under it.
class _PreviewPainter extends CustomPainter {
  _PreviewPainter({
    required this.drawing,
    required this.extent,
    required this.ink,
    required this.mark,
    required this.marked,
    required this.horizontal,
    required this.vertical,
    required this.viewport,
  }) : super(repaint: Listenable.merge([horizontal, vertical, marked]));

  final LilyPondDrawing drawing;
  final Rect extent;
  final Color ink, mark;
  final ValueListenable<List<Rect>> marked;
  final ScrollController horizontal, vertical;
  final Size viewport;

  static const _scale = _LilyPondEditorState._scale;

  @override
  void paint(Canvas canvas, Size size) {
    final x = horizontal.hasClients ? horizontal.offset : 0.0, y = vertical.hasClients ? vertical.offset : 0.0;
    final visible = Rect.fromLTWH(extent.left + x / _scale, extent.top + y / _scale, viewport.width / _scale, viewport.height / _scale);
    canvas
      ..save()
      ..scale(_scale)
      ..translate(-extent.left, -extent.top);
    final paint = Paint()..color = mark;
    const pad = LilyPondScore.unit * 0.35;
    for (final r in marked.value) {
      if (r.overlaps(visible)) canvas.drawRRect(RRect.fromRectAndRadius(r.inflate(pad), const Radius.circular(pad)), paint);
    }
    drawing.paint(canvas, visible.inflate(2 * LilyPondScore.unit), ink);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PreviewPainter old) =>
      old.drawing != drawing || old.ink != ink || old.mark != mark || old.viewport != viewport || old.extent != extent;
}

/// What can be typed where the caret is ([LilyPondPrompts]), the chosen one marked: ↑ and ↓
/// choose, Return or a click puts it in.
class _PromptList extends StatefulWidget implements PreferredSizeWidget {
  const _PromptList({required this.notifier, required this.onSelected});
  final ValueNotifier<CodeAutocompleteEditingValue> notifier;
  final ValueChanged<CodeAutocompleteResult> onSelected;

  static const _row = 24.0, _rows = 8;

  @override
  /// Its rows, the list's padding (4 above and below) and its border's (1).
  Size get preferredSize => Size(300, math.min(notifier.value.prompts.length, _rows) * _row + 10);

  @override
  State<_PromptList> createState() => _PromptListState();
}

class _PromptListState extends State<_PromptList> {
  /// What [kind] of word one offered is, as shown beside it: LilyPond's own terms.
  static String _kind(LilyPondKind kind) => switch (kind) {
        LilyPondKind.context => 'context'.trIn('lilypond'),
        LilyPondKind.clef => 'clef'.trIn('lilypond'),
        LilyPondKind.repeat => 'repeat'.trIn('lilypond'),
        LilyPondKind.barline => 'barline'.trIn('lilypond'),
        LilyPondKind.language => 'language'.trIn('lilypond'),
        LilyPondKind.property => 'property'.trIn('lilypond'),
        LilyPondKind.grob => 'grob'.trIn('lilypond'),
        LilyPondKind.variable => 'variable'.trIn('lilypond'),
        LilyPondKind.command => 'command'.trIn('lilypond'),
      };

  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(_moved);
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_moved);
    _scroll.dispose();
    super.dispose();
  }

  void _moved() {
    if (!mounted) return;
    setState(() {});
    if (!_scroll.hasClients) return;
    final top = widget.notifier.value.index * _PromptList._row, view = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _PromptList._row > _scroll.offset + view) {
      _scroll.jumpTo(top + _PromptList._row - view);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, value = widget.notifier.value, dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: widget.preferredSize.width,
      height: widget.preferredSize.height,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: AppStyle.of(context).radius(6),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4))],
      ),
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(4),
        itemExtent: _PromptList._row,
        itemCount: value.prompts.length,
        itemBuilder: (context, i) {
          final prompt = value.prompts[i], chosen = i == value.index;
          // The chosen one in the accent's light tint, as a sidebar's chosen row.
          final ink = chosen ? colors.accentOn(colors.accentSoft, dark: dark) : colors.text;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onSelected(value.copyWith(index: i).autocomplete),
            child: Container(
              decoration: BoxDecoration(color: chosen ? colors.accentSoft : null, borderRadius: BorderRadius.circular(4)),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                Expanded(child: Text(prompt.word, overflow: TextOverflow.ellipsis, style: monospace.copyWith(fontSize: 13, color: ink))),
                if (prompt is LilyPondPrompt)
                  Text(_kind(prompt.kind), style: TextStyle(fontSize: 11.5, color: chosen ? ink.withValues(alpha: 0.75) : colors.textMuted)),
              ]),
            ),
          );
        },
      ),
    );
  }
}

/// Find (⌘F), and Replace (⌥⌘F): over the code at its top right; Return finds the next, Esc
/// closes it.
class _FindBar extends StatelessWidget implements PreferredSizeWidget {
  const _FindBar({required this.controller, required this.readOnly});
  final CodeFindController controller;
  final bool readOnly;

  static const _row = 38.0;

  @override
  Size get preferredSize => Size(double.infinity, switch (controller.value) {
        null => 0,
        final v when v.replaceMode && !readOnly => _row * 2,
        _ => _row,
      });

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    if (value == null) return const SizedBox.shrink();
    final colors = context.colors;
    final result = value.result;
    final count = value.option.pattern.isEmpty
        ? ''
        : result == null || result.matches.isEmpty
            ? 'No matches'.tr
            : '{n} of {all}'.fill({'n': result.index + 1, 'all': result.matches.length});
    // Return the next match (or, replacing, replaces it), ⇧Return the one before; Esc closes.
    Widget field(TextEditingController text, FocusNode focus, String hint, VoidCallback onSubmitted, {VoidCallback? back}) => SizedBox(
          width: 240,
          height: 28,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): controller.close,
              if (back != null) ...{
                const SingleActivator(LogicalKeyboardKey.enter, shift: true): back,
                const SingleActivator(LogicalKeyboardKey.numpadEnter, shift: true): back,
              },
            },
            child: TextField(
              controller: text,
              focusNode: focus,
              style: monospace.copyWith(fontSize: 13, color: colors.text),
              onSubmitted: (_) => onSubmitted(),
              decoration: InputDecoration(
                isDense: true,
                hintText: hint,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                border: OutlineInputBorder(borderRadius: AppStyle.of(context).radius(4)),
              ),
            ),
          ),
        );
    return Container(
      height: preferredSize.height,
      decoration: BoxDecoration(color: colors.chrome, border: Border(bottom: BorderSide(color: colors.line))),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(children: [
        SizedBox(
          height: _row,
          child: Row(children: [
            field(controller.findInputController, controller.findInputFocusNode, 'Find'.tr, () {
              controller.nextMatch();
              controller.findInputFocusNode.requestFocus();
            }, back: controller.previousMatch),
            const SizedBox(width: 8),
            Text(count, style: TextStyle(fontSize: 12, color: colors.textMuted)),
            const Spacer(),
            ToolbarButton(
                icon: AppIcon.previous.of(context),
                tooltip: 'Previous ({key})'.fill({'key': shortcut('⇧↩', 'Shift+Enter')}),
                onPressed: result == null ? null : controller.previousMatch),
            ToolbarButton(
                icon: AppIcon.next.of(context),
                tooltip: 'Next ({key})'.fill({'key': shortcut('↩', 'Enter')}),
                onPressed: result == null ? null : controller.nextMatch),
            if (!readOnly) ToolbarButton(icon: AppIcon.more.of(context), tooltip: 'Replace'.tr, onPressed: controller.toggleMode),
            ToolbarButton(icon: AppIcon.close.of(context), tooltip: 'Close'.tr, onPressed: controller.close),
          ]),
        ),
        if (value.replaceMode && !readOnly)
          SizedBox(
            height: _row,
            child: Row(children: [
              field(controller.replaceInputController, controller.replaceInputFocusNode, 'Replace'.tr, controller.replaceMatch),
              const SizedBox(width: 8),
              TextButton(onPressed: result == null ? null : controller.replaceMatch, child: Text('Replace'.tr)),
              TextButton(onPressed: result == null ? null : controller.replaceAllMatches, child: Text('Replace All'.tr)),
            ]),
          ),
      ]),
    );
  }
}
