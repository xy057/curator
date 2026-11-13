import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app_colors.dart';
import 'file_names.dart';
import 'key_bindings.dart';
import 'l10n/l10n.dart';

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
    this.onMaximizeTimeline,
    this.onNextTab,
    this.onPreviousTab,
    this.tabBarShown = true,
    this.onShowTabBar,
  });

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

  /// View ▸ Maximize Preview / Timeline: the other at its smallest; null while nothing is open.
  final VoidCallback? onMaximizePreview, onMaximizeTimeline;

  /// Show Next / Previous Tab (⌃Tab, ⌃⇧Tab), Home among them: Window on macOS, View elsewhere;
  /// null while no project is open.
  final VoidCallback? onNextTab, onPreviousTab;

  /// View ▸ Show / Hide Tab Bar (⇧⌘T), given whether to show it; Show All Tabs (⇧⌘\) shows it,
  /// and is greyed out while it shows.
  final bool tabBarShown;
  final ValueChanged<bool>? onShowTabBar;

  static bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

  /// ⌘ on macOS, Ctrl elsewhere.
  static SingleActivator _key(LogicalKeyboardKey key, {bool shift = false}) =>
      SingleActivator(key, meta: _mac, control: !_mac, shift: shift);

  /// [command]'s key as set, if it has one.
  SingleActivator? _keyOf(KeyCommand command) => keys[command]?.activator;

  PlatformMenuItemGroup get _tabs => PlatformMenuItemGroup(members: [
        PlatformMenuItem(label: 'Show Previous Tab'.tr, shortcut: _keyOf(KeyCommand.previousTab), onSelected: onPreviousTab),
        PlatformMenuItem(label: 'Show Next Tab'.tr, shortcut: _keyOf(KeyCommand.nextTab), onSelected: onNextTab),
      ]);

  List<PlatformMenuItem> get _menus => [
        if (_mac)
          PlatformMenu(label: 'Curator', menus: [
            PlatformMenuItemGroup(members: [
              PlatformMenuItem(label: 'About Curator'.tr, onSelected: onAbout),
            ]),
            PlatformMenuItemGroup(members: [
              PlatformMenuItem(label: 'Settings…'.tr, shortcut: _key(LogicalKeyboardKey.comma), onSelected: onSettings),
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
        PlatformMenu(label: 'File'.tr, menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'New LilyPond Score…'.tr, shortcut: _keyOf(KeyCommand.newLilyPond), onSelected: onNewLilyPond),
            PlatformMenuItem(label: 'Open…'.tr, shortcut: _keyOf(KeyCommand.open), onSelected: onOpen),
            PlatformMenuItem(label: 'Import…'.tr, shortcut: _keyOf(KeyCommand.importScore), onSelected: onImport),
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
            PlatformMenuItem(label: 'Close'.tr, shortcut: _keyOf(KeyCommand.close), onSelected: onClose),
            PlatformMenuItem(label: 'Save'.tr, shortcut: _keyOf(KeyCommand.save), onSelected: onSave),
            PlatformMenuItem(label: 'Save As…'.tr, shortcut: _keyOf(KeyCommand.saveAs), onSelected: onSaveAs),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Export Video…'.tr, shortcut: _keyOf(KeyCommand.exportVideo), onSelected: onExportVideo),
            PlatformMenuItem(label: 'Export to Web…'.tr, shortcut: _keyOf(KeyCommand.exportWeb), onSelected: onExportWeb),
          ]),
        ]),
        PlatformMenu(label: 'Edit'.tr, menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Undo'.tr, shortcut: _key(LogicalKeyboardKey.keyZ), onSelected: onUndo),
            PlatformMenuItem(
              label: 'Redo'.tr,
              shortcut: _mac
                  ? _key(LogicalKeyboardKey.keyZ, shift: true)
                  : const SingleActivator(LogicalKeyboardKey.keyY, control: true),
              onSelected: onRedo,
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Cut'.tr, shortcut: _key(LogicalKeyboardKey.keyX), onSelected: onCut),
            PlatformMenuItem(label: 'Copy'.tr, shortcut: _key(LogicalKeyboardKey.keyC), onSelected: onCopy),
            PlatformMenuItem(label: 'Paste'.tr, shortcut: _key(LogicalKeyboardKey.keyV), onSelected: onPaste),
            PlatformMenuItem(
              label: 'Delete'.tr,
              shortcut: SingleActivator(_mac ? LogicalKeyboardKey.backspace : LogicalKeyboardKey.delete),
              onSelected: onDelete,
            ),
            PlatformMenuItem(label: 'Select All'.tr, shortcut: _key(LogicalKeyboardKey.keyA), onSelected: onSelectAll),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Find Phrase…'.tr, shortcut: _keyOf(KeyCommand.findPhrase), onSelected: onFindPhrase),
          ]),
          // The open project's settings, then the app's; on macOS the Curator menu has the
          // app's too, with the shortcut.
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
                label: 'Project Settings…'.tr,
                shortcut: _keyOf(KeyCommand.projectSettings),
                onSelected: onProjectSettings),
            PlatformMenuItem(label: 'Settings…'.tr, shortcut: _mac ? null : _key(LogicalKeyboardKey.comma), onSelected: onSettings),
          ]),
        ]),
        PlatformMenu(label: 'View'.tr, menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: previewShown ? 'Hide Preview'.tr : 'Show Preview'.tr,
              shortcut: _keyOf(KeyCommand.showPreview),
              onSelected: onShowPreview == null ? null : () => onShowPreview!(!previewShown),
            ),
            PlatformMenuItem(
              label: timelineShown ? 'Hide Timeline'.tr : 'Show Timeline'.tr,
              shortcut: _keyOf(KeyCommand.showTimeline),
              onSelected: onShowTimeline == null ? null : () => onShowTimeline!(!timelineShown),
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Maximize Preview'.tr, shortcut: _keyOf(KeyCommand.maximizePreview), onSelected: onMaximizePreview),
            PlatformMenuItem(label: 'Maximize Timeline'.tr, shortcut: _keyOf(KeyCommand.maximizeTimeline), onSelected: onMaximizeTimeline),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: tabBarShown ? 'Hide Tab Bar'.tr : 'Show Tab Bar'.tr,
              shortcut: _keyOf(KeyCommand.showTabBar),
              onSelected: onShowTabBar == null ? null : () => onShowTabBar!(!tabBarShown),
            ),
            PlatformMenuItem(
              label: 'Show All Tabs'.tr,
              shortcut: _keyOf(KeyCommand.showAllTabs),
              onSelected: onShowTabBar == null || tabBarShown ? null : () => onShowTabBar!(true),
            ),
          ]),
          if (!_mac) _tabs,
        ]),
        if (_mac)
          PlatformMenu(label: 'Window'.tr, menus: [
            PlatformMenuItemGroup(members: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
            ]),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
            _tabs,
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.arrangeWindowsInFront),
          ]),
        if (!_mac)
          PlatformMenu(label: 'Help'.tr, menus: [
            PlatformMenuItem(label: 'About Curator'.tr, onSelected: onAbout),
          ]),
      ];

  @override
  Widget build(BuildContext context) {
    final menus = _menus;
    if (_mac) return PlatformMenuBar(menus: menus, child: child);
    // Elsewhere the menu bar only shows the shortcuts; these make them work.
    return CallbackShortcuts(
      bindings: {for (final (key, action) in _shortcuts(menus)) key: action},
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
