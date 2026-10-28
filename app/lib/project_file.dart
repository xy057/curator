import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:score_engine/score_engine.dart' show ScoreFile, ZipEntries;

import 'file_names.dart';
import 'legacy_project.dart';
import 'media_converter.dart';
import 'project_archive.dart';
import 'project_modules.dart';
import 'project_state.dart';

/// A Curator project (.ccs): a zip archive in [ProjectArchive]'s layout, holding besides its
/// modules (every edit made in the app, [ProjectModules.all])
///
///     score/<name>      the source score file, byte for byte
///     media/<name>      the recording
///
/// both named in the manifest (`score`, `media`: the name and the entry). Everything the app
/// changes lives in the modules, so the source score is never rewritten. One saved before
/// modules ([LegacyProject]) has its edits in project.json instead.
abstract final class ProjectFile {
  static const extension = 'ccs';
  static const mimeType = 'application/x-curated-score';

  static const _notOurs = 'This isn’t a Curator project.';
  static const _newer = 'This project needs a newer version of Curator. Update to open it.';

  /// Writes a project. The archive is built next to [path] and moved into place at the end,
  /// so a failed save (or a crash during an autosave) never damages the previous file.
  /// Runs on a background isolate: embedding a long video takes a moment.
  static Future<void> write(String path, ProjectContents contents) => Isolate.run(() => _write(path, contents));

  /// Reads a project. Its recording is unpacked into [mediaDirectory]. A project saved before
  /// recordings were always embedded may link to one instead: that is looked for next to the
  /// project first (so a folder can be moved as a whole), then at its original location, and
  /// only when it is a recording ([MediaFormats]). The next save embeds it.
  static Future<OpenedProject> read(String path, {required String mediaDirectory}) =>
      Isolate.run(() => _read(path, mediaDirectory));

  static void _write(String path, ProjectContents c) {
    final media = c.media;
    final mediaEntry = media == null ? null : 'media/${safeFileName(media.name)}';
    final scoreEntry = 'score/${safeFileName(c.scoreName)}';

    final temp = '$path.saving';
    final out = OutputFileStream(temp);
    // zlib's default level: ZipEncoder's own (1) is no faster here and makes a score 60 % bigger;
    // the best (9) takes twice as long for a few percent.
    final zip = ZipEncoder()..startEncode(out, level: DeflateLevel.defaultCompression);
    InputFileStream? mediaStream;
    try {
      ProjectArchive.write(zip, c.state, mimeType: mimeType, stub: 'project.json', modules: ProjectModules.all, manifest: {
        'score': {'name': c.scoreName, 'entry': scoreEntry},
        if (media != null) 'media': {'name': media.name, 'entry': mediaEntry},
      });
      zip.add(ArchiveFile.bytes(scoreEntry, c.scoreBytes));
      // Last: everything before it can be read without passing it.
      if (mediaEntry != null) {
        final source = media!.embedFrom;
        if (!File(source).existsSync()) {
          throw FileSystemException('Can’t find the recording to embed', source);
        }
        mediaStream = InputFileStream(source);
        // Audio and video are compressed already; deflating them again only costs time.
        zip.add(ArchiveFile.stream(mediaEntry, mediaStream)..compression = CompressionType.none);
      }
      zip.endEncode();
      out.closeSync();
      mediaStream?.closeSync();
      File(temp).renameSync(path);
    } catch (_) {
      out.closeSync();
      mediaStream?.closeSync();
      final f = File(temp);
      if (f.existsSync()) f.deleteSync();
      rethrow;
    }
  }

  static OpenedProject _read(String path, String mediaDirectory) {
    final input = InputFileStream(path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final JsonReader manifest;
      final ProjectState state;
      final legacy = !ProjectArchive.isModular(archive);
      if (legacy) {
        final manifestFile = archive.findFile('project.json');
        if (manifestFile == null) throw const FormatException(_notOurs);
        manifest = JsonReader(jsonDecode(utf8.decode(ZipEntries.read(manifestFile, limit: ProjectArchive.maxJsonBytes))), 'project');
        if (manifest.string('format') != mimeType) throw const FormatException(_notOurs);
        // A stub with no manifest (one past the last format) is from a newer layout too.
        final version = manifest.number('version')?.toInt() ?? 0;
        if (version > LegacyProject.lastVersion) throw const FormatException(_newer);
        state = ProjectArchive.readLegacy(archive, manifest.map('state'), version, ProjectModules.all);
      } else {
        manifest = ProjectArchive.manifestOf(archive, mimeType: mimeType, notOurs: _notOurs, newer: _newer);
        state = ProjectArchive.read(archive, manifest, ProjectModules.all, newer: _newer);
      }

      final score = manifest.child('score');
      final scoreFile = archive.findFile(score.string('entry', required: true)!);
      if (scoreFile == null) throw const FormatException('The project has no score in it.');

      ProjectMediaLocation? media;
      if (!manifest.isAbsent('media')) {
        final m = manifest.child('media');
        final name = m.string('name', required: true)!;
        // Only a project saved before recordings were always embedded links to one.
        final original = legacy ? m.string('path') : null;
        final relative = legacy ? m.string('relativePath') : null;
        final entry = m.string('entry');
        final candidates = [
          if (relative != null) _join(File(path).parent.path, relative),
          if (original != null && isLocalPath(original)) original,
        ];
        // Only a recording: whatever else a project names is never opened.
        final linked = candidates.where((p) => MediaFormats.isRecording(p) && File(p).existsSync()).firstOrNull;
        String? playable;
        // Unpacked only under a recording's name: what it is called decides what reads it.
        if (entry != null && MediaFormats.isRecording(name)) {
          final file = archive.findFile(entry);
          if (file != null) {
            Directory(mediaDirectory).createSync(recursive: true);
            playable = _join(mediaDirectory, safeFileName(name));
            final out = OutputFileStream(playable);
            try {
              // Stored as it is (see [_write]), so never much more than the project itself.
              ZipEntries.write(file, out.writeBytes, limit: 4 * File(path).lengthSync() + (64 << 20));
            } finally {
              out.closeSync();
            }
          }
        }
        media = ProjectMediaLocation(
          name: name,
          path: playable ?? linked,
          missingPath: playable == null && linked == null ? (original ?? relative) : null,
        );
      }

      return OpenedProject(
        scoreName: score.string('name', required: true)!,
        scoreBytes: ZipEntries.read(scoreFile, limit: ScoreFile.maxBytes),
        state: state,
        media: media,
      );
    } finally {
      input.closeSync();
    }
  }

  /// Whether [path] is an absolute path on this computer's own disks: `C:\…`, or `/…` but not
  /// `//server/…` or macOS's `/net` and `/Network` (which mount other computers). Only looking
  /// for a file elsewhere already connects there, and Windows signs in to a share as the user,
  /// so the location a project gives is used only when it is local.
  static bool isLocalPath(String path) {
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)) return true;
    final lower = path.toLowerCase();
    return path.startsWith('/') &&
        !path.startsWith('//') &&
        !RegExp(r'^/(net|network)(/|$)').hasMatch(lower);
  }

  static String _join(String dir, String name) => '$dir${Platform.pathSeparator}$name';
}

/// Everything a save writes.
class ProjectContents {
  const ProjectContents({required this.scoreName, required this.scoreBytes, required this.state, this.media});

  final String scoreName;
  final Uint8List scoreBytes;

  /// The app's edits and view.
  final ProjectState state;
  final ProjectMedia? media;
}

/// The recording, as a save should store it.
class ProjectMedia {
  const ProjectMedia({required this.name, required this.embedFrom});

  final String name;

  /// The file whose bytes are embedded (the playable copy).
  final String embedFrom;
}

/// What [ProjectFile.read] found.
class OpenedProject {
  const OpenedProject({required this.scoreName, required this.scoreBytes, required this.state, this.media});

  final String scoreName;
  final Uint8List scoreBytes;
  final ProjectState state;
  final ProjectMediaLocation? media;
}

class ProjectMediaLocation {
  const ProjectMediaLocation({required this.name, this.path, this.missingPath});

  final String name;

  /// A file that can be played: the unpacked copy, or the linked original. Null when missing.
  final String? path;

  /// Where a linked recording was expected, when it could not be found.
  final String? missingPath;
}
