import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_settings.dart';
import 'editor_controller.dart';
import 'project_file.dart';
import 'scratch_space.dart';

/// The demo project, bundled with the app.
const sampleProjectAsset = 'assets/demo/WI275 - 01 Intro.ccs';

/// How this save stores the recording.
///
/// [preferred] is the choice in Settings. [originalPath] is the recording's own file, if it
/// still exists (a recording unpacked from a project has none).
/// [sizeBytes] is the size of the recording.
///
/// With nothing to link to, the recording is embedded: a project should never be saved
/// pointing nowhere. A recording larger than [embedLimitBytes] is linked when it can be, so
/// every (auto)save doesn't rewrite gigabytes of video.
MediaStorage resolveMediaStorage({
  required MediaStorage preferred,
  required String? originalPath,
  required int sizeBytes,
}) {
  if (originalPath == null) return MediaStorage.embed;
  if (sizeBytes > embedLimitBytes) return MediaStorage.link;
  return preferred;
}

/// Recordings above this size are linked even when Settings say "embed" (see
/// [resolveMediaStorage]).
const embedLimitBytes = 2 * 1024 * 1024 * 1024;

/// The open project: where it is saved, whether it has unsaved changes, and autosave.
class ProjectDocument extends ChangeNotifier {
  ProjectDocument(this.controller, this.settings) {
    controller.editRevision.addListener(_edited);
    settings.addListener(_settingsChanged);
    _settingsChanged();
  }

  final EditorController controller;
  final AppSettings settings;

  /// Called when an autosave fails (a manual save reports its error to the caller).
  void Function(Object error)? onAutosaveError;

  /// Where the project is saved; null until it has been saved once.
  String? get path => _path;
  String? _path;

  int _savedRevision = 0;
  bool _dirty = false;

  /// True when there are changes since the last save (or since opening).
  bool get isDirty => _dirty;

  /// The name for the title bar: the project file, or the imported score.
  String? get title => _path != null ? _basename(_path!) : controller.fileName;

  bool get isSaving => _saving != null;

  /// True while the bundled demo is open: it can't be saved (Save and Save As are off) and
  /// its changes are never unsaved, so closing it asks nothing.
  bool get isSample => _isSample;
  bool _isSample = false;
  Future<void>? _saving;

  // MARK: Opening

  /// Opens a .ccs project. Either it opens and becomes this document, or (it throws and)
  /// nothing changes. Returns what went wrong with the recording, if anything: the project
  /// still opens without it.
  Future<String?> open(String path) async {
    final String? recordingProblem;
    final previousMedia = _mediaDirectory;
    final mediaDirectory = ScratchSpace.folder('project');
    try {
      final project = await ProjectFile.read(path, mediaDirectory: mediaDirectory.path);
      final problem = await controller.openProject(
        name: project.scoreName,
        scoreBytes: project.scoreBytes,
        state: project.state,
        mediaPath: project.media?.path,
        mediaOriginal: project.media?.originalPath,
      );
      final missing = project.media?.missingPath;
      recordingProblem = problem ?? (missing == null ? null : 'The linked recording was not found:\n$missing');
    } catch (_) {
      ScratchSpace.release(mediaDirectory);
      rethrow;
    }
    _mediaDirectory = mediaDirectory;
    ScratchSpace.release(previousMedia);
    _path = path;
    _isSample = false;
    _markSaved(controller.editRevision.value);
    settings.addRecent(path);
    return recordingProblem;
  }

  /// Starts a new, unsaved project from a score file (Open… with a MusicXML score).
  Future<void> importScore(String path) async {
    await controller.openFile(path);
    ScratchSpace.release(_mediaDirectory); // the project before had its recording unpacked there
    _mediaDirectory = null;
    _path = null;
    _isSample = false;
    _markSaved(controller.editRevision.value);
    settings.addRecent(path);
  }

  /// Opens the demo project to try things in; it can't be saved ([isSample]). Returns the
  /// same as [open].
  Future<String?> openSample() async {
    final data = await rootBundle.load(sampleProjectAsset);
    final folder = ScratchSpace.folder('sample');
    final file = File('${folder.path}${Platform.pathSeparator}${sampleProjectAsset.split('/').last}');
    await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    try {
      final missing = await open(file.path);
      settings.removeRecent(file.path); // a temporary copy: nothing to reopen
      _path = null;
      _isSample = true;
      _markSaved(controller.editRevision.value);
      return missing;
    } finally {
      ScratchSpace.release(folder); // its score and recording are unpacked by now
    }
  }

  /// Closes the project (File ▸ Close); unsaved changes are the caller's to ask about.
  Future<void> close() async {
    await controller.close();
    ScratchSpace.release(_mediaDirectory);
    _mediaDirectory = null;
    _path = null;
    _isSample = false;
    _markSaved(controller.editRevision.value);
  }

  // MARK: Saving

  /// Saves to [path] (Save As…), or to where the project already is (Save).
  Future<void> save([String? path]) async {
    if (_isSample) throw StateError('The demo can’t be saved.');
    final target = path ?? _path;
    if (target == null) throw StateError('The project has not been saved yet: choose where to save it.');
    while (_saving != null) {
      await _saving; // one save at a time; the next one picks up the latest edits
    }
    final completer = Completer<void>();
    _saving = completer.future;
    notifyListeners();
    try {
      final revision = controller.editRevision.value;
      await ProjectFile.write(target, _contents());
      _path = target;
      _markSaved(revision);
      if (path != null) settings.addRecent(target);
    } finally {
      _saving = null;
      completer.complete();
      notifyListeners();
    }
  }

  ProjectContents _contents() {
    final source = controller.source!;
    final track = controller.track;
    ProjectMedia? media;
    if (track != null) {
      final original = controller.mediaOriginal;
      final originalExists = original != null && File(original).existsSync();
      media = ProjectMedia(
        name: track.name,
        storage: resolveMediaStorage(
          preferred: settings.mediaStorage,
          originalPath: originalExists ? original : null,
          sizeBytes: File(track.path).existsSync() ? File(track.path).lengthSync() : 0,
        ),
        embedFrom: track.path,
        originalPath: originalExists ? original : null,
      );
    }
    return ProjectContents(
      scoreName: source.name,
      scoreBytes: source.bytes,
      state: controller.projectState,
      media: media,
    );
  }

  /// A name for Save As…: the project's, or the score's with .ccs.
  String get suggestedFileName {
    if (_path != null) return _basename(_path!);
    final name = controller.source?.name ?? 'Untitled';
    final dot = name.lastIndexOf('.');
    return '${dot > 0 ? name.substring(0, dot) : name}.${ProjectFile.extension}';
  }

  // MARK: Unsaved changes and autosave

  void _edited() {
    final dirty = !_isSample && controller.score != null && controller.editRevision.value != _savedRevision;
    if (dirty == _dirty) return;
    _dirty = dirty;
    notifyListeners();
  }

  void _markSaved(int revision) {
    _savedRevision = revision;
    _dirty = !_isSample && controller.editRevision.value != revision;
    notifyListeners();
  }

  Timer? _autosaveTimer;
  Duration? _autosaveInterval;

  void _settingsChanged() {
    controller.undoLimit = settings.undoSteps;
    controller.defaultTransition = settings.transition;
    if (settings.autosave != _autosaveInterval) _restartAutosave();
  }

  void _restartAutosave() {
    _autosaveInterval = settings.autosave;
    _autosaveTimer?.cancel();
    _autosaveTimer = settings.autosave > Duration.zero ? Timer.periodic(settings.autosave, (_) => autosave()) : null;
  }

  /// Saves if the project has a file and unsaved changes. An untitled project is left alone:
  /// autosave never asks where to save.
  @visibleForTesting
  Future<void> autosave() async {
    if (_path == null || !_dirty || isSaving) return;
    try {
      await save();
    } catch (e) {
      onAutosaveError?.call(e);
    }
  }

  // MARK: Housekeeping

  /// Where the open project's embedded recording is unpacked.
  Directory? _mediaDirectory;

  static String _basename(String path) => path.split(RegExp(r'[/\\]')).last;

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    controller.editRevision.removeListener(_edited);
    settings.removeListener(_settingsChanged);
    ScratchSpace.release(_mediaDirectory);
    super.dispose();
  }
}
