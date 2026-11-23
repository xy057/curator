/// Curating without writing: a macro is a few steps, each put together from choices (what to
/// do, to which lanes, over which bars), kept by the app for every project and run with a click
/// or a key. A step says what a script's line says, with what a script can't: the lanes
/// selected, where the playhead is, bars asked for as it runs.
///
/// A macro runs as a script ([LaneMacro.script] writes it for the moment: a line a step, so a
/// line's number is its step's), which is why it does what the tools do, is checked whole
/// before anything changes and is one Undo step ([LaneScript]).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'lane_script.dart';

/// What a step's number counts, with what a new step has and the most it takes.
enum MacroUnit {
  bars(1, 1000),
  seconds(0.5, 30);

  const MacroUnit(this.standard, this.most);
  final double standard, most;
}

/// What a step does: one of the script's statements. [ranged]: over some bars; [unit]: with a
/// number of them, or of seconds.
enum MacroAction {
  show(ranged: true),
  hide(ranged: true),
  only(ranged: true),
  clear,
  auto,
  bridge(unit: MacroUnit.bars),
  removeShort(unit: MacroUnit.bars),
  transition(ranged: true, unit: MacroUnit.seconds),
  split,
  join,
  moveTop,
  moveBottom;

  const MacroAction({this.ranged = false, this.unit});
  final bool ranged;
  final MacroUnit? unit;
}

/// Which lanes a step is done to: every one, those selected as it runs, the rest, or those
/// named ([MacroStep.names]).
enum MacroLanes { all, selected, others, named }

/// Which bars a step is done over: the piece, those written ([MacroStep.bars], as a script
/// writes them: "1-8, 17-24"), from the first selected region's start to the last one's end,
/// from or until the playhead, the bar the playhead is in, or those asked for as it runs.
enum MacroRange { whole, bars, selection, fromPlayhead, untilPlayhead, playheadBar, ask }

/// One step of a macro.
@immutable
class MacroStep {
  const MacroStep(this.action, {this.lanes = MacroLanes.selected, this.names = const [], this.range = MacroRange.whole, this.bars = '', this.number});

  final MacroAction action;
  final MacroLanes lanes;

  /// The lanes' names while [lanes] is [MacroLanes.named], a `*` in one standing for anything.
  final List<String> names;

  /// Over which bars, for an action that is [MacroAction.ranged].
  final MacroRange range;

  /// The bars while [range] is [MacroRange.bars].
  final String bars;

  /// How many of the action's [MacroAction.unit]; null: as a new step has it.
  final double? number;

  /// The step's number as it is used.
  double get amount => (number ?? action.unit?.standard ?? 0).clamp(0, action.unit?.most ?? 0).toDouble();

  MacroStep copyWith({MacroAction? action, MacroLanes? lanes, List<String>? names, MacroRange? range, String? bars, double? number}) => MacroStep(
        action ?? this.action,
        lanes: lanes ?? this.lanes,
        names: names ?? this.names,
        range: range ?? this.range,
        bars: bars ?? this.bars,
        // (Another action's number is its own.)
        number: action != null && action.unit != this.action.unit ? null : number ?? this.number,
      );

  Map<String, Object?> toJson() => {
        'do': action.name,
        'lanes': lanes.name,
        if (lanes == MacroLanes.named) 'names': names,
        if (action.ranged) 'range': range.name,
        if (action.ranged && range == MacroRange.bars) 'bars': bars,
        if (action.unit != null && number != null) 'number': number,
      };

  /// What [toJson] wrote; null for what isn't a step this version knows.
  static MacroStep? fromJson(Object? json) {
    if (json is! Map) return null;
    final action = MacroAction.values.asNameMap()[json['do']];
    if (action == null) return null;
    final number = json['number'];
    return MacroStep(
      action,
      lanes: MacroLanes.values.asNameMap()[json['lanes']] ?? MacroLanes.selected,
      names: [if (json['names'] case final List names) ...names.whereType<String>()],
      range: MacroRange.values.asNameMap()[json['range']] ?? MacroRange.whole,
      bars: switch (json['bars']) { final String bars => bars, _ => '' },
      number: number is num && number.isFinite ? number.toDouble() : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MacroStep &&
      other.action == action &&
      other.lanes == lanes &&
      listEquals(other.names, names) &&
      other.range == range &&
      other.bars == bars &&
      other.number == number;

  @override
  int get hashCode => Object.hash(action, lanes, Object.hashAll(names), range, bars, number);
}

/// Why a step can't be done.
enum MacroFault {
  /// It is for the lanes selected, and none is.
  lanes,

  /// It is for the bars of the regions selected, and none is.
  regions,

  /// It is for lanes by name, and names none.
  names,

  /// Its bars aren't written (or asked for), or aren't bars.
  bars,

  /// What the script it makes gets wrong ([MacroProblem.message] says what).
  script,
}

/// Something wrong with a macro as it is run: at its [step] (1 the first).
@immutable
class MacroProblem {
  const MacroProblem(this.step, this.fault, [this.message = '']);
  final int step;
  final MacroFault fault;

  /// A script's own words for it, in English, for [MacroFault.script].
  final String message;

  @override
  String toString() => 'Step $step: ${fault == MacroFault.script ? message : fault.name}';
}

/// What a macro is run with: what is selected and where the playhead is, as a script says them.
@immutable
class MacroContext {
  const MacroContext({this.selected = const [], this.playhead, this.bar, this.span, this.asked});

  /// Of the project [host] is: its lanes [selected] (by their ids), the [playhead] in quarters,
  /// the [span] of the regions selected (from the first's start to the last's end, in
  /// quarters), and the bars [asked] for.
  factory MacroContext.of(LaneScriptHost host, {Iterable<String> selected = const [], double? playhead, (double, double)? span, String? asked}) {
    final lanes = host.lanes, beats = host.beats, called = LaneScript.references(lanes), chosen = selected.toSet();
    String? bar;
    if (playhead != null && beats.measureStarts.length > 1) {
      final starts = beats.measureStarts;
      bar = '${beats.barNumber(starts.lastIndexWhere((s) => s <= playhead + 1e-9).clamp(0, starts.length - 2))}';
    }
    return MacroContext(
      selected: [for (final lane in lanes) if (chosen.contains(lane.id)) called[lane.id]!],
      playhead: playhead == null ? null : LaneScript.place(beats, playhead),
      bar: bar,
      span: span == null ? null : LaneScript.range(beats, span.$1, span.$2),
      asked: asked,
    );
  }

  /// The lanes selected, each as a script names it (`"Violin"[2]`), top to bottom.
  final List<String> selected;

  /// Where the playhead is, as a script writes a place; null: nowhere known.
  final String? playhead;

  /// The bar the playhead is in.
  final String? bar;

  /// The bars of the regions selected, as a script writes a stretch ('' the whole piece); null:
  /// none is selected.
  final String? span;

  /// The bars asked for, as a script writes them; null: not asked.
  final String? asked;
}

/// A macro: its [name] and its steps, done in order.
@immutable
class LaneMacro {
  const LaneMacro({required this.name, this.steps = const []});
  final String name;
  final List<MacroStep> steps;

  /// The most steps one has.
  static const maxSteps = 40;

  /// Whether running it asks for bars first.
  bool get asks => steps.any((s) => s.action.ranged && s.range == MacroRange.ask);

  LaneMacro copyWith({String? name, List<MacroStep>? steps}) => LaneMacro(name: name ?? this.name, steps: steps ?? this.steps);

  /// A few to begin with, by their names in English.
  static const examples = [
    LaneMacro(name: 'Solo from Here', steps: [MacroStep(MacroAction.only, range: MacroRange.fromPlayhead)]),
    LaneMacro(name: 'Hide from Here', steps: [MacroStep(MacroAction.hide, range: MacroRange.fromPlayhead)]),
    LaneMacro(name: 'Show Bars…', steps: [MacroStep(MacroAction.show, range: MacroRange.ask)]),
    LaneMacro(name: 'Tidy Up', steps: [
      MacroStep(MacroAction.bridge, lanes: MacroLanes.all, number: 2),
      MacroStep(MacroAction.removeShort, lanes: MacroLanes.all, number: 1),
    ]),
  ];

  // MARK: Running

  /// The macro as a script for now, a line a step ([context]: what is selected, where the
  /// playhead is), and what keeps a step from being written: with any, it isn't to be run.
  ({String script, List<MacroProblem> problems}) script(MacroContext context) {
    final lines = <String>[], problems = <MacroProblem>[];
    for (final (i, step) in steps.indexed) {
      try {
        lines.add(_line(step, context));
      } on MacroFault catch (fault) {
        lines.add('');
        problems.add(MacroProblem(i + 1, fault));
      }
    }
    return (script: lines.join('\n'), problems: problems);
  }

  /// What a script found wrong ([found], by line) as the steps' problems.
  static List<MacroProblem> problemsOf(List<LaneScriptProblem> found) => [for (final p in found) MacroProblem(p.line, MacroFault.script, p.message)];

  /// A name in a script's quotes, its `*` still standing for anything.
  static String _quoted(String name) => '"${name.replaceAllMapped(RegExp(r'[\\"]'), (m) => '\\${m[0]}')}"';

  /// Bars as written by hand, on the line they are put in: nothing that would end it.
  static String _written(String bars) {
    final text = bars.trim();
    if (text.isEmpty || text.contains(RegExp(r'[#\r\n]'))) throw MacroFault.bars;
    return text;
  }

  static String _line(MacroStep step, MacroContext context) {
    final lanes = switch (step.lanes) {
      MacroLanes.all => 'all',
      MacroLanes.selected => context.selected.isEmpty ? throw MacroFault.lanes : context.selected.join(', '),
      MacroLanes.others => context.selected.isEmpty ? 'all' : 'all except ${context.selected.join(', ')}',
      MacroLanes.named => switch ([for (final name in step.names) if (name.trim().isNotEmpty) _quoted(name.trim())]) {
          [] => throw MacroFault.names,
          final names => names.join(', '),
        },
    };
    final range = !step.action.ranged
        ? ''
        : switch (step.range) {
            MacroRange.whole => '',
            MacroRange.bars => _written(step.bars),
            MacroRange.selection => context.span ?? (throw MacroFault.regions),
            MacroRange.fromPlayhead => context.playhead == null ? throw MacroFault.bars : 'from ${context.playhead}',
            MacroRange.untilPlayhead => context.playhead == null ? throw MacroFault.bars : 'until ${context.playhead}',
            MacroRange.playheadBar => context.bar ?? (throw MacroFault.bars),
            MacroRange.ask => _written(context.asked ?? ''),
          };
    final n = LaneScript.number(step.amount);
    return [
      ...switch (step.action) {
        MacroAction.show => ['show', lanes, range],
        MacroAction.hide => ['hide', lanes, range],
        MacroAction.only => ['only', lanes, range],
        MacroAction.clear => ['clear', lanes],
        MacroAction.auto => ['auto', lanes],
        MacroAction.bridge => ['bridge rests', n, 'in', lanes],
        MacroAction.removeShort => ['remove short', n, 'in', lanes],
        MacroAction.transition => ['transition', lanes, range, 'in', n, 'out', n],
        MacroAction.split => ['split', lanes],
        MacroAction.join => ['join', lanes],
        MacroAction.moveTop => ['move', lanes, 'to top'],
        MacroAction.moveBottom => ['move', lanes, 'to bottom'],
      },
    ].where((part) => part.isNotEmpty).join(' ');
  }

  // MARK: Keeping

  Map<String, Object?> toJson() => {'name': name, 'steps': [for (final step in steps) step.toJson()]};

  /// What [toJson] wrote, the steps this version doesn't know left out; null for no macro.
  static LaneMacro? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'], steps = json['steps'];
    if (name is! String) return null;
    return LaneMacro(name: name, steps: List.unmodifiable([if (steps is List) ...steps.map(MacroStep.fromJson).nonNulls.take(maxSteps)]));
  }

  /// [macros] as the app keeps them.
  static String write(List<LaneMacro> macros) => jsonEncode([for (final macro in macros) macro.toJson()]);

  /// What [write] wrote: none from nothing, or from what can't be read.
  static List<LaneMacro> read(String? saved) {
    if (saved == null) return const [];
    try {
      return [...(jsonDecode(saved) as List).map(fromJson).nonNulls];
    } catch (_) {
      return const []; // damaged, or a newer version's
    }
  }

  @override
  bool operator ==(Object other) => other is LaneMacro && other.name == name && listEquals(other.steps, steps);

  @override
  int get hashCode => Object.hash(name, Object.hashAll(steps));
}
