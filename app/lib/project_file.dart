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
///     media/stems/<id>/<name>  each stem ([EditState.stems])
///
/// all named in its fields in project.cura (`score`, `media`, `takes`, `stems`: the name and the
/// entry, and a take's or stem's id), with the project's `kind` ([ProjectKind]). Everything the
/// app changes lives in the modules, so the source score is never rewritten. One saved by
/// Curator 0.7 to 0.11.0-beta1 has them in manifest.json and its modules in JSON; one saved before
/// modules ([LegacyProject]), its edits in project.json.
abstract final class ProjectFile {
  static const extension = 'ccs';
  static const mimeType = 'application/x-curated-score';

  /// The stub Curator 0.6.1 and before read; the project in CuraScript is `project.cura`
  /// ([ProjectArchive.documentOf]).
  static const stub = 'project.json';
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
    final stemEntries = {for (final MapEntry(key: id, value: m) in c.stems.entries) id: 'media/stems/$id/${safeFileName(m.name)}'};
    final scoreEntry = 'score/${safeFileName(c.scoreName)}';

    ProjectArchive.writeFile(path, (zip, opened) {
      ProjectArchive.write(zip, c.state, mimeType: mimeType, stub: stub, modules: ProjectModules.all, fields: {
        'kind': c.state.kind.name,
        'score': {'name': c.scoreName, 'entry': scoreEntry},
        if (media != null)
          'media': {'name': media.name, 'entry': mediaEntry}
        else if (c.missingMedia case final m?)
          // Linked, and not found when the project was opened: where it was is kept, so the
          // project still says so, and finds it once it is back.
          'media': {'name': m.name, 'path': ?m.path, 'relativePath': ?m.relativePath},
        if (c.takes.isNotEmpty)
          'takes': [
            for (final MapEntry(key: id, value: m) in c.takes.entries) {'id': id, 'name': m.name, 'entry': takeEntries[id]},
          ],
        if (c.stems.isNotEmpty)
          'stems': [
            for (final MapEntry(key: id, value: m) in c.stems.entries) {'id': id, 'name': m.name, 'entry': stemEntries[id]},
          ],
      });
      zip.add(ArchiveFile.bytes(scoreEntry, c.scoreBytes));
      // Last: everything before them can be read without passing them.
      for (final (entry, m) in [
        if (mediaEntry != null) (mediaEntry, media!),
        for (final MapEntry(key: id, value: m) in c.takes.entries) (takeEntries[id]!, m),
        for (final MapEntry(key: id, value: m) in c.stems.entries) (stemEntries[id]!, m),
      ]) {
        if (!File(m.embedFrom).existsSync()) {
          throw FileSystemException('Can’t find the recording to embed', m.embedFrom);
        }
        final stream = InputFileStream(m.embedFrom);
        opened.add(stream);
        // Audio and video are compressed already; deflating them again only costs time.
        zip.add(ArchiveFile.stream(entry, stream)..compression = CompressionType.none);
      }
    });
  }

  static OpenedProject _read(String path, String mediaDirectory) {
    final input = InputFileStream(path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final (:fields, :state, :layout) =
          ProjectArchive.load(archive, mimeType: mimeType, stub: stub, modules: ProjectModules.all, notOurs: _notOurs, newer: _newer);
      final legacy = layout == 1; // before modules: Curator 0.6.1 and before
      // A kind this build doesn't know (a newer one's): what its score is.
      final kind = ProjectKind.values.asNameMap()[fields.string('kind')] ?? state.kind;

      final score = fields.child('score');
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
      if (!fields.isAbsent('media')) {
        final m = fields.child('media');
        final name = m.string('name', required: true)!;
        // Only a project saved before recordings were always embedded links to one, or one
        // saved since while that recording couldn't be found (it has none embedded).
        final entry = m.string('entry');
        final links = legacy || entry == null;
        final original = links ? m.string('path') : null;
        final relative = links ? m.string('relativePath') : null;
        final candidates = [
          if (relative != null) _join(File(path).parent.path, relative),
          if (original != null && isLocalPath(original)) original,
        ];
        // Only a recording: whatever else a project names is never opened.
        final linked = candidates.where((p) => MediaFormats.isRecording(p) && File(p).existsSync()).firstOrNull;
        final playable = entry == null ? null : unpack(entry, name, mediaDirectory);
        final missing = playable == null && linked == null && (original ?? relative) != null;
        media = ProjectMediaLocation(
          name: name,
          path: playable ?? linked,
          missingPath: missing ? (original ?? relative) : null,
          link: missing ? (name: name, path: original, relativePath: relative) : null,
        );
      }

      // The other recordings: each one the takes module names, in a folder of its own. Every one
      // listed when the module is a newer build's, kept unread ([ProjectState.foreign]): a save
      // writes them back with it.
      final takes = <String, String>{};
      final unreadTakes = state.foreign.containsKey(ProjectModules.takes.id);
      for (final (i, value) in fields.list('takes').indexed) {
        final t = JsonReader(value, '${fields.where}.takes[$i]');
        final id = t.string('id', required: true)!, entry = t.string('entry', required: true)!;
        if (!ProjectModules.isTakeId(id) || takes.containsKey(id)) continue;
        if (!unreadTakes && (!state.edits.takes.any((take) => take.id == id) || id == state.edits.focus)) continue;
        if (unpack(entry, t.string('name', required: true)!, _join(mediaDirectory, id)) case final playable?) takes[id] = playable;
      }

      // The stems: each one the stems module names, as the takes are.
      final stems = <String, String>{};
      final unreadStems = state.foreign.containsKey(ProjectModules.stems.id);
      for (final (i, value) in fields.list('stems').indexed) {
        final t = JsonReader(value, '${fields.where}.stems[$i]');
        final id = t.string('id', required: true)!, entry = t.string('entry', required: true)!;
        if (!Stem.isId(id) || stems.containsKey(id)) continue;
        if (!unreadStems && !state.edits.stems.any((stem) => stem.id == id)) continue;
        if (unpack(entry, t.string('name', required: true)!, _join(_join(mediaDirectory, 'stems'), id)) case final playable?) stems[id] = playable;
      }

      return OpenedProject(
        takes: takes,
        stems: stems,
        scoreName: score.string('name', required: true)!,
        scoreBytes: ZipEntries.read(scoreFile, limit: ScoreFile.maxBytes),
        state: state.copyWith(kind: kind),
        media: media,
        olderFormat: layout < ProjectArchive.layout,
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
  const ProjectContents(
      {required this.scoreName,
      required this.scoreBytes,
      required this.state,
      this.media,
      this.missingMedia,
      this.takes = const {},
      this.stems = const {}});

  final String scoreName;
  final Uint8List scoreBytes;

  /// The app's edits and view.
  final ProjectState state;
  final ProjectMedia? media;

  /// With no [media]: the recording the project linked to and couldn't find when it was opened
  /// ([ProjectMediaLocation.link]), kept as it was named.
  final MissingMedia? missingMedia;

  /// The recordings besides the focus's ([media]), by [Take.id].
  final Map<String, ProjectMedia> takes;

  /// The stems' files, by [Stem.id].
  final Map<String, ProjectMedia> stems;
}

/// A recording a project links to that wasn't found: its [name], and where it was, as the
/// project says it ([path], and [relativePath] from the project's folder).
typedef MissingMedia = ({String name, String? path, String? relativePath});

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
      {required this.scoreName,
      required this.scoreBytes,
      required this.state,
      this.media,
      this.takes = const {},
      this.stems = const {},
      this.olderFormat = false});

  final String scoreName;
  final Uint8List scoreBytes;
  final ProjectState state;
  final ProjectMediaLocation? media;

  /// The recordings besides the focus's, unpacked, by [Take.id]: a take not here has none.
  /// With the takes module unread (a newer build's), every one the file lists.
  final Map<String, String> takes;

  /// The stems' files, unpacked, by [Stem.id]: a stem not here has none. With the stems module
  /// unread (a newer build's), every one the file lists.
  final Map<String, String> stems;

  /// Whether it was saved in an older format: before modules ([LegacyProject]: Curator 0.6.1
  /// and before), or with its modules in JSON (layout 2: Curator 0.7 to 0.11.0-beta1). A save writes
  /// it in CuraScript, which those versions can't open.
  final bool olderFormat;
}

class ProjectMediaLocation {
  const ProjectMediaLocation({required this.name, this.path, this.missingPath, this.link});

  final String name;

  /// A file that can be played: the unpacked copy, or the linked original. Null when missing.
  final String? path;

  /// Where a linked recording was expected, when it could not be found.
  final String? missingPath;

  /// The link itself then, for a save to keep ([ProjectContents.missingMedia]).
  final MissingMedia? link;
}
