import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:score_engine/score_engine.dart' show ZipEntries;

import 'legacy_project.dart';
import 'project_modules.dart';
import 'project_state.dart';
import 'updater.dart' show appBuild, appVersion;

/// The layout projects (.ccs, [ProjectFile]) and settings files (.ccf, [SettingsFile]) share: a
/// zip archive holding
///
///     mimetype           the kind of file (stored first, uncompressed)
///     project.json       (settings.json for settings) only for Curator 0.6.1 and before, which
///                        read nothing else: format 27, past theirs, so they ask for an update
///     manifest.json      the kind of file, the layout's version, what wrote it, and each
///                        module's version (and whether it may go unread)
///     modules/<id>.json  each module ([ProjectModules]): a part of the edits, compact JSON
///     <id>/…             a module's own files (images/<id>, fonts/<name>.font)
///     …                  the kind of file's own (a project's score/ and media/)
///
/// A file older than this ([LegacyProject]) has no manifest: its stub was all there was.
abstract final class ProjectArchive {
  /// The layout's version: changed only when the archive's own shape does, never for a
  /// module's ([ProjectModule.version]).
  static const layout = 2;

  /// What [stub] says its format is.
  static const stubVersion = LegacyProject.lastVersion + 1;
  static const manifestEntry = 'manifest.json';

  /// The most the manifest, or a module's JSON, may unpack to; and modules this build can't
  /// read, with their files, together. What a project unpacks is counted as it comes
  /// ([ZipEntries]): a damaged or hostile file can't fill the memory or the disk.
  static const maxJsonBytes = 64 << 20, maxForeignBytes = 256 << 20;

  /// Which Curator wrote a file: for a later one to tell, should a build ever save something wrong.
  static const writer = 'Curator $appVersion ($appBuild)';

  /// Ids a module may have: not a folder the archive keeps for itself.
  static bool _isModuleId(String id) =>
      RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(id) && !const {'score', 'media', 'modules'}.contains(id);

  /// Adds the mimetype, the stub (`project.json` or `settings.json`) older Curators read, the
  /// manifest (with [manifest]'s entries: a project's score and media) and [state] as [modules]
  /// write it, with their files. [state]'s foreign modules go in as they came.
  static void write(ZipEncoder zip, ProjectState state,
      {required String mimeType, required String stub, required List<ProjectModule> modules, Map<String, Object?> manifest = const {}}) {
    final files = <ArchiveFile>[];
    void addFile(String entry, Uint8List bytes, {bool compress = true}) =>
        files.add(ArchiveFile.bytes(entry, bytes)..compression = compress ? CompressionType.deflate : CompressionType.none);
    final bodies = <String, List<int>>{}, listed = <String, Object?>{};
    for (final m in modules) {
      if (state.foreign.containsKey(m.id)) continue; // a newer version's, kept (below)
      bodies[m.id] = utf8.encode(jsonEncode(m.write(state, addFile)));
      listed[m.id] = {'version': m.version, if (m.optional) 'optional': true};
    }
    for (final MapEntry(key: id, value: f) in state.foreign.entries) {
      bodies[id] = f.json;
      listed[id] = {'version': f.version, 'optional': true};
      for (final MapEntry(key: entry, value: bytes) in f.files.entries) {
        addFile(entry, bytes);
      }
    }
    zip.add(ArchiveFile.noCompress('mimetype', mimeType.length, ascii.encode(mimeType)));
    zip.add(ArchiveFile.string(stub, jsonEncode({'format': mimeType, 'version': stubVersion})));
    zip.add(ArchiveFile.string(
        manifestEntry, jsonEncode({'format': mimeType, 'layout': layout, 'writer': writer, ...manifest, 'modules': listed})));
    for (final MapEntry(key: id, value: body) in bodies.entries) {
      zip.add(ArchiveFile.bytes('modules/$id.json', body));
    }
    files.forEach(zip.add);
  }

  /// Whether [archive] is in this layout; if not, it is older ([readLegacy]) or not Curator's.
  static bool isModular(Archive archive) => archive.findFile(manifestEntry) != null;

  /// [archive]'s manifest, checked: of [mimeType]'s kind (else [notOurs]) in a layout this
  /// build reads (else [newer]).
  static JsonReader manifestOf(Archive archive, {required String mimeType, required String notOurs, required String newer}) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(ZipEntries.read(archive.findFile(manifestEntry)!, limit: maxJsonBytes)));
    } on FormatException {
      throw FormatException(notOurs);
    }
    if (json is! Map || json['format'] != mimeType) throw FormatException(notOurs);
    final manifest = JsonReader(json, 'manifest');
    if ((manifest.number('layout') ?? 0) > layout) throw FormatException(newer);
    return manifest;
  }

  /// The state [manifest]'s modules hold, read by [modules]. A module this build can't read
  /// (unknown, or a newer version of one) stops it ([newer]), unless the file says it may go
  /// unread: then it is kept as it came ([ProjectState.foreign]) when [keepForeign].
  static ProjectState read(Archive archive, JsonReader manifest, List<ProjectModule> modules,
      {required String newer, bool keepForeign = true}) {
    final known = {for (final m in modules) m.id: m};
    final jsons = <String, Object?>{};
    final foreign = <String, ForeignModule>{};
    var foreignBytes = 0;
    Uint8List take(ArchiveFile file) {
      final bytes = ZipEntries.read(file, limit: maxForeignBytes - foreignBytes);
      foreignBytes += bytes.length;
      return bytes;
    }

    final listed = manifest.child('modules');
    for (final id in manifest.map('modules').keys) {
      final entry = listed.child(id);
      final version = entry.number('version', required: true)!.toInt();
      final module = known[id];
      final file = archive.findFile('modules/$id.json');
      if (module == null || version > module.version) {
        if (entry.boolean('optional') != true) throw FormatException(newer);
        if (keepForeign && _isModuleId(id) && file != null) {
          foreign[id] = ForeignModule(version: version, json: take(file), files: {
            for (final f in archive.files)
              if (f.isFile && f.name.startsWith('$id/')) f.name: take(f),
          });
        }
        continue;
      }
      if (file == null) throw FormatException('The project is damaged: modules/$id.json is missing.');
      Object? json;
      try {
        json = jsonDecode(utf8.decode(ZipEntries.read(file, limit: maxJsonBytes)));
      } on FormatException {
        throw FormatException('The project is damaged: modules/$id.json is not JSON.');
      }
      for (var v = version.clamp(1, module.version); v < module.version; v++) {
        if ((module.migrations[v], json) case (final migrate?, final Map<String, Object?> j)) json = migrate(j);
      }
      jsons[id] = json;
    }
    return _decode(archive, jsons, modules).copyWith(foreign: foreign);
  }

  /// The state in [json], a file's single `state` of format [savedVersion] ([LegacyProject]),
  /// read by [modules].
  static ProjectState readLegacy(Archive archive, Map<String, Object?> json, int savedVersion, List<ProjectModule> modules) {
    if (savedVersion > LegacyProject.lastVersion) throw StateError('A modular file read as an old one.');
    return _decode(archive, LegacyProject.modules(json, savedVersion), modules);
  }

  static ProjectState _decode(Archive archive, Map<String, Object?> jsons, List<ProjectModule> modules) {
    Uint8List? file(String entry, {required int limit}) => switch (archive.findFile(entry)) {
          final f? when f.isFile => ZipEntries.read(f, limit: limit),
          _ => null,
        };
    var state = const ProjectState();
    for (final m in modules) {
      state = m.read(JsonReader(jsons[m.id], m.id), state, file);
    }
    return state;
  }
}
