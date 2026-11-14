/// Lua, run in Dart: the language extensions are written in (see docs/extensions.md).
///
/// It is Lua 5.4 as it is written, read into a tree and turned into Dart closures ([Lua.load]),
/// so it runs wherever the engine does, a web page's player too, and can reach nothing but what
/// it is given: there is no `io`, no `os.execute`, no `debug`. What differs from Lua 5.4:
/// numbers are one kind (3 / 1 is 3, as in Lua 5.1), a string is text (its length counts UTF-16
/// units, not bytes), bitwise operators work on 32 bits, and there are no coroutines and no
/// `<close>` variables. A script is stopped past a number of steps ([Lua.steps]), past a depth
/// of calls and past a size of string or list, by a [LuaLimit] that `pcall` doesn't catch.
library;

import 'dart:math' as math;

part 'lua/value.dart';
part 'lua/parser.dart';
part 'lua/interp.dart';
part 'lua/lib.dart';
part 'lua/strings.dart';

/// One Lua world: its globals, and the code loaded into it.
final class Lua {
  Lua({this.print}) {
    _openBase(this);
    _openString(this);
    _openTable(this);
    _openMath(this);
    _openOs(this);
    _openUtf8(this);
  }

  /// The steps a call from the host may take when it names no number: a call or a turn of a
  /// loop is one.
  static const defaultSteps = 10000000;

  /// How deep calls may go.
  static const maxDepth = 200;

  /// The most a string's characters or a list's values may be.
  static const maxLength = 1 << 26;

  /// Every global, `print` and `string` among them.
  final LuaTable globals = LuaTable();

  /// What `print` writes a line to.
  void Function(String line)? print;

  /// A module by the name `require` was given ("draw", "util.text"): its code, and the file
  /// name its errors say; null: there is none.
  ({String chunk, String code})? Function(String name)? source;

  /// What is left of the steps allowed.
  int steps = defaultSteps;
  int _depth = 0;

  final LuaTable _stringMeta = LuaTable();
  late final LuaFunction _next, _inext;
  final LuaTable _loaded = LuaTable();

  /// [source] as a function that runs it: nothing has run yet. A syntax error is a [LuaError]
  /// naming [chunk] and the line.
  LuaFunction load(String source, {String chunk = 'chunk'}) {
    try {
      final proto = _Parser(source, chunk).parseChunk();
      return LuaClosure._(this, _Compiler(this, chunk).code(proto), const []);
    } on StackOverflowError {
      throw _syntax(chunk, 1, 'the code is nested too deeply');
    }
  }

  /// Calls [fn] from the host with [steps] to spend: its values, or a [LuaError] (whatever
  /// went wrong made one).
  List<Object?> call(LuaFunction fn, [List<Object?> args = const [], int? steps]) {
    final outer = _depth == 0;
    if (outer) this.steps = steps ?? defaultSteps;
    try {
      return fn.call(args);
    } on LuaError {
      rethrow;
    } on StackOverflowError {
      throw LuaLimit('stack overflow (a function calls itself without end?)');
    } catch (e) {
      throw LuaError('$e', level: 0);
    } finally {
      if (outer) _depth = 0;
    }
  }

  /// Loads [source] and runs it: what it returns.
  List<Object?> run(String source, {String chunk = 'chunk', int? steps}) => call(load(source, chunk: chunk), const [], steps);

  /// A host function as the global [name].
  void register(String name, LuaCall fn) => globals[name] = LuaBuiltin(name, fn);

  /// A table of host functions, each named `<name>.<key>` in errors.
  static LuaTable library(String name, Map<String, LuaCall> functions) {
    final t = LuaTable()..shape = LuaShape.map;
    functions.forEach((key, fn) => t[key] = LuaBuiltin('$name.$key', fn));
    return t;
  }

  // MARK: Values

  /// `type(v)`.
  static String typeOf(Object? v) => switch (v) {
        null => 'nil',
        bool() => 'boolean',
        num() => 'number',
        String() => 'string',
        LuaTable() => 'table',
        LuaFunction() => 'function',
        _ => 'userdata',
      };

  /// A number as Lua writes it: a whole one without a fraction.
  static String number(num n) {
    if (n is int) return n.toString();
    if (n.isNaN) return 'nan';
    if (n.isInfinite) return n > 0 ? 'inf' : '-inf';
    if (n == n.truncateToDouble() && n.abs() < 1e15) return n.toInt().toString();
    return n.toString();
  }

  /// `tostring(v)` without metamethods.
  static String show(Object? v) => switch (v) {
        null => 'nil',
        true => 'true',
        false => 'false',
        final num n => number(n),
        final String s => s,
        LuaTable() => 'table: 0x${identityHashCode(v).toRadixString(16).padLeft(8, '0')}',
        LuaClosure() => 'function: 0x${identityHashCode(v).toRadixString(16).padLeft(8, '0')}',
        LuaFunction(:final name) => 'function: builtin: $name',
        _ => 'userdata: ${v.runtimeType}',
      };

  static final _decimal = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$'), _hexadecimal = RegExp(r'^[+-]?0[xX][0-9a-fA-F]+$');

  /// A string read as a number, as Lua's arithmetic and `tonumber` read one; null: it isn't.
  static num? toNumber(String s) {
    s = s.trim();
    if (_decimal.hasMatch(s)) return int.tryParse(s) ?? double.tryParse(s);
    if (_hexadecimal.hasMatch(s)) {
      final negative = s.startsWith('-'), digits = s.substring(s.toLowerCase().indexOf('x') + 1);
      final v = int.tryParse(digits, radix: 16);
      if (v == null) return null;
      return negative ? -v : v;
    }
    return null;
  }

  /// `tostring(v)`.
  String tostring(Object? v) {
    final h = _meta(v, '__tostring');
    if (h is LuaFunction) {
      final r = h.call([v]);
      final s = r.isEmpty ? null : r[0];
      if (s is! String) throw LuaError("'__tostring' must return a string");
      return s;
    }
    if (v is LuaTable) {
      final name = v.metatable?.field('__name');
      if (name is String) return '$name: 0x${identityHashCode(v).toRadixString(16).padLeft(8, '0')}';
    }
    return show(v);
  }

  Object? _meta(Object? v, String event) {
    if (v is LuaTable) return v.metatable?.field(event);
    if (v is String) return _stringMeta.field(event);
    return null;
  }

  LuaLimit _tooLong() => LuaLimit('the script ran too long and was stopped');
  LuaLimit _tooBig() => LuaLimit('a string or list grew too long');

  // MARK: What the operators do past the plain cases

  static String _suffix(String? what) => what == null ? '' : ' ($what)';

  List<Object?> _invoke(Object? fn, List<Object?> args, _Site at) {
    try {
      if (fn is LuaFunction) return fn.call(args);
      final h = _meta(fn, '__call');
      if (h is LuaFunction) return h.call([fn, ...args]);
    } on LuaError catch (e) {
      at.place(e);
      rethrow;
    } on StackOverflowError {
      throw LuaLimit('stack overflow (a function calls itself without end?)');
    } catch (e) {
      // Something of the host's went wrong: Lua's error all the same, so it says where.
      throw at.error('$e');
    }
    throw at.error('attempt to call a ${typeOf(fn)} value${_suffix(at.what)}');
  }

  Object? _index(Object? o, Object? k, _Site at) {
    for (var loop = 0; loop < 100; loop++) {
      Object? h;
      if (o is LuaTable) {
        final v = o[k];
        if (v != null) return v;
        h = o.metatable?.field('__index');
        if (h == null) return null;
      } else if (o is String) {
        h = _stringMeta.field('__index');
      } else {
        throw at.error('attempt to index a ${typeOf(o)} value${_suffix(at.what)}');
      }
      if (h is LuaFunction) {
        final r = _invoke(h, [o, k], at);
        return r.isEmpty ? null : r[0];
      }
      o = h;
    }
    throw at.error("'__index' chain too long; possibly a loop");
  }

  void _setIndex(Object? o, Object? k, Object? v, _Site at) {
    for (var loop = 0; loop < 100; loop++) {
      if (o is! LuaTable) throw at.error('attempt to index a ${typeOf(o)} value${_suffix(at.what)}');
      final h = o.metatable?.field('__newindex');
      if (h == null || o[k] != null) {
        if (k == null) throw at.error('table index is nil');
        if (k is double && k.isNaN) throw at.error('table index is NaN');
        o[k] = v;
        if (o.array.length > maxLength) throw _tooBig();
        return;
      }
      if (h is LuaFunction) {
        _invoke(h, [o, k, v], at);
        return;
      }
      o = h;
    }
    throw at.error("'__newindex' chain too long; possibly a loop");
  }

  static num? _numberOf(Object? v) => v is num ? v : (v is String ? toNumber(v) : null);

  static num _mod(num a, num b) {
    if (b == 0) return double.nan;
    final r = a % b;
    return r != 0 && b < 0 ? r + b : r;
  }

  static num _idiv(num a, num b) {
    if (a is int && b is int && b != 0) {
      final q = a ~/ b;
      return a % b != 0 && (a < 0) != (b < 0) ? q - 1 : q;
    }
    return (a / b).floorToDouble();
  }

  static const _bitwise = {'band', 'bor', 'bxor', 'shl', 'shr', 'bnot'};

  Object? _arith(String op, Object? x, Object? y, _Site at) {
    final a = _numberOf(x), b = op == 'unm' || op == 'bnot' ? a : _numberOf(y);
    if (a != null && b != null) {
      switch (op) {
        case 'add':
          return a + b;
        case 'sub':
          return a - b;
        case 'mul':
          return a * b;
        case 'div':
          return a / b;
        case 'mod':
          return _mod(a, b);
        case 'idiv':
          return _idiv(a, b);
        case 'pow':
          return math.pow(a.toDouble(), b.toDouble());
        case 'unm':
          return -a;
      }
      int whole(num v) {
        if (v is int) return v;
        if (v.isFinite && v == v.truncateToDouble()) return v.toInt();
        throw at.error('number has no integer representation');
      }

      const mask = 0xFFFFFFFF;
      final i = whole(a) & mask, j = whole(b);
      switch (op) {
        case 'band':
          return i & (j & mask);
        case 'bor':
          return i | (j & mask);
        case 'bxor':
          return i ^ (j & mask);
        case 'bnot':
          return ~i & mask;
        case 'shl':
          return j >= 32 || j <= -32 ? 0 : (j >= 0 ? (i << j) & mask : i >>> -j);
        case 'shr':
          return j >= 32 || j <= -32 ? 0 : (j >= 0 ? i >>> j : (i << -j) & mask);
      }
    }
    final h = _meta(x, '__$op') ?? _meta(y, '__$op');
    if (h is LuaFunction) {
      final r = _invoke(h, [x, y], at);
      return r.isEmpty ? null : r[0];
    }
    final second = a != null, bad = second ? y : x, what = second ? at.what2 : at.what;
    if (_bitwise.contains(op) && bad is num) throw at.error('number has no integer representation');
    final doing = _bitwise.contains(op) ? 'perform bitwise operation on' : 'perform arithmetic on';
    throw at.error('attempt to $doing a ${typeOf(bad)} value${_suffix(what)}');
  }

  Object? _concat(Object? x, Object? y, _Site at) {
    if ((x is String || x is num) && (y is String || y is num)) {
      final s = show(x) + show(y);
      if (s.length > maxLength) throw _tooBig();
      steps -= s.length >> 6;
      return s;
    }
    final h = _meta(x, '__concat') ?? _meta(y, '__concat');
    if (h is LuaFunction) {
      final r = _invoke(h, [x, y], at);
      return r.isEmpty ? null : r[0];
    }
    final second = x is String || x is num;
    throw at.error('attempt to concatenate a ${typeOf(second ? y : x)} value${_suffix(second ? at.what2 : at.what)}');
  }

  bool _equals(Object? x, Object? y) {
    if (x is LuaTable && y is LuaTable) {
      final h = x.metatable?.field('__eq') ?? y.metatable?.field('__eq');
      if (h is LuaFunction) {
        final r = h.call([x, y]);
        return r.isNotEmpty && _truthy(r[0]);
      }
    }
    return false;
  }

  Never _incomparable(Object? x, Object? y, _Site at) {
    final a = typeOf(x), b = typeOf(y);
    throw at.error(a == b ? 'attempt to compare two $a values' : 'attempt to compare $a with $b');
  }

  bool _less(Object? x, Object? y, _Site at) {
    if (x is num && y is num) return x < y;
    if (x is String && y is String) return x.compareTo(y) < 0;
    final h = _meta(x, '__lt') ?? _meta(y, '__lt');
    if (h is LuaFunction) {
      final r = _invoke(h, [x, y], at);
      return r.isNotEmpty && _truthy(r[0]);
    }
    _incomparable(x, y, at);
  }

  bool _lessEqual(Object? x, Object? y, _Site at) {
    if (x is num && y is num) return x <= y;
    if (x is String && y is String) return x.compareTo(y) <= 0;
    final h = _meta(x, '__le') ?? _meta(y, '__le');
    if (h is LuaFunction) {
      final r = _invoke(h, [x, y], at);
      return r.isNotEmpty && _truthy(r[0]);
    }
    _incomparable(x, y, at);
  }

  Object? _length(Object? x, _Site at) {
    if (x is String) return x.length;
    final h = _meta(x, '__len');
    if (h is LuaFunction) {
      final r = _invoke(h, [x], at);
      return r.isEmpty ? null : r[0];
    }
    if (x is LuaTable) return x.array.length;
    throw at.error('attempt to get length of a ${typeOf(x)} value${_suffix(at.what)}');
  }
}

/// What a host function reads its arguments with: each says what was expected when it isn't
/// there ("bad argument #2 to 'insert' (number expected, got nil)").
extension LuaArgs on List<Object?> {
  Object? at(int i) => i < length ? this[i] : null;

  Never bad(int i, String fn, String message) => throw LuaError("bad argument #${i + 1} to '$fn' ($message)");

  String _got(int i) => i < length ? Lua.typeOf(this[i]) : 'no value';

  num number(int i, String fn) {
    final v = at(i);
    if (v is num) return v;
    if (v is String) {
      final n = Lua.toNumber(v);
      if (n != null) return n;
    }
    bad(i, fn, 'number expected, got ${_got(i)}');
  }

  num? numberOr(int i, String fn) => at(i) == null ? null : number(i, fn);

  int integer(int i, String fn) {
    final n = number(i, fn);
    if (n is int) return n;
    if (n.isFinite && n == n.truncateToDouble()) return n.toInt();
    bad(i, fn, 'number has no integer representation');
  }

  int? integerOr(int i, String fn) => at(i) == null ? null : integer(i, fn);

  String string(int i, String fn) {
    final v = at(i);
    if (v is String) return v;
    if (v is num) return Lua.number(v);
    bad(i, fn, 'string expected, got ${_got(i)}');
  }

  String? stringOr(int i, String fn) => at(i) == null ? null : string(i, fn);

  LuaTable table(int i, String fn) {
    final v = at(i);
    if (v is LuaTable) return v;
    bad(i, fn, 'table expected, got ${_got(i)}');
  }

  LuaTable? tableOr(int i, String fn) => at(i) == null ? null : table(i, fn);

  LuaFunction function(int i, String fn) {
    final v = at(i);
    if (v is LuaFunction) return v;
    bad(i, fn, 'function expected, got ${_got(i)}');
  }

  LuaFunction? functionOr(int i, String fn) => at(i) == null ? null : function(i, fn);

  /// Whether the argument is neither nil nor false.
  bool truthy(int i) => _truthy(at(i));
}
