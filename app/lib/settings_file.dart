import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:score_engine/score_engine.dart' show ZipEntries;

import 'project_file.dart';
import 'project_state.dart';

/// A project's settings for other projects (.ccf, Project Settings ▸ Export… / Import…): a zip
/// archive holding
///
///     mimetype          application/x-curator-settings (stored first, uncompressed)
///     settings.json     format version, and the settings as a project's `state` writes them
///     fonts/<name>.font an added music font, and its SMuFL metadata, as a project keeps them
///     fonts/<name>.json (only when it is embedded)
///
/// Only the score-wide settings ([of]): what a page of Project Settings sets for the whole score,
/// not for one instrument (brackets, groups' members, pairs), which another score's differ in.
/// Read through [ProjectState.fromJson], so it is checked, and migrated, as a project is.
abstract final class SettingsFile {
  static const extension = 'ccf';
  static const mimeType = 'application/x-curator-settings';

  /// The keys of a project's `state` a settings file keeps; of `curation`, only these.
  static const _keys = {
    'fonts', 'engraving', 'extensions', 'flags', 'motion', 'typography', //
    'groupSections', 'barNumbers', 'playheadColor', 'colorNames', 'nameColors',
  };
  static const _curationKeys = {'transition', 'scrollFollow'};

  /// [edits]' score-wide settings, nothing else.
  static EditState of(EditState edits) => EditState(
        transition: edits.transition,
        scrollFollow: edits.scrollFollow,
        motion: edits.motion,
        typography: edits.typography,
        barNumbers: edits.barNumbers,
        playheadColor: edits.playheadColor,
        colorNames: edits.colorNames,
        nameColors: edits.nameColors,
        groupSections: edits.groupSections,
        captionFont: edits.captionFont,
        fonts: edits.fonts,
        embedFont: edits.embedFont,
        engraving: edits.engraving,
        extensions: edits.extensions,
        textDynamics: edits.textDynamics,
        rehearsalInRow: edits.rehearsalInRow,
        centeredLyrics: edits.centeredLyrics,
      );

  /// Writes [settings] ([of] them), built beside [path] and moved into place at the end.
  static Future<void> write(String path, EditState settings) => Isolate.run(() => _write(path, of(settings)));

  /// Reads a settings file: its settings ([of]). Throws a [FormatException] saying what is wrong.
  static Future<EditState> read(String path) => Isolate.run(() => _read(path));

  static void _write(String path, EditState settings) {
    final state = ProjectState(edits: settings).toJson();
    final manifest = {
      'format': mimeType,
      'version': ProjectState.version,
      'state': {
        for (final key in _keys) key: ?state[key],
        'curation': {
          for (final key in _curationKeys) key: ?(state['curation']! as Map)[key],
        },
      },
    };
    final temp = '$path.saving';
    final out = OutputFileStream(temp);
    final zip = ZipEncoder()..startEncode(out);
    try {
      zip.add(ArchiveFile.noCompress('mimetype', mimeType.length, ascii.encode(mimeType)));
      zip.add(ArchiveFile.string('settings.json', const JsonEncoder.withIndent(' ').convert(manifest)));
      ProjectFile.addFont(zip, settings);
      zip.endEncode();
      out.closeSync();
      File(temp).renameSync(path);
    } catch (_) {
      out.closeSync();
      final f = File(temp);
      if (f.existsSync()) f.deleteSync();
      rethrow;
    }
  }

  static EditState _read(String path) {
    final input = InputFileStream(path);
    try {
      final Archive archive;
      try {
        archive = ZipDecoder().decodeStream(input);
      } on Exception {
        throw const FormatException('This isn’t a Curator settings file.');
      }
      final manifestFile = archive.findFile('settings.json');
      if (manifestFile == null) throw const FormatException('This isn’t a Curator settings file.');
      final manifest =
          JsonReader(jsonDecode(utf8.decode(ZipEntries.read(manifestFile, limit: ProjectFile.maxManifestBytes))), 'settings');
      if (manifest.string('format') != mimeType) throw const FormatException('This isn’t a Curator settings file.');
      final version = manifest.number('version')?.toInt() ?? 0;
      if (version > ProjectState.version) {
        throw const FormatException('These settings need a newer version of Curator. Update to import them.');
      }
      final state = manifest.map('state');
      final ProjectState read;
      try {
        read = ProjectState.fromJson({
        for (final key in _keys) key: ?state[key],
        'curation': {
          for (final MapEntry(:key, :value) in manifest.child('state').map('curation').entries)
            if (_curationKeys.contains(key)) key: value,
        },
        }, savedVersion: version, fontFiles: ProjectFile.fontFilesIn(archive, state));
      } on FormatException catch (e) {
        throw FormatException(e.message.replaceFirst('The project is damaged', 'The settings are damaged'));
      }
      return of(read.edits);
    } finally {
      input.closeSync();
    }
  }
}
