part of '../lua.dart';

// MARK: Tokens

final class _Token {
  const _Token(this.type, this.value, this.line);

  /// 'name', 'number', 'string', 'eof', or the keyword or symbol itself.
  final String type;
  final Object? value;
  final int line;
}

const _keywords = {
  'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'goto', 'if', 'in', 'local', 'nil', 'not', 'or', 'repeat',
  'return', 'then', 'true', 'until', 'while', //
};

LuaError _syntax(String chunk, int line, String message) => LuaError('$chunk:$line: $message', level: 0)
  ..placed = true
  ..chunk = chunk
  ..line = line;

final class _Lexer {
  _Lexer(this.src, this.chunk);
  final String src, chunk;
  int pos = 0, line = 1;

  static bool _digit(int c) => c >= 0x30 && c <= 0x39;
  static bool _hex(int c) => _digit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);
  static bool _nameStart(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;

  int _at(int i) => i < src.length ? src.codeUnitAt(i) : -1;

  Never _fail(String message) => throw _syntax(chunk, line, message);

  _Token next() {
    _skip();
    final start = pos, c = _at(pos);
    if (c < 0) return _Token('eof', null, line);
    if (_nameStart(c)) {
      while (_nameStart(_at(pos)) || _digit(_at(pos))) {
        pos++;
      }
      final word = src.substring(start, pos);
      return _keywords.contains(word) ? _Token(word, null, line) : _Token('name', word, line);
    }
    if (_digit(c) || (c == 0x2E && _digit(_at(pos + 1)))) return _number();
    if (c == 0x22 || c == 0x27) return _string(c);
    if (c == 0x5B) {
      final level = _longLevel();
      if (level >= 0) {
        final at = line;
        return _Token('string', _long(level), at);
      }
    }
    final three = pos + 3 <= src.length ? src.substring(pos, pos + 3) : '';
    if (three == '...') {
      pos += 3;
      return _Token('...', null, line);
    }
    final two = pos + 2 <= src.length ? src.substring(pos, pos + 2) : '';
    const twos = {'==', '~=', '<=', '>=', '//', '::', '<<', '>>', '..'};
    if (twos.contains(two)) {
      pos += 2;
      return _Token(two, null, line);
    }
    const ones = '+-*/%^#&~|<>=(){}[];:,.';
    final one = src[pos];
    if (ones.contains(one)) {
      pos++;
      return _Token(one, null, line);
    }
    _fail("unexpected symbol near '$one'");
  }

  void _skip() {
    while (true) {
      final c = _at(pos);
      if (c == 0x0A) {
        line++;
        pos++;
      } else if (c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0B || c == 0x0C) {
        pos++;
      } else if (c == 0x2D && _at(pos + 1) == 0x2D) {
        pos += 2;
        if (_at(pos) == 0x5B) {
          final level = _longLevel();
          if (level >= 0) {
            _long(level);
            continue;
          }
        }
        while (_at(pos) >= 0 && _at(pos) != 0x0A) {
          pos++;
        }
      } else {
        return;
      }
    }
  }

  /// At a `[`: how many `=` a long bracket opening here has, or -1 when it isn't one.
  int _longLevel() {
    var i = pos + 1, level = 0;
    while (_at(i) == 0x3D) {
      i++;
      level++;
    }
    return _at(i) == 0x5B ? level : -1;
  }

  String _long(int level) {
    final startLine = line;
    pos += level + 2;
    if (_at(pos) == 0x0D) pos++;
    if (_at(pos) == 0x0A) {
      pos++;
      line++;
    }
    final start = pos, close = ']${'=' * level}]';
    final end = src.indexOf(close, pos);
    if (end < 0) {
      line = startLine;
      _fail('unfinished long string or comment');
    }
    for (var i = start; i < end; i++) {
      if (src.codeUnitAt(i) == 0x0A) line++;
    }
    pos = end + close.length;
    return src.substring(start, end);
  }

  _Token _number() {
    final start = pos;
    if (_at(pos) == 0x30 && (_at(pos + 1) == 0x78 || _at(pos + 1) == 0x58)) {
      pos += 2;
      final digits = pos;
      while (_hex(_at(pos))) {
        pos++;
      }
      if (pos == digits || _nameStart(_at(pos)) || _at(pos) == 0x2E) _fail("malformed number near '${src.substring(start, pos + 1 > src.length ? pos : pos + 1)}'");
      final text = src.substring(digits, pos);
      // Past what an integer holds, the nearest number.
      final value = int.tryParse(text, radix: 16) ?? text.codeUnits.fold<double>(0, (v, c) => v * 16 + int.parse(String.fromCharCode(c), radix: 16));
      return _Token('number', value, line);
    }
    var fraction = false;
    while (_digit(_at(pos))) {
      pos++;
    }
    if (_at(pos) == 0x2E) {
      fraction = true;
      pos++;
      while (_digit(_at(pos))) {
        pos++;
      }
    }
    if (_at(pos) == 0x65 || _at(pos) == 0x45) {
      fraction = true;
      pos++;
      if (_at(pos) == 0x2B || _at(pos) == 0x2D) pos++;
      if (!_digit(_at(pos))) _fail("malformed number near '${src.substring(start, pos)}'");
      while (_digit(_at(pos))) {
        pos++;
      }
    }
    final text = src.substring(start, pos);
    if (_nameStart(_at(pos))) _fail("malformed number near '$text${src[pos]}'");
    final num value = fraction ? double.parse(text) : (int.tryParse(text) ?? double.parse(text));
    return _Token('number', value, line);
  }

  _Token _string(int quote) {
    final at = line, out = StringBuffer();
    pos++;
    while (true) {
      final c = _at(pos);
      if (c < 0 || c == 0x0A) {
        line = at;
        _fail('unfinished string');
      }
      pos++;
      if (c == quote) break;
      if (c != 0x5C) {
        out.writeCharCode(c);
        continue;
      }
      final e = _at(pos++);
      switch (e) {
        case 0x6E:
          out.write('\n');
        case 0x74:
          out.write('\t');
        case 0x72:
          out.write('\r');
        case 0x61:
          out.writeCharCode(7);
        case 0x62:
          out.writeCharCode(8);
        case 0x66:
          out.writeCharCode(12);
        case 0x76:
          out.writeCharCode(11);
        case 0x5C || 0x22 || 0x27:
          out.writeCharCode(e);
        case 0x0A:
          line++;
          out.write('\n');
        case 0x78:
          if (!_hex(_at(pos)) || !_hex(_at(pos + 1))) _fail('hexadecimal digit expected');
          out.writeCharCode(int.parse(src.substring(pos, pos + 2), radix: 16));
          pos += 2;
        case 0x7A:
          while (true) {
            final w = _at(pos);
            if (w == 0x0A) line++;
            if (w == 0x20 || w == 0x09 || w == 0x0A || w == 0x0D) {
              pos++;
            } else {
              break;
            }
          }
        case 0x75:
          if (_at(pos) != 0x7B) _fail("missing '{' in \\u{xxxx}");
          final close = src.indexOf('}', pos);
          final code = close < 0 ? null : int.tryParse(src.substring(pos + 1, close), radix: 16);
          if (code == null || code > 0x10FFFF) _fail('invalid \\u{xxxx} escape');
          out.writeCharCode(code);
          pos = close + 1;
        default:
          if (!_digit(e)) _fail('invalid escape sequence');
          var value = e - 0x30;
          for (var k = 0; k < 2 && _digit(_at(pos)); k++) {
            value = value * 10 + _at(pos++) - 0x30;
          }
          if (value > 255) _fail('decimal escape too large');
          out.writeCharCode(value);
      }
    }
    return _Token('string', out.toString(), at);
  }
}

// MARK: Tree

/// A local variable: where its value is kept in its function's frame.
final class _Var {
  _Var(this.name, this.slot);
  final String name;
  final int slot;

  /// Whether a function inside takes hold of it: its slot then holds a [_Cell].
  bool captured = false;
  bool isConst = false;
}

/// One variable a function takes from the one around it: that one's local (by slot), or one it
/// took itself (by index).
final class _UpDesc {
  _UpDesc(this.name, this.fromLocal, this.index, this.v);
  final String name;
  final bool fromLocal;
  final int index;
  final _Var v;
}

final class _Proto {
  _Proto(this.chunk, this.line);
  final String chunk;
  final int line;
  String name = '?';
  final params = <_Var>[];
  bool isVararg = false;
  int nslots = 0;
  final upvals = <_UpDesc>[];
  late _Block body;
}

final class _Block {
  final stats = <_Stat>[];
}

sealed class _Expr {
  int line = 0;
}

final class _ENil extends _Expr {}

final class _ETrue extends _Expr {}

final class _EFalse extends _Expr {}

final class _EVararg extends _Expr {}

final class _ENumber extends _Expr {
  _ENumber(this.v);
  final num v;
}

final class _EString extends _Expr {
  _EString(this.v);
  final String v;
}

final class _ELocal extends _Expr {
  _ELocal(this.v);
  final _Var v;
}

final class _EUpval extends _Expr {
  _EUpval(this.index, this.v);
  final int index;
  final _Var v;
}

final class _EGlobal extends _Expr {
  _EGlobal(this.name);
  final String name;
}

final class _EIndex extends _Expr {
  _EIndex(this.obj, this.key);
  final _Expr obj, key;
}

final class _ECall extends _Expr {
  _ECall(this.fn, this.args);
  final _Expr fn;
  final List<_Expr> args;
}

final class _EMethod extends _Expr {
  _EMethod(this.obj, this.name, this.args);
  final _Expr obj;
  final String name;
  final List<_Expr> args;
}

final class _EFunction extends _Expr {
  _EFunction(this.proto);
  final _Proto proto;
}

final class _EBinary extends _Expr {
  _EBinary(this.op, this.a, this.b);
  final String op;
  final _Expr a, b;
}

final class _EUnary extends _Expr {
  _EUnary(this.op, this.a);
  final String op;
  final _Expr a;
}

final class _EParen extends _Expr {
  _EParen(this.e);
  final _Expr e;
}

/// `{…}`: each entry a value at the next place in the list ([key] null) or at a key.
final class _ETable extends _Expr {
  final entries = <({_Expr? key, _Expr value})>[];
}

sealed class _Stat {
  int line = 0;
}

final class _SLocal extends _Stat {
  _SLocal(this.vars, this.exprs);
  final List<_Var> vars;
  final List<_Expr> exprs;
}

final class _SAssign extends _Stat {
  _SAssign(this.targets, this.exprs);
  final List<_Expr> targets, exprs;
}

final class _SCall extends _Stat {
  _SCall(this.call);
  final _Expr call;
}

final class _SDo extends _Stat {
  _SDo(this.block);
  final _Block block;
}

final class _SWhile extends _Stat {
  _SWhile(this.cond, this.block);
  final _Expr cond;
  final _Block block;
}

final class _SRepeat extends _Stat {
  _SRepeat(this.block, this.cond);
  final _Block block;
  final _Expr cond;
}

final class _SIf extends _Stat {
  final arms = <({_Expr cond, _Block block})>[];
  _Block? otherwise;
}

final class _SFor extends _Stat {
  _SFor(this.v, this.start, this.stop, this.step, this.block);
  final _Var v;
  final _Expr start, stop;
  final _Expr? step;
  final _Block block;
}

final class _SForIn extends _Stat {
  _SForIn(this.vars, this.exprs, this.block);
  final List<_Var> vars;
  final List<_Expr> exprs;
  final _Block block;
}

final class _SLocalFunction extends _Stat {
  _SLocalFunction(this.v, this.proto);
  final _Var v;
  final _Proto proto;
}

final class _SReturn extends _Stat {
  _SReturn(this.exprs);
  final List<_Expr> exprs;
}

final class _SBreak extends _Stat {}

final class _SGoto extends _Stat {
  _SGoto(this.label);
  final String label;
}

final class _SLabel extends _Stat {
  _SLabel(this.name);
  final String name;
}

// MARK: Parser

final class _FuncState {
  _FuncState(this.parent, this.proto);
  final _FuncState? parent;
  final _Proto proto;
  final active = <_Var>[];
  int free = 0;
  int loops = 0;

  _Var declare(String name) {
    final v = _Var(name, free++);
    if (free > proto.nslots) proto.nslots = free;
    active.add(v);
    return v;
  }

  _Var? local(String name) {
    for (var i = active.length - 1; i >= 0; i--) {
      if (active[i].name == name) return active[i];
    }
    return null;
  }

  int? upval(String name) {
    final ups = proto.upvals;
    for (var i = 0; i < ups.length; i++) {
      if (ups[i].name == name) return i;
    }
    final p = parent;
    if (p == null) return null;
    final v = p.local(name);
    if (v != null) {
      v.captured = true;
      ups.add(_UpDesc(name, true, v.slot, v));
      return ups.length - 1;
    }
    final up = p.upval(name);
    if (up == null) return null;
    ups.add(_UpDesc(name, false, up, p.proto.upvals[up].v));
    return ups.length - 1;
  }
}

/// Reads Lua source into a tree, every name already found: a local, one of an outer function's,
/// or a global.
final class _Parser {
  _Parser(String source, this.chunk) : _lexer = _Lexer(source, chunk) {
    _tok = _lexer.next();
  }
  final String chunk;
  final _Lexer _lexer;
  late _Token _tok;
  _Token? _ahead;
  late _FuncState _fs;

  static const _priority = <String, (int, int)>{
    'or': (1, 1), 'and': (2, 2), //
    '<': (3, 3), '>': (3, 3), '<=': (3, 3), '>=': (3, 3), '~=': (3, 3), '==': (3, 3), //
    '|': (4, 4), '~': (5, 5), '&': (6, 6), '<<': (7, 7), '>>': (7, 7), //
    '..': (9, 8), '+': (10, 10), '-': (10, 10), '*': (11, 11), '/': (11, 11), '//': (11, 11), '%': (11, 11), '^': (14, 13),
  };
  static const _unaryPriority = 12;

  /// The whole file as a function taking `...`.
  _Proto parseChunk() {
    final proto = _Proto(chunk, 0)
      ..name = 'main chunk'
      ..isVararg = true;
    _fs = _FuncState(null, proto);
    proto.body = _block();
    if (_tok.type != 'eof') _fail("'<eof>' expected");
    return proto;
  }

  // Tokens.

  void _next() {
    if (_ahead != null) {
      _tok = _ahead!;
      _ahead = null;
    } else {
      _tok = _lexer.next();
    }
  }

  _Token _peek() => _ahead ??= _lexer.next();

  String get _near => switch (_tok.type) {
        'eof' => '<eof>',
        'name' || 'number' => '${_tok.value}',
        'string' => '"${_tok.value}"',
        final t => t,
      };

  Never _fail(String message) => throw _syntax(chunk, _tok.line, "$message near '$_near'");

  bool _accept(String type) {
    if (_tok.type != type) return false;
    _next();
    return true;
  }

  void _expect(String type) {
    if (!_accept(type)) _fail("'$type' expected");
  }

  /// The closing [type] of what [open] began at [line].
  void _close(String type, String open, int line) {
    if (_accept(type)) return;
    _fail(line == _tok.line ? "'$type' expected" : "'$type' expected (to close '$open' at line $line)");
  }

  String _name() {
    if (_tok.type != 'name') _fail('<name> expected');
    final name = _tok.value as String;
    _next();
    return name;
  }

  // Blocks and statements.

  bool get _blockEnds => const {'eof', 'end', 'else', 'elseif', 'until'}.contains(_tok.type);

  _Block _block() {
    final block = _Block(), scope = _fs.active.length, free = _fs.free;
    _statements(block);
    _fs.active.length = scope;
    _fs.free = free;
    return block;
  }

  void _statements(_Block block) {
    while (!_blockEnds) {
      if (_tok.type == 'return') {
        final line = _tok.line;
        _next();
        final exprs = _blockEnds || _tok.type == ';' ? <_Expr>[] : _exprList();
        _accept(';');
        block.stats.add(_SReturn(exprs)..line = line);
        if (!_blockEnds) _fail("'<eof>' expected");
        return;
      }
      final stat = _statement();
      if (stat != null) block.stats.add(stat);
    }
  }

  _Stat? _statement() {
    final line = _tok.line;
    switch (_tok.type) {
      case ';':
        _next();
        return null;
      case 'if':
        return _if()..line = line;
      case 'while':
        _next();
        final cond = _expr();
        _expect('do');
        _fs.loops++;
        final body = _block();
        _fs.loops--;
        _close('end', 'while', line);
        return _SWhile(cond, body)..line = line;
      case 'do':
        _next();
        final body = _block();
        _close('end', 'do', line);
        return _SDo(body)..line = line;
      case 'for':
        return _for()..line = line;
      case 'repeat':
        _next();
        final block = _Block(), scope = _fs.active.length, free = _fs.free;
        _fs.loops++;
        _statements(block);
        _fs.loops--;
        _close('until', 'repeat', line);
        // The condition sees the body's locals.
        final cond = _expr();
        _fs.active.length = scope;
        _fs.free = free;
        return _SRepeat(block, cond)..line = line;
      case 'function':
        _next();
        // function a.b.c:m(…)
        final first = _name();
        _Expr target = _resolve(first)..line = line;
        var name = first, method = false;
        while (_tok.type == '.' || _tok.type == ':') {
          method = _tok.type == ':';
          _next();
          final key = _name();
          name = '$name${method ? ':' : '.'}$key';
          target = _EIndex(target, _EString(key)..line = line)..line = line;
          if (method) break;
        }
        final proto = _body(line, name: name, method: method);
        _assignable(target);
        return _SAssign([target], [_EFunction(proto)..line = line])..line = line;
      case 'local':
        _next();
        if (_accept('function')) {
          final name = _name();
          final v = _fs.declare(name);
          return _SLocalFunction(v, _body(line, name: name))..line = line;
        }
        final names = <String>[], attribs = <String?>[];
        do {
          names.add(_name());
          if (_accept('<')) {
            final attrib = _name();
            if (attrib != 'const' && attrib != 'close') _fail("unknown attribute '$attrib'");
            if (attrib == 'close') _fail("'<close>' variables aren't available here");
            attribs.add(attrib);
            _expect('>');
          } else {
            attribs.add(null);
          }
        } while (_accept(','));
        final exprs = _accept('=') ? _exprList() : <_Expr>[];
        // In scope only after their values: `local x = x` reads the outer one.
        final vars = [
          for (final (i, name) in names.indexed) _fs.declare(name)..isConst = attribs[i] != null,
        ];
        return _SLocal(vars, exprs)..line = line;
      case 'return':
        _fail('unexpected return');
      case 'break':
        _next();
        if (_fs.loops == 0) throw _syntax(chunk, line, "break outside a loop at line $line");
        return _SBreak()..line = line;
      case 'goto':
        _next();
        return _SGoto(_name())..line = line;
      case '::':
        _next();
        final label = _name();
        _expect('::');
        return _SLabel(label)..line = line;
      default:
        final e = _suffixed();
        if (_tok.type == '=' || _tok.type == ',') {
          final targets = [e];
          while (_accept(',')) {
            targets.add(_suffixed());
          }
          _expect('=');
          final exprs = _exprList();
          targets.forEach(_assignable);
          return _SAssign(targets, exprs)..line = line;
        }
        if (e is! _ECall && e is! _EMethod) _fail('syntax error');
        return _SCall(e)..line = line;
    }
  }

  void _assignable(_Expr e) {
    switch (e) {
      case _ELocal(:final v) || _EUpval(:final v):
        if (v.isConst) throw _syntax(chunk, e.line, "attempt to assign to const variable '${v.name}'");
      case _EGlobal() || _EIndex():
        break;
      default:
        _fail('syntax error');
    }
  }

  _SIf _if() {
    final stat = _SIf(), line = _tok.line;
    _next();
    while (true) {
      final cond = _expr();
      _expect('then');
      stat.arms.add((cond: cond, block: _block()));
      if (_accept('elseif')) continue;
      if (_accept('else')) stat.otherwise = _block();
      _close('end', 'if', line);
      return stat;
    }
  }

  _Stat _for() {
    final line = _tok.line;
    _next();
    final first = _name();
    final scope = _fs.active.length, free = _fs.free;
    _Stat stat;
    if (_accept('=')) {
      final start = _expr();
      _expect(',');
      final stop = _expr();
      final step = _accept(',') ? _expr() : null;
      _expect('do');
      final v = _fs.declare(first);
      _fs.loops++;
      final body = _block();
      _fs.loops--;
      stat = _SFor(v, start, stop, step, body);
    } else {
      final names = [first];
      while (_accept(',')) {
        names.add(_name());
      }
      _expect('in');
      final exprs = _exprList();
      _expect('do');
      final vars = [for (final n in names) _fs.declare(n)];
      _fs.loops++;
      final body = _block();
      _fs.loops--;
      stat = _SForIn(vars, exprs, body);
    }
    _fs.active.length = scope;
    _fs.free = free;
    _close('end', 'for', line);
    return stat;
  }

  /// `(params) block end`, the function keyword already read.
  _Proto _body(int line, {required String name, bool method = false}) {
    final proto = _Proto(chunk, line)..name = name;
    final outer = _fs;
    _fs = _FuncState(outer, proto);
    if (method) proto.params.add(_fs.declare('self'));
    _expect('(');
    if (_tok.type != ')') {
      do {
        if (_accept('...')) {
          proto.isVararg = true;
          break;
        }
        proto.params.add(_fs.declare(_name()));
      } while (_accept(','));
    }
    _expect(')');
    proto.body = _block();
    _close('end', 'function', line);
    _fs = outer;
    return proto;
  }

  // Expressions.

  List<_Expr> _exprList() {
    final list = [_expr()];
    while (_accept(',')) {
      list.add(_expr());
    }
    return list;
  }

  _Expr _expr() => _sub(0);

  _Expr _sub(int limit) {
    final line = _tok.line;
    _Expr e;
    final t = _tok.type;
    if (t == 'not' || t == '-' || t == '#' || t == '~') {
      _next();
      final a = _sub(_unaryPriority);
      e = t == '-' && a is _ENumber ? _ENumber(-a.v) : _EUnary(t, a);
      e.line = line;
    } else {
      e = _simple();
    }
    while (true) {
      final op = _tok.type, p = _priority[op];
      if (p == null || p.$1 <= limit) return e;
      final at = _tok.line;
      _next();
      e = _EBinary(op, e, _sub(p.$2))..line = at;
    }
  }

  _Expr _simple() {
    final line = _tok.line;
    _Expr e;
    switch (_tok.type) {
      case 'number':
        e = _ENumber(_tok.value as num);
      case 'string':
        e = _EString(_tok.value as String);
      case 'nil':
        e = _ENil();
      case 'true':
        e = _ETrue();
      case 'false':
        e = _EFalse();
      case '...':
        if (!_fs.proto.isVararg) _fail("cannot use '...' outside a vararg function");
        e = _EVararg();
      case '{':
        return _table();
      case 'function':
        _next();
        return _EFunction(_body(line, name: 'anonymous'))..line = line;
      default:
        return _suffixed();
    }
    _next();
    return e..line = line;
  }

  _Expr _resolve(String name) {
    final v = _fs.local(name);
    if (v != null) return _ELocal(v);
    final up = _fs.upval(name);
    if (up != null) return _EUpval(up, _fs.proto.upvals[up].v);
    return _EGlobal(name);
  }

  _Expr _suffixed() {
    final line = _tok.line;
    _Expr e;
    if (_tok.type == 'name') {
      e = _resolve(_name())..line = line;
    } else if (_accept('(')) {
      final inner = _expr();
      _close(')', '(', line);
      // In brackets a call gives one value.
      e = (inner is _ECall || inner is _EMethod || inner is _EVararg ? _EParen(inner) : inner)..line = line;
    } else {
      _fail('unexpected symbol');
    }
    while (true) {
      final at = _tok.line;
      switch (_tok.type) {
        case '.':
          _next();
          e = _EIndex(e, _EString(_name())..line = at)..line = at;
        case '[':
          _next();
          final key = _expr();
          _expect(']');
          e = _EIndex(e, key)..line = at;
        case ':':
          _next();
          final name = _name();
          e = _EMethod(e, name, _args())..line = at;
        case '(' || 'string' || '{':
          e = _ECall(e, _args())..line = at;
        default:
          return e;
      }
    }
  }

  List<_Expr> _args() {
    final line = _tok.line;
    switch (_tok.type) {
      case 'string':
        final s = _EString(_tok.value as String)..line = line;
        _next();
        return [s];
      case '{':
        return [_table()];
      case '(':
        _next();
        if (_accept(')')) return [];
        final args = _exprList();
        _close(')', '(', line);
        return args;
      default:
        _fail('function arguments expected');
    }
  }

  _Expr _table() {
    final line = _tok.line, table = _ETable()..line = line;
    _expect('{');
    while (_tok.type != '}') {
      if (_tok.type == 'name' && _peek().type == '=') {
        final key = _EString(_name())..line = _tok.line;
        _next();
        table.entries.add((key: key, value: _expr()));
      } else if (_tok.type == '[') {
        _next();
        final key = _expr();
        _expect(']');
        _expect('=');
        table.entries.add((key: key, value: _expr()));
      } else {
        table.entries.add((key: null, value: _expr()));
      }
      if (!_accept(',') && !_accept(';')) break;
    }
    _close('}', '{', line);
    return table;
  }
}
