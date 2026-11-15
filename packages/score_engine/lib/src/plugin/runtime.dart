import 'package:flutter/foundation.dart';

import '../lua.dart';
import '../script.dart';
import 'api.dart';
import 'package.dart';

/// A key as a plugin writes one: what is held, then the key, joined by "+" ("cmd+shift+k").
/// [key] is the key as typed, in lower case ("k", "7", ","), or its name ([PluginApi.keyNames]).
/// [command] is ⌘ on a Mac and Ctrl elsewhere.
@immutable
class PluginKey {
  const PluginKey(this.key, {this.command = false, this.control = false, this.alt = false, this.shift = false});
  final String key;
  final bool command, control, alt, shift;

  static const _held = {
    'cmd': 'cmd', 'command': 'cmd', '⌘': 'cmd', //
    'ctrl': 'ctrl', 'control': 'ctrl', '⌃': 'ctrl',
    'alt': 'alt', 'option': 'alt', 'opt': 'alt', '⌥': 'alt',
    'shift': 'shift', '⇧': 'shift',
  };
  static const _names = {'return': 'enter', 'esc': 'escape', 'del': 'delete', 'pgup': 'pageup', 'pgdn': 'pagedown', 'plus': '=', 'minus': '-'};

  /// The key [text] writes; null when it writes none.
  static PluginKey? parse(String text) {
    final parts = text.trim().toLowerCase().split('+').map((p) => p.trim()).toList();
    if (parts.isEmpty || parts.any((p) => p.isEmpty)) return null;
    final held = <String>{};
    for (final part in parts.take(parts.length - 1)) {
      final name = _held[part];
      if (name == null || !held.add(name)) return null;
    }
    final key = _names[parts.last] ?? parts.last;
    if (!PluginApi.keyNames.contains(key) && (key.runes.length != 1 || key.codeUnitAt(0) <= 0x20 || key.codeUnitAt(0) >= 0x7f)) return null;
    return PluginKey(key, command: held.contains('cmd'), control: held.contains('ctrl'), alt: held.contains('alt'), shift: held.contains('shift'));
  }

  /// As it is written.
  @override
  String toString() => [if (command) 'cmd', if (control) 'ctrl', if (alt) 'alt', if (shift) 'shift', key].join('+');

  @override
  bool operator ==(Object other) => other is PluginKey && other.toString() == toString();
  @override
  int get hashCode => toString().hashCode;
}

/// A command a plugin added (`app.command`): what it is called, where it is offered, and its
/// functions.
class PluginCommand {
  PluginCommand({
    required this.plugin,
    required this.id,
    required this.title,
    required this.run,
    this.menu = const [],
    this.before,
    this.after,
    this.key,
    this.toolbar = false,
    this.home = false,
    this.preview = false,
    this.icon,
    this.enabled,
    this.checked,
  });

  /// The id of the plugin that added it.
  final String plugin;
  final String id;

  /// Its name, in English: shown translated ([ScriptRuntime.translate]).
  final String title;

  /// The menu it is in, then the menus inside that one down to its own (["View", "Zoom"]);
  /// none: it is in no menu.
  final List<String> menu;

  /// A command of its menu it sits before, or after; neither: at the menu's end.
  final String? before, after;
  final PluginKey? key;

  /// Whether it is a button on the editor's toolbar, on Home, an item of the preview's menu.
  final bool toolbar, home, preview;
  final String? icon;
  final LuaFunction run;
  final LuaFunction? enabled, checked;
}

/// What a running plugin stands on: the app. Its window gives one; a test gives its own.
abstract class PluginHost extends ScriptHost {
  /// What plugins add to the app or change in it is other than it was: the menus, the keys and
  /// the toolbar are made again.
  void changed() {}

  /// Whether a command of another plugin's goes by [name] (its id or its title).
  bool hasCommand(String name) => false;

  /// Adds what this host offers beyond the engine's (the rest of `app`, `project`, `ui`), once
  /// the runtime's own libraries are in place.
  void install(PluginRuntime runtime) {}
}

/// A plugin running: its Lua world, what it added to the app ([commands]) and changed in it
/// ([hidden], [titles], [keys], [wraps]), and what it listens to. One for the app, started as it
/// starts or as the plugin's switch is turned on.
class PluginRuntime extends ScriptRuntime {
  PluginRuntime(this.package, this.host) : super(package, host) {
    _installApp();
    host.install(this);
    if (!package.sources.containsKey(PluginPackage.entry)) {
      _problem(ScriptProblem(id, 'The plugin has no src/${PluginPackage.entry}.', file: 'plugin.json'));
      return;
    }
    try {
      lua.call(LuaBuiltin('load', (_) => [module(PluginPackage.entry)]), const [], ScriptRuntime.eventSteps);
    } on LuaError catch (e) {
      _problem(ScriptProblem.of(id, e, where: PluginPackage.entry));
    }
  }

  /// The most commands a plugin adds, and the most it listens to.
  static const maxCommands = 500, maxListeners = 500;

  final PluginPackage package;
  final PluginHost host;

  /// What went wrong starting it: none when its main.lua read and ran.
  final List<ScriptProblem> problems = [];

  void _problem(ScriptProblem problem) {
    problems.add(problem);
    host.report(problem);
  }

  @override
  int get apiLevel => PluginApi.level;
  @override
  bool knows(String name) => PluginApi.has(name);

  // MARK: What it adds and changes

  /// The commands it added, in the order it did.
  final commands = <PluginCommand>[];

  /// The commands it took out of their menus; the titles and the keys (null: none) it gave
  /// commands; what it put around the app's own. Each by the command's id: one of the app's
  /// ([PluginApi.commands]), or a plugin's.
  final hidden = <String>{};
  final titles = <String, String>{};
  final keys = <String, PluginKey?>{};
  final wraps = <String, LuaFunction>{};

  final _listeners = <String, List<LuaFunction>>{};

  /// Whether it listens to [event].
  bool listens(String event) => _listeners[event]?.isNotEmpty ?? false;

  /// Tells its listeners [event] happened, with [args] (Lua values). What one raises is
  /// reported, and the rest are still told.
  void emit(String event, [List<Object?> args = const []]) {
    for (final fn in [...?_listeners[event]]) {
      call(fn, args: args, where: event);
    }
  }

  PluginCommand? command(String name) {
    final wanted = PluginApi.named(name);
    for (final c in commands) {
      if (c.id == wanted || c.title == wanted) return c;
    }
    return null;
  }

  /// The `enabled` and `checked` functions that failed: asked at every drawing of a menu, one
  /// says what is wrong once and is not asked again.
  final _failed = Set<LuaFunction>.identity();

  bool _ask(LuaFunction fn, String where, List<Object?> args) {
    if (_failed.contains(fn)) return false;
    final result = call(fn, args: args, where: where, steps: ScriptRuntime.frameSteps);
    if (result == null) _failed.add(fn);
    return result != null && result.truthy(0);
  }

  /// Whether [command] can be chosen now, as its `enabled` says (always, without one; not when
  /// that fails).
  bool canRun(PluginCommand command, [List<Object?> args = const []]) => command.enabled == null || _ask(command.enabled!, '${command.id} enabled', args);

  /// Whether [command] is ticked now, as its `checked` says.
  bool isChecked(PluginCommand command) => command.checked != null && _ask(command.checked!, '${command.id} checked', const []);

  /// Does [command]; whether it ran without an error.
  bool perform(PluginCommand command, [List<Object?> args = const []]) => call(command.run, args: args, where: command.id) != null;

  /// The id of the command [name] names, for changing it: one of the app's, one of this
  /// plugin's, or another's. An error when there is none.
  String _named(String fn, String name) {
    final wanted = PluginApi.named(name);
    final own = PluginApi.command(wanted);
    if (own != null) return own.id;
    final mine = command(wanted);
    if (mine != null) return mine.id;
    if (host.hasCommand(wanted)) return wanted;
    throw LuaError("bad argument #1 to '$fn' (there is no command '$name')");
  }

  static final _idChars = RegExp(r'[^a-z0-9]+');

  /// An id from a title: "Count Bars…" is "count-bars".
  static String idOf(String title) => title.toLowerCase().replaceAll(_idChars, '-').replaceAll(RegExp(r'^-+|-+$'), '');

  void _installApp() {
    library('app', {
      'command': (a) {
        final spec = a.table(0, 'app.command');
        String? text(String key) => switch (spec[key]) {
              null => null,
              final String s when s.trim().isNotEmpty => s.trim(),
              _ => throw LuaError("bad argument #1 to 'app.command' ($key is not a text)"),
            };
        LuaFunction? function(String key) => switch (spec[key]) {
              null => null,
              final LuaFunction f => f,
              _ => throw LuaError("bad argument #1 to 'app.command' ($key is not a function)"),
            };
        bool flag(String key) => spec[key] != null && spec[key] != false;

        final title = text('title'), run = function('run');
        if (title == null) throw LuaError("bad argument #1 to 'app.command' (a command needs a title)");
        if (run == null) throw LuaError("bad argument #1 to 'app.command' (a command needs run, the function that does it)");
        final id = text('id') ?? idOf(title);
        if (id.isEmpty) throw LuaError("bad argument #1 to 'app.command' (give it an id: its title has no letters to make one from)");
        if (PluginApi.command(id) != null) throw LuaError("bad argument #1 to 'app.command' ('$id' is a command of the app’s own: give it another id)");
        final keyText = text('key'), key = keyText == null ? null : PluginKey.parse(keyText);
        if (keyText != null && key == null) throw LuaError("bad argument #1 to 'app.command' ('$keyText' is not a key: write one as \"cmd+shift+k\")");
        final icon = text('icon');
        if (icon != null && !PluginApi.icons.contains(icon)) throw LuaError("bad argument #1 to 'app.command' (there is no icon '$icon')");
        final menu = [
          for (final part in (text('menu') ?? '').split('/'))
            if (part.trim().isNotEmpty) part.trim(),
        ];
        final added = PluginCommand(
          plugin: this.id,
          id: id,
          title: title,
          run: run,
          menu: menu,
          before: switch (text('before')) { final b? => PluginApi.command(b)?.id ?? PluginApi.named(b), null => null },
          after: switch (text('after')) { final b? => PluginApi.command(b)?.id ?? PluginApi.named(b), null => null },
          key: key,
          toolbar: flag('toolbar'),
          home: flag('home'),
          preview: flag('preview'),
          icon: icon,
          enabled: function('enabled'),
          checked: function('checked'),
        );
        final at = commands.indexWhere((c) => c.id == id);
        if (at >= 0) {
          commands[at] = added;
        } else {
          if (commands.length >= maxCommands) throw LuaError("'app.command': a plugin adds $maxCommands commands at most");
          commands.add(added);
        }
        host.changed();
        return [id];
      },
      'remove': (a) {
        final name = PluginApi.named(a.string(0, 'app.remove')), before = commands.length;
        commands.removeWhere((c) => c.id == name || c.title == name);
        if (commands.length != before) host.changed();
        return const [];
      },
      'hide': (a) {
        if (hidden.add(_named('app.hide', a.string(0, 'app.hide')))) host.changed();
        return const [];
      },
      'show': (a) {
        if (hidden.remove(_named('app.show', a.string(0, 'app.show')))) host.changed();
        return const [];
      },
      'rename': (a) {
        final id = _named('app.rename', a.string(0, 'app.rename')), title = a.stringOr(1, 'app.rename')?.trim();
        if (title == null || title.isEmpty) {
          titles.remove(id);
        } else {
          titles[id] = title;
        }
        host.changed();
        return const [];
      },
      'rebind': (a) {
        final id = _named('app.rebind', a.string(0, 'app.rebind')), text = a.stringOr(1, 'app.rebind');
        if (PluginApi.command(id) case final own? when !own.rebind) throw LuaError("bad argument #1 to 'app.rebind' (${own.title} keeps its key)");
        final key = text == null ? null : PluginKey.parse(text);
        if (text != null && key == null) throw LuaError("bad argument #2 to 'app.rebind' ('$text' is not a key: write one as \"cmd+shift+k\")");
        keys[id] = key;
        host.changed();
        return const [];
      },
      'wrap': (a) {
        final id = _named('app.wrap', a.string(0, 'app.wrap')), fn = a.functionOr(1, 'app.wrap');
        if (PluginApi.command(id) == null) throw LuaError("bad argument #1 to 'app.wrap' (only the app’s own commands are wrapped)");
        if (fn == null) {
          wraps.remove(id);
        } else {
          wraps[id] = fn;
        }
        host.changed();
        return const [];
      },
      'on': (a) {
        final event = a.string(0, 'app.on'), fn = a.function(1, 'app.on');
        if (PluginApi.event(event) == null) throw LuaError("bad argument #1 to 'app.on' (there is no event '$event')");
        final listeners = _listeners[event] ??= [];
        if (_listeners.values.fold(0, (n, l) => n + l.length) >= maxListeners) throw LuaError("'app.on': a plugin listens $maxListeners times at most");
        listeners.add(fn);
        host.changed();
        return [
          LuaBuiltin('off', (_) {
            if (listeners.remove(fn)) host.changed();
            return const [];
          }),
        ];
      },
    });
  }
}

/// What is wrong with [package] as it is written, found without running it: no main.lua, a
/// file that doesn't read as Lua (with its line), an API level this Curator hasn't reached
/// (a warning: it runs, and what it asks for that isn't here fails as it is called).
List<ScriptProblem> checkPlugin(PluginPackage package) {
  final id = package.id, problems = <ScriptProblem>[];
  if (package.api > PluginApi.level) {
    problems.add(ScriptProblem(id, 'It needs API level ${package.api}; this Curator has ${PluginApi.level}.', file: 'plugin.json', warning: true));
  }
  if (!package.sources.containsKey(PluginPackage.entry)) problems.add(ScriptProblem(id, 'The plugin has no src/${PluginPackage.entry}.', file: 'plugin.json'));
  for (final MapEntry(key: path, value: source) in package.sources.entries) {
    try {
      Lua.functionsIn(source, chunk: path);
    } on LuaError catch (e) {
      problems.add(ScriptProblem(id, e.message, file: path, line: e.line));
    }
  }
  return problems;
}
