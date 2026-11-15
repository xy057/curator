import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import '../app_colors.dart';
import '../app_folders.dart';
import '../app_icons.dart';
import '../app_settings.dart';
import '../editor_controller.dart';
import '../extensions/extension_files.dart';
import '../extensions/extension_form.dart';
import '../extensions/extension_sheet.dart';
import '../key_bindings.dart';
import '../l10n/l10n.dart';
import '../updater.dart' show appBuild, appVersion;
import 'bundled.dart';

/// A project in a tab, as a plugin is told of one.
typedef PluginProject = ({String name, String? path, bool edited});

/// What plugins act on: the app's window, which gives one.
abstract interface class PluginWindow {
  /// Where a plugin's dialogs open; null: nowhere now.
  BuildContext? get dialogContext;

  /// The editor of the project showing; null on Home, and until it has opened.
  EditorController? get controller;

  /// The project showing; null on Home.
  PluginProject? get project;

  /// The projects open, in the tabs' order, and which shows (null: Home).
  List<PluginProject> get projects;
  int? get showing;

  /// Shows a tab: null for Home.
  void showTab(int? index);

  /// Opens the project or score at [path] in a tab.
  void open(String path);

  /// A line at the window's foot, for a moment.
  void message(String text);

  /// The app's own commands by id ([PluginApi.commands]), each as it can be chosen now: null
  /// while it can't.
  Map<String, VoidCallback?> get commands;
}

/// A command a plugin added, with the plugin running it.
typedef PluginEntry = ({PluginRuntime runtime, PluginCommand command});

/// Plugins: what augments the app itself, in every project (Settings ▸ Plugins). Which there
/// are (Curator's own, [BundledPlugins], and those the user added, kept as `.cgp` files in the
/// app's Plugins folder), which are on ([AppSettings.pluginsOn]), those running (a
/// [PluginRuntime] each, from the app's start or their switch), and what they add to the app
/// and change in it, as the menus, the keys and the toolbar ask.
///
/// It tells its listeners when what plugins add or change is other than it was.
class Plugins extends ChangeNotifier {
  /// [folder] is where added plugins are kept; without one they are kept until the app closes
  /// (a test's).
  Plugins(this.settings, {this.folder, Iterable<PluginPackage> installed = const [], Map<String, String> files = const {}}) : _files = {...files} {
    for (final p in installed) {
      _installed[p.id] = p;
    }
    // What a plugin says of a command (ticked, to be chosen) may hang on a setting.
    settings.addListener(_changed);
  }

  /// The plugins in the app's Plugins folder ([AppFolders]), read as the app starts. One that
  /// doesn't read is left where it is, and isn't listed.
  static Future<Plugins> load(AppSettings settings) async {
    final installed = <PluginPackage>[], files = <String, String>{};
    Directory? folder;
    try {
      folder = AppFolders.folder('Plugins');
      for (final file in folder.listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path))) {
        if (!file.path.toLowerCase().endsWith('.${PluginPackage.fileExtension}')) continue;
        try {
          final package = PluginPackage.read(await file.readAsBytes());
          if (!PluginPackage.isThirdPartyId(package.id) || files.containsKey(package.id)) continue;
          installed.add(package);
          files[package.id] = file.path;
        } on Object catch (e) {
          debugPrint('Couldn’t read the plugin ${file.path}: $e');
        }
      }
    } on Object catch (e) {
      debugPrint('Couldn’t read the plugins: $e');
    }
    return Plugins(settings, folder: folder, installed: installed, files: files);
  }

  final AppSettings settings;
  final Directory? folder;

  /// Where each added plugin's file is, by id.
  final Map<String, String> _files;
  final _installed = <String, PluginPackage>{};

  // MARK: Which there are

  /// Curator's own, then the ones added, by name.
  List<PluginPackage> get packages => [
        ...BundledPlugins.packages,
        ..._installed.values.toList()..sort((a, b) => switch (a.name.toLowerCase().compareTo(b.name.toLowerCase())) { 0 => a.id.compareTo(b.id), final by => by }),
      ];

  PluginPackage? package(String id) => _installed[id] ?? BundledPlugins.byId(id);

  /// Whether plugin [id] is Curator's own: it changes with the app, and is never changed here.
  bool isOwn(String id) => BundledPlugins.byId(id) != null;

  bool isOn(String id) => settings.pluginsOn.contains(id);

  /// Turns plugin [id] on or off: it starts or stops now.
  void turn(String id, bool on) {
    settings.setPluginOn(id, on);
    if (!on) clearProblems(id);
    _sync();
    _changed();
  }

  /// Adds [package] (in place of the one with its id), kept as a file in the Plugins folder:
  /// off until its switch is turned; one that is on starts again as it now is. A
  /// [FileSystemException] when it can't be kept.
  void add(PluginPackage package) {
    if (!PluginPackage.isThirdPartyId(package.id)) throw const FormatException('The plugin has no id Curator can use.');
    if (_installed[package.id] == package) return;
    if (folder case final folder?) {
      final path = _files[package.id] ?? '${folder.path}${Platform.pathSeparator}${package.id}.${PluginPackage.fileExtension}';
      File(path).writeAsBytesSync(package.write(), flush: true);
      _files[package.id] = path;
    }
    _installed[package.id] = package;
    restart(package.id);
    _changed();
  }

  /// Takes plugin [id] out of the app, its file and its switch with it; what it kept
  /// ([AppSettings.pluginSettings]) stays, for when it is added again.
  void remove(String id) {
    if (!_installed.containsKey(id)) return;
    _stop(id);
    _installed.remove(id);
    if (_files.remove(id) case final path?) {
      try {
        File(path).deleteSync();
      } on FileSystemException catch (e) {
        debugPrint('Couldn’t delete the plugin $path: $e');
      }
    }
    settings.setPluginOn(id, false);
    clearProblems(id);
    _changed();
  }

  /// An id for a plugin named [name] that there is none with yet: "user.my-plugin".
  String idFor(String name) {
    final slug = PluginRuntime.idOf(name);
    final base = 'user.${slug.isEmpty ? 'plugin' : slug}';
    for (var n = 1;; n++) {
      final id = n == 1 ? base : '$base-$n';
      if (package(id) == null) return id;
    }
  }

  // MARK: Running

  PluginWindow? _window;
  bool _started = false;
  final _runtimes = <String, PluginRuntime>{};
  final _timers = <String, Set<Timer>>{};

  /// The window plugins act on, from now.
  void attach(PluginWindow window) => _window = window;

  void detach(PluginWindow window) {
    if (identical(_window, window)) _window = null;
  }

  /// Starts the plugins that are on: once the app's window is up, so one may show something
  /// as it starts.
  void start() {
    if (_started) return;
    _started = true;
    _sync();
    _changed();
    emit('app.started');
  }

  /// The plugins running, in the order they are listed.
  List<PluginRuntime> get running => [
        for (final p in packages)
          ?_runtimes[p.id],
      ];

  PluginRuntime? runtime(String id) => _runtimes[id];

  /// Starts plugin [id] again, as it now is, when it is on.
  void restart(String id) {
    _stop(id);
    clearProblems(id);
    _sync();
    _changed();
  }

  void _sync() {
    if (!_started) return;
    for (final id in _runtimes.keys.toList()) {
      if (package(id) == null || !isOn(id)) _stop(id);
    }
    for (final p in packages) {
      if (!isOn(p.id) || _runtimes.containsKey(p.id)) continue;
      if (p.api > PluginApi.level) {
        if (problemOf(p.id) == null) _report(ScriptProblem(p.id, 'It needs a newer Curator.', file: 'plugin.json'));
        continue;
      }
      // Its main.lua runs here: what it adds is the app's from its first line (_install).
      PluginRuntime(p, _Host(this, p));
    }
  }

  void _stop(String id) {
    _runtimes.remove(id);
    for (final timer in _timers.remove(id) ?? const <Timer>{}) {
      timer.cancel();
    }
  }

  @override
  void dispose() {
    settings.removeListener(_changed);
    for (final id in _runtimes.keys.toList()) {
      _stop(id);
    }
    problems.dispose();
    log.dispose();
    super.dispose();
  }

  /// What went wrong in plugins, the newest last, and the lines they printed.
  final problems = ValueNotifier<List<ScriptProblem>>(const []);
  final log = ValueNotifier<List<String>>(const []);

  /// What is wrong with plugin [id] now: the last thing that went wrong in it.
  ScriptProblem? problemOf(String id) => problems.value.where((p) => p.extension == id && !p.warning).lastOrNull;

  void clearProblems(String id) {
    if (problems.value.any((p) => p.extension == id)) _later(() => problems.value = [for (final p in problems.value) if (p.extension != id) p]);
  }

  /// Runs [change] now, or once the frame being built is, when one is: what listens to it
  /// can't be told while widgets are built (a menu asking a plugin whether a command is on).
  void _later(VoidCallback change) {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => change());
    } else {
      change();
    }
  }

  void _report(ScriptProblem problem) {
    _later(() {
      final all = [...problems.value, problem];
      problems.value = all.length > 200 ? all.sublist(all.length - 200) : all;
      // Said where the user is, too: a command that failed would otherwise do nothing.
      if (!problem.warning) _window?.message('${package(problem.extension)?.name ?? problem.extension}: ${problem.message}');
    });
  }

  void _print(String id, String line) {
    _later(() {
      final all = [...log.value, line];
      log.value = all.length > 500 ? all.sublist(all.length - 500) : all;
    });
  }

  bool _notifying = false;

  /// What plugins add or change is other than it was: the listeners are told, once for
  /// changes made together, and never while widgets are built.
  void _changed() {
    _revision++;
    if (_notifying) return;
    _notifying = true;
    _later(() {
      _notifying = false;
      notifyListeners();
    });
  }

  int _revision = 0;

  // MARK: What they add

  /// Every command plugins added, but those one has hidden.
  List<PluginEntry> get commands => [
        for (final runtime in running)
          for (final command in runtime.commands)
            if (!hides(command.id)) (runtime: runtime, command: command),
      ];

  /// The command a plugin added that goes by [name] (its id or its title).
  PluginEntry? entry(String name) {
    for (final runtime in _runtimes.values) {
      if (runtime.command(name) case final command?) return (runtime: runtime, command: command);
    }
    return null;
  }

  /// [entry]'s name as it is shown: the one a plugin gave it, else its own, translated.
  String titleOf(PluginEntry entry) => titleFor(entry.command.id) ?? entry.runtime.translate(entry.command.title);

  /// The commands plugins added that are buttons, or items of the score's menu: those [where] picks.
  List<PluginEntry> commandsWhere(bool Function(PluginCommand command) where) => [
        for (final entry in commands)
          if (where(entry.command)) entry,
      ];

  static final _icons = AppIcon.values.asNameMap();

  /// [entry]'s icon: the one of the app's it names, else the plugins' own.
  static IconData iconOf(BuildContext context, PluginEntry entry) => (_icons[entry.command.icon] ?? AppIcon.plugins).of(context);

  /// [entry]'s name with its key, as a button's tip has them: "Loop Playback (⌘L)".
  String tipOf(PluginEntry entry, KeyMap keys) => switch (chords(keys)[entry.command.id]) {
        final key? => '${titleOf(entry)} (${key.label})',
        null => titleOf(entry),
      };

  /// What choosing [entry] does, given [args]; null while it can't be chosen.
  VoidCallback? actionOf(PluginEntry entry, [List<Object?> args = const []]) => entry.runtime.canRun(entry.command, args) ? () => perform(entry, args) : null;

  /// Does [entry], given [args] (Lua values), if it can be chosen now. What its plugin says of
  /// its commands (ticked, to be chosen) may be other than it was, so they are asked again.
  void perform(PluginEntry entry, [List<Object?> args = const []]) {
    if (!identical(_runtimes[entry.runtime.id], entry.runtime) || !entry.runtime.canRun(entry.command, args)) return;
    entry.runtime.perform(entry.command, args);
    _changed();
  }

  /// Does one of the app's own commands ([action], by its [id]) from a button, as plugins
  /// have it where [context] is: [invoke], or [action] itself outside the app (a test of one
  /// widget).
  static void doOwn(BuildContext context, String id, VoidCallback action) => switch (PluginScope.read(context)) {
        final plugins? => plugins.invoke(id, action),
        null => action(),
      };

  /// Whether plugin [id] has settings of its own to show (it listens to `settings`).
  bool hasSettings(String id) => _runtimes[id]?.listens('settings') ?? false;

  /// Settings… in plugin [id]'s menu: it shows its own.
  void showSettings(String id) => _runtimes[id]?.emit('settings');

  /// Tells every plugin listening that [event] happened ([PluginApi.events]). One that makes
  /// it happen again as it is told (a tab shown from `project.shown`) is not told of that.
  void emit(String event, [List<Object?> args = const []]) {
    if (!_telling.add(event)) return;
    var told = false;
    try {
      for (final runtime in running) {
        if (!runtime.listens(event)) continue;
        runtime.emit(event, args);
        told = true;
      }
    } finally {
      _telling.remove(event);
    }
    // What a plugin told says of its commands may be other than it was.
    if (told) _changed();
  }

  final _telling = <String>{};

  /// [project] as a plugin is told of one; nil for none.
  static LuaTable? projectTable(PluginProject? project) =>
      project == null ? null : LuaTable.map({'name': project.name, if (project.path != null) 'path': project.path, 'edited': project.edited});

  // MARK: What they change

  /// Whether a plugin took command [id] (one of the app's, or a plugin's) out of its menu.
  bool hides(String id) => _runtimes.values.any((r) => r.hidden.contains(id));

  /// The name a plugin gave command [id], translated as that plugin's; null: none did.
  String? titleFor(String id) {
    for (final runtime in running.reversed) {
      if (runtime.titles[id] case final title?) return runtime.translate(title);
    }
    return null;
  }

  /// Does one of the app's own commands ([original], by its [id]): what a plugin put around
  /// it, given [original] to call, when one did (the last to wrap it outermost). One wrapped
  /// that runs itself again (`app.run`) does the app's.
  void invoke(String id, VoidCallback original) {
    final around = [
      for (final runtime in running)
        if (runtime.wraps[id] case final fn?) (runtime, fn),
    ];
    if (around.isEmpty || !_inside.add(id)) return original();
    try {
      var next = original;
      for (final (runtime, fn) in around) {
        final inner = next;
        next = () => runtime.call(fn, where: id, args: [
              LuaBuiltin('original', (_) {
                inner();
                return const [];
              }),
            ]);
      }
      next();
    } finally {
      _inside.remove(id);
    }
  }

  final _inside = <String>{};

  /// [original] (the app's command [id]) as plugins have it: [invoke], while one wraps it.
  /// One that can't be chosen now (null) stays so.
  VoidCallback? wrapped(String id, VoidCallback? original) =>
      original == null || !_runtimes.values.any((r) => r.wraps.containsKey(id)) ? original : () => invoke(id, original);

  /// Does the command [name] names, the app's or a plugin's (`app.run`): false when it can't
  /// be chosen now; null when there is none.
  bool? run(String name, [List<Object?> args = const []]) {
    if (PluginApi.command(name) case final own?) {
      final action = _window?.commands[own.id];
      if (action == null) return false;
      invoke(own.id, action);
      return true;
    }
    final found = entry(name);
    if (found == null) return null;
    if (!found.runtime.canRun(found.command, args)) return false;
    found.runtime.perform(found.command, args);
    _changed();
    return true;
  }

  // MARK: Keys

  static final _keyNames = <String, LogicalKeyboardKey>{
    'space': LogicalKeyboardKey.space,
    'enter': LogicalKeyboardKey.enter,
    'tab': LogicalKeyboardKey.tab,
    'escape': LogicalKeyboardKey.escape,
    'backspace': LogicalKeyboardKey.backspace,
    'delete': LogicalKeyboardKey.delete,
    'left': LogicalKeyboardKey.arrowLeft,
    'right': LogicalKeyboardKey.arrowRight,
    'up': LogicalKeyboardKey.arrowUp,
    'down': LogicalKeyboardKey.arrowDown,
    'home': LogicalKeyboardKey.home,
    'end': LogicalKeyboardKey.end,
    'pageup': LogicalKeyboardKey.pageUp,
    'pagedown': LogicalKeyboardKey.pageDown,
    'f1': LogicalKeyboardKey.f1,
    'f2': LogicalKeyboardKey.f2,
    'f3': LogicalKeyboardKey.f3,
    'f4': LogicalKeyboardKey.f4,
    'f5': LogicalKeyboardKey.f5,
    'f6': LogicalKeyboardKey.f6,
    'f7': LogicalKeyboardKey.f7,
    'f8': LogicalKeyboardKey.f8,
    'f9': LogicalKeyboardKey.f9,
    'f10': LogicalKeyboardKey.f10,
    'f11': LogicalKeyboardKey.f11,
    'f12': LogicalKeyboardKey.f12,
  };

  /// [key], as a plugin wrote it, as the app takes keys.
  static KeyChord chordOf(PluginKey key) {
    final code = key.key.codeUnitAt(0);
    final logical = _keyNames[key.key] ?? LogicalKeyboardKey.findKeyByKeyId(code) ?? LogicalKeyboardKey(code);
    return KeyChord(logical, command: key.command, control: key.control, alt: key.alt, shift: key.shift);
  }

  final _warned = <String>{};

  void _warn(PluginRuntime runtime, String message) {
    if (_warned.add('${runtime.id}\u0000$message')) _report(ScriptProblem(runtime.id, message, warning: true));
  }

  /// [keys] (the user's, Settings ▸ Shortcuts) with the keys plugins gave the app's commands
  /// (`app.rebind`): only where the user chose none, and never a key another command has.
  KeyMap keysOver(KeyMap keys) {
    var out = keys;
    final commands = KeyCommand.values.asNameMap();
    for (final runtime in running) {
      for (final MapEntry(key: id, value: key) in runtime.keys.entries) {
        final command = commands[id];
        if (command == null || !command.editable || keys.isChanged(command)) continue;
        final chord = key == null ? null : chordOf(key);
        if (chord != null) {
          if (command.refuses(chord) != null) {
            _warn(runtime, '${command.label} is in a menu: its key needs cmd or ctrl ($key).');
            continue;
          }
          if (out.takenBy(command, chord) case final other?) {
            _warn(runtime, '$key is ${other.label}’s key: ${command.label} keeps its own.');
            continue;
          }
        }
        out = out.withKey(command, chord);
      }
    }
    return out;
  }

  (int, KeyMap)? _chordsFor;
  Map<String, KeyChord> _chords = const {};

  /// The key of each command plugins added that has one, by the command's id, where [keys] are
  /// the app's commands' ([keysOver]): the one its plugin gave it, or another gave it since
  /// (`app.rebind`); none where one of the app's commands, or a plugin's before it, has that key.
  Map<String, KeyChord> chords(KeyMap keys) {
    if (_chordsFor == (_revision, keys)) return _chords;
    final out = <String, KeyChord>{}, taken = <KeyChord, String>{};
    for (final (:runtime, :command) in commands) {
      var key = command.key;
      for (final other in running) {
        if (other.keys.containsKey(command.id)) key = other.keys[command.id];
      }
      if (key == null) continue;
      final chord = chordOf(key);
      if (keys.holderOf(chord) case final own?) {
        _warn(runtime, '$key is ${own.label}’s key: ${command.title} has none.');
      } else if (taken[chord] case final other?) {
        _warn(runtime, '$key is $other’s key: ${command.title} has none.');
      } else {
        out[command.id] = chord;
        taken[chord] = command.title;
      }
    }
    _chordsFor = (_revision, keys);
    return _chords = out;
  }

  // MARK: What the app gives Lua

  void _install(PluginRuntime runtime) {
    final id = runtime.id;
    _runtimes[id] = runtime;
    BuildContext window(String fn) => _window?.dialogContext ?? (throw LuaError("'$fn' needs the app’s window, and it isn’t up"));
    EditorController editor(String fn) => _window?.controller ?? (throw LuaError("'$fn' needs a project, and none shows"));

    final app = runtime.library('app', {
      'run': (a) {
        final name = a.string(0, 'app.run');
        return [run(name, a.skip(1).toList()) ?? (throw LuaError("bad argument #1 to 'app.run' (there is no command '$name')"))];
      },
      'commands': (a) {
        final keys = keysOver(settings.keys), own = _window?.commands ?? const {}, plugins = chords(keys);
        final all = KeyCommand.values.asNameMap();
        return [
          LuaTable.list([
            for (final c in PluginApi.commands)
              LuaTable.map({
                'id': c.id,
                'title': c.title,
                if (c.menu != null) 'menu': c.menu,
                if (all[c.id] case final command?)
                  if (keys[command] case final key?) 'key': key.label,
                'enabled': own[c.id] != null,
              }),
            for (final e in commands)
              LuaTable.map({
                'id': e.command.id,
                'title': e.command.title,
                if (e.command.menu.isNotEmpty) 'menu': e.command.menu.join('/'),
                if (plugins[e.command.id] case final key?) 'key': key.label,
                'enabled': e.runtime.canRun(e.command),
                'plugin': e.runtime.id,
              }),
          ]),
        ];
      },
      'setting': (a) {
        final name = a.string(0, 'app.setting');
        final setting = _settings[name] ?? (throw LuaError("bad argument #1 to 'app.setting' (there is no setting '$name')"));
        if (a.length > 1) {
          if (!setting.set(settings, a[1])) throw LuaError("bad argument #2 to 'app.setting' ($name is ${PluginApi.setting(name)!.values})");
        }
        return [setting.get(settings)];
      },
      'recent': (a) => [LuaTable.list(settings.recentFiles)],
      'open': (a) {
        final path = a.string(0, 'app.open');
        (_window ?? (throw LuaError("'app.open' needs the app’s window, and it isn’t up"))).open(path);
        return const [];
      },
      'tabs': (a) {
        final window = _window;
        return [
          LuaTable.list([
            if (window != null)
              for (final (i, p) in window.projects.indexed)
                LuaTable.map({'name': p.name, if (p.path != null) 'path': p.path, 'edited': p.edited, 'showing': i == window.showing}),
          ]),
        ];
      },
      'show_tab': (a) {
        final index = a.integer(0, 'app.show_tab'), window = _window;
        if (window == null || index < 0 || index > window.projects.length) throw LuaError("bad argument #1 to 'app.show_tab' (there is no tab $index)");
        window.showTab(index == 0 ? null : index - 1);
        return const [];
      },
      'after': (a) {
        final seconds = a.number(0, 'app.after').toDouble(), fn = a.function(1, 'app.after');
        if (!(seconds >= 0 && seconds <= 86400)) throw LuaError("bad argument #1 to 'app.after' (0 to 86400 seconds expected)");
        final timers = _timers[id] ??= {};
        if (timers.length >= 64) throw LuaError("'app.after': a plugin waits for 64 at most");
        late final Timer timer;
        timer = Timer(Duration(microseconds: (seconds * 1e6).round()), () {
          timers.remove(timer);
          if (identical(_runtimes[id], runtime)) runtime.call(fn, where: 'app.after');
        });
        timers.add(timer);
        return [
          LuaBuiltin('cancel', (_) {
            timer.cancel();
            timers.remove(timer);
            return const [];
          }),
        ];
      },
      'copy': (a) {
        unawaited(Clipboard.setData(ClipboardData(text: a.string(0, 'app.copy'))));
        return const [];
      },
    });
    app['version'] = appVersion;
    app['build'] = appBuild;
    app['platform'] = switch (defaultTargetPlatform) { TargetPlatform.macOS => 'macos', TargetPlatform.windows => 'windows', _ => 'linux' };

    runtime.library('project', {
      'open': (a) => [_window?.project != null],
      'name': (a) => [_window?.project?.name],
      'path': (a) => [_window?.project?.path],
      'edited': (a) => [_window?.project?.edited ?? false],
      'playing': (a) => [_window?.controller?.playback.isPlaying ?? false],
      'play': (a) {
        editor('project.play').playback.play();
        return const [];
      },
      'pause': (a) {
        editor('project.pause').playback.pause();
        return const [];
      },
      'time': (a) => [editor('project.time').playback.time.value],
      'seek': (a) {
        editor('project.seek').playback.seek(a.number(0, 'project.seek').toDouble());
        return const [];
      },
      'duration': (a) => [editor('project.duration').playback.duration],
    });

    runtime.library('ui', {
      'form': (a) {
        showExtensionForm(window('ui.form'), runtime, a.table(0, 'ui.form'));
        return const [];
      },
      'message': (a) {
        final text = a.string(0, 'ui.message');
        (_window ?? (throw LuaError("'ui.message' needs the app’s window, and it isn’t up"))).message(text);
        return const [];
      },
      'ask': (a) {
        showExtensionAsk(window('ui.ask'), runtime, a.table(0, 'ui.ask'));
        return const [];
      },
      'sheet': (a) {
        final handle = SheetHandle();
        showExtensionSheet(window('ui.sheet'), runtime, a.table(0, 'ui.sheet'), handle);
        return [handle.table];
      },
      'open_file': (a) {
        openExtensionFile(runtime, a.table(0, 'ui.open_file'));
        return const [];
      },
      'save_file': (a) {
        saveExtensionFile(window('ui.save_file'), runtime, a.table(0, 'ui.save_file'));
        return const [];
      },
    });
  }

  /// The app's settings a plugin reads and sets (`app.setting`, [PluginApi.settings]): each
  /// given as Lua has it, and set from a Lua value (false: not one it can be).
  static final _settings = <String, ({Object? Function(AppSettings) get, bool Function(AppSettings, Object?) set})>{
    'theme': (
      get: (s) => s.themeMode.name,
      set: (s, v) => _choose(ThemeMode.values.asNameMap()[v], (ThemeMode mode) => s.themeMode = mode),
    ),
    'accent': (
      get: (s) => '#${(s.accent.color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
      set: (s, v) => _choose(luaColor(v), (Color color) => s.accent = AccentColor.custom(color)),
    ),
    'style': (
      get: (s) => s.uiStyle.name,
      set: (s, v) => _choose(UiStyle.values.asNameMap()[v], (UiStyle style) => s.uiStyle = style),
    ),
    'text_size': (
      get: (s) => s.textSize.name,
      set: (s, v) => _choose(TextSize.values.asNameMap()[v], (TextSize size) => s.textSize = size),
    ),
    'density': (
      get: (s) => s.density.name,
      set: (s, v) => _choose(UiDensity.values.asNameMap()[v], (UiDensity density) => s.density = density),
    ),
    'reduce_motion': (
      get: (s) => s.reduceMotion,
      set: (s, v) => _choose(v is bool ? v : null, (bool on) => s.reduceMotion = on),
    ),
    'language': (
      get: (s) => s.language.name,
      set: (s, v) => _choose(
          v is String ? AppLanguage.values.where((l) => l.name == AppLanguage.named(v).name).firstOrNull : null, (AppLanguage language) => s.language = language),
    ),
    'tab_bar': (
      get: (s) => s.tabBar,
      set: (s, v) => _choose(v is bool ? v : null, (bool on) => s.tabBar = on),
    ),
  };

  static bool _choose<T>(T? value, void Function(T) set) {
    if (value == null) return false;
    set(value);
    return true;
  }
}

/// What a running plugin stands on: the app, through [Plugins].
class _Host extends PluginHost {
  _Host(this._plugins, this._package);
  final Plugins _plugins;
  final PluginPackage _package;

  EditorController? get _editor => _plugins._window?.controller;

  @override
  Object? get settings => _plugins.settings.pluginSettings(_package.id);
  @override
  void saveSettings(Object? json) => _plugins.settings.setPluginSettings(_package.id, json);
  @override
  LoadedScore? get score => _editor?.score;
  @override
  ScoreTimeline? get timeline => _editor?.score == null ? null : _editor!.timeline;
  @override
  BeatGrid? get beats => _editor?.score?.beats;
  @override
  String get language => Strings.language.locale.toLanguageTag();
  // Curator's own plugins' texts are the app's, translated with it.
  @override
  String? translate(String text) => _plugins.isOwn(_package.id) ? Strings.tableOf(Strings.language)[text] : null;
  @override
  void report(ScriptProblem problem) => _plugins._report(problem);
  @override
  void print(String extension, String line) => _plugins._print(extension, line);
  @override
  void changed() => _plugins._changed();
  @override
  bool hasCommand(String name) => _plugins.entry(name) != null;
  @override
  void install(PluginRuntime runtime) => _plugins._install(runtime);
}

/// Gives the widgets under it the app's plugins ([of]); they are built again when what
/// plugins add or change is other than it was. The app puts one over its window.
class PluginScope extends InheritedNotifier<Plugins> {
  const PluginScope({super.key, required Plugins plugins, required super.child}) : super(notifier: plugins);

  /// The app's plugins where [context] is; null outside one (a test of one widget).
  static Plugins? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PluginScope>()?.notifier;

  /// The same, without being built again when they change.
  static Plugins? read(BuildContext context) => context.getInheritedWidgetOfExactType<PluginScope>()?.notifier;
}
