import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart' show EngravingOptions, MusicFont, verovioVersion;

import 'app_colors.dart';
import 'app_extensions.dart';
import 'app_settings.dart';
import 'editor_controller.dart';
import 'engrave_options_dialog.dart';
import 'export_dialog.dart' show revealInFileManager;
import 'font_settings.dart';
import 'project_file.dart';
import 'ui_kit.dart';
import 'updater.dart';

/// Settings… (⌘,): the app's, for every project. Categories on the left, each a page of
/// items on the right.
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
    _showWindow(
      context,
      _SettingsWindow(
        kind: _Window.app,
        settings: settings,
        controller: controller,
        updater: updater ?? Updater(),
        page: page,
      ),
    );

/// Score ▸ Project Settings… (⇧⌘,): the open project's own settings, laid out as Settings
/// ([_projectCategories]). Each change is an edit: an Undo step, saved with the project.
Future<void> showProjectSettingsDialog(BuildContext context, AppSettings settings, EditorController controller,
        {String? page}) =>
    _showWindow(
      context,
      _SettingsWindow(
        kind: _Window.project,
        settings: settings,
        controller: controller,
        updater: Updater(), // nothing here asks it
        page: page,
      ),
    );

Future<void> _showWindow(BuildContext context, _SettingsWindow window) => showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close settings',
      barrierColor: Colors.black.withValues(alpha: 0.2),
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (context, _, _) => window,
      transitionBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeOutCubic.flipped);
        return FadeTransition(
          opacity: curved,
          alwaysIncludeSemantics: true, // see showAppDialog
          child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(curved), child: child),
        );
      },
    );

/// Which settings a window shows: the app's or the open project's.
enum _Window {
  app,
  project;

  List<_Category> get categories => this == app ? _categories : _projectCategories;
}

/// One setting: a title and help on the left, its control on the right.
class _Item {
  const _Item(this.title, this.help, this.control, {this.note, this.keywords = '', this.shown});
  final String title;

  /// Whether it is offered now (on its page and in the search); null: always.
  final bool Function(_Context)? shown;

  /// Small and muted after the title (a version).
  final String? note;

  /// One short line under the title; null when the control says it all.
  final String Function(_Context)? help;
  final Widget Function(_Context) control;
  final String keywords;
}

class _Category {
  const _Category(this.label, this.icon, this.items, {this.empty, this.page});
  final String label;
  final IconData icon;
  final List<_Item> items;

  /// A page of its own in place of the rows of [items], which then only answer the search.
  final Widget Function(_Context)? page;

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
      (_) => 'For new projects.',
      (c) => _TransitionPicker(value: c.settings.transition, onChanged: (s) => c.settings.transition = s),
      keywords: 'fade duration enter leave glide default',
    ),
    _Item(
      'Scrolling',
      (c) => switch (c.settings.scrollFollow) {
        0 => 'Glides from beat to beat, as before 0.2: the speed changes only with the tempo.',
        1 => 'Every note is under the pointer exactly as it sounds: slower through long notes, quicker through runs.',
        _ => 'A blend: the beats land on time, and the speed follows the notes '
            '${(c.settings.scrollFollow * 100).round()}% of the way.',
      },
      (c) => _ScrollFollowSlider(settings: c.settings),
      keywords: 'scroll speed smooth snap note beat follow onset glide motion pointer',
    ),
  ]),
  _Category('Fonts', Icons.text_fields_rounded, [
    _Item('Music', (_) => 'For new projects.', (c) => MusicFontPicker.forNewProjects(settings: c.settings),
        keywords: 'font smufl bravura leland petaluma notation default'),
    _Item(
      'Embed font',
      (_) => 'For new projects.',
      (c) => EmbedFontSwitch.forNewProjects(settings: c.settings),
      shown: (c) => MusicFont.bundledNamed(c.settings.musicFont) == null,
      keywords: 'font embed include file installed default',
    ),
    _Item('Text', (_) => 'For new projects.', (c) => TextFontPicker.forNewProjects(settings: c.settings),
        keywords: 'font academico family typeface default'),
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
  // Each one is a switch for the whole app (AppExtension), off by default; what it adds
  // works only while it is on.
  _Category('Extension', Icons.extension_outlined, [
    for (final e in AppExtension.values)
      _Item(
        e.label,
        (_) => e.summary,
        (c) => Row(mainAxisSize: MainAxisSize.min, children: [
          _ExtensionSettingsButton(e, c.settings),
          const SizedBox(width: 6),
          Switch(value: e.isOn(c.settings), onChanged: (v) => e.set(c.settings, v)),
        ]),
        note: e.version,
        keywords: '${e.keywords} extension',
      ),
  ], empty: 'No extensions yet.'),
  _Category('Advanced', Icons.build_outlined, [
    _Item(
      'Engraving',
      (c) => _changedText(c.settings.engravingOptions, 'Every project.'),
      (c) => _EngraveOptionButton(c, project: false),
      keywords: _engravingKeywords,
    ),
  ]),
  // The page is _AboutPage; these rows are what the search finds.
  _Category('About', Icons.info_outline_rounded, page: (c) => _AboutPage(c), [
    _Item(
      'Version',
      null,
      (_) => Row(mainAxisSize: MainAxisSize.min, children: [_Value(_versionText), const _CopyButton()]),
      keywords: 'version build number commit about copy',
    ),
    _Item(
      'Updates',
      (c) => _updateHelp(c.updater.status),
      (c) => _UpdateControl(updater: c.updater),
      keywords: 'update download release new version check latest',
    ),
    _Item(
      'Check at launch',
      (_) => 'Asks GitHub for a newer version each time the app starts.',
      (c) => _launchSwitch(c),
      keywords: 'update automatic startup',
    ),
    _Item('Changelog', null, (_) => const _Link(changelogUrl), keywords: 'changelog changes release notes what\'s new history website open'),
    _Item('Source code', null, (_) => const _Link(repositoryUrl), keywords: 'github repository repo source code website open'),
    _Item('License', null, (_) => const _Link(licenseUrl, label: 'GPL-3.0'), keywords: 'license gpl copyright about'),
    _Item('Verovio', null, (_) => _Value(verovioVersion), keywords: 'engraver engine library about'),
    _Item('System', null, (_) => _Value(_systemText), keywords: 'os macos windows linux architecture about'),
  ]),
];

/// The open project's settings (Score ▸ Project Settings…): each change an edit.
final _projectCategories = <_Category>[
  _Category('Animation', Icons.animation_rounded, [
    _Item(
      'Staff transition',
      (_) => 'Regions can have their own.',
      (c) => _TransitionPicker(value: c.controller?.curation?.transition, onChanged: (s) => c.controller?.setTransition(s)),
      keywords: 'fade duration enter leave glide',
    ),
  ]),
  _Category('Fonts', Icons.text_fields_rounded, [
    _Item('Music', null, (c) => MusicFontPicker(controller: c.controller!), keywords: 'font smufl bravura leland petaluma notation'),
    _Item(
      'Embed font',
      null,
      (c) => EmbedFontSwitch(controller: c.controller!),
      shown: (c) => !c.controller!.fonts.music.isBundled, // a bundled one is in every copy of the app
      keywords: 'font embed include file installed',
    ),
    _Item('Text', null, (c) => TextFontPicker(controller: c.controller!), keywords: 'font academico family typeface'),
    _Item(
      'Caption',
      null,
      (c) => TextFontPicker(controller: c.controller!, caption: true),
      shown: (c) => c.controller!.captions.enabled,
      keywords: 'font captions family typeface',
    ),
  ]),
  _Category('Advanced', Icons.build_outlined, [
    _Item(
      'Engraving',
      (c) => _changedText(c.controller!.projectEngraving, 'Over the app’s.'),
      (c) => _EngraveOptionButton(c, project: true),
      keywords: _engravingKeywords,
    ),
  ]),
];

const _engravingKeywords = 'engrave engraving verovio options spacing slur tie beam stem thickness margin bar number lyric';

/// How many of [options] are set, or [none] while there are none.
String _changedText(EngravingOptions options, String none) => switch (options.overrides.length) {
      0 => none,
      1 => '1 changed.',
      final n => '$n changed.',
    };

/// Opens the engraving options, the app's or the project's, after the warning.
class _EngraveOptionButton extends StatelessWidget {
  const _EngraveOptionButton(this.c, {required this.project});
  final _Context c;
  final bool project;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: () async {
          if (!await _confirmEngraving(context) || !context.mounted) return;
          showEngraveOptionsDialog(context, c.settings, controller: c.controller, project: project);
        },
        child: const Text('Engrave Option'),
      );
}

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

Widget _launchSwitch(_Context c) =>
    Switch(value: c.settings.checkForUpdates, onChanged: (v) => c.settings.checkForUpdates = v);

/// `0.3.0 (17)`, then the commit when the build knows it.
String get _versionText => '$appVersion ($appBuild)${appCommit.isEmpty ? '' : ' · $appCommit'}';

/// `macOS 15.6 (24G84) · arm64`.
String get _systemText {
  final name = switch (Platform.operatingSystem) { 'macos' => 'macOS', 'windows' => 'Windows', 'linux' => 'Linux', final os => os };
  final version = Platform.operatingSystemVersion.replaceFirst(RegExp(r'^Version '), '').replaceFirst('(Build ', '(');
  return '$name $version · ${Abi.current().toString().split('_').last}';
}

/// What Copy puts on the clipboard: everything a bug report needs to say which build it is.
String get aboutText => 'Curator $_versionText\nVerovio $verovioVersion\n$_systemText';

String _updateHelp(UpdateStatus status) => switch (status) {
      UpdateIdle() => 'From GitHub.',
      UpdateChecking() => 'Asking GitHub…',
      UpToDate() => 'This is the latest version.',
      UpdateAvailable(:final release) when release.download == null =>
        '${release.version} is out, but not for this system yet.',
      UpdateAvailable(:final release) => '${release.version} is out.',
      UpdateDownloading(:final release) => 'Downloading ${release.version}…',
      UpdateDownloaded(:final path) => 'Saved “${path.split(RegExp(r'[/\\]')).last}”. '
          '${Platform.isWindows ? 'Close Curator, then replace its folder with the unzipped one.' : 'Unzip it and replace this app with it.'}',
      UpdateFailed(:final message) => message,
    };

String _autosaveLabel(Duration d) => switch (d) {
      Duration.zero => 'Off',
      Duration(inMinutes: 0, :final inSeconds) => 'Every $inSeconds s',
      Duration(inMinutes: 1) => 'Every minute',
      Duration(:final inMinutes) => 'Every $inMinutes min',
    };

class _SettingsWindow extends StatefulWidget {
  const _SettingsWindow({required this.kind, required this.settings, this.controller, required this.updater, this.page});
  final _Window kind;
  final AppSettings settings;
  final EditorController? controller;
  final Updater updater;
  final String? page;

  @override
  State<_SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends State<_SettingsWindow> {
  static final _lastPages = <_Window, int>{}; // each window reopens where it was left
  late final _categories = widget.kind.categories;
  late int _page = _lastPage = switch (_categories.indexWhere((c) => c.label == widget.page)) {
    -1 => _lastPage,
    final i => i,
  };
  final _search = TextEditingController();

  int get _lastPage => _lastPages[widget.kind] ?? 0;
  set _lastPage(int page) => _lastPages[widget.kind] = page;

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
        for (final item in _shownItems(cat))
          if ('${cat.label} ${item.title} ${item.keywords} ${item.help?.call(_ctx) ?? ''}'.toLowerCase().contains(q)) (cat, item),
    ];
  }

  /// The project closed under it (the menu bar works while it is open): it closes too.
  bool get _closed {
    if (widget.kind != _Window.project || widget.controller?.score != null) return false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) Navigator.pop(context);
    });
    return true;
  }

  Iterable<_Item> _shownItems(_Category cat) => cat.items.where((item) => item.shown?.call(_ctx) ?? true);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final size = MediaQuery.sizeOf(context);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 760, maxHeight: (size.height - 64).clamp(360, 500)),
        child: Material(
          color: Theme.of(context).dialogTheme.backgroundColor,
          elevation: 16,
          shadowColor: Colors.black.withValues(alpha: 0.14),
          // Its outline changes with the theme at once, as every other line does, not on a Material's
          // own shape animation, which would trail the window's cross-fade.
          animationDuration: Duration.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: colors.line)),
          clipBehavior: Clip.antiAlias,
          child: ListenableBuilder(
            listenable: Listenable.merge([widget.settings, _search, widget.updater, ?widget.controller]),
            builder: (context, _) => _closed
                ? const SizedBox.shrink()
                : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
      width: 200,
      color: _sidebarColor(colors),
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 30,
          child: TextField(
            controller: _search,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search',
              prefixIcon: Icon(Icons.search_rounded, size: 16, color: colors.textMuted),
              prefixIconConstraints: const BoxConstraints(minWidth: 30),
              filled: true,
              fillColor: colors.line.withValues(alpha: 0.6),
              contentPadding: const EdgeInsets.symmetric(vertical: 7),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(7), borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: BorderSide(color: colors.accent.withValues(alpha: 0.6)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
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
        const Spacer(),
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(
            widget.kind == _Window.project ? widget.controller?.fileName ?? '' : 'Curator $appVersion',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: colors.textMuted),
          ),
        ),
      ]),
    );
  }

  Widget _content(BuildContext context) {
    final matches = _matches;
    final cat = _categories[_page];
    final Widget page;
    if (matches == null && cat.page != null) {
      page = KeyedSubtree(key: ValueKey(_page), child: cat.page!(_ctx));
    } else if (matches == null) {
      page = _Page(
        key: ValueKey(_page),
        empty: cat.empty,
        groups: [if (_shownItems(cat).isNotEmpty) (null, [for (final item in _shownItems(cat)) _row(item)])],
      );
    } else {
      // One group per page, in sidebar order, each under its page's name.
      page = _Page(
        key: const ValueKey('search'),
        empty: matches.isEmpty
            ? widget.kind == _Window.project
                ? 'Try another word, such as “font” or “transition”.'
                : 'Try another word, such as “theme” or “update”.'
            : null,
        groups: [
          for (final c in _categories)
            if (matches.where((m) => m.$1 == c).toList() case final inCat when inCat.isNotEmpty)
              (c.label, [for (final (_, item) in inCat) _row(item)]),
        ],
      );
    }
    final colors = context.colors;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The header stays put while the page under it changes.
      Container(
        height: 52,
        padding: const EdgeInsets.only(left: 28, right: 10),
        child: Row(children: [
          Expanded(
            child: Text(
              matches == null
                  ? cat.label
                  : matches.isEmpty
                      ? 'No matching settings'
                      : 'Search results',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text),
            ),
          ),
          if (widget.kind == _Window.project && (widget.controller?.isReengraving ?? false))
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          IconButton(
            tooltip: 'Close',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            color: colors.textMuted,
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
          ),
        ]),
      ),
      Divider(height: 1, color: colors.line),
      Expanded(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          reverseDuration: const Duration(milliseconds: 90),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeOut,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              // A few points' rise as the page arrives; the leaving page only fades.
              position: Tween(begin: const Offset(0, 0.008), end: Offset.zero).animate(animation),
              child: child,
            ),
          ),
          layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
          child: page,
        ),
      ),
    ]);
  }

  // Keyed, so a control keeps its state when a row above it comes or goes (`shown`).
  Widget _row(_Item item) => _SettingRow(
      key: ObjectKey(item), title: item.title, note: item.note, help: item.help?.call(_ctx), control: item.control(_ctx));
}

/// The sidebar's neutral tint: a step off the dialog's surface, without the accent.
Color _sidebarColor(AppColors colors) => Color.lerp(colors.surface, colors.line, 0.32)!;

/// A group's fill: a lighter step than the sidebar, so the groups sit on the page without borders.
Color _groupColor(AppColors colors) => Color.lerp(colors.surface, colors.line, 0.22)!;

class _SidebarTile extends StatefulWidget {
  const _SidebarTile({required this.icon, required this.label, required this.selected, required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SidebarTile> createState() => _SidebarTileState();
}

class _SidebarTileState extends State<_SidebarTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final selected = widget.selected;
    // Raised off the sidebar: white on the light grey, a lighter grey on the dark one.
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Semantics(
        button: true,
        selected: selected,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: stateDuration(const Duration(milliseconds: 120)),
              curve: Curves.easeOut,
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: selected
                    ? (dark ? colors.line : colors.surface)
                    : _hover
                        ? colors.line.withValues(alpha: 0.45)
                        : colors.line.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(7),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: selected && !dark ? 0.06 : 0),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Row(children: [
                Icon(widget.icon, size: 16, color: selected ? colors.accentStrong : colors.textMuted),
                const SizedBox(width: 10),
                Text(widget.label,
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.text,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    )),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A page: groups of rows, each group optionally under a small heading; [empty] when there are none.
class _Page extends StatelessWidget {
  const _Page({super.key, required this.groups, this.empty});
  final List<(String?, List<Widget>)> groups;
  final String? empty;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
      children: [
        for (final (i, (heading, rows)) in groups.indexed) ...[
          if (i > 0) const SizedBox(height: 18),
          if (heading != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(heading,
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: colors.textMuted, letterSpacing: 0.2)),
            ),
          DecoratedBox(
            decoration: BoxDecoration(color: _groupColor(colors), borderRadius: BorderRadius.circular(10)),
            child: Column(children: [
              for (final (j, row) in rows.indexed) ...[
                if (j > 0) Divider(height: 1, indent: 14, endIndent: 14, color: colors.line),
                row,
              ],
            ]),
          ),
        ],
        if (groups.isEmpty && empty != null)
          Padding(
            padding: const EdgeInsets.only(top: 48),
            child: Text(empty!, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: colors.textMuted)),
          ),
      ],
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({super.key, required this.title, this.note, required this.help, required this.control});
  final String title;
  final String? note;
  final String? help;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text.rich(TextSpan(children: [
                TextSpan(text: title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: colors.text)),
                if (note != null) TextSpan(text: '  $note', style: TextStyle(fontSize: 11.5, color: colors.textMuted)),
              ])),
              if (help != null) ...[
                const SizedBox(height: 2),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 120),
                  layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                  child: Text(help!, key: ValueKey(help), style: TextStyle(fontSize: 12, height: 1.35, color: colors.textMuted)),
                ),
              ],
            ]),
          ),
          const SizedBox(width: 20),
          control,
        ]),
      ),
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
                duration: stateDuration(const Duration(milliseconds: 120)),
                curve: Curves.easeOut,
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

/// Beats ⟷ Notes: how closely the scroll follows the notes, live in the preview.
class _ScrollFollowSlider extends StatelessWidget {
  const _ScrollFollowSlider({required this.settings});
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final label = TextStyle(fontSize: 12, color: colors.textMuted);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('Beats', style: label),
      SizedBox(
        width: 150,
        child: OverlaySemantics(
          child: Slider(
            value: settings.scrollFollow,
            divisions: 20,
            label: '${(settings.scrollFollow * 100).round()}%',
            onChanged: (v) => settings.scrollFollow = v,
          ),
        ),
      ),
      Text('Notes', style: label),
    ]);
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
    return AnimatedSwitcher(duration: const Duration(milliseconds: 120), child: control);
  }
}

/// Opens [extension]'s own settings; greyed out when it has none.
class _ExtensionSettingsButton extends StatelessWidget {
  const _ExtensionSettingsButton(this.extension, this.settings);
  final AppExtension extension;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final page = extension.settings;
    return Tip(
      message: page == null ? 'No settings' : 'Settings',
      child: IconButton(
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        color: context.colors.textMuted,
        onPressed: page == null
            ? null
            : () => showAppDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(extension.label),
                    content: Builder(builder: (context) => page(context, settings)),
                    actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
                  ),
                ),
        icon: const Icon(Icons.settings_outlined),
      ),
    );
  }
}

/// An address that opens in the browser, shown without its scheme or `#` part.
class _Link extends StatelessWidget {
  const _Link(this.url, {this.label});
  final String url;
  final String? label;

  @override
  Widget build(BuildContext context) => Tip(
        message: 'Open in the browser',
        child: TextButton(
          onPressed: () => openInBrowser(url),
          child: Text(label ?? url.replaceFirst('https://', '').split('#').first, style: const TextStyle(fontSize: 13)),
        ),
      );
}

/// A read-only value, selectable so it can be copied.
class _Value extends StatelessWidget {
  const _Value(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      SelectableText(text, style: TextStyle(fontSize: 13, color: context.colors.textMuted));
}

/// Copies [aboutText]; a check for a moment after.
class _CopyButton extends StatefulWidget {
  const _CopyButton();

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) => Tip(
        message: 'Copy',
        child: IconButton(
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          color: context.colors.textMuted,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: aboutText));
            if (!mounted) return;
            setState(() => _copied = true);
            await Future<void>.delayed(const Duration(milliseconds: 1500));
            if (mounted) setState(() => _copied = false);
          },
          icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded),
        ),
      );
}

/// Settings ▸ About: the icon, name and build up top, the updates under them, then the links;
/// Verovio and the system at the foot.
class _AboutPage extends StatelessWidget {
  const _AboutPage(this.c);
  final _Context c;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final muted = TextStyle(fontSize: 12, color: colors.textMuted);
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight - 34),
          child: IntrinsicHeight(
            child: Column(children: [
              Image.asset(
                'assets/icon/app_icon.png',
                width: 76,
                height: 76,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => Icon(Icons.music_note_rounded, size: 64, color: colors.accent),
              ),
              const SizedBox(height: 6),
              Text('Curator', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: colors.text)),
              const SizedBox(height: 2),
              Text('Version $appVersion', style: TextStyle(fontSize: 13, color: colors.textMuted)),
              const SizedBox(height: 10),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _Pill('Build $appBuild'),
                if (appCommit.isNotEmpty) ...[const SizedBox(width: 6), _Pill(appCommit, mono: true)],
                const SizedBox(width: 2),
                const _CopyButton(),
              ]),
              const SizedBox(height: 18),
              DecoratedBox(
                decoration: BoxDecoration(color: _groupColor(colors), borderRadius: BorderRadius.circular(10)),
                child: Column(children: [
                  _SettingRow(
                    title: 'Updates',
                    help: _updateHelp(c.updater.status),
                    control: _UpdateControl(updater: c.updater),
                  ),
                  Divider(height: 1, indent: 14, endIndent: 14, color: colors.line),
                  _SettingRow(title: 'Check at launch', help: null, control: _launchSwitch(c)),
                ]),
              ),
              const SizedBox(height: 6),
              const Wrap(alignment: WrapAlignment.center, spacing: 4, children: [
                _Link(changelogUrl, label: 'Changelog'),
                _Link(repositoryUrl, label: 'Source code'),
                _Link(licenseUrl, label: 'License (GPL-3.0)'),
              ]),
              const Spacer(),
              const SizedBox(height: 6),
              SelectableText('Verovio $verovioVersion  ·  $_systemText', textAlign: TextAlign.center, style: muted),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A small rounded label: the build, the commit.
class _Pill extends StatelessWidget {
  const _Pill(this.text, {this.mono = false});
  final String text;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: _groupColor(colors), borderRadius: BorderRadius.circular(20)),
      child: SelectableText(
        text,
        style: TextStyle(
          fontSize: 11.5,
          color: colors.textMuted,
          fontFamily: mono ? 'Menlo' : null,
          fontFamilyFallback: mono ? const ['Consolas', 'monospace'] : null,
        ),
      ),
    );
  }
}
