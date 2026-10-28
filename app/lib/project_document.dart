import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_settings.dart';
import 'editor_controller.dart';
import 'file_names.dart';
import 'project_file.dart';
import 'score_replacement.dart';
import 'scratch_space.dart';
import 'l10n/l10n.dart';

/// The demo project, bundled with the app.
const sampleProjectAsset = 'assets/demo/WI275 - 01 Intro.ccs';

/// The open project: where it is saved, whether it has unsaved changes, and autosave.
class ProjectDocument extends ChangeNotifier {
  ProjectDocument(this.controller, this.settings) {
    controller.inTurn = _oneAtATime; // a recording replaced while a save embeds it would be gone
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
  String? get title => _path != null ? fileNameOf(_path!) : controller.fileName;

  bool get isSaving => _saving != null;

  /// True while the open project is as Curator 0.6.1 and before saved it ([OpenedProject.olderFormat]),
  /// not saved since: the next save (an autosave too) writes the new format, which they can't open.
  bool get isOlderFormat => _olderFormat;
  bool _olderFormat = false;

  /// True while the bundled demo is open: it can't be saved (Save and Save As are off) and
  /// its changes are never unsaved, so closing it asks nothing.
  bool get isSample => _isSample;
  bool _isSample = false;
  Future<void>? _saving;

  // MARK: One at a time

  /// Opening, importing, closing, saving (autosaves too) and loading a recording
  /// ([EditorController.inTurn]) run one at a time, in the order asked. Interleaved, a second
  /// open could replace the score while the first was still loading its recording, and leave
  /// one project's score under the other's path for the next save; an autosave in the middle
  /// of an open would write the new project over the old one's file; a recording loaded during
  /// a save would delete the converted file it embeds.
  Future<void> _queue = Future.value();

  Future<T> _oneAtATime<T>(Future<T> Function() job) {
    final run = _queue.then((_) => job());
    _queue = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  // MARK: Opening

  /// Opens a .ccs project. Either it opens and becomes this document, or (it throws and)
  /// nothing changes. Returns what went wrong with the recording, if anything: the project
  /// still opens without it.
  Future<String?> open(String path) => _oneAtATime(() => _open(path));

  Future<String?> _open(String path) async {
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
      );
      final missing = project.media?.missingPath;
      recordingProblem = problem ?? (missing == null ? null : '${'Can’t find the linked recording:'.tr}\n$missing');
      _olderFormat = project.olderFormat;
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
  Future<void> importScore(String path) => _oneAtATime(() async {
    await controller.openFile(path);
    ScratchSpace.release(_mediaDirectory); // the project before had its recording unpacked there
    _mediaDirectory = null;
    _path = null;
    _isSample = false;
    _olderFormat = false;
    _markSaved(controller.editRevision.value);
    settings.addRecent(path);
  });

  /// Project Info ▸ Replace Score: the score file at [path], engraved with this project's edits
  /// carried over (see [EditorController.prepareReplacement]); nothing changes yet.
  Future<ScoreReplacement> prepareReplacement(String path) =>
      _oneAtATime(() => controller.prepareReplacement(path));

  /// Puts [replacement] in place of the score: the project, its path and recording stay,
  /// with unsaved changes.
  Future<void> replaceScore(ScoreReplacement replacement) =>
      _oneAtATime(() => controller.replaceScore(replacement));

  /// Opens the demo project to try things in; it can't be saved ([isSample]). Returns the
  /// same as [open].
  Future<String?> openSample() => _oneAtATime(() async {
    final data = await rootBundle.load(sampleProjectAsset);
    final folder = ScratchSpace.folder('sample');
    final file = File('${folder.path}${Platform.pathSeparator}${sampleProjectAsset.split('/').last}');
    await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    try {
      final missing = await _open(file.path);
      settings.removeRecent(file.path); // a temporary copy: nothing to reopen
      _path = null;
      _isSample = true;
      _olderFormat = false; // never saved
      _markSaved(controller.editRevision.value);
      return missing;
    } finally {
      ScratchSpace.release(folder); // its score and recording are unpacked by now
    }
  });

  /// Closes the project (File ▸ Close); unsaved changes are the caller's to ask about.
  Future<void> close() => _oneAtATime(() async {
    await controller.close();
    ScratchSpace.release(_mediaDirectory);
    _mediaDirectory = null;
    _path = null;
    _isSample = false;
    _olderFormat = false;
    _markSaved(controller.editRevision.value);
  });

  // MARK: Saving

  /// Saves to [path] (Save As…), or to where the project already is (Save).
  Future<void> save([String? path]) => _oneAtATime(() => _save(path));

  /// One save at a time ([_oneAtATime]); each picks up the edits made until it starts.
  Future<void> _save(String? path) async {
    if (_isSample) throw StateError('The sample can’t be saved.');
    final target = path ?? _path;
    if (target == null) throw StateError('The project has not been saved yet: choose where to save it.');
    final completer = Completer<void>();
    _saving = completer.future;
    notifyListeners();
    try {
      final revision = controller.editRevision.value;
      await ProjectFile.write(target, _contents());
      _path = target;
      _olderFormat = false;
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
    return ProjectContents(
      scoreName: source.name,
      scoreBytes: source.bytes,
      state: controller.projectState,
      media: track == null ? null : ProjectMedia(name: track.name, embedFrom: track.path),
    );
  }

  /// A name for Save As…: the project's, or the score's with .ccs.
  String get suggestedFileName {
    if (_path != null) return fileNameOf(_path!);
    final name = controller.source?.name ?? 'Untitled'.tr;
    return '${stemOf(name)}.${ProjectFile.extension}';
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
  Future<void> autosave() => _oneAtATime(() async {
    // Asked after whatever ran before it: an open may have changed the answers.
    if (_path == null || !_dirty || _isSample) return;
    try {
      await _save(null);
    } catch (e) {
      onAutosaveError?.call(e);
    }
  });

  // MARK: Housekeeping

  /// Where the open project's embedded recording is unpacked.
  Directory? _mediaDirectory;


  @override
  void dispose() {
    _autosaveTimer?.cancel();
    controller.editRevision.removeListener(_edited);
    settings.removeListener(_settingsChanged);
    ScratchSpace.release(_mediaDirectory);
    super.dispose();
  }
}
