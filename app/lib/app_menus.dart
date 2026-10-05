import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The menu bar: native on macOS, a Material menu bar at the top of the window elsewhere.
/// Both are built from the same [PlatformMenu] description.
class AppMenus extends StatelessWidget {
  const AppMenus({
    super.key,
    required this.onOpen,
    required this.onSave,
    required this.onSaveAs,
    required this.onSettings,
    required this.child,
    this.recentFiles = const [],
    this.onOpenRecent,
    this.onClearRecent,
    this.onEditTexts,
    this.onCondensing,
    this.onFonts,
    this.onAddRecording,
    this.onExportVideo,
    this.onClose,
    this.onUndo,
    this.onRedo,
    this.onPaste,
    this.onDelete,
    this.onSelectAll,
  });

  /// Open…: a project, or a score to start one from.
  final VoidCallback? onOpen;
  final VoidCallback? onSave;
  final VoidCallback? onSaveAs;
  final VoidCallback? onSettings;
  final Widget child;

  /// File ▸ Open Recent, most recent first.
  final List<String> recentFiles;
  final ValueChanged<String>? onOpenRecent;
  final VoidCallback? onClearRecent;

  /// File ▸ Close: back to the start screen; null (greyed out) while nothing is open.
  final VoidCallback? onClose;

  /// Score menu; null (greyed out) while nothing is open.
  final VoidCallback? onEditTexts;
  final VoidCallback? onCondensing;
  final VoidCallback? onFonts;
  final VoidCallback? onAddRecording;

  /// File ▸ Export Video…; null (greyed out) while nothing is open.
  final VoidCallback? onExportVideo;

  /// Edit menu; each null (greyed out) when it has nothing to do.
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback? onPaste;
  final VoidCallback? onDelete;
  final VoidCallback? onSelectAll;

  static bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

  /// ⌘ on macOS, Ctrl elsewhere.
  static SingleActivator _key(LogicalKeyboardKey key, {bool shift = false}) =>
      SingleActivator(key, meta: _mac, control: !_mac, shift: shift);

  List<PlatformMenuItem> get _menus => [
        if (_mac)
          PlatformMenu(label: 'Curator', menus: [
            if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.about))
              const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
            PlatformMenuItemGroup(members: [
              PlatformMenuItem(label: 'Settings…', shortcut: _key(LogicalKeyboardKey.comma), onSelected: onSettings),
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
        PlatformMenu(label: 'File', menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Open…', shortcut: _key(LogicalKeyboardKey.keyO), onSelected: onOpen),
            PlatformMenu(label: 'Open Recent', menus: [
              if (recentFiles.isEmpty)
                const PlatformMenuItem(label: 'No Recent Files') // no handler: greyed out
              else
                PlatformMenuItemGroup(members: [
                  for (final path in recentFiles)
                    PlatformMenuItem(label: _basename(path), onSelected: onOpenRecent == null ? null : () => onOpenRecent!(path)),
                ]),
              PlatformMenuItem(label: 'Clear Menu', onSelected: recentFiles.isEmpty ? null : onClearRecent),
            ]),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Close', shortcut: _key(LogicalKeyboardKey.keyW), onSelected: onClose),
            PlatformMenuItem(label: 'Save', shortcut: _key(LogicalKeyboardKey.keyS), onSelected: onSave),
            PlatformMenuItem(label: 'Save As…', shortcut: _key(LogicalKeyboardKey.keyS, shift: true), onSelected: onSaveAs),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Export Video…', shortcut: _key(LogicalKeyboardKey.keyE), onSelected: onExportVideo),
          ]),
          if (!_mac)
            PlatformMenuItemGroup(members: [
              PlatformMenuItem(label: 'Settings…', shortcut: _key(LogicalKeyboardKey.comma), onSelected: onSettings),
            ]),
        ]),
        PlatformMenu(label: 'Edit', menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Undo', shortcut: _key(LogicalKeyboardKey.keyZ), onSelected: onUndo),
            PlatformMenuItem(
              label: 'Redo',
              shortcut: _mac
                  ? _key(LogicalKeyboardKey.keyZ, shift: true)
                  : const SingleActivator(LogicalKeyboardKey.keyY, control: true),
              onSelected: onRedo,
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Paste', shortcut: _key(LogicalKeyboardKey.keyV), onSelected: onPaste),
            PlatformMenuItem(
              label: 'Delete',
              shortcut: SingleActivator(_mac ? LogicalKeyboardKey.backspace : LogicalKeyboardKey.delete),
              onSelected: onDelete,
            ),
            PlatformMenuItem(label: 'Select All', shortcut: _key(LogicalKeyboardKey.keyA), onSelected: onSelectAll),
          ]),
        ]),
        PlatformMenu(label: 'Score', menus: [
          PlatformMenuItem(label: 'Edit Texts…', onSelected: onEditTexts),
          PlatformMenuItem(label: 'Condensing…', onSelected: onCondensing),
          PlatformMenuItem(label: 'Fonts…', onSelected: onFonts),
          PlatformMenuItem(label: 'Add Recording…', onSelected: onAddRecording),
        ]),
        if (_mac)
          const PlatformMenu(label: 'Window', menus: [
            PlatformMenuItemGroup(members: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
            ]),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.arrangeWindowsInFront),
          ]),
      ];

  static String _basename(String path) => path.split(RegExp(r'[/\\]')).last;

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
                  backgroundColor: WidgetStatePropertyAll(Theme.of(context).colorScheme.surface),
                  elevation: const WidgetStatePropertyAll(0),
                  shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
                  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6)),
                ),
                children: _material(menus),
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

  static List<Widget> _material(List<PlatformMenuItem> items) => [
        for (final (i, item) in items.indexed)
          ...switch (item) {
            PlatformMenu(:final label, :final menus) => [SubmenuButton(menuChildren: _material(menus), child: Text(label))],
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
