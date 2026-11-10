import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show GestureBinding, PointerScrollEvent, PointerSignalEvent, kMiddleMouseButton;
import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'l10n/l10n.dart';
import 'ui_kit.dart';

/// What a project's tab says: its name, whether it has unsaved changes, and its file (the tip).
typedef ProjectTabLabel = ({String name, bool edited, String? path});

/// The tabs along the top of the window while a project is open: Home first (an icon), then each
/// project open by its name. A click shows one; its ×, or a middle click, closes it; dragged, it
/// changes places with the tabs it passes. Unsaved
/// changes are a dot where the × goes, which the × takes over under the pointer. Past the
/// window's width they scroll, under a mouse wheel too, and to the tab showing when another does.
class ProjectTabs extends StatefulWidget {
  const ProjectTabs({
    super.key,
    required this.labels,
    required this.shown,
    required this.onShow,
    required this.onClose,
    this.onMove,
  });

  /// The projects' tabs, in order.
  final List<ValueListenable<ProjectTabLabel>> labels;

  /// The tab showing: an index into [labels], or null for Home.
  final int? shown;
  final ValueChanged<int?> onShow;
  final ValueChanged<int> onClose;

  /// A project's tab dragged along the strip, from one place among [labels] to another; null:
  /// they stay as they are.
  final void Function(int from, int to)? onMove;

  static double heightOf(BuildContext context) => AppStyle.of(context).control + 4;

  static const _minWidth = 110.0, _maxWidth = 220.0;

  @override
  State<ProjectTabs> createState() => _ProjectTabsState();
}

class _ProjectTabsState extends State<ProjectTabs> {
  final _scroll = ScrollController();

  /// How wide each project's tab is laid out.
  double _tabWidth = ProjectTabs._minWidth;

  // MARK: Dragging a tab

  final _row = GlobalKey();

  /// The tab held, and where its left edge is dragged to (in the row of tabs).
  ValueListenable<ProjectTabLabel>? _held;
  double _heldLeft = 0;
  double _grab = 0; // from the tab's left edge to the pointer

  /// How far the held tab is drawn from its place, following the pointer.
  double _offsetOf(int index) => _heldLeft - index * _tabWidth;

  /// Tabs slide to their places: while one is held, and as it settles once let go. Not
  /// otherwise (a window resized lays them out at once).
  bool _sliding = false;
  Timer? _settled;

  void _dragStart(int index, DragStartDetails d) {
    widget.onShow(index); // the tab dragged shows, as one clicked does
    _settled?.cancel();
    setState(() {
      _sliding = true;
      _held = widget.labels[index];
      _grab = d.localPosition.dx;
      _heldLeft = index * _tabWidth;
    });
  }

  void _dragUpdate(DragUpdateDetails d) {
    final held = _held, row = _row.currentContext?.findRenderObject() as RenderBox?;
    final index = held == null ? -1 : widget.labels.indexOf(held);
    if (index < 0 || row == null) return;
    final last = widget.labels.length - 1;
    setState(() => _heldLeft = (row.globalToLocal(d.globalPosition).dx - _grab).clamp(0.0, last * _tabWidth));
    // Past the middle of the tab beside it: they change places (the strip is built again in
    // the new order, the held tab still under the pointer).
    final offset = _offsetOf(index);
    if (offset > _tabWidth / 2 && index < last) widget.onMove?.call(index, index + 1);
    if (offset < -_tabWidth / 2 && index > 0) widget.onMove?.call(index, index - 1);
  }

  void _dragEnd() {
    setState(() => _held = null);
    _settled = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _sliding = false);
    });
  }

  @override
  void dispose() {
    _settled?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // Another tab shows (one just opened is the last, Show Next Tab goes round): past the
  // window's width, the strip scrolls to it.
  @override
  void didUpdateWidget(ProjectTabs old) {
    super.didUpdateWidget(old);
    if (widget.shown == old.shown && widget.labels.length == old.labels.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  /// Scrolls just far enough that the tab showing is all in view.
  void _reveal() {
    final shown = widget.shown;
    if (!mounted || shown == null || !_scroll.hasClients) return;
    final position = _scroll.position;
    final left = shown * _tabWidth, right = left + _tabWidth;
    final to = left < position.pixels
        ? left
        : right > position.pixels + position.viewportDimension
            ? right - position.viewportDimension
            : null;
    if (to == null) return;
    final target = to.clamp(position.minScrollExtent, position.maxScrollExtent);
    final duration = motion(context, 220);
    if (duration == Duration.zero) {
      position.jumpTo(target);
    } else {
      position.animateTo(target, duration: duration, curve: AppStyle.of(context).curve);
    }
  }

  /// A wheel turns up and down, and the tabs run across: its turn scrolls them. (A sideways
  /// scroll, a trackpad's or a tilted wheel's, the scroll view takes itself, first.)
  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    final position = _scroll.position, delta = event.scrollDelta.dy;
    if (delta == 0 || position.maxScrollExtent == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) => position.pointerScroll(delta));
  }

  @override
  Widget build(BuildContext context) {
    final ProjectTabs(:labels, :shown, :onShow, :onClose) = widget;
    final colors = context.colors;
    final height = ProjectTabs.heightOf(context);
    return SizedBox(
      height: height,
      // Above the pages' scaffolds: its own material, for its text and buttons.
      child: Material(
        color: colors.well,
        child: Stack(children: [
          // Under every tab but the one showing, which covers it: that one runs on into its page.
          Positioned(left: 0, right: 0, bottom: 0, child: Divider(height: 1, thickness: 1, color: colors.line)),
          Row(children: [
            _Tab(
              selected: shown == null,
              // Home's page: the window's own background, where the editor's is its toolbar.
              fill: Theme.of(context).scaffoldBackgroundColor,
              tip: 'Home'.tr,
              onShow: () => onShow(null),
              child: Icon(AppIcon.home.of(context), size: 16),
            ),
            Expanded(
              child: LayoutBuilder(builder: (context, constraints) {
                final width = (constraints.maxWidth / labels.length).clamp(ProjectTabs._minWidth, ProjectTabs._maxWidth);
                _tabWidth = width;
                return Listener(
                  onPointerSignal: _wheel,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    // Each tab at its place; the one held follows the pointer, over the others
                    // (drawn last), which slide aside as it passes them.
                    child: SizedBox(
                      key: _row,
                      width: labels.length * width,
                      height: height,
                      child: Stack(children: [
                      for (final (i, label) in [
                        for (final (i, l) in labels.indexed)
                          if (!identical(l, _held)) (i, l),
                        for (final (i, l) in labels.indexed)
                          if (identical(l, _held)) (i, l),
                      ])
                        // Keyed: a tab closed takes its own hover with it, and one dragged past
                        // another keeps its drag.
                        AnimatedPositioned(
                          key: ObjectKey(label),
                          duration: _sliding && !identical(label, _held) ? motion(context, 180) : Duration.zero,
                          curve: Curves.easeOutCubic,
                          left: identical(label, _held) ? _heldLeft : i * width,
                          top: 0,
                          bottom: 0,
                          child: ValueListenableBuilder(
                            valueListenable: label,
                            builder: (context, label, _) => SizedBox(
                              width: width,
                              child: _Tab(
                                selected: shown == i,
                                fill: colors.chrome,
                                tip: label.path ?? label.name,
                                onShow: () => onShow(i),
                                onClose: () => onClose(i),
                                onDragStart: widget.onMove == null || labels.length < 2 ? null : (d) => _dragStart(i, d),
                                onDragUpdate: _dragUpdate,
                                onDragEnd: _dragEnd,
                                edited: label.edited,
                                child: Text(label.name, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false),
                              ),
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ),
                );
              }),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _Tab extends StatefulWidget {
  const _Tab({
    required this.selected,
    required this.fill,
    required this.tip,
    required this.onShow,
    required this.child,
    this.onClose,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.edited = false,
  });

  /// Dragged along the strip, to another place in it; null: it stays where it is.
  final GestureDragStartCallback? onDragStart;
  final GestureDragUpdateCallback? onDragUpdate;
  final VoidCallback? onDragEnd;

  final bool selected;

  /// Its colour while selected: the page under it.
  final Color fill;

  /// Under the pointer, as it is (translated already, or a file's path).
  final String tip;
  final VoidCallback onShow;

  /// Null: it can't be closed (Home), and it is as wide as its icon.
  final VoidCallback? onClose;
  final bool edited;
  final Widget child;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final selected = widget.selected;
    final height = ProjectTabs.heightOf(context);
    final onClose = widget.onClose;
    final side = BorderSide(color: selected ? colors.line : Colors.transparent);
    final dark = Theme.of(context).brightness == Brightness.dark;
    // On the label, not around the × with its own too. Not a [Tip]: a file's path isn't translated.
    Widget tip(Widget child) => OverlaySemantics(
          child: Tooltip(message: widget.tip, waitDuration: const Duration(milliseconds: 600), child: child),
        );
    // Selected or not at once: a tab fading out as the other fades in passed through grey (a fill
    // lerped to transparent black), a flash at every switch. Only the pointer's wash fades, in
    // its own colour.
    final wash = (dark ? Colors.white : Colors.black).withValues(alpha: dark ? 0.06 : 0.04);
    final tab = AnimatedContainer(
      duration: stateDuration(motion(context, 120)),
      height: height,
      padding: EdgeInsets.only(left: onClose == null ? 0 : 12, right: onClose == null ? 0 : 6),
      constraints: onClose == null ? BoxConstraints.tightFor(width: height + 8) : null,
      color: _hover && !selected ? wash : wash.withValues(alpha: 0),
      alignment: Alignment.center,
      child: DefaultTextStyle.merge(
        style: TextStyle(fontSize: 12.5, color: selected || _hover ? colors.text : colors.textMuted),
        child: IconTheme.merge(
          data: IconThemeData(color: selected || _hover ? colors.text : colors.textMuted),
          child: onClose == null
              ? tip(widget.child)
              : Row(children: [
                  Expanded(child: tip(widget.child)),
                  const SizedBox(width: 4),
                  SizedBox.square(
                    dimension: 20,
                    child: _hover || selected && !widget.edited
                        // Its tooltip apart from the tab's (see OverlaySemantics).
                        ? OverlaySemantics(child: IconButton(
                            tooltip: 'Close tab ({key})'.fill({'key': shortcut('⌘W')}),
                            onPressed: onClose,
                            iconSize: 12,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints.tightFor(width: 20, height: 20),
                            style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: AppStyle.of(context).radius(4))),
                            icon: Icon(AppIcon.close.of(context)),
                          ))
                        : widget.edited
                            ? Center(
                                child: Container(
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(color: colors.textMuted, shape: BoxShape.circle),
                                ),
                              )
                            : null,
                  ),
                ]),
        ),
      ),
    );
    // A node of its own: merged into the strip's, the tabs' tooltips met in one (see
    // OverlaySemantics) and the semantics tree broke.
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Listener(
          onPointerDown: (e) {
            if (e.buttons == kMiddleMouseButton) onClose?.call();
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onShow,
            supportedDevices: kDragDevices, // a swipe scrolls the strip
            onHorizontalDragStart: widget.onDragStart,
            onHorizontalDragUpdate: widget.onDragStart == null ? null : widget.onDragUpdate,
            onHorizontalDragEnd: widget.onDragStart == null ? null : (_) => widget.onDragEnd?.call(),
            onHorizontalDragCancel: widget.onDragStart == null ? null : widget.onDragEnd,
                child: DecoratedBox(
              decoration: BoxDecoration(
                color: selected ? widget.fill : null,
                border: Border(left: side, right: side),
              ),
              child: tab,
            ),
          ),
        ),
      ),
    );
  }
}
