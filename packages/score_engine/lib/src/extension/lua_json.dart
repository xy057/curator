import '../lua.dart';

/// Lua values as JSON and back: what an extension saves in a project, and what the app hands it.
///
/// A list is a table of values at 1, 2, 3…; a map a table of values by text keys. A table with
/// nothing in it is saved as what it was read as ([LuaTable.shape]), a new one as a list. JSON's
/// null is nil in a map (the key isn't there) and [nil] in a list, where a nil would end it.
abstract final class LuaJson {
  /// JSON's null where Lua's nil can't stand: a value in a list (`curator.null`).
  static const Object nil = _Null();

  /// [json] (maps, lists, text, numbers, booleans, null) as a Lua value.
  static Object? toLua(Object? json) {
    switch (json) {
      case final Map<Object?, Object?> map:
        final t = LuaTable()..shape = LuaShape.map;
        map.forEach((k, v) {
          if (v != null) t[k as String] = toLua(v);
        });
        return t;
      case final List<Object?> list:
        final t = LuaTable()..shape = LuaShape.list;
        for (final v in list) {
          t.array.add(v == null ? nil : toLua(v));
        }
        return t;
      default:
        return json;
    }
  }

  /// A Lua value as JSON. What can't be saved (a function, a table that is both a list and a
  /// map, a key that isn't text, a number that isn't one) is a [LuaError] saying where in
  /// [where] it is.
  static Object? fromLua(Object? value, {String where = 'value'}) => _from(value, where, 0);

  static Object? _from(Object? value, String where, int depth) {
    if (value == null || value is bool || value is String || identical(value, nil)) return identical(value, nil) ? null : value;
    if (value is num) {
      if (value is double && !value.isFinite) throw LuaError('$where is ${Lua.number(value)}, which can’t be saved', level: 0);
      return value;
    }
    if (value is! LuaTable) throw LuaError('$where is a ${Lua.typeOf(value)}, which can’t be saved', level: 0);
    if (depth > 64) throw LuaError('$where is nested too deeply (does a table hold itself?)', level: 0);
    final keyed = value.hashLength > 0;
    if (keyed && value.length > 0) throw LuaError('$where is both a list and a map: save one or the other', level: 0);
    if (!keyed && (value.length > 0 || value.shape != LuaShape.map)) {
      return [
        for (final (i, v) in value.array.indexed)
          if (v == null) throw LuaError('$where[${i + 1}] is nil: a list saved has no gaps', level: 0) else _from(v, '$where[${i + 1}]', depth + 1),
      ];
    }
    final out = <String, Object?>{};
    for (final key in value.hashKeys) {
      if (key is! String) throw LuaError('$where has the key ${Lua.show(key)}: a map saved has text keys', level: 0);
      out[key] = _from(value[key], '$where.$key', depth + 1);
    }
    return out;
  }

  /// Whether two JSON values are the same, a number equal to itself as an int or a double.
  static bool same(Object? a, Object? b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !same(a[key], b[key])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!same(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}

final class _Null {
  const _Null();
  @override
  String toString() => 'null';
}
