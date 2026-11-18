import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'scroll_map.dart';
import 'search.dart';

/// What a lane of [Automation] sets: its id (its key in the project), and how its values are
/// written and read. One target, one lane. The video's view is one ([SceneViews.target]); a
/// later feature adds its own and gets a lane, saving, Undo and timing for nothing.
abstract class AutomationTarget<T> {
  const AutomationTarget(this.id);

  /// Its lane's key: lower-case letters, digits and `-`.
  final String id;

  /// What it is where no stretch (or point) says otherwise.
  T get base;

  /// [value] as JSON.
  Object? encode(T value);

  /// A value from [json]; throws a [FormatException] naming [where] when it isn't one.
  T decode(Object? json, String where);

  /// A lane of this target from [json] ([StepLane.toJson]'s), typed as its values are.
  StepLane<T> readSteps(Map<String, Object?> json, String where) => StepLane.fromJson<T>(this, json, where);
}

/// A stretch of a [StepLane]: [value] from score quarter [start] to [end], changing into it
/// and out of it over [fade] seconds centred on its edges (0: a cut).
@immutable
class AutoStretch<T> {
  const AutoStretch(this.start, this.end, this.value, {this.fade = defaultFade});

  final double start, end;
  final T value;
  final double fade;

  /// Seconds a stretch drawn takes to change, unless set.
  static const defaultFade = 0.5;

  /// The most a change may take.
  static const maxFade = 10.0;

  AutoStretch<T> withBounds(double start, double end) => AutoStretch(start, end, value, fade: fade);
  AutoStretch<T> withValue(T value) => AutoStretch(start, end, value, fade: fade);
  AutoStretch<T> withFade(double fade) => AutoStretch(start, end, value, fade: fade);

  @override
  bool operator ==(Object other) =>
      other is AutoStretch<T> && other.start == start && other.end == end && other.value == value && other.fade == fade;

  @override
  int get hashCode => Object.hash(start, end, value, fade);

  @override
  String toString() => 'AutoStretch($start–$end: $value, ${fade}s)';
}

/// A value held over stretches of the score, each its own ([AutoStretch]); between them, the
/// target's [AutomationTarget.base]. Stretches are kept in the score's order, never
/// overlapping: one put over others ([painted]) cuts back what it covers of them, as a region
/// drawn over a lane does.
@immutable
class StepLane<T> {
  StepLane(this.target, [Iterable<AutoStretch<T>> stretches = const []]) : stretches = List.unmodifiable(_tidy(stretches));

  final AutomationTarget<T> target;
  final List<AutoStretch<T>> stretches;

  bool get isEmpty => stretches.isEmpty;

  /// Shorter than this, a stretch is gone.
  static const minLength = 1e-6;

  /// [list] in order, later ones over earlier ones, empty ones left out.
  static List<AutoStretch<T>> _tidy<T>(Iterable<AutoStretch<T>> list) {
    var kept = <AutoStretch<T>>[];
    for (final s in list) {
      if (!s.start.isFinite || !s.end.isFinite || s.end - s.start < minLength) continue;
      kept = [
        for (final k in kept) ...[
          if (k.start < s.start - minLength) k.withBounds(k.start, math.min(k.end, s.start)),
          if (k.end > s.end + minLength) k.withBounds(math.max(k.start, s.end), k.end),
        ],
        s,
      ];
    }
    return kept..sort((a, b) => a.start.compareTo(b.start));
  }

  /// This lane with [stretch] over what it covers of the others.
  StepLane<T> painted(AutoStretch<T> stretch) => StepLane(target, [...stretches, stretch]);

  /// This lane with stretch [index] replaced by [stretch], over what it then covers of the
  /// others (of [base]'s, when given: the stretches as a drag found them).
  StepLane<T> reshaped(int index, AutoStretch<T> stretch, {List<AutoStretch<T>>? base}) {
    final from = base ?? stretches;
    if (index < 0 || index >= from.length) return this;
    return StepLane(target, [...from]..removeAt(index)..add(stretch));
  }

  /// This lane without stretch [index].
  StepLane<T> without(int index) => index < 0 || index >= stretches.length ? this : StepLane(target, [...stretches]..removeAt(index));

  /// Where [stretch] went in this lane; null when it isn't in it (cut back, say).
  int? indexOf(AutoStretch<T> stretch) {
    final i = stretches.indexWhere((s) => (s.start - stretch.start).abs() < minLength && s.value == stretch.value);
    return i < 0 ? null : i;
  }

  /// What is set at score quarter [quarter]: the stretch's there, else the base.
  T valueAt(double quarter) {
    final i = lastAtOrBefore(stretches.length, quarter, (i) => stretches[i].start);
    return i >= 0 && quarter < stretches[i].end ? stretches[i].value : target.base;
  }

  /// When each value holds in [timeline]'s performance ([TimedSteps]): what plays and shows.
  TimedSteps<T> inTime(ScoreTimeline timeline) => TimedSteps._(this, timeline);

  @override
  bool operator ==(Object other) => other is StepLane<T> && other.target.id == target.id && listEquals(other.stretches, stretches);

  @override
  int get hashCode => Object.hash(target.id, Object.hashAll(stretches));

  /// Its JSON: each stretch `{from, to, value, fade}` (fade left out at its default).
  Map<String, Object?> toJson() => {
        'kind': 'steps',
        'stretches': [
          for (final s in stretches)
            {'from': s.start, 'to': s.end, 'value': target.encode(s.value), if (s.fade != AutoStretch.defaultFade) 'fade': s.fade},
        ],
      };

  /// A lane of [target] read from [json] (as [toJson] writes it); throws a [FormatException]
  /// naming [where] when it isn't one.
  static StepLane<T> fromJson<T>(AutomationTarget<T> target, Map<String, Object?> json, String where) {
    final list = json['stretches'];
    if (list is! List) throw FormatException('$where.stretches is not a list.');
    return StepLane(target, [
      for (final (i, item) in list.indexed)
        () {
          final at = '$where.stretches[$i]';
          if (item is! Map) throw FormatException('$at is not an object.');
          final from = item['from'], to = item['to'], fade = item['fade'] ?? AutoStretch.defaultFade;
          if (from is! num || to is! num || !from.isFinite || !to.isFinite || from < 0 || to <= from) {
            throw FormatException('$at is not a stretch of the score.');
          }
          if (fade is! num || fade < 0 || fade > AutoStretch.maxFade) throw FormatException('$at.fade is out of range.');
          return AutoStretch(from.toDouble(), to.toDouble(), target.decode(item['value'], '$at.value'), fade: fade.toDouble());
        }(),
    ]);
  }
}

/// What a [StepLane] sets at a time: [from], changing to [to] by [mix] (0: [from] alone, as
/// it is outside a change; 1: [to] alone).
typedef StepMix<T> = ({T from, T to, double mix});

/// A [StepLane] in a performance's time: each stretch once in every pass that plays it, the
/// base between them, and where the value changes, a change [AutoStretch.fade] long centred on
/// it. A stretch where the performance starts (or ends) holds from before it (and on after it),
/// so nothing changes on the first bar or after the last.
class TimedSteps<T> {
  TimedSteps._(StepLane<T> lane, ScoreTimeline timeline)
      : base = lane.target.base,
        _first = lane.target.base {
    final passes = timeline.passes;
    final held = <({double start, double end, T value, double fade})>[
      for (final s in lane.stretches)
        for (final p in timeline.spans(s.start, s.end))
          (
            start: p.pass == 0 && p.start <= passes.first.start + 1e-6 ? double.negativeInfinity : p.startSeconds,
            end: p.pass == passes.length - 1 && p.end >= passes.last.end - 1e-6 ? double.infinity : p.endSeconds,
            value: s.value,
            fade: s.fade,
          ),
    ]..sort((a, b) => a.start.compareTo(b.start));
    // Every time the value changes, and the change's length: a stretch's own, going in or out
    // (going from one to the next, the next's).
    var value = base;
    void change(double seconds, T to, double length) {
      if (to == value) return;
      if (seconds == double.negativeInfinity) {
        _first = value = to; // held from before the performance starts: no change, what it starts with
        return;
      }
      _changes.add((seconds: seconds, from: value, to: to, fade: length));
      value = to;
    }

    for (final (i, h) in held.indexed) {
      change(h.start, h.value, h.fade);
      final next = i + 1 < held.length ? held[i + 1].start : double.infinity;
      if (h.end.isFinite && h.end < next - 1e-9) change(h.end, base, h.fade);
    }
    // A change takes no more than half the time to the changes either side, so two never overlap.
    for (final (i, c) in _changes.indexed) {
      final before = i > 0 ? c.seconds - _changes[i - 1].seconds : double.infinity;
      final after = i + 1 < _changes.length ? _changes[i + 1].seconds - c.seconds : double.infinity;
      final length = [c.fade, before, after].reduce(math.min);
      if (length != c.fade) _changes[i] = (seconds: c.seconds, from: c.from, to: c.to, fade: length);
    }
  }

  /// What holds where no stretch does.
  final T base;

  /// What holds before the first change.
  T _first;

  final _changes = <({double seconds, T from, T to, double fade})>[];

  /// Every change, in time: when (its middle), from what, to what, over how many seconds.
  List<({double seconds, T from, T to, double fade})> get changes => List.unmodifiable(_changes);

  /// What is set at [seconds], mid-change or not.
  StepMix<T> at(double seconds) {
    final i = lastAtOrBefore(_changes.length, seconds, (i) => _changes[i].seconds);
    // The change just past (i) or just ahead (i + 1) may still be under way.
    if (i + 1 < _changes.length) {
      final next = _changes[i + 1];
      if (seconds > next.seconds - next.fade / 2) return (from: next.from, to: next.to, mix: _ease(seconds, next));
    }
    if (i < 0) return (from: _first, to: _first, mix: 0);
    final c = _changes[i];
    if (seconds < c.seconds + c.fade / 2 && c.fade > 0) return (from: c.from, to: c.to, mix: _ease(seconds, c));
    return (from: c.to, to: c.to, mix: 0);
  }

  /// What holds at [seconds] once any change there is over (the later of the two mid-change).
  T valueAt(double seconds) {
    final m = at(seconds);
    return m.mix >= 0.5 ? m.to : m.from;
  }

  /// How far through change [c] [seconds] is, eased in and out.
  static double _ease(double seconds, ({double seconds, Object? from, Object? to, double fade}) c) {
    if (c.fade <= 0) return seconds >= c.seconds ? 1 : 0;
    final x = ((seconds - (c.seconds - c.fade / 2)) / c.fade).clamp(0.0, 1.0);
    return 0.5 - 0.5 * math.cos(math.pi * x);
  }
}

/// How a [CurveLane] goes from one point to the next.
enum CurveShape {
  /// A straight line.
  linear,

  /// Eased out of one and into the next.
  smooth,

  /// Held until the next, then a jump.
  hold,
}

/// A point of a [CurveLane]: [value] at score quarter [at], going on to the next as [shape] says.
@immutable
class AutoPoint {
  const AutoPoint(this.at, this.value, {this.shape = CurveShape.linear});
  final double at, value;
  final CurveShape shape;

  @override
  bool operator ==(Object other) => other is AutoPoint && other.at == at && other.value == value && other.shape == shape;

  @override
  int get hashCode => Object.hash(at, value, shape);
}

/// A number drawn as a line through points along the score: before the first point, its value;
/// after the last, the last's; none, the target's base. For what moves smoothly (a size, a
/// level) rather than switches.
@immutable
class CurveLane {
  CurveLane(this.target, [Iterable<AutoPoint> points = const []])
      : points = List.unmodifiable([...points.where((p) => p.at.isFinite && p.value.isFinite)]..sort((a, b) => a.at.compareTo(b.at)));

  final AutomationTarget<double> target;
  final List<AutoPoint> points;

  bool get isEmpty => points.isEmpty;

  /// The value at score quarter [quarter].
  double valueAt(double quarter) {
    if (points.isEmpty) return target.base;
    final i = lastAtOrBefore(points.length, quarter, (i) => points[i].at);
    if (i < 0) return points.first.value;
    if (i >= points.length - 1) return points.last.value;
    final (a, b) = (points[i], points[i + 1]);
    final x = b.at - a.at < 1e-9 ? 1.0 : ((quarter - a.at) / (b.at - a.at)).clamp(0.0, 1.0);
    final t = switch (a.shape) {
      CurveShape.linear => x,
      CurveShape.smooth => x * x * (3 - 2 * x),
      CurveShape.hold => x >= 1 ? 1.0 : 0.0,
    };
    return a.value + (b.value - a.value) * t;
  }

  /// The value at [seconds] of [timeline]'s performance (where the score is then).
  double valueInTime(ScoreTimeline timeline, double seconds) => valueAt(timeline.quarterAtSeconds(seconds));

  @override
  bool operator ==(Object other) => other is CurveLane && other.target.id == target.id && listEquals(other.points, points);

  @override
  int get hashCode => Object.hash(target.id, Object.hashAll(points));

  Map<String, Object?> toJson() => {
        'kind': 'curve',
        'points': [
          for (final p in points) {'at': p.at, 'value': p.value, if (p.shape != CurveShape.linear) 'shape': p.shape.name},
        ],
      };

  static CurveLane fromJson(AutomationTarget<double> target, Map<String, Object?> json, String where) {
    final list = json['points'];
    if (list is! List) throw FormatException('$where.points is not a list.');
    return CurveLane(target, [
      for (final (i, item) in list.indexed)
        () {
          final at = '$where.points[$i]';
          if (item is! Map || item['at'] is! num || item['value'] is! num) throw FormatException('$at is not a point.');
          final shape = switch (item['shape']) {
            null => CurveShape.linear,
            final String name => CurveShape.values.asNameMap()[name] ?? (throw FormatException('$at.shape "$name" is unknown.')),
            _ => throw FormatException('$at.shape is not a name.'),
          };
          return AutoPoint((item['at'] as num).toDouble(), target.decode(item['value'], '$at.value'), shape: shape);
        }(),
    ]);
  }
}

/// A project's automation: a lane per target that has any, by its id. Lanes this Curator knows
/// no target for (a later one's) are kept as they came ([foreign]) and written back unchanged.
@immutable
class Automation {
  Automation({Map<String, StepLane<Object?>> steps = const {}, Map<String, CurveLane> curves = const {}, Map<String, Object?> foreign = const {}})
      : _steps = Map.unmodifiable({
          for (final MapEntry(:key, :value) in steps.entries)
            if (!value.isEmpty) key: value
        }),
        _curves = Map.unmodifiable({
          for (final MapEntry(:key, :value) in curves.entries)
            if (!value.isEmpty) key: value
        }),
        foreign = Map.unmodifiable(foreign);

  static final none = Automation();

  final Map<String, StepLane<Object?>> _steps;
  final Map<String, CurveLane> _curves;

  /// Lanes of targets this Curator doesn't know, by id, as JSON.
  final Map<String, Object?> foreign;

  bool get isEmpty => _steps.isEmpty && _curves.isEmpty && foreign.isEmpty;

  /// The step lane of [target] (empty while it has none: the same one each time, so what is
  /// kept by the lane, as the frame's views in time are, holds while there is none).
  StepLane<T> steps<T>(AutomationTarget<T> target) => switch (_steps[target.id]) {
        final StepLane<T> lane => lane,
        _ => (_emptyLanes[target] ??= StepLane<T>(target)) as StepLane<T>,
      };

  static final _emptyLanes = Expando<StepLane<Object?>>();

  /// The curve lane of [target] (empty while it has none).
  CurveLane curve(AutomationTarget<double> target) => _curves[target.id] ?? CurveLane(target);

  /// This automation with [lane] in place of its target's.
  Automation withSteps<T>(StepLane<T> lane) =>
      Automation(steps: {..._steps, lane.target.id: lane}, curves: _curves, foreign: {...foreign}..remove(lane.target.id));

  Automation withCurve(CurveLane lane) =>
      Automation(steps: _steps, curves: {..._curves, lane.target.id: lane}, foreign: {...foreign}..remove(lane.target.id));

  @override
  bool operator ==(Object other) =>
      other is Automation && mapEquals(other._steps, _steps) && mapEquals(other._curves, _curves) && _sameJson(other.foreign, foreign);

  static bool _sameJson(Object? a, Object? b) => switch ((a, b)) {
        (final Map a, final Map b) => a.length == b.length && a.keys.every((k) => b.containsKey(k) && _sameJson(a[k], b[k])),
        (final List a, final List b) => a.length == b.length && [for (var i = 0; i < a.length; i++) i].every((i) => _sameJson(a[i], b[i])),
        _ => a == b,
      };

  @override
  int get hashCode => Object.hash(_steps.length, _curves.length, foreign.length);

  /// Every lane by its target's id.
  Map<String, Object?> toJson() => {
        ...foreign,
        for (final MapEntry(:key, :value) in _steps.entries) key: value.toJson(),
        for (final MapEntry(:key, :value) in _curves.entries) key: value.toJson(),
      };

  /// The lanes [json] holds, read by the [targets] this Curator knows (each a step lane's or,
  /// for a target of numbers, either kind); any other kept as it is. Throws a
  /// [FormatException] naming [where] for a lane that can't be read.
  static Automation fromJson(Map<String, Object?> json, String where, {required List<AutomationTarget<Object?>> targets}) {
    final known = {for (final t in targets) t.id: t};
    final steps = <String, StepLane<Object?>>{}, curves = <String, CurveLane>{}, foreign = <String, Object?>{};
    for (final MapEntry(:key, :value) in json.entries) {
      final target = known[key], at = '$where.$key';
      if (target == null) {
        foreign[key] = value;
        continue;
      }
      if (value is! Map<String, Object?>) throw FormatException('$at is not a lane.');
      switch (value['kind']) {
        case 'steps':
          steps[key] = target.readSteps(value, at);
        case 'curve' when target is AutomationTarget<double>:
          curves[key] = CurveLane.fromJson(target, value, at);
        default:
          throw FormatException('$at is not a lane this Curator reads.');
      }
    }
    return Automation(steps: steps, curves: curves, foreign: foreign);
  }
}
