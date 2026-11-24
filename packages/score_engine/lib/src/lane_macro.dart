/// Curating without writing: a macro is a few steps, each put together from choices (what to
/// do, to which lanes, over which bars), kept by the app for every project and run with a click
/// or a key. A step says what a script's line says, with what a script can't: the lanes
/// selected, where the playhead is, bars asked for as it runs.
///
/// A macro runs as a script ([LaneMacro.script] writes it for the moment: a line a step),
/// which is why it does what the tools do and is checked whole before anything changes
/// ([LaneScript]).
///
/// Its steps are the nodes of a graph, and its wires say which goes after which
/// ([LaneMacro.wires]: a step is done once every step wired into it is, on what they left). So
/// a macro can branch: steps with no wire between them, by whatever way, wait for nothing of
/// each other's, and those that don't come after a step that takes time (the recording heard)
/// are done at once while it is ([LaneMacro.stages]).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'lane_script.dart';
import 'words.dart';

/// What a step's number counts, with what a new step has and the most it takes.
enum MacroUnit {
  bars(1, 1000),
  seconds(0.5, 30);

  const MacroUnit(this.standard, this.most);
  final double standard, most;
}

/// What a step does: one of the script's statements. [ranged]: over some bars; [unit]: with a
/// number of them, or of seconds ([standard]: what a new step has, where it isn't the unit's).
/// One not [onLanes] is done to the recording's anchors (the Audio tab's), and names no lanes.
enum MacroAction {
  show(ranged: true),
  hide(ranged: true),
  only(ranged: true),
  clear,
  auto,

  /// Auto-Curate's first half: shown where it plays, through rests of up to its number of bars.
  follow(ranged: true, unit: MacroUnit.bars),

  /// Auto-Curate's second half: hidden where the staves run off the frame, in phrases of its
  /// number of bars. The three after it are its steps, each by itself.
  fit(unit: MacroUnit.bars, ownStandard: 4),
  thin(unit: MacroUnit.bars, ownStandard: 4),
  refill,
  lone,
  bridge(unit: MacroUnit.bars),
  removeShort(unit: MacroUnit.bars),
  transition(ranged: true, unit: MacroUnit.seconds),
  split,
  join,
  moveTop,
  moveBottom,

  /// The Audio tab's Align, whole; the three after it are its steps, each by itself: the
  /// recording heard, the anchors matched from it, each snapped to a note heard starting
  /// within its number of seconds (where the project snaps them: [MacroContext.snaps]).
  align(onLanes: false),
  hear(onLanes: false),
  match(onLanes: false),
  snap(onLanes: false, unit: MacroUnit.seconds, ownStandard: 0.05);

  const MacroAction({this.ranged = false, this.unit, this.ownStandard, this.onLanes = true});
  final bool ranged;
  final MacroUnit? unit;

  /// Whether it is done to lanes (the Instruments tab's); else to the recording's anchors.
  final bool onLanes;

  /// Whether it takes time (the recording heard, the score found in it): what comes after it
  /// in a macro waits for it, what doesn't is done meanwhile.
  bool get waits => this == hear || this == match || this == align;

  /// The number a new step of it has, where that isn't its unit's.
  final double? ownStandard;

  /// The number a new step of it has; 0 for one that takes none.
  double get standard => ownStandard ?? unit?.standard ?? 0;
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
  const MacroStep(this.action, {this.lanes = MacroLanes.selected, this.names = const [], this.range = MacroRange.whole, this.bars = '', this.number, this.at});

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

  /// Where its node is on the macro's graph (x, y); null: where the graph's own layout puts it
  /// ([LaneMacro.grid]).
  final (double, double)? at;

  /// The step's number as it is used.
  double get amount => (number ?? action.standard).clamp(0, action.unit?.most ?? 0).toDouble();

  MacroStep copyWith({MacroAction? action, MacroLanes? lanes, List<String>? names, MacroRange? range, String? bars, double? number, (double, double)? at}) => MacroStep(
        action ?? this.action,
        lanes: lanes ?? this.lanes,
        names: names ?? this.names,
        range: range ?? this.range,
        bars: bars ?? this.bars,
        // (Another action's number is its own.)
        number: action != null && action.unit != this.action.unit ? null : number ?? this.number,
        at: at ?? this.at,
      );

  Map<String, Object?> toJson() => {
        'do': action.name,
        if (action.onLanes) 'lanes': lanes.name,
        if (action.onLanes && lanes == MacroLanes.named) 'names': names,
        if (action.ranged) 'range': range.name,
        if (action.ranged && range == MacroRange.bars) 'bars': bars,
        if (action.unit != null && number != null) 'number': number,
        if (at case (final x, final y)) 'at': [x, y],
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
      at: switch (json['at']) { [final num x, final num y] when x.isFinite && y.isFinite => (x.toDouble(), y.toDouble()), _ => null },
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
      other.number == number &&
      other.at == at;

  @override
  int get hashCode => Object.hash(action, lanes, Object.hashAll(names), range, bars, number, at);
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

  /// It sets the anchors as heard, and no step that hears the recording is wired into it.
  heard,

  /// What the script it makes gets wrong ([MacroProblem.message] says what).
  script,
}

/// Something wrong with a macro as it is run: at its [step] (1 the first).
@immutable
class MacroProblem {
  const MacroProblem(this.step, this.fault, [this.message = const Words('')]);
  final int step;
  final MacroFault fault;

  /// A script's own words for it, for [MacroFault.script].
  final Words message;

  @override
  String toString() => 'Step $step: ${fault == MacroFault.script ? message : fault.name}';
}

/// What a macro is run with: what is selected and where the playhead is, as a script says them.
@immutable
class MacroContext {
  const MacroContext({this.selected = const [], this.playhead, this.bar, this.span, this.asked, this.snaps = true});

  /// Of the project [host] is: its lanes [selected] (by their ids), the [playhead] in quarters,
  /// the [span] of the regions selected (from the first's start to the last's end, in
  /// quarters), and the bars [asked] for.
  factory MacroContext.of(LaneScriptHost host, {Iterable<String> selected = const [], double? playhead, (double, double)? span, String? asked}) {
    // (The lanes are named only where some are selected: a macro on every lane is run as often.)
    final chosen = selected.toSet(), lanes = chosen.isEmpty ? const <ScriptLane>[] : host.lanes;
    final beats = host.beats, called = LaneScript.references(lanes);
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
      snaps: host.snaps,
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

  /// Whether the project snaps anchors to the notes heard starting (the Audio tab's Snap to
  /// Onsets): a Snap Anchors step is done only then, as Align's own snapping is.
  final bool snaps;
}

/// A wire of a macro's graph: the step at [to] is done after the one at [from] (their places in
/// [LaneMacro.steps]).
typedef MacroWire = ({int from, int to});

/// A macro: its [name], its steps and the wires between them.
@immutable
class LaneMacro {
  const LaneMacro({required this.name, this.steps = const [], this.icon = '', this.wired});
  final String name;

  /// Its steps, the nodes of its graph: a step's place here is its number, and what a wire
  /// names it by.
  final List<MacroStep> steps;

  /// The wires as they are kept; null for a macro whose steps are a chain, each wired into the
  /// next (as one put together before macros branched is).
  final List<MacroWire>? wired;

  /// The wires: which step is done after which.
  List<MacroWire> get wires => wired ?? [for (var i = 0; i + 1 < steps.length; i++) (from: i, to: i + 1)];

  /// Its icon, by the name the app has for it; '' for the one every macro has.
  final String icon;

  /// The most steps one has.
  static const maxSteps = 40;

  /// Whether running it asks for bars first.
  bool get asks => steps.any((s) => s.action.ranged && s.range == MacroRange.ask);

  /// Whether any step is done to lanes, and whether any is to the recording's anchors: where
  /// it can be run (the Instruments tab, the Audio tab).
  bool get onLanes => steps.any((s) => s.action.onLanes);
  bool get onRecording => steps.any((s) => !s.action.onLanes);

  LaneMacro copyWith({String? name, List<MacroStep>? steps, String? icon, List<MacroWire>? wires}) =>
      LaneMacro(name: name ?? this.name, steps: steps ?? this.steps, icon: icon ?? this.icon, wired: wires ?? wired);

  // MARK: The graph

  /// The steps wired into the one at [i], and those it is wired into.
  List<int> into(int i) => [for (final w in wires) if (w.to == i) w.from];
  List<int> outOf(int i) => [for (final w in wires) if (w.from == i) w.to];

  /// Every step the one at [i] comes after, by whatever way.
  Set<int> before(int i) {
    final found = <int>{}, next = [...into(i)];
    while (next.isNotEmpty) {
      final at = next.removeLast();
      if (found.add(at)) next.addAll(into(at));
    }
    return found;
  }

  /// The order the steps are done in, and so the lines of the script they are written as: each
  /// after every step wired into it, the lower number first where either may go, and those that
  /// wait for the recording after all that don't, as a run does them ([stages]). Checked in this
  /// order, a macro is checked as it runs.
  List<int> get order => [...stages.now, ...stages.later];

  /// The steps each after every step wired into it, the lower number first where either may go.
  List<int> get _wired {
    final wires = this.wires, left = {for (var i = 0; i < steps.length; i++) i}, order = <int>[];
    while (left.isNotEmpty) {
      // (A ring has no first step: what is left of one goes as numbered. None is ever kept.)
      final next = left.firstWhere((i) => !wires.any((w) => w.to == i && left.contains(w.from)), orElse: () => left.first);
      left.remove(next);
      order.add(next);
    }
    return order;
  }

  /// The steps done at once (those that neither take time nor come after one that does) and
  /// those done once what takes time has been got, each lot as wired.
  ({List<int> now, List<int> later}) get stages {
    final now = <int>[], later = <int>[];
    for (final i in _wired) {
      (steps[i].action.waits || before(i).any((b) => steps[b].action.waits) ? later : now).add(i);
    }
    return (now: now, later: later);
  }

  /// Where the graph's own layout puts each step: its column (how many steps deep it comes
  /// after others) and its row there, top to bottom as numbered.
  List<(int, int)> get grid {
    final column = List.filled(steps.length, 0), rows = <int, int>{};
    for (final i in order) {
      column[i] = into(i).fold(0, (deepest, from) => column[from] + 1 > deepest ? column[from] + 1 : deepest);
    }
    return [for (var i = 0; i < steps.length; i++) (column[i], rows.update(column[i], (row) => row + 1, ifAbsent: () => 0))];
  }

  /// With [step] added, wired in after the step at [after] where one is given.
  LaneMacro withStep(MacroStep step, {int? after}) =>
      copyWith(steps: List.unmodifiable([...steps, step]), wires: List.unmodifiable([...wires, if (after != null) (from: after, to: steps.length)]));

  /// With the step at [i] changed for [step].
  LaneMacro withStepAt(int i, MacroStep step) => copyWith(steps: List.unmodifiable([...steps]..[i] = step));

  /// Without the step at [i]: what was wired into it goes on into what it was wired into.
  LaneMacro withoutStep(int i) {
    int moved(int at) => at > i ? at - 1 : at;
    final kept = <MacroWire>{
      for (final w in wires) if (w.from != i && w.to != i) (from: moved(w.from), to: moved(w.to)),
      for (final from in into(i)) for (final to in outOf(i)) (from: moved(from), to: moved(to)),
    };
    return copyWith(steps: List.unmodifiable([...steps]..removeAt(i)), wires: List.unmodifiable(kept));
  }

  /// Whether a wire can go from the step at [from] into the one at [to]: between two steps,
  /// not there yet, and closing no ring.
  bool canWire(int from, int to) =>
      from != to && from >= 0 && to >= 0 && from < steps.length && to < steps.length && !wires.contains((from: from, to: to)) && !before(from).contains(to);

  /// With a wire from the step at [from] into the one at [to], where one [canWire].
  LaneMacro withWire(int from, int to) => canWire(from, to) ? copyWith(wires: List.unmodifiable([...wires, (from: from, to: to)])) : this;

  LaneMacro withoutWire(int from, int to) => copyWith(wires: List.unmodifiable([for (final w in wires) if (w != (from: from, to: to)) w]));

  /// A few to begin with, by their names in English.
  static const examples = [
    // Auto-Curate, whole, a step for each thing it does: what `auto` does.
    LaneMacro(name: 'Auto-curate', icon: 'autoCurate', steps: [
      MacroStep(MacroAction.follow, lanes: MacroLanes.all, number: 1),
      MacroStep(MacroAction.thin, lanes: MacroLanes.all, number: 4),
      MacroStep(MacroAction.refill, lanes: MacroLanes.all),
      MacroStep(MacroAction.lone, lanes: MacroLanes.all),
    ]),
    // Align, whole, a step for each thing it does: what `align` does.
    LaneMacro(name: 'Auto-align', icon: 'align', steps: [
      MacroStep(MacroAction.hear),
      MacroStep(MacroAction.match),
      MacroStep(MacroAction.snap, number: 0.05),
    ]),
    LaneMacro(name: 'Solo from Here', steps: [MacroStep(MacroAction.only, range: MacroRange.fromPlayhead)]),
    LaneMacro(name: 'Hide from Here', steps: [MacroStep(MacroAction.hide, range: MacroRange.fromPlayhead)]),
    LaneMacro(name: 'Show Bars…', steps: [MacroStep(MacroAction.show, range: MacroRange.ask)]),
    LaneMacro(name: 'Tidy Up', steps: [
      MacroStep(MacroAction.bridge, lanes: MacroLanes.all, number: 2),
      MacroStep(MacroAction.removeShort, lanes: MacroLanes.all, number: 1),
    ]),
  ];

  // MARK: Running

  /// The macro as a script for now, a line a step in the [order] they are done in ([context]:
  /// what is selected, where the playhead is), and what keeps a step from being written, by
  /// the steps' numbers: with any, it isn't to be run. Line n is the step at `order[n - 1]`.
  ({String script, List<MacroProblem> problems, List<int> order}) script(MacroContext context) {
    final order = this.order, lines = <String>[], problems = <MacroProblem>[];
    for (final i in order) {
      try {
        final hears = before(i).any((b) => steps[b].action == MacroAction.hear || steps[b].action == MacroAction.align);
        if (steps[i].action == MacroAction.match && !hears) throw MacroFault.heard;
        lines.add(_line(steps[i], context));
      } on MacroFault catch (fault) {
        lines.add('');
        problems.add(MacroProblem(i + 1, fault));
      }
    }
    return (script: lines.join('\n'), problems: problems..sort((a, b) => a.step.compareTo(b.step)), order: order);
  }

  /// What a script found wrong ([found], by line) as the steps' problems; [order]: the step
  /// each line is ([script]'s), a line's number being its step's without.
  static List<MacroProblem> problemsOf(List<LaneScriptProblem> found, [List<int>? order]) => [
        for (final p in found) MacroProblem(order == null ? p.line : (order.elementAtOrNull(p.line - 1) ?? p.line - 1) + 1, MacroFault.script, p.message),
      ]..sort((a, b) => a.step.compareTo(b.step));

  /// A name in a script's quotes, its `*` still standing for anything.
  static String _quoted(String name) => '"${name.replaceAllMapped(RegExp(r'[\\"]'), (m) => '\\${m[0]}')}"';

  /// Bars as written by hand, on the line they are put in: nothing that would end it.
  static String _written(String bars) {
    final text = bars.trim();
    if (text.isEmpty || text.contains(RegExp(r'[#\r\n]'))) throw MacroFault.bars;
    return text;
  }

  static String _line(MacroStep step, MacroContext context) {
    final lanes = !step.action.onLanes
        ? ''
        : switch (step.lanes) {
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
    // (Bars counted whole: a phrase is one at least.)
    final whole = step.amount.round();
    return [
      ...switch (step.action) {
        MacroAction.show => ['show', lanes, range],
        MacroAction.hide => ['hide', lanes, range],
        MacroAction.only => ['only', lanes, range],
        MacroAction.clear => ['clear', lanes],
        MacroAction.auto => ['auto', lanes],
        MacroAction.follow => ['follow', lanes, range, 'bridge', '$whole'],
        MacroAction.fit => ['fit', lanes, 'phrase', '${whole < 1 ? 1 : whole}'],
        MacroAction.thin => ['thin', lanes, 'phrase', '${whole < 1 ? 1 : whole}'],
        MacroAction.refill => ['refill', lanes],
        MacroAction.lone => ['remove lone in', lanes],
        MacroAction.bridge => ['bridge rests', n, 'in', lanes],
        MacroAction.removeShort => ['remove short', n, 'in', lanes],
        MacroAction.transition => ['transition', lanes, range, 'in', n, 'out', n],
        MacroAction.split => ['split', lanes],
        MacroAction.join => ['join', lanes],
        MacroAction.moveTop => ['move', lanes, 'to top'],
        MacroAction.moveBottom => ['move', lanes, 'to bottom'],
        MacroAction.align => ['align'],
        MacroAction.hear => ['hear'],
        MacroAction.match => ['match'],
        // (Left to the project, as Align's own snapping is: a line that does nothing keeps the steps' numbers.)
        MacroAction.snap => [context.snaps ? 'snap anchors within ${step.amount > 1 ? '1' : n}' : '# Snap to Notes is off'],
      },
    ].where((part) => part.isNotEmpty).join(' ');
  }

  // MARK: Keeping

  Map<String, Object?> toJson() => {
        'name': name,
        if (icon.isNotEmpty) 'icon': icon,
        'steps': [for (final step in steps) step.toJson()],
        if (wired != null) 'wires': [for (final w in wired!) [w.from, w.to]],
      };

  /// What [toJson] wrote, the steps this version doesn't know left out; null for no macro.
  static LaneMacro? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'], steps = json['steps'];
    if (name is! String) return null;
    // (A wire names its steps by their places as written: where each is once those unknown are left out.)
    final read = [if (steps is List) ...steps.map(MacroStep.fromJson)], places = <int, int>{};
    for (final (i, step) in read.indexed) {
      if (step != null && places.length < maxSteps) places[i] = places.length;
    }
    var macro = LaneMacro(
      name: name,
      steps: List.unmodifiable([for (final i in places.keys) read[i]!]),
      icon: switch (json['icon']) { final String icon => icon, _ => '' },
      wired: json['wires'] is List ? const [] : null,
    );
    if (json['wires'] case final List wires) {
      for (final wire in wires) {
        if (wire case [final int from, final int to] when places.containsKey(from) && places.containsKey(to)) macro = macro.withWire(places[from]!, places[to]!);
      }
    }
    return macro;
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
  bool operator ==(Object other) =>
      other is LaneMacro && other.name == name && other.icon == icon && listEquals(other.steps, steps) && listEquals(other.wired, wired);

  @override
  int get hashCode => Object.hash(name, icon, Object.hashAll(steps), wired == null ? null : Object.hashAll(wired!));
}
