import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app_colors.dart';
import 'file_names.dart';
import 'key_bindings.dart';
import 'l10n/l10n.dart';
import 'plugins/plugins.dart';

/// The MIDI menu as it is now ([AppMenus.midi]): what is on ([velocity]: louder notes darker;
/// [sharedRange]: every row's height the same span of pitches; [fileTempo]: it plays by its
/// file's own tempo map), and what each item does, null (greyed out) when it can't (a row at
/// its tallest, the file's tempo followed already).
typedef MidiMenu = ({
  bool velocity,
  bool sharedRange,
  bool fileTempo,
  VoidCallback? onVelocity,
  VoidCallback? onSharedRange,
  VoidCallback? onTallerRows,
  VoidCallback? onShorterRows,
  VoidCallback? onWiderBeats,
  VoidCallback? onNarrowerBeats,
  VoidCallback? onFileTempo,
});

/// The menu bar: native on macOS, a Material menu bar at the top of the window elsewhere.
/// Both are built from the same [PlatformMenu] description.
class AppMenus extends StatelessWidget {
  const AppMenus({
    super.key,
    this.keys = KeyMap.standard,
    required this.onOpen,
    required this.onImport,
    this.onNewLilyPond,
    required this.onSave,
    required this.onSaveAs,
    required this.onSettings,
    required this.child,
    this.onAbout,
    this.recentFiles = const [],
    this.onOpenRecent,
    this.onClearRecent,
    this.onProjectSettings,
    this.onExportVideo,
    this.onExportWeb,
    this.onClose,
    this.onUndo,
    this.onRedo,
    this.onCut,
    this.onCopy,
    this.onPaste,
    this.onDelete,
    this.onSelectAll,
    this.onFindPhrase,
    this.previewShown = true,
    this.timelineShown = true,
    this.onShowPreview,
    this.onShowTimeline,
    this.onMaximizePreview,
    this.playerMapShown = false,
    this.onShowPlayerMap,
    this.onMaximizeTimeline,
    this.onNextTab,
    this.onPreviousTab,
    this.tabBarShown = true,
    this.onShowTabBar,
    this.midi,
    this.plugins,
    this.free = true,
    this.typing = false,
  });

  /// The app's plugins: what they add to the menus and change in them; null: none (a test).
  final Plugins? plugins;

  /// Whether no dialog is over the window, and whether a text field has the keyboard: what
  /// plugins added is off under a dialog, and a key of theirs without ⌘ or ⌃ while typing.
  final bool free, typing;

  /// The keys of the items the user can give others (Settings ▸ Shortcuts).
  final KeyMap keys;

  /// Open…: a project, or a score to start one from.
  final VoidCallback? onOpen;

  /// Import…: a PDF or LilyPond score to start a project from.
  final VoidCallback? onImport;

  /// New LilyPond Score…: a score written in the LilyPond editor, as a new project.
  final VoidCallback? onNewLilyPond;
  final VoidCallback? onSave;
  final VoidCallback? onSaveAs;
  final VoidCallback? onSettings;
  final Widget child;

  /// About Curator: the app menu on macOS (in place of the standard panel), Help elsewhere.
  final VoidCallback? onAbout;

  /// File ▸ Open Recent, most recent first.
  final List<String> recentFiles;
  final ValueChanged<String>? onOpenRecent;
  final VoidCallback? onClearRecent;

  /// File ▸ Close: closes the project showing, its tab with it; null (greyed out) on Home.
  final VoidCallback? onClose;

  /// Edit ▸ Project Settings… (⇧⌘,); null (greyed out) while nothing is open.
  final VoidCallback? onProjectSettings;

  /// File ▸ Export Video…; null (greyed out) while nothing is open.
  final VoidCallback? onExportVideo;

  /// File ▸ Export to Web…; null (greyed out) while nothing is open.
  final VoidCallback? onExportWeb;

  /// Edit menu; each null (greyed out) when it has nothing to do.
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback? onCut;
  final VoidCallback? onCopy;
  final VoidCallback? onPaste;
  final VoidCallback? onDelete;
  final VoidCallback? onSelectAll;

  /// Edit ▸ Find Phrase… (⌘F); null (greyed out) while nothing is open.
  final VoidCallback? onFindPhrase;

  /// View ▸ Hide / Show Preview and Timeline: the editor's upper and lower parts, each given
  /// whether to show it; null (greyed out) while nothing is open.
  final bool previewShown, timelineShown;
  final ValueChanged<bool>? onShowPreview, onShowTimeline;

  /// View ▸ Show Player Map / Show Score (Show MIDI View for a MIDI project): the project's map
  /// in the score's place (the toolbar's switch); null while nothing is open.
  final bool playerMapShown;
  final ValueChanged<bool>? onShowPlayerMap;

  /// View ▸ Maximize Preview / Timeline: the other at its smallest; null while nothing is open.
  final VoidCallback? onMaximizePreview, onMaximizeTimeline;

  /// Show Next / Previous Tab (⌃Tab, ⌃⇧Tab), Home among them: Window on macOS, View elsewhere;
  /// null while no project is open.
  final VoidCallback? onNextTab, onPreviousTab;

  /// View ▸ Show / Hide Tab Bar (⇧⌘T), given whether to show it; Show All Tabs (⇧⌘\) shows it,
  /// and is greyed out while it shows.
  final bool tabBarShown;
  final ValueChanged<bool>? onShowTabBar;

  /// The MIDI menu, for a MIDI project (its notes drawn in rows, nothing engraved); null, and no
  /// such menu, while another project or none shows.
  final MidiMenu? midi;

  static bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

  /// ⌘ on macOS, Ctrl elsewhere.
  static SingleActivator _key(LogicalKeyboardKey key, {bool shift = false}) =>
      SingleActivator(key, meta: _mac, control: !_mac, shift: shift);

  /// [command]'s key as set, if it has one.
  SingleActivator? _keyOf(KeyCommand command) => keys[command]?.activator;

  /// One of the app's own items, by its command's id ([PluginApi.commands]), as plugins have
  /// it: gone when one hid it, named as one renamed it, doing what one put around it.
  PlatformMenuItem? _own(String id, String label, {MenuSerializableShortcut? shortcut, VoidCallback? onSelected}) {
    final plugins = this.plugins;
    if (plugins == null) return _MenuItem(id, label: label, shortcut: shortcut, onSelected: onSelected);
    if (plugins.hides(id)) return null;
    return _MenuItem(id, label: plugins.titleFor(id) ?? label, shortcut: shortcut, onSelected: plugins.wrapped(id, onSelected));
  }

  /// [title] as an item that is on or off: ticked while [on] (a plugin's `checked` likewise).
  static String _ticked(String title, bool on) => on ? '✓ $title' : title;

  PlatformMenuItemGroup get _tabs => PlatformMenuItemGroup(members: [
        ?_own('previousTab', 'Show Previous Tab'.tr, shortcut: _keyOf(KeyCommand.previousTab), onSelected: onPreviousTab),
        ?_own('nextTab', 'Show Next Tab'.tr, shortcut: _keyOf(KeyCommand.nextTab), onSelected: onNextTab),
      ]);

  /// The menus as they are now: the app's own, as plugins changed them, with what plugins added.
  @visibleForTesting
  List<PlatformMenuItem> get menus => _withPlugins(_menus);

  List<PlatformMenuItem> get _menus => [
        if (_mac)
          _Menu('Curator', label: 'Curator', menus: [
            PlatformMenuItemGroup(members: [
              ?_own('about', 'About Curator'.tr, onSelected: onAbout),
            ]),
            PlatformMenuItemGroup(members: [
              ?_own('settings', 'Settings…'.tr, shortcut: _key(LogicalKeyboardKey.comma), onSelected: onSettings),
            ]),
            const PlatformMenuItemGroup(members: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu),
            ]),
            const PlatformMenuItemGroup(members: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
            ]),
            const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
          ]),
        _Menu('File', label: 'File'.tr, menus: [
          PlatformMenuItemGroup(members: [
            ?_own('newLilyPond', 'New LilyPond Score…'.tr, shortcut: _keyOf(KeyCommand.newLilyPond), onSelected: onNewLilyPond),
            ?_own('open', 'Open…'.tr, shortcut: _keyOf(KeyCommand.open), onSelected: onOpen),
            ?_own('importScore', 'Import…'.tr, shortcut: _keyOf(KeyCommand.importScore), onSelected: onImport),
            PlatformMenu(label: 'Open Recent'.tr, menus: [
              if (recentFiles.isEmpty)
                PlatformMenuItem(label: 'No Recent Files'.tr) // no handler: greyed out
              else
                PlatformMenuItemGroup(members: [
                  for (final path in recentFiles)
                    PlatformMenuItem(label: fileNameOf(path), onSelected: onOpenRecent == null ? null : () => onOpenRecent!(path)),
                ]),
              PlatformMenuItem(label: 'Clear Menu'.tr, onSelected: recentFiles.isEmpty ? null : onClearRecent),
            ]),
          ]),
          PlatformMenuItemGroup(members: [
            ?_own('close', 'Close'.tr, shortcut: _keyOf(KeyCommand.close), onSelected: onClose),
            ?_own('save', 'Save'.tr, shortcut: _keyOf(KeyCommand.save), onSelected: onSave),
            ?_own('saveAs', 'Save As…'.tr, shortcut: _keyOf(KeyCommand.saveAs), onSelected: onSaveAs),
          ]),
          PlatformMenuItemGroup(members: [
            ?_own('exportVideo', 'Export Video…'.tr, shortcut: _keyOf(KeyCommand.exportVideo), onSelected: onExportVideo),
            ?_own('exportWeb', 'Export to Web…'.tr, shortcut: _keyOf(KeyCommand.exportWeb), onSelected: onExportWeb),
          ]),
        ]),
        _Menu('Edit', label: 'Edit'.tr, menus: [
          PlatformMenuItemGroup(members: [
            ?_own('undo', 'Undo'.tr, shortcut: _key(LogicalKeyboardKey.keyZ), onSelected: onUndo),
            ?_own(
              'redo',
              'Redo'.tr,
              shortcut: _mac
                  ? _key(LogicalKeyboardKey.keyZ, shift: true)
                  : const SingleActivator(LogicalKeyboardKey.keyY, control: true),
              onSelected: onRedo,
            ),
          ]),
          PlatformMenuItemGroup(members: [
            ?_own('cut', 'Cut'.tr, shortcut: _key(LogicalKeyboardKey.keyX), onSelected: onCut),
            ?_own('copy', 'Copy'.tr, shortcut: _key(LogicalKeyboardKey.keyC), onSelected: onCopy),
            ?_own('paste', 'Paste'.tr, shortcut: _key(LogicalKeyboardKey.keyV), onSelected: onPaste),
            ?_own(
              'delete',
              'Delete'.tr,
              shortcut: SingleActivator(_mac ? LogicalKeyboardKey.backspace : LogicalKeyboardKey.delete),
              onSelected: onDelete,
            ),
            ?_own('selectAll', 'Select All'.tr, shortcut: _key(LogicalKeyboardKey.keyA), onSelected: onSelectAll),
          ]),
          PlatformMenuItemGroup(members: [
            ?_own('findPhrase', 'Find Phrase…'.tr, shortcut: _keyOf(KeyCommand.findPhrase), onSelected: onFindPhrase),
          ]),
          // The open project's settings, then the app's; on macOS the Curator menu has the
          // app's too, with the shortcut.
          PlatformMenuItemGroup(members: [
            ?_own('projectSettings', 'Project Settings…'.tr, shortcut: _keyOf(KeyCommand.projectSettings), onSelected: onProjectSettings),
            ?_own('settings', 'Settings…'.tr, shortcut: _mac ? null : _key(LogicalKeyboardKey.comma), onSelected: onSettings),
          ]),
        ]),
        _Menu('View', label: 'View'.tr, menus: [
          PlatformMenuItemGroup(members: [
            ?_own(
              'showPreview',
              previewShown ? 'Hide Preview'.tr : 'Show Preview'.tr,
              shortcut: _keyOf(KeyCommand.showPreview),
              onSelected: onShowPreview == null ? null : () => onShowPreview!(!previewShown),
            ),
            ?_own(
              'showTimeline',
              timelineShown ? 'Hide Timeline'.tr : 'Show Timeline'.tr,
              shortcut: _keyOf(KeyCommand.showTimeline),
              onSelected: onShowTimeline == null ? null : () => onShowTimeline!(!timelineShown),
            ),
          ]),
          PlatformMenuItemGroup(members: [
            ?_own('maximizePreview', 'Maximize Preview'.tr, shortcut: _keyOf(KeyCommand.maximizePreview), onSelected: onMaximizePreview),
            ?_own('maximizeTimeline', 'Maximize Timeline'.tr, shortcut: _keyOf(KeyCommand.maximizeTimeline), onSelected: onMaximizeTimeline),
          ]),
          PlatformMenuItemGroup(members: [
            ?_own(
              'showPlayerMap',
              playerMapShown ? (midi == null ? 'Show Score'.tr : 'Show MIDI View'.tr) : 'Show Player Map'.tr,
              shortcut: _keyOf(KeyCommand.showPlayerMap),
              onSelected: onShowPlayerMap == null ? null : () => onShowPlayerMap!(!playerMapShown),
            ),
          ]),
          PlatformMenuItemGroup(members: [
            ?_own(
              'showTabBar',
              tabBarShown ? 'Hide Tab Bar'.tr : 'Show Tab Bar'.tr,
              shortcut: _keyOf(KeyCommand.showTabBar),
              onSelected: onShowTabBar == null ? null : () => onShowTabBar!(!tabBarShown),
            ),
            ?_own(
              'showAllTabs',
              'Show All Tabs'.tr,
              shortcut: _keyOf(KeyCommand.showAllTabs),
              onSelected: onShowTabBar == null || tabBarShown ? null : () => onShowTabBar!(true),
            ),
          ]),
          if (!_mac) _tabs,
        ]),
        if (midi case final midi?)
          _Menu('MIDI', label: 'MIDI'.tr, menus: [
            PlatformMenuItemGroup(members: [
              ?_own('midiVelocity', _ticked('Shade Notes by Velocity'.tr, midi.velocity),
                  shortcut: _keyOf(KeyCommand.midiVelocity), onSelected: midi.onVelocity),
              ?_own('midiSharedRange', _ticked('Shared Pitch Range'.tr, midi.sharedRange),
                  shortcut: _keyOf(KeyCommand.midiSharedRange), onSelected: midi.onSharedRange),
            ]),
            PlatformMenuItemGroup(members: [
              ?_own('midiTallerRows', 'Taller Rows'.tr, shortcut: _keyOf(KeyCommand.midiTallerRows), onSelected: midi.onTallerRows),
              ?_own('midiShorterRows', 'Shorter Rows'.tr, shortcut: _keyOf(KeyCommand.midiShorterRows), onSelected: midi.onShorterRows),
              ?_own('midiWiderBeats', 'Wider Beats'.tr, shortcut: _keyOf(KeyCommand.midiWiderBeats), onSelected: midi.onWiderBeats),
              ?_own('midiNarrowerBeats', 'Narrower Beats'.tr,
                  shortcut: _keyOf(KeyCommand.midiNarrowerBeats), onSelected: midi.onNarrowerBeats),
            ]),
            PlatformMenuItemGroup(members: [
              ?_own('midiFileTempo', _ticked('Use File’s Tempo'.tr, midi.fileTempo),
                  shortcut: _keyOf(KeyCommand.midiFileTempo), onSelected: midi.onFileTempo),
            ]),
          ]),
        if (_mac)
          _Menu('Window', label: 'Window'.tr, menus: [
            PlatformMenuItemGroup(members: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
            ]),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
            _tabs,
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.arrangeWindowsInFront),
          ]),
        if (!_mac)
          _Menu('Help', label: 'Help'.tr, menus: [
            ?_own('about', 'About Curator'.tr, onSelected: onAbout),
          ]),
      ];

  // MARK: What plugins add

  /// Whether a menu can show [key] and take it: one that holds ⌘ or ⌃, or a function key (a
  /// letter alone would be taken from what is typed). Another key works in the window instead.
  static bool _menuKey(KeyChord key) => KeyCommand.open.refuses(key) == null;

  /// [top], the app's own menus, with the commands plugins added: each in the menu it names
  /// (one the app hasn't got is a new menu, before Window and Help), beside the item it names
  /// or at the menu's end, in a menu inside it when it names one. A group left empty (its
  /// items hidden) goes.
  List<PlatformMenuItem> _withPlugins(List<PlatformMenuItem> top) {
    final plugins = this.plugins;
    if (plugins == null) return top;
    final chords = plugins.chords(keys);
    final names = {for (final m in top.whereType<_Menu>()) m.name.toLowerCase(): m.name};
    final added = <String, List<PluginEntry>>{};
    for (final entry in plugins.commands) {
      if (entry.command.menu.isEmpty) continue;
      final menu = entry.command.menu.first;
      (added[names[menu.toLowerCase()] ?? menu] ??= []).add(entry);
    }
    final out = <PlatformMenuItem>[
      for (final menu in top)
        if (menu is _Menu) _Menu(menu.name, label: menu.label, menus: _insert(_tidy(menu.menus), added.remove(menu.name) ?? const [], chords)) else menu,
    ];
    final end = out.indexWhere((m) => m is _Menu && (m.name == 'Window' || m.name == 'Help'));
    out.insertAll(end < 0 ? out.length : end, [
      for (final MapEntry(key: name, value: entries) in added.entries)
        PlatformMenu(label: entries.first.runtime.translate(name), menus: _insert(const [], entries, chords)),
    ]);
    return out;
  }

  static List<PlatformMenuItem> _tidy(List<PlatformMenuItem> items) => [
        for (final item in items)
          if (item is! PlatformMenuItemGroup || item.members.isNotEmpty) item,
      ];

  /// [items] with [entries] (commands of this menu, [depth] menus down) put in.
  List<PlatformMenuItem> _insert(List<PlatformMenuItem> items, List<PluginEntry> entries, Map<String, KeyChord> chords, [int depth = 1]) {
    if (entries.isEmpty) return items;
    var out = items;
    final rest = <PlatformMenuItem>[], inside = <String, List<PluginEntry>>{};
    for (final entry in entries) {
      final command = entry.command;
      if (command.menu.length > depth) {
        (inside[command.menu[depth]] ??= []).add(entry);
        continue;
      }
      final item = _added(entry, chords), beside = command.before ?? command.after;
      final placed = beside == null ? null : _beside(out, beside, item, after: command.before == null);
      if (placed == null) {
        rest.add(item);
      } else {
        out = placed;
      }
    }
    for (final MapEntry(key: name, value: entries) in inside.entries) {
      rest.add(PlatformMenu(label: entries.first.runtime.translate(name), menus: _insert(const [], entries, chords, depth + 1)));
    }
    return [...out, if (out.isEmpty) ...rest else if (rest.isNotEmpty) PlatformMenuItemGroup(members: rest)];
  }

  /// [items] with [item] before or after the one whose command is [id], in its group; null
  /// when none of them is.
  static List<PlatformMenuItem>? _beside(List<PlatformMenuItem> items, String id, PlatformMenuItem item, {required bool after}) {
    for (final (i, each) in items.indexed) {
      if (each is _MenuItem && each.id == id) return [...items.take(after ? i + 1 : i), item, ...items.skip(after ? i + 1 : i)];
      if (each is PlatformMenuItemGroup) {
        final members = _beside(each.members, id, item, after: after);
        if (members != null) return [...items.take(i), PlatformMenuItemGroup(members: members), ...items.skip(i + 1)];
      }
    }
    return null;
  }

  /// A command a plugin added, as a menu's item: ticked while its `checked` says so, greyed
  /// out while its `enabled` says no, or under a dialog.
  PlatformMenuItem _added(PluginEntry entry, Map<String, KeyChord> chords) {
    final plugins = this.plugins!, title = plugins.titleOf(entry), key = chords[entry.command.id];
    return _MenuItem(
      entry.command.id,
      label: _ticked(title, entry.runtime.isChecked(entry.command)),
      shortcut: key != null && _menuKey(key) ? key.activator : null,
      onSelected: free && entry.runtime.canRun(entry.command) ? () => plugins.perform(entry) : null,
    );
  }

  /// The keys of plugins' commands that no menu takes: those of commands in no menu, and a
  /// key without ⌘ or ⌃ (not while typing). The window takes them, while no dialog is up.
  Map<ShortcutActivator, VoidCallback> get _windowKeys {
    final plugins = this.plugins;
    if (plugins == null || !free) return const {};
    final chords = plugins.chords(keys);
    return {
      for (final entry in plugins.commands)
        if (chords[entry.command.id] case final key?)
          if (_menuKey(key) ? entry.command.menu.isEmpty : !typing) key.activator: () => plugins.perform(entry),
    };
  }

  @override
  Widget build(BuildContext context) {
    final menus = this.menus, windowKeys = _windowKeys;
    // Always around the window, with or without keys: the window under it keeps its place in
    // the tree (and so its state) as plugins come and go.
    if (_mac) return PlatformMenuBar(menus: menus, child: CallbackShortcuts(bindings: windowKeys, child: child));
    // Elsewhere the menu bar only shows the shortcuts; these make them work.
    return CallbackShortcuts(
      bindings: {for (final (key, action) in _shortcuts(menus)) key: action, ...windowKeys},
      child: Column(children: [
        DecoratedBox(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
          child: Row(children: [
            Expanded(
              child: MenuBar(
                style: MenuStyle(
                  backgroundColor: WidgetStatePropertyAll(
                      Theme.of(context).extension<AppColors>()?.chrome ?? Theme.of(context).colorScheme.surface),
                  elevation: const WidgetStatePropertyAll(0),
                  shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
                  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6)),
                ),
                // The bar's own buttons keep their height; the theme's 22 px rows are its menus'.
                children: _material(menus, bar: _barButton),
              ),
            ),
          ]),
        ),
        Expanded(child: child),
      ]),
    );
  }

  static Iterable<(SingleActivator, VoidCallback)> _shortcuts(List<PlatformMenuItem> items) sync* {
    for (final item in items) {
      switch (item) {
        case PlatformMenu(:final menus) || PlatformMenuItemGroup(members: final menus):
          yield* _shortcuts(menus);
        case PlatformMenuItem(:final SingleActivator shortcut, onSelected: final VoidCallback action):
          yield (shortcut, action);
        default:
      }
    }
  }

  static const _barButton = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(0, 26)),
    visualDensity: VisualDensity.compact,
  );

  /// [items] as material menus; [bar], the style of the top level's buttons (a menu bar's).
  static List<Widget> _material(List<PlatformMenuItem> items, {ButtonStyle? bar}) => [
        for (final (i, item) in items.indexed)
          ...switch (item) {
            PlatformMenu(:final label, :final menus) => [
                SubmenuButton(style: bar, menuChildren: _material(menus), child: Text(label)),
              ],
            PlatformMenuItemGroup(:final members) => [if (i > 0) const Divider(height: 1), ..._material(members)],
            PlatformProvidedMenuItem() => const <Widget>[],
            _ => [
                MenuItemButton(
                  onPressed: item.onSelected,
                  shortcut: item.shortcut as SingleActivator?,
                  child: Text(item.label),
                ),
              ],
          },
      ];
}

/// One of the app's menus, by its name in English: what a plugin's command names to be in it.
class _Menu extends PlatformMenu {
  _Menu(this.name, {required super.label, required super.menus});
  final String name;
}

/// A menu's item that is a command, by the command's id: one of the app's own
/// ([PluginApi.commands]) or one a plugin added, which another can sit beside.
class _MenuItem extends PlatformMenuItem {
  const _MenuItem(this.id, {required super.label, super.shortcut, super.onSelected});
  final String id;
}
