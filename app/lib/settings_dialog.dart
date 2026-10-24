import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart' show EngraveOption, InstrumentFamily, verovioVersion;

import 'app_colors.dart';
import 'app_icons.dart';
import 'app_logo.dart';
import 'app_settings.dart';
import 'color_dialog.dart';
import 'audio_panel.dart' show pickAudio;
import 'condensing_editor.dart';
import 'dialog_kit.dart';
import 'editor_controller.dart';
import 'engrave_options_dialog.dart';
import 'engraving_settings.dart';
import 'extensions/extension.dart';
import 'export_dialog.dart' show revealInFileManager;
import 'file_names.dart';
import 'font_settings.dart';
import 'menu_kit.dart';
import 'project_file.dart';
import 'project_state.dart' show defaultNameColors;
import 'sections_editor.dart';
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

/// File ▸ Project Settings… (⇧⌘,): the open project's own settings, laid out as Settings
/// ([_projectCategories]). Each change is an edit: an Undo step, saved with the project.
/// [replaceScore] is Project Info's Replace… (the app's, which asks first).
Future<void> showProjectSettingsDialog(BuildContext context, AppSettings settings, EditorController controller,
        {String? page, Future<void> Function()? replaceScore}) =>
    _showWindow(
      context,
      _SettingsWindow(
        kind: _Window.project,
        settings: settings,
        controller: controller,
        updater: Updater(), // nothing here asks it
        page: page,
        replaceScore: replaceScore,
      ),
    );

Future<void> _showWindow(BuildContext context, _SettingsWindow window) => showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close settings',
      barrierColor: Colors.black.withValues(alpha: 0.2),
      transitionDuration: motion(context, 160),
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
  const _Item(this.title, this.help, this.control, {this.note, this.keywords = '', this.shown, this.group});
  final String title;

  /// The heading it is under on its page; items in a row with the same one share a group.
  final String? group;

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
  const _Category(this.label, this.icon, this.items, {this.empty, this.page, this.header, this.saveDefault});
  final String label;
  final AppIcon icon;
  final List<_Item> items;

  /// Above the page's rows, staying put while they scroll; null for none.
  final Widget? Function(_Context)? header;

  /// A page of its own in place of the rows of [items], which then only answer the search.
  final Widget Function(_Context)? page;

  /// Shown in place of the items while there are none.
  final String? empty;

  /// A project page whose settings can become the app's, for other projects: a slim Save as
  /// Default button beside the page's title.
  final _SaveDefault? saveDefault;
}

/// Save as Default on a project page: [isDefault] while the app's already match the project's;
/// [save] makes them so. Offered while [shown] (null: always).
typedef _SaveDefault = ({
  bool Function(_Context)? shown,
  bool Function(_Context) isDefault,
  void Function(_Context) save,
});

typedef _Context = ({
  AppSettings settings,
  EditorController? controller,
  Updater updater,
  Future<void> Function()? replaceScore,
});

final _categories = <_Category>[
  _Category('General', AppIcon.general, [
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
      (_) => 'Per project.',
      (c) => _Dropdown<int>(
        value: c.settings.undoSteps,
        values: AppSettings.undoStepChoices,
        label: (n) => '$n steps',
        onChanged: (v) => c.settings.undoSteps = v,
      ),
      keywords: 'undo redo steps',
    ),
  ]),
  _Category('Appearance', AppIcon.appearance, [
    _Item(
      'Theme',
      (_) => 'Dark also turns the score dark.',
      (c) => Builder(builder: (context) => AppSegmented<ThemeMode>(
        segments: [
          ButtonSegment(value: ThemeMode.system, icon: Icon(AppIcon.auto.of(context), size: 16), label: Text('Auto')),
          ButtonSegment(value: ThemeMode.light, icon: Icon(AppIcon.light.of(context), size: 16), label: Text('Light')),
          ButtonSegment(value: ThemeMode.dark, icon: Icon(AppIcon.dark.of(context), size: 16), label: Text('Dark')),
        ],
        selected: c.settings.themeMode,
        onChanged: (v) => c.settings.themeMode = v,
      )),
      keywords: 'dark light mode colour color',
    ),
    _Item(
      'Accent color',
      null,
      (c) => _AccentPicker(settings: c.settings),
      keywords: 'color colour scheme custom hex',
    ),
    _Item(
      'Style',
      null,
      (c) => AppSegmented<UiStyle>(
        segments: [for (final s in UiStyle.values) ButtonSegment(value: s, label: Text(s.label))],
        selected: c.settings.uiStyle,
        onChanged: (v) => c.settings.uiStyle = v,
      ),
      keywords: 'look controls switch button classic refined carbon ibm theme',
    ),
    _Item(
      'Text size',
      null,
      (c) => AppSegmented<TextSize>(
        segments: [for (final s in TextSize.values) ButtonSegment(value: s, label: Text(s.label))],
        selected: c.settings.textSize,
        onChanged: (v) => c.settings.textSize = v,
      ),
      keywords: 'font type bigger smaller larger scale zoom accessibility',
    ),
    _Item(
      'Density',
      null,
      (c) => AppSegmented<UiDensity>(
        segments: [for (final d in UiDensity.values) ButtonSegment(value: d, label: Text(d.label))],
        selected: c.settings.density,
        onChanged: (v) => c.settings.density = v,
      ),
      keywords: 'compact comfortable spacing size toolbar rows tight roomy',
    ),
    _Item(
      'Reduce motion',
      null,
      (c) => AppSwitch(value: c.settings.reduceMotion, onChanged: (v) => c.settings.reduceMotion = v),
      keywords: 'animation animations fade slide still accessibility',
    ),
  ]),
  // The page is _AboutPage; these rows are what the search finds.
  _Category('About', AppIcon.about, page: (c) => _AboutPage(c), [
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

/// The open project's settings (File ▸ Project Settings…): each change an edit.
final _projectCategories = <_Category>[
  _Category('Project Info', AppIcon.about, [
    _Item(
      'Score',
      (c) => c.controller!.fileName ?? '',
      (c) => OutlinedButton(onPressed: c.replaceScore, child: const Text('Replace…')),
      keywords: 'replace score file musicxml mei import',
    ),
    _Item(
      'Recording',
      (c) => c.controller!.track?.name ?? 'None.',
      (c) => Builder(
        builder: (context) => OutlinedButton(
          onPressed: c.controller!.isLoadingAudio ? null : () => pickAudio(context, c.controller!),
          child: Text(c.controller!.track == null ? 'Add…' : 'Replace…'),
        ),
      ),
      keywords: 'add recording audio file video sound',
    ),
    _Item(
      'Save the recording',
      (c) => switch (_mediaStorage(c)) {
        MediaStorage.embed => 'In the project file.',
        MediaStorage.link => 'Linked; keep it nearby.',
      },
      (c) => Builder(builder: (context) => AppSegmented<MediaStorage>(
        segments: [
          ButtonSegment(value: MediaStorage.embed, label: Text('Embed'), icon: Icon(AppIcon.embed.of(context), size: 16)),
          ButtonSegment(value: MediaStorage.link, label: Text('Link'), icon: Icon(AppIcon.link.of(context), size: 16)),
        ],
        selected: _mediaStorage(c),
        onChanged: c.controller!.setMediaStorage,
      )),
      shown: (c) => c.controller!.track != null,
      keywords: 'embed link media audio video file save',
    ),
  ], saveDefault: (
    shown: (c) => c.controller!.track != null,
    isDefault: (c) => _mediaStorage(c) == c.settings.mediaStorage,
    save: (c) => c.settings.mediaStorage = _mediaStorage(c),
  )),
  _Category('Animation', AppIcon.transition, [
    _Item(
      'Staff transition',
      (_) => 'Regions can have their own.',
      (c) => _TransitionPicker(value: c.controller?.curation?.transition, onChanged: (s) => c.controller?.setTransition(s)),
      keywords: 'fade duration enter leave glide',
    ),
    _Item(
      'Scrolling',
      (c) => switch (c.controller!.scrollFollow) {
        0 => 'Glides from beat to beat: the speed changes only with the tempo.',
        1 => 'Every note is under the playhead exactly as it sounds: slower through long notes, quicker through runs.',
        final f => 'A blend: the beats land on time, and the speed follows the notes ${(f * 100).round()}% of the way.',
      },
      (c) => _ScrollFollowSlider(controller: c.controller!),
      keywords: 'scroll speed smooth snap note beat follow onset glide motion pointer',
    ),
  ], saveDefault: (
    shown: null,
    isDefault: _animationIsDefault,
    save: (c) => c.settings
      ..transition = c.controller!.curation!.transition
      ..scrollFollow = c.controller!.scrollFollow,
  )),
  _engravingCategory(),
  _Category('Instruments', AppIcon.score, [
    _Item(
      'Color names',
      null,
      (c) => AppSwitch(value: c.controller!.colorNames, onChanged: c.controller!.setColorNames),
      keywords: 'color colour names labels instrument family section group woodwinds brass strings percussion',
    ),
    for (final family in defaultNameColors.keys)
      _Item(
        family.label,
        null,
        (c) => _NameColorPicker(controller: c.controller!, family: family),
        group: 'Colors',
        shown: (c) => c.controller!.colorNames,
        keywords: 'color colour names labels instrument family section group',
      ),
  ]),
  _Category('Sections', AppIcon.lanes, page: (c) => _SectionsPage(c), [
    _Item(
      'Group sections',
      null,
      (c) => AppSwitch(value: c.controller!.groupSections, onChanged: c.controller!.setGroupSections),
      keywords: 'bracket barline barlines group sections family instrument woodwinds brass strings percussion printed',
    ),
  ]),
  _Category('Condensing', AppIcon.condense, page: (c) => _CondensingPage(c), [
    _Item(
      'All pairs',
      _condensedText,
      (c) => _allPairsSwitch(c.controller!),
      keywords: 'condense condensing pair players share staff a2',
    ),
  ]),
  // First-party components that are not part of the main work (import, curate, sync, export):
  // lower priority, each one optional, off by default. Each is a switch for this project only
  // (an Undo step, no app-wide default); what it adds works only while it is on.
  _Category('Extensions', AppIcon.extensions, [
    for (final e in Extensions.all)
      _Item(
        e.label,
        (_) => e.summary,
        (c) => Row(mainAxisSize: MainAxisSize.min, children: [
          _ExtensionSettingsButton(e, c.settings),
          const SizedBox(width: 6),
          AppSwitch(value: e.isOn(c.controller!), onChanged: (v) => e.set(c.controller!, v)),
        ]),
        note: e.version,
        keywords: '${e.keywords} extension',
      ),
  ], empty: 'No extensions yet.'),
  // Fixes for how other programs write their files, on by default; a switch to turn one off.
  _Category('Flags', AppIcon.flags, [
    _Item(
      'Dynamics typed as text',
      (_) => 'Engraves “f” set in a music font as a dynamic.',
      (c) => AppSwitch(value: c.controller!.textDynamics, onChanged: c.controller!.setTextDynamics),
      keywords: 'flag dynamics text words music font maestro opus sibelius finale import musicxml forte piano',
    ),
  ], saveDefault: (
    shown: null,
    isDefault: _flagsAreDefault,
    save: (c) => c.settings.textDynamics = c.controller!.textDynamics,
  )),
];

/// Whether the project's flags are the app's default (Save as default).
bool _flagsAreDefault(_Context c) => c.controller!.textDynamics == c.settings.textDynamics;

/// How the project's saves keep the recording.
MediaStorage _mediaStorage(_Context c) => c.controller!.mediaStorage ?? c.settings.mediaStorage;

/// Whether the project's animation is the app's default (Save as default).
bool _animationIsDefault(_Context c) =>
    c.settings.transition == c.controller!.curation!.transition && c.settings.scrollFollow == c.controller!.scrollFollow;

/// How many of the score's pairs share a staff.
String _condensedText(_Context c) {
  final pairs = c.controller!.condensable;
  return '${pairs.where((p) => c.controller!.condensed.contains(p.id)).length} of ${pairs.length} share a staff.';
}

/// On while every pair shares a staff; turning it on or off turns them all.
Widget _allPairsSwitch(EditorController c) {
  final pairs = c.condensable;
  final all = pairs.isNotEmpty && pairs.every((p) => c.condensed.contains(p.id));
  return AppSwitch(
    value: all,
    onChanged: pairs.isEmpty ? null : (_) => c.setCondensed([for (final p in pairs) p.id], on: !all),
  );
}

/// Project Settings ▸ Condensing, as in Dorico (Layout Options ▸ Condensing): which pairs of
/// players share a staff, each its own switch (an Undo step); and pairs of the user's own
/// ([CondensingAddPair]), which can be removed. The only place condensing is chosen.
class _CondensingPage extends StatelessWidget {
  const _CondensingPage(this.c);
  final _Context c;

  @override
  Widget build(BuildContext context) {
    final controller = c.controller!;
    final pairs = controller.condensable;
    return _Page(
      empty: 'No players in this score can share a staff.',
      groups: [
        if (pairs.length > 1)
          (null, [_SettingRow(title: 'All pairs', help: _condensedText(c), control: _allPairsSwitch(controller))]),
        if (pairs.isNotEmpty)
          ('Pairs', [
            for (final pair in pairs)
              _SettingRow(
                title: controller.pairName(pair),
                help: controller.pairs.contains(pair) ? 'Yours.' : null,
                control: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (controller.pairs.contains(pair)) ...[
                    ToolbarButton(
                      icon: AppIcon.close.of(context),
                      tooltip: 'Remove pair',
                      onPressed: () => controller.removePair(pair),
                    ),
                    const SizedBox(width: 10),
                  ],
                  AppSwitch(
                    value: controller.condensed.contains(pair.id),
                    onChanged: (on) => controller.setCondensed([pair.id], on: on),
                  ),
                ]),
              ),
          ]),
        if (CondensingAddPair.offered(controller)) ('Add a pair', [CondensingAddPair(controller: controller)]),
      ],
    );
  }
}

/// Project Settings ▸ Sections: Group sections, and the brackets ([SectionsEditor]).
class _SectionsPage extends StatelessWidget {
  const _SectionsPage(this.c);
  final _Context c;

  /// Laid out as a [_Page], but the brackets fill the rest of it and scroll on their own, so
  /// their buttons stay in view.
  @override
  Widget build(BuildContext context) {
    final decoration = BoxDecoration(color: _groupColor(context), borderRadius: AppStyle.of(context).radius(10));
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DecoratedBox(
          decoration: decoration,
          child: _SettingRow(
              title: 'Group sections',
              help: null,
              control: AppSwitch(value: c.controller!.groupSections, onChanged: c.controller!.setGroupSections)),
        ),
        const SizedBox(height: 18),
        Expanded(
          child: DecoratedBox(
            decoration: decoration,
            child: ClipRRect(
                borderRadius: AppStyle.of(context).radius(10), child: SectionsEditor(controller: c.controller!)),
          ),
        ),
      ]),
    );
  }
}

/// Project Settings ▸ Engraving: the fonts, the options most scores want changed
/// ([EngravingSetting.all]) under a preview of the score, every other one in Engraving options
/// by code name, and Save as default (the app's, for other projects).
_Category _engravingCategory() {
  EngravingTarget target(_Context c) => EngravingTarget(c.settings, c.controller!);
  return _Category(
    'Engraving',
    AppIcon.music,
    header: (c) => SizedBox(
        height: 170, child: EngravingPreviewHost(settings: c.settings, controller: c.controller, scale: 0.5)),
    saveDefault: (shown: null, isDefault: (c) => target(c).isDefault, save: (c) => target(c).saveAsDefault()),
    [
      _Item('Music font', null, (c) => MusicFontPicker(controller: c.controller!),
          group: 'Fonts', keywords: 'font smufl bravura leland petaluma notation'),
      _Item(
        'Embed font',
        null,
        (c) => EmbedFontSwitch(controller: c.controller!),
        shown: (c) => !c.controller!.fonts.music.isBundled, // a bundled one is in every copy of the app
        group: 'Fonts',
        keywords: 'font embed include file installed',
      ),
      _Item('Text font', null, (c) => TextFontPicker(controller: c.controller!),
          group: 'Fonts', keywords: 'font academico family typeface'),
      _Item(
        'Caption font',
        null,
        (c) => TextFontPicker(controller: c.controller!, caption: true),
        shown: (c) => c.controller!.captions.enabled,
        group: 'Fonts',
        keywords: 'font captions family typeface',
      ),
      for (final s in EngravingSetting.all)
        _Item(
          s.title,
          null,
          (c) => EngravingControl(target: target(c), setting: s),
          group: s.group,
          keywords: 'engrave engraving ${s.group} ${s.keywords} ${s.key}',
        ),
      _Item(
        'Bar numbers',
        null,
        (c) => AppSwitch(value: c.controller!.barNumbers, onChanged: c.controller!.setBarNumbers),
        group: 'Notation',
        keywords: 'bar measure numbers numbering count',
      ),
      _Item(
        'Engraving options',
        (c) => switch (EngraveOption.all.where(target(c).isChanged).length) {
          0 => 'None changed.',
          1 => '1 changed.',
          final n => '$n changed.',
        },
        (c) => _EngraveOptionButton(c),
        group: 'All options',
        keywords: 'engrave engraving verovio advanced expert options code spacing slur tie beam stem '
            'thickness margin bar number lyric',
      ),
    ],
  );
}

/// Opens the project's engraving options, after the warning.
class _EngraveOptionButton extends StatelessWidget {
  const _EngraveOptionButton(this.c);
  final _Context c;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: () async {
          if (!await _confirmEngraving(context) || !context.mounted) return;
          unawaited(showEngraveOptionsDialog(context, c.settings, c.controller!));
        },
        child: const Text('Open…'),
      );
}

/// Asked each time before the engraving options open: their values go straight to Verovio.
Future<bool> _confirmEngraving(BuildContext context) async {
  final go = await showAppDialog<bool>(
    context: context,
    builder: (context) => AppDialog(
      title: const Text('Advanced Engraving'),
      content: const Text('Some values can break the layout or stop engraving.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
      ],
    ),
  );
  return go ?? false;
}

Widget _launchSwitch(_Context c) =>
    AppSwitch(value: c.settings.checkForUpdates, onChanged: (v) => c.settings.checkForUpdates = v);

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
      UpdateChecking() => 'Checking…',
      UpToDate() => 'Curator is up to date.',
      UpdateAvailable(:final release) when release.download == null =>
        'Curator ${release.version} is available, but not yet for this system.',
      UpdateAvailable(:final release) => 'Curator ${release.version} is available.',
      UpdateDownloading(:final release) => 'Downloading ${release.version}…',
      UpdateDownloaded(:final path) => 'Saved “${fileNameOf(path)}”. '
          '${Platform.isWindows ? 'Close Curator, then replace its folder with the unzipped one.' : 'Unzip it and replace this app with it.'}',
      UpdateFailed(:final message) => message,
    };

String _autosaveLabel(Duration d) => switch (d) {
      Duration.zero => 'Off',
      Duration(inMinutes: 0, :final inSeconds) => 'Every $inSeconds seconds',
      Duration(inMinutes: 1) => 'Every minute',
      Duration(:final inMinutes) => 'Every $inMinutes minutes',
    };

class _SettingsWindow extends StatefulWidget {
  const _SettingsWindow(
      {required this.kind, required this.settings, this.controller, required this.updater, this.page, this.replaceScore});
  final _Window kind;
  final Future<void> Function()? replaceScore;
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
    widget.controller?.removeListener(_controllerChanged);
    _search.dispose();
    super.dispose();
  }

  _Context get _ctx => (
        settings: widget.settings,
        controller: widget.controller,
        updater: widget.updater,
        replaceScore: widget.replaceScore,
      );

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

  /// The project closed under it (the menu bar works while it is open): it closes too
  /// ([_controllerChanged]), showing nothing meanwhile.
  bool get _closed => widget.kind == _Window.project && widget.controller?.score == null;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_controllerChanged);
  }

  @override
  void didUpdateWidget(_SettingsWindow old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?.removeListener(_controllerChanged);
      widget.controller?.addListener(_controllerChanged);
    }
  }

  void _controllerChanged() {
    if (!_closed || _closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) Navigator.pop(context);
    });
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
          shape: AppStyle.of(context).isCarbon
              ? const RoundedRectangleBorder()
              : RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: colors.line)),
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
    final carbon = CarbonColors.maybeOf(context);
    final searching = _search.text.trim().isNotEmpty;
    return Container(
      width: 200,
      color: _sidebarColor(context),
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: carbon == null ? 30 : 32,
          child: TextField(
            controller: _search,
            style: TextStyle(fontSize: carbon == null ? 13 : 14),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search',
              prefixIcon: Icon(AppIcon.search.of(context), size: 16, color: carbon?.textSecondary ?? colors.textMuted),
              prefixIconConstraints: BoxConstraints(minWidth: carbon == null ? 30 : 40),
              filled: true,
              fillColor: carbon?.field ?? colors.line.withValues(alpha: 0.6),
              contentPadding: EdgeInsets.symmetric(vertical: carbon == null ? 7 : 8),
              // Carbon's small search: a line under it, its focus ring.
              border: carbon != null
                  ? fieldBorders(context).rest
                  : OutlineInputBorder(borderRadius: BorderRadius.circular(7), borderSide: BorderSide.none),
              enabledBorder: carbon != null ? fieldBorders(context).rest : null,
              focusedBorder: carbon != null
                  ? fieldBorders(context).focused
                  : OutlineInputBorder(
                      borderRadius: BorderRadius.circular(7),
                      borderSide: BorderSide(color: colors.accent.withValues(alpha: 0.6)),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        for (final (i, cat) in _categories.indexed)
          _SidebarTile(
            icon: cat.icon.of(context),
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
    Widget page;
    if (matches == null && cat.page != null) {
      page = KeyedSubtree(key: ValueKey(_page), child: cat.page!(_ctx));
    } else if (matches == null) {
      final groups = <(String?, List<Widget>)>[];
      for (final item in _shownItems(cat)) {
        if (groups.isEmpty || groups.last.$1 != item.group) groups.add((item.group, []));
        groups.last.$2.add(_row(item));
      }
      page = _Page(key: ValueKey(_page), empty: cat.empty, groups: groups);
      if (cat.header?.call(_ctx) case final header?) {
        final colors = context.colors;
        page = Column(key: ValueKey(_page), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          header,
          Divider(height: 1, color: colors.line),
          Expanded(child: page),
        ]);
      }
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
          if (matches == null && cat.saveDefault != null && (cat.saveDefault!.shown?.call(_ctx) ?? true))
            _SaveDefaultButton(isDefault: cat.saveDefault!.isDefault(_ctx), onPressed: () => cat.saveDefault!.save(_ctx)),
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
            icon: Icon(AppIcon.close.of(context)),
          ),
        ]),
      ),
      Divider(height: 1, color: colors.line),
      Expanded(
        child: AnimatedSwitcher(
          duration: motion(context, 160),
          reverseDuration: motion(context, 90),
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

/// The sidebar's neutral tint: a step off the dialog's surface, without the accent; in the light
/// theme the (nearly white) chrome; in Carbon the modal's own $layer-01.
Color _sidebarColor(BuildContext context) {
  final colors = context.colors;
  if (CarbonColors.maybeOf(context) case final k?) return k.layer01;
  return _lightChrome(colors) ? colors.chrome : Color.lerp(colors.surface, colors.line, 0.32)!;
}

bool _lightChrome(AppColors colors) => colors.chrome != colors.surface && colors.surface.computeLuminance() > 0.5;

/// A group's fill: a lighter step than the sidebar, so the groups sit on the page without borders
/// (Carbon: a tile on $layer-02).
Color _groupColor(BuildContext context) {
  final colors = context.colors;
  if (CarbonColors.maybeOf(context) case final k?) return k.layer02;
  return _lightChrome(colors) ? colors.chrome : Color.lerp(colors.surface, colors.line, 0.22)!;
}

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
    final style = AppStyle.of(context);
    final k = CarbonColors.maybeOf(context);
    // Refined: a solid accent row with white text, as a desktop source list's. Carbon: its side
    // nav's item, $layer-selected with a 3 px bar of the accent at its left, the text semibold.
    final solid = k == null && selected;
    final fill = k != null
        ? (selected ? k.layerSelected : _hover ? k.layerHover : k.layerHover.withValues(alpha: 0))
        : solid
            ? colors.accentFill
            : _hover
                ? colors.line.withValues(alpha: 0.45)
                : colors.line.withValues(alpha: 0);
    final ink = k != null ? (selected || _hover ? k.textPrimary : k.textSecondary) : solid ? Colors.white : colors.text;
    return Padding(
      padding: EdgeInsets.only(bottom: k != null ? 0 : 1),
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
              duration: stateDuration(motion(context, 120)),
              curve: style.curve,
              height: k != null ? 32 : 30,
              padding: EdgeInsets.only(left: k != null ? 13 : 8, right: 8),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: style.radius(5),
                // $border-interactive: the accent, in the dark too.
                border: k == null
                    ? null
                    : Border(left: BorderSide(color: selected ? colors.accent : Colors.transparent, width: 3)),
              ),
              child: Row(children: [
                Icon(widget.icon, size: 16, color: k != null ? ink : solid ? Colors.white : colors.textMuted),
                SizedBox(width: k != null ? 8 : 10),
                Flexible(
                  child: Text(widget.label,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: k != null ? 14 : 13,
                        letterSpacing: k != null ? 0.16 : null,
                        color: ink,
                        fontWeight: k != null && selected ? FontWeight.w600 : FontWeight.w400,
                      )),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Save as Default, slim beside a page's title: once saved (or already the same), a muted
/// check and "Default" in its place.
class _SaveDefaultButton extends StatelessWidget {
  const _SaveDefaultButton({required this.isDefault, required this.onPressed});
  final bool isDefault;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // Slimmer than the rows' buttons: it belongs to the page, not to a setting.
    final style = OutlinedButton.styleFrom(
      minimumSize: const Size(0, 26),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      shape: RoundedRectangleBorder(borderRadius: AppStyle.of(context).radius(13)),
      side: BorderSide(color: colors.line),
      // The theme's, so it keeps the app's font.
      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12, fontWeight: FontWeight.w500),
      disabledForegroundColor: colors.textMuted,
    );
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tip(
        message: isDefault ? 'Other projects start with these' : 'Use these for other projects',
        child: isDefault
            ? OutlinedButton.icon(
                style: style.copyWith(side: const WidgetStatePropertyAll(BorderSide(color: Colors.transparent))),
                onPressed: null,
                icon: Icon(AppIcon.check.of(context), size: 13),
                label: const Text('Default'),
              )
            : OutlinedButton(style: style, onPressed: onPressed, child: const Text('Save as Default')),
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
            decoration: BoxDecoration(color: _groupColor(context), borderRadius: AppStyle.of(context).radius(10)),
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
                  duration: motion(context, 120),
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
  Widget build(BuildContext context) => SettingsDropdown<T>(
        value: value,
        onChanged: onChanged,
        items: [for (final v in values) DropdownMenuItem(value: v, child: Text(label(v)))],
      );
}

/// A row of colour swatches, then the user's own (a colour wheel until there is one), which asks
/// for a colour; the chosen one is ringed.
class _AccentPicker extends StatelessWidget {
  const _AccentPicker({required this.settings});
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final style = AppStyle.of(context);
    // Each as the style shows it: Carbon's IBM hue (square, as Carbon's swatches are).
    Color swatch(AccentColor accent) {
      final c = AppColors.of(accent, Theme.of(context).brightness, style.style);
      return dark ? c.accent : c.accentStrong;
    }

    final shape = style.rounded ? BoxShape.circle : BoxShape.rectangle;
    Widget item(String tip, bool chosen, Color ring, Decoration fill, VoidCallback onTap) => Tip(
          message: tip,
          child: GestureDetector(
            onTap: onTap,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: AnimatedContainer(
                duration: stateDuration(motion(context, 120)),
                curve: style.curve,
                width: 24,
                height: 24,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: shape,
                  border: Border.all(color: chosen ? ring : Colors.transparent, width: 2),
                ),
                child: DecoratedBox(decoration: fill),
              ),
            ),
          ),
        );

    final custom = settings.customAccent;
    final own = custom == null ? null : AccentColor.custom(custom);
    Future<void> pick() async {
      final color = await showColorDialog(context, initial: custom ?? settings.accent.color);
      if (color != null) settings.accent = AccentColor.custom(color);
    }

    return Wrap(spacing: 6, children: [
      for (final accent in AccentColor.values)
        item(accent.label, settings.accent == accent, swatch(accent), BoxDecoration(color: swatch(accent), shape: shape),
            () => settings.accent = accent),
      item(
        'Custom…',
        settings.accent.isCustom,
        own == null ? context.colors.text : swatch(own),
        own == null
            ? BoxDecoration(
                shape: shape,
                gradient: SweepGradient(colors: [
                  for (var d = 0; d <= 360; d += 60) HSLColor.fromAHSL(1, d % 360, 0.75, 0.6).toColor(),
                ]),
              )
            : BoxDecoration(color: swatch(own), shape: shape),
        pick,
      ),
    ]);
  }
}

/// The colour [family]'s names take: a swatch asking for another, and Reset once it is the user's.
class _NameColorPicker extends StatelessWidget {
  const _NameColorPicker({required this.controller, required this.family});
  final EditorController controller;
  final InstrumentFamily family;

  @override
  Widget build(BuildContext context) {
    final style = AppStyle.of(context);
    final color = controller.nameColor(family);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (controller.ownNameColor(family))
        IconButton(
          icon: Icon(AppIcon.reset.of(context), size: 15),
          tooltip: 'Reset',
          visualDensity: VisualDensity.compact,
          color: context.colors.textMuted,
          onPressed: () => controller.setNameColor(family, null),
        ),
      const SizedBox(width: 6),
      GestureDetector(
        onTap: () async {
          final chosen = await showColorDialog(context, initial: color, title: family.label);
          if (chosen != null) controller.setNameColor(family, chosen);
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color,
              shape: style.rounded ? BoxShape.circle : BoxShape.rectangle,
              border: Border.all(color: context.colors.text.withValues(alpha: 0.15)),
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

/// Beats ⟷ Notes: how closely the project's scroll follows the notes, live in the score; a
/// drag is one Undo step.
class _ScrollFollowSlider extends StatelessWidget {
  const _ScrollFollowSlider({required this.controller});
  final EditorController controller;

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
            value: controller.scrollFollow,
            divisions: 20,
            label: '${(controller.scrollFollow * 100).round()}%',
            onChangeStart: (_) => controller.beginEdit(),
            onChanged: controller.setScrollFollow,
            onChangeEnd: (_) => controller.endEdit(),
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
          child: LinearProgressIndicator(value: progress, borderRadius: AppStyle.of(context).radius(2)),
        ),
      UpdateDownloaded(:final path) =>
        OutlinedButton(onPressed: () => revealInFileManager(path), child: Text(_revealLabel)),
      UpdateFailed(release: final release?) =>
        OutlinedButton(onPressed: () => updater.download(release), child: const Text('Try Again')),
    };
    return AnimatedSwitcher(duration: motion(context, 120), child: control);
  }
}

/// Opens [extension]'s own settings; greyed out when it has none.
class _ExtensionSettingsButton extends StatelessWidget {
  const _ExtensionSettingsButton(this.extension, this.settings);
  final CuratorExtension extension;
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
                  builder: (context) => AppDialog(
                    title: Text(extension.label),
                    content: Builder(builder: (context) => page(context, settings)),
                    actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
                  ),
                ),
        icon: Icon(AppIcon.settings.of(context)),
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
          icon: Icon(_copied ? AppIcon.check.of(context) : AppIcon.copy.of(context)),
        ),
      );
}

/// The app icon at the top of About. A click toggles the mascot in its place, everywhere the
/// app icon shows ([AppSettings.mascotIcon]).
class _AboutIcon extends StatelessWidget {
  const _AboutIcon(this.settings);
  final AppSettings settings;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => settings.mascotIcon = !settings.mascotIcon,
        child: AppLogo(settings: settings, size: 76),
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
              _AboutIcon(c.settings),
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
                decoration: BoxDecoration(color: _groupColor(context), borderRadius: AppStyle.of(context).radius(10)),
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
      decoration: BoxDecoration(color: _groupColor(context), borderRadius: BorderRadius.circular(20)), // a tag: a pill in Carbon too
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
