import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:score_engine/score_engine.dart' show ZipEntries;

import 'legacy_project.dart';
import 'project_archive.dart';
import 'project_modules.dart';
import 'project_state.dart';

/// A project's settings for other projects (.ccf, Project Settings ▸ Export… / Import…): a zip
/// archive in [ProjectArchive]'s layout, as a project is, holding only the score-wide modules
/// ([ProjectModules.settings]: fonts, with an added music font's file, engraving, display,
/// extensions), as [of] leaves them: what a page of Project Settings sets for the whole score,
/// not for one instrument (brackets, groups' members, pairs), which another score's differ in.
/// One saved before modules ([LegacyProject]) has them in settings.json, as a project's `state`.
abstract final class SettingsFile {
  static const extension = 'ccf';
  static const mimeType = 'application/x-curator-settings';

  static const _notOurs = 'This isn’t a Curator settings file.';
  static const _newer = 'These settings need a newer version of Curator. Update to import them.';

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

  /// Reads a settings file: its settings ([of]), and whether it was saved before modules
  /// ([LegacyProject]: Curator 0.6.1 and before; it is never written so). Throws a
  /// [FormatException] saying what is wrong.
  static Future<({EditState settings, bool olderFormat})> read(String path) => Isolate.run(() => _read(path));

  static void _write(String path, EditState settings) {
    final temp = '$path.saving';
    final out = OutputFileStream(temp);
    final zip = ZipEncoder()..startEncode(out, level: DeflateLevel.defaultCompression); // as a project ([ProjectFile])
    try {
      ProjectArchive.write(zip, ProjectState(edits: settings), mimeType: mimeType, stub: 'settings.json', modules: ProjectModules.settings);
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

  static ({EditState settings, bool olderFormat}) _read(String path) {
    final input = InputFileStream(path);
    try {
      final Archive archive;
      try {
        archive = ZipDecoder().decodeStream(input);
      } on Exception {
        throw const FormatException(_notOurs);
      }
      try {
        if (ProjectArchive.isModular(archive)) {
          final manifest = ProjectArchive.manifestOf(archive, mimeType: mimeType, notOurs: _notOurs, newer: _newer);
          return (settings: of(ProjectArchive.read(archive, manifest, ProjectModules.settings, newer: _newer, keepForeign: false).edits), olderFormat: false);
        }
        final manifestFile = archive.findFile('settings.json');
        if (manifestFile == null) throw const FormatException(_notOurs);
        final manifest = JsonReader(jsonDecode(utf8.decode(ZipEntries.read(manifestFile, limit: ProjectArchive.maxJsonBytes))), 'settings');
        if (manifest.string('format') != mimeType) throw const FormatException(_notOurs);
        final version = manifest.number('version')?.toInt() ?? 0;
        if (version > LegacyProject.lastVersion) throw const FormatException(_newer);
        return (settings: of(ProjectArchive.readLegacy(archive, manifest.map('state'), version, ProjectModules.settings).edits), olderFormat: true);
      } on FormatException catch (e) {
        throw FormatException(e.message.replaceFirst('The project is damaged', 'The settings are damaged'));
      }
    } finally {
      input.closeSync();
    }
  }
}
