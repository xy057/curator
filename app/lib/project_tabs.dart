import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show kMiddleMouseButton;
import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'l10n/l10n.dart';
import 'ui_kit.dart';

/// What a project's tab says: its name, whether it has unsaved changes, and its file (the tip).
typedef ProjectTabLabel = ({String name, bool edited, String? path});

/// The tabs along the top of the window while a project is open: Home first (an icon), then each
/// project open by its name. A click shows one; its ×, or a middle click, closes it. Unsaved
/// changes are a dot where the × goes, which the × takes over under the pointer.
class ProjectTabs extends StatelessWidget {
  const ProjectTabs({
    super.key,
    required this.labels,
    required this.shown,
    required this.onShow,
    required this.onClose,
  });

  /// The projects' tabs, in order.
  final List<ValueListenable<ProjectTabLabel>> labels;

  /// The tab showing: an index into [labels], or null for Home.
  final int? shown;
  final ValueChanged<int?> onShow;
  final ValueChanged<int> onClose;

  static double heightOf(BuildContext context) => AppStyle.of(context).control + 4;

  static const _minWidth = 110.0, _maxWidth = 220.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final height = heightOf(context);
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
                final width = (constraints.maxWidth / labels.length).clamp(_minWidth, _maxWidth);
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final (i, label) in labels.indexed)
                      ValueListenableBuilder(
                        valueListenable: label,
                        builder: (context, label, _) => SizedBox(
                          width: width,
                          child: _Tab(
                            selected: shown == i,
                            fill: colors.chrome,
                            tip: label.path ?? label.name,
                            onShow: () => onShow(i),
                            onClose: () => onClose(i),
                            edited: label.edited,
                            child: Text(label.name, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false),
                          ),
                        ),
                      ),
                  ]),
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
    this.edited = false,
  });

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
    final tab = AnimatedContainer(
      duration: stateDuration(motion(context, 120)),
      height: height,
      padding: EdgeInsets.only(left: onClose == null ? 0 : 12, right: onClose == null ? 0 : 6),
      constraints: onClose == null ? BoxConstraints.tightFor(width: height + 8) : null,
      decoration: BoxDecoration(
        color: selected
            ? widget.fill
            : _hover
                ? (dark ? Colors.white : Colors.black).withValues(alpha: dark ? 0.06 : 0.04)
                : Colors.transparent,
        border: Border(left: side, right: side),
      ),
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
            child: tab,
          ),
        ),
      ),
    );
  }
}
