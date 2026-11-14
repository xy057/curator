part of '../lua.dart';

typedef _E = Object? Function(_Frame f);
typedef _M = List<Object?> Function(_Frame f);

/// A statement run: null to go on, or why not ([_breakSignal], [_returnSignal], a [_Goto]).
typedef _S = Object? Function(_Frame f);

final Object _breakSignal = Object(), _returnSignal = Object();

final class _Goto {
  _Goto(this.label);
  final String label;
}

/// One call of a Lua function: its locals by slot, the variables it took from outside, what it
/// was given past its parameters, and what it returns.
final class _Frame {
  _Frame(this.slots, this.upvals, this.varargs);
  final List<Object?> slots;
  final List<_Cell> upvals;
  final List<Object?> varargs;
  List<Object?> ret = _none;
}

/// Where in the source something is, for an error raised there, and what it is about
/// ("local 'x'").
final class _Site {
  const _Site(this.chunk, this.line, [this.what, this.what2]);
  final String chunk;
  final int line;
  final String? what, what2;

  /// An error here; from [_library], one the call it came through places.
  LuaError error(String message) => chunk.isEmpty
      ? LuaError(message)
      : (LuaError('$chunk:$line: $message', level: 0)
        ..placed = true
        ..chunk = chunk
        ..line = line);

  /// An error on its way out through the call here: says where it was raised, if nothing has.
  void place(LuaError e) {
    if (!e.placed) {
      if (e.level > 1) {
        e.level--;
      } else {
        e.placed = true;
        e.chunk = chunk;
        e.line = line;
        if (e.level != 0 && e.value is String) e.value = '$chunk:$line: ${e.value}';
      }
    }
    if (e.trace.length < 24) e.trace.add('$chunk:$line');
  }
}

/// Where a library function's errors are: nowhere of their own, so the call says.
const _library = _Site('', 0);

/// A function written in Lua.
final class LuaClosure extends LuaFunction {
  LuaClosure._(this._lua, this._code, this._upvals);
  final Lua _lua;
  final _Code _code;
  final List<_Cell> _upvals;

  @override
  String get name => _code.proto.name;

  /// The file it is written in, and the line it starts at.
  String get chunk => _code.proto.chunk;
  int get line => _code.proto.line;

  /// Its parameters' names.
  List<String> get parameters => [for (final p in _code.proto.params) p.name];

  @override
  List<Object?> call(List<Object?> args) {
    final lua = _lua, code = _code;
    if (--lua.steps < 0) throw lua._tooLong();
    if (++lua._depth > Lua.maxDepth) {
      lua._depth--;
      throw LuaLimit('stack overflow (a function calls itself without end?)');
    }
    final n = code.nparams, slots = List<Object?>.filled(code.nslots, null), given = args.length;
    final captured = code.capturedParams;
    if (captured == null) {
      for (var i = 0; i < n && i < given; i++) {
        slots[i] = args[i];
      }
    } else {
      for (var i = 0; i < n; i++) {
        final v = i < given ? args[i] : null;
        slots[i] = captured[i] ? _Cell(v) : v;
      }
    }
    final f = _Frame(slots, _upvals, code.isVararg && given > n ? args.sublist(n) : _none);
    try {
      final s = code.body(f);
      if (s == null) return _none;
      if (identical(s, _returnSignal)) return f.ret;
      throw LuaError("${code.proto.chunk}:${code.proto.line}: no visible label '${(s as _Goto).label}' for goto", level: 0)..placed = true;
    } finally {
      lua._depth--;
    }
  }

  @override
  String toString() => 'function: ${_code.proto.chunk}:${_code.proto.line}';
}

/// A function's tree made runnable.
final class _Code {
  _Code(this.proto)
      : nparams = proto.params.length,
        nslots = proto.nslots,
        isVararg = proto.isVararg,
        capturedParams = proto.params.any((p) => p.captured) ? [for (final p in proto.params) p.captured] : null;
  final _Proto proto;
  final int nparams, nslots;
  final bool isVararg;
  final List<bool>? capturedParams;
  late final _S body;
}

bool _truthy(Object? v) => v != null && !identical(v, false);

/// Turns a tree into closures: each node once, so running it reads no tree.
final class _Compiler {
  _Compiler(this.lua, this.chunk, this.env);
  final Lua lua;
  final String chunk;

  /// Where the code's own globals are kept, the world's read where it has none; null: they are
  /// the world's.
  final LuaTable? env;

  _Code code(_Proto proto) {
    final c = _Code(proto);
    c.body = block(proto.body);
    return c;
  }

  _Site site(int line, [String? what, String? what2]) => _Site(chunk, line, what, what2);

  /// What an error about [e]'s value calls it.
  static String? describe(_Expr e) => switch (e) {
        _ELocal(:final v) => "local '${v.name}'",
        _EUpval(:final v) => "upvalue '${v.name}'",
        _EGlobal(:final name) => "global '$name'",
        _EIndex(key: _EString(:final v)) => "field '$v'",
        _EMethod(:final name) => "method '$name'",
        _ => null,
      };

  static bool isMulti(_Expr e) => e is _ECall || e is _EMethod || e is _EVararg;

  // MARK: Statements

  _S block(_Block b) {
    final code = <_S>[], labels = <String, int>{};
    for (final s in b.stats) {
      if (s is _SLabel) {
        labels[s.name] = code.length;
      } else {
        code.add(stat(s));
      }
    }
    final n = code.length;
    if (labels.isEmpty) {
      if (n == 0) return (_) => null;
      if (n == 1) return code[0];
      if (n == 2) {
        final first = code[0], second = code[1];
        return (f) => first(f) ?? second(f);
      }
      return (f) {
        for (var i = 0; i < n; i++) {
          final s = code[i](f);
          if (s != null) return s;
        }
        return null;
      };
    }
    final lua = this.lua;
    return (f) {
      var i = 0;
      while (i < n) {
        final s = code[i](f);
        if (s == null) {
          i++;
          continue;
        }
        if (s is _Goto) {
          final at = labels[s.label];
          if (at != null) {
            if (--lua.steps < 0) throw lua._tooLong();
            i = at;
            continue;
          }
        }
        return s;
      }
      return null;
    };
  }

  _S stat(_Stat s) {
    switch (s) {
      case _SCall(:final call):
        final m = multi(call);
        return (f) {
          m(f);
          return null;
        };
      case _SLocal():
        return _local(s);
      case _SAssign():
        return _assign(s);
      case _SDo(block: final b):
        return block(b);
      case _SIf():
        return _if(s);
      case _SWhile():
        final cond = expr(s.cond), body = block(s.block), lua = this.lua;
        return (f) {
          while (_truthy(cond(f))) {
            if (--lua.steps < 0) throw lua._tooLong();
            final r = body(f);
            if (r != null) {
              if (identical(r, _breakSignal)) break;
              return r;
            }
          }
          return null;
        };
      case _SRepeat():
        final cond = expr(s.cond), body = block(s.block), lua = this.lua;
        return (f) {
          do {
            if (--lua.steps < 0) throw lua._tooLong();
            final r = body(f);
            if (r != null) {
              if (identical(r, _breakSignal)) break;
              return r;
            }
          } while (!_truthy(cond(f)));
          return null;
        };
      case _SFor():
        return _for(s);
      case _SForIn():
        return _forIn(s);
      case _SLocalFunction(:final v, :final proto):
        final make = _function(proto), slot = v.slot;
        if (!v.captured) {
          return (f) {
            f.slots[slot] = make(f);
            return null;
          };
        }
        return (f) {
          // In scope in its own body: it can call itself.
          final cell = _Cell(null);
          f.slots[slot] = cell;
          cell.value = make(f);
          return null;
        };
      case _SReturn(:final exprs):
        if (exprs.isEmpty) {
          return (f) {
            f.ret = _none;
            return _returnSignal;
          };
        }
        if (exprs.length == 1 && !isMulti(exprs[0])) {
          final e = expr(exprs[0]);
          return (f) {
            f.ret = [e(f)];
            return _returnSignal;
          };
        }
        final m = list(exprs);
        return (f) {
          f.ret = m(f);
          return _returnSignal;
        };
      case _SBreak():
        return (_) => _breakSignal;
      case _SGoto(:final label):
        final signal = _Goto(label);
        return (_) => signal;
      case _SLabel():
        throw StateError('a label is not run');
    }
  }

  _S _local(_SLocal s) {
    final vars = s.vars;
    if (vars.length == 1 && s.exprs.length == 1) {
      final slot = vars[0].slot, e = expr(s.exprs[0]);
      if (vars[0].captured) {
        return (f) {
          f.slots[slot] = _Cell(e(f));
          return null;
        };
      }
      return (f) {
        f.slots[slot] = e(f);
        return null;
      };
    }
    final n = vars.length, slots = [for (final v in vars) v.slot], captured = [for (final v in vars) v.captured];
    if (s.exprs.isEmpty) {
      return (f) {
        for (var i = 0; i < n; i++) {
          f.slots[slots[i]] = captured[i] ? _Cell(null) : null;
        }
        return null;
      };
    }
    final m = list(s.exprs);
    return (f) {
      final values = m(f), given = values.length;
      for (var i = 0; i < n; i++) {
        final v = i < given ? values[i] : null;
        f.slots[slots[i]] = captured[i] ? _Cell(v) : v;
      }
      return null;
    };
  }

  /// Puts a value where [target] names.
  void Function(_Frame f, Object? value) _setter(_Expr target) {
    switch (target) {
      case _ELocal(:final v):
        final slot = v.slot;
        if (v.captured) return (f, value) => (f.slots[slot] as _Cell).value = value;
        return (f, value) => f.slots[slot] = value;
      case _EUpval(:final index):
        return (f, value) => f.upvals[index].value = value;
      case _EGlobal(:final name):
        final globals = env ?? lua.globals;
        return (f, value) => globals[name] = value;
      default:
        throw StateError('not assignable');
    }
  }

  _S _assign(_SAssign s) {
    final lua = this.lua;
    if (s.targets.length == 1 && s.exprs.length == 1) {
      final target = s.targets[0], e = expr(s.exprs[0]);
      if (target is _EIndex) {
        final obj = expr(target.obj), at = site(target.line, describe(target.obj));
        final key = target.key;
        if (key is _EString) {
          final name = key.v;
          return (f) {
            final o = obj(f), value = e(f);
            if (o is LuaTable && o.metatable == null) {
              o[name] = value;
            } else {
              lua._setIndex(o, name, value, at);
            }
            return null;
          };
        }
        final k = expr(key);
        return (f) {
          final o = obj(f), at2 = k(f);
          lua._setIndex(o, at2, e(f), at);
          return null;
        };
      }
      final set = _setter(target);
      return (f) {
        set(f, e(f));
        return null;
      };
    }
    // Several: where each goes is worked out first, then every value, then they are put in place.
    final n = s.targets.length, m = list(s.exprs);
    final objs = <_E?>[], keys = <_E?>[], sets = <void Function(_Frame, Object?)?>[], sites = <_Site?>[];
    for (final t in s.targets) {
      if (t is _EIndex) {
        objs.add(expr(t.obj));
        keys.add(expr(t.key));
        sets.add(null);
        sites.add(site(t.line, describe(t.obj)));
      } else {
        objs.add(null);
        keys.add(null);
        sets.add(_setter(t));
        sites.add(null);
      }
    }
    return (f) {
      final os = List<Object?>.filled(n, null), ks = List<Object?>.filled(n, null);
      for (var i = 0; i < n; i++) {
        final o = objs[i];
        if (o != null) {
          os[i] = o(f);
          ks[i] = keys[i]!(f);
        }
      }
      final values = m(f), given = values.length;
      for (var i = n - 1; i >= 0; i--) {
        final v = i < given ? values[i] : null, set = sets[i];
        if (set != null) {
          set(f, v);
        } else {
          lua._setIndex(os[i], ks[i], v, sites[i]!);
        }
      }
      return null;
    };
  }

  _S _if(_SIf s) {
    if (s.arms.length == 1) {
      final cond = expr(s.arms[0].cond), then = block(s.arms[0].block);
      final other = s.otherwise == null ? null : block(s.otherwise!);
      if (other == null) return (f) => _truthy(cond(f)) ? then(f) : null;
      return (f) => _truthy(cond(f)) ? then(f) : other(f);
    }
    final conds = [for (final a in s.arms) expr(a.cond)], blocks = [for (final a in s.arms) block(a.block)];
    final other = s.otherwise == null ? null : block(s.otherwise!), n = conds.length;
    return (f) {
      for (var i = 0; i < n; i++) {
        if (_truthy(conds[i](f))) return blocks[i](f);
      }
      return other == null ? null : other(f);
    };
  }

  _S _for(_SFor s) {
    final start = expr(s.start), stop = expr(s.stop), step = s.step == null ? null : expr(s.step!);
    final body = block(s.block), slot = s.v.slot, captured = s.v.captured, lua = this.lua, at = site(s.line);
    num number(Object? v, String what) {
      if (v is num) return v;
      if (v is String) {
        final n = Lua.toNumber(v);
        if (n != null) return n;
      }
      throw at.error("'for' $what must be a number");
    }

    return (f) {
      final a = number(start(f), 'initial value'), b = number(stop(f), 'limit');
      final c = step == null ? 1 : number(step(f), 'step');
      if (c == 0) throw at.error("'for' step is zero");
      final slots = f.slots;
      for (var i = a; c > 0 ? i <= b : i >= b; i += c) {
        if (--lua.steps < 0) throw lua._tooLong();
        slots[slot] = captured ? _Cell(i) : i;
        final r = body(f);
        if (r != null) {
          if (identical(r, _breakSignal)) break;
          return r;
        }
      }
      return null;
    };
  }

  _S _forIn(_SForIn s) {
    final init = list(s.exprs), body = block(s.block), lua = this.lua, at = site(s.line, 'for iterator');
    final n = s.vars.length, slots = [for (final v in s.vars) v.slot], captured = [for (final v in s.vars) v.captured];
    final any = captured.contains(true);
    final k = slots[0], v = n > 1 ? slots[1] : -1;

    void put(_Frame f, Object? key, Object? value) {
      if (any) {
        f.slots[k] = captured[0] ? _Cell(key) : key;
        if (v >= 0) f.slots[v] = captured[1] ? _Cell(value) : value;
      } else {
        f.slots[k] = key;
        if (v >= 0) f.slots[v] = value;
      }
      for (var i = 2; i < n; i++) {
        f.slots[slots[i]] = captured[i] ? _Cell(null) : null;
      }
    }

    return (f) {
      final values = init(f);
      final fn = values.isNotEmpty ? values[0] : null, state = values.length > 1 ? values[1] : null;
      var control = values.length > 2 ? values[2] : null;
      // pairs and ipairs over a plain table, without a call a turn.
      if (state is LuaTable && control == null && identical(fn, lua._next)) {
        final array = state.array;
        for (var i = 0; i < array.length; i++) {
          final value = array[i];
          if (value == null) continue;
          if (--lua.steps < 0) throw lua._tooLong();
          put(f, i + 1, value);
          final r = body(f);
          if (r != null) {
            if (identical(r, _breakSignal)) return null;
            return r;
          }
        }
        if (state.hashLength > 0) {
          // The keys as they are now: one set meanwhile isn't visited, one cleared is skipped.
          for (final key in state.hashKeys.toList(growable: false)) {
            final value = state[key];
            if (value == null) continue;
            if (--lua.steps < 0) throw lua._tooLong();
            put(f, key, value);
            final r = body(f);
            if (r != null) {
              if (identical(r, _breakSignal)) return null;
              return r;
            }
          }
        }
        return null;
      }
      if (state is LuaTable && control == 0 && identical(fn, lua._inext) && state.metatable == null) {
        final array = state.array;
        for (var i = 0; i < array.length; i++) {
          final value = array[i];
          if (value == null) break;
          if (--lua.steps < 0) throw lua._tooLong();
          put(f, i + 1, value);
          final r = body(f);
          if (r != null) {
            if (identical(r, _breakSignal)) return null;
            return r;
          }
        }
        return null;
      }
      while (true) {
        if (--lua.steps < 0) throw lua._tooLong();
        final r = lua._invoke(fn, [state, control], at), given = r.length;
        final first = given > 0 ? r[0] : null;
        if (first == null) return null;
        control = first;
        for (var i = 0; i < n; i++) {
          final value = i < given ? r[i] : null;
          f.slots[slots[i]] = captured[i] ? _Cell(value) : value;
        }
        final out = body(f);
        if (out != null) {
          if (identical(out, _breakSignal)) return null;
          return out;
        }
      }
    };
  }

  // MARK: Expressions

  LuaClosure Function(_Frame f) _function(_Proto proto) {
    final c = code(proto), ups = proto.upvals, n = ups.length, lua = this.lua;
    if (n == 0) return (f) => LuaClosure._(lua, c, const []);
    final fromLocal = [for (final u in ups) u.fromLocal], index = [for (final u in ups) u.index];
    return (f) {
      final cells = List<_Cell>.generate(n, (i) => fromLocal[i] ? f.slots[index[i]] as _Cell : f.upvals[index[i]], growable: false);
      return LuaClosure._(lua, c, cells);
    };
  }

  /// Every value of [exprs], the last one's all of them (a call's, `...`).
  _M list(List<_Expr> exprs, {_E? first}) {
    final lead = first == null ? 0 : 1;
    if (exprs.isEmpty) {
      if (first == null) return (_) => _none;
      return (f) => [first(f)];
    }
    final last = exprs.last;
    if (!isMulti(last)) {
      final es = [?first, for (final e in exprs) expr(e)], n = es.length;
      switch (n) {
        case 1:
          final a = es[0];
          return (f) => [a(f)];
        case 2:
          final a = es[0], b = es[1];
          return (f) => [a(f), b(f)];
        case 3:
          final a = es[0], b = es[1], c = es[2];
          return (f) => [a(f), b(f), c(f)];
      }
      return (f) => List<Object?>.generate(n, (i) => es[i](f), growable: false);
    }
    final head = [?first, for (final e in exprs.take(exprs.length - 1)) expr(e)], h = head.length, tail = multi(last);
    if (h == 0 && lead == 0) return tail;
    return (f) {
      final out = List<Object?>.filled(h, null, growable: true);
      for (var i = 0; i < h; i++) {
        out[i] = head[i](f);
      }
      out.addAll(tail(f));
      return out;
    };
  }

  /// Every value [e] gives.
  _M multi(_Expr e) {
    final lua = this.lua;
    switch (e) {
      case _ECall():
        final fn = expr(e.fn), args = list(e.args), at = site(e.line, describe(e.fn));
        return (f) => lua._invoke(fn(f), args(f), at);
      case _EMethod(:final name):
        final obj = expr(e.obj), at = site(e.line, "method '$name'", describe(e.obj));
        late Object? self;
        final args = list(e.args, first: (_) => self);
        return (f) {
          final o = obj(f);
          final fn = o is LuaTable ? (o.field(name) ?? lua._index(o, name, at)) : lua._index(o, name, _Site(at.chunk, at.line, at.what2));
          self = o;
          final given = args(f);
          return lua._invoke(fn, given, at);
        };
      case _EVararg():
        return (f) => f.varargs;
      default:
        final one = expr(e);
        return (f) => [one(f)];
    }
  }

  /// [e]'s value: a call's first.
  _E expr(_Expr e) {
    final lua = this.lua;
    switch (e) {
      case _ENil():
        return (_) => null;
      case _ETrue():
        return (_) => true;
      case _EFalse():
        return (_) => false;
      case _ENumber(:final v):
        return (_) => v;
      case _EString(:final v):
        return (_) => v;
      case _ELocal(:final v):
        final slot = v.slot;
        if (v.captured) return (f) => (f.slots[slot] as _Cell).value;
        return (f) => f.slots[slot];
      case _EUpval(:final index):
        return (f) => f.upvals[index].value;
      case _EGlobal(:final name):
        final globals = lua.globals, own = env;
        if (own != null) return (_) => own.field(name) ?? globals.field(name);
        return (_) => globals.field(name);
      case _EVararg():
        return (f) => f.varargs.isEmpty ? null : f.varargs[0];
      case _EParen(e: final inner):
        return expr(inner);
      case _ECall() || _EMethod():
        final m = multi(e);
        return (f) {
          final r = m(f);
          return r.isEmpty ? null : r[0];
        };
      case _EFunction(:final proto):
        return _function(proto);
      case _EIndex():
        final obj = expr(e.obj), at = site(e.line, describe(e.obj));
        final key = e.key;
        if (key is _EString) {
          final name = key.v;
          return (f) {
            final o = obj(f);
            if (o is LuaTable) {
              final v = o.field(name);
              if (v != null || o.metatable == null) return v;
            }
            return lua._index(o, name, at);
          };
        }
        final k = expr(key);
        return (f) {
          final o = obj(f), at2 = k(f);
          if (o is LuaTable) {
            final v = o[at2];
            if (v != null || o.metatable == null) return v;
          }
          return lua._index(o, at2, at);
        };
      case _ETable():
        return _table(e);
      case _EUnary():
        return _unary(e);
      case _EBinary():
        return _binary(e);
    }
  }

  _E _table(_ETable e) {
    final entries = e.entries, lua = this.lua;
    if (entries.isEmpty) return (_) => LuaTable();
    final n = entries.length, at = site(e.line);
    final keys = <_E?>[for (final entry in entries) entry.key == null ? null : expr(entry.key!)];
    final lastMulti = entries.last.key == null && isMulti(entries.last.value);
    final values = <_E>[for (final (i, entry) in entries.indexed) i == n - 1 && lastMulti ? (_) => null : expr(entry.value)];
    final tail = lastMulti ? multi(entries.last.value) : null;
    final keyed = keys.any((k) => k != null), count = tail == null ? n : n - 1;
    return (f) {
      final t = LuaTable(), array = t.array;
      // The values without a key are the list, in order, a nil among them too (as Lua's own
      // constructor keeps them); those with a key are set after, and never over one of the list.
      List<Object?>? later;
      for (var i = 0; i < count; i++) {
        final key = keys[i];
        if (key == null) {
          array.add(values[i](f));
        } else {
          final k = key(f);
          if (k == null) throw at.error('table index is nil');
          if (k is double && k.isNaN) throw at.error('table index is NaN');
          (later ??= [])
            ..add(k)
            ..add(values[i](f));
        }
      }
      if (tail != null) {
        array.addAll(tail(f));
        lua.steps -= array.length >> 6; // as many values as a call gave, in one step
      }
      if (array.length > Lua.maxLength) throw lua._tooBig();
      t._trim();
      if (keyed && later != null) {
        final listed = array.length;
        for (var i = 0; i < later.length; i += 2) {
          final k = later[i];
          if (k is num && k >= 1 && k <= listed && k == k.truncate()) continue;
          t[k] = later[i + 1];
        }
      }
      return t;
    };
  }

  _E _unary(_EUnary e) {
    final a = expr(e.a), lua = this.lua, at = site(e.line, describe(e.a));
    switch (e.op) {
      case 'not':
        return (f) => !_truthy(a(f));
      case '-':
        return (f) {
          final x = a(f);
          return x is num ? -x : lua._arith('unm', x, x, at);
        };
      case '#':
        return (f) {
          final x = a(f);
          if (x is String) return x.length;
          if (x is LuaTable && x.metatable == null) return x.array.length;
          return lua._length(x, at);
        };
      default:
        return (f) => lua._arith('bnot', a(f), null, at);
    }
  }

  _E _binary(_EBinary e) {
    final lua = this.lua, op = e.op;
    if (op == 'and') {
      final a = expr(e.a), b = expr(e.b);
      return (f) {
        final x = a(f);
        return _truthy(x) ? b(f) : x;
      };
    }
    if (op == 'or') {
      final a = expr(e.a), b = expr(e.b);
      return (f) {
        final x = a(f);
        return _truthy(x) ? x : b(f);
      };
    }
    final a = expr(e.a), b = expr(e.b), at = site(e.line, describe(e.a), describe(e.b));
    switch (op) {
      case '+':
        return (f) {
          final x = a(f), y = b(f);
          return x is num && y is num ? x + y : lua._arith('add', x, y, at);
        };
      case '-':
        return (f) {
          final x = a(f), y = b(f);
          return x is num && y is num ? x - y : lua._arith('sub', x, y, at);
        };
      case '*':
        return (f) {
          final x = a(f), y = b(f);
          return x is num && y is num ? x * y : lua._arith('mul', x, y, at);
        };
      case '/':
        return (f) {
          final x = a(f), y = b(f);
          return x is num && y is num ? x / y : lua._arith('div', x, y, at);
        };
      case '%':
        return (f) {
          final x = a(f), y = b(f);
          return x is num && y is num ? Lua._mod(x, y) : lua._arith('mod', x, y, at);
        };
      case '//':
        return (f) {
          final x = a(f), y = b(f);
          return x is num && y is num ? Lua._idiv(x, y) : lua._arith('idiv', x, y, at);
        };
      case '^':
        return (f) {
          final x = a(f), y = b(f);
          return x is num && y is num ? math.pow(x.toDouble(), y.toDouble()) : lua._arith('pow', x, y, at);
        };
      case '..':
        return (f) {
          final x = a(f), y = b(f);
          if (x is String && y is String) {
            if (x.length + y.length > Lua.maxLength) throw lua._tooBig();
            lua.steps -= (x.length + y.length) >> 6;
            return x + y;
          }
          return lua._concat(x, y, at);
        };
      case '==':
        return (f) {
          final x = a(f), y = b(f);
          return x == y || lua._equals(x, y);
        };
      case '~=':
        return (f) {
          final x = a(f), y = b(f);
          return !(x == y || lua._equals(x, y));
        };
      case '<':
        return (f) {
          final x = a(f), y = b(f);
          return x is num && y is num ? x < y : lua._less(x, y, at);
        };
      case '<=':
        return (f) {
          final x = a(f), y = b(f);
          return x is num && y is num ? x <= y : lua._lessEqual(x, y, at);
        };
      case '>':
        return (f) {
          final x = a(f), y = b(f);
          return x is num && y is num ? x > y : lua._less(y, x, _Site(at.chunk, at.line, at.what2, at.what));
        };
      case '>=':
        return (f) {
          final x = a(f), y = b(f);
          return x is num && y is num ? x >= y : lua._lessEqual(y, x, _Site(at.chunk, at.line, at.what2, at.what));
        };
      case '&':
        return (f) => lua._arith('band', a(f), b(f), at);
      case '|':
        return (f) => lua._arith('bor', a(f), b(f), at);
      case '~':
        return (f) => lua._arith('bxor', a(f), b(f), at);
      case '<<':
        return (f) => lua._arith('shl', a(f), b(f), at);
      case '>>':
        return (f) => lua._arith('shr', a(f), b(f), at);
    }
    throw StateError('unknown operator $op');
  }
}
