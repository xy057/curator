import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// A toolbar's items in a row that never runs past its width: each as wide as it likes,
/// centred, [spacing] after it; the room left over shared among those that are spaces
/// ([StripItem.space]). When
/// they don't all fit, the last ones are left out (laid out still, so they come back as the
/// window widens, but not drawn, hit or read) and [more], the button at the right end, shows:
/// [onFit] says how many are on the bar, so its menu can hold the rest. [showMore] keeps the
/// button there with everything fitting (its menu has items of its own).
///
/// A rule ([StripItem.rule]) shows only between items, of those between two spaces: not first or
/// last there, nor after another with nothing shown between them (an item with nothing to show
/// now takes no room); with [collapse] off, they all show.
///
/// [insertAt] draws a mark before that item (after the last, at their number): where one
/// dragged over the bar would go ([RenderToolbarStrip.placeAt]).
class ToolbarStrip extends MultiChildRenderObjectWidget {
  ToolbarStrip({
    super.key,
    required List<StripItem> items,
    required Widget more,
    required this.onFit,
    this.showMore = false,
    this.collapse = true,
    this.spacing = 2,
    this.insertAt,
    this.markColor = const Color(0xFF000000),
  }) : super(children: [...items, StripItem(child: more)]);

  final ValueChanged<int> onFit;
  final bool showMore, collapse;
  final double spacing;
  final int? insertAt;
  final Color markColor;

  @override
  RenderToolbarStrip createRenderObject(BuildContext context) =>
      RenderToolbarStrip(onFit: onFit, showMore: showMore, collapse: collapse, spacing: spacing, insertAt: insertAt, markColor: markColor);

  @override
  void updateRenderObject(BuildContext context, RenderToolbarStrip renderObject) => renderObject
    ..onFit = onFit
    ..showMore = showMore
    ..collapse = collapse
    ..spacing = spacing
    ..insertAt = insertAt
    ..markColor = markColor;
}

/// An item of a [ToolbarStrip]: as wide as it likes, or, given [space], room to share out:
/// that wide at the least, with its share of what the bar has left over. A [rule] (a divider)
/// is never the last one shown before those left out: it goes with them, as does an item with
/// nothing to show.
class StripItem extends ParentDataWidget<StripParentData> {
  const StripItem({super.key, this.space, this.rule = false, required super.child});
  final double? space;
  final bool rule;

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as StripParentData;
    if (data.least == space && data.rule == rule) return;
    data
      ..least = space
      ..rule = rule;
    renderObject.parent?.markNeedsLayout();
  }

  @override
  Type get debugTypicalAncestorWidgetClass => ToolbarStrip;
}

class StripParentData extends ContainerBoxParentData<RenderBox> {
  /// A space's least width; null for an item as wide as it likes.
  double? least;

  /// Whether it is a rule between groups of items.
  bool rule = false;

  /// Whether the bar has no room for it (or, the button at its end, no use).
  bool hidden = false;

  /// A rule with no item to one side of it: not shown, taking no room.
  bool collapsed = false;
}

class RenderToolbarStrip extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, StripParentData>, RenderBoxContainerDefaultsMixin<RenderBox, StripParentData> {
  RenderToolbarStrip({
    required this.onFit,
    required this._showMore,
    required this._collapse,
    required this._spacing,
    this._insertAt,
    required this._markColor,
  });

  ValueChanged<int> onFit;

  bool get showMore => _showMore;
  bool _showMore;
  set showMore(bool value) {
    if (value == _showMore) return;
    _showMore = value;
    markNeedsLayout();
  }

  bool get collapse => _collapse;
  bool _collapse;
  set collapse(bool value) {
    if (value == _collapse) return;
    _collapse = value;
    markNeedsLayout();
  }

  double get spacing => _spacing;
  double _spacing;
  set spacing(double value) {
    if (value == _spacing) return;
    _spacing = value;
    markNeedsLayout();
  }

  int? get insertAt => _insertAt;
  int? _insertAt;
  set insertAt(int? value) {
    if (value == _insertAt) return;
    _insertAt = value;
    markNeedsPaint();
  }

  Color get markColor => _markColor;
  Color _markColor;
  set markColor(Color value) {
    if (value == _markColor) return;
    _markColor = value;
    markNeedsPaint();
  }

  /// How many items the bar has room for, as last laid out and as last told ([onFit]).
  int _fit = 0;
  int? _told;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! StripParentData) child.parentData = StripParentData();
  }

  static StripParentData _data(RenderBox child) => child.parentData! as StripParentData;

  /// The items, without the button at the end.
  List<RenderBox> get _items => [
        for (var child = firstChild; child != null && child != lastChild; child = childAfter(child)) child,
      ];

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    final width = constraints.maxWidth, height = constraints.maxHeight;
    size = constraints.biggest;
    final more = lastChild;
    if (more == null) return;
    final items = _items, loose = BoxConstraints(maxHeight: height);
    more.layout(loose, parentUsesSize: true);
    // What each takes of the bar: its width and the gap after it; a space, its least.
    final takes = <double>[];
    for (final item in items) {
      final least = _data(item).least;
      if (least != null) {
        takes.add(least);
      } else {
        item.layout(loose, parentUsesSize: true);
        takes.add(item.size.width > 0 ? item.size.width + spacing : 0);
      }
    }
    // A rule shows between two items that do, of those between two spaces.
    int? rule; // one since the last item shown: shown once another item follows
    var open = false; // whether an item has shown since the last space
    for (final (i, item) in items.indexed) {
      final data = _data(item)..collapsed = false;
      if (!collapse) continue;
      if (data.rule) {
        data.collapsed = true;
        if (open) rule ??= i;
      } else if (data.least != null) {
        open = false;
        rule = null;
      } else if (takes[i] > 0) {
        if (rule != null) _data(items[rule]).collapsed = false;
        open = true;
        rule = null;
      }
    }
    for (final (i, item) in items.indexed) {
      if (_data(item).collapsed) takes[i] = 0;
    }
    var fit = items.length, used = takes.fold(0.0, (sum, w) => sum + w), withMore = showMore;
    if (used + (withMore ? more.size.width : 0) > width) {
      withMore = true;
      while (fit > 0 && (used + more.size.width > width || _data(items[fit - 1]).rule || takes[fit - 1] == 0)) {
        used -= takes[--fit];
      }
    }
    final room = width - (withMore ? more.size.width : 0);
    final spaces = [for (final item in items.take(fit)) if (_data(item).least != null) item].length;
    final share = spaces == 0 ? 0.0 : math.max(0.0, room - used) / spaces;
    var x = 0.0;
    for (final (i, item) in items.indexed) {
      final data = _data(item)..hidden = i >= fit;
      if (data.least case final least?) {
        item.layout(BoxConstraints(minWidth: data.hidden ? 0 : least + share, maxWidth: data.hidden ? 0 : least + share, maxHeight: height), parentUsesSize: true);
      }
      data.offset = Offset(x, (height - item.size.height) / 2);
      if (!data.hidden) x += data.least != null ? item.size.width : takes[i];
    }
    _data(more)
      ..hidden = !withMore
      ..offset = Offset(width - more.size.width, (height - more.size.height) / 2);
    _fit = fit;
    if (fit != _told) {
      // Told after the frame: what hears it builds the menu again.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!attached || _fit == _told) return;
        onFit(_told = _fit);
      });
    }
  }

  /// Where an item dragged to [x] (in the bar) would go: before the first item whose middle is
  /// at its right, among those shown.
  int placeAt(double x) {
    final items = _items;
    for (final (i, item) in items.indexed) {
      final data = _data(item);
      if (data.hidden) return i;
      if (!data.collapsed && x < data.offset.dx + item.size.width / 2) return i;
    }
    return items.length;
  }

  /// The item at [position] (in the bar), by its place; null over none.
  int? itemAt(Offset position) {
    for (final (i, item) in _items.indexed) {
      final data = _data(item);
      if (!data.hidden && !data.collapsed && (data.offset & item.size).contains(position)) return i;
    }
    return null;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (var child = lastChild; child != null; child = childBefore(child)) {
      final data = _data(child);
      if (data.hidden || data.collapsed) continue;
      final hit = result.addWithPaintOffset(
        offset: data.offset,
        position: position,
        hitTest: (result, transformed) => child!.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = _data(child);
      if (!data.hidden && !data.collapsed) context.paintChild(child, data.offset + offset);
    }
    final at = insertAt;
    if (at == null) return;
    final items = _items, shown = [for (final item in items) if (!_data(item).hidden) item];
    final double x;
    if (shown.isEmpty) {
      x = 1;
    } else if (at < shown.length) {
      x = _data(shown[at]).offset.dx - spacing / 2;
    } else {
      x = _data(shown.last).offset.dx + shown.last.size.width + spacing / 2;
    }
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(offset.dx + x.clamp(1, size.width - 1) - 1, offset.dy + 4, 2, size.height - 8), const Radius.circular(1)),
      Paint()..color = markColor,
    );
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      if (!_data(child).hidden && !_data(child).collapsed) visitor(child);
    }
  }
}
