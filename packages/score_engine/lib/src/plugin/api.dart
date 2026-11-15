/// The plugin API as a list: every function a plugin's Lua can call, every event it can
/// listen to, every command of the app it can run or change, every setting it can read and
/// set. The one place it is written down: the runtime answers `curator.has` from it, the plugin
/// editor's reference and what it offers as code is typed are made from it, and so is
/// docs/plugin-api.md (app/tool/plugin_docs.dart).
///
/// It only grows, as the extension API does ([ExtensionApi]): nothing listed is taken away or
/// made to mean something else. What is added says the level it came with; a plugin says the
/// level it needs (`"api"` in plugin.json) and may ask for more with `curator.has`.
library;

import '../extension/api.dart';

/// A command of the app's own: something its menus or its keys do, which a plugin can run,
/// hide, rename, give another key or wrap.
class ApiCommand {
  const ApiCommand(this.id, this.title, this.menu, {this.rebind = true, this.since = 1});

  /// What a plugin calls it by: "exportVideo".
  final String id;

  /// Its name in English, as its menu has it ("Export Video…"): a plugin may call it by this too.
  final String title;

  /// The menu it is in ("File"); null: none, a key of the editor's.
  final String? menu;

  /// Whether its key can be changed (`app.rebind`): those the user can change in Settings ▸
  /// Shortcuts.
  final bool rebind;
  final int since;
}

/// Something that happens in the app, which a plugin can listen to (`app.on`).
class ApiEvent {
  const ApiEvent(this.name, this.signature, this.summary, {this.since = 1});
  final String name;

  /// The function it takes, as it would be written: "function(project)".
  final String signature;
  final String summary;
  final int since;
}

/// A setting of the app's a plugin can read and set (`app.setting`).
class ApiSetting {
  const ApiSetting(this.name, this.values, this.summary, {this.since = 1});
  final String name;

  /// What it may be, as written in Lua.
  final String values;
  final String summary;
  final int since;
}

abstract final class PluginApi {
  /// This build's API level.
  static const level = 1;

  /// A command's name as plugins write one: three dots for an ellipsis, spaces at its ends gone.
  static String named(String name) => name.trim().replaceAll('...', '…');

  /// The app's command [name] names, by its id or its title in English; null: it has none.
  static ApiCommand? command(String name) {
    final wanted = named(name);
    for (final c in commands) {
      if (c.id == wanted || c.title == wanted) return c;
    }
    return null;
  }

  static ApiEvent? event(String name) => events.where((e) => e.name == name).firstOrNull;
  static ApiSetting? setting(String name) => settings.where((s) => s.name == name).firstOrNull;

  /// Whether this Curator has [name]: a function ("app.command"), a library ("project"), an
  /// event ("event:project.opened"), a command ("command:exportVideo") or a setting
  /// ("setting:theme").
  static bool has(String name) {
    if (name.startsWith('event:')) return event(name.substring(6)) != null;
    if (name.startsWith('command:')) return command(name.substring(8)) != null;
    if (name.startsWith('setting:')) return setting(name.substring(8)) != null;
    return libraries.any((l) => l.name == name || l.functions.any((f) => f.name == name) || l.values.any((v) => '${l.name}.${v.$1}' == name));
  }

  /// The menus the app has, by the name a command's `menu` gives: any other name is a new menu.
  static const menus = ['File', 'Edit', 'View', 'Window', 'Help'];

  /// The icons a command's `icon` may name (the app's own, by name).
  static const icons = ExtensionApi.icons;

  /// What a key is written with: what is held, then the key, joined by "+".
  static const modifiers = ['cmd', 'ctrl', 'alt', 'shift'];

  /// The keys that have names: the rest are written as they are typed ("k", "7", ",").
  static const keyNames = [
    'space', 'enter', 'tab', 'escape', 'backspace', 'delete', 'left', 'right', 'up', 'down', 'home', 'end', 'pageup', 'pagedown', //
    'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8', 'f9', 'f10', 'f11', 'f12',
  ];

  static const commands = <ApiCommand>[
    ApiCommand('about', 'About Curator', 'Curator', rebind: false),
    ApiCommand('settings', 'Settings…', 'Edit', rebind: false),
    ApiCommand('newLilyPond', 'New LilyPond Score…', 'File'),
    ApiCommand('open', 'Open…', 'File'),
    ApiCommand('importScore', 'Import…', 'File'),
    ApiCommand('close', 'Close', 'File'),
    ApiCommand('save', 'Save', 'File'),
    ApiCommand('saveAs', 'Save As…', 'File'),
    ApiCommand('exportVideo', 'Export Video…', 'File'),
    ApiCommand('exportWeb', 'Export to Web…', 'File'),
    ApiCommand('undo', 'Undo', 'Edit', rebind: false),
    ApiCommand('redo', 'Redo', 'Edit', rebind: false),
    ApiCommand('cut', 'Cut', 'Edit', rebind: false),
    ApiCommand('copy', 'Copy', 'Edit', rebind: false),
    ApiCommand('paste', 'Paste', 'Edit', rebind: false),
    ApiCommand('delete', 'Delete', 'Edit', rebind: false),
    ApiCommand('selectAll', 'Select All', 'Edit', rebind: false),
    ApiCommand('findPhrase', 'Find Phrase…', 'Edit'),
    ApiCommand('projectSettings', 'Project Settings…', 'Edit'),
    ApiCommand('showPreview', 'Hide / Show Preview', 'View'),
    ApiCommand('showTimeline', 'Hide / Show Timeline', 'View'),
    ApiCommand('maximizePreview', 'Maximize Preview', 'View'),
    ApiCommand('maximizeTimeline', 'Maximize Timeline', 'View'),
    ApiCommand('showPlayerMap', 'Hide / Show Player Map', 'View'),
    ApiCommand('showTabBar', 'Hide / Show Tab Bar', 'View'),
    ApiCommand('showAllTabs', 'Show All Tabs', 'View'),
    ApiCommand('previousTab', 'Show Previous Tab', 'Window'),
    ApiCommand('nextTab', 'Show Next Tab', 'Window'),
    // The editor's keys, in no menu.
    ApiCommand('playPause', 'Play / Pause', null, rebind: false),
    ApiCommand('goToStart', 'Go to start', null),
    ApiCommand('goToEnd', 'Go to end', null),
    ApiCommand('goTo', 'Go to bar or time', null),
    ApiCommand('metronome', 'Metronome', null),
    ApiCommand('tapAnchors', 'Tap anchors', null),
    ApiCommand('warp', 'Warp', null),
    ApiCommand('selectTool', 'Select', null),
    ApiCommand('drawTool', 'Draw', null),
    ApiCommand('eraseTool', 'Erase', null),
    ApiCommand('trimStart', 'Start at the playhead', null),
    ApiCommand('trimEnd', 'End at the playhead', null),
    ApiCommand('deselect', 'Deselect', null, rebind: false),
  ];

  static const events = <ApiEvent>[
    ApiEvent('app.started', 'function()', 'Curator has started and its window is up. Told once, to the plugins on as it starts: one turned on later isn’t told.'),
    ApiEvent('project.opened', 'function(project)', 'A project has opened in a tab. project: {name, path, edited} (no path until it is saved).'),
    ApiEvent('project.saved', 'function(project)', 'The project was saved (Save, Save As…).'),
    ApiEvent('project.closed', 'function(project)', 'A project’s tab was closed.'),
    ApiEvent('project.shown', 'function(project)', 'Another tab shows: its project, or nil for Home.'),
    ApiEvent('playback.started', 'function()', 'The project showing started playing.'),
    ApiEvent('playback.stopped', 'function()', 'It stopped.'),
    ApiEvent('settings', 'function()',
        'Settings… was chosen in the plugin’s menu in Settings ▸ Plugins, which has it while the plugin listens: show them (ui.form) and keep them (curator.save_settings).'),
  ];

  static const settings = <ApiSetting>[
    ApiSetting('theme', '"light", "dark" or "system"', 'Light or dark.'),
    ApiSetting('accent', '"#rrggbb"', 'The accent colour.'),
    ApiSetting('style', '"refined" or "carbon"', 'The interface’s style.'),
    ApiSetting('text_size', '"small", "medium" or "large"', 'The interface’s text size.'),
    ApiSetting('density', '"compact", "standard" or "roomy"', 'How close the controls are set.'),
    ApiSetting('reduce_motion', 'true or false', 'Whether the interface moves less.'),
    ApiSetting('language', 'a locale ("en", "zh-Hans") or "system"', 'The interface’s language.'),
    ApiSetting('tab_bar', 'true or false', 'Whether the tab bar shows.'),
  ];

  /// What a plugin's Lua has beyond Lua 5.4's own libraries: its own, then those an extension
  /// has too (`score`, `text`, `math`, `ui`), as [ExtensionApi] lists them.
  static final libraries = <ApiLibrary>[
    const ApiLibrary('curator', 'The plugin itself: its settings, its texts.', [
      ApiFunction('curator.settings', 'curator.settings() → table', 'What the plugin keeps, for every project (a copy).'),
      ApiFunction('curator.save_settings', 'curator.save_settings(table)', 'Keeps table as the plugin’s settings.'),
      ApiFunction('curator.tr', 'curator.tr(text, values) → text',
          'text in the interface’s language, from locales/<language>.json; each {name} in it is replaced by values.name.',
          example: 'curator.tr("{n} bars", {n = 3})'),
      ApiFunction('curator.tr_in', 'curator.tr_in(context, text, values) → text',
          'curator.tr for a text that means two things: its translation in a context ("context|text" in locales/<language>.json), else as curator.tr gives it.'),
      ApiFunction('curator.has', 'curator.has(name) → boolean',
          'Whether this Curator has a function ("app.after"), a library ("project"), an event ("event:project.saved"), a command ("command:exportWeb") or a setting ("setting:theme"): for using something newer than the level the plugin asks for.'),
      ApiFunction('curator.log', 'curator.log(...)', 'Writes a line to the plugin editor’s log. print does the same.'),
      ApiFunction('curator.list', 'curator.list(table) → table', 'Marks a table as a list, so that it is saved as [] while it is empty. A new table already is.'),
      ApiFunction('curator.map', 'curator.map(table) → table', 'Marks a table as a map, so that it is saved as {} while it is empty.'),
      ApiFunction('curator.asset', 'curator.asset(path) → text', 'A file of the plugin’s assets folder as text; nil when there is none.'),
    ], values: [
      ('api', 'This Curator’s plugin API level (a number).'),
      ('id', 'The plugin’s id.'),
      ('name', 'The plugin’s name.'),
      ('version', 'The plugin’s version, as plugin.json says it.'),
      ('language', 'The interface’s language ("en", "zh-Hans").'),
      ('null', 'JSON’s null where nil can’t stand: a value in a saved list.'),
    ]),
    const ApiLibrary('app', 'The app: its commands, menus, keys and toolbar, what happens in it, its settings and tabs.', [
      ApiFunction('app.command', 'app.command(spec) → id',
          'Adds a command: something the user can do. spec: title (its name, in English: translated from locales/), run (what it does), id (what it is called by; from its title when left out), menu (the menu it is in: "File", "Edit", "View", "Window", "Help", or any other name for a new menu; "View/Zoom" for a menu inside one), before or after (a command of that menu it sits beside; else at the menu’s end), key (its key: "cmd+shift+k"), toolbar (true: a button on the editor’s toolbar), home (true: a button on Home), preview (true: an item of the menu a right-click on the score opens; run is then given the place clicked, in quarters), icon (a button’s icon), enabled (a function: whether it can be chosen now) and checked (a function: whether it is ticked). Adding one with the id of one the plugin has replaces it.',
          example:
              'app.command{\n  title = "Count Bars",\n  menu = "View",\n  key = "cmd+shift+b",\n  enabled = function() return score.open() end,\n  run = function()\n    ui.message(curator.tr("{n} bars", {n = #score.bars()}))\n  end,\n}'),
      ApiFunction('app.remove', 'app.remove(id)', 'Takes out a command the plugin added.'),
      ApiFunction('app.refresh', 'app.refresh()',
          'Has every command asked again whether it can be chosen and is ticked (enabled, checked): after something they hang on changed in a timer or a dialog’s answer. A command that ran and an event that was told do it by themselves.'),
      ApiFunction('app.run', 'app.run(name, ...) → boolean',
          'Does a command, the app’s own or a plugin’s, by its id ("exportVideo") or its title ("Export Video..."): as its menu item or its key would. false when it can’t be chosen now.',
          example: 'app.run("save")'),
      ApiFunction('app.commands', 'app.commands() → list',
          'Every command there is, the app’s then the plugins’: {id, title, menu, key, enabled, plugin (the id of the plugin that added it)}.'),
      ApiFunction('app.hide', 'app.hide(name)', 'Takes a command out of its menu and off its key, until app.show. app.run still does it.'),
      ApiFunction('app.show', 'app.show(name)', 'Puts a hidden command back.'),
      ApiFunction('app.rename', 'app.rename(name, title)', 'Gives a command another name in its menu; nil: its own again.'),
      ApiFunction('app.rebind', 'app.rebind(name, key)',
          'Gives a command another key ("cmd+alt+s"); nil: none. A key the user chose in Settings ▸ Shortcuts stays theirs. Only for the commands the user can change there, and plugins’ own.'),
      ApiFunction('app.wrap', 'app.wrap(name, fn)',
          'Puts fn around one of the app’s commands: fn(original, ...) is called in its place, however it is chosen, and calls original() to do what the app does, or doesn’t. nil takes it off.',
          example: 'app.wrap("exportVideo", function(original)\n  app.run("save")\n  original()\nend)'),
      ApiFunction('app.on', 'app.on(event, fn) → off',
          'Calls fn when something happens in the app (see Events). off() stops it.',
          example: 'app.on("project.opened", function(project)\n  print("Opened " .. project.name)\nend)'),
      ApiFunction('app.setting', 'app.setting(name, value) → value',
          'One of the app’s settings (see Settings): with a value, sets it; gives it as it then is.',
          example: 'app.setting("theme", "dark")'),
      ApiFunction('app.recent', 'app.recent() → list', 'The files of File ▸ Open Recent, as paths, the latest first.'),
      ApiFunction('app.open', 'app.open(path)', 'Opens a project or a score in a tab, or shows the tab it is open in.'),
      ApiFunction('app.tabs', 'app.tabs() → list', 'The projects open, in the tabs’ order: {name, path, edited, showing}.'),
      ApiFunction('app.show_tab', 'app.show_tab(index)', 'Shows a tab: 0 is Home, 1 the first project.'),
      ApiFunction('app.after', 'app.after(seconds, fn) → cancel', 'Calls fn once, seconds from now. cancel() stops it first.'),
      ApiFunction('app.copy', 'app.copy(text)', 'Puts text on the clipboard.'),
    ], values: [
      ('version', 'Curator’s version ("0.9.0").'),
      ('build', 'Its build (a number).'),
      ('platform', '"macos", "windows" or "linux".'),
    ]),
    const ApiLibrary('project', 'The project showing: its file and its playback. The score library reads its score.', [
      ApiFunction('project.open', 'project.open() → boolean', 'Whether a project shows (false on Home). The rest need one.'),
      ApiFunction('project.name', 'project.name() → text', 'Its name, as its tab has it.'),
      ApiFunction('project.path', 'project.path() → text', 'Its file; nil until it is saved.'),
      ApiFunction('project.edited', 'project.edited() → boolean', 'Whether it has changes not saved.'),
      ApiFunction('project.playing', 'project.playing() → boolean', 'Whether it is playing.'),
      ApiFunction('project.play', 'project.play()', 'Plays from the playhead.'),
      ApiFunction('project.pause', 'project.pause()', 'Stops playing.'),
      ApiFunction('project.time', 'project.time() → seconds', 'Where the playhead is.'),
      ApiFunction('project.seek', 'project.seek(seconds)', 'Moves the playhead.'),
      ApiFunction('project.duration', 'project.duration() → seconds', 'How long it plays.'),
    ]),
    for (final l in ExtensionApi.libraries)
      if (const {'score', 'text', 'math', 'ui'}.contains(l.name))
        ApiLibrary(
          l.name,
          switch (l.name) {
            'score' => 'The score of the project showing, and the performance it is synced to. Places are in quarter notes from the start of the score; times in seconds.',
            'ui' => 'Dialogs, laid out as the app’s own.',
            _ => l.summary,
          },
          [for (final f in l.functions) if (!f.editor) f],
          values: l.values,
          addsTo: l.addsTo,
        ),
  ];

  /// The docs whole, as Markdown: the [guide] to writing a plugin, then the [reference].
  static String docs(String guide) => '${guide.trimRight()}\n\n# Reference\n\nAPI level $level.\n\n${reference()}';

  /// The API as JSON, for a program (or a model) to read: what [reference] says, as data.
  static Map<String, Object?> toJson() => {
        'level': level,
        'commands': [
          for (final c in commands) {'id': c.id, 'title': c.title, 'menu': c.menu, 'rebind': c.rebind, 'since': c.since},
        ],
        'events': [
          for (final e in events) {'name': e.name, 'signature': e.signature, 'summary': e.summary, 'since': e.since},
        ],
        'settings': [
          for (final s in settings) {'name': s.name, 'values': s.values, 'summary': s.summary, 'since': s.since},
        ],
        'menus': menus,
        'keys': {'modifiers': modifiers, 'names': keyNames},
        'icons': icons,
        'libraries': [
          for (final l in libraries)
            {
              'name': l.name,
              'summary': l.summary,
              'functions': [
                for (final f in l.functions) {'name': f.name, 'signature': f.signature, 'summary': f.summary, 'since': f.since, if (f.example != null) 'example': f.example},
              ],
              if (l.values.isNotEmpty) 'values': [for (final (name, summary) in l.values) {'name': name, 'summary': summary}],
            },
        ],
      };

  /// The whole API as Markdown: every library with its functions, every event, every command
  /// and setting of the app's. docs/plugin-api.md is the guide followed by this.
  static String reference() {
    final out = StringBuffer('## Libraries\n');
    String since(int level) => level > 1 ? ' *(API $level)*' : '';
    for (final l in libraries) {
      out.writeln('\n### `${l.name}`\n\n${l.summary}\n');
      for (final f in l.functions) {
        out.writeln('- `${f.signature}`${since(f.since)}: ${f.summary}');
        if (f.example case final example?) out.writeln('\n  ```lua\n${example.split('\n').map((line) => '  $line').join('\n')}\n  ```\n');
      }
      for (final (name, summary) in l.values) {
        out.writeln('- `${l.name}.$name`: $summary');
      }
    }
    out.writeln('\n## Events\n\nWhat `app.on` listens to:\n');
    for (final e in events) {
      out.writeln('- `"${e.name}"`, `${e.signature}`${since(e.since)}: ${e.summary}');
    }
    out.writeln('\n## Commands\n\nThe app’s own, by the id `app.run`, `app.hide`, `app.rename`, `app.rebind` and `app.wrap` take (its title does too). '
        'Those marked * keep their key.\n');
    String? menu = '';
    for (final c in commands) {
      if (c.menu != menu) {
        menu = c.menu;
        out.writeln('\n${menu ?? 'The editor’s keys, in no menu'}:\n');
      }
      out.writeln('- `${c.id}`${c.rebind ? '' : ' *'}${since(c.since)}: ${c.title}');
    }
    out.writeln('\n## Settings\n\nWhat `app.setting` reads and sets:\n');
    for (final s in settings) {
      out.writeln('- `${s.name}` (${s.values})${since(s.since)}: ${s.summary}');
    }
    out.writeln('\n## Keys\n\nA key is what is held, then the key, joined by `+`: `"cmd+shift+k"`. '
        'Held: ${modifiers.map((m) => '`$m`').join(', ')} (`cmd` is ⌘ on a Mac and Ctrl elsewhere). '
        'A key is written as it is typed (`k`, `7`, `,`), or by name: ${keyNames.map((k) => '`$k`').join(', ')}.');
    out.writeln('\nIcons: ${icons.map((i) => '`$i`').join(', ')}.');
    return out.toString();
  }
}
