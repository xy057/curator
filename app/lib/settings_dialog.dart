import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart' show RenderStyle, TextKind, verovioVersion;

import 'app_colors.dart';
import 'app_icons.dart';
import 'app_logo.dart';
import 'app_settings.dart';
import 'color_dialog.dart';
import 'audio_panel.dart' show pickAudio;
import 'condensing_editor.dart';
import 'dialog_kit.dart';
import 'editor_controller.dart';
import 'engraving_settings.dart';
import 'extensions/extension.dart';
import 'export_dialog.dart' show revealInFileManager;
import 'file_names.dart';
import 'font_settings.dart';
import 'menu_kit.dart';
import 'motion_settings.dart';
import 'typography_settings.dart';
import 'project_state.dart' show NameGroupInfo;
import 'edit_dialogs.dart' show confirmSavePath, showNameGroupDialog;
import 'error_text.dart';
import 'settings_file.dart';
import 'sections_editor.dart';
import 'ui_kit.dart';
import 'updater.dart';
import 'l10n/l10n.dart';

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

/// Edit ▸ Project Settings… (⇧⌘,): the open project's own settings, laid out as Settings
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

/// Whether a settings window, app's or project's, is up (until it is gone, its fade-out
/// included): opening another then does nothing, so ⌘, held down doesn't stack them.
bool _windowShown = false;

Future<void> _showWindow(BuildContext context, _SettingsWindow window) {
  if (_windowShown) return Future.value();
  _windowShown = true;
  return _presentWindow(context, window);
}

Future<void> _presentWindow(BuildContext context, _SettingsWindow window) => showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close settings'.tr,
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
  const _Category(this.label, this.icon, this.items,
      {this.empty, this.page, this.preview = false, this.saveDefault, this.title})
      : tabs = null;

  /// One sidebar entry for several pages, chosen by a switch under its title; each can open in a
  /// window of its own ([_EngravingWindow]). Its items, every tab's, answer the search.
  _Category.tabbed(this.label, this.icon, List<_Category> this.tabs)
      : items = [for (final t in tabs) ...t.items],
        empty = null,
        page = null,
        preview = false,
        saveDefault = null,
        title = null;

  final String label;
  final AppIcon icon;
  final List<_Item> items;
  final List<_Category>? tabs;

  /// Its name in a window of its own (a tab's label may lean on the page's: "Advanced").
  final String? title;

  /// The score as engraved above the page's rows, staying put while they scroll: an engraving
  /// page's, while [AppSettings.engravingPreview] (Hide Preview, by the page's title).
  final bool preview;

  /// A page of its own in place of the rows of [items], which then only answer the search.
  final Widget Function(_Context)? page;

  /// Shown in place of the items while there are none.
  final String? empty;

  /// A project page whose settings can become the app's, for other projects: a slim Save as
  /// Default button beside the page's title, and Reset to Default before it.
  final _SaveDefault? saveDefault;
}

/// Save as Default on a project page: [isDefault] while the app's already match the project's;
/// [save] makes them so, and [reset] the project's the app's (one Undo step). Offered while
/// [shown] (null: always).
typedef _SaveDefault = ({
  bool Function(_Context)? shown,
  bool Function(_Context) isDefault,
  void Function(_Context) save,
  FutureOr<void> Function(_Context) reset,
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
      'Language',
      null,
      (c) => _Dropdown<AppLanguage>(
        value: c.settings.language,
        values: AppLanguage.values,
        label: (l) => l == AppLanguage.system ? 'System'.tr : l.label,
        onChanged: (v) => c.settings.language = v,
      ),
      keywords: 'language chinese english locale translation 语言 中文',
    ),
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
        label: (n) => '{n} steps'.fill({'n': n}),
        onChanged: (v) => c.settings.undoSteps = v,
      ),
      keywords: 'undo redo steps',
    ),
    _Item(
      'Align added recordings',
      (_) => 'When no anchors are set yet.',
      (c) => AppSwitch(value: c.settings.alignAddedRecordings, onChanged: (v) => c.settings.alignAddedRecordings = v),
      keywords: 'align sync automatic anchors recording audio import add',
    ),
    _Item(
      'Auto-curate imported scores',
      (_) => 'Off: every staff throughout.',
      (c) => AppSwitch(value: c.settings.autoCurateImported, onChanged: (v) => c.settings.autoCurateImported = v),
      keywords: 'auto curate lanes import new score staves automatic',
    ),
  ]),
  _Category('Appearance', AppIcon.appearance, [
    _Item(
      'Theme',
      (_) => 'Dark also turns the score dark.',
      (c) => Builder(builder: (context) => AppSegmented<ThemeMode>(
        segments: [
          ButtonSegment(value: ThemeMode.system, icon: Icon(AppIcon.auto.of(context), size: 16), label: Text('Auto'.tr)),
          ButtonSegment(value: ThemeMode.light, icon: Icon(AppIcon.light.of(context), size: 16), label: Text('Light'.tr)),
          ButtonSegment(value: ThemeMode.dark, icon: Icon(AppIcon.dark.of(context), size: 16), label: Text('Dark'.tr)),
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
        segments: [for (final s in UiStyle.values) ButtonSegment(value: s, label: Text(s.label.tr))],
        selected: c.settings.uiStyle,
        onChanged: (v) => c.settings.uiStyle = v,
      ),
      keywords: 'look controls switch button classic refined carbon ibm theme',
    ),
    _Item(
      'Text size',
      null,
      (c) => AppSegmented<TextSize>(
        segments: [for (final s in TextSize.values) ButtonSegment(value: s, label: Text(s.label.tr))],
        selected: c.settings.textSize,
        onChanged: (v) => c.settings.textSize = v,
      ),
      keywords: 'font type bigger smaller larger scale zoom accessibility',
    ),
    _Item(
      'Density',
      null,
      (c) => AppSegmented<UiDensity>(
        segments: [for (final d in UiDensity.values) ButtonSegment(value: d, label: Text(d.label.tr))],
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
    _Item('Website', null, (_) => const _Link(websiteUrl), keywords: 'website home page official site web open'),
    _Item('Changelog', null, (_) => const _Link(changelogUrl), keywords: 'changelog changes release notes what\'s new history website open'),
    _Item('Source code', null, (_) => const _Link(repositoryUrl), keywords: 'github repository repo source code website open'),
    _Item('License', null, (_) => const _Link(licenseUrl, label: 'GPL-3.0'), keywords: 'license gpl copyright about'),
    _Item('Verovio', null, (_) => _Value(verovioVersion), keywords: 'engraver engine library about'),
    _Item('System', null, (_) => _Value(_systemText), keywords: 'os macos windows linux architecture about'),
  ]),
];

/// The open project's settings (Edit ▸ Project Settings…): each change an edit.
final _projectCategories = <_Category>[
  _Category('Project Info', AppIcon.about, [
    _Item(
      'Score',
      (c) => c.controller!.fileName ?? '',
      (c) => OutlinedButton(onPressed: c.replaceScore, child: Text('Replace…'.tr)),
      keywords: 'replace score file musicxml mei import',
    ),
    _Item(
      'Recording',
      (c) => c.controller!.track?.name ?? 'None.'.tr,
      (c) => Builder(builder: (context) {
        final controller = c.controller!, busy = controller.isLoadingAudio;
        return Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: [
          if (controller.track != null)
            OutlinedButton(onPressed: busy ? null : controller.removeAudio, child: Text('Remove'.tr)),
          OutlinedButton(
            onPressed: busy ? null : () => pickAudio(context, controller),
            child: Text((controller.track == null ? 'Add…' : 'Replace…').tr),
          ),
        ]);
      }),
      keywords: 'add remove delete recording audio file video sound',
    ),
  ]),
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
        0 => 'Glides from beat to beat: the speed changes only with the tempo.'.tr,
        1 => 'Every note is under the playhead exactly as it sounds: slower through long notes, quicker through runs.'.tr,
        final f => 'A blend: the beats land on time, and the speed follows the notes {percent}% of the way.'
            .fill({'percent': (f * 100).round()}),
      },
      (c) => _ScrollFollowSlider(controller: c.controller!),
      keywords: 'scroll speed smooth snap note beat follow onset glide motion pointer',
    ),
    _Item(
      'Bar numbers',
      null,
      (c) => AppSwitch(value: c.controller!.barNumbers, onChanged: c.controller!.setBarNumbers),
      keywords: 'bar measure numbers numbering count tempo row',
    ),
  ], saveDefault: (
    shown: null,
    isDefault: _animationIsDefault,
    save: (c) => c.settings
      ..transition = c.controller!.curation!.transition
      ..scrollFollow = c.controller!.scrollFollow,
    reset: (c) => c.controller!
      ..setTransition(c.settings.transition)
      ..setScrollFollow(c.settings.scrollFollow),
  )),
  _Category.tabbed('Engraving', AppIcon.music, [_engravingCategory(), _typographyCategory(), _advancedEngravingCategory()]),
  _Category('Instruments', AppIcon.score, page: (c) => _InstrumentsPage(c), [
    _Item(
      'Playback line color',
      null,
      (c) => _PlayheadColor(c.controller!),
      keywords: 'color colour playback line playhead pointer cursor position score video',
    ),
    _Item(
      'Color names',
      null,
      (c) => AppSwitch(value: c.controller!.colorNames, onChanged: c.controller!.setColorNames),
      keywords: 'color colour names labels instrument family section group woodwinds brass strings percussion',
    ),
    _Item('Groups', null, (_) => const SizedBox.shrink(),
        keywords: 'color colour group groups add remove rename family woodwinds brass strings percussion'),
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
    _Item(
      'Rehearsal marks in bar numbers',
      (_) => 'With bar numbers, shows rehearsal marks beside them, out of the music.',
      (c) => AppSwitch(value: c.controller!.rehearsalInRow, onChanged: c.controller!.setRehearsalInRow),
      keywords: 'flag rehearsal marks letters box bar numbers row',
    ),
    _Item(
      'Centered lyrics',
      (_) => 'Centers syllables under their notes.',
      (c) => AppSwitch(value: c.controller!.centeredLyrics, onChanged: c.controller!.setCenteredLyrics),
      keywords: 'flag lyrics syllables words text centre center align alignment choral',
    ),
  ], saveDefault: (
    shown: null,
    isDefault: _flagsAreDefault,
    save: (c) {
      c.settings
        ..textDynamics = c.controller!.textDynamics
        ..rehearsalInRow = c.controller!.rehearsalInRow
        ..centeredLyrics = c.controller!.centeredLyrics;
    },
    reset: (c) => c.controller!.setFlags(
        textDynamics: c.settings.textDynamics,
        rehearsalInRow: c.settings.rehearsalInRow,
        centeredLyrics: c.settings.centeredLyrics),
  )),
  _advancedCategory(),
];

/// Project Settings ▸ Advanced: how the score moves, every curve and length of time in it
/// ([MotionSetting.all]), each over the app's default (Save as default).
_Category _advancedCategory() {
  MotionTarget target(_Context c) => MotionTarget(c.settings, c.controller!);
  return _Category(
    'Advanced',
    AppIcon.settings,
    saveDefault: (
      shown: null,
      isDefault: (c) => target(c).isDefault,
      save: (c) => target(c).saveAsDefault(),
      reset: (c) => target(c).resetToDefault(),
    ),
    [
      for (final s in MotionSetting.all)
        _Item(
          s.title,
          null,
          (c) => MotionControl(target: target(c), setting: s),
          group: s.group,
          shown: switch (s.group) {
            MotionSetting.captions => (c) => c.controller!.captions.enabled,
            MotionSetting.barNumbers => (c) => c.controller!.barNumbers,
            _ => null,
          },
          keywords: 'animation motion curve easing equation ${s.group} ${s.keywords}',
        ),
    ],
  );
}

/// Project Settings ▸ Engraving ▸ Typography: how each kind of text in the score looks ([TypographySetting.all]),
/// over the app's default (Save as default), under the score as it shows them.
_Category _typographyCategory() {
  TypographyTarget target(_Context c) => TypographyTarget(c.settings, c.controller!);
  return _Category(
    'Typography',
    AppIcon.fonts,
    preview: true,
    saveDefault: (
      shown: null,
      isDefault: (c) => target(c).isDefault,
      save: (c) => target(c).saveAsDefault(),
      reset: (c) => target(c).resetToDefault(),
    ),
    [
      for (final s in TypographySetting.all)
        _Item(
          s.title,
          null,
          (c) => TypographyControl(target: target(c), setting: s),
          group: s.group,
          shown: switch (s.kind) {
            TextKind.captions => (c) => c.controller!.captions.enabled,
            TextKind.barNumbers || TextKind.tempoRow => (c) => c.controller!.barNumbers,
            _ => null,
          },
          keywords: 'font text type typography engraving ${s.kind.label} ${s.kind.isSymbol ? 'music symbol smufl glyph ' : ''}${s.keywords}',
        ),
    ],
  );
}

/// Project Settings ▸ Engraving ▸ Advanced: every other engraving option ([EngravingSetting.advanced]),
/// by plain name as on Engraving, under the same preview; Save as default is Engraving's too.
_Category _advancedEngravingCategory() {
  EngravingTarget target(_Context c) => EngravingTarget(c.settings, c.controller!);
  return _Category(
    'Advanced',
    AppIcon.general,
    title: 'Advanced Engraving',
    preview: true,
    saveDefault: (
      shown: null,
      isDefault: (c) => target(c).isDefault,
      save: (c) => target(c).saveAsDefault(),
      reset: (c) => target(c).resetToDefault(),
    ),
    [
      for (final s in EngravingSetting.advanced)
        _Item(
          s.title,
          null,
          (c) => EngravingControl(target: target(c), setting: s),
          group: s.group,
          keywords: 'engrave engraving advanced verovio ${s.group} ${s.keywords} ${s.key}',
        ),
    ],
  );
}

/// Whether the project's flags are the app's default (Save as default).
bool _flagsAreDefault(_Context c) =>
    c.controller!.textDynamics == c.settings.textDynamics &&
    c.controller!.rehearsalInRow == c.settings.rehearsalInRow &&
    c.controller!.centeredLyrics == c.settings.centeredLyrics;

/// Whether the project's animation is the app's default (Save as default).
bool _animationIsDefault(_Context c) =>
    c.settings.transition == c.controller!.curation!.transition && c.settings.scrollFollow == c.controller!.scrollFollow;

/// How many of the score's pairs share a staff.
String _condensedText(_Context c) {
  final pairs = c.controller!.condensable;
  return '{shared} of {all} share a staff.'
      .fill({'shared': pairs.where((p) => c.controller!.condensed.contains(p.id)).length, 'all': pairs.length});
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
                help: controller.pairs.contains(pair) ? 'Yours.'.tr : null,
                control: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (controller.pairs.contains(pair)) ...[
                    ToolbarButton(
                      icon: AppIcon.close.of(context),
                      tooltip: 'Remove pair'.tr,
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

/// Project Settings ▸ Engraving ▸ Engraving: the fonts and the options most scores want changed
/// ([EngravingSetting.all]) under a preview of the score, every other one on the Advanced tab,
/// and Save as default (the app's, for other projects).
_Category _engravingCategory() {
  EngravingTarget target(_Context c) => EngravingTarget(c.settings, c.controller!);
  return _Category(
    'Engraving',
    AppIcon.music,
    preview: true,
    saveDefault: (
      shown: null,
      isDefault: (c) => target(c).isDefault,
      save: (c) => target(c).saveAsDefault(),
      reset: (c) => target(c).resetToDefault(),
    ),
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
    ],
  );
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
      UpdateIdle() => 'From GitHub.'.tr,
      UpdateChecking() => 'Checking…'.tr,
      UpToDate() => 'Curator is up to date! ☆'.tr,
      UpdateAvailable(:final release) when release.download == null =>
        'Curator {version} is out, but not for this system yet.'.fill({'version': release.version}),
      UpdateAvailable(:final release) => 'Curator {version} is available! ☆'.fill({'version': release.version}),
      UpdateDownloading(:final release) => 'Downloading {version}…'.fill({'version': release.version}),
      UpdateDownloaded(:final path) => '${'Saved “{name}”.'.fill({'name': fileNameOf(path)})} '
          '${(Platform.isWindows ? 'Close Curator, then replace its folder with the unzipped one.' : 'Unzip it and replace this app with it.').tr}',
      UpdateFailed(:final message) => message.tr,
    };

String _autosaveLabel(Duration d) => switch (d) {
      Duration.zero => 'Off'.tr,
      Duration(inMinutes: 0, :final inSeconds) => 'Every {n} seconds'.fill({'n': inSeconds}),
      Duration(inMinutes: 1) => 'Every minute'.tr,
      Duration(:final inMinutes) => 'Every {n} minutes'.fill({'n': inMinutes}),
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
  static final _lastTabs = <String, int>{}; // a tabbed page's tab, by its label
  late final _categories = widget.kind.categories;
  late int _page = _lastPage = _open(widget.page) ?? _lastPage;

  /// The page named [name] (a page's label, or a tab's label or title, choosing the tab).
  int? _open(String? name) {
    for (final (i, c) in _categories.indexed) {
      if (c.label == name) return i;
      final tab = c.tabs?.indexWhere((t) => t.label == name || t.title == name) ?? -1;
      if (tab >= 0) {
        _lastTabs[c.label] = tab;
        return i;
      }
    }
    return null;
  }

  /// [cat]'s tab shown, or [cat] itself.
  _Category _tabOf(_Category cat) => cat.tabs?[_lastTabs[cat.label] ?? 0] ?? cat;

  /// [tab] in a window of its own, over the editor, in place of this one.
  void _popOut(_Category tab) {
    final overlay = Overlay.of(context, rootOverlay: true);
    Navigator.pop(context);
    _EngravingWindow.show(
        overlay, tab, (settings: widget.settings, controller: widget.controller, updater: Updater(), replaceScore: null));
  }
  final _search = TextEditingController();

  int get _lastPage => _lastPages[widget.kind] ?? 0;
  set _lastPage(int page) => _lastPages[widget.kind] = page;

  @override
  void dispose() {
    widget.controller?.removeListener(_controllerChanged);
    _search.dispose();
    _windowShown = false;
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
          if (_searched(cat, item).toLowerCase().contains(q)) (cat, item),
    ];
  }

  /// What the search looks in: [item]'s words in English and as shown.
  String _searched(_Category cat, _Item item) {
    final help = item.help?.call(_ctx) ?? '';
    return '${cat.label} ${cat.label.trIn('page')} ${item.title} ${item.title.tr} ${item.group?.tr ?? ''} ${item.keywords} $help ${help.tr}';
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

  Iterable<_Item> _shownItems(_Category cat) => _shown(cat, _ctx);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final size = MediaQuery.sizeOf(context);
    final refined = AppStyle.of(context).style == UiStyle.refined;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 760, maxHeight: (size.height - 64).clamp(360, 500)),
        child: Material(
          color: Theme.of(context).dialogTheme.backgroundColor,
          // Refined: a dialog's elevation, the top one.
          elevation: refined ? 24 : 16,
          shadowColor: refined ? Theme.of(context).dialogTheme.shadowColor : Colors.black.withValues(alpha: 0.14),
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
                    // Refined: the sidebar's tone alone parts it from the page, no line as well.
                    if (AppStyle.of(context).isCarbon) VerticalDivider(width: 1, color: colors.line),
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
              hintText: 'Search'.tr,
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
            label: cat.label.trIn('page'),
            selected: !searching && i == _page,
            onTap: () {
              _search.clear();
              setState(() => _page = _lastPage = i);
            },
          ),
        const Spacer(),
        if (widget.kind == _Window.project && widget.controller != null) _SettingsFileButtons(widget.controller!),
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
    // A tabbed page: its tab's rows, preview and Save as Default under the page's title.
    final tab = _tabOf(cat);
    final tabs = cat.tabs;
    Widget page;
    if (matches == null && cat.page != null) {
      page = KeyedSubtree(key: ValueKey(_page), child: cat.page!(_ctx));
    } else if (matches == null) {
      page = _pageBody(context, tab, _ctx,
          key: ValueKey(_page),
          rowsKey: ValueKey((_page, tab.label)),
          above: tabs == null
              ? null
              : Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                  child: Center(
                    child: AppSegmented<int>(
                      segments: [for (final (i, t) in tabs.indexed) ButtonSegment(value: i, label: Text(t.label.tr))],
                      selected: tabs.indexOf(tab),
                      onChanged: (i) => setState(() => _lastTabs[cat.label] = i),
                    ),
                  ),
                ));
    } else {
      // One group per page, in sidebar order, each under its page's name.
      page = _Page(
        key: const ValueKey('search'),
        empty: matches.isEmpty
            ? widget.kind == _Window.project
                ? 'Try another word, such as “font” or “transition”.'.tr
                : 'Try another word, such as “theme” or “update”.'.tr
            : null,
        groups: [
          for (final c in _categories)
            if (matches.where((m) => m.$1 == c).toList() case final inCat when inCat.isNotEmpty)
              (c.label.trIn('page'), [
                for (final (_, item) in inCat) _row(item, withGroup: c.items.where((i) => i.title == item.title).length > 1),
              ]),
        ],
      );
    }
    final colors = context.colors;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The header stays put while the page under it changes.
      Container(
        height: 52,
        padding: const EdgeInsets.only(left: 28, right: 10),
        child: _TitleBar(
            title: matches == null
                ? cat.label.trIn('page')
                : matches.isEmpty
                    ? 'No matching settings'.tr
                    : 'Search results'.tr,
            buttons: [
          if (matches == null && tabs != null)
            _HeaderIcon(tooltip: 'Open in Window'.tr, icon: AppIcon.popOut, onPressed: () => _popOut(tab)),
          if (matches == null) ..._pageButtons(context, tab, _ctx),
          if (widget.kind == _Window.project && (widget.controller?.isReengraving ?? false))
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          _HeaderIcon(tooltip: 'Close'.tr, icon: AppIcon.close, onPressed: () => Navigator.pop(context)),
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

  Widget _row(_Item item, {bool withGroup = false}) => _rowOf(item, _ctx, withGroup: withGroup);
}

Iterable<_Item> _shown(_Category cat, _Context ctx) => cat.items.where((item) => item.shown?.call(ctx) ?? true);

// Keyed, so a control keeps its state when a row above it comes or goes (`shown`). Found by a
// search, away from its heading, a row whose title its page repeats names its group
// ("Size · Lyrics").
Widget _rowOf(_Item item, _Context ctx, {bool withGroup = false}) => _SettingRow(
    key: ObjectKey(item),
    title: withGroup && item.group != null ? '${item.title.tr} · ${item.group!.tr}' : item.title,
    note: item.note,
    help: item.help?.call(ctx),
    control: item.control(ctx));

/// [cat]'s rows under their headings, with [above] them a tabbed page's switch and an engraving
/// page's preview. Shown or hidden, the rows stay where they are: the same tree, keeping their
/// scroll ([rowsKey] tells one page's rows from another's).
Widget _pageBody(BuildContext context, _Category cat, _Context ctx,
    {required Key key, required Key rowsKey, Widget? above}) {
  final groups = <(String?, List<Widget>)>[];
  for (final item in _shown(cat, ctx)) {
    if (groups.isEmpty || groups.last.$1 != item.group) groups.add((item.group, []));
    groups.last.$2.add(_rowOf(item, ctx));
  }
  final rows = _Page(key: rowsKey, empty: cat.empty, groups: groups);
  if (!cat.preview && above == null) return KeyedSubtree(key: key, child: rows);
  final colors = context.colors;
  final preview = cat.preview && ctx.settings.engravingPreview;
  return Column(key: key, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    ?above,
    if (preview) ...[
      if (above != null) Divider(height: 1, color: colors.line),
      SizedBox(height: 170, child: EngravingPreviewHost(settings: ctx.settings, controller: ctx.controller, scale: 0.5)),
    ],
    if (above != null || preview) Divider(height: 1, color: colors.line),
    Expanded(key: const ValueKey('rows'), child: rows),
  ]);
}

/// By a page's title: Hide Preview on an engraving page, and Save as Default.
List<Widget> _pageButtons(BuildContext context, _Category cat, _Context ctx) {
  final settings = ctx.settings;
  final save = cat.saveDefault;
  return [
    if (cat.preview)
      _HeaderIcon(
        tooltip: settings.engravingPreview ? 'Hide Preview' : 'Show Preview',
        icon: settings.engravingPreview ? AppIcon.noImage : AppIcon.image,
        onPressed: () => settings.engravingPreview = !settings.engravingPreview,
      ),
    if (save != null && (save.shown?.call(ctx) ?? true))
      _SaveDefaultButton(
        isDefault: save.isDefault(ctx),
        onPressed: () => save.save(ctx),
        // The page's settings back to the app's defaults: one Undo step however many it changes.
        onReset: () async {
          final controller = ctx.controller!..beginEdit();
          try {
            await save.reset(ctx);
          } finally {
            controller.endEdit();
          }
        },
      ),
  ];
}

/// A page's title, and its buttons at the right: made smaller, not overflowing, when the line
/// can't hold them (a wider font, a longer title).
class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.title, required this.buttons});
  final String title;
  final List<Widget> buttons;

  @override
  Widget build(BuildContext context) => Row(children: [
        Text(title.tr, maxLines: 1, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: context.colors.text)),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Row(mainAxisSize: MainAxisSize.min, children: buttons),
          ),
        ),
      ]);
}

/// At the foot of Project Settings' sidebar: Import… and Export… the score-wide settings as a
/// settings file ([SettingsFile]), for other projects. An import is one Undo step.
class _SettingsFileButtons extends StatelessWidget {
  const _SettingsFileButtons(this.controller);
  final EditorController controller;

  static List<XTypeGroup> get _types => [XTypeGroup(label: 'Curator settings'.tr, extensions: const [SettingsFile.extension])];

  Future<void> _import(BuildContext context) async {
    final file = await openFile(acceptedTypeGroups: _types);
    if (file == null || !context.mounted) return;
    await _guard(context, 'Couldn’t Import Settings'.tr, () async {
      final (:settings, :olderFormat) = await SettingsFile.read(file.path);
      await controller.importSettings(settings);
      // Applied: Export writes them in the new format.
      if (olderFormat && context.mounted) await _tell(context, 'Settings Imported'.tr, 'This file is a little old. Export again to update it.'.tr);
    });
  }

  Future<void> _export(BuildContext context) async {
    final location = await getSaveLocation(
        acceptedTypeGroups: _types, suggestedName: '${stemOf(controller.fileName ?? 'Settings'.tr)}.${SettingsFile.extension}');
    if (location == null || !context.mounted) return;
    final path = await confirmSavePath(context, location.path, SettingsFile.extension);
    if (path == null || !context.mounted) return;
    await _guard(context, 'Couldn’t Export Settings'.tr, () => SettingsFile.write(path, controller.exportedSettings));
  }

  static Future<void> _guard(BuildContext context, String title, Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (context.mounted) await _tell(context, title, describeError(e));
    }
  }

  static Future<void> _tell(BuildContext context, String title, String message) => showAppDialog<void>(
        context: context,
        builder: (context) => AppDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(message)),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text('OK'.tr))],
        ),
      );

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Wrap(spacing: 2, children: [
          TextButton(onPressed: () => _import(context), child: Text('Import…'.tr)),
          TextButton(onPressed: () => _export(context), child: Text('Export…'.tr)),
        ]),
      );
}

/// A page title's icon button: muted, 32 points square.
class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({required this.tooltip, required this.icon, required this.onPressed});
  final String tooltip;
  final AppIcon icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip.tr,
        iconSize: 18,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        color: context.colors.textMuted,
        onPressed: onPressed,
        icon: Icon(icon.of(context)),
      );
}

/// A tab of Project Settings ▸ Engraving in a window of its own, floating over the editor (which
/// stays usable: the score re-engraves behind it), moved by its title. One at a time; it closes
/// with its Close or Escape, or when the project does.
class _EngravingWindow extends StatefulWidget {
  const _EngravingWindow({required this.page, required this.ctx, required this.onClose});
  final _Category page;
  final _Context ctx;
  final VoidCallback onClose;

  static OverlayEntry? _shown;

  static void show(OverlayState overlay, _Category page, _Context ctx) {
    close();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _EngravingWindow(
        page: page,
        ctx: ctx,
        onClose: () {
          if (_shown != entry) return;
          _shown = null;
          entry.remove();
        },
      ),
    );
    overlay.insert(_shown = entry);
  }

  static void close() {
    _shown?.remove();
    _shown = null;
  }

  @override
  State<_EngravingWindow> createState() => _EngravingWindowState();
}

class _EngravingWindowState extends State<_EngravingWindow> {
  static const _width = 560.0;

  /// Its top left, once moved: at first by the editor's right edge, under the toolbar.
  Offset? _at;

  EditorController get _controller => widget.ctx.controller!;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_controllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_controllerChanged);
    super.dispose();
  }

  void _controllerChanged() {
    if (_controller.score == null) WidgetsBinding.instance.addPostFrameCallback((_) => widget.onClose());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final size = MediaQuery.sizeOf(context);
    final height = math.min(620.0, size.height - 96);
    Offset clamp(Offset o) =>
        Offset(o.dx.clamp(0, math.max(0, size.width - _width)), o.dy.clamp(0, math.max(0, size.height - 52)));
    final at = clamp(_at ?? Offset(size.width - _width - 24, 72));
    final page = widget.page;
    final ctx = widget.ctx;
    final title = _TitleBar(title: page.title ?? page.label.trIn('page'), buttons: [
      ..._pageButtons(context, page, ctx),
      if (_controller.isReengraving)
        const Padding(
          padding: EdgeInsets.only(right: 8),
          child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      _HeaderIcon(tooltip: 'Close'.tr, icon: AppIcon.close, onPressed: widget.onClose),
    ]);
    return Positioned(
      left: at.dx,
      top: at.dy,
      width: _width,
      height: height,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.onClose},
        child: FocusScope(
          // Apart from the editor's frames: playback repaints the score under it every frame.
          child: RepaintBoundary(
            child: Material(
              color: Theme.of(context).dialogTheme.backgroundColor,
              elevation: 16,
              shadowColor: Colors.black.withValues(alpha: 0.2),
              animationDuration: Duration.zero,
              shape: AppStyle.of(context).isCarbon
                  ? const RoundedRectangleBorder()
                  : RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: colors.line)),
              clipBehavior: Clip.antiAlias,
              child: ListenableBuilder(
                listenable: Listenable.merge([ctx.settings, _controller]),
                builder: (context, _) => _controller.score == null
                    ? const SizedBox.shrink()
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        // Moved by its title, as a window is.
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanUpdate: (d) => setState(() => _at = clamp(at + d.delta)),
                          child: Container(height: 52, padding: const EdgeInsets.only(left: 24, right: 10), child: title),
                        ),
                        Divider(height: 1, color: colors.line),
                        Expanded(
                          child: _pageBody(context, page, ctx, key: const ValueKey('page'), rowsKey: const ValueKey('rows')),
                        ),
                      ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The sidebar's neutral tint: a step off the dialog's surface, without the accent, strong enough
/// to stand without a dividing line (light: the well, a step past the nearly white chrome); in
/// Carbon the modal's own $layer-01.
Color _sidebarColor(BuildContext context) {
  final colors = context.colors;
  if (CarbonColors.maybeOf(context) case final k?) return k.layer01;
  return _lightChrome(colors) ? colors.well : Color.lerp(colors.surface, colors.line, 0.32)!;
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
    // Refined: the accent's light tint, as a chosen segment's, the label in the accent and
    // semibold (the solid accent is left for the default button). Carbon: its side nav's item,
    // $layer-selected with a 3 px bar of the accent at its left, the text semibold.
    final tinted = k == null && selected;
    final fill = k != null
        ? (selected ? k.layerSelected : _hover ? k.layerHover : k.layerHover.withValues(alpha: 0))
        : tinted
            ? colors.accentSoft
            : _hover
                ? colors.line.withValues(alpha: 0.45)
                : colors.line.withValues(alpha: 0);
    final ink = k != null
        ? (selected || _hover ? k.textPrimary : k.textSecondary)
        : tinted
            ? colors.accentOn(fill, dark: Theme.of(context).brightness == Brightness.dark)
            // The rows not chosen a step quieter, so the chosen one stands out without more weight.
            : _hover
                ? colors.text
                : Color.lerp(colors.text, colors.textMuted, 0.4)!;
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
                Icon(widget.icon, size: 16, color: k != null || tinted ? ink : colors.textMuted),
                SizedBox(width: k != null ? 8 : 10),
                Flexible(
                  child: Text(widget.label.tr,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: k != null ? 14 : 13,
                        letterSpacing: k != null ? 0.16 : null,
                        color: ink,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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
  const _SaveDefaultButton({required this.isDefault, required this.onPressed, required this.onReset});
  final bool isDefault;
  final VoidCallback onPressed;

  /// Reset to Default: the page as the app's defaults (shown only while it differs).
  final VoidCallback onReset;

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
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (!isDefault) ...[
          Tip(
            message: 'Use the saved defaults here'.tr,
            child: OutlinedButton(style: style, onPressed: onReset, child: Text('Reset to Default'.tr)),
          ),
          const SizedBox(width: 6),
        ],
        Tip(
          message: isDefault ? 'Other projects start with these' : 'Use these for other projects',
          child: isDefault
              ? OutlinedButton.icon(
                  style: style.copyWith(side: const WidgetStatePropertyAll(BorderSide(color: Colors.transparent))),
                  onPressed: null,
                  icon: Icon(AppIcon.check.of(context), size: 13),
                  label: Text('Default'.tr),
                )
              : OutlinedButton(style: style, onPressed: onPressed, child: Text('Save as Default'.tr)),
        ),
      ]),
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
      // Every row laid out and in the accessibility tree, however far down: a row past the
      // cache would be dropped from it, but not its slider's overlay (see OverlaySemantics).
      scrollCacheExtent: const ScrollCacheExtent.pixels(double.maxFinite),
      children: [
        for (final (i, (heading, rows)) in groups.indexed) ...[
          if (i > 0) const SizedBox(height: 18),
          if (heading != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(heading.tr,
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
            child: Text(empty!.tr, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: colors.textMuted)),
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
                TextSpan(text: title.tr, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: colors.text)),
                if (note != null) TextSpan(text: '  $note', style: TextStyle(fontSize: 11.5, color: colors.textMuted)),
              ])),
              if (help != null) ...[
                const SizedBox(height: 2),
                AnimatedSwitcher(
                  duration: motion(context, 120),
                  layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                  child: Text(help!.tr, key: ValueKey(help), style: TextStyle(fontSize: 12, height: 1.35, color: colors.textMuted)),
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
        items: [for (final v in values) DropdownMenuItem(value: v, child: Text(label(v).tr))],
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

/// Project Settings ▸ Instruments: Color names, then the groups (the families', which stay, and
/// the user's, added, renamed and removed here), each a colour; then which group each
/// instrument is in.
class _InstrumentsPage extends StatelessWidget {
  const _InstrumentsPage(this.c);
  final _Context c;

  @override
  Widget build(BuildContext context) {
    final controller = c.controller!;
    final groups = controller.nameGroups;
    final parts = controller.laneParts;
    int members(String id) => parts.where((p) => controller.nameGroupOf(p) == id).length;
    return _Page(groups: [
      (null, [
        _SettingRow(title: 'Playback line color', help: null, control: _PlayheadColor(controller)),
        _SettingRow(
            title: 'Color names',
            help: null,
            control: AppSwitch(value: controller.colorNames, onChanged: controller.setColorNames)),
      ]),
      if (controller.colorNames) ...[
        ('Groups', [
          for (final g in groups)
            _SettingRow(
              key: ValueKey(g.id),
              title: g.name,
              note: switch (members(g.id)) { 0 => null, final n => '$n' },
              help: null,
              control: Row(mainAxisSize: MainAxisSize.min, children: [
                if (g.family == null) ...[
                  TextButton(
                    onPressed: () async {
                      final name = await showNameGroupDialog(context, rename: g.name);
                      if (name != null) controller.renameNameGroup(g.id, name);
                    },
                    child: Text('Rename…'.tr),
                  ),
                  ToolbarButton(
                    icon: AppIcon.close.of(context),
                    tooltip: 'Remove group'.tr,
                    onPressed: () => controller.removeNameGroup(g.id),
                  ),
                ] else if (controller.ownNameGroupColor(g.id))
                  IconButton(
                    icon: Icon(AppIcon.reset.of(context), size: 15),
                    tooltip: 'Reset'.tr,
                    visualDensity: VisualDensity.compact,
                    color: context.colors.textMuted,
                    onPressed: () => controller.setNameGroupColor(g.id, null),
                  ),
                const SizedBox(width: 8),
                _ColorSwatch(
                  color: g.color,
                  title: g.name,
                  onChanged: (color) => controller.setNameGroupColor(g.id, color),
                ),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: Icon(AppIcon.add.of(context), size: 16),
                label: Text('Add Group…'.tr),
                onPressed: () async {
                  final name = await showNameGroupDialog(context);
                  if (name != null) controller.addNameGroup(name);
                },
              ),
            ),
          ),
        ]),
        ('Instruments', [
          for (final part in parts)
            _SettingRow(
              key: ValueKey(part.id),
              title: controller.laneName(part),
              help: null,
              control: Row(mainAxisSize: MainAxisSize.min, children: [
                if (controller.ownNameGroup(part))
                  IconButton(
                    icon: Icon(AppIcon.reset.of(context), size: 15),
                    tooltip: 'Reset'.tr,
                    visualDensity: VisualDensity.compact,
                    color: context.colors.textMuted,
                    onPressed: () => controller.resetNameGroup(part),
                  ),
                const SizedBox(width: 6),
                SettingsDropdown<String>(
                  value: controller.nameGroupOf(part) ?? '',
                  width: 170,
                  items: [
                    for (final g in groups)
                      DropdownMenuItem(value: g.id, child: _GroupLabel(g)),
                    DropdownMenuItem(value: '', child: Text('None'.tr)),
                  ],
                  onChanged: (id) => controller.setNameGroup(part, id.isEmpty ? null : id),
                ),
              ]),
            ),
        ]),
      ],
    ]);
  }
}

/// The playback line's colour (over the score, in the video too): its own blue until one is chosen,
/// which Reset gives back.
class _PlayheadColor extends StatelessWidget {
  const _PlayheadColor(this.controller);
  final EditorController controller;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        if (controller.playheadColor != null)
          IconButton(
            icon: Icon(AppIcon.reset.of(context), size: 15),
            tooltip: 'Reset'.tr,
            visualDensity: VisualDensity.compact,
            color: context.colors.textMuted,
            onPressed: () => controller.setPlayheadColor(null),
          ),
        const SizedBox(width: 8),
        _ColorSwatch(
          color: controller.playheadColor ?? const RenderStyle().pointer,
          title: 'Playback line',
          onChanged: controller.setPlayheadColor,
        ),
      ]);
}

/// A group in a menu: its colour, then its name.
class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.group);
  final NameGroupInfo group;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
              color: group.color, shape: AppStyle.of(context).rounded ? BoxShape.circle : BoxShape.rectangle),
        ),
        const SizedBox(width: 8),
        Flexible(child: Text(group.name.tr, overflow: TextOverflow.ellipsis)),
      ]);
}

/// A colour that asks for another when clicked.
class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.color, required this.title, required this.onChanged});
  final Color color;
  final String title;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () async {
          final chosen = await showColorDialog(context, initial: color, title: title);
          if (chosen != null) onChanged(chosen);
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color,
              shape: AppStyle.of(context).rounded ? BoxShape.circle : BoxShape.rectangle,
              border: Border.all(color: context.colors.text.withValues(alpha: 0.15)),
            ),
          ),
        ),
      );
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
      Text('Beats'.tr, style: label),
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
      Text('Notes'.tr, style: label),
      SliderValueField(
          value: controller.scrollFollow,
          min: 0,
          max: 1,
          scale: 100,
          width: 52,
          format: (v) => '${(v * 100).round()}%',
          onChanged: controller.setScrollFollow),
    ]);
  }
}

/// Check, then Download, then Show in Finder: the one button the update's state calls for.
class _UpdateControl extends StatelessWidget {
  const _UpdateControl({required this.updater});
  final Updater updater;

  static String get _revealLabel => (Platform.isMacOS
          ? 'Show in Finder'
          : Platform.isWindows
              ? 'Show in Explorer'
              : 'Open Folder')
      .tr;

  @override
  Widget build(BuildContext context) {
    final check = OutlinedButton(onPressed: updater.check, child: Text('Check for Updates'.tr));
    final Widget control = switch (updater.status) {
      UpdateIdle() || UpToDate() || UpdateFailed(release: null) => check,
      UpdateChecking() => const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      UpdateAvailable(:final release) when release.download == null =>
        OutlinedButton(onPressed: () => openInBrowser(release.pageUrl), child: Text('Open Release Page'.tr)),
      UpdateAvailable(:final release) =>
        FilledButton(onPressed: () => updater.download(release), child: Text('Download {version}'.fill({'version': release.version}))),
      UpdateDownloading(:final progress) => SizedBox(
          width: 140,
          child: LinearProgressIndicator(value: progress, borderRadius: AppStyle.of(context).radius(2)),
        ),
      UpdateDownloaded(:final path) =>
        OutlinedButton(onPressed: () => revealInFileManager(path), child: Text(_revealLabel)),
      UpdateFailed(release: final release?) =>
        OutlinedButton(onPressed: () => updater.download(release), child: Text('Try Again'.tr)),
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
                    title: Text(extension.label.tr),
                    content: Builder(builder: (context) => page(context, settings)),
                    actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text('Done'.tr))],
                  ),
                ),
        icon: Icon(AppIcon.settings.of(context)),
      ),
    );
  }
}

/// An address that opens in the browser, shown without its scheme or `#` part.
class _Link extends StatelessWidget {
  const _Link(this.url, {this.label, this.accent = false});
  final String url;
  final String? label;

  /// In the accent and a little larger: the website under About's title.
  final bool accent;

  @override
  Widget build(BuildContext context) => Tip(
        message: 'Open in the browser'.tr,
        child: TextButton(
          onPressed: () => openInBrowser(url),
          // The website's lines up with the text above it.
          style: accent
              ? TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 28), tapTargetSize: MaterialTapTargetSize.shrinkWrap)
              : null,
          child: Text(
            label ?? url.replaceFirst('https://', '').split('#').first.replaceFirst(RegExp(r'/$'), ''),
            style: TextStyle(fontSize: accent ? 14 : 13, color: accent ? _linkColor(context) : null),
          ),
        ),
      );
}

/// The accent as text on the page: its strong shade in the light.
Color _linkColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? context.colors.accent : context.colors.accentStrong;

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
        message: 'Copy'.tr,
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
        child: AppLogo(settings: settings, size: 84),
      );
}

/// Settings ▸ About: the icon, and beside it the name, version and website; the updates, then
/// the other links, each a group; Verovio and the system at the foot (with the mascot's credit
/// while it shows).
class _AboutPage extends StatelessWidget {
  const _AboutPage(this.c);
  final _Context c;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final muted = TextStyle(fontSize: 12, color: colors.textMuted);
    Widget group(List<Widget> rows) => DecoratedBox(
          decoration: BoxDecoration(color: _groupColor(context), borderRadius: AppStyle.of(context).radius(10)),
          child: Column(children: [
            for (final (i, row) in rows.indexed) ...[
              if (i > 0) Divider(height: 1, indent: 14, endIndent: 14, color: colors.line),
              row,
            ],
          ]),
        );
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 14),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight - 38),
          child: IntrinsicHeight(
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _AboutIcon(c.settings),
                const SizedBox(width: 20),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Curator', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, height: 1.15, letterSpacing: -0.3, color: colors.text)),
                  const SizedBox(height: 2),
                  Row(spacing: 6, children: [
                    SelectableText('Version {version}'.fill({'version': '$appVersion ($appBuild)'}), style: TextStyle(fontSize: 13, color: colors.textMuted)),
                    if (appCommit.isNotEmpty) _Pill(appCommit, mono: true),
                    const _CopyButton(),
                  ]),
                  const _Link(websiteUrl, accent: true),
                ]),
              ]),
              const SizedBox(height: 16),
              group([
                _SettingRow(
                  title: 'Updates',
                  help: _updateHelp(c.updater.status),
                  control: _UpdateControl(updater: c.updater),
                ),
                _SettingRow(title: 'Check at launch', help: null, control: _launchSwitch(c)),
              ]),
              const SizedBox(height: 12),
              group(const [
                _LinkRow('Changelog', changelogUrl),
                _LinkRow('Source code', repositoryUrl, value: 'GitHub'),
                _LinkRow('License', licenseUrl, value: 'GPL-3.0'),
              ]),
              const Spacer(),
              const SizedBox(height: 14),
              // The mascot's credit, only while it shows.
              ListenableBuilder(
                listenable: c.settings,
                builder: (context, _) => AnimatedSwitcher(
                  duration: motion(context, 250),
                  switchInCurve: AppStyle.of(context).enterCurve,
                  switchOutCurve: AppStyle.of(context).exitCurve,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SizeTransition(sizeFactor: animation, alignment: Alignment.bottomCenter, child: child),
                  ),
                  child: c.settings.mascotIcon
                      ? Container(
                          key: const ValueKey(true),
                          width: double.infinity,
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text('Created using EmoteLab'.tr, textAlign: TextAlign.center, style: muted),
                        )
                      : const SizedBox(key: ValueKey(false), width: double.infinity),
                ),
              ),
              SelectableText('Verovio $verovioVersion  ·  $_systemText', textAlign: TextAlign.center, style: muted),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A row of an About group that opens [url] in the browser: [title], then [value] (or nothing)
/// and an arrow out at the right; shaded under the pointer.
class _LinkRow extends StatefulWidget {
  const _LinkRow(this.title, this.url, {this.value});
  final String title, url;
  final String? value;

  @override
  State<_LinkRow> createState() => _LinkRowState();
}

class _LinkRowState extends State<_LinkRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = AppStyle.of(context);
    final k = CarbonColors.maybeOf(context);
    final shade = k?.layerHover ?? colors.line.withValues(alpha: 0.45);
    return Semantics(
      link: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => openInBrowser(widget.url),
          child: AnimatedContainer(
            duration: stateDuration(motion(context, 120)),
            curve: style.curve,
            height: 38,
            padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
            decoration: BoxDecoration(color: _hover ? shade : shade.withValues(alpha: 0), borderRadius: style.radius(10)),
            child: Row(children: [
              Expanded(
                child: Text(widget.title.tr, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: colors.text)),
              ),
              if (widget.value case final value?) ...[
                Text(value, style: TextStyle(fontSize: 13, color: colors.textMuted)),
                const SizedBox(width: 8),
              ],
              Icon(AppIcon.popOut.of(context), size: 14, color: colors.textMuted),
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
