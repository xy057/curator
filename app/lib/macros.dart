import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart'
    show LaneMacro, LaneScript, MacroAction, MacroFault, MacroLanes, MacroProblem, MacroRange, MacroStep, MacroUnit;

import 'app_colors.dart';
import 'app_icons.dart';
import 'app_settings.dart';
import 'dialog_kit.dart';
import 'editor_controller.dart';
import 'key_bindings.dart';
import 'l10n/l10n.dart';
import 'menu_kit.dart';
import 'toolbar_layout.dart';
import 'ui_kit.dart';

// Macros: curating without writing (see *The lanes can be written*). A macro ([LaneMacro]) is
// steps put together from choices; here are their names, the dialog that puts them together
// ([showMacrosDialog]), the Instruments bar's menu of them ([MacrosMenu]) and what runs one
// ([playMacro]).

/// What a step does, as its choice says it.
String macroActionLabel(MacroAction action) => switch (action) {
      MacroAction.show => 'Show'.tr,
      MacroAction.hide => 'Hide'.tr,
      MacroAction.only => 'Show Only'.tr,
      MacroAction.clear => 'Clear'.tr,
      MacroAction.auto => 'Auto-curate'.tr,
      MacroAction.follow => 'Show Where Playing'.tr,
      MacroAction.fit => 'Fit to Frame'.tr,
      MacroAction.thin => 'Hide Least Important'.tr,
      MacroAction.refill => 'Show Again Where It Fits'.tr,
      MacroAction.lone => 'Remove Lone Bars'.tr,
      MacroAction.bridge => 'Bridge Rests'.tr,
      MacroAction.removeShort => 'Remove Short Regions'.tr,
      MacroAction.transition => 'Set Transition'.tr,
      MacroAction.split => 'Split into Staves'.tr,
      MacroAction.join => 'Join Staves'.tr,
      MacroAction.moveTop => 'Move to Top'.tr,
      MacroAction.moveBottom => 'Move to Bottom'.tr,
      MacroAction.align => 'Align'.tr,
      MacroAction.hear => 'Hear the Recording'.tr,
      MacroAction.match => 'Set Anchors As Heard'.tr,
      MacroAction.snap => 'Snap Anchors to Notes'.tr,
    };

String _lanesLabel(MacroLanes lanes) => switch (lanes) {
      MacroLanes.all => 'All Lanes'.tr,
      MacroLanes.selected => 'Selected Lanes'.tr,
      MacroLanes.others => 'Other Lanes'.tr,
      MacroLanes.named => 'Lanes Named'.tr,
    };

String _rangeLabel(MacroRange range) => switch (range) {
      MacroRange.whole => 'Whole piece'.tr,
      MacroRange.bars => 'Bars'.tr,
      MacroRange.selection => 'Selected Regions'.tr,
      MacroRange.fromPlayhead => 'From the Playhead'.tr,
      MacroRange.untilPlayhead => 'Until the Playhead'.tr,
      MacroRange.playheadBar => 'Bar at the Playhead'.tr,
      MacroRange.ask => 'Ask Each Time'.tr,
    };

/// The examples' names ([LaneMacro.examples], in their order), translated.
List<String> get _exampleNames => ['Auto-curate'.tr, 'Auto-align'.tr, 'Solo from Here'.tr, 'Hide from Here'.tr, 'Show Bars…'.tr, 'Tidy Up'.tr];

String _nameOf(LaneMacro macro) => macro.name.trim().isEmpty ? 'Untitled'.tr : macro.name;

/// A macro's name as shown: its own, or Untitled.
String macroName(LaneMacro macro) => _nameOf(macro);

/// The icons a macro can be given, the first the one every macro has.
const macroIcons = [
  AppIcon.repeat, AppIcon.show, AppIcon.hide, AppIcon.pointer, AppIcon.draw, AppIcon.erase, AppIcon.tidy, AppIcon.autoCurate, //
  AppIcon.clearLanes, AppIcon.transition, AppIcon.lanes, AppIcon.score, AppIcon.music, AppIcon.play, AppIcon.trimStart, AppIcon.trimEnd, //
  AppIcon.condense, AppIcon.expand, AppIcon.collapse, AppIcon.moveUp, AppIcon.moveDown, AppIcon.snap, AppIcon.pin, AppIcon.link, //
  AppIcon.check, AppIcon.add, AppIcon.delete, AppIcon.reset, AppIcon.copy, AppIcon.chapters, AppIcon.tonality, AppIcon.captions, //
  AppIcon.image, AppIcon.frame, AppIcon.audio, AppIcon.align, AppIcon.speed, AppIcon.search, AppIcon.code, AppIcon.test,
];

/// [macro]'s icon ([LaneMacro.icon], one of the app's by its name); the first of [macroIcons]
/// for one with none, for none at all, and for a name this version hasn't got.
AppIcon macroIcon(LaneMacro? macro) => AppIcon.values.asNameMap()[macro?.icon] ?? macroIcons.first;

/// Gives the widgets under it the app's macros ([MacrosScope.of]): the app puts one over the
/// window, with [AppSettings.macros], so a toolbar's buttons for them ([BarItem.macro]) have
/// their names and icons wherever they are drawn.
class MacrosScope extends InheritedWidget {
  const MacrosScope({super.key, required this.macros, required super.child});
  final List<LaneMacro> macros;

  /// The macros where [context] is; none outside a scope.
  static List<LaneMacro> of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<MacrosScope>()?.macros ?? const [];

  @override
  bool updateShouldNotify(MacrosScope oldWidget) => !listEquals(macros, oldWidget.macros);
}

/// What is wrong with a macro, as it is said: "Step 2: Select lanes first". A script's own
/// words (in English) for what only it finds.
String macroProblemText(MacroProblem problem) => 'Step {n}: {problem}'.fill({
      'n': problem.step,
      'problem': switch (problem.fault) {
        MacroFault.lanes => 'Select lanes first'.tr,
        MacroFault.regions => 'Select regions first'.tr,
        MacroFault.names => 'Name the lanes'.tr,
        MacroFault.bars => 'No bars given'.tr,
        MacroFault.heard => 'Wire Hear the Recording into it'.tr,
        MacroFault.script => problem.message,
      },
    });

/// Runs [macro] on [controller]'s lanes, asking for its bars first when it asks: null when it
/// was given up there (it did nothing); else what it came to that is worth saying (what is
/// wrong, or that nothing changed), with no text when it did its work.
Future<({String? text, bool failed})?> _run(BuildContext context, EditorController controller, LaneMacro macro) async {
  String? asked;
  if (macro.asks) {
    asked = await showAppDialog<String>(context: context, builder: (_) => _AskBars(controller: controller, macro: macro));
    if (asked == null) return null;
  }
  final (:problems, :changed) = await controller.lanes.runMacroReady(macro, asked: asked);
  if (problems.isNotEmpty) return (text: macroProblemText(problems.first), failed: true);
  return (text: changed ? null : 'Nothing changed'.tr, failed: false);
}

/// Runs [macro] (the Instruments bar's menu, ⌃1–9): one Undo step, or nothing and why.
/// What running [macro] from a toolbar, a menu or its key does now; null while it can't be
/// run: it has no steps, or what its steps are done to isn't showing. Steps for lanes run in
/// the Instruments tab (not while the script is in the lanes' place), steps for the
/// recording's anchors in the Audio tab, a macro of both in either; none for the recording
/// while an Align is under way or a recording loads.
VoidCallback? macroAction(BuildContext context, EditorController controller, LaneMacro macro) {
  final shown = (macro.onLanes && controller.tab == BottomTab.instruments && !controller.lanes.scripting) ||
      (macro.onRecording && controller.tab == BottomTab.audio);
  return !shown || controller.curation == null || (macro.onRecording && (controller.anchors.aligning != null || controller.isLoadingAudio))
      ? null
      : () => playMacro(context, controller, macro);
}

Future<void> playMacro(BuildContext context, EditorController controller, LaneMacro macro) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final text = (await _run(context, controller, macro))?.text;
  if (text == null) return;
  messenger
    ?..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text('${_nameOf(macro)}: $text')));
}

/// Edit ▸ Macros…: the app's macros ([AppSettings.macros]), tried on [controller]'s project.
Future<void> showMacrosDialog(BuildContext context, AppSettings settings, EditorController controller) =>
    showAppDialog<void>(context: context, builder: (_) => _MacrosDialog(settings: settings, controller: controller));

/// The Instruments bar's Macros: each macro, chosen to run it (the first nine with their
/// keys), then Edit Macros… ([onEdit]; null: greyed out).
class MacrosMenu extends StatelessWidget {
  const MacrosMenu({super.key, required this.controller, required this.onEdit});
  final EditorController controller;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final macros = MacrosScope.of(context), keys = KeyCommand.runMacro.also;
    return OverlaySemantics(
      child: AppPopupMenuButton<VoidCallback>(
        tooltip: 'Macros'.tr,
        // A toolbar's icon button, as Tidy's and Sync's menus are.
        iconSize: 16,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 220),
        style: ToolbarButton.styleOf(context),
        icon: Icon(AppIcon.repeat.of(context)),
        onSelected: (action) => action(),
        itemBuilder: (menu) => [
          for (final (i, macro) in macros.indexed)
            menuItem(
              menu,
              value: macroAction(context, controller, macro) ?? () {},
              enabled: macroAction(context, controller, macro) != null,
              child: Row(children: [
                Icon(macroIcon(macro).of(menu), size: 16),
                SizedBox(width: AppStyle.of(menu).isCarbon ? 8 : 6),
                Expanded(child: Text(_nameOf(macro), overflow: TextOverflow.ellipsis)),
                if (i < keys.length) ...[const SizedBox(width: 24), Text(keys[i].label, style: TextStyle(fontSize: 12, color: menu.colors.textMuted))],
              ]),
            ),
          if (macros.isNotEmpty) menuDivider(menu),
          menuItem(menu, value: onEdit ?? () {}, enabled: onEdit != null, child: Text('Edit Macros…'.tr)),
        ],
      ),
    );
  }
}

/// The bars a macro asks for as it runs, as a script writes them ("1-8, 17-24", "from 9"):
/// given once they are bars the macro can be run with.
class _AskBars extends StatefulWidget {
  const _AskBars({required this.controller, required this.macro});
  final EditorController controller;
  final LaneMacro macro;

  @override
  State<_AskBars> createState() => _AskBarsState();
}

class _AskBarsState extends State<_AskBars> {
  final _bars = TextEditingController();
  String? _wrong;

  @override
  void dispose() {
    _bars.dispose();
    super.dispose();
  }

  void _done() {
    final text = _bars.text.trim();
    if (text.isEmpty) return;
    final problems = widget.controller.lanes.checkMacro(widget.macro, asked: text);
    problems.isEmpty ? Navigator.pop(context, text) : setState(() => _wrong = macroProblemText(problems.first));
  }

  @override
  Widget build(BuildContext context) => AppDialog(
        title: Text(_nameOf(widget.macro)),
        content: SizedBox(
          width: dialogWidth(context, 300),
          child: AppTextField(
            controller: _bars,
            label: 'Bars',
            hint: '1-8, 17-24',
            autofocus: true,
            bad: _wrong != null,
            onChanged: (_) => setState(() => _wrong = null),
            onSubmitted: (_) => _done(),
          ),
        ),
        status: _wrong == null ? null : Text(_wrong!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
          FilledButton(onPressed: _bars.text.trim().isEmpty ? null : _done, child: Text('Run'.tr)),
        ],
      );
}

/// The macros, listed at the left (in the order their keys count them), the one chosen put
/// together at the right: its name, then its steps, each a row of choices. What is changed is
/// kept as it is changed; Run tries the macro on the project under the dialog.
class _MacrosDialog extends StatefulWidget {
  const _MacrosDialog({required this.settings, required this.controller});
  final AppSettings settings;
  final EditorController controller;

  @override
  State<_MacrosDialog> createState() => _MacrosDialogState();
}

class _MacrosDialogState extends State<_MacrosDialog> {
  int _at = 0;
  final _name = TextEditingController();

  /// What the last Run came to, until the macro is changed.
  ({String text, bool failed})? _said;

  List<LaneMacro> get _macros => widget.settings.macros;
  LaneMacro? get _macro => _at < _macros.length ? _macros[_at] : null;

  @override
  void initState() {
    super.initState();
    _name.text = _macro?.name ?? '';
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// The toolbars a macro's button can be on.
  static const _bars = [BarKind.editor, BarKind.instruments, BarKind.audio];

  /// [macros] kept as the app's, the one at [at] chosen; [moved]: where each macro of the list
  /// went (null: gone), which its toolbar button follows ([ToolbarLayout.macrosMoved]).
  void _keep(List<LaneMacro> macros, {int? at, int? Function(int at)? moved}) => setState(() {
        final settings = widget.settings;
        if (moved != null) {
          for (final kind in _bars) {
            settings.setToolbar(settings.toolbarOf(kind).macrosMoved(moved));
          }
        }
        settings.macros = macros;
        _said = null;
        if (at != null) {
          _at = at.clamp(0, macros.isEmpty ? 0 : macros.length - 1);
          _name.text = _macro?.name ?? '';
        }
      });

  /// The macro chosen, changed.
  void _change(LaneMacro macro) => _keep([for (final (i, m) in _macros.indexed) i == _at ? macro : m]);

  void _add(LaneMacro macro) => _keep([..._macros, macro], at: _macros.length);

  void _move(int by) {
    final from = _at, to = _at + by, macros = [..._macros], macro = macros.removeAt(from);
    _keep(macros..insert(to, macro), at: to, moved: (at) => at == from ? to : (at == to ? from : at));
  }

  /// How many macros were deleted here: the one that takes a deleted one's place in the list
  /// is another, with a graph of its own.
  int _removed = 0;

  void _remove() {
    final gone = _at;
    _removed++;
    _keep([for (final (i, m) in _macros.indexed) if (i != gone) m], at: gone, moved: (at) => at == gone ? null : (at > gone ? at - 1 : at));
  }

  /// The chosen macro's button, if it can have one (the first nine do), and whether a toolbar
  /// has it, on its bar or in its menu.
  BarItem? get _button => _at < BarItem.macroButtons.length ? BarItem.macroButtons[_at] : null;
  bool get _onToolbar => _bars.any((kind) => widget.settings.toolbarOf(kind).bar.contains(_button) || widget.settings.toolbarOf(kind).menu.contains(_button));

  /// Puts the chosen macro's button on the bar of the tab it runs in (the Instruments tab's;
  /// the Audio tab's for one that is all the recording's), or takes it off every toolbar.
  void _pin() => setState(() {
        final settings = widget.settings, button = _button!;
        if (_onToolbar) {
          for (final kind in _bars) {
            settings.setToolbar(settings.toolbarOf(kind).without(button));
          }
        } else {
          final kind = _macro!.onRecording && !_macro!.onLanes ? BarKind.audio : BarKind.instruments;
          settings.setToolbar(settings.toolbarOf(kind).added(button));
        }
      });

  /// Whether a run from here is still going (one that hears the recording takes a while).
  bool _trying = false;

  Future<void> _try() async {
    if (_trying) return;
    setState(() => _trying = true);
    try {
      // (Given up as it asked for bars: nothing to say.)
      final said = await _run(context, widget.controller, _macro!);
      if (mounted) setState(() => _said = said == null ? null : (text: said.text ?? 'Done'.trIn('status'), failed: said.failed));
    } finally {
      if (mounted) setState(() => _trying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, macro = _macro, said = _said;
    return AppDialog(
      title: Text('Macros'.tr),
      divided: true,
      confirmsOnReturn: false,
      maxWidth: 1300,
      content: SizedBox(
        width: dialogWidth(context, 1000),
        height: 520,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(width: 190, child: _list(context)),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: VerticalDivider(width: 1, color: colors.line)),
          Expanded(
            child: macro == null
                ? Center(child: Text('No macros'.tr, style: TextStyle(color: colors.textMuted)))
                : _steps(context, macro),
          ),
        ]),
      ),
      leading: [TextButton(onPressed: macro == null || macro.steps.isEmpty || _trying ? null : _try, child: Text('Run'.tr))],
      status: said == null
          ? null
          : Text(said.text,
              maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: said.failed ? Theme.of(context).colorScheme.error : colors.textMuted)),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text('Done'.tr))],
    );
  }

  Widget _list(BuildContext context) {
    final colors = context.colors, macros = _macros, keys = KeyCommand.runMacro.also;
    final names = _exampleNames;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: ListView(children: [
          for (final (i, macro) in macros.indexed)
            SidebarTile(
              icon: macroIcon(macro).of(context),
              label: _nameOf(macro),
              selected: i == _at,
              onTap: () => setState(() {
                _at = i;
                _name.text = macro.name;
                _said = null;
              }),
              trailing: i < keys.length ? Text(keys[i].label, style: TextStyle(fontSize: 12, color: colors.textMuted)) : null,
            ),
        ]),
      ),
      const SizedBox(height: 6),
      Row(children: [
        OverlaySemantics(
          child: AppPopupMenuButton<VoidCallback>(
            tooltip: 'Add'.tr,
            iconSize: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 200),
            style: IconButton.styleFrom(fixedSize: const Size(32, 32), minimumSize: const Size(32, 32), shape: RoundedRectangleBorder(borderRadius: AppStyle.of(context).radius(8))),
            icon: Icon(AppIcon.add.of(context)),
            onSelected: (action) => action(),
            itemBuilder: (menu) => [
              menuItem(menu, value: () => _add(LaneMacro(name: 'New Macro'.tr)), child: Text('New Macro'.tr)),
              menuDivider(menu),
              menuHeader(menu, 'Examples'.tr),
              for (final (i, example) in LaneMacro.examples.indexed)
                menuItem(menu, value: () => _add(example.copyWith(name: names[i])), child: Text(names[i])),
            ],
          ),
        ),
        ToolbarButton(icon: AppIcon.copy.of(context), tooltip: 'Duplicate'.tr, onPressed: _macro == null ? null : () => _add(_macro!)),
        const Spacer(),
        ToolbarButton(icon: AppIcon.moveUp.of(context), tooltip: 'Move Up'.tr, onPressed: _macro == null || _at == 0 ? null : () => _move(-1)),
        ToolbarButton(icon: AppIcon.moveDown.of(context), tooltip: 'Move Down'.tr, onPressed: _macro == null || _at >= macros.length - 1 ? null : () => _move(1)),
        ToolbarButton(
          icon: AppIcon.delete.of(context),
          tooltip: 'Delete'.tr,
          onPressed: _macro == null ? null : _remove,
        ),
      ]),
    ]);
  }

  Widget _steps(BuildContext context, LaneMacro macro) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        // (At the field's top, as its outline is: a text field is drawn in its box's top.)
        SizedBox(
          height: AppStyle.of(context).field,
          child: Align(
            alignment: Alignment.topCenter,
            child: _IconButton(icon: macroIcon(macro), onChanged: (icon) => _change(macro.copyWith(icon: icon == macroIcons.first ? '' : icon.name))),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: AppTextField(controller: _name, label: 'Name', maxLength: 60, onChanged: (name) => _change(macro.copyWith(name: name)))),
        const SizedBox(width: 6),
        // Its own button on a toolbar (the first nine have one), there or not.
        SizedBox(
          height: AppStyle.of(context).field,
          child: Align(
            alignment: Alignment.topCenter,
            child: ToolbarButton(
              icon: AppIcon.pin.of(context),
              tooltip: _button == null ? 'The first nine macros'.tr : (_onToolbar ? 'Remove from Toolbar'.tr : 'Add to Toolbar'.tr),
              selected: _button != null && _onToolbar,
              onPressed: _button == null ? null : _pin,
            ),
          ),
        ),
      ]),
      const SizedBox(height: 14),
      // (A macro's graph is its own: another's starts where it is, with nothing chosen.)
      Expanded(child: _Graph(key: ValueKey((_at, _removed)), macro: macro, onChanged: _change)),
    ]);
  }
}

/// A macro's icon, as a field showing it: a click opens the icons it can be given, in a grid.
class _IconButton extends StatelessWidget {
  const _IconButton({required this.icon, required this.onChanged});
  final AppIcon icon;
  final ValueChanged<AppIcon> onChanged;

  @override
  Widget build(BuildContext context) {
    final style = AppStyle.of(context), colors = context.colors;
    return OverlaySemantics(
      child: AppPopupMenuButton<AppIcon>(
        tooltip: 'Icon'.tr,
        padding: EdgeInsets.zero,
        position: PopupMenuPosition.under,
        onSelected: onChanged,
        itemBuilder: (_) => [_IconGrid(chosen: icon)],
        child: Container(
          width: style.control + 4,
          height: style.control,
          decoration: BoxDecoration(color: fieldFill(context), border: Border.all(color: colors.line), borderRadius: style.radius(8)),
          child: Icon(icon.of(context), size: 18, color: colors.text),
        ),
      ),
    );
  }
}

/// The icons a macro can be given ([macroIcons]) as a menu's one entry: a grid, the one it has
/// marked, a click on one choosing it.
class _IconGrid extends PopupMenuEntry<AppIcon> {
  const _IconGrid({required this.chosen});
  final AppIcon chosen;

  static const _columns = 8, _cell = 32.0;

  @override
  double get height => (macroIcons.length / _columns).ceil() * _cell;

  @override
  bool represents(AppIcon? value) => false;

  @override
  State<_IconGrid> createState() => _IconGridState();
}

class _IconGridState extends State<_IconGrid> {
  @override
  Widget build(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: SizedBox(
        width: _IconGrid._columns * _IconGrid._cell,
        child: Wrap(children: [
          for (final icon in macroIcons)
            InkWell(
              borderRadius: style.radius(6),
              onTap: () => Navigator.pop(context, icon),
              child: Container(
                width: _IconGrid._cell,
                height: _IconGrid._cell,
                decoration: icon == widget.chosen ? BoxDecoration(color: colors.accent.withValues(alpha: 0.16), borderRadius: style.radius(6)) : null,
                child: Icon(icon.of(context), size: 18, color: icon == widget.chosen ? colors.accent : colors.text),
              ),
            ),
        ]),
      ),
    );
  }
}

/// A node's width, its head's height (the ports are at its middle), and how far apart the
/// graph's own layout puts the nodes ([LaneMacro.grid]).
const _nodeWidth = 252.0, _nodeHead = 36.0, _gridX = _nodeWidth + 44, _gridY = 240.0;

/// A macro as a graph: its steps the nodes, each a card of its choices, and its wires drawn
/// from a node's right side into another's left: what is done after what. A node is moved by
/// its head; a wire is drawn out of the port at a node's right onto another node (one that
/// would close a ring isn't taken) and cut at the dot in its middle; the ground is dragged
/// or scrolled about. Add Step puts one after the node chosen (the last added, with none).
class _Graph extends StatefulWidget {
  const _Graph({super.key, required this.macro, required this.onChanged});
  final LaneMacro macro;
  final ValueChanged<LaneMacro> onChanged;

  @override
  State<_Graph> createState() => _GraphState();
}

class _GraphState extends State<_Graph> {
  static const _inset = Offset(20, 16);

  Offset _pan = Offset.zero;
  Size _view = Size.zero;
  int? _selected;

  /// The node being moved, with where it is; the wire being drawn out of a node, with where
  /// its end is (both on the graph's own ground).
  (int, Offset)? _moving, _wiring;

  /// Where the node being moved was taken from.
  Offset? _from;

  LaneMacro get _macro => widget.macro;

  /// Where each node is: where it was put, else where the graph's layout has it.
  List<Offset> get _places {
    final grid = _macro.grid;
    return [
      for (final (i, step) in _macro.steps.indexed)
        if (_moving case (final at, final where) when at == i)
          where
        else if (step.at case (final x, final y))
          Offset(x, y)
        else
          Offset(grid[i].$1 * _gridX, grid[i].$2 * _gridY),
    ];
  }

  static Offset _in(Offset place) => place + const Offset(0, _nodeHead / 2);
  static Offset _out(Offset place) => place + const Offset(_nodeWidth, _nodeHead / 2);

  /// [pan] kept to where there are nodes: never past the first, nor the last out of sight.
  Offset _held(Offset pan, List<Offset> places) {
    var right = 0.0, bottom = 0.0;
    for (final p in places) {
      right = math.max(right, p.dx + _nodeWidth + 2 * _inset.dx);
      bottom = math.max(bottom, p.dy + 260);
    }
    return Offset(pan.dx.clamp(math.min(0.0, _view.width - right), 0.0), pan.dy.clamp(math.min(0.0, _view.height - bottom), 0.0));
  }

  /// The node a wire from [from] let go at [point] goes into, if it can.
  int? _target(int from, Offset point, List<Offset> places) {
    for (final (i, p) in places.indexed) {
      if (Rect.fromLTWH(p.dx - 20, p.dy - 10, _nodeWidth + 20, _nodeHead + 20).contains(point) && _macro.canWire(from, i)) return i;
    }
    return null;
  }

  void _add(MacroAction action) {
    final macro = _macro, places = _places;
    final after = switch (_selected) { final chosen? when chosen < macro.steps.length => chosen, _ => macro.steps.isEmpty ? null : macro.steps.length - 1 };
    var at = after == null ? Offset.zero : places[after] + const Offset(_gridX, 0);
    while (places.any((p) => (p - at).distance < 60)) {
      at += const Offset(0, 150);
    }
    final lanes = action == MacroAction.clear || action.unit == MacroUnit.bars ? MacroLanes.all : MacroLanes.selected;
    widget.onChanged(macro.withStep(MacroStep(action, lanes: lanes, at: after == null ? null : (at.dx, at.dy)), after: after));
    setState(() {
      _selected = macro.steps.length;
      // Into sight.
      _pan = Offset(math.min(_pan.dx, _view.width - at.dx - _nodeWidth - 2 * _inset.dx), math.min(_pan.dy, _view.height - at.dy - 220));
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context), macro = _macro, places = _places;
    return LayoutBuilder(builder: (context, box) {
      _view = box.biggest;
      final pan = _held(_pan, places), origin = _inset + pan;
      // (From the pan as it is: several moves may come between two frames.)
      void move(Offset by) => setState(() => _pan = _held(_held(_pan, places) + by, places));
      final target = switch (_wiring) { (final from, final end) => _target(from, end, places), null => null };
      return DecoratedBox(
        decoration: BoxDecoration(color: colors.well, border: Border.all(color: colors.line), borderRadius: style.radius(8)),
        child: ClipRRect(
          borderRadius: style.radius(8),
          child: Listener(
            onPointerSignal: (signal) {
              if (signal is PointerScrollEvent) move(-signal.scrollDelta);
            },
            onPointerPanZoomUpdate: (swipe) => move(swipe.panDelta),
            // (A drag is a pointer's: a trackpad's swipe is the Listener's, which pans, and moves nothing it passes over.)
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              supportedDevices: kDragDevices,
              onTap: () => setState(() => _selected = null),
              onPanUpdate: (drag) => move(drag.delta),
              child: Stack(children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _WirePainter(
                      [for (final w in macro.wires) (_out(places[w.from]) + origin, _in(places[w.to]) + origin)],
                      switch (_wiring) { (final from, final end) => (_out(places[from]) + origin, (target == null ? end : _in(places[target])) + origin), null => null },
                      colors.textMuted,
                      colors.accent,
                    ),
                  ),
                ),
                for (final w in macro.wires)
                  if ((_out(places[w.from]) + _in(places[w.to])) / 2 + origin case final middle)
                    Positioned(
                      left: middle.dx - 10,
                      top: middle.dy - 10,
                      child: _WireCut(key: ValueKey('macro wire ${w.from + 1} ${w.to + 1}'), onCut: () => widget.onChanged(macro.withoutWire(w.from, w.to))),
                    ),
                for (final (i, step) in macro.steps.indexed)
                  Positioned(
                    left: places[i].dx + origin.dx,
                    top: places[i].dy + origin.dy,
                    width: _nodeWidth,
                    child: _Node(
                      // (A node's fields are its own: another's start from its own.)
                      key: ValueKey(i),
                      number: i + 1,
                      step: step,
                      selected: i == _selected,
                      onChanged: (changed) => widget.onChanged(macro.withStepAt(i, changed)),
                      onRemove: () {
                        setState(() => _selected = null);
                        widget.onChanged(macro.withoutStep(i));
                      },
                      onSelect: () => setState(() => _selected = i),
                      onMove: (by) => setState(() {
                        final to = (_from ??= places[i]) + by;
                        _moving = (i, Offset(math.max(0, to.dx), math.max(0, to.dy)));
                      }),
                      onMoved: () {
                        final at = _moving?.$2;
                        setState(() => _moving = _from = null);
                        if (at != null) widget.onChanged(macro.withStepAt(i, step.copyWith(at: (at.dx, at.dy))));
                      },
                    ),
                  ),
                // The ports: a wire goes into a node at its left, and is drawn out of its right.
                for (final (i, place) in places.indexed) ...[
                  Positioned(
                    left: _in(place).dx + origin.dx - 6,
                    top: _in(place).dy + origin.dy - 6,
                    child: IgnorePointer(child: _Port(lit: i == target)),
                  ),
                  Positioned(
                    left: _out(place).dx + origin.dx - 6,
                    top: _out(place).dy + origin.dy - 6,
                    child: IgnorePointer(child: _Port(lit: _wiring?.$1 == i)),
                  ),
                  // (Taken from the node's edge outward: inside it is the head's ×.)
                  Positioned(
                    left: _out(place).dx + origin.dx - 2,
                    top: _out(place).dy + origin.dy - 12,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.precise,
                      child: GestureDetector(
                        key: ValueKey('macro out ${i + 1}'),
                        behavior: HitTestBehavior.opaque,
                        supportedDevices: kDragDevices,
                        onPanStart: (_) => setState(() => _wiring = (i, _out(place))),
                        onPanUpdate: (drag) => setState(() => _wiring = (i, (_wiring?.$2 ?? _out(place)) + drag.delta)),
                        onPanCancel: () => setState(() => _wiring = null),
                        onPanEnd: (_) {
                          setState(() => _wiring = null);
                          if (target != null) widget.onChanged(macro.withWire(i, target));
                        },
                        child: const SizedBox(width: 16, height: 24),
                      ),
                    ),
                  ),
                ],
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: colors.chrome, border: Border.all(color: colors.line), borderRadius: style.radius(8)),
                    child: OverlaySemantics(
                      child: AppPopupMenuButton<MacroAction>(
                        enabled: macro.steps.length < LaneMacro.maxSteps,
                        style: toolbarMenuStyle(context, left: 6),
                        constraints: const BoxConstraints(minWidth: 220),
                        onSelected: _add,
                        itemBuilder: (menu) => [for (final action in MacroAction.values) menuItem(menu, value: action, child: Text(macroActionLabel(action)))],
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(AppIcon.add.of(context), size: 16),
                          const SizedBox(width: 5),
                          Text('Add Step'.tr, style: const TextStyle(fontSize: 13)),
                          const SizedBox(width: 8),
                        ]),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

/// The wires, each a curve leaving a node level and coming into the next level; [drawing]:
/// one being drawn out, in the accent colour.
class _WirePainter extends CustomPainter {
  _WirePainter(this.wires, this.drawing, this.color, this.accent);
  final List<(Offset, Offset)> wires;
  final (Offset, Offset)? drawing;
  final Color color, accent;

  static Path _curve(Offset from, Offset to) {
    final reach = math.max(40.0, (to.dx - from.dx).abs() / 2);
    return Path()
      ..moveTo(from.dx, from.dy)
      ..cubicTo(from.dx + reach, from.dy, to.dx - reach, to.dy, to.dx, to.dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = color;
    for (final (from, to) in wires) {
      canvas.drawPath(_curve(from, to), line);
    }
    if (drawing case (final from, final to)) {
      canvas.drawPath(
          _curve(from, to),
          line
            ..color = accent
            ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_WirePainter old) => !listEquals(old.wires, wires) || old.drawing != drawing || old.color != color || old.accent != accent;
}

/// A port of a node: where a wire meets it.
class _Port extends StatelessWidget {
  const _Port({required this.lit});
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(shape: BoxShape.circle, color: lit ? colors.accent : colors.surface, border: Border.all(color: lit ? colors.accent : colors.textMuted, width: 1.5)),
    );
  }
}

/// The dot in a wire's middle: a click cuts the wire.
class _WireCut extends StatefulWidget {
  const _WireCut({super.key, required this.onCut});
  final VoidCallback onCut;

  @override
  State<_WireCut> createState() => _WireCutState();
}

class _WireCutState extends State<_WireCut> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tip(
      message: 'Disconnect'.tr,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _over = true),
        onExit: (_) => setState(() => _over = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onCut,
          child: SizedBox(
            width: 20,
            height: 20,
            child: Center(
              child: Container(
                width: _over ? 16 : 7,
                height: _over ? 16 : 7,
                decoration: BoxDecoration(shape: BoxShape.circle, color: _over ? colors.surface : colors.textMuted, border: _over ? Border.all(color: colors.textMuted) : null),
                child: _over ? Icon(AppIcon.close.of(context), size: 10, color: colors.text) : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A step as a node: its head (its number, what it does, taken out by its ×; dragged, it moves
/// the node) over its choices, each a row.
class _Node extends StatefulWidget {
  const _Node({
    super.key,
    required this.number,
    required this.step,
    required this.selected,
    required this.onChanged,
    required this.onRemove,
    required this.onSelect,
    required this.onMove,
    required this.onMoved,
  });
  final int number;
  final MacroStep step;
  final bool selected;
  final ValueChanged<MacroStep> onChanged;
  final VoidCallback onRemove, onSelect, onMoved;
  final ValueChanged<Offset> onMove;

  @override
  State<_Node> createState() => _NodeState();
}

class _NodeState extends State<_Node> {
  late final _names = TextEditingController(text: widget.step.names.join(', '));
  late final _bars = TextEditingController(text: widget.step.bars);
  late final _number = TextEditingController(text: _numberText(widget.step));

  /// How far the node has been dragged since its head was taken.
  Offset _dragged = Offset.zero;

  static String _numberText(MacroStep step) => step.number == null ? '' : LaneScript.number(step.amount);
  static List<String> _split(String names) => [for (final name in names.split(RegExp('[,，、]'))) if (name.trim().isNotEmpty) name.trim()];

  /// What is typed stays as typed; a step that says something else (its action another, the
  /// one before it taken out) is shown as it is.
  @override
  void didUpdateWidget(_Node old) {
    super.didUpdateWidget(old);
    final step = widget.step;
    if (!listEquals(_split(_names.text), step.names)) _names.text = step.names.join(', ');
    if (_bars.text != step.bars) _bars.text = step.bars;
    if (double.tryParse(_number.text) != step.number) _number.text = _numberText(step);
  }

  @override
  void dispose() {
    _names.dispose();
    _bars.dispose();
    _number.dispose();
    super.dispose();
  }

  Widget _choice<T>(T value, List<T> values, String Function(T) label, ValueChanged<T> onChanged, {bool boxed = true}) => AppDropdown<T>(
        value: value,
        boxed: boxed,
        isExpanded: true,
        onChanged: (v) => onChanged(v as T),
        items: [for (final v in values) DropdownMenuItem<T>(value: v, child: Text(label(v), overflow: TextOverflow.ellipsis))],
      );

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context), step = widget.step, unit = step.action.unit;
    final rows = [
      if (step.action.onLanes) _choice(step.lanes, MacroLanes.values, _lanesLabel, (lanes) => widget.onChanged(step.copyWith(lanes: lanes))),
      if (step.action.onLanes && step.lanes == MacroLanes.named)
        AppTextField(controller: _names, label: '', hint: 'Flute*, Oboe*', onChanged: (names) => widget.onChanged(step.copyWith(names: _split(names)))),
      if (step.action.ranged) _choice(step.range, MacroRange.values, _rangeLabel, (range) => widget.onChanged(step.copyWith(range: range))),
      if (step.action.ranged && step.range == MacroRange.bars)
        AppTextField(controller: _bars, label: '', hint: '1-8, 17-24', onChanged: (bars) => widget.onChanged(step.copyWith(bars: bars))),
      if (unit != null)
        Row(children: [
          // What the number is of, where the step's name doesn't say.
          if (switch (step.action) { MacroAction.follow => 'Bridge Rests'.tr, MacroAction.fit || MacroAction.thin => 'Phrases of'.tr, MacroAction.snap => 'Within'.tr, _ => null } case final String of) ...[
            Flexible(child: Text(of, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: colors.textMuted))),
            const SizedBox(width: 6),
          ],
          SizedBox(
            width: 60,
            child: AppTextField(
              controller: _number,
              label: '',
              hint: LaneScript.number(step.action.standard),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              // (None typed: as a new step has it.)
              onChanged: (text) => widget.onChanged(MacroStep(step.action,
                  lanes: step.lanes, names: step.names, range: step.range, bars: step.bars, number: double.tryParse(text)?.clamp(0, unit.most).toDouble(), at: step.at)),
            ),
          ),
          const SizedBox(width: 6),
          Text(unit == MacroUnit.bars ? 'bars'.tr : 's', style: TextStyle(fontSize: 13, color: colors.textMuted)),
        ]),
    ];
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: widget.selected ? colors.accent : colors.line, width: widget.selected ? 1.5 : 1),
        borderRadius: style.radius(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        // The head: taken anywhere but its ×, it moves the node; a click chooses it.
        GestureDetector(
          key: ValueKey('macro node ${widget.number}'),
          behavior: HitTestBehavior.opaque,
          supportedDevices: kDragDevices,
          onTap: widget.onSelect,
          onPanStart: (_) {
            _dragged = Offset.zero;
            widget.onSelect();
          },
          onPanUpdate: (drag) => widget.onMove(_dragged += drag.delta),
          onPanEnd: (_) => widget.onMoved(),
          onPanCancel: widget.onMoved,
          child: SizedBox(
            height: _nodeHead,
            child: Row(children: [
              SizedBox(
                width: 30,
                child: Center(child: Text('${widget.number}', style: TextStyle(fontSize: 12, color: colors.textMuted, fontFeatures: const [FontFeature.tabularFigures()]))),
              ),
              Expanded(child: _choice(step.action, MacroAction.values, macroActionLabel, (action) => widget.onChanged(step.copyWith(action: action)), boxed: false)),
              ToolbarButton(icon: AppIcon.close.of(context), tooltip: 'Remove'.tr, onPressed: widget.onRemove),
              const SizedBox(width: 2),
            ]),
          ),
        ),
        if (rows.isNotEmpty) ...[
          Divider(height: 1, color: colors.line),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              for (final (i, row) in rows.indexed) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 8), child: row),
            ]),
          ),
        ],
      ]),
    );
  }
}
