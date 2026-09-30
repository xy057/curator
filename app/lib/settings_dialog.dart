import 'dart:io';

import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_settings.dart';
import 'editor_controller.dart';
import 'engrave_options_dialog.dart';
import 'export_dialog.dart' show revealInFileManager;
import 'project_file.dart';
import 'ui_kit.dart';
import 'updater.dart';

/// Settings… (⌘,): categories on the left, each a page of items on the right.
///
/// Adding a setting is one [_Item] in [_categories]; adding a page is one [_Category]. The
/// search field filters items across every page. [page] (a category's label) opens that page.
Future<void> showSettingsDialog(
  BuildContext context,
  AppSettings settings, {
  EditorController? controller,
  Updater? updater,
  String? page,
}) =>
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close settings',
      barrierColor: Colors.black.withValues(alpha: 0.28),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, _, _) => _SettingsWindow(
        settings: settings,
        controller: controller,
        updater: updater ?? Updater(),
        page: page,
      ),
      transitionBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
        return FadeTransition(
          opacity: curved,
          alwaysIncludeSemantics: true, // see showAppDialog
          child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(curved), child: child),
        );
      },
    );

/// One setting: a title and help on the left, its control on the right.
class _Item {
  const _Item(this.title, this.help, this.control, {this.keywords = ''});
  final String title;

  /// One short line under the title; null when the control says it all.
  final String Function(_Context)? help;
  final Widget Function(_Context) control;
  final String keywords;
}

class _Category {
  const _Category(this.label, this.icon, this.items, {this.empty});
  final String label;
  final IconData icon;
  final List<_Item> items;

  /// Shown in place of the items while there are none.
  final String? empty;
}

typedef _Context = ({AppSettings settings, EditorController? controller, Updater updater});

final _categories = <_Category>[
  _Category('General', Icons.tune_rounded, [
    _Item(
      'Autosave',
      (_) => 'Saved projects only.',
      (c) => _Dropdown<Duration>(
        value: c.settings.autosave,
        values: AppSettings.autosaveChoices,
        label: _autosaveLabel,
        onChanged: (v) => c.settings.autosave = v,
      ),
      keywords: 'save interval',
    ),
    _Item(
      'Undo history',
      (_) => 'Every edit in a project: lanes, sync, names, texts.',
      (c) => _Dropdown<int>(
        value: c.settings.undoSteps,
        values: AppSettings.undoStepChoices,
        label: (n) => '$n steps',
        onChanged: (v) => c.settings.undoSteps = v,
      ),
      keywords: 'undo redo steps',
    ),
  ]),
  _Category('Appearance', Icons.palette_outlined, [
    _Item(
      'Theme',
      (_) => 'Dark also turns the score dark.',
      (c) => SegmentedButton<ThemeMode>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_outlined, size: 16), label: Text('Auto')),
          ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined, size: 16), label: Text('Light')),
          ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined, size: 16), label: Text('Dark')),
        ],
        selected: {c.settings.themeMode},
        onSelectionChanged: (s) => c.settings.themeMode = s.single,
      ),
      keywords: 'dark light mode colour color',
    ),
    _Item(
      'Accent colour',
      null,
      (c) => _AccentPicker(settings: c.settings),
      keywords: 'color colour scheme',
    ),
  ]),
  _Category('Animation', Icons.animation_rounded, [
    _Item(
      'Staff transition',
      (c) => c.controller?.curation == null
          ? 'Open a project to set how its staves glide in and out.'
          : 'How long a staff takes to glide in or out, in this project. Regions can have their own: select them and pick one in the Instruments tab, or double-click one.',
      (c) => _TransitionPicker(
        value: c.controller?.curation?.transition,
        onChanged: (s) => c.controller?.setTransition(s),
      ),
      keywords: 'fade duration enter leave project',
    ),
    _Item(
      'For new projects',
      (_) => 'What a newly imported score starts with.',
      (c) => _TransitionPicker(value: c.settings.transition, onChanged: (s) => c.settings.transition = s),
      keywords: 'fade duration enter leave default',
    ),
  ]),
  _Category('Recording', Icons.graphic_eq_rounded, [
    _Item(
      'Save the recording',
      (c) => switch (c.settings.mediaStorage) {
        MediaStorage.embed => 'The audio is stored in the project file.',
        MediaStorage.link => 'The project points to the recording; keep it nearby.',
      },
      (c) => SegmentedButton<MediaStorage>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: MediaStorage.embed, label: Text('Embed'), icon: Icon(Icons.inventory_2_outlined, size: 16)),
          ButtonSegment(value: MediaStorage.link, label: Text('Link'), icon: Icon(Icons.link, size: 16)),
        ],
        selected: {c.settings.mediaStorage},
        onSelectionChanged: (s) => c.settings.mediaStorage = s.single,
      ),
      keywords: 'embed link media audio video file',
    ),
  ]),
  // First-party components that are not part of the main work (import, curate, sync, export):
  // lower priority, each one optional.
  _Category('Extension', Icons.extension_outlined, [], empty: 'No extensions yet.'),
  _Category('Advanced', Icons.build_outlined, [
    _Item(
      'Engraving',
      null,
      (c) => Builder(
        builder: (context) => OutlinedButton(
          onPressed: () async {
            if (!await _confirmEngraving(context) || !context.mounted) return;
            showEngraveOptionsDialog(context, c.settings, controller: c.controller);
          },
          child: const Text('Engrave Option'),
        ),
      ),
      keywords: 'engrave engraving verovio options spacing slur tie beam stem thickness margin bar number lyric',
    ),
  ]),
  _Category('Update', Icons.system_update_alt_rounded, [
    _Item(
      'Version $appVersion',
      (c) => _updateHelp(c.updater.status),
      (c) => _UpdateControl(updater: c.updater),
      keywords: 'update download release new version check',
    ),
    _Item(
      'Check at launch',
      (_) => 'Asks GitHub for a newer version each time the app starts.',
      (c) => Switch(value: c.settings.checkForUpdates, onChanged: (v) => c.settings.checkForUpdates = v),
      keywords: 'update automatic startup',
    ),
    _Item(
      'Changelog',
      null,
      (_) => const _Link(changelogUrl),
      keywords: 'changelog changes release notes what\'s new history website open',
    ),
    _Item(
      'Source code',
      null,
      (_) => const _Link(repositoryUrl),
      keywords: 'github repository repo source code website open',
    ),
  ]),
];

/// Asked each time before the engraving options open: their values go straight to Verovio.
Future<bool> _confirmEngraving(BuildContext context) async {
  final go = await showAppDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Advanced engraving'),
      content: const Text('Editing these values might generate unintended results and errors. Use cautiously.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
      ],
    ),
  );
  return go ?? false;
}

String _updateHelp(UpdateStatus status) => switch (status) {
      UpdateIdle() => 'Curator, from GitHub.',
      UpdateChecking() => 'Asking GitHub…',
      UpToDate() => 'This is the latest version.',
      UpdateAvailable(:final release) when release.download == null =>
        '${release.version} is out, but not for this system yet.',
      UpdateAvailable(:final release) => '${release.version} is out.',
      UpdateDownloading(:final release) => 'Downloading ${release.version}…',
      UpdateDownloaded(:final path) =>
        'Saved “${path.split(RegExp(r'[/\\]')).last}”. Unzip it and replace this app with it.',
      UpdateFailed(:final message) => message,
    };

String _autosaveLabel(Duration d) => switch (d) {
      Duration.zero => 'Off',
      Duration(inMinutes: 0, :final inSeconds) => 'Every $inSeconds s',
      Duration(inMinutes: 1) => 'Every minute',
      Duration(:final inMinutes) => 'Every $inMinutes min',
    };

class _SettingsWindow extends StatefulWidget {
  const _SettingsWindow({required this.settings, this.controller, required this.updater, this.page});
  final AppSettings settings;
  final EditorController? controller;
  final Updater updater;
  final String? page;

  @override
  State<_SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends State<_SettingsWindow> {
  static int _lastPage = 0; // reopens where it was left
  late int _page = _lastPage = switch (_categories.indexWhere((c) => c.label == widget.page)) {
    -1 => _lastPage,
    final i => i,
  };
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  _Context get _ctx => (settings: widget.settings, controller: widget.controller, updater: widget.updater);

  /// Items matching the search, with their category; null when not searching.
  List<(_Category, _Item)>? get _matches {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return null;
    return [
      for (final cat in _categories)
        for (final item in cat.items)
          if ('${cat.label} ${item.title} ${item.keywords} ${item.help?.call(_ctx) ?? ''}'.toLowerCase().contains(q)) (cat, item),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final size = MediaQuery.sizeOf(context);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 720, maxHeight: (size.height - 64).clamp(340, 460)),
        child: Material(
          color: Theme.of(context).dialogTheme.backgroundColor,
          elevation: 10,
          shadowColor: Colors.black.withValues(alpha: 0.18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: colors.line)),
          clipBehavior: Clip.antiAlias,
          child: ListenableBuilder(
            listenable: Listenable.merge([widget.settings, _search, widget.updater, ?widget.controller]),
            builder: (context, _) => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _sidebar(context),
              VerticalDivider(width: 1, color: colors.line),
              Expanded(child: _content(context)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _sidebar(BuildContext context) {
    final colors = context.colors;
    final searching = _search.text.trim().isNotEmpty;
    return Container(
      width: 208,
      color: colors.accentWash,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 12),
          child: Text('Settings', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        ),
        SizedBox(
          height: 32,
          child: TextField(
            controller: _search,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search',
              prefixIcon: Icon(Icons.search, size: 16, color: colors.textMuted),
              prefixIconConstraints: const BoxConstraints(minWidth: 32),
              filled: true,
              fillColor: colors.surface,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: colors.line)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: colors.line)),
            ),
          ),
        ),
        const SizedBox(height: 12),
        for (final (i, cat) in _categories.indexed)
          _SidebarTile(
            icon: cat.icon,
            label: cat.label,
            selected: !searching && i == _page,
            onTap: () {
              _search.clear();
              setState(() => _page = _lastPage = i);
            },
          ),
      ]),
    );
  }

  Widget _content(BuildContext context) {
    final matches = _matches;
    final cat = _categories[_page];
    final Widget page;
    if (matches == null) {
      page = _Page(
        key: ValueKey(_page),
        title: cat.label,
        empty: cat.empty,
        children: [for (final item in cat.items) _row(item)],
      );
    } else {
      page = _Page(
        key: const ValueKey('search'),
        title: matches.isEmpty ? 'No matching settings' : 'Search results',
        children: [for (final (cat, item) in matches) _row(item, category: cat.label)],
      );
    }
    return Column(children: [
      Expanded(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.02), end: Offset.zero).animate(animation),
              child: child,
            ),
          ),
          layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
          child: page,
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 20, 16),
        child: Align(
          alignment: Alignment.centerRight,
          child: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
        ),
      ),
    ]);
  }

  Widget _row(_Item item, {String? category}) => _SettingRow(
        title: item.title,
        category: category,
        help: item.help?.call(_ctx),
        control: item.control(_ctx),
      );
}

class _SidebarTile extends StatelessWidget {
  const _SidebarTile({required this.icon, required this.label, required this.selected, required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: selected ? colors.accentSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(icon, size: 18, color: selected ? colors.accentStrong : colors.textMuted),
              const SizedBox(width: 10),
              Text(label,
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.text,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  )),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({super.key, required this.title, required this.children, this.empty});
  final String title;
  final List<Widget> children;
  final String? empty;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 22, 24, 12),
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        if (children.isNotEmpty)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(children: [
              for (final (i, child) in children.indexed) ...[
                if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: colors.line),
                child,
              ],
            ]),
          )
        else if (empty != null)
          Text(empty!, style: TextStyle(fontSize: 13, color: colors.textMuted)),
      ],
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.title, required this.help, required this.control, this.category});
  final String title;
  final String? help;
  final Widget control;
  final String? category;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (category != null)
              Text(category!.toUpperCase(),
                  style: TextStyle(fontSize: 10, letterSpacing: 0.6, color: colors.textMuted, fontWeight: FontWeight.w600)),
            Text(title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: colors.text)),
            if (help != null) ...[
              const SizedBox(height: 2),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                child: Text(help!, key: ValueKey(help), style: TextStyle(fontSize: 12, color: colors.textMuted)),
              ),
            ],
          ]),
        ),
        const SizedBox(width: 20),
        control,
      ]),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({required this.value, required this.values, required this.label, required this.onChanged});
  final T value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(border: Border.all(color: colors.line), borderRadius: BorderRadius.circular(8)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          borderRadius: BorderRadius.circular(10),
          focusColor: Colors.transparent,
          icon: Icon(Icons.unfold_more_rounded, size: 16, color: colors.textMuted),
          style: TextStyle(fontSize: 13, color: colors.text),
          onChanged: (v) => v == null ? null : onChanged(v),
          items: [for (final v in values) DropdownMenuItem(value: v, child: Text(label(v)))],
        ),
      ),
    );
  }
}

/// A row of colour swatches; the chosen one is ringed.
class _AccentPicker extends StatelessWidget {
  const _AccentPicker({required this.settings});
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Wrap(spacing: 6, children: [
      for (final accent in AccentColor.values)
        Tip(
          message: accent.label,
          child: GestureDetector(
            onTap: () => settings.accent = accent,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 24,
                height: 24,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: settings.accent == accent ? (dark ? accent.color : accent.strong) : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: dark ? accent.color : accent.strong, shape: BoxShape.circle),
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// A staff transition time; nothing when [value] is null.
class _TransitionPicker extends StatelessWidget {
  const _TransitionPicker({required this.value, required this.onChanged});
  final double? value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final current = value;
    if (current == null) return const SizedBox.shrink();
    return _Dropdown<double>(
      value: current,
      values: {...AppSettings.transitionChoices, current}.toList()..sort(),
      label: (s) => '$s s',
      onChanged: onChanged,
    );
  }
}

/// Check, then Download, then Show in Finder: the one button the update's state calls for.
class _UpdateControl extends StatelessWidget {
  const _UpdateControl({required this.updater});
  final Updater updater;

  static String get _revealLabel => Platform.isMacOS
      ? 'Show in Finder'
      : Platform.isWindows
          ? 'Show in Explorer'
          : 'Open Folder';

  @override
  Widget build(BuildContext context) {
    final check = OutlinedButton(onPressed: updater.check, child: const Text('Check for Updates'));
    final Widget control = switch (updater.status) {
      UpdateIdle() || UpToDate() || UpdateFailed(release: null) => check,
      UpdateChecking() => const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      UpdateAvailable(:final release) when release.download == null =>
        OutlinedButton(onPressed: () => openInBrowser(release.pageUrl), child: const Text('Open Release Page')),
      UpdateAvailable(:final release) =>
        FilledButton(onPressed: () => updater.download(release), child: Text('Download ${release.version}')),
      UpdateDownloading(:final progress) => SizedBox(
          width: 140,
          child: LinearProgressIndicator(value: progress, borderRadius: BorderRadius.circular(2)),
        ),
      UpdateDownloaded(:final path) =>
        OutlinedButton(onPressed: () => revealInFileManager(path), child: Text(_revealLabel)),
      UpdateFailed(release: final release?) =>
        OutlinedButton(onPressed: () => updater.download(release), child: const Text('Try Again')),
    };
    return AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: control);
  }
}

/// An address that opens in the browser, shown without its scheme or `#` part.
class _Link extends StatelessWidget {
  const _Link(this.url);
  final String url;

  @override
  Widget build(BuildContext context) => Tip(
        message: 'Open in the browser',
        child: TextButton(
          onPressed: () => openInBrowser(url),
          child: Text(url.replaceFirst('https://', '').split('#').first, style: const TextStyle(fontSize: 13)),
        ),
      );
}
