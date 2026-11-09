import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show AppExitResponse;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show LicenseEntry, LicenseEntryWithLineBreaks, LicenseRegistry, ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'app_menus.dart';
import 'app_settings.dart';
import 'audio_panel.dart';
import 'bottom_panel.dart';
import 'controller_settings.dart';
import 'dialog_kit.dart';
import 'edit_dialogs.dart';
import 'editor_controller.dart';
import 'editor_toolbar.dart';
import 'error_text.dart';
import 'extensions/extensions_dialog.dart';
import 'export_dialog.dart';
import 'file_names.dart';
import 'home_screen.dart';
import 'l10n/l10n.dart';
import 'media_converter.dart';
import 'phrase_search_window.dart';
import 'pdf_import.dart';
import 'project_document.dart';
import 'project_file.dart';
import 'project_tabs.dart';
import 'score_editor.dart';
import 'score_view.dart';
import 'scratch_space.dart';
import 'settings_dialog.dart';
import 'ui_kit.dart';
import 'updater.dart';
import 'video_export.dart';
import 'web_export_dialog.dart';
import 'window_chrome.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Clear out what earlier runs left behind (a crash can't clean up after itself).
  final keep = ScratchSpace.session.path;
  unawaited(Isolate.run(() => ScratchSpace.sweep(keep: keep)).catchError((_) {}));
  FontResources.workDirectory = ScratchSpace.folder('fonts').path; // metrics of fonts not bundled
  LicenseRegistry.addLicense(_fontLicenses);
  final (settings, _) = await (AppSettings.load(), Strings.load(rootBundle.loadString)).wait;
  if (settings.rememberWindow) await WindowChrome.restoreFrame(settings.windowFrame);
  final updater = Updater();
  if (settings.checkForUpdates) unawaited(updater.check());
  runApp(CuratedScoreApp(settings: settings, updater: updater));
}

/// The bundled fonts' licences, which go with them: read only when asked for.
Stream<LicenseEntry> _fontLicenses() async* {
  for (final (package, file) in [
    ('Carbon Icons', 'assets/fonts/CarbonIcons-LICENSE.txt'),
    ('Material Symbols', 'assets/fonts/MaterialSymbols-LICENSE.txt'),
    ('IBM Plex Sans', 'assets/fonts/IBMPlexSans-OFL.txt'),
    for (final font in ['Bravura', 'Leland', 'Petaluma', 'Leipzig', 'Gootville', 'Academico'])
      (font, 'packages/score_engine/assets/fonts/$font-OFL.txt'),
  ]) {
    yield LicenseEntryWithLineBreaks([package], await rootBundle.loadString(file));
  }
}

class CuratedScoreApp extends StatefulWidget {
  const CuratedScoreApp({super.key, this.settings, this.updater});

  /// Stored preferences; in-memory defaults when not given (tests).
  final AppSettings? settings;

  /// Settings ▸ About; one that hasn't checked yet when not given (tests).
  final Updater? updater;

  @override
  State<CuratedScoreApp> createState() => _CuratedScoreAppState();
}

class _CuratedScoreAppState extends State<CuratedScoreApp> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final settings = widget.settings ?? AppSettings.memory();

  // Appearance changes cross-fade: the theme changes at once, under a still of the window as it
  // was, which fades out. A lerped theme would rebuild every widget on every frame of the fade.
  final _windowKey = GlobalKey();
  final _before = ValueNotifier<ui.Image?>(null);
  late final _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 280))
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) _showBefore(null);
    });
  late (Brightness, AccentColor, UiStyle, TextSize, UiDensity, AppLanguage) _appearance;

  (Brightness, AccentColor, UiStyle, TextSize, UiDensity, AppLanguage) get _currentAppearance => (
        switch (settings.themeMode) {
          ThemeMode.light => Brightness.light,
          ThemeMode.dark => Brightness.dark,
          ThemeMode.system => WidgetsBinding.instance.platformDispatcher.platformBrightness,
        },
        settings.accent,
        settings.uiStyle,
        settings.textSize,
        settings.density,
        settings.language.resolved,
      );

  @override
  void initState() {
    super.initState();
    Strings.use(settings.language);
    _appearance = _currentAppearance;
    settings.addListener(_appearanceChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangePlatformBrightness() => _appearanceChanged();

  @override
  void didChangeLocales(List<Locale>? locales) => _appearanceChanged(); // Language: System

  /// Before the window rebuilds in the new theme: a still of it as it is, to fade out over it.
  void _appearanceChanged() {
    final appearance = _currentAppearance;
    if (appearance == _appearance) return;
    final language = appearance.$6 != _appearance.$6;
    _appearance = appearance;
    appearanceChanging(); // before the window rebuilds in it
    if (language) _translate();
    if (settings.reduceMotion) return; // no cross-fade
    final boundary = _windowKey.currentContext?.findRenderObject() as _RenderStillBoundary?;
    final still = boundary?.still(View.of(context).devicePixelRatio);
    if (still == null) return;
    _showBefore(still);
    _fade.forward(from: 0);
  }

  /// Every widget built again in the new language: text is translated as it is built ([tr]), and
  /// most of the window is built once and kept (the page, its panels), so nothing else would ask.
  void _translate() {
    Strings.use(settings.language);
    void rebuild(Element e) {
      e.markNeedsBuild();
      e.visitChildren(rebuild);
    }

    if (mounted) (context as Element).visitChildren(rebuild);
  }

  // Not a setState: only the still changes, and the rest of the window must not rebuild for it.
  void _showBefore(ui.Image? image) {
    final old = _before.value;
    _before.value = image;
    // Painted until the next frame; let go of it after that.
    if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  @override
  void dispose() {
    settings.removeListener(_appearanceChanged);
    WidgetsBinding.instance.removeObserver(this);
    _fade.dispose();
    _before.value?.dispose();
    _before.dispose();
    super.dispose();
  }

  // The same widget each build: a change of settings rebuilds only what reads them (or the theme).
  late final _home = AppWindow(settings: settings, updater: widget.updater);

  // Built once per accent, style, density and motion: a new ThemeData never equals the last (its extensions and button
  // styles compare by identity), so one per build would rebuild every widget that reads the
  // theme at any change of settings, each tick of a slider among them.
  (AccentColor, UiStyle, UiDensity, bool)? _themesFor;
  late ThemeData _light, _dark;

  void _buildThemes() {
    final key = (settings.accent, settings.uiStyle, settings.density, settings.reduceMotion);
    if (_themesFor == key) return;
    _themesFor = key;
    _light = AppColors.theme(accent: key.$1, brightness: Brightness.light, style: key.$2, density: key.$3, still: key.$4);
    _dark = AppColors.theme(accent: key.$1, brightness: Brightness.dark, style: key.$2, density: key.$3, still: key.$4);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        _buildThemes();
        return MaterialApp(
          title: 'Curator',
          debugShowCheckedModeBanner: false,
          theme: _light,
          darkTheme: _dark,
          themeMode: settings.themeMode,
          themeAnimationDuration: Duration.zero,
          locale: settings.language.locale,
          supportedLocales: AppLanguage.locales,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          // The still fades over everything, open menus and dialogs too, and is part of the next still.
          builder: (context, child) => _StillBoundary(
            key: _windowKey,
            child: Stack(fit: StackFit.expand, children: [
              MediaQuery(
                // Over the system's own text size (Windows has one).
                data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(MediaQuery.textScalerOf(context).scale(1) * settings.textSize.scale),
                    disableAnimations: settings.reduceMotion || MediaQuery.disableAnimationsOf(context)),
                child: child!,
              ),
              ValueListenableBuilder(
                valueListenable: _before,
                builder: (context, before, _) => before == null
                    ? const SizedBox.shrink()
                    : IgnorePointer(
                        child: FadeTransition(
                          opacity: ReverseAnimation(CurvedAnimation(parent: _fade, curve: Curves.easeInOut)),
                          child: RawImage(image: before, fit: BoxFit.fill),
                        ),
                      ),
              ),
            ]),
          ),
          home: _home,
        );
      },
    );
  }
}

/// A repaint boundary that hands over what it last painted, even with a repaint pending (a click
/// on the theme switch has just left one).
class _StillBoundary extends RepaintBoundary {
  const _StillBoundary({super.key, super.child});

  @override
  RenderRepaintBoundary createRenderObject(BuildContext context) => _RenderStillBoundary();
}

class _RenderStillBoundary extends RenderRepaintBoundary {
  ui.Image? still(double pixelRatio) => switch (layer) {
        final OffsetLayer layer when hasSize =>
          withoutLeftOut(() => layer.toImageSync(Offset.zero & size, pixelRatio: pixelRatio)),
        _ => null,
      };
}

/// The window: Home and the projects open, a tab each ([ProjectTabs], shown once one is open).
/// The menus act on the tab showing; a project's tab keeps its editor as it was left while
/// another shows.
class AppWindow extends StatefulWidget {
  const AppWindow({super.key, this.settings, this.updater});
  final AppSettings? settings;
  final Updater? updater;

  @override
  State<AppWindow> createState() => _AppWindowState();
}

/// A project open in a tab.
class _OpenProject {
  _OpenProject(this.path)
      : label = ValueNotifier((name: stemOf(fileNameOf(path ?? sampleProjectAsset)), edited: false, path: path));

  /// The project or score file it opened; null: the sample.
  final String? path;
  final key = GlobalKey<_ProjectPageState>();
  final messenger = GlobalKey<ScaffoldMessengerState>();
  final ValueNotifier<ProjectTabLabel> label;

  /// Closed: its tab is gone, its page kept (empty, out of sight) until the document has let go.
  bool closing = false;

  _ProjectPageState? get page => key.currentState;

  /// The file it is open from: its project's; a score's, opened as a project not saved yet (the
  /// score opened again shows that project, not a second one of it); or while it opens, the one
  /// it opens.
  String? get file => switch (page) {
        final page? when page.controller.score != null => page.document.path ?? path,
        _ => path,
      };

  bool get isSample => path == null;
}

class _AppWindowState extends State<AppWindow> {
  late final settings = widget.settings ?? AppSettings.memory();
  late final updater = widget.updater ?? Updater();
  late final _lifecycle = AppLifecycleListener(onExitRequested: _exitRequested);

  /// Every project open, those closing too (their pages stay until they have).
  final _projects = <_OpenProject>[];

  /// The tabs, in order.
  List<_OpenProject> get _tabs => [for (final p in _projects) if (!p.closing) p];

  /// The tab showing: a project, or null for Home.
  _OpenProject? _showing;

  final _homeMessenger = GlobalKey<ScaffoldMessengerState>();
  final _homeKeys = FocusNode(debugLabel: 'Home shortcuts');

  /// The menus are built again when this changes: the project showing's state (see
  /// [_ProjectPageState._menusChanged]), or the tab showing.
  final _menus = ValueNotifier(0);
  late final _recent = ValueNotifier(settings.recentFiles);

  /// While a text field has the keyboard, Edit's items are off (see build).
  final _typing = ValueNotifier(false);

  /// Whether a file is dragged over Home.
  bool _dropping = false;

  static const _scoreExtensions = ['musicxml', 'xml', 'mxl'];
  static XTypeGroup get _openableTypes => XTypeGroup(
        label: 'Projects and scores'.tr,
        extensions: const [ProjectFile.extension, ..._scoreExtensions, 'pdf'],
      );
  static const _scoreTypes = XTypeGroup(label: 'MusicXML', extensions: _scoreExtensions);
  static const _pdfTypes = XTypeGroup(label: 'PDF', extensions: ['pdf']);
  static XTypeGroup get _projectTypes => XTypeGroup(label: 'Curator project'.tr, extensions: const [ProjectFile.extension]);

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusChanged);
    settings.addListener(_settingsChanged);
    _lifecycle; // start listening for Quit
    updater.addListener(_launchCheckAnswered);
    WindowChrome.listenForOpenedFiles((paths) => paths.forEach(_openFromSystem));
    WindowChrome.showAppIcon(mascot: settings.mascotIcon);
    // Once, after the window's first frame, not when a video's background is first made
    // transparent. (Not an idle task: one waits while anything animates, re-arming a timer on
    // every turn of the event loop, which spun and, in widget tests, filled memory.)
    WidgetsBinding.instance.addPostFrameCallback((_) => CuratedScene.warmUp());
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    settings.removeListener(_settingsChanged);
    updater.removeListener(_launchCheckAnswered);
    _lifecycle.dispose();
    _homeKeys.dispose();
    _menus.dispose();
    _recent.dispose();
    _typing.dispose();
    for (final p in _projects) {
      p.label.dispose();
    }
    super.dispose();
  }

  /// Whether no dialog is over the window (its route is the one showing).
  bool _free = true;

  /// Files the system asked to open (the Finder, the Dock) while a dialog was up: opened once
  /// it has gone. A tab shown under a dialog would leave the dialog, which belongs to the tab it
  /// was opened in, over another project.
  final _waiting = <String>[];

  void _openFromSystem(String path) => _free ? _openPath(path) : _waiting.add(path);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _free = ModalRoute.of(context)?.isCurrent ?? true;
    if (!_free || _waiting.isEmpty) return;
    final paths = [..._waiting];
    _waiting.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) paths.forEach(_openPath);
    });
  }

  void _settingsChanged() {
    _recent.value = settings.recentFiles;
    WindowChrome.showAppIcon(mascot: settings.mascotIcon);
    if (settings.tabBar != _tabBar) {
      setState(() => _tabBar = settings.tabBar);
      _menus.value++;
    }
  }

  /// View ▸ Show / Hide Tab Bar ([AppSettings.tabBar]).
  late bool _tabBar = settings.tabBar;

  void _focusChanged() =>
      _typing.value = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;

  /// The check made at launch (Settings ▸ About ▸ Check at launch) says so when there is a
  /// newer version for this system, once; failures, and a release without this system's
  /// download, stay quiet. Later checks are the About page's to show.
  void _launchCheckAnswered() {
    final status = updater.status;
    if (status is UpdateIdle || status is UpdateChecking) return;
    updater.removeListener(_launchCheckAnswered);
    if (status is! UpdateAvailable || status.release.download == null || !mounted) return;
    _messenger?.showSnackBar(SnackBar(
      duration: const Duration(seconds: 10),
      content: Text('Curator {version} is available! ☆'.fill({'version': status.release.version})),
      action: SnackBarAction(label: 'Update…'.tr, onPressed: () => _settings(page: 'About')),
    ));
  }

  /// The tab showing's messages.
  ScaffoldMessengerState? get _messenger => (_showing?.messenger ?? _homeMessenger).currentState;

  void _snack(String message) => _messenger?.showSnackBar(SnackBar(content: Text(message.tr)));

  void _settings({String? page}) =>
      showSettingsDialog(context, settings, controller: _showing?.page?.controller, updater: updater, page: page);

  // MARK: Tabs

  void _show(_OpenProject? project) {
    if (project == _showing) return;
    // Before the rebuild, not in it: pausing tells the controller's listeners, a dialog's or
    // a floating window's among them, which aren't the page's to rebuild then.
    _showing?.page?._hide();
    setState(() => _showing = project);
    _menus.value++;
    if (project == null) {
      WindowChrome.showDocument();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _showing == null) _homeKeys.requestFocus();
      });
    }
  }

  /// Show Next / Previous Tab: [step] tabs on, Home before the first and after the last.
  void _step(int step) {
    final tabs = <_OpenProject?>[null, ..._tabs];
    _show(tabs[(tabs.indexOf(_showing) + step) % tabs.length]);
  }

  /// Open…, Open Recent, a drop, the Finder: the project or score at [path] in a tab of its own,
  /// or the tab it is open in already.
  void _openPath(String path) {
    if (!File(path).existsSync()) {
      settings.removeRecent(path);
      _snack('Can’t find “{name}”. Was it moved or deleted?'.fill({'name': fileNameOf(path)}));
      return;
    }
    final open = _tabs.where((p) => p.file == path).firstOrNull;
    _show(open ?? _add(_OpenProject(path)));
  }

  /// Open Sample: the sample in a tab, or its tab if it is open.
  void _openSample() => _show(_tabs.where((p) => p.isSample).firstOrNull ?? _add(_OpenProject(null)));

  _OpenProject _add(_OpenProject project) {
    setState(() => _projects.add(project));
    return project;
  }

  /// Open… (⌘O): a Curator project, or a MusicXML score to start a new one, in a new tab.
  Future<void> _open() async {
    final file = await openFile(acceptedTypeGroups: [_openableTypes, _projectTypes, _scoreTypes, _pdfTypes]);
    if (file != null && mounted) _openPath(file.path);
  }

  /// File ▸ Close (⌘W), a tab's ×: offers to save unsaved changes (showing the project they're
  /// in), then the tab goes, the one after it showing (or before it, or Home).
  Future<void> _close(_OpenProject project) async {
    if (project.closing) return;
    final page = project.page;
    if (page != null && page.document.isDirty) {
      _show(project);
      if (!await page._confirmDiscard() || !mounted || project.closing) return;
    }
    final tabs = _tabs, at = tabs.indexOf(project);
    tabs.remove(project);
    setState(() => project.closing = true); // its page drops the editor now
    if (_showing == project) _show(tabs.isEmpty ? null : tabs[math.min(at, tabs.length - 1)]);
    // After a save under way, if any; then the page goes, its controller with it.
    await page?.document.close();
    if (!mounted) return;
    setState(() => _projects.remove(project));
    project.label.dispose();
  }

  Future<AppExitResponse> _exitRequested() async {
    for (final project in _tabs) {
      final page = project.page;
      if (page == null || !page.document.isDirty) continue;
      _show(project);
      if (!await page._confirmDiscard()) return AppExitResponse.cancel;
    }
    for (final project in _projects) {
      await project.page?.controller.audio.unload(); // lets go of its files, so they can be deleted
    }
    ScratchSpace.close();
    final frame = await WindowChrome.currentFrame(previous: settings.windowFrame);
    if (frame != null) await settings.saveWindowFrame(frame);
    return AppExitResponse.exit;
  }

  /// With no project showing, or the demo, there is nothing to save: says so instead.
  void _nothingToSave() => _snack('Nothing to save yet! Open a project or score first.');

  // MARK: Home's drops

  void _droppedOnHome(String path) {
    if (MediaFormats.isMidi(path) || MediaFormats.isRecording(path)) {
      _snack(MediaFormats.isMidi(path)
          ? 'Open a score first, then its MIDI tempo map.'
          : 'Open a score first, then its recording.');
    } else {
      _openPath(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs, barShown = tabs.isNotEmpty && _tabBar;
    // The menus follow the tab showing; the window below them is built here and passed through.
    return ListenableBuilder(
      listenable: Listenable.merge([_recent, _menus, _typing]),
      builder: (context, window) {
        final page = _showing?.page;
        final open = page != null && page._hasScore.value;
        // A dialog is up: it belongs to the tab showing, so that tab stays showing and open
        // (on macOS the menus' keys still reach them: ⌘W meant for the dialog would close
        // the project under it, its controller with it).
        final free = ModalRoute.of(context)?.isCurrent ?? true;
        // Edit acts on the score, so not while a text field or a dialog has the keyboard:
        // a key the field leaves unused would otherwise reach the menu.
        final edit = page != null && !_typing.value && free ? page._edit.value : null;
        final commands = page?._commands;
        return AppMenus(
          onOpen: free ? _open : null,
          // Enabled but for the demo: Save explains when there is nothing to save.
          onSave: page == null ? _nothingToSave : page._isSample.value ? null : page._save,
          onSaveAs: page == null ? _nothingToSave : page._isSample.value ? null : page._saveAs,
          onSettings: _settings,
          onAbout: () => _settings(page: 'About'),
          recentFiles: _recent.value,
          onOpenRecent: free ? _openPath : null,
          onClearRecent: settings.clearRecent,
          onClose: _showing == null || !free ? null : () => _close(_showing!),
          onProjectSettings: open ? page._projectSettings : null,
          onExportVideo: open && page._canExport.value ? page._exportVideo : null,
          onExportWeb: open && page._canExport.value ? page._exportWeb : null,
          onUndo: edit != null && edit.undo ? page!.controller.undo : null,
          onRedo: edit != null && edit.redo ? page!.controller.redo : null,
          onCut: edit != null && edit.copy ? commands!.cut : null,
          onCopy: edit != null && edit.copy ? commands!.copy : null,
          onPaste: edit != null && edit.paste ? page!._paste : null,
          onDelete: edit != null && edit.delete ? commands!.delete : null,
          onSelectAll: edit != null && commands!.canSelectAll ? commands.selectAll : null,
          onFindPhrase: open && !_typing.value && free && !page.controller.isPdf ? page._findPhrase : null,
          previewShown: page?._previewShown ?? true,
          timelineShown: page?._timelineShown ?? true,
          onShowPreview: open ? page._showPreview : null,
          onShowTimeline: open ? page._showTimeline : null,
          onMaximizePreview: open ? () => page._maximize(timeline: false) : null,
          onMaximizeTimeline: open ? () => page._maximize(timeline: true) : null,
          onNextTab: tabs.isEmpty || !free ? null : () => _step(1),
          onPreviousTab: tabs.isEmpty || !free ? null : () => _step(-1),
          tabBarShown: _tabBar,
          onShowTabBar: (on) => settings.tabBar = on,
          child: window!,
        );
      },
      // Under everything: no part of the window ever shows its black backing.
      child: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Column(children: [
          // The strip itself slides up under the menu as it goes (clipped), not a gap: its
          // place left empty while it shrank showed the window's black backing.
          ClipRect(
            child: AnimatedAlign(
              duration: motion(context, 220),
              curve: AppStyle.of(context).curve,
              alignment: Alignment.bottomCenter,
              heightFactor: barShown ? 1 : 0,
              child: IgnorePointer(
                ignoring: !barShown,
                child: ExcludeSemantics(
                  excluding: !barShown,
                  child: ExcludeFocus(
                    excluding: !barShown,
                    child: ProjectTabs(
                      labels: [for (final p in tabs) p.label],
                      shown: _showing == null ? null : tabs.indexOf(_showing!),
                      onShow: (i) => _show(i == null ? null : tabs[i]),
                      onClose: (i) => _close(tabs[i]),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Stack(fit: StackFit.expand, children: [
              _tab(
                key: const ValueKey('home'),
                showing: _showing == null,
                messenger: _homeMessenger,
                child: Focus(focusNode: _homeKeys, autofocus: true, child: _home()),
              ),
              for (final project in _projects)
                _tab(
                  key: ObjectKey(project),
                  showing: _showing == project,
                  messenger: project.messenger,
                  child: ProjectPage(
                    key: project.key,
                    settings: settings,
                    path: project.path,
                    showing: _showing == project,
                    closing: project.closing,
                    label: project.label,
                    onMenusChanged: () => _menus.value++,
                    onOpen: _openPath,
                    openElsewhere: (path) => _tabs.any((p) => p != project && p.file == path),
                    onFailed: () => _close(project),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }

  /// A tab's page: while another shows, kept as it is, out of sight, its animations stopped and
  /// its keyboard focus let go.
  static Widget _tab({required Key key, required bool showing, required GlobalKey<ScaffoldMessengerState> messenger, required Widget child}) =>
      Offstage(
        key: key,
        offstage: !showing,
        child: TickerMode(
          enabled: showing,
          child: ExcludeFocus(excluding: !showing, child: ScaffoldMessenger(key: messenger, child: child)),
        ),
      );

  Widget _home() => DropTarget(
        enable: _showing == null,
        onDragEntered: (_) => setState(() => _dropping = true),
        onDragExited: (_) => setState(() => _dropping = false),
        onDragDone: (details) {
          setState(() => _dropping = false);
          if (details.files.isNotEmpty) _droppedOnHome(details.files.first.path);
        },
        child: Scaffold(
          body: Stack(children: [
            Positioned.fill(
              child: ValueListenableBuilder(
                valueListenable: _recent,
                builder: (context, recent, _) => HomeScreen(
                  settings: settings,
                  recentFiles: recent,
                  onOpen: _open,
                  onOpenRecent: _openPath,
                  onRemoveRecent: settings.removeRecent,
                  onClearRecent: settings.clearRecent,
                  onOpenSample: _openSample,
                ),
              ),
            ),
            _DropHint(area: _DropArea.home, visible: _dropping, rect: null, attachImage: false),
          ]),
        ),
      );
}

/// A project's tab: the editor around one document, opened from [path] (or the sample) as it
/// is first built. Its keys, drops and messages are its own; the menus reach it through
/// [AppWindow].
class ProjectPage extends StatefulWidget {
  const ProjectPage({
    super.key,
    required this.settings,
    required this.path,
    required this.showing,
    required this.closing,
    required this.label,
    required this.onMenusChanged,
    required this.onOpen,
    required this.openElsewhere,
    required this.onFailed,
  });

  final AppSettings settings;

  /// The project or score it opens; null: the sample.
  final String? path;

  /// Whether its tab shows (before it stops, [_ProjectPageState._hide] has stopped it playing and
  /// closed its floating windows).
  final bool showing;

  /// Closed: it builds nothing more while the document lets go.
  final bool closing;

  /// What its tab says, kept up to date here.
  final ValueNotifier<ProjectTabLabel> label;

  /// What the menus offer changed, while it shows.
  final VoidCallback onMenusChanged;

  /// Another project or score to open (one dropped on the timeline), in a tab of its own.
  final ValueChanged<String> onOpen;

  /// Whether the file at a path is open in another tab.
  final bool Function(String path) openElsewhere;

  /// It didn't open (said why already): its tab goes.
  final VoidCallback onFailed;

  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

class _ProjectPageState extends State<ProjectPage> with SingleTickerProviderStateMixin {
  late final controller = EditorController(vsync: this);
  AppSettings get settings => widget.settings;
  late final document = ProjectDocument(controller, settings)..onAutosaveError = _autosaveFailed;
  /// Where a file being dragged over the window would go; null: none is.
  _DropArea? _drop;
  _DropArea _lastDrop = _DropArea.home; // the hint's text while it fades out
  final _scoreView = GlobalKey<ScoreViewState>(), _timeline = GlobalKey(), _dropStack = GlobalKey();
  double _timelineHeight = 300;

  /// View ▸ Hide / Show: the preview and the timeline; one of them always shows.
  bool _previewShown = true, _timelineShown = true;

  /// Whether a score is open: the menus' Score items follow it.
  final _hasScore = ValueNotifier(false);

  /// Whether a video can be made now: not while the score is engraved again (the toolbar's
  /// button is greyed out then too).
  final _canExport = ValueNotifier(false);

  /// Whether the demo is open: Save and Save As are off for it.
  final _isSample = ValueNotifier(false);

  /// What the Edit menu can do; the menus rebuild when it changes, not on every edit.
  final _edit = ValueNotifier((undo: false, redo: false, copy: false, paste: false, delete: false));

  /// The settings the page shows: it rebuilds when one of them changes, not at every change of
  /// settings (a slider in Settings changes them many times a second).
  late final _shown = ValueNotifier(_shownSettings);

  ({bool videoFrame, VideoRatio videoRatio, bool tabBar}) get _shownSettings => (
        videoFrame: settings.previewVideoFrame,
        videoRatio: settings.videoRatio,
        tabBar: settings.tabBar,
      );

  late final _menuState = Listenable.merge([_hasScore, _canExport, _isSample, _edit]);

  void _settingsChanged() {
    controller.takeSettings(settings);
    _shown.value = _shownSettings;
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusChanged);
    document.addListener(_updateWindowTitle);
    document.addListener(_sampleChanged);
    controller.addListener(_scoreChanged);
    controller.engravingFailure.addListener(_engravingFailed);
    settings.addListener(_settingsChanged);
    _menuState.addListener(_menusChanged);
    controller.takeSettings(settings);
    unawaited(_load());
    // Home had the keyboard: it comes here, as it does when the tab is shown again.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.showing) _keys.requestFocus();
    });
  }

  @override
  void didUpdateWidget(ProjectPage old) {
    super.didUpdateWidget(old);
    if (widget.showing == old.showing) return;
    if (widget.showing) {
      _updateWindowTitle();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.showing) _keys.requestFocus();
      });
    }
  }

  /// Its tab is about to stop showing ([AppWindow] calls it before its rebuild): heard only
  /// while seen, and its windows over the editor would float over another's.
  void _hide() {
    controller.playback.pause();
    PhraseSearchWindow.close();
    closeEngravingWindow();
  }

  void _menusChanged() {
    if (widget.showing) widget.onMenusChanged();
  }

  void _scoreChanged() {
    final open = controller.score != null;
    _hasScore.value = open;
    _canExport.value = open && !controller.isReengraving;
    _edit.value = (
      undo: controller.canUndo,
      redo: controller.canRedo,
      copy: _commands.canCopy,
      paste: _commands.canPaste,
      delete: _commands.canDelete,
    );
  }

  void _sampleChanged() => _isSample.value = document.isSample;

  /// An edit that couldn't be engraved: the score stays as it was, and Undo steps back.
  void _engravingFailed() {
    final error = controller.engravingFailure.value;
    if (error == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn’t engrave. {error}'.fill({'error': describeError(error)}))));
  }

  /// The document's name (without extension) and edited state, in its tab and, while it
  /// shows, the native title bar.
  void _updateWindowTitle() {
    final title = document.title;
    if (title != null) widget.label.value = (name: stemOf(title), edited: document.isDirty, path: document.path);
    if (!widget.showing || widget.closing) return;
    WindowChrome.showDocument(
      name: title == null ? null : stemOf(title),
      edited: document.isDirty,
      path: document.path,
    );
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    document.removeListener(_updateWindowTitle);
    document.removeListener(_sampleChanged);
    controller.removeListener(_scoreChanged);
    controller.engravingFailure.removeListener(_engravingFailed);
    settings.removeListener(_settingsChanged);
    _menuState.removeListener(_menusChanged);
    _hasScore.dispose();
    _canExport.dispose();
    _isSample.dispose();
    _edit.dispose();
    _shown.dispose();
    _keys.dispose();
    document.dispose();
    controller.dispose();
    super.dispose();
  }

  /// While a text field has focus, keys go to it (Space, T, arrows…), not to the shortcuts.
  bool _typing = false;

  /// Where the window's shortcuts listen: the keyboard comes back here from a field.
  final _keys = FocusNode(debugLabel: 'Window shortcuts');

  void _focusChanged() {
    final typing =
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (typing != _typing && mounted) setState(() => _typing = typing);
  }

  // MARK: Files

  /// Opens what the tab is for: a project, a score (a new project), or the sample. When it
  /// doesn't open, it has said why, and the tab goes.
  Future<void> _load() async {
    final path = widget.path;
    if (path == null) {
      await _guard(() async {
        final problem = await document.openSample();
        if (problem != null && mounted) _recordingProblem(problem);
      }, title: 'Couldn’t Open Sample'.tr);
    } else if (path.toLowerCase().endsWith('.${ProjectFile.extension}')) {
      await _guard(() async {
        final problem = await document.open(path);
        if (controller.fonts.music.isMissing && mounted) _fontMissing(controller.fonts.music.name);
        if (problem != null && mounted) _recordingProblem(problem);
        if (document.isOlderFormat && mounted) _olderFormat();
        if (mounted) await promptForExtensions(context, controller);
      }, title: 'Couldn’t Open Project'.tr);
    } else if (path.toLowerCase().endsWith('.pdf')) {
      await _guard(() => _importPdf(path), title: 'Couldn’t Import PDF'.tr);
    } else {
      await _guard(() async {
        await document.importScore(path);
        if (controller.fonts.music.isMissing && mounted) _fontMissing(controller.fonts.music.name); // the default's
        final warnings = controller.score?.warnings ?? const [];
        if (warnings.isNotEmpty && mounted) await showImportWarnings(context, controller.fileName ?? path, warnings);
      });
    }
    if (mounted && controller.score == null) widget.onFailed();
  }

  void _snack(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message.tr)));
  }

  /// A PDF score: read and set out in the PDF import ([showPdfImport]), then a new project of
  /// it. Cancelled, nothing opens.
  Future<void> _importPdf(String path) async {
    final bytes = await File(path).readAsBytes();
    final pages = await PdfPages.open(bytes);
    PdfScoreLayout? layout;
    try {
      if (mounted) layout = await showPdfImport(context, pages, name: fileNameOf(path));
    } finally {
      if (layout == null || !mounted) pages.close();
    }
    if (layout == null || !mounted) return;
    await document.importPdf(path, bytes, pages, layout);
    if (controller.fonts.music.isMissing && mounted) _fontMissing(controller.fonts.music.name); // the default's
  }

  /// The project opened, but not its recording: says why, and offers to pick it.
  void _recordingProblem(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 12),
      content: Text(message.tr),
      action: SnackBarAction(label: 'Locate…'.tr, onPressed: () => pickAudio(context, controller)),
    ));
  }

  /// The project's music font isn't embedded, nor installed here: Bravura stands in until it is
  /// closed (dismissed by the user).
  void _fontMissing(String name) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      persist: true,
      showCloseIcon: true,
      content: Text('Can’t find the font “{name}”, so Bravura is filling in.'.fill({'name': name})),
    ));
  }

  /// The project was saved by Curator 0.6.1 or before: saving it here (an autosave too) updates
  /// it, and they can't open it then (dismissed by the user).
  void _olderFormat() {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      persist: true,
      showCloseIcon: true,
      content: Text('A project from an older Curator! Saving updates it, so older versions won’t open it after.'.tr),
    ));
  }

  /// Save (⌘S). Returns false when nothing was saved (cancelled or failed). Saves even
  /// without changes.
  Future<bool> _save() async {
    if (!_canSave()) return false;
    return document.path == null ? _saveAs() : _write(null);
  }

  /// Save As… (⇧⌘S).
  Future<bool> _saveAs() async {
    if (!_canSave()) return false;
    final location = await getSaveLocation(
      acceptedTypeGroups: [_AppWindowState._projectTypes],
      suggestedName: document.suggestedFileName,
    );
    if (location == null || !mounted) return false;
    final path = await confirmSavePath(context, location.path, ProjectFile.extension);
    if (path == null || !mounted) return false;
    // Two tabs on one file would each save over the other (an autosave too).
    if (widget.openElsewhere(path)) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('“{name}” is open in another tab. Close it there first.'.fill({'name': fileNameOf(path)}))));
      return false;
    }
    return _write(path);
  }

  /// With no score open (yet), or the demo, there is nothing to save: says so instead of saving.
  bool _canSave() {
    if (controller.score != null && !document.isSample) return true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text((document.isSample
                ? 'The sample is just for looking. Open a score to start your own!'
                : 'Nothing to save yet! Open a project or score first.')
            .tr)));
    return false;
  }

  Future<bool> _write(String? path) async {
    var saved = false;
    await _guard(() async {
      await document.save(path);
      saved = true;
    }, title: 'Couldn’t Save Project'.tr);
    return saved;
  }

  void _autosaveFailed(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn’t autosave. {error}'.fill({'error': describeError(error)}))));
  }

  /// Before the project goes: offers to save unsaved changes. False: stay.
  Future<bool> _confirmDiscard() async {
    if (!document.isDirty) return true;
    final choice = await showAppDialog<String>(
      context: context,
      builder: (context) => AppDialog(
        title: Text('Save your changes to “{name}” first?'.fill({'name': document.title})),
        content: Text('If you don’t, they’ll be lost.'.tr),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'discard'), child: Text('Don’t Save'.tr)),
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
          FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: Text((document.path == null ? 'Save…' : 'Save').tr)),
        ],
      ),
    );
    return switch (choice) { 'discard' => true, 'save' => await _save(), _ => false };
  }

  Future<void> _guard(Future<void> Function() action, {String? title}) async {
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      unawaited(showAppDialog<void>(
        context: context,
        builder: (context) => AppDialog(
          title: Text(title ?? 'Couldn’t Open Score'.tr),
          content: SingleChildScrollView(child: Text(describeError(e))),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text('OK'.tr))],
        ),
      ));
    }
  }

  EditCommands get _commands => controller.commands;

  void _toggleTapMode() {
    if (controller.score == null) return;
    controller.tab = BottomTab.audio;
    controller.anchors.tapArmed = !controller.anchors.tapArmed;
  }

  void _toggleMetronome() {
    if (controller.score == null) return;
    controller.playback.metronome = !controller.playback.metronome;
  }

  /// W: make the selected anchor a warp, or add one at the playhead (in the Audio tab).
  void _warp() {
    if (controller.score == null) return;
    controller.tab = BottomTab.audio;
    controller.playback.pause(); // a dialog asks where it jumps to
    unawaited(editWarp(context, controller));
  }

  final _readout = GlobalKey<TimeReadoutState>();

  void _goTo() => _readout.currentState?.edit();

  /// Find Phrase… (⌘F): its window over the editor.
  void _findPhrase() {
    if (controller.score == null) return;
    PhraseSearchWindow.show(Overlay.of(context), controller);
  }

  /// Paste: regions copied in the Instruments tab, while it shows; else Attach Image's image.
  void _paste() => _commands.pastesRegions ? _commands.pasteRegions() : _pasteImage();

  Future<void> _pasteImage() async {
    if (!_commands.pastesImage) return;
    String? problem;
    try {
      if (!await controller.images.paste()) problem = 'There’s no image to paste.'.tr;
    } catch (e) {
      problem = 'Couldn’t paste the image. {error}'.fill({'error': describeError(e)});
    }
    if (problem != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
  }

  /// A drop goes by where it lands: before the score is open anything opens (in a tab of its
  /// own); over the score it is an image; over the timeline, the Instruments tab opens a
  /// project or score and the Audio tab takes a MIDI tempo map or a recording.
  _DropArea _areaAt(Offset global) {
    if (controller.score == null) return _DropArea.home;
    final timelineTop = _top(_timeline);
    if (!_previewShown || timelineTop != null && global.dy >= timelineTop) {
      return controller.tab == BottomTab.audio ? _DropArea.audio : _DropArea.project;
    }
    return _DropArea.image;
  }

  /// The top of [key]'s widget in the window.
  static double? _top(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    return box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero).dy;
  }

  void _dragAt(Offset global) {
    final area = _areaAt(global);
    if (area != _drop) setState(() => _drop = _lastDrop = area);
  }

  /// Where the drop hint for [area] is drawn, in the window's page; null: all of it.
  Rect? _dropRect(_DropArea area) {
    final stack = _dropStack.currentContext?.findRenderObject() as RenderBox?, top = _top(_timeline);
    if (area == _DropArea.home || stack == null || !stack.hasSize || top == null) return null;
    final split = stack.globalToLocal(Offset(0, top)).dy;
    return area == _DropArea.image
        ? Rect.fromLTRB(0, 0, stack.size.width, split)
        : Rect.fromLTRB(0, split, stack.size.width, stack.size.height);
  }

  void _dropped(String path, _DropArea area, Offset global) {
    switch (area) {
      case _DropArea.image:
        _scoreView.currentState?.dropImage(path, global);
      case _DropArea.project:
        if (MediaFormats.isMidi(path) || MediaFormats.isRecording(path)) {
          _snack('Recordings and MIDI files go on the Audio tab!');
        } else {
          widget.onOpen(path);
        }
      case _DropArea.audio:
        if (!_addMedia(path)) _snack('Try a MIDI file or a recording.');
      case _DropArea.home:
        if (MediaFormats.isMidi(path) || MediaFormats.isRecording(path)) {
          _snack('Recordings and MIDI files go on the Audio tab!');
        } else {
          widget.onOpen(path);
        }
    }
  }

  /// Adds the MIDI tempo map or the recording at [path] to the score open; false when it is
  /// neither.
  bool _addMedia(String path) {
    if (MediaFormats.isMidi(path)) {
      unawaited(_guard(() async {
        final taken = await controller.loadMidiTempo(path);
        if (mounted) showMidiWarpsTaken(context, controller, taken);
      }, title: 'Couldn’t Use MIDI File'.tr));
    } else if (MediaFormats.isRecording(path)) {
      unawaited(_guard(() async {
        await controller.loadAudio(path);
        if (mounted) await alignAdded(context, controller);
      }, title: 'Couldn’t Load Recording'.tr));
    } else {
      return false;
    }
    return true;
  }

  void _projectSettings() =>
      showProjectSettingsDialog(context, settings, controller, editScore: _editScore);

  /// Project Settings ▸ Project Info ▸ Score ▸ Edit…: the score's MusicXML in the score editor;
  /// what is edited there replaces the score (this project's edits and recording kept; asks
  /// first when the two differ).
  Future<void> _editScore() async {
    final loaded = controller.score;
    if (loaded == null) return;
    if (loaded.pdf case final pdf?) return _editPdf(pdf.layout);
    final name = '${stemOf(controller.fileName ?? document.title ?? 'Score')}.musicxml';
    final EditableScore score;
    try {
      score = EditableScore.parse(loaded.musicXML);
    } on Object catch (e) {
      await _guard(() => Future.error(e), title: 'Couldn’t Edit Score'.tr);
      return;
    }
    if (!mounted) return;
    final xml = await showScoreEditor(context, score, name: name);
    if (xml == null || !mounted) return;
    await _guard(() async {
      final replacement = await document.prepareReplacementWith(name, utf8.encode(xml));
      if (!mounted) return;
      if (replacement.differences.isNotEmpty &&
          !await confirmReplaceScore(context, replacement.name, replacement.differences)) {
        return;
      }
      await document.replaceScore(replacement);
      final warnings = replacement.score.warnings;
      if (warnings.isNotEmpty && mounted) await showImportWarnings(context, replacement.name, warnings);
    }, title: 'Couldn’t Edit Score'.tr);
  }

  /// Project Info ▸ Score ▸ Edit… for a PDF score: its import again; what is set there replaces
  /// the score, as the score editor's does.
  Future<void> _editPdf(PdfScoreLayout layout) async {
    final pages = controller.pdfPages;
    final name = controller.fileName ?? 'Score.pdf';
    if (pages == null) return;
    final next = await showPdfImport(context, pages, name: name, layout: layout);
    if (next == null || !mounted) return;
    await _guard(() async {
      final replacement = await document.prepareReplacementWith(name, controller.source!.bytes, pdf: next);
      if (!mounted) return;
      if (replacement.differences.isNotEmpty &&
          !await confirmReplaceScore(context, replacement.name, replacement.differences)) {
        replacement.score.pdf?.dispose();
        return;
      }
      await document.replaceScore(replacement);
    }, title: 'Couldn’t Edit Score'.tr);
  }

  /// File ▸ Export Video… (⌘E): offers the project's (or the score's) name for the video.
  void _exportVideo() {
    if (controller.score == null || controller.isReengraving) return;
    showExportDialog(context, controller, settings, suggestedName: stemOf(document.title ?? 'Curator'));
  }

  /// File ▸ Export to Web…: offers the project's (or the score's) name for the page.
  void _exportWeb() {
    if (controller.score == null || controller.isReengraving) return;
    showWebExportDialog(context, controller, settings, suggestedName: stemOf(document.title ?? 'Curator'));
  }

  // MARK: View

  /// View ▸ Hide / Show Preview: hiding it shows the timeline if that was hidden.
  void _showPreview(bool on) {
    setState(() {
      _previewShown = on;
      if (!on) _timelineShown = true;
    });
    _menusChanged();
  }

  /// View ▸ Hide / Show Timeline: hiding it shows the preview if that was hidden.
  void _showTimeline(bool on) {
    setState(() {
      _timelineShown = on;
      if (!on) _previewShown = true;
    });
    _menusChanged();
  }

  /// View ▸ Maximize Preview / Timeline: both shown, the other at its smallest (and kept so as
  /// the window is resized, until the divider is dragged).
  void _maximize({required bool timeline}) {
    setState(() {
      _previewShown = _timelineShown = true;
      _timelineHeight = timeline ? double.infinity : _minTimeline;
    });
    _menusChanged();
  }

  @override
  Widget build(BuildContext context) {
    // Closed: the editor goes before the document it shows does.
    if (widget.closing) return const SizedBox.shrink();
    return CallbackShortcuts(
      bindings: _typing ? const {} : _bindings,
      child: Focus(
        focusNode: _keys,
        autofocus: true,
        // A click outside a field of the window's (the time, Starts at) hands the keyboard
        // back to its shortcuts, not to the route above them, where Space, T, ⌘Z… would stop.
        child: Actions(
          actions: {
            EditableTextTapOutsideIntent: CallbackAction<EditableTextTapOutsideIntent>(onInvoke: (intent) {
              if (intent.focusNode.hasFocus) _keys.requestFocus();
              return null;
            }),
          },
          child: DropTarget(
            enable: widget.showing,
            onDragEntered: (d) => _dragAt(d.globalPosition),
            onDragUpdated: (d) => _dragAt(d.globalPosition),
            onDragExited: (_) => setState(() => _drop = null),
            onDragDone: (details) {
              final area = _areaAt(details.globalPosition);
              setState(() => _drop = null);
              if (details.files.isNotEmpty) _dropped(details.files.first.path, area, details.globalPosition);
            },
            // Rebuilt when a score opens, not at every edit: the toolbar, the score and the
            // timeline each follow what they show.
            child: Select(
              listenable: Listenable.merge([controller, _shown]),
              select: () => (score: controller.score, loading: controller.isLoading, shown: _shown.value),
              builder: (context, _) => Scaffold(
                body: Stack(
                  key: _dropStack,
                  children: [
                    AnimatedSwitcher(
                      duration: motion(context, 320),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      // Semantics stay through the fade (see showAppDialog: the size slider).
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        alwaysIncludeSemantics: true,
                        child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(animation), child: child),
                      ),
                      child: controller.score == null
                          ? const SizedBox.expand(key: ValueKey('opening'))
                          : KeyedSubtree(key: const ValueKey('editor'), child: _editor(context)),
                    ),
                    // Until it has opened, too: the score is read before it is engraved.
                    _Busy(visible: controller.isLoading || controller.score == null, stage: controller.loadStage),
                    _DropHint(area: _lastDrop, visible: _drop != null, rect: _dropRect(_lastDrop), attachImage: controller.images.enabled),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Map<ShortcutActivator, VoidCallback> get _bindings => {
        // Space plays / pauses — or, in tap mode, marks the bar or beat sounding now.
        const SingleActivator(LogicalKeyboardKey.space): _commands.space,
        const SingleActivator(LogicalKeyboardKey.enter): controller.playback.togglePlay,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): controller.playback.togglePlay,
        // P too: tap mode takes Space.
        const SingleActivator(LogicalKeyboardKey.keyP): controller.playback.togglePlay,
        const SingleActivator(LogicalKeyboardKey.keyT): _toggleTapMode,
        const SingleActivator(LogicalKeyboardKey.keyW): _warp,
        const SingleActivator(LogicalKeyboardKey.keyC): _toggleMetronome,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _commands.arrow(-1, fine: false),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _commands.arrow(1, fine: false),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () => _commands.arrow(-1, fine: true),
        const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () => _commands.arrow(1, fine: true),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () => _commands.arrow(-1, fine: true, nudge: true),
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () => _commands.arrow(1, fine: true, nudge: true),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _commands.vertical(-1),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _commands.vertical(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true): () => _commands.vertical(-1, fine: true),
        const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true): () => _commands.vertical(1, fine: true),
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true): _commands.selectAll,
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): _commands.selectAll,
        const SingleActivator(LogicalKeyboardKey.home): () => controller.playback.seek(0),
        const SingleActivator(LogicalKeyboardKey.end): () => controller.playback.seek(controller.playback.duration),
        // Go to a bar or a time: the toolbar's readout, typed.
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true): _goTo,
        const SingleActivator(LogicalKeyboardKey.keyG, control: true): _goTo,
        const SingleActivator(LogicalKeyboardKey.delete): _commands.delete,
        const SingleActivator(LogicalKeyboardKey.backspace): _commands.delete,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): controller.undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true): controller.redo,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): controller.undo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): controller.redo,
        const SingleActivator(LogicalKeyboardKey.escape): _commands.escape,
        // Instruments tab: the selected regions. Paste: those, or Attach Image's image at the pointer.
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true): _commands.copy,
        const SingleActivator(LogicalKeyboardKey.keyC, control: true): _commands.copy,
        const SingleActivator(LogicalKeyboardKey.keyX, meta: true): _commands.cut,
        const SingleActivator(LogicalKeyboardKey.keyX, control: true): _commands.cut,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _paste,
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): _paste,
        // Instruments tab: tools, and trimming the selected regions to the playhead.
        const SingleActivator(LogicalKeyboardKey.keyV): () => _commands.tool(LaneTool.select),
        const SingleActivator(LogicalKeyboardKey.keyD): () => _commands.tool(LaneTool.draw),
        const SingleActivator(LogicalKeyboardKey.keyE): () => _commands.tool(LaneTool.erase),
        const SingleActivator(LogicalKeyboardKey.bracketLeft): () => _commands.trim(start: true),
        const SingleActivator(LogicalKeyboardKey.bracketRight): () => _commands.trim(start: false),
      };

  static const _minTimeline = 150.0, _minScore = 180.0;

  Widget _editor(BuildContext context) {
    // Built here, not in the layout builder: resizing the window lays them out again, the
    // same widgets, without rebuilding them at every step of the drag.
    final toolbar = EditorToolbar(
      controller: controller,
      document: document,
      onExportVideo: _exportVideo,
      onExportWeb: _exportWeb,
      videoFrame: settings.previewVideoFrame,
      onVideoFrame: (on) => settings.previewVideoFrame = on,
      videoRatio: settings.videoRatio,
      // Choosing a ratio shows it.
      onVideoRatio: (r) => settings
        ..videoRatio = r
        ..previewVideoFrame = true,
      // While the tab bar is hidden, its tabs (Home among them) are a click away.
      onShowTabBar: settings.tabBar ? null : () => settings.tabBar = true,
      readout: _readout,
    );
    final score = Expanded(child: ScoreView(
      key: _scoreView,
      controller: controller,
      aspectRatio: settings.previewVideoFrame ? settings.videoFormat.aspectRatio : null,
    ));
    // Working in the timeline leaves the image selected in the score.
    // Keyed so it keeps its state when the preview is hidden or shown around it.
    final timeline = KeyedSubtree(
      key: _timeline,
      child: Listener(
        onPointerDown: (_) => controller.images.select(null),
        child: BottomPanel(controller: controller, onProjectSettings: _projectSettings),
      ),
    );
    final toolbarHeight = EditorToolbar.heightOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      final maxTimeline = math.max(_minTimeline, constraints.maxHeight - toolbarHeight - _minScore);
      final timelineHeight = _timelineHeight.clamp(_minTimeline, maxTimeline);
      // View ▸ Hide: the part left takes the whole height.
      return Column(
        children: [
          toolbar,
          if (_previewShown) score,
          if (_previewShown && _timelineShown)
            _ResizeHandle(
              onDrag: (dy) => setState(() => _timelineHeight = (timelineHeight - dy).clamp(_minTimeline, maxTimeline)),
            ),
          if (_timelineShown)
            _previewShown ? SizedBox(height: timelineHeight, child: timeline) : Expanded(child: timeline),
        ],
      );
    });
  }
}

/// The divider between the score and the timeline: drag it to share the height.
class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({required this.onDrag});
  final ValueChanged<double> onDrag;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hover = false, _dragging = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final active = _hover || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        supportedDevices: kDragDevices,
        onVerticalDragStart: (_) => setState(() => _dragging = true),
        onVerticalDragEnd: (_) => setState(() => _dragging = false),
        onVerticalDragCancel: () => setState(() => _dragging = false),
        onVerticalDragUpdate: (d) => widget.onDrag(d.delta.dy),
        child: AnimatedContainer(
          duration: stateDuration(motion(context, 150)),
          height: 7,
          decoration: BoxDecoration(
            color: active ? colors.accentWash : colors.chrome,
            border: Border(top: BorderSide(color: colors.line)),
          ),
          alignment: Alignment.center,
          child: AnimatedContainer(
            duration: stateDuration(motion(context, 150)),
            width: active ? 44 : 32,
            height: 3,
            decoration: BoxDecoration(
              color: active ? colors.accent : colors.activity,
              borderRadius: AppStyle.of(context).radius(2),
            ),
          ),
        ),
      ),
    );
  }
}

/// A veil with a spinner while a score is engraved; fades in and out (then lets go of the
/// spinner, which would otherwise turn on unseen).
/// Over the page while a score opens: how far it has got, a bar creeping on to where its stage
/// ends ([LoadStage]; before it is read, a bar running to and fro).
class _Busy extends StatefulWidget {
  const _Busy({required this.visible, required this.stage});
  final bool visible;
  final ValueListenable<LoadStage?> stage;

  @override
  State<_Busy> createState() => _BusyState();
}

class _BusyState extends State<_Busy> {
  late bool _built = widget.visible; // until it has faded out

  @override
  void didUpdateWidget(_Busy old) {
    super.didUpdateWidget(old);
    if (widget.visible) _built = true;
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        ignoring: !widget.visible,
        child: AnimatedOpacity(
          opacity: widget.visible ? 1 : 0,
          duration: motion(context, 200),
          onEnd: () {
            if (!widget.visible && mounted) setState(() => _built = false);
          },
          child: !_built
              ? const SizedBox.expand()
              : ColoredBox(
                  color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.75),
                  child: Center(
                    child: ValueListenableBuilder<LoadStage?>(
                      valueListenable: widget.stage,
                      builder: (context, stage, _) => Column(mainAxisSize: MainAxisSize.min, children: [
                        const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
                        const SizedBox(height: 14),
                        Text(
                            switch (stage) {
                              null => 'Opening…',
                              LoadStage.reading => 'Reading score…',
                              LoadStage.engraving => 'Engraving…',
                              LoadStage.measuring => 'Measuring…',
                            }
                                .tr,
                            style: TextStyle(color: context.colors.textMuted)),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: 220,
                          child: stage == null
                              ? LinearProgressIndicator(minHeight: 4, borderRadius: AppStyle.of(context).radius(2))
                              // Each stage's share, crept over in about the time it takes.
                              : TweenAnimationBuilder<double>(
                                  tween: Tween(
                                      begin: 0,
                                      end: switch (stage) {
                                    LoadStage.reading => 0.35,
                                    LoadStage.engraving => 0.85,
                                    LoadStage.measuring => 0.97,
                                  }),
                                  duration: Duration(milliseconds: stage == LoadStage.engraving ? 2500 : 900),
                                  curve: Curves.easeOutCubic,
                                  builder: (context, value, _) => LinearProgressIndicator(
                                      value: value, minHeight: 4, borderRadius: AppStyle.of(context).radius(2)),
                                ),
                        ),
                      ]),
                    ),
                  ),
                ),
        ),
      );
}

/// Shown while a file is dragged over the window.
/// Where a dropped file goes (see [_ProjectPageState._areaAt]).
enum _DropArea { home, image, project, audio }

class _DropHint extends StatelessWidget {
  const _DropHint({required this.area, required this.visible, required this.rect, required this.attachImage});
  final _DropArea area;
  final bool visible;

  /// Where it is drawn; null: the whole page.
  final Rect? rect;
  final bool attachImage;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final (icon, title, detail) = switch (area) {
      _DropArea.home => (AppIcon.drop.of(context), 'Drop to open', 'A project or a MusicXML score'),
      _DropArea.project => (AppIcon.drop.of(context), 'Drop to open', 'A project or a MusicXML score'),
      _DropArea.audio => (AppIcon.audio.of(context), 'Drop to add', 'A MIDI tempo map or a recording'),
      _DropArea.image when attachImage => (AppIcon.image.of(context), 'Drop to add an image', 'SVG, PNG, GIF, JPEG…'),
      _DropArea.image => (AppIcon.noImage.of(context), 'Attach Image is off', 'Turn on in Project Settings ▸ Extensions'),
    };
    final hint = IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: motion(context, 160),
        child: AnimatedScale(
          scale: visible ? 1 : 0.98,
          duration: motion(context, 200),
          curve: Curves.easeOutCubic,
          child: Container(
            margin: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.accentWash.withValues(alpha: 0.85),
              border: Border.all(color: colors.accent, width: 2),
              borderRadius: AppStyle.of(context).radius(16),
            ),
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 40, color: colors.accentStrong),
                const SizedBox(height: 10),
                Text(title.tr, style: Theme.of(context).textTheme.titleLarge?.copyWith(color: colors.text)),
                const SizedBox(height: 4),
                Text(detail.tr, style: TextStyle(fontSize: 12.5, color: colors.textMuted)),
              ]),
            ),
          ),
        ),
      ),
    );
    final r = rect;
    return r == null ? Positioned.fill(child: hint) : Positioned.fromRect(rect: r, child: hint);
  }
}
