import 'package:flutter/foundation.dart' show listEquals;
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
      MacroAction.bridge => 'Bridge Rests'.tr,
      MacroAction.removeShort => 'Remove Short Regions'.tr,
      MacroAction.transition => 'Set Transition'.tr,
      MacroAction.split => 'Split into Staves'.tr,
      MacroAction.join => 'Join Staves'.tr,
      MacroAction.moveTop => 'Move to Top'.tr,
      MacroAction.moveBottom => 'Move to Bottom'.tr,
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
List<String> get _exampleNames => ['Solo from Here'.tr, 'Hide from Here'.tr, 'Show Bars…'.tr, 'Tidy Up'.tr];

String _nameOf(LaneMacro macro) => macro.name.trim().isEmpty ? 'Untitled'.tr : macro.name;

/// What is wrong with a macro, as it is said: "Step 2: Select lanes first". A script's own
/// words (in English) for what only it finds.
String macroProblemText(MacroProblem problem) => 'Step {n}: {problem}'.fill({
      'n': problem.step,
      'problem': switch (problem.fault) {
        MacroFault.lanes => 'Select lanes first'.tr,
        MacroFault.regions => 'Select regions first'.tr,
        MacroFault.names => 'Name the lanes'.tr,
        MacroFault.bars => 'No bars given'.tr,
        MacroFault.script => problem.message,
      },
    });

/// Runs [macro] on [controller]'s lanes, asking for its bars first when it asks; what it came
/// to that is worth saying (what is wrong, or that nothing changed), null when it did its work
/// or was given up.
Future<({String text, bool failed})?> _run(BuildContext context, EditorController controller, LaneMacro macro) async {
  String? asked;
  if (macro.asks) {
    asked = await showAppDialog<String>(context: context, builder: (_) => _AskBars(controller: controller, macro: macro));
    if (asked == null) return null;
  }
  final (:problems, :changed) = controller.lanes.runMacro(macro, asked: asked);
  if (problems.isNotEmpty) return (text: macroProblemText(problems.first), failed: true);
  return changed ? null : (text: 'Nothing changed'.tr, failed: false);
}

/// Runs [macro] (the Instruments bar's menu, ⌃1–9): one Undo step, or nothing and why.
Future<void> playMacro(BuildContext context, EditorController controller, LaneMacro macro) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final said = await _run(context, controller, macro);
  if (said == null) return;
  messenger
    ?..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text('${_nameOf(macro)}: ${said.text}')));
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
    final macros = controller.lanes.macros, keys = KeyCommand.runMacro.also;
    return OverlaySemantics(
      child: AppPopupMenuButton<VoidCallback>(
        tooltip: 'Macros'.tr,
        iconSize: 18,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 220),
        style: IconButton.styleFrom(
          fixedSize: const Size(32, 32),
          minimumSize: const Size(32, 32),
          shape: RoundedRectangleBorder(borderRadius: AppStyle.of(context).radius(8)),
        ),
        icon: Icon(AppIcon.repeat.of(context)),
        onSelected: (action) => action(),
        itemBuilder: (menu) => [
          for (final (i, macro) in macros.indexed)
            menuItem(
              menu,
              value: () => playMacro(context, controller, macro),
              enabled: macro.steps.isNotEmpty,
              child: Row(children: [
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

  void _keep(List<LaneMacro> macros, {int? at}) => setState(() {
        widget.settings.macros = macros;
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
    final macros = [..._macros], macro = macros.removeAt(_at);
    _keep(macros..insert(_at + by, macro), at: _at + by);
  }

  Future<void> _try() async {
    final said = await _run(context, widget.controller, _macro!);
    if (mounted) setState(() => _said = said ?? (text: 'Done'.tr, failed: false));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, macro = _macro, said = _said;
    return AppDialog(
      title: Text('Macros'.tr),
      divided: true,
      confirmsOnReturn: false,
      content: SizedBox(
        width: dialogWidth(context, 650),
        height: 440,
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
      leading: [TextButton(onPressed: macro == null || macro.steps.isEmpty ? null : _try, child: Text('Run'.tr))],
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
              icon: null,
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
          onPressed: _macro == null ? null : () => _keep([for (final (i, m) in macros.indexed) if (i != _at) m], at: _at),
        ),
      ]),
    ]);
  }

  Widget _steps(BuildContext context, LaneMacro macro) {
    final steps = macro.steps;
    void set(List<MacroStep> steps) => _change(macro.copyWith(steps: List.unmodifiable(steps)));
    void swap(int i, int j) => set([...steps]
      ..[i] = steps[j]
      ..[j] = steps[i]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppTextField(controller: _name, label: 'Name', maxLength: 60, onChanged: (name) => _change(macro.copyWith(name: name))),
      const SizedBox(height: 14),
      Expanded(
        child: ListView(children: [
          for (final (i, step) in steps.indexed)
            _StepCard(
              // (A macro's steps are its own: another's fields start from its own.)
              key: ValueKey((_at, i)),
              number: i + 1,
              step: step,
              onChanged: (changed) => set([...steps]..[i] = changed),
              onRemove: () => set([...steps]..removeAt(i)),
              onUp: i == 0 ? null : () => swap(i, i - 1),
              onDown: i == steps.length - 1 ? null : () => swap(i, i + 1),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OverlaySemantics(
              child: AppPopupMenuButton<MacroAction>(
                enabled: steps.length < LaneMacro.maxSteps,
                position: PopupMenuPosition.under,
                style: toolbarMenuStyle(context, left: 6),
                constraints: const BoxConstraints(minWidth: 220),
                onSelected: (action) => set([...steps, MacroStep(action, lanes: action == MacroAction.clear || action.unit == MacroUnit.bars ? MacroLanes.all : MacroLanes.selected)]),
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
        ]),
      ),
    ]);
  }
}

/// A step, as a row of choices read left to right: what it does, to which lanes (their names
/// typed, for those named), over which bars (typed, for bars written), and its number of bars
/// or seconds; then what moves it among the steps and takes it out.
class _StepCard extends StatefulWidget {
  const _StepCard({super.key, required this.number, required this.step, required this.onChanged, required this.onRemove, required this.onUp, required this.onDown});
  final int number;
  final MacroStep step;
  final ValueChanged<MacroStep> onChanged;
  final VoidCallback onRemove;
  final VoidCallback? onUp, onDown;

  @override
  State<_StepCard> createState() => _StepCardState();
}

class _StepCardState extends State<_StepCard> {
  late final _names = TextEditingController(text: widget.step.names.join(', '));
  late final _bars = TextEditingController(text: widget.step.bars);
  late final _number = TextEditingController(text: _numberText(widget.step));

  static String _numberText(MacroStep step) => step.number == null ? '' : LaneScript.number(step.amount);
  static List<String> _split(String names) => [for (final name in names.split(RegExp('[,，、]'))) if (name.trim().isNotEmpty) name.trim()];

  /// What is typed stays as typed; a step that says something else (moved here, its action
  /// another) is shown as it is.
  @override
  void didUpdateWidget(_StepCard old) {
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

  Widget _choice<T>(double width, T value, List<T> values, String Function(T) label, ValueChanged<T> onChanged) => SizedBox(
        width: width,
        child: AppDropdown<T>(
          value: value,
          boxed: true,
          isExpanded: true,
          onChanged: (v) => onChanged(v as T),
          items: [for (final v in values) DropdownMenuItem<T>(value: v, child: Text(label(v), overflow: TextOverflow.ellipsis))],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context), step = widget.step, unit = step.action.unit;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      decoration: BoxDecoration(border: Border.all(color: colors.line), borderRadius: style.radius(8)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 28,
          height: style.field,
          child: Center(child: Text('${widget.number}', style: TextStyle(fontSize: 12, color: colors.textMuted, fontFeatures: const [FontFeature.tabularFigures()]))),
        ),
        Expanded(
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _choice(170, step.action, MacroAction.values, macroActionLabel, (action) => widget.onChanged(step.copyWith(action: action))),
            _choice(150, step.lanes, MacroLanes.values, _lanesLabel, (lanes) => widget.onChanged(step.copyWith(lanes: lanes))),
            if (step.lanes == MacroLanes.named)
              SizedBox(
                width: 180,
                child: AppTextField(controller: _names, label: '', hint: 'Flute*, Oboe*', onChanged: (names) => widget.onChanged(step.copyWith(names: _split(names)))),
              ),
            if (step.action.ranged) _choice(180, step.range, MacroRange.values, _rangeLabel, (range) => widget.onChanged(step.copyWith(range: range))),
            if (step.action.ranged && step.range == MacroRange.bars)
              SizedBox(
                width: 140,
                child: AppTextField(controller: _bars, label: '', hint: '1-8, 17-24', onChanged: (bars) => widget.onChanged(step.copyWith(bars: bars))),
              ),
            if (unit != null)
              Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: 60,
                  child: AppTextField(
                    controller: _number,
                    label: '',
                    hint: LaneScript.number(unit.standard),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    // (None typed: as a new step has it.)
                    onChanged: (text) => widget.onChanged(MacroStep(step.action,
                        lanes: step.lanes, names: step.names, range: step.range, bars: step.bars, number: double.tryParse(text)?.clamp(0, unit.most).toDouble())),
                  ),
                ),
                const SizedBox(width: 6),
                Text(unit == MacroUnit.bars ? 'bars'.tr : 's', style: TextStyle(fontSize: 13, color: colors.textMuted)),
              ]),
          ]),
        ),
        ToolbarButton(icon: AppIcon.moveUp.of(context), tooltip: 'Move Up'.tr, onPressed: widget.onUp),
        ToolbarButton(icon: AppIcon.moveDown.of(context), tooltip: 'Move Down'.tr, onPressed: widget.onDown),
        ToolbarButton(icon: AppIcon.close.of(context), tooltip: 'Remove'.tr, onPressed: widget.onRemove),
      ]),
    );
  }
}
