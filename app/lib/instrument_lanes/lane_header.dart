part of '../timeline_panel.dart';

/// What a lane's ⋯ menu offers.
enum _LaneAction {
  rename('Rename…'),
  spacing('Spacing…'),
  split('Split Lane'), // an instrument on several staves: a lane a staff
  join('Join Lanes'), // a staff's lane: its instrument's one again
  spacer('Edit Spacer…'), // a vertical spacer's lane: its dialog names it too
  removeSpacer('Remove Spacer'),
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

  /// The instrument the lane is: its own, or (a staff's lane) the one split.
  ScorePart get instrument =>
      _staffLane ? controller.score!.metadata.parts.firstWhere((p) => p.id == controller.instrumentOfLane(part.id)) : part;
  bool get _staffLane => Curation.staffOfLane(part.id) != null;
  Offset? _downAt;
  final _clicks = DoubleClicks();

  void _down(PointerDownEvent e) => _downAt = e.buttons == kPrimaryButton ? e.position : null;

  /// A click, handled as the button comes up (not after waiting to see whether a second click
  /// follows), so clicking through lanes one after another keeps up. Not after a hold, which
  /// moved the lane, nor after the pointer wandered off.
  void _up(PointerUpEvent e) {
    final down = _downAt;
    _downAt = null;
    if (down == null || widget.lifted || (e.position - down).distance > 6) return;
    final doubleClick = _clicks.press(e.timeStamp, e.position);
    if (doubleClick && controller.spacers.verticalOf(part.id) != null) {
      showVerticalSpacerDialog(context, controller, part.id);
    } else if (doubleClick && controller.condensedGroupOf(part.id) == null) {
      showRenameDialog(context, controller, instrument);
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
        showRenameDialog(context, controller, instrument);
      case _LaneAction.split:
        controller.setSplit(part.id, on: true);
      case _LaneAction.join:
        controller.setSplit(controller.instrumentOfLane(part.id), on: false);
      case _LaneAction.spacer:
        showVerticalSpacerDialog(context, controller, part.id);
      case _LaneAction.spacing:
        showSpacingDialog(context, controller, part);
      case _LaneAction.removeSpacer:
        controller.spacers.removeVertical(part.id);
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

  /// What the lane's ⋯ (or a right click on its name) offers.
  List<PopupMenuEntry<_LaneAction>> _items(BuildContext context) {
    PopupMenuItem<_LaneAction> item(BuildContext context, _LaneAction a) =>
        menuItem(context, value: a, child: Text(a.label.tr));
    final group = controller.condensedGroupOf(part.id);
    final spacer = controller.spacers.verticalOf(part.id) != null;
    return [
      // A pair's lane names both players: each is renamed on its own, as on its own staff.
      if (group case final group?) ...[
        menuItem(context, value: _LaneAction.renameFirst, child: Text('Rename {name}…'.fill({'name': controller.partNameOf(group.first)}))),
        menuItem(context, value: _LaneAction.renameSecond, child: Text('Rename {name}…'.fill({'name': controller.partNameOf(group.second)}))),
      ] else if (spacer) ...[
        item(context, _LaneAction.spacer),
        item(context, _LaneAction.removeSpacer),
      ] else ...[
        menuItem(context,
            value: _LaneAction.rename,
            child: Text(_staffLane ? 'Rename {name}…'.fill({'name': controller.partName(instrument)}) : 'Rename…'.tr)),
        item(context, _LaneAction.spacing),
        if (_staffLane) item(context, _LaneAction.join) else if (controller.canSplit(part.id)) item(context, _LaneAction.split),
      ],
      menuDivider(context),
      item(context, _LaneAction.select),
      item(context, _LaneAction.copy),
      menuDivider(context),
      item(context, _LaneAction.showThroughout),
      if (!spacer) item(context, _LaneAction.autoCurate), // nothing plays in it
      item(context, _LaneAction.clear),
      menuDivider(context),
      item(context, _LaneAction.moveToTop),
      item(context, _LaneAction.moveToBottom),
      if (!controller.isScoreOrder) item(context, _LaneAction.scoreOrder),
    ];
  }

  /// A right click on the name: the lane's menu, where it was clicked.
  Future<void> _contextMenu(Offset global) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final style = AppStyle.of(context);
    final action = await showMenu<_LaneAction>(
      context: context,
      position: RelativeRect.fromRect(overlay.globalToLocal(global) & const Size(1, 1), Offset.zero & overlay.size),
      popUpAnimationStyle: AnimationStyle(
          duration: style.menuOpen, reverseDuration: style.menuClose, curve: style.enterCurve, reverseCurve: style.exitCurve),
      items: _items(context),
    );
    if (action != null && mounted) _run(context, action);
  }

  @override
  Widget build(BuildContext context) {
    final group = controller.condensedGroupOf(part.id);
    final condensed = group != null, spacer = controller.spacers.verticalOf(part.id) != null;
    final menu = OverlaySemantics(
      child: AppPopupMenuButton<_LaneAction>(
        tooltip: 'Lane options'.tr,
        padding: EdgeInsets.zero,
        iconSize: 16,
        icon: Icon(AppIcon.more.of(context), color: context.colors.textMuted),
        onSelected: (action) => _run(context, action),
        itemBuilder: _items,
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
            message: '{names}: one lane'.fill({'names': group.partIds.map(controller.partNameOf).join(' and '.tr)}),
            child: Icon(AppIcon.link.of(context), size: 14, color: context.colors.textMuted),
          ),
        if (spacer)
          Tip(message: 'Spacer'.tr, child: Icon(AppIcon.verticalSpacer.of(context), size: 14, color: context.colors.textMuted)),
        menu,
      ]),
      child: Listener(
        onPointerDown: _down,
        onPointerUp: _up,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTapUp: (d) => _contextMenu(d.globalPosition),
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
