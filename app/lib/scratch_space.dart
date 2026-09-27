import 'dart:io';

/// Where the app keeps files it makes along the way: recordings unpacked from projects, audio
/// converted from videos, the sample project's copy.
///
/// Each running app gets one folder, `<system temp>/curated-score/session-…`, and holds a lock
/// on a file inside it for as long as it runs. Whatever a job no longer needs is deleted right
/// away ([release]); the whole folder goes when the app quits ([close]). A crash can't clean up,
/// so [sweep] (at start-up) deletes every folder whose lock can be taken: its app is gone.
abstract final class ScratchSpace {
  static Directory get root => Directory('${Directory.systemTemp.path}${Platform.pathSeparator}curated-score');

  static Directory? _session;
  static RandomAccessFile? _lock;
  static var _count = 0;

  static const _lockName = '.lock';

  /// This app's folder, created (and locked) on first use.
  static Directory get session {
    final existing = _session;
    if (existing != null && existing.existsSync()) return existing;
    final dir = Directory('${root.path}${Platform.pathSeparator}session-$pid-${DateTime.now().microsecondsSinceEpoch}')
      ..createSync(recursive: true);
    _lock = File('${dir.path}${Platform.pathSeparator}$_lockName').openSync(mode: FileMode.write)
      ..lockSync(FileLock.exclusive);
    return _session = dir;
  }

  /// A new, empty folder for one job, e.g. `folder('recording')`.
  static Directory folder(String purpose) =>
      Directory('${session.path}${Platform.pathSeparator}$purpose-${++_count}')..createSync(recursive: true);

  /// Deletes a job's folder (or file) once nothing needs it any more.
  static void release(FileSystemEntity? entity) {
    if (entity == null) return;
    try {
      entity.deleteSync(recursive: true);
    } on FileSystemException {
      // already gone, or still open elsewhere: the session's clean-up gets it later
    }
  }

  /// Deletes this app's folder (when it quits).
  static void close() {
    final dir = _session;
    _session = null;
    _lock?.closeSync();
    _lock = null;
    release(dir);
  }

  /// Deletes what apps that are no longer running left behind. [keep] is this app's session.
  /// Safe to run on another isolate.
  static void sweep({String? keep}) {
    final base = root;
    if (!base.existsSync()) return;
    for (final entity in base.listSync()) {
      if (entity.path == keep) continue;
      if (entity is Directory && entity.path.split(Platform.pathSeparator).last.startsWith('session-')) {
        if (_isAbandoned(entity)) release(entity);
      } else {
        release(entity); // loose files and folders from before sessions existed
      }
    }
  }

  static bool _isAbandoned(Directory dir) {
    final lock = File('${dir.path}${Platform.pathSeparator}$_lockName');
    if (!lock.existsSync()) return true;
    RandomAccessFile? file;
    try {
      file = lock.openSync(mode: FileMode.append);
      file.lockSync(FileLock.exclusive); // throws while its app still holds it
      file.unlockSync();
      return true;
    } on FileSystemException {
      return false;
    } finally {
      file?.closeSync();
    }
  }
}
