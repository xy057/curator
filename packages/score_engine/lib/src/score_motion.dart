import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// How a move goes from start (0) to end (1): an equation in `t`, 0 to 1 as the move runs
/// ("t*t*(3-2*t)", "1-(1-t)^3", "0.5-0.5*cos(pi*t)").
///
/// Whatever it is written as, a curve always starts at 0 and ends at 1: its value is scaled
/// so that `f(0)` and `f(1)` land there, so `3t^2-2t^3+5` is the same as smoothstep. Between
/// them it may leave 0–1 (an overshoot) by up to 1: a glide then goes past its place and comes
/// back, while what can't (an opacity) is held inside.
///
/// Written: numbers, `t` (or `x`), `pi`, `e`; `+ - * /`, `^` (or `**`), brackets; a number
/// before a name or bracket multiplies (`3t^2`); and `sin cos tan asin acos atan exp ln log
/// sqrt abs floor ceil round sign`, `min max` (two or more), `pow(a, b)`, `clamp(x, lo, hi)`,
/// `mix(a, b, t)`, `smoothstep(a, b, x)`.
@immutable
class MotionCurve {
  /// [expression] as it is, unchecked: the house curves ([presets]) only. Use [MotionCurve.parse]
  /// for anything typed.
  const MotionCurve._(this.expression);

  /// [text] as a curve. Throws a [FormatException] saying what is wrong with it.
  factory MotionCurve.parse(String text) {
    final expression = text.trim();
    _compiled(expression);
    return MotionCurve._(expression);
  }

  /// [text] as a curve, or null when it isn't one.
  static MotionCurve? tryParse(String text) {
    try {
      return MotionCurve.parse(text);
    } on FormatException {
      return null;
    }
  }

  /// What is wrong with [text] as a curve, or null when it is one.
  static String? problemWith(String text) {
    try {
      MotionCurve.parse(text);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  final String expression;

  static const linear = MotionCurve._('t');
  static const smooth = MotionCurve._('t*t*(3-2*t)');
  static const smoother = MotionCurve._('t^3*(t*(6*t-15)+10)');
  static const easeIn = MotionCurve._('t^3');
  static const easeOut = MotionCurve._('1-(1-t)^3');
  static const easeInOut = MotionCurve._('t<0.5 ? 4t^3 : 1-(2-2t)^3/2');
  static const sine = MotionCurve._('0.5-0.5*cos(pi*t)');
  static const back = MotionCurve._('1+2.70158*(t-1)^3+1.70158*(t-1)^2');

  /// The curves offered by name, in the order offered.
  static const presets = <(String, MotionCurve)>[
    ('Linear', linear),
    ('Smooth', smooth),
    ('Smoother', smoother),
    ('Ease In', easeIn),
    ('Ease Out', easeOut),
    ('Ease In-Out', easeInOut),
    ('Sine', sine),
    ('Overshoot', back),
  ];

  /// The name this curve is offered by, or null for one of the user's own.
  String? get presetName {
    for (final (name, e) in presets) {
      if (e == this) return name;
    }
    return null;
  }

  /// The curve at [t] (held to 0–1): 0 at 0, 1 at 1.
  double at(double t) => _compiled(expression)(t.clamp(0.0, 1.0));

  /// [at], held to 0–1.
  double inside(double t) => at(t).clamp(0.0, 1.0);

  /// How fast it starts, the slope at 0 (1 for [linear], 3 for [easeOut], 0 for [smooth]).
  double get startSlope => _slopes[expression] ??= 2 * at(5e-5) / 5e-5 - at(1e-4) / 1e-4; // Richardson: error ~h²
  static final _slopes = <String, double>{};

  @override
  bool operator ==(Object other) => other is MotionCurve && other.expression == expression;

  @override
  int get hashCode => expression.hashCode;

  @override
  String toString() => expression;

  /// Every curve met so far, compiled and scaled to 0–1. A frame asks hundreds of times, so
  /// each is read once; the house curve is plain Dart.
  static final _cache = <String, double Function(double)>{
    smooth.expression: (t) => t * t * (3 - 2 * t),
    linear.expression: (t) => t,
  };

  static double Function(double) _compiled(String expression) {
    final known = _cache[expression];
    if (known != null) return known;
    final f = _Parser(expression).parse();
    final f0 = f(0), f1 = f(1);
    if (!f0.isFinite || !f1.isFinite) throw const FormatException('Undefined at t = 0 or 1.');
    if ((f1 - f0).abs() < 1e-9) throw const FormatException('f(1) must differ from f(0).');
    final span = f1 - f0;
    for (var i = 1; i < _checks; i++) {
      final t = i / _checks, v = (f(t) - f0) / span;
      if (!v.isFinite) throw FormatException('Undefined at t = ${t.toStringAsFixed(2)}.');
      if (v < -_reach || v > 1 + _reach) throw FormatException('Too far past 0–1 at t = ${t.toStringAsFixed(2)}.');
    }
    if (_cache.length > 256) _cache.removeWhere((k, _) => !_house.contains(k));
    return _cache[expression] = (t) {
      // Between the points checked it may still be undefined, or spike: a straight line there,
      // and never further past 0–1 than it may go.
      final v = (f(t) - f0) / span;
      return v.isFinite ? v.clamp(-_reach, 1 + _reach) : t;
    };
  }

  /// Points a curve is checked at; how far past 0 and 1 it may go.
  static const _checks = 1024, _reach = 1.0;

  static final _house = {for (final (_, e) in presets) e.expression};
}

/// Everything about how the score moves that isn't a region's own (Project Settings ▸ Advanced):
/// how staves glide and fade, how the scroll comes to rest, how the frame fades out at the end,
/// how a caption comes in, how the bar numbers' row rises and the tempo at the left gives way.
/// The default is the house style.
@immutable
class ScoreMotion {
  const ScoreMotion({
    this.glide = MotionCurve.smooth,
    this.fade = MotionCurve.smooth,
    this.inkDelay = 0.1,
    this.ink = MotionCurve.smooth,
    this.settle = 2.5,
    this.settleCurve = MotionCurve.easeOut,
    this.slowest = 0.25,
    this.endFade = 1.5,
    this.endCurve = MotionCurve.smooth,
    this.captionFade = 0.4,
    this.captionRise = 4,
    this.captionCurve = MotionCurve.smooth,
    this.rowLead = 1.2,
    this.rowCurve = MotionCurve.smooth,
    this.tempoFade = 2,
    this.tempoCurve = MotionCurve.smooth,
  });

  static const standard = ScoreMotion();

  /// How staves move to their new places (and the key column to its new width) over a
  /// transition.
  final MotionCurve glide;

  /// How a staff's visibility ramps over a transition.
  final MotionCurve fade;

  /// How far into its ramp (0–0.9) a staff's ink starts to show: just behind the room opening up.
  final double inkDelay;

  /// How the ink fades in after [inkDelay].
  final MotionCurve ink;

  /// Seconds the score takes to come to rest after the final barline reaches the playhead.
  final double settle;

  /// How it slows: one that starts at the speed it had (an ease out) travels the speed ÷ the
  /// curve's starting slope, and doesn't jolt.
  final MotionCurve settleCurve;

  /// The slowest the scroll may go between two notes, as a share of its mean speed there.
  final double slowest;

  /// Seconds the frame takes to fade to paper at the end.
  final double endFade;
  final MotionCurve endCurve;

  /// Seconds a caption takes to fade in and out; points it rises (or falls) into place.
  final double captionFade;
  final double captionRise;
  final MotionCurve captionCurve;

  /// Seconds ahead of the staves the bar numbers' row starts to rise.
  final double rowLead;
  final MotionCurve rowCurve;

  /// Staff spaces of scroll over which one tempo at the left gives way to the next.
  final double tempoFade;
  final MotionCurve tempoCurve;

  /// Every setting: its key in the JSON, its range for numbers.
  static const ranges = <String, ({double min, double max})>{
    'inkDelay': (min: 0, max: 0.9),
    'settle': (min: 0, max: 8),
    'slowest': (min: 0.05, max: 1),
    'endFade': (min: 0, max: 6),
    'captionFade': (min: 0, max: 2),
    'captionRise': (min: 0, max: 24),
    'rowLead': (min: 0.2, max: 4),
    'tempoFade': (min: 0, max: 10),
  };

  /// Opacity of ink whose staff is [v] (0–1) visible: ink fades in just behind the space
  /// opening up, so a staff lands in room already made.
  double inkFor(double v) => ink.inside(((v - inkDelay) / (1 - inkDelay)).clamp(0.0, 1.0));

  /// Seconds of [settle] and of [endFade]: how long after the final barline a performance ends.
  double get ending => settle + endFade;

  /// A value as numbers and curves, for [fromJson]. Each key is written, so a project keeps its
  /// motion even if the house style changes.
  Map<String, Object?> toJson() => {
        'glide': glide.expression,
        'fade': fade.expression,
        'inkDelay': inkDelay,
        'ink': ink.expression,
        'settle': settle,
        'settleCurve': settleCurve.expression,
        'slowest': slowest,
        'endFade': endFade,
        'endCurve': endCurve.expression,
        'captionFade': captionFade,
        'captionRise': captionRise,
        'captionCurve': captionCurve.expression,
        'rowLead': rowLead,
        'rowCurve': rowCurve.expression,
        'tempoFade': tempoFade,
        'tempoCurve': tempoCurve.expression,
      };

  /// Reads [toJson]'s map. A key left out is the house style's (a newer setting, in an older
  /// file); one this version doesn't know is ignored. Throws a [FormatException] naming the
  /// key that is wrong.
  factory ScoreMotion.fromJson(Map<String, Object?> json) {
    const d = standard;
    double number(String key, double fallback) {
      final v = json[key];
      if (v == null) return fallback;
      final range = ranges[key]!;
      if (v is! num || !v.isFinite || v < range.min || v > range.max) {
        throw FormatException('$key is not between ${range.min} and ${range.max}.');
      }
      return v.toDouble();
    }

    MotionCurve curve(String key, MotionCurve fallback) {
      final v = json[key];
      if (v == null) return fallback;
      if (v is! String) throw FormatException('$key is not a curve.');
      try {
        return MotionCurve.parse(v);
      } on FormatException catch (e) {
        throw FormatException('$key is not a curve: ${e.message}');
      }
    }

    return ScoreMotion(
      glide: curve('glide', d.glide),
      fade: curve('fade', d.fade),
      inkDelay: number('inkDelay', d.inkDelay),
      ink: curve('ink', d.ink),
      settle: number('settle', d.settle),
      settleCurve: curve('settleCurve', d.settleCurve),
      slowest: number('slowest', d.slowest),
      endFade: number('endFade', d.endFade),
      endCurve: curve('endCurve', d.endCurve),
      captionFade: number('captionFade', d.captionFade),
      captionRise: number('captionRise', d.captionRise),
      captionCurve: curve('captionCurve', d.captionCurve),
      rowLead: number('rowLead', d.rowLead),
      rowCurve: curve('rowCurve', d.rowCurve),
      tempoFade: number('tempoFade', d.tempoFade),
      tempoCurve: curve('tempoCurve', d.tempoCurve),
    );
  }

  /// This motion with one setting, by its [toJson] key, set to [value] (a double or an [MotionCurve]).
  ScoreMotion withValue(String key, Object value) => ScoreMotion.fromJson({...toJson(), key: value is MotionCurve ? value.expression : value});

  /// One setting by its [toJson] key: a double or an [MotionCurve].
  Object valueOf(String key) => switch (key) {
        'glide' => glide,
        'fade' => fade,
        'inkDelay' => inkDelay,
        'ink' => ink,
        'settle' => settle,
        'settleCurve' => settleCurve,
        'slowest' => slowest,
        'endFade' => endFade,
        'endCurve' => endCurve,
        'captionFade' => captionFade,
        'captionRise' => captionRise,
        'captionCurve' => captionCurve,
        'rowLead' => rowLead,
        'rowCurve' => rowCurve,
        'tempoFade' => tempoFade,
        'tempoCurve' => tempoCurve,
        _ => throw ArgumentError.value(key, 'key'),
      };

  /// Whether the scroll moves differently from [other]'s (a new [ScrollMap] is needed).
  bool scrollsLike(ScoreMotion other) => settle == other.settle && settleCurve == other.settleCurve && slowest == other.slowest;

  @override
  bool operator ==(Object other) =>
      other is ScoreMotion &&
      glide == other.glide &&
      fade == other.fade &&
      inkDelay == other.inkDelay &&
      ink == other.ink &&
      scrollsLike(other) &&
      endFade == other.endFade &&
      endCurve == other.endCurve &&
      captionFade == other.captionFade &&
      captionRise == other.captionRise &&
      captionCurve == other.captionCurve &&
      rowLead == other.rowLead &&
      rowCurve == other.rowCurve &&
      tempoFade == other.tempoFade &&
      tempoCurve == other.tempoCurve;

  @override
  int get hashCode => Object.hash(glide, fade, inkDelay, ink, settle, settleCurve, slowest, endFade, endCurve, captionFade,
      captionRise, captionCurve, rowLead, rowCurve, tempoFade, tempoCurve);
}

/// Reads an [MotionCurve]'s equation into a function of t: a recursive descent over
///   sum     = product (('+' | '-') product)*
///   product = unary (('*' | '/' | implied) unary)*
///   unary   = ('-' | '+') unary | power
///   power   = atom ('^' unary)?
///   atom    = number | name | name '(' sum (',' sum)* ')' | '(' sum ')'
/// with `a < b ? c : d` (and `<= > >=`) around it all.
class _Parser {
  _Parser(this.text);
  final String text;
  var _at = 0;

  double Function(double) parse() {
    if (text.isEmpty) throw const FormatException('Type an equation in t.');
    final f = _conditional();
    _skip();
    if (_at < text.length) throw FormatException('Unexpected “${text[_at]}”.');
    return f;
  }

  void _skip() {
    while (_at < text.length && ' \t\n'.contains(text[_at])) {
      _at++;
    }
  }

  bool _eat(String s) {
    _skip();
    if (!text.startsWith(s, _at)) return false;
    _at += s.length;
    return true;
  }

  String? get _peek {
    _skip();
    return _at < text.length ? text[_at] : null;
  }

  double Function(double) _conditional() {
    final a = _sum();
    for (final (op, test) in <(String, bool Function(double, double))>[
      ('<=', (x, y) => x <= y),
      ('>=', (x, y) => x >= y),
      ('<', (x, y) => x < y),
      ('>', (x, y) => x > y),
    ]) {
      if (!_eat(op)) continue;
      final b = _sum();
      if (!_eat('?')) throw const FormatException('A comparison needs “? … : …”.');
      final yes = _conditional();
      if (!_eat(':')) throw const FormatException('Missing “:”.');
      final no = _conditional();
      return (t) => test(a(t), b(t)) ? yes(t) : no(t);
    }
    return a;
  }

  double Function(double) _sum() {
    var f = _product();
    while (true) {
      if (_eat('+')) {
        final a = f, b = _product();
        f = (t) => a(t) + b(t);
      } else if (_eat('-')) {
        final a = f, b = _product();
        f = (t) => a(t) - b(t);
      } else {
        return f;
      }
    }
  }

  double Function(double) _product() {
    var f = _unary();
    while (true) {
      final next = _peek;
      if (next == '*' && !text.startsWith('**', _at) || next == '·' || next == '×') {
        _at++;
        final a = f, b = _unary();
        f = (t) => a(t) * b(t);
      } else if (next == '/') {
        _at++;
        final a = f, b = _unary();
        f = (t) => a(t) / b(t);
      } else if (next != null && (next == '(' || _isLetter(next) || _isDigit(next) || next == '.' || next == 'π')) {
        final a = f, b = _power(); // implied: 3t, 2(t+1), t sin(t)
        f = (t) => a(t) * b(t);
      } else {
        return f;
      }
    }
  }

  double Function(double) _unary() {
    if (_eat('-')) {
      final f = _unary();
      return (t) => -f(t);
    }
    if (_eat('+')) return _unary();
    return _power();
  }

  double Function(double) _power() {
    final base = _atom();
    if (_eat('^') || _eat('**')) {
      final exponent = _unary();
      return (t) => math.pow(base(t), exponent(t)).toDouble();
    }
    return base;
  }

  static bool _isDigit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
  static bool _isLetter(String c) {
    final u = c.codeUnitAt(0) | 0x20; // lower case
    return u >= 97 && u <= 122 || c == '_';
  }

  double Function(double) _atom() {
    final c = _peek;
    if (c == null) throw const FormatException('The equation ends too soon.');
    if (_eat('(')) {
      final f = _conditional();
      if (!_eat(')')) throw const FormatException('Missing “)”.');
      return f;
    }
    if (_isDigit(c) || c == '.') {
      final match = RegExp(r'\d*\.?\d+(?:[eE][-+]?\d+)?|\d+\.').matchAsPrefix(text, _at)!;
      _at = match.end;
      final v = double.parse(match[0]!);
      return (_) => v;
    }
    if (c == 'π') {
      _at++;
      return (_) => math.pi;
    }
    if (!_isLetter(c)) throw FormatException('Unexpected “$c”.');
    final name = RegExp(r'[A-Za-z_][A-Za-z_0-9]*').matchAsPrefix(text, _at)![0]!;
    _at += name.length;
    if (_peek == '(') {
      _at++;
      final args = [_conditional()];
      while (_eat(',')) {
        args.add(_conditional());
      }
      if (!_eat(')')) throw const FormatException('Missing “)”.');
      return _function(name.toLowerCase(), args);
    }
    return switch (name) {
      't' || 'x' => (t) => t,
      'pi' || 'PI' => (_) => math.pi,
      'e' => (_) => math.e,
      _ => throw FormatException('Unknown name “$name”.'),
    };
  }

  static double Function(double) _function(String name, List<double Function(double)> args) {
    double Function(double) one(double Function(double) f) {
      if (args.length != 1) throw FormatException('$name takes one value.');
      final a = args[0];
      return (t) => f(a(t));
    }

    double Function(double) exactly(int n, double Function(List<double>) f) {
      if (args.length != n) throw FormatException('$name takes $n values.');
      return (t) => f([for (final a in args) a(t)]);
    }

    double smoothstep(double a, double b, double x) {
      final u = ((x - a) / (b - a)).clamp(0.0, 1.0);
      return u * u * (3 - 2 * u);
    }

    return switch (name) {
      'sin' => one(math.sin),
      'cos' => one(math.cos),
      'tan' => one(math.tan),
      'asin' => one(math.asin),
      'acos' => one(math.acos),
      'atan' => one(math.atan),
      'exp' => one(math.exp),
      'ln' => one(math.log),
      'log' => one((x) => math.log(x) / math.ln10),
      'sqrt' => one(math.sqrt),
      'abs' => one((x) => x.abs()),
      'floor' => one((x) => x.floorToDouble()),
      'ceil' => one((x) => x.ceilToDouble()),
      'round' => one((x) => x.roundToDouble()),
      'sign' => one((x) => x.sign),
      'min' || 'max' when args.length < 2 => throw FormatException('$name takes two values or more.'),
      'min' => (t) => args.map((a) => a(t)).reduce(math.min),
      'max' => (t) => args.map((a) => a(t)).reduce(math.max),
      'pow' => exactly(2, (v) => math.pow(v[0], v[1]).toDouble()),
      'clamp' => exactly(3, (v) => v[0].clamp(math.min(v[1], v[2]), math.max(v[1], v[2]))),
      'mix' => exactly(3, (v) => v[0] + (v[1] - v[0]) * v[2]),
      'smoothstep' => exactly(3, (v) => smoothstep(v[0], v[1], v[2])),
      _ => throw FormatException('Unknown function “$name”.'),
    };
  }
}
