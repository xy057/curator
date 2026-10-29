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
///     media/<name>      the focus's recording ([EditState.focus])
///     media/takes/<id>/<name>  each other recording ([EditState.takes])
///
/// all named in the manifest (`score`, `media`, `takes`: the name and the entry, and a take's id). Everything the app
/// changes lives in the modules, so the source score is never rewritten. One saved before
/// modules ([LegacyProject]) has its edits in project.json instead.
abstract final class ProjectFile {
  static const extension = 'ccs';
  static const mimeType = 'application/x-curated-score';

  static const _notOurs = 'That doesn’t look like a Curator project.';
  static const _newer = 'This project is from a newer Curator. Update to open it!';

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
    final takeEntries = {for (final MapEntry(key: id, value: m) in c.takes.entries) id: 'media/takes/$id/${safeFileName(m.name)}'};
    final scoreEntry = 'score/${safeFileName(c.scoreName)}';

    final temp = '$path.saving';
    final out = OutputFileStream(temp);
    // zlib's default level: ZipEncoder's own (1) is no faster here and makes a score 60 % bigger;
    // the best (9) takes twice as long for a few percent.
    final zip = ZipEncoder()..startEncode(out, level: DeflateLevel.defaultCompression);
    final streams = <InputFileStream>[];
    try {
      ProjectArchive.write(zip, c.state, mimeType: mimeType, stub: 'project.json', modules: ProjectModules.all, manifest: {
        'score': {'name': c.scoreName, 'entry': scoreEntry},
        if (media != null) 'media': {'name': media.name, 'entry': mediaEntry},
        if (c.takes.isNotEmpty)
          'takes': [
            for (final MapEntry(key: id, value: m) in c.takes.entries) {'id': id, 'name': m.name, 'entry': takeEntries[id]},
          ],
      });
      zip.add(ArchiveFile.bytes(scoreEntry, c.scoreBytes));
      // Last: everything before them can be read without passing them.
      for (final (entry, m) in [
        if (mediaEntry != null) (mediaEntry, media!),
        for (final MapEntry(key: id, value: m) in c.takes.entries) (takeEntries[id]!, m),
      ]) {
        if (!File(m.embedFrom).existsSync()) {
          throw FileSystemException('Can’t find the recording to embed', m.embedFrom);
        }
        final stream = InputFileStream(m.embedFrom);
        streams.add(stream);
        // Audio and video are compressed already; deflating them again only costs time.
        zip.add(ArchiveFile.stream(entry, stream)..compression = CompressionType.none);
      }
      zip.endEncode();
      out.closeSync();
      for (final s in streams) {
        s.closeSync();
      }
      File(temp).renameSync(path);
    } catch (_) {
      out.closeSync();
      for (final s in streams) {
        s.closeSync();
      }
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

      // Stored as it is (see [_write]), so never much more than the project itself.
      final limit = 4 * File(path).lengthSync() + (64 << 20);
      var unpacked = 0;
      // Unpacked only under a recording's name: what it is called decides what reads it.
      String? unpack(String entry, String name, String folder) {
        final file = archive.findFile(entry);
        if (file == null || !MediaFormats.isRecording(name)) return null;
        Directory(folder).createSync(recursive: true);
        final playable = _join(folder, safeFileName(name));
        final out = OutputFileStream(playable);
        try {
          ZipEntries.write(file, (bytes) {
            unpacked += bytes.length;
            out.writeBytes(bytes);
          }, limit: limit - unpacked);
        } finally {
          out.closeSync();
        }
        return playable;
      }

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
        final playable = entry == null ? null : unpack(entry, name, mediaDirectory);
        media = ProjectMediaLocation(
          name: name,
          path: playable ?? linked,
          missingPath: playable == null && linked == null ? (original ?? relative) : null,
        );
      }

      // The other recordings: each one the takes module names, in a folder of its own.
      final takes = <String, String>{};
      for (final (i, value) in manifest.list('takes').indexed) {
        final t = JsonReader(value, 'manifest.takes[$i]');
        final id = t.string('id', required: true)!, entry = t.string('entry', required: true)!;
        if (!state.edits.takes.any((take) => take.id == id) || id == state.edits.focus || takes.containsKey(id)) continue;
        if (unpack(entry, t.string('name', required: true)!, _join(mediaDirectory, id)) case final playable?) takes[id] = playable;
      }

      return OpenedProject(
        takes: takes,
        scoreName: score.string('name', required: true)!,
        scoreBytes: ZipEntries.read(scoreFile, limit: ScoreFile.maxBytes),
        state: state,
        media: media,
        olderFormat: legacy,
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
  const ProjectContents({required this.scoreName, required this.scoreBytes, required this.state, this.media, this.takes = const {}});

  final String scoreName;
  final Uint8List scoreBytes;

  /// The app's edits and view.
  final ProjectState state;
  final ProjectMedia? media;

  /// The recordings besides the focus's ([media]), by [Take.id].
  final Map<String, ProjectMedia> takes;
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
  const OpenedProject(
      {required this.scoreName, required this.scoreBytes, required this.state, this.media, this.takes = const {}, this.olderFormat = false});

  final String scoreName;
  final Uint8List scoreBytes;
  final ProjectState state;
  final ProjectMediaLocation? media;

  /// The recordings besides the focus's, unpacked, by [Take.id]: a take not here has none.
  final Map<String, String> takes;

  /// Whether it was saved before modules ([LegacyProject]: Curator 0.6.1 and before). A save
  /// writes the new format, which those versions can't open.
  final bool olderFormat;
}

class ProjectMediaLocation {
  const ProjectMediaLocation({required this.name, this.path, this.missingPath});

  final String name;

  /// A file that can be played: the unpacked copy, or the linked original. Null when missing.
  final String? path;

  /// Where a linked recording was expected, when it could not be found.
  final String? missingPath;
}
