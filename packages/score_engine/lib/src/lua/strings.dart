part of '../lua.dart';

// The string library: Lua's patterns (find, match, gmatch, gsub) and format, over a string's
// UTF-16 units.

void _openString(Lua lua) {
  final string = Lua.library('string', {
    'len': (a) => [a.string(0, 'len').length],
    'sub': (a) {
      final s = a.string(0, 'sub');
      final i = _from(a.integerOr(1, 'sub') ?? 1, s.length), j = _to(a.integerOr(2, 'sub') ?? -1, s.length);
      return [i > j ? '' : lua._made(s.substring(i - 1, j))];
    },
    'upper': (a) => [lua._made(a.string(0, 'upper').toUpperCase())],
    'lower': (a) => [lua._made(a.string(0, 'lower').toLowerCase())],
    'rep': (a) {
      final s = a.string(0, 'rep'), n = a.integer(1, 'rep'), sep = a.stringOr(2, 'rep') ?? '';
      if (n <= 0) return const [''];
      if ((s.length + sep.length) * n > Lua.maxLength) throw lua._tooBig();
      lua.steps -= ((s.length + sep.length) * n) >> 6;
      return [sep.isEmpty ? s * n : List.filled(n, s).join(sep)];
    },
    'reverse': (a) => [lua._made(String.fromCharCodes(a.string(0, 'reverse').codeUnits.reversed))],
    'byte': (a) {
      final s = a.string(0, 'byte');
      final i = _from(a.integerOr(1, 'byte') ?? 1, s.length), j = _to(a.integerOr(2, 'byte') ?? i, s.length);
      if (i > j) return _none;
      lua.spend(j - i + 1);
      return s.substring(i - 1, j).codeUnits;
    },
    'char': (a) => [lua._made(String.fromCharCodes([for (var i = 0; i < a.length; i++) a.integer(i, 'char')]))],
    'format': (a) => [lua._made(_format(lua, a))],
    'find': (a) => _find(lua, a, true),
    'match': (a) => _find(lua, a, false),
    'gmatch': (a) {
      final s = a.string(0, 'gmatch'), pattern = a.string(1, 'gmatch');
      final m = _Matcher(lua, s, pattern);
      var at = 0, last = -1;
      return [
        LuaBuiltin('gmatch_iterator', (_) {
          for (; at <= s.length; at++) {
            m.reset();
            final e = m.match(at, 0);
            if (e != -1 && e != last) {
              final from = at;
              at = last = e;
              return m.captures(from, e, true);
            }
          }
          return const [null];
        }),
      ];
    },
    'gsub': (a) {
      final s = a.string(0, 'gsub');
      var pattern = a.string(1, 'gsub');
      final repl = a.at(2), limit = a.integerOr(3, 'gsub') ?? s.length + 1;
      if (repl is! String && repl is! num && repl is! LuaTable && repl is! LuaFunction) {
        a.bad(2, 'gsub', 'string/function/table expected, got ${a.length > 2 ? Lua.typeOf(repl) : 'no value'}');
      }
      final anchor = pattern.startsWith('^');
      if (anchor) pattern = pattern.substring(1);
      final m = _Matcher(lua, s, pattern), out = StringBuffer();
      var at = 0, last = -1, count = 0;
      while (count < limit) {
        m.reset();
        final e = m.match(at, 0);
        if (e != -1 && e != last) {
          count++;
          final whole = s.substring(at, e);
          Object? value;
          if (repl is String || repl is num) {
            final text = Lua.show(repl), b = StringBuffer();
            for (var i = 0; i < text.length; i++) {
              final c = text.codeUnitAt(i);
              if (c != 0x25) {
                b.writeCharCode(c);
                continue;
              }
              i++;
              final d = i < text.length ? text.codeUnitAt(i) : -1;
              if (d == 0x25) {
                b.write('%');
              } else if (d >= 0x30 && d <= 0x39) {
                final capture = d == 0x30 ? whole : m.capture(d - 0x31, at, e);
                b.write(Lua.show(capture));
              } else {
                throw LuaError("invalid use of '%' in replacement string");
              }
            }
            value = b.toString();
          } else {
            final first = m.capture(0, at, e);
            if (repl is LuaTable) {
              value = lua._index(repl, first, _library);
            } else {
              final r = (repl as LuaFunction).call(m.captures(at, e, true));
              value = r.isEmpty ? null : r[0];
            }
            if (value == null || identical(value, false)) {
              value = whole;
            } else if (value is! String && value is! num) {
              throw LuaError('invalid replacement value (a ${Lua.typeOf(value)})');
            }
          }
          out.write(Lua.show(value));
          at = last = e;
        } else if (at < s.length) {
          out.writeCharCode(s.codeUnitAt(at++));
        } else {
          break;
        }
        if (anchor) break;
        if (out.length > Lua.maxLength) throw lua._tooBig();
      }
      if (at < s.length) out.write(s.substring(at));
      return [lua._made(out.toString()), count];
    },
  });
  lua.globals['string'] = string;
  lua._stringMeta['__index'] = string;
}

List<Object?> _find(Lua lua, List<Object?> a, bool find) {
  final fn = find ? 'find' : 'match';
  final s = a.string(0, fn);
  var pattern = a.string(1, fn);
  var init = a.integerOr(2, fn) ?? 1;
  if (init < 0) {
    init = s.length + init + 1;
    if (init < 1) init = 1;
  } else if (init == 0) {
    init = 1;
  }
  if (init > s.length + 1) return const [null];
  const specials = r'^$*+?.([%-';
  if (find && (a.truthy(3) || !pattern.split('').any(specials.contains))) {
    final at = s.indexOf(pattern, init - 1);
    return at < 0 ? const [null] : [at + 1, at + pattern.length];
  }
  final anchor = pattern.startsWith('^');
  if (anchor) pattern = pattern.substring(1);
  final m = _Matcher(lua, s, pattern);
  var at = init - 1;
  do {
    m.reset();
    final e = m.match(at, 0);
    if (e != -1) {
      if (find) return [at + 1, e, ...m.captures(at, e, false)];
      return m.captures(at, e, true);
    }
  } while (at++ < s.length && !anchor);
  return const [null];
}

/// Lua's pattern matching, as lstrlib.c does it.
final class _Matcher {
  _Matcher(this.lua, this.src, this.pat);
  final Lua lua;
  final String src, pat;
  static const _unfinished = -1, _position = -2, _most = 32;
  int level = 0, _depth = 0;
  final _start = List<int>.filled(_most, 0), _length = List<int>.filled(_most, 0);

  void reset() {
    level = 0;
    _depth = 0;
  }

  int _p(int i) => i < pat.length ? pat.codeUnitAt(i) : -1;

  /// Where a match of the pattern from [p] on, starting at [s], ends; -1: there is none.
  int match(int s, int p) {
    if (--lua.steps < 0) throw lua._tooLong();
    if (++_depth > 180) throw LuaError('pattern too complex');
    try {
      while (true) {
        if (p >= pat.length) return s;
        final c = pat.codeUnitAt(p);
        if (c == 0x28) {
          // (
          if (_p(p + 1) == 0x29) return _open(s, p + 2, _position);
          return _open(s, p + 1, _unfinished);
        }
        if (c == 0x29) return _close(s, p + 1);
        if (c == 0x24 && p + 1 == pat.length) return s == src.length ? s : -1;
        if (c == 0x25) {
          final d = _p(p + 1);
          if (d == 0x62) {
            // %b
            s = _balance(s, p + 2);
            if (s == -1) return -1;
            p += 4;
            continue;
          }
          if (d == 0x66) {
            // %f
            p += 2;
            if (_p(p) != 0x5B) throw LuaError("missing '[' after '%f' in pattern");
            final ep = _classEnd(p);
            final before = s == 0 ? 0 : src.codeUnitAt(s - 1), here = s < src.length ? src.codeUnitAt(s) : 0;
            if (!_set(before, p, ep - 1) && _set(here, p, ep - 1)) {
              p = ep;
              continue;
            }
            return -1;
          }
          if (d >= 0x30 && d <= 0x39) {
            s = _back(s, d);
            if (s == -1) return -1;
            p += 2;
            continue;
          }
        }
        final ep = _classEnd(p), next = _p(ep);
        final fits = s < src.length && _single(s, p, ep);
        if (next == 0x3F) {
          // ?
          if (fits) {
            final r = match(s + 1, ep + 1);
            if (r != -1) return r;
          }
          p = ep + 1;
          continue;
        }
        if (next == 0x2B) return fits ? _most_(s + 1, p, ep) : -1;
        if (next == 0x2A) return _most_(s, p, ep);
        if (next == 0x2D) {
          while (true) {
            final r = match(s, ep + 1);
            if (r != -1) return r;
            if (s < src.length && _single(s, p, ep)) {
              s++;
            } else {
              return -1;
            }
          }
        }
        if (!fits) return -1;
        s++;
        p = ep;
      }
    } finally {
      _depth--;
    }
  }

  int _most_(int s, int p, int ep) {
    var i = 0;
    while (s + i < src.length && _single(s + i, p, ep)) {
      i++;
    }
    while (i >= 0) {
      final r = match(s + i, ep + 1);
      if (r != -1) return r;
      i--;
    }
    return -1;
  }

  int _open(int s, int p, int what) {
    if (level >= _most) throw LuaError('too many captures');
    _start[level] = s;
    _length[level] = what;
    level++;
    final r = match(s, p);
    if (r == -1) level--;
    return r;
  }

  int _close(int s, int p) {
    var l = -1;
    for (var i = level - 1; i >= 0; i--) {
      if (_length[i] == _unfinished) {
        l = i;
        break;
      }
    }
    if (l < 0) throw LuaError('invalid pattern capture');
    _length[l] = s - _start[l];
    final r = match(s, p);
    if (r == -1) _length[l] = _unfinished;
    return r;
  }

  int _back(int s, int digit) {
    final l = digit - 0x31;
    if (l < 0 || l >= level || _length[l] == _unfinished) throw LuaError('invalid capture index %${l + 1}');
    final n = _length[l];
    if (src.length - s >= n && src.substring(_start[l], _start[l] + n) == src.substring(s, s + n)) return s + n;
    return -1;
  }

  int _balance(int s, int p) {
    if (p + 1 >= pat.length) throw LuaError("malformed pattern (missing arguments to '%b')");
    if (s >= src.length || src.codeUnitAt(s) != pat.codeUnitAt(p)) return -1;
    final open = pat.codeUnitAt(p), close = pat.codeUnitAt(p + 1);
    var depth = 1;
    while (++s < src.length) {
      final c = src.codeUnitAt(s);
      if (c == close) {
        if (--depth == 0) return s + 1;
      } else if (c == open) {
        depth++;
      }
    }
    return -1;
  }

  int _classEnd(int p) {
    final c = pat.codeUnitAt(p++);
    if (c == 0x25) {
      if (p >= pat.length) throw LuaError("malformed pattern (ends with '%')");
      return p + 1;
    }
    if (c == 0x5B) {
      if (_p(p) == 0x5E) p++;
      do {
        if (p >= pat.length) throw LuaError("malformed pattern (missing ']')");
        final cc = pat.codeUnitAt(p++);
        if (cc == 0x25) {
          if (p >= pat.length) throw LuaError("malformed pattern (missing ']')");
          p++;
        }
      } while (_p(p) != 0x5D);
      return p + 1;
    }
    return p;
  }

  bool _single(int s, int p, int ep) {
    final c = src.codeUnitAt(s), pc = pat.codeUnitAt(p);
    if (pc == 0x2E) return true;
    if (pc == 0x25) return _class(c, pat.codeUnitAt(p + 1));
    if (pc == 0x5B) return _set(c, p, ep - 1);
    return pc == c;
  }

  bool _set(int c, int p, int end) {
    var sig = true;
    if (_p(p + 1) == 0x5E) {
      sig = false;
      p++;
    }
    while (++p < end) {
      final pc = pat.codeUnitAt(p);
      if (pc == 0x25) {
        p++;
        if (_class(c, pat.codeUnitAt(p))) return sig;
      } else if (_p(p + 1) == 0x2D && p + 2 < end) {
        p += 2;
        if (pat.codeUnitAt(p - 2) <= c && c <= pat.codeUnitAt(p)) return sig;
      } else if (pc == c) {
        return sig;
      }
    }
    return !sig;
  }

  static bool _class(int c, int cl) {
    final lower = c >= 0x61 && c <= 0x7A, upper = c >= 0x41 && c <= 0x5A, digit = c >= 0x30 && c <= 0x39;
    bool r;
    switch (cl | 0x20) {
      case 0x61: // a
        r = lower || upper;
      case 0x63: // c
        r = c < 0x20 || c == 0x7F;
      case 0x64: // d
        r = digit;
      case 0x67: // g
        r = c > 0x20 && c < 0x7F;
      case 0x6C: // l
        r = lower;
      case 0x70: // p
        r = c > 0x20 && c < 0x7F && !lower && !upper && !digit;
      case 0x73: // s
        r = c == 0x20 || (c >= 0x09 && c <= 0x0D);
      case 0x75: // u
        r = upper;
      case 0x77: // w
        r = lower || upper || digit;
      case 0x78: // x
        r = digit || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46);
      default:
        return cl == c;
    }
    // An upper-case class is everything its lower-case one isn't.
    return cl >= 0x41 && cl <= 0x5A ? !r : r;
  }

  /// Capture [i] of a match from [s] to [e]: the whole match when the pattern has none.
  Object? capture(int i, int s, int e) {
    if (i >= level) {
      if (i == 0) return src.substring(s, e);
      throw LuaError('invalid capture index %${i + 1}');
    }
    final n = _length[i];
    if (n == _unfinished) throw LuaError('unfinished capture');
    if (n == _position) return _start[i] + 1;
    return src.substring(_start[i], _start[i] + n);
  }

  /// Every capture; with none, the whole match if [whole].
  List<Object?> captures(int s, int e, bool whole) {
    final n = level == 0 && whole ? 1 : level;
    final all = [for (var i = 0; i < n; i++) capture(i, s, e)];
    for (final captured in all) {
      if (captured is String) lua.spend(captured.length);
    }
    return all;
  }
}

// MARK: format

String _format(Lua lua, List<Object?> a) {
  final fmt = a.string(0, 'format'), out = StringBuffer();
  var arg = 1;
  for (var i = 0; i < fmt.length; i++) {
    final c = fmt[i];
    if (c != '%') {
      out.write(c);
      continue;
    }
    if (++i >= fmt.length) throw LuaError("invalid conversion '%' to 'format'");
    if (fmt[i] == '%') {
      out.write('%');
      continue;
    }
    final start = i;
    var left = false, plus = false, space = false, alt = false, zero = false;
    flags:
    for (; i < fmt.length; i++) {
      switch (fmt[i]) {
        case '-':
          left = true;
        case '+':
          plus = true;
        case ' ':
          space = true;
        case '#':
          alt = true;
        case '0':
          zero = true;
        default:
          break flags;
      }
    }
    int digits() {
      final from = i;
      while (i < fmt.length && fmt.codeUnitAt(i) >= 0x30 && fmt.codeUnitAt(i) <= 0x39) {
        i++;
      }
      return i == from ? -1 : int.parse(fmt.substring(from, i));
    }

    final width = digits();
    var precision = -1;
    if (i < fmt.length && fmt[i] == '.') {
      i++;
      precision = digits();
      if (precision < 0) precision = 0;
    }
    if (i >= fmt.length || width > 99 || precision > 99) throw LuaError("invalid conversion '%${fmt.substring(start, i.clamp(start, fmt.length))}' to 'format'");
    final conv = fmt[i], n = arg++;
    if (n >= a.length && conv != '%') a.bad(n, 'format', 'no value');
    String sign(num v) => v < 0 || (v == 0 && v is double && v.isNegative) ? '-' : (plus ? '+' : (space ? ' ' : ''));
    var numeric = true, head = '', body = '';
    switch (conv) {
      case 'd' || 'i' || 'u':
        final v = a.integer(n, 'format');
        head = sign(v);
        body = v.abs().toString();
        if (precision >= 0) {
          body = body.padLeft(precision, '0');
          zero = false;
        }
      case 'c':
        body = String.fromCharCode(a.integer(n, 'format'));
        numeric = false;
      case 'x' || 'X' || 'o':
        final v = a.integer(n, 'format'), radix = conv == 'o' ? 8 : 16;
        body = v >= 0 ? v.toRadixString(radix) : BigInt.from(v).toUnsigned(64).toRadixString(radix);
        if (conv == 'X') body = body.toUpperCase();
        if (precision >= 0) {
          body = body.padLeft(precision, '0');
          zero = false;
        }
        if (alt && v != 0) head = conv == 'o' ? '0' : (conv == 'X' ? '0X' : '0x');
      case 'e' || 'E' || 'f' || 'F' || 'g' || 'G':
        final v = a.number(n, 'format').toDouble();
        head = sign(v);
        if (v.isNaN || v.isInfinite) {
          body = v.isNaN ? 'nan' : 'inf';
          zero = false;
        } else {
          final p = precision < 0 ? 6 : precision, m = v.abs();
          body = switch (conv) {
            'f' || 'F' => _fixed(m, p, alt),
            'e' || 'E' => _exponential(m, p, alt),
            _ => _general(m, p, alt),
          };
        }
        if (conv == 'E' || conv == 'G' || conv == 'F') body = body.toUpperCase();
      case 's':
        body = lua.tostring(a[n]);
        if (precision >= 0 && body.length > precision) body = body.substring(0, precision);
        numeric = false;
      case 'q':
        body = _quoted(a[n]);
        numeric = false;
      default:
        throw LuaError("invalid conversion '%${fmt.substring(start, i + 1)}' to 'format'");
    }
    final length = head.length + body.length;
    if (width > length) {
      if (left) {
        out.write('$head$body'.padRight(width));
      } else if (zero && numeric) {
        out.write('$head${body.padLeft(width - head.length, '0')}');
      } else {
        out.write('$head$body'.padLeft(width));
      }
    } else {
      out
        ..write(head)
        ..write(body);
    }
    if (out.length > Lua.maxLength) throw lua._tooBig();
  }
  return out.toString();
}

String _fixed(double m, int p, bool alt) {
  // toStringAsFixed takes up to 20 digits, and gives up past 1e21.
  if (m >= 1e21) {
    final whole = BigInt.from(m).toString();
    return p == 0 ? (alt ? '$whole.' : whole) : '$whole.${'0' * p}';
  }
  final s = p <= 20 ? m.toStringAsFixed(p) : m.toStringAsFixed(20) + '0' * (p - 20);
  return alt && p == 0 ? '$s.' : s;
}

String _exponential(double m, int p, bool alt) {
  final s = p <= 20 ? m.toStringAsExponential(p) : m.toStringAsExponential(20);
  final e = s.indexOf('e');
  var mantissa = s.substring(0, e);
  if (p > 20) mantissa += '0' * (p - 20);
  if (alt && p == 0) mantissa += '.';
  final exponent = int.parse(s.substring(e + 1));
  return '$mantissa${'e'}${exponent < 0 ? '-' : '+'}${exponent.abs().toString().padLeft(2, '0')}';
}

String _general(double m, int p, bool alt) {
  if (p == 0) p = 1;
  if (p > 21) p = 21;
  if (m == 0) return alt ? '0.${'0' * (p - 1)}' : '0';
  final probe = m.toStringAsExponential(p - 1);
  final x = int.parse(probe.substring(probe.indexOf('e') + 1));
  String strip(String s) {
    if (alt || !s.contains('.')) return s;
    s = s.replaceFirst(RegExp(r'0+$'), '');
    return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
  }

  if (x < -4 || x >= p) {
    final mantissa = strip(probe.substring(0, probe.indexOf('e')));
    return '$mantissa${'e'}${x < 0 ? '-' : '+'}${x.abs().toString().padLeft(2, '0')}';
  }
  return strip(m.toStringAsFixed(p - 1 - x));
}

String _quoted(Object? v) {
  if (v is! String) {
    if (v == null || v is bool || v is num) return Lua.show(v);
    throw LuaError("bad argument to 'format' (value has no literal form)");
  }
  final out = StringBuffer('"');
  for (final c in v.codeUnits) {
    switch (c) {
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x0A:
        out.write('\\n');
      case 0x0D:
        out.write(r'\r');
      case 0:
        out.write(r'\0');
      default:
        out.writeCharCode(c);
    }
  }
  out.write('"');
  return out.toString();
}
