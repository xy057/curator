import 'dart:io';

import 'package:flutter/foundation.dart';

/// Where the app keeps files it makes along the way: recordings unpacked from projects, audio
/// converted from videos, the sample project's copy.
///
/// Each running app gets one folder, `<root>/session-…` (see [rootFor]), and holds a lock
/// on a file inside it for as long as it runs. Whatever a job no longer needs is deleted right
/// away ([release]); the whole folder goes when the app quits ([close]). A crash can't clean up,
/// so [sweep] (at start-up) deletes every folder whose lock can be taken: its app is gone.
abstract final class ScratchSpace {
  static Directory get root => Directory(rootFor(Platform.operatingSystem, Directory.systemTemp.path, Platform.environment));

  /// Where the sessions go: `curated-score` in the system's temporary folder, which macOS and
  /// Windows give each user. Linux's `/tmp` is everyone's: another user could make that folder
  /// (or a link of that name) first, and then see or receive what the app writes and sweeps.
  /// There it is the user's own cache folder.
  @visibleForTesting
  static String rootFor(String os, String temp, Map<String, String> env) {
    if (os != 'linux') return '$temp${Platform.pathSeparator}curated-score';
    final xdg = env['XDG_CACHE_HOME'];
    final cache = xdg != null && xdg.startsWith('/') ? xdg : '${env['HOME'] ?? temp}/.cache';
    return '$cache/curated-score/scratch';
  }

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
  /// Safe to run on another isolate. Links are never followed: a link is removed, not what it
  /// points to, and a root that is itself a link is left alone.
  static void sweep({String? keep, @visibleForTesting Directory? within}) {
    final base = within ?? root;
    if (!base.existsSync() || FileSystemEntity.isLinkSync(base.path)) return;
    for (final entity in base.listSync(followLinks: false)) {
      if (entity.path == keep) continue;
      if (entity is Link) {
        release(entity);
      } else if (entity is Directory && entity.path.split(Platform.pathSeparator).last.startsWith('session-')) {
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
