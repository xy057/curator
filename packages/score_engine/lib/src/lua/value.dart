part of '../lua.dart';

/// What a Lua function is called with and what it gives back: Lua values, any number of each.
/// A Lua value is null (nil), a [bool], a [num], a [String], a [LuaTable], a [LuaFunction] or
/// anything else the host hands in (a userdata: Lua can pass it around and nothing more).
typedef LuaCall = List<Object?> Function(List<Object?> args);

const _none = <Object?>[];

/// An error raised in Lua (`error(…)`, a wrong operand, a syntax error): its [value], most often
/// a message starting with where it happened (`main.lua:12: attempt to index a nil value`).
class LuaError implements Exception {
  LuaError(this.value, {this.level = 1});

  /// What `error` was given, or the message.
  Object? value;

  /// As `error`'s second argument: 0 keeps the message as it is, 1 has where it was raised put
  /// before it (once: see [placed]), 2 where that function was called, and so on.
  int level;

  /// Whether [value] already says where.
  bool placed = false;

  /// The file and line the error is at, once placed.
  String? chunk;
  int? line;

  /// The calls it passed through, innermost first (`main.lua:40`).
  final List<String> trace = [];

  String get message => value is String ? value as String : Lua.show(value);

  @override
  String toString() => message;
}

/// A limit reached (too many steps, too deep, a string too long): what stops a script that would
/// never end. `pcall` doesn't catch it.
class LuaLimit extends LuaError {
  LuaLimit(String super.message) : super(level: 0);
}

/// A Lua function: one written in Lua, or one of the host's ([LuaBuiltin]).
abstract class LuaFunction {
  String get name;
  List<Object?> call(List<Object?> args);
}

/// A function the host gives Lua.
final class LuaBuiltin extends LuaFunction {
  LuaBuiltin(this.name, this.fn);
  @override
  final String name;
  final LuaCall fn;

  @override
  List<Object?> call(List<Object?> args) => fn(args);

  @override
  String toString() => 'builtin: $name';
}

/// Whether a table is saved as a list or as a map when it is empty (otherwise what it holds says).
enum LuaShape { list, map }

/// A Lua table: values by key, those at 1, 2, 3… kept in order ([array]).
final class LuaTable {
  LuaTable();

  /// A list's table: [values] at 1, 2, 3….
  LuaTable.list(Iterable<Object?> values) : shape = LuaShape.list {
    array.addAll(values);
    _trim();
  }

  /// A map's table.
  LuaTable.map(Map<Object, Object?> values) : shape = LuaShape.map {
    values.forEach((k, v) => this[k] = v);
  }

  /// The values at 1…: `array[i - 1]` is `t[i]`. Its last is never nil; one before may be.
  final List<Object?> array = [];
  Map<Object, Object?>? _hash;

  LuaTable? metatable;

  /// What an empty table is saved as; null: a list.
  LuaShape? shape;

  /// `#t`.
  int get length => array.length;

  /// How many keys are held outside [array].
  int get hashLength => _hash?.length ?? 0;

  /// The keys outside [array], in the order they were first set.
  Iterable<Object> get hashKeys => _hash?.keys ?? const [];

  bool get isEmpty => array.isEmpty && (_hash?.isEmpty ?? true);

  /// `rawget(t, key)`.
  Object? operator [](Object? key) {
    if (key is int) {
      if (key >= 1 && key <= array.length) return array[key - 1];
      return _hash?[key];
    }
    if (key is double) {
      if (key.isFinite && key == key.truncateToDouble()) return this[key.toInt()];
      return _hash?[key];
    }
    if (key == null) return null;
    return _hash?[key];
  }

  /// A field by name.
  Object? field(String name) => _hash?[name];

  /// `rawset(t, key, value)`.
  void operator []=(Object? key, Object? value) {
    if (key is double && key is! int) {
      if (key.isNaN) throw LuaError('table index is NaN');
      if (key.isFinite && key == key.truncateToDouble()) key = key.toInt();
    }
    if (key is int) {
      final n = array.length;
      if (key >= 1 && key <= n) {
        array[key - 1] = value;
        if (value == null && key == n) _trim();
        return;
      }
      if (key == n + 1) {
        if (value == null) return;
        array.add(value);
        final hash = _hash;
        if (hash != null && hash.isNotEmpty) {
          // What was set past the end before now follows on.
          for (var next = n + 2; hash.containsKey(next); next++) {
            array.add(hash.remove(next));
          }
        }
        return;
      }
    }
    if (key == null) throw LuaError('table index is nil');
    if (value == null) {
      _hash?.remove(key);
    } else {
      (_hash ??= {})[key] = value;
    }
  }

  void _trim() {
    while (array.isNotEmpty && array.last == null) {
      array.removeLast();
    }
  }

  /// `table.insert(t, value)`.
  void add(Object? value) => this[array.length + 1] = value;

  /// After [array] was changed in place: its last is no nil, and what was set past its end
  /// before follows on.
  void _settle() {
    _trim();
    final hash = _hash;
    if (hash == null || hash.isEmpty) return;
    for (var next = array.length + 1; hash.containsKey(next); next++) {
      array.add(hash.remove(next));
    }
  }

  /// The key after [key] and its value as `next` gives them (the list's first, then the rest in
  /// the order set); null at the end. Slow past the list: `pairs` doesn't use it.
  (Object, Object?)? after(Object? key) {
    var i = 0;
    if (key != null) {
      final at = key is num && key == key.truncate() ? key.toInt() : 0;
      if (at >= 1 && at <= array.length) {
        i = at;
      } else {
        final hash = _hash;
        if (hash == null || !hash.containsKey(key)) throw LuaError("invalid key to 'next'");
        var found = false;
        for (final e in hash.entries) {
          if (found) return (e.key, e.value);
          if (e.key == key) found = true;
        }
        return null;
      }
    }
    for (; i < array.length; i++) {
      if (array[i] != null) return (i + 1, array[i]);
    }
    final hash = _hash;
    if (hash == null || hash.isEmpty) return null;
    final first = hash.entries.first;
    return (first.key, first.value);
  }
}

/// A variable a function inside its own took hold of: both see the one value.
final class _Cell {
  _Cell(this.value);
  Object? value;
}
