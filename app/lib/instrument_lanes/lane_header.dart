part of '../timeline_panel.dart';

/// What a lane's ⋯ menu offers.
enum _LaneAction {
  rename('Rename…'),
  renameFirst('Rename…'), // a condensed pair's lane: one player, or the other (named in the menu)
  renameSecond('Rename…'),
  select('Select All in Lane'),
  copy('Copy Lane To…'),
  showThroughout('Show Throughout'),
  autoCurate('Auto-Curate Lane'),
  clear('Clear Lane'),
  moveToTop('Move to Top'),
  moveToBottom('Move to Bottom'),
  scoreOrder('Restore Score Order');

  const _LaneAction(this.label);
  final String label;
}

class _LaneHeader extends StatefulWidget {
  const _LaneHeader({
    required this.controller,
    required this.part,
    required this.selected,
    required this.hovered,
    required this.onHover,
    required this.lifted,
    required this.onLift,
    required this.onDrag,
    required this.onDrop,
    required this.onCancel,
  });
  final EditorController controller;
  final ScorePart part;
  final bool selected;

  /// Under the mouse, or selected with the lane that is (the selection lights up as one).
  final bool hovered;
  final ValueChanged<bool> onHover;

  /// Held (click and hold on the name) and being moved to another place.
  final bool lifted;
  final void Function(Offset global) onLift, onDrag;
  final VoidCallback onDrop;

  /// The system took the pointer while it was held: the lane goes back.
  final VoidCallback onCancel;

  @override
  State<_LaneHeader> createState() => _LaneHeaderState();
}

class _LaneHeaderState extends State<_LaneHeader> {
  EditorController get controller => widget.controller;
  ScorePart get part => widget.part;
  Offset? _downAt;
  Duration? _lastClick;

  void _down(PointerDownEvent e) => _downAt = e.buttons == kPrimaryButton ? e.position : null;

  /// A click, handled as the button comes up (not after waiting to see whether a second click
  /// follows), so clicking through lanes one after another keeps up. Not after a hold, which
  /// moved the lane, nor after the pointer wandered off.
  void _up(PointerUpEvent e) {
    final down = _downAt;
    _downAt = null;
    if (down == null || widget.lifted || (e.position - down).distance > 6) return;
    final last = _lastClick;
    final doubleClick = last != null && e.timeStamp - last < const Duration(milliseconds: 350);
    _lastClick = doubleClick ? null : e.timeStamp;
    if (doubleClick && controller.condensedGroupOf(part.id) == null) {
      showRenameDialog(context, controller, part);
    } else if (isCommandPressed) {
      controller.lanes.selectLaneRange(part.id);
    } else {
      controller.lanes.selectLane(part.id, add: HardwareKeyboard.instance.isShiftPressed);
    }
  }

  void _run(BuildContext context, _LaneAction action) {
    final lanes = controller.lanes;
    switch (action) {
      case _LaneAction.rename:
        showRenameDialog(context, controller, part);
      case _LaneAction.renameFirst || _LaneAction.renameSecond:
        final group = controller.condensedGroupOf(part.id)!;
        final id = action == _LaneAction.renameFirst ? group.first : group.second;
        showRenameDialog(context, controller, controller.score!.metadata.parts.firstWhere((p) => p.id == id));
      case _LaneAction.select:
        lanes.selectLane(part.id);
      case _LaneAction.copy:
        showCopyLaneDialog(context, controller, part);
      case _LaneAction.showThroughout:
        lanes.showThroughout(part.id);
      case _LaneAction.autoCurate:
        lanes.autoCurate([part.id]);
      case _LaneAction.clear:
        lanes.clear([part.id]);
      case _LaneAction.moveToTop:
        controller.moveLane(part.id, 0);
      case _LaneAction.moveToBottom:
        controller.moveLane(part.id, controller.laneParts.length - 1);
      case _LaneAction.scoreOrder:
        controller.restoreScoreOrder();
    }
  }

  @override
  Widget build(BuildContext context) {
    PopupMenuItem<_LaneAction> item(BuildContext context, _LaneAction a) =>
        menuItem(context, value: a, child: Text(a.label));
    final group = controller.condensedGroupOf(part.id);
    final condensed = group != null;
    final menu = OverlaySemantics(
      child: AppPopupMenuButton<_LaneAction>(
        tooltip: 'Lane options',
        padding: EdgeInsets.zero,
        iconSize: 16,
        icon: Icon(Icons.more_horiz, color: context.colors.textMuted),
        onSelected: (action) => _run(context, action),
        itemBuilder: (context) => [
          // A pair's lane names both players: each is renamed on its own, as on its own staff.
          if (group case final group?) ...[
            menuItem(context, value: _LaneAction.renameFirst, child: Text('Rename ${controller.partNameOf(group.first)}…')),
            menuItem(context, value: _LaneAction.renameSecond, child: Text('Rename ${controller.partNameOf(group.second)}…')),
          ] else
            item(context, _LaneAction.rename),
          menuDivider(context),
          item(context, _LaneAction.select),
          item(context, _LaneAction.copy),
          menuDivider(context),
          item(context, _LaneAction.showThroughout),
          item(context, _LaneAction.autoCurate),
          item(context, _LaneAction.clear),
          menuDivider(context),
          item(context, _LaneAction.moveToTop),
          item(context, _LaneAction.moveToBottom),
          if (!controller.isScoreOrder) item(context, _LaneAction.scoreOrder),
        ],
      ),
    );
    final colors = context.colors;
    final label = LaneLabel(
      height: _laneHeight,
      color: widget.lifted
          ? colors.accentSoft
          : widget.selected
              ? widget.hovered
                  ? Color.alphaBlend(colors.accent.withValues(alpha: 0.14), colors.accentSoft)
                  : colors.accentSoft
              : widget.hovered
                  ? colors.accentWash
                  : colors.surface.withValues(alpha: 0),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (condensed)
          Tip(
            message: '${group.partIds.map(controller.partNameOf).join(' and ')}: one lane',
            child: Icon(Icons.link_rounded, size: 14, color: context.colors.textMuted),
          ),
        menu,
      ]),
      child: Listener(
        onPointerDown: _down,
        onPointerUp: _up,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (d) => widget.onLift(d.globalPosition),
          onLongPressMoveUpdate: (d) => widget.onDrag(d.globalPosition),
          onLongPressEnd: (_) => widget.onDrop(),
          onLongPressCancel: widget.onCancel,
          child: Text(controller.laneName(part)),
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => widget.onHover(true),
      onExit: (_) => widget.onHover(false),
      child: label,
    );
  }
}
