import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

import 'image_patch.dart';
import 'media_converter.dart';
import 'project_state.dart';

/// How a project keeps its recording.
enum MediaStorage {
  /// A copy travels inside the .ccs: bigger, but self-contained.
  embed,

  /// Only the recording's location is saved: small, but the file has to stay where it is.
  link,
}

/// A Curator project (.ccs): a zip archive holding
///
///     mimetype          application/x-curated-score (stored first, uncompressed)
///     project.json      format version, where things are, and every edit made in the app
///     score/<name>      the source score file, byte for byte
///     media/<name>      the recording, when it is embedded
///     images/<id>       each image on the score (Attach Image), byte for byte
///     fonts/<name>.font an added music font the score is engraved in, and its SMuFL
///     fonts/<name>.json metadata (if it has some)
///
/// Everything the app changes (curation, sync, texts, names…) lives in project.json, so
/// the source score is never rewritten.
abstract final class ProjectFile {
  static const extension = 'ccs';
  static const mimeType = 'application/x-curated-score';
  static const formatVersion = ProjectState.version;

  /// Writes a project. The archive is built next to [path] and moved into place at the end,
  /// so a failed save (or a crash during an autosave) never damages the previous file.
  /// Runs on a background isolate: embedding a long video takes a moment.
  static Future<void> write(String path, ProjectContents contents) => Isolate.run(() => _write(path, contents));

  /// Reads a project. An embedded recording is unpacked into [mediaDirectory]; a linked one
  /// is looked for next to the project first (so a folder can be moved as a whole), then at
  /// its original location, and only when it is a recording ([MediaFormats]).
  static Future<OpenedProject> read(String path, {required String mediaDirectory}) =>
      Isolate.run(() => _read(path, mediaDirectory));

  static void _write(String path, ProjectContents c) {
    final media = c.media;
    final String? mediaEntry;
    if (media != null && media.storage == MediaStorage.embed) {
      mediaEntry = 'media/${_safeName(media.name)}';
    } else {
      mediaEntry = null;
      if (media != null && media.originalPath == null) {
        throw FileSystemException('The recording has no file of its own to link to; embed it instead', media.name);
      }
    }
    final scoreEntry = 'score/${_safeName(c.scoreName)}';
    final manifest = {
      'format': mimeType,
      'version': formatVersion,
      'score': {'name': c.scoreName, 'entry': scoreEntry},
      if (media != null)
        'media': {
          'name': media.name,
          'entry': ?mediaEntry,
          // Kept for embedded media too, so switching to "link" later knows where it came from.
          'path': ?media.originalPath,
          if (media.originalPath != null) 'relativePath': _relative(media.originalPath!, File(path).parent.path),
        },
      'state': c.state.toJson(),
    };

    final temp = '$path.saving';
    final out = OutputFileStream(temp);
    final zip = ZipEncoder()..startEncode(out);
    InputFileStream? mediaStream;
    try {
      zip.add(ArchiveFile.noCompress('mimetype', mimeType.length, ascii.encode(mimeType)));
      zip.add(ArchiveFile.string('project.json', const JsonEncoder.withIndent(' ').convert(manifest)));
      zip.add(ArchiveFile.bytes(scoreEntry, c.scoreBytes));
      // Only the images still on the score (Undo keeps the rest while the project is open).
      for (final id in {for (final p in c.state.patches) p.image}) {
        final image = c.state.images[id];
        if (image == null || !PatchImage.isId(id)) throw FileSystemException('An image on the score is missing', id);
        zip.add(ArchiveFile.bytes('images/$id', image.bytes)..compression = image.kind == ImageKind.vector ? CompressionType.deflate : CompressionType.none);
      }
      final music = c.state.fonts.music;
      if (music.file case final file?) {
        zip.add(ArchiveFile.bytes('fonts/${_safeName(music.name)}.font', file));
        if (music.metadata case final metadata?) zip.add(ArchiveFile.bytes('fonts/${_safeName(music.name)}.json', metadata));
      }
      if (mediaEntry != null) {
        final source = media!.embedFrom;
        if (source == null || !File(source).existsSync()) {
          throw FileSystemException('The recording to embed was not found', source);
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
      final manifestFile = archive.findFile('project.json');
      if (manifestFile == null) throw const FormatException('This is not a Curator project.');
      final manifest = JsonReader(jsonDecode(utf8.decode(manifestFile.content)), 'project');
      if (manifest.string('format') != mimeType) throw const FormatException('This is not a Curator project.');
      final version = manifest.number('version')?.toInt() ?? 0;
      if (version > formatVersion) {
        throw const FormatException('This project was saved by a newer version of Curator.');
      }

      final score = manifest.child('score');
      final scoreFile = archive.findFile(score.string('entry', required: true)!);
      if (scoreFile == null) throw const FormatException('The project has no score in it.');

      ProjectMediaLocation? media;
      if (!manifest.isAbsent('media')) {
        final m = manifest.child('media');
        final name = m.string('name', required: true)!;
        final original = m.string('path');
        final relative = m.string('relativePath');
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
            playable = _join(mediaDirectory, _safeName(name));
            final out = OutputFileStream(playable);
            file.writeContent(out);
            out.closeSync();
          }
        }
        media = ProjectMediaLocation(
          name: name,
          path: playable ?? linked,
          originalPath: linked,
          missingPath: playable == null && linked == null ? (original ?? relative) : null,
        );
      }

      final stateJson = manifest.map('state');
      return OpenedProject(
        scoreName: score.string('name', required: true)!,
        scoreBytes: scoreFile.content,
        // Only the images on the score are read (and so decoded): any others are left in the zip.
        state: ProjectState.fromJson(stateJson, savedVersion: version, images: {
          for (final id in {
            if (stateJson['patches'] case final List patches)
              for (final p in patches)
                if (p case {'image': final String id}) id,
          })
            if ((PatchImage.kindOfId(id), archive.findFile('images/$id')) case (final kind?, final file?) when file.isFile)
              id: PatchImage(id, kind, file.content),
        }, fontFiles: {
          for (final file in archive.files)
            if (file.isFile && file.name.startsWith('fonts/') && file.name.endsWith('.font'))
              file.name.substring(6, file.name.length - 5): (
                file: file.content,
                metadata: archive.findFile('${file.name.substring(0, file.name.length - 5)}.json')?.content,
              ),
        }),
        media: media,
      );
    } finally {
      input.closeSync();
    }
  }

  /// A file name that is safe as a zip entry and on every file system.
  static String _safeName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_').trim();
    return cleaned.isEmpty ? 'file' : cleaned;
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

  /// [target] relative to [from] (both absolute), with '/' separators.
  static String _relative(String target, String from) {
    List<String> parts(String p) => p.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty).toList();
    final t = parts(target), f = parts(from);
    var common = 0;
    while (common < math.min(t.length, f.length) && t[common] == f[common]) {
      common++;
    }
    return [for (var i = common; i < f.length; i++) '..', ...t.skip(common)].join('/');
  }
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
  const ProjectMedia({required this.name, required this.storage, this.embedFrom, this.originalPath});

  final String name;
  final MediaStorage storage;

  /// The file whose bytes are embedded (the playable copy; for embed only).
  final String? embedFrom;

  /// The recording's own file on disk, if there is one: what a link points to.
  final String? originalPath;
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
  const ProjectMediaLocation({required this.name, this.path, this.originalPath, this.missingPath});

  final String name;

  /// A file that can be played: the unpacked copy, or the linked original. Null when missing.
  final String? path;

  /// The recording's own file, when it still exists.
  final String? originalPath;

  /// Where a linked recording was expected, when it could not be found.
  final String? missingPath;
}
