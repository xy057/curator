part of '../lua.dart';

// The standard library: what of Lua 5.4's a script that can reach nothing needs.

void _openBase(Lua lua) {
  final g = lua.globals;
  LuaFunction def(String name, LuaCall fn) {
    final f = LuaBuiltin(name, fn);
    g[name] = f;
    return f;
  }

  List<Object?> callValue(Object? fn, List<Object?> args) {
    if (fn is LuaFunction) return fn.call(args);
    final h = lua._meta(fn, '__call');
    if (h is LuaFunction) return h.call([fn, ...args]);
    throw LuaError('attempt to call a ${Lua.typeOf(fn)} value');
  }

  g['_G'] = g;
  g['_VERSION'] = 'Lua 5.4';

  def('type', (a) {
    if (a.isEmpty) a.bad(0, 'type', 'value expected');
    return [Lua.typeOf(a[0])];
  });
  def('tostring', (a) => [lua.tostring(a.at(0))]);
  def('tonumber', (a) {
    final v = a.at(0), base = a.integerOr(1, 'tonumber');
    if (base == null) {
      if (v is num) return [v];
      if (v is String) return [Lua.toNumber(v)];
      if (a.isEmpty) a.bad(0, 'tonumber', 'value expected');
      return const [null];
    }
    if (base < 2 || base > 36) a.bad(1, 'tonumber', 'base out of range');
    final s = a.string(0, 'tonumber').trim().toLowerCase();
    final negative = s.startsWith('-'), n = int.tryParse(negative ? s.substring(1) : s, radix: base);
    return [n == null ? null : (negative ? -n : n)];
  });
  def('print', (a) {
    lua.print?.call(a.map(lua.tostring).join('\t'));
    return _none;
  });
  def('assert', (a) {
    if (a.isEmpty) a.bad(0, 'assert', 'value expected');
    if (a.truthy(0)) return a;
    throw LuaError(a.length > 1 ? a[1] : 'assertion failed!', level: 0);
  });
  def('error', (a) => throw LuaError(a.at(0), level: a.integerOr(1, 'error') ?? 1));
  def('pcall', (a) {
    if (a.isEmpty) a.bad(0, 'pcall', 'value expected');
    final depth = lua._depth;
    try {
      return [true, ...callValue(a[0], a.sublist(1))];
    } on LuaLimit {
      rethrow;
    } on LuaError catch (e) {
      lua._depth = depth;
      return [false, e.value];
    } on StackOverflowError {
      throw LuaLimit('stack overflow (a function calls itself without end?)');
    } catch (e) {
      lua._depth = depth;
      return [false, '$e'];
    }
  });
  def('xpcall', (a) {
    final handler = a.function(1, 'xpcall'), depth = lua._depth;
    try {
      return [true, ...callValue(a[0], a.sublist(2))];
    } on LuaLimit {
      rethrow;
    } on LuaError catch (e) {
      lua._depth = depth;
      return [false, ...handler.call([e.value])];
    } on StackOverflowError {
      throw LuaLimit('stack overflow (a function calls itself without end?)');
    } catch (e) {
      lua._depth = depth;
      return [false, ...handler.call(['$e'])];
    }
  });
  def('select', (a) {
    final n = a.at(0);
    if (n == '#') return [a.length - 1];
    final i = a.integer(0, 'select');
    if (i < 0) {
      if (-i > a.length - 1) a.bad(0, 'select', 'index out of range');
      lua.spend(-i);
      return a.sublist(a.length + i);
    }
    if (i == 0) a.bad(0, 'select', 'index out of range');
    if (i >= a.length) return _none;
    lua.spend(a.length - i);
    return a.sublist(i);
  });
  def('rawget', (a) => [a.table(0, 'rawget')[a.at(1)]]);
  def('rawset', (a) {
    final t = a.table(0, 'rawset');
    if (a.at(1) == null) throw LuaError('table index is nil');
    t[a.at(1)] = a.at(2);
    return [t];
  });
  def('rawequal', (a) => [a.at(0) == a.at(1)]);
  def('rawlen', (a) {
    final v = a.at(0);
    if (v is LuaTable) return [v.length];
    if (v is String) return [v.length];
    a.bad(0, 'rawlen', 'table or string expected');
  });
  def('setmetatable', (a) {
    final t = a.table(0, 'setmetatable'), mt = a.at(1);
    if (mt != null && mt is! LuaTable) a.bad(1, 'setmetatable', 'nil or table expected');
    if (t.metatable?.field('__metatable') != null) throw LuaError('cannot change a protected metatable');
    t.metatable = mt as LuaTable?;
    return [t];
  });
  def('getmetatable', (a) {
    final v = a.at(0);
    final mt = v is LuaTable ? v.metatable : (v is String ? lua._stringMeta : null);
    return [mt?.field('__metatable') ?? mt];
  });
  lua._next = def('next', (a) {
    final r = a.table(0, 'next').after(a.at(1));
    return r == null ? const [null] : [r.$1, r.$2];
  });
  def('pairs', (a) {
    final v = a.at(0), h = lua._meta(v, '__pairs');
    if (h is LuaFunction) {
      final r = h.call([v]);
      return [r.at(0), r.at(1), r.at(2)];
    }
    return [lua._next, a.table(0, 'pairs'), null];
  });
  lua._inext = LuaBuiltin('ipairs_iterator', (a) {
    final i = a.integer(1, 'ipairs') + 1, t = a.at(0);
    final v = t is LuaTable && t.metatable == null ? t[i] : lua._index(t, i, _library);
    return v == null ? const [null] : [i, v];
  });
  def('ipairs', (a) {
    if (a.isEmpty) a.bad(0, 'ipairs', 'table expected, got no value');
    return [lua._inext, a[0], 0];
  });

  final package = LuaTable()..shape = LuaShape.map;
  package['loaded'] = lua._loaded;
  g['package'] = package;
  final loading = <String>{};
  def('require', (a) {
    final name = a.string(0, 'require');
    final cached = lua._loaded[name];
    if (cached != null) return [cached];
    final found = lua.source?.call(name);
    if (found == null) throw LuaError("module '$name' not found");
    if (!loading.add(name)) throw LuaError("module '$name' requires itself");
    try {
      final r = lua.load(found.code, chunk: found.chunk).call([name]);
      final value = r.at(0) ?? true;
      lua._loaded[name] = value;
      return [value];
    } finally {
      loading.remove(name);
    }
  });
  LuaCall loader(String fn) => (a) {
        final code = a.at(0);
        if (code is! String) return [null, "'$fn' takes the code as a string"];
        lua.spend(code.length);
        try {
          return [lua.load(code, chunk: a.stringOr(1, fn) ?? 'loaded')];
        } on LuaError catch (e) {
          return [null, e.value];
        }
      };
  def('load', loader('load'));
  def('loadstring', loader('loadstring'));
  def('collectgarbage', (a) => const [0]);

  // Named so that code written for them says why it can't run, rather than "nil value".
  final coroutine = LuaTable()..shape = LuaShape.map;
  for (final name in const ['create', 'resume', 'yield', 'wrap', 'status', 'running', 'isyieldable', 'close']) {
    coroutine[name] = LuaBuiltin('coroutine.$name', (_) => throw LuaError("coroutines aren't available here"));
  }
  g['coroutine'] = coroutine;
}

void _openTable(Lua lua) {
  bool less(Object? x, Object? y) => lua._less(x, y, _library);

  final table = Lua.library('table', {
    'insert': (a) {
      final t = a.table(0, 'insert'), n = t.length;
      if (a.length == 2) {
        t[n + 1] = a[1];
      } else if (a.length == 3) {
        final pos = a.integer(1, 'insert');
        if (pos < 1 || pos > n + 1) a.bad(1, 'insert', 'position out of bounds');
        t.array.insert(pos - 1, a[2]);
        t._settle();
      } else {
        throw LuaError("wrong number of arguments to 'insert'");
      }
      if (t.array.length > Lua.maxLength) throw lua._tooBig();
      return _none;
    },
    'remove': (a) {
      final t = a.table(0, 'remove'), n = t.length;
      final pos = a.integerOr(1, 'remove');
      if (pos == null) {
        if (n == 0) return const [null];
        final v = t.array.removeLast();
        t._settle();
        return [v];
      }
      if (n == 0 && (pos == 0 || pos == n)) return [t[pos]];
      if (n + 1 == pos) {
        final v = t[pos];
        t[pos] = null;
        return [v];
      }
      if (pos < 1 || pos > n + 1) a.bad(1, 'remove', 'position out of bounds');
      final v = t.array.removeAt(pos - 1);
      t._settle();
      return [v];
    },
    'concat': (a) {
      final t = a.table(0, 'concat'), sep = a.stringOr(1, 'concat') ?? '';
      final i = a.integerOr(2, 'concat') ?? 1, j = a.integerOr(3, 'concat') ?? t.length;
      final out = StringBuffer();
      for (var k = i; k <= j; k++) {
        final v = t[k];
        if (v is! String && v is! num) throw LuaError("invalid value (at index $k) in table for 'concat'");
        if (k > i) out.write(sep);
        out.write(Lua.show(v));
        if (out.length > Lua.maxLength) throw lua._tooBig();
      }
      lua.steps -= out.length >> 6;
      return [out.toString()];
    },
    'unpack': (a) => _unpack(lua, a, 'unpack'),
    'pack': (a) {
      lua.spend(a.length);
      return [LuaTable.list(a)..['n'] = a.length];
    },
    'sort': (a) {
      final t = a.table(0, 'sort'), by = a.functionOr(1, 'sort');
      final list = t.array;
      lua.steps -= list.length;
      if (lua.steps < 0) throw lua._tooLong();
      bool before(Object? x, Object? y) {
        if (by == null) return x is num && y is num ? x < y : less(x, y);
        final r = by.call([x, y]);
        return r.isNotEmpty && _truthy(r[0]);
      }

      list.sort((x, y) => before(x, y) ? -1 : (before(y, x) ? 1 : 0));
      return _none;
    },
    'move': (a) {
      final from = a.table(0, 'move'), f = a.integer(1, 'move'), e = a.integer(2, 'move'), t = a.integer(3, 'move');
      final to = a.tableOr(4, 'move') ?? from;
      if (e >= f) {
        if (e - f > Lua.maxLength) throw lua._tooBig();
        lua.steps -= e - f; // a value at a time, as a loop moving them would spend
        if (lua.steps < 0) throw lua._tooLong();
        if (t > e || t <= f || !identical(to, from)) {
          for (var i = 0; i <= e - f; i++) {
            to[t + i] = from[f + i];
          }
        } else {
          for (var i = e - f; i >= 0; i--) {
            to[t + i] = from[f + i];
          }
        }
      }
      return [to];
    },
  });
  lua.globals['table'] = table;
  lua.globals['unpack'] = LuaBuiltin('unpack', (a) => _unpack(lua, a, 'unpack'));
}

List<Object?> _unpack(Lua lua, List<Object?> a, String fn) {
  final t = a.table(0, fn), i = a.integerOr(1, fn) ?? 1, j = a.integerOr(2, fn) ?? t.length;
  if (j < i) return _none;
  if (j - i >= 1000000) throw LuaError('too many results to unpack');
  lua.spend(j - i + 1);
  return List<Object?>.generate(j - i + 1, (k) => t[i + k], growable: false);
}

void _openMath(Lua lua) {
  // The same numbers everywhere: Dart's own Random differs between the app and a web page.
  var seed = 0x2545F491;
  int next() {
    var x = seed;
    x = (x ^ (x << 13)) & 0xFFFFFFFF;
    x = x ^ (x >>> 17);
    x = (x ^ (x << 5)) & 0xFFFFFFFF;
    return seed = x;
  }

  Object? whole(num x) => x is int ? x : (x.isFinite ? x.toInt() : x);

  final m = Lua.library('math', {
    'abs': (a) => [a.number(0, 'abs').abs()],
    'ceil': (a) {
      final x = a.number(0, 'ceil');
      return [x is int || !x.isFinite ? x : x.ceil()];
    },
    'floor': (a) {
      final x = a.number(0, 'floor');
      return [x is int || !x.isFinite ? x : x.floor()];
    },
    // Not Lua's: to the nearest whole number, a half away from zero (as Dart rounds).
    'round': (a) {
      final x = a.number(0, 'round');
      return [x is int || !x.isFinite ? x : x.round()];
    },
    // Not Lua's: x no lower than low and no higher than high (as Dart clamps).
    'clamp': (a) {
      final low = a.number(1, 'clamp'), high = a.number(2, 'clamp');
      if (low.compareTo(high) > 0) a.bad(2, 'clamp', 'the highest is under the lowest');
      return [a.number(0, 'clamp').clamp(low, high)];
    },
    'sqrt': (a) => [math.sqrt(a.number(0, 'sqrt'))],
    'sin': (a) => [math.sin(a.number(0, 'sin'))],
    'cos': (a) => [math.cos(a.number(0, 'cos'))],
    'tan': (a) => [math.tan(a.number(0, 'tan'))],
    'asin': (a) => [math.asin(a.number(0, 'asin'))],
    'acos': (a) => [math.acos(a.number(0, 'acos'))],
    'atan': (a) => [math.atan2(a.number(0, 'atan'), a.numberOr(1, 'atan') ?? 1)],
    'exp': (a) => [math.exp(a.number(0, 'exp'))],
    'log': (a) {
      final x = a.number(0, 'log'), base = a.numberOr(1, 'log');
      if (base == null) return [math.log(x)];
      if (base == 2) return [math.log(x) / math.ln2];
      if (base == 10) return [math.log(x) / math.ln10];
      return [math.log(x) / math.log(base)];
    },
    'log10': (a) => [math.log(a.number(0, 'log10')) / math.ln10],
    'pow': (a) => [math.pow(a.number(0, 'pow').toDouble(), a.number(1, 'pow').toDouble())],
    'fmod': (a) {
      final x = a.number(0, 'fmod'), y = a.number(1, 'fmod');
      if (y == 0) return [double.nan];
      return [x.remainder(y)];
    },
    'modf': (a) {
      final x = a.number(0, 'modf');
      if (x.isInfinite) return [x, 0.0];
      final whole = x.truncateToDouble();
      return [whole, x.isNaN ? x : x - whole];
    },
    'max': (a) {
      var best = a.number(0, 'max');
      for (var i = 1; i < a.length; i++) {
        final v = a.number(i, 'max');
        if (v > best) best = v;
      }
      return [best];
    },
    'min': (a) {
      var best = a.number(0, 'min');
      for (var i = 1; i < a.length; i++) {
        final v = a.number(i, 'min');
        if (v < best) best = v;
      }
      return [best];
    },
    'deg': (a) => [a.number(0, 'deg') * 180 / math.pi],
    'rad': (a) => [a.number(0, 'rad') * math.pi / 180],
    'random': (a) {
      final r = next() / 4294967296.0;
      if (a.isEmpty) return [r];
      final lo = a.length == 1 ? 1 : a.integer(0, 'random'), hi = a.integer(a.length == 1 ? 0 : 1, 'random');
      if (lo > hi) a.bad(a.length == 1 ? 0 : 1, 'random', 'interval is empty');
      return [lo + (r * (hi - lo + 1)).floor()];
    },
    'randomseed': (a) {
      final x = a.numberOr(0, 'randomseed') ?? 0;
      seed = (x.isFinite ? x.toInt() & 0xFFFFFFFF : 0) ^ 0x2545F491;
      if (seed == 0) seed = 0x2545F491;
      return _none;
    },
    'tointeger': (a) {
      final x = a.at(0);
      return [x is num && x.isFinite && x == x.truncateToDouble() ? whole(x) : null];
    },
    'type': (a) {
      if (a.isEmpty) a.bad(0, 'type', 'value expected');
      final x = a[0];
      if (x is! num) return const [null];
      return [x.isFinite && x == x.truncateToDouble() ? 'integer' : 'float'];
    },
  });
  m['pi'] = math.pi;
  m['huge'] = double.infinity;
  m['maxinteger'] = 9007199254740991;
  m['mininteger'] = -9007199254740991;
  lua.globals['math'] = m;
}

void _openOs(Lua lua) {
  final started = Stopwatch()..start();
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  String two(int n) => n.toString().padLeft(2, '0');

  lua.globals['os'] = Lua.library('os', {
    'time': (a) {
      final t = a.tableOr(0, 'time');
      if (t == null) return [DateTime.now().millisecondsSinceEpoch ~/ 1000];
      int field(String name, [int? otherwise]) {
        final v = t[name];
        if (v is num) return v.toInt();
        if (otherwise == null) throw LuaError("field '$name' missing in date table");
        return otherwise;
      }

      final at = DateTime(field('year'), field('month'), field('day'), field('hour', 12), field('min', 0), field('sec', 0));
      return [at.millisecondsSinceEpoch ~/ 1000];
    },
    'clock': (a) => [started.elapsedMicroseconds / 1e6],
    'difftime': (a) => [a.number(0, 'difftime') - (a.numberOr(1, 'difftime') ?? 0)],
    'getenv': (a) => const [null],
    'date': (a) {
      var format = a.stringOr(0, 'date') ?? '%c';
      final seconds = a.numberOr(1, 'date');
      var at = seconds == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
      if (format.startsWith('!')) {
        at = at.toUtc();
        format = format.substring(1);
      }
      if (format.startsWith('*t')) {
        return [
          LuaTable.map({
            'year': at.year, 'month': at.month, 'day': at.day, 'hour': at.hour, 'min': at.minute, 'sec': at.second, //
            'wday': at.weekday % 7 + 1, 'yday': at.difference(DateTime(at.year)).inDays + 1, 'isdst': false,
          }),
        ];
      }
      final out = StringBuffer();
      for (var i = 0; i < format.length; i++) {
        final c = format[i];
        if (c != '%' || i + 1 >= format.length) {
          out.write(c);
          continue;
        }
        final hour12 = at.hour % 12 == 0 ? 12 : at.hour % 12;
        out.write(switch (format[++i]) {
          'Y' => at.year,
          'y' => two(at.year % 100),
          'm' => two(at.month),
          'd' => two(at.day),
          'H' => two(at.hour),
          'I' => two(hour12),
          'M' => two(at.minute),
          'S' => two(at.second),
          'p' => at.hour < 12 ? 'AM' : 'PM',
          'B' => months[at.month - 1],
          'b' => months[at.month - 1].substring(0, 3),
          'A' => days[at.weekday - 1],
          'a' => days[at.weekday - 1].substring(0, 3),
          'j' => (at.difference(DateTime(at.year)).inDays + 1).toString().padLeft(3, '0'),
          'c' => '${at.year}-${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}:${two(at.second)}',
          'x' => '${at.year}-${two(at.month)}-${two(at.day)}',
          'X' => '${two(at.hour)}:${two(at.minute)}:${two(at.second)}',
          '%' => '%',
          final other => throw LuaError("bad argument #1 to 'date' (invalid conversion specifier '%$other')"),
        });
      }
      return [out.toString()];
    },
  });
}

void _openUtf8(Lua lua) {
  final utf8 = Lua.library('utf8', {
    'char': (a) => [lua._made(String.fromCharCodes([for (var i = 0; i < a.length; i++) a.integer(i, 'char')]))],
    'len': (a) {
      final s = a.string(0, 'len');
      final i = _from(a.integerOr(1, 'len') ?? 1, s.length), j = _to(a.integerOr(2, 'len') ?? -1, s.length);
      return [i > j ? 0 : s.substring(i - 1, j).runes.length];
    },
    'codepoint': (a) {
      final s = a.string(0, 'codepoint');
      final i = _from(a.integerOr(1, 'codepoint') ?? 1, s.length), j = _to(a.integerOr(2, 'codepoint') ?? i, s.length);
      if (i > j) return _none;
      lua.spend(j - i + 1);
      return s.substring(i - 1, j).runes.toList();
    },
    'codes': (a) {
      final s = a.string(0, 'codes');
      return [
        LuaBuiltin('utf8.codes_iterator', (b) {
          var at = b.integer(1, 'codes');
          // Past the character at `at` (two units when it is a pair).
          if (at > 0) at += at <= s.length && s.codeUnitAt(at - 1) & 0xFC00 == 0xD800 && at < s.length ? 2 : 1;
          if (at == 0) at = 1;
          if (at > s.length) return const [null];
          final unit = s.codeUnitAt(at - 1);
          if (unit & 0xFC00 == 0xD800 && at < s.length) {
            return [at, 0x10000 + ((unit & 0x3FF) << 10) + (s.codeUnitAt(at) & 0x3FF)];
          }
          return [at, unit];
        }),
        s,
        0,
      ];
    },
  });
  utf8['charpattern'] = '[\u0000-퟿-￿]';
  lua.globals['utf8'] = utf8;
}

/// A string's start index as Lua counts (from 1; negative from the end), kept in it.
int _from(int i, int length) {
  if (i < 0) i = length + i + 1;
  return i < 1 ? 1 : i;
}

/// A string's end index as Lua counts, kept in it.
int _to(int j, int length) {
  if (j < 0) j = length + j + 1;
  return j > length ? length : j;
}
