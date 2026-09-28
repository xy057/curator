import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show AppExitResponse;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_menus.dart';
import 'app_settings.dart';
import 'audio_panel.dart';
import 'bottom_panel.dart';
import 'condensing_dialog.dart';
import 'editor_controller.dart';
import 'edit_dialogs.dart';
import 'editor_toolbar.dart';
import 'error_text.dart';
import 'export_dialog.dart';
import 'home_screen.dart';
import 'media_converter.dart';
import 'project_document.dart';
import 'project_file.dart';
import 'scratch_space.dart';
import 'score_view.dart';
import 'settings_dialog.dart';
import 'ui_kit.dart';
import 'updater.dart';
import 'window_chrome.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Clear out what earlier runs left behind (a crash can't clean up after itself).
  final keep = ScratchSpace.session.path;
  unawaited(Isolate.run(() => ScratchSpace.sweep(keep: keep)).catchError((_) {}));
  final settings = await AppSettings.load();
  final updater = Updater();
  if (settings.checkForUpdates) unawaited(updater.check());
  runApp(CuratedScoreApp(settings: settings, updater: updater));
}

class CuratedScoreApp extends StatefulWidget {
  const CuratedScoreApp({super.key, this.settings, this.updater});

  /// Stored preferences; in-memory defaults when not given (tests).
  final AppSettings? settings;

  /// Settings ▸ Update; one that hasn't checked yet when not given (tests).
  final Updater? updater;

  @override
  State<CuratedScoreApp> createState() => _CuratedScoreAppState();
}

class _CuratedScoreAppState extends State<CuratedScoreApp> {
  late final settings = widget.settings ?? AppSettings.memory();

  @override
  Widget build(BuildContext context) {
    // Appearance changes cross-fade: the theme (and the palette in it) lerps.
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: 'Curator',
        debugShowCheckedModeBanner: false,
        theme: AppColors.theme(accent: settings.accent, brightness: Brightness.light),
        darkTheme: AppColors.theme(accent: settings.accent, brightness: Brightness.dark),
        themeMode: settings.themeMode,
        themeAnimationDuration: const Duration(milliseconds: 280),
        themeAnimationCurve: Curves.easeInOut,
        home: HomePage(settings: settings, updater: widget.updater),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.settings, this.updater});
  final AppSettings? settings;
  final Updater? updater;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  late final controller = EditorController(vsync: this);
  late final settings = widget.settings ?? AppSettings.memory();
  late final updater = widget.updater ?? Updater();
  late final document = ProjectDocument(controller, settings)..onAutosaveError = _autosaveFailed;
  late final _lifecycle = AppLifecycleListener(onExitRequested: _exitRequested);
  bool _dragging = false;
  double _timelineHeight = 300;

  static const _scoreExtensions = ['musicxml', 'xml', 'mxl'];
  static const _openableTypes = XTypeGroup(
    label: 'Projects and scores',
    extensions: [ProjectFile.extension, ..._scoreExtensions],
  );
  static const _scoreTypes = XTypeGroup(label: 'MusicXML', extensions: _scoreExtensions);
  static const _projectTypes = XTypeGroup(label: 'Curator project', extensions: [ProjectFile.extension]);

  /// Whether a score is open: the menus' Score items follow it.
  final _hasScore = ValueNotifier(false);

  /// Whether the demo is open: Save and Save As are off for it.
  final _isSample = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusChanged);
    document.addListener(_updateWindowTitle);
    document.addListener(_sampleChanged);
    controller.addListener(_scoreChanged);
    settings.addListener(_engravingChanged);
    _engravingChanged();
    _lifecycle; // start listening for Quit
    updater.addListener(_launchCheckAnswered);
    WindowChrome.listenForOpenedFiles((paths) => _openPath(paths.first));
  }

  /// The check made at launch (Settings ▸ Update ▸ Check at launch) says so when there is a
  /// newer version, once; failures stay quiet. Later checks are the Update page's to show.
  void _launchCheckAnswered() {
    final status = updater.status;
    if (status is UpdateIdle || status is UpdateChecking) return;
    updater.removeListener(_launchCheckAnswered);
    if (status is! UpdateAvailable || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 10),
      content: Text('Curator ${status.release.version} is out.'),
      action: SnackBarAction(label: 'Update…', onPressed: () => _settings(page: 'Update')),
    ));
  }

  void _scoreChanged() => _hasScore.value = controller.score != null;

  /// Settings ▸ Advanced ▸ Engrave Options: what is open is engraved again with them.
  void _engravingChanged() => controller.engravingOptions = settings.engravingOptions;
  void _sampleChanged() => _isSample.value = document.isSample;

  /// The document's name (without extension) and edited state, in the native title bar.
  void _updateWindowTitle() {
    final title = document.title;
    final dot = title?.lastIndexOf('.') ?? -1;
    WindowChrome.showDocument(
      name: title == null ? null : (dot > 0 ? title.substring(0, dot) : title),
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
    settings.removeListener(_engravingChanged);
    updater.removeListener(_launchCheckAnswered);
    _hasScore.dispose();
    _isSample.dispose();
    _lifecycle.dispose();
    document.dispose();
    controller.dispose();
    super.dispose();
  }

  /// While a text field has focus, keys go to it (Space, T, arrows…), not to the shortcuts.
  bool _typing = false;

  void _focusChanged() {
    final typing =
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (typing != _typing && mounted) setState(() => _typing = typing);
  }

  // MARK: Files

  /// Open… (⌘O): a Curator project, or a MusicXML score to start a new one.
  Future<void> _open() async {
    if (!await _confirmDiscard()) return;
    final file = await openFile(acceptedTypeGroups: const [_openableTypes, _projectTypes, _scoreTypes]);
    if (file != null) await _openPath(file.path, confirmed: true);
  }

  /// Opens a project or a score (Open…, Open Recent, dropping a file).
  Future<void> _openPath(String path, {bool confirmed = false}) async {
    if (!File(path).existsSync()) {
      settings.removeRecent(path);
      _snack('“${path.split(RegExp(r'[/\\]')).last}” was moved or deleted.');
      return;
    }
    if (!confirmed && !await _confirmDiscard()) return;
    if (path.toLowerCase().endsWith('.${ProjectFile.extension}')) {
      await _guard(() async {
        final problem = await document.open(path);
        if (problem != null && mounted) _recordingProblem(problem);
      }, title: 'Could not open the project');
    } else {
      await _guard(() => document.importScore(path));
    }
  }

  void _snack(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// The project opened, but not its recording: says why, and offers to pick it.
  void _recordingProblem(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 12),
      content: Text(message),
      action: SnackBarAction(label: 'Locate…', onPressed: () => pickAudio(context, controller)),
    ));
  }

  Future<void> _openSample() async {
    if (!await _confirmDiscard()) return;
    await _guard(() async {
      final problem = await document.openSample();
      if (problem != null && mounted) _recordingProblem(problem);
    }, title: 'Could not open the sample');
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
      acceptedTypeGroups: const [_projectTypes],
      suggestedName: document.suggestedFileName,
    );
    if (location == null) return false;
    var path = location.path;
    if (!path.toLowerCase().endsWith('.${ProjectFile.extension}')) path += '.${ProjectFile.extension}';
    return _write(path);
  }

  /// With no score open, or the demo, there is nothing to save: says so instead of saving.
  bool _canSave() {
    if (controller.score != null && !document.isSample) return true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(document.isSample
            ? 'The demo can’t be saved: import a score to start a project of your own.'
            : 'Nothing to save yet: open a project or import a score first.')));
    return false;
  }

  Future<bool> _write(String? path) async {
    var saved = false;
    await _guard(() async {
      await document.save(path);
      saved = true;
    }, title: 'Could not save the project');
    return saved;
  }

  void _autosaveFailed(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Autosave failed: ${describeError(error)}')));
  }

  /// Before replacing the project: offers to save unsaved changes. False: stay.
  Future<bool> _confirmDiscard() async {
    if (!document.isDirty) return true;
    final choice = await showAppDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Save changes to “${document.title}”?'),
        content: const Text('Your changes will be lost if you don’t save them.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'discard'), child: const Text('Don’t Save')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save…')),
        ],
      ),
    );
    return switch (choice) { 'discard' => true, 'save' => await _save(), _ => false };
  }

  Future<AppExitResponse> _exitRequested() async {
    if (!await _confirmDiscard()) return AppExitResponse.cancel;
    await controller.audio.unload(); // lets go of its files, so they can be deleted
    ScratchSpace.close();
    return AppExitResponse.exit;
  }

  void _settings({String? page}) =>
      showSettingsDialog(context, settings, controller: controller, updater: updater, page: page);

  Future<void> _guard(Future<void> Function() action, {String title = 'Could not open the score'}) async {
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      showAppDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(describeError(e))),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    }
  }

  bool get _syncing => controller.score != null && controller.tab == BottomTab.audio;
  bool get _curating => controller.score != null && controller.tab == BottomTab.instruments;

  void _tool(LaneTool tool) {
    if (_curating) controller.lanes.tool = tool;
  }

  void _trim({required bool start}) {
    if (_curating) controller.lanes.trimToPlayhead(start: start);
  }

  void _space() => _syncing && controller.anchors.tapArmed ? controller.anchors.tap() : controller.playback.togglePlay();

  void _toggleTapMode() {
    if (controller.score == null) return;
    controller.tab = BottomTab.audio;
    controller.anchors.tapArmed = !controller.anchors.tapArmed;
  }

  /// W: make the selected anchor a warp, or add one at the playhead (in the Audio tab).
  void _warp() {
    if (controller.score == null) return;
    controller.tab = BottomTab.audio;
    controller.playback.pause(); // a dialog asks where it jumps to
    editWarp(context, controller);
  }

  /// ←/→ nudge the selected anchors (10 ms, ⇧ 1 ms) or regions (a bar, ⇧ a beat);
  /// otherwise skip 5 s (⇧ 1 s).
  void _arrow(int direction, {required bool fine}) {
    if (_syncing && controller.anchors.selected.isNotEmpty) {
      controller.anchors.nudge(direction * (fine ? 0.001 : 0.01));
    } else if (_curating && controller.lanes.selected.isNotEmpty) {
      controller.lanes.nudge(direction, beat: fine);
    } else {
      controller.playback.skip(direction * (fine ? 1.0 : 5.0));
    }
  }

  /// ↑/↓ move the selected regions to the lane above / below, or re-bar the selected anchors
  /// (↑ the next bar or beat, ↓ the previous).
  void _vertical(int direction) {
    if (_curating) {
      controller.lanes.moveToLane(direction);
    } else {
      controller.anchors.shift(-direction);
    }
  }

  void _selectAll() {
    if (_syncing) controller.anchors.selectAll();
    if (_curating) controller.lanes.selectAll();
  }

  void _escape() {
    if (controller.anchors.tapArmed) {
      controller.anchors.tapArmed = false;
      controller.playback.pause();
    } else if (_curating && controller.lanes.selected.isEmpty && controller.lanes.tool != LaneTool.select) {
      controller.lanes.tool = LaneTool.select;
    } else {
      controller.clearSelection();
    }
  }

  void _dropped(String path) {
    if (MediaFormats.isRecording(path)) {
      if (controller.score == null) {
        _snack('Open a score first, then add its recording.');
      } else {
        _guard(() => controller.loadAudio(path), title: 'Could not load the recording');
      }
    } else {
      _openPath(path);
    }
  }

  // MARK: Close

  final _editorKey = GlobalKey();

  /// The editor as a still image while it fades out: the live one would rebuild against a
  /// closed project.
  ui.Image? _editorSnapshot;

  /// File ▸ Close (⌘W): back to the start screen.
  Future<void> _close() async {
    if (controller.score == null || !await _confirmDiscard() || !mounted) return;
    // Only what is painted can be snapshot, and a click (the toolbar's Close) has just left
    // the editor to paint again: let that frame happen first.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final boundary = _editorKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary != null && boundary.hasSize) {
      setState(() => _editorSnapshot = boundary.toImageSync(pixelRatio: MediaQuery.devicePixelRatioOf(context)));
      await WidgetsBinding.instance.endOfFrame;
    }
    await document.close();
    // Let go of the snapshot once the cross-fade to the start screen is over.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    final snapshot = _editorSnapshot;
    setState(() => _editorSnapshot = null);
    snapshot?.dispose();
  }

  void _editTexts() => showTextsDialog(context, controller);
  void _condensing() => showCondensingDialog(context, controller);
  void _addRecording() => pickAudio(context, controller);

  /// File ▸ Export Video… (⌘E): offers the project's (or the score's) name for the video.
  void _exportVideo() {
    if (controller.score == null || controller.isReengraving) return;
    final title = document.title ?? 'Curator';
    final dot = title.lastIndexOf('.');
    showExportDialog(context, controller, settings, suggestedName: dot > 0 ? title.substring(0, dot) : title);
  }

  @override
  Widget build(BuildContext context) {
    // The menus follow the recent files and whether a score is open; the page below them is
    // built once and passed through.
    return ListenableBuilder(
      listenable: Listenable.merge([settings, _hasScore, _isSample]),
      builder: (context, page) => AppMenus(
        onOpen: _open,
        // Enabled but for the demo: Save explains when there is nothing to save.
        onSave: _isSample.value ? null : _save,
        onSaveAs: _isSample.value ? null : _saveAs,
        onSettings: _settings,
        recentFiles: settings.recentFiles,
        onOpenRecent: _openPath,
        onClearRecent: settings.clearRecent,
        onClose: _hasScore.value ? _close : null,
        onEditTexts: _hasScore.value ? _editTexts : null,
        onCondensing: _hasScore.value ? _condensing : null,
        onAddRecording: _hasScore.value ? _addRecording : null,
        onExportVideo: _hasScore.value ? _exportVideo : null,
        child: page!,
      ),
      child: CallbackShortcuts(
        bindings: _typing ? const {} : _bindings,
        child: Focus(
          autofocus: true,
          child: DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: (details) {
              setState(() => _dragging = false);
              if (details.files.isNotEmpty) _dropped(details.files.first.path);
            },
            child: ListenableBuilder(
              listenable: Listenable.merge([controller, document, settings]),
              builder: (context, _) => Scaffold(
                body: Stack(
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 320),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      // Semantics stay through the fade (see showAppDialog: the size slider).
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        alwaysIncludeSemantics: true,
                        child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(animation), child: child),
                      ),
                      child: controller.score == null
                          ? HomeScreen(
                              key: const ValueKey('home'),
                              recentFiles: settings.recentFiles,
                              onOpen: _open,
                              onOpenRecent: _openPath,
                              onRemoveRecent: settings.removeRecent,
                              onClearRecent: settings.clearRecent,
                              onOpenSample: _openSample,
                            )
                          : KeyedSubtree(
                              key: const ValueKey('editor'),
                              child: _editorSnapshot != null
                                  ? RawImage(image: _editorSnapshot, fit: BoxFit.fill)
                                  : RepaintBoundary(key: _editorKey, child: _editor(context)),
                            ),
                    ),
                    _Busy(visible: controller.isLoading, message: 'Engraving…'),
                    _DropHint(visible: _dragging),
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
        const SingleActivator(LogicalKeyboardKey.space): _space,
        const SingleActivator(LogicalKeyboardKey.enter): controller.playback.togglePlay,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): controller.playback.togglePlay,
        const SingleActivator(LogicalKeyboardKey.keyT): _toggleTapMode,
        const SingleActivator(LogicalKeyboardKey.keyW): _warp,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _arrow(-1, fine: false),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _arrow(1, fine: false),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () => _arrow(-1, fine: true),
        const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () => _arrow(1, fine: true),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _vertical(-1),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _vertical(1),
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true): _selectAll,
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): _selectAll,
        const SingleActivator(LogicalKeyboardKey.home): () => controller.playback.seek(0),
        const SingleActivator(LogicalKeyboardKey.delete): controller.deleteSelection,
        const SingleActivator(LogicalKeyboardKey.backspace): controller.deleteSelection,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): controller.undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true): controller.redo,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): controller.undo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): controller.redo,
        const SingleActivator(LogicalKeyboardKey.escape): _escape,
        // Instruments tab: tools, and trimming the selected regions to the playhead.
        const SingleActivator(LogicalKeyboardKey.keyV): () => _tool(LaneTool.select),
        const SingleActivator(LogicalKeyboardKey.keyD): () => _tool(LaneTool.draw),
        const SingleActivator(LogicalKeyboardKey.keyE): () => _tool(LaneTool.erase),
        const SingleActivator(LogicalKeyboardKey.bracketLeft): () => _trim(start: true),
        const SingleActivator(LogicalKeyboardKey.bracketRight): () => _trim(start: false),
      };

  static const _minTimeline = 150.0, _minScore = 180.0;

  Widget _editor(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final maxTimeline = math.max(_minTimeline, constraints.maxHeight - EditorToolbar.height - _minScore);
      final timelineHeight = _timelineHeight.clamp(_minTimeline, maxTimeline);
      return Column(
        children: [
          EditorToolbar(
            controller: controller,
            document: document,
            onEditTexts: _editTexts,
            onExportVideo: _exportVideo,
            videoFrame: settings.previewVideoFrame,
            onVideoFrame: (on) => settings.previewVideoFrame = on,
            videoRatio: settings.videoRatio,
            // Choosing a ratio shows it.
            onVideoRatio: (r) => settings
              ..videoRatio = r
              ..previewVideoFrame = true,
            onClose: _close,
          ),
          Expanded(child: ScoreView(
            controller: controller,
            aspectRatio: settings.previewVideoFrame ? settings.videoFormat.aspectRatio : null,
          )),
          _ResizeHandle(
            onDrag: (dy) => setState(() => _timelineHeight = (timelineHeight - dy).clamp(_minTimeline, maxTimeline)),
          ),
          SizedBox(height: timelineHeight, child: BottomPanel(controller: controller)),
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
        onVerticalDragStart: (_) => setState(() => _dragging = true),
        onVerticalDragEnd: (_) => setState(() => _dragging = false),
        onVerticalDragCancel: () => setState(() => _dragging = false),
        onVerticalDragUpdate: (d) => widget.onDrag(d.delta.dy),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 7,
          decoration: BoxDecoration(
            color: active ? colors.accentWash : colors.surface,
            border: Border(top: BorderSide(color: colors.line)),
          ),
          alignment: Alignment.center,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: active ? 44 : 32,
            height: 3,
            decoration: BoxDecoration(
              color: active ? colors.accent : colors.activity,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

/// A veil with a spinner while a score is engraved; fades in and out.
class _Busy extends StatelessWidget {
  const _Busy({required this.visible, required this.message});
  final bool visible;
  final String message;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: !visible
              ? const SizedBox.expand()
              : ColoredBox(
                  color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.75),
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
                      const SizedBox(height: 14),
                      Text(message, style: TextStyle(color: context.colors.textMuted)),
                    ]),
                  ),
                ),
        ),
      );
}

/// Shown while a file is dragged over the window.
class _DropHint extends StatelessWidget {
  const _DropHint({required this.visible});
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 160),
        child: AnimatedScale(
          scale: visible ? 1 : 0.98,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: Container(
            margin: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.accentWash.withValues(alpha: 0.85),
              border: Border.all(color: colors.accent, width: 2),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.file_download_outlined, size: 40, color: colors.accentStrong),
                const SizedBox(height: 10),
                Text('Drop to open', style: Theme.of(context).textTheme.titleLarge?.copyWith(color: colors.text)),
                const SizedBox(height: 4),
                Text('A project, a MusicXML score, or a recording for the open score',
                    style: TextStyle(fontSize: 12.5, color: colors.textMuted)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
