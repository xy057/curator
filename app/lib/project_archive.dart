import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:score_engine/score_engine.dart' show CuraData, CuraDocument, CuraModule, ZipEntries;

import 'legacy_project.dart';
import 'project_modules.dart';
import 'project_state.dart';
import 'updater.dart' show appReleaseBuild;

/// The layout projects (.ccs, [ProjectFile]) and settings files (.ccf, [SettingsFile]) share: a
/// zip archive holding
///
///     mimetype           the kind of file (stored first, uncompressed)
///     project.json       (settings.json for settings) only for Curator 0.6.1 and before, which
///                        read nothing else: format 27, past theirs, so they ask for an update
///     manifest.json      only for Curator 0.7 to 0.11, which read their modules from it: the
///                        kind of file and the layout, past theirs, so they ask for an update
///     project.cura       (settings.cura) the file in CuraScript ([CuraData]): the kind of file,
///                        the layout's version, what wrote it, the kind of file's own fields (a
///                        project's score and recordings), then each module ([ProjectModules]),
///                        its version, whether it may go unread, and its data
///     <id>/…             a module's own files (images/<id>, fonts/<name>.font)
///     …                  the kind of file's own (a project's score/ and media/)
///
/// A file of layout 2 (Curator 0.7 to 0.11) has its manifest in manifest.json and each module
/// as compact JSON, `modules/<id>.json`: it is read as it is, and saved again in CuraScript. One
/// older than that ([LegacyProject]) has no manifest: its stub was all there was.
abstract final class ProjectArchive {
  /// The layout's version: changed only when the archive's own shape does, never for a
  /// module's ([ProjectModule.version]). 3: the file in CuraScript.
  static const layout = 3;

  /// What [stub] says its format is.
  static const stubVersion = LegacyProject.lastVersion + 1;
  static const manifestEntry = 'manifest.json';

  /// The most a layout 2 file's manifest, or one of its modules' JSON, may unpack to; the most
  /// a file in CuraScript may; and modules this build can't read, with their files, together.
  /// What a project unpacks is counted as it comes ([ZipEntries]): a damaged or hostile file
  /// can't fill the memory or the disk.
  static const maxJsonBytes = 64 << 20, maxDocumentBytes = 128 << 20, maxForeignBytes = 256 << 20;

  /// Which Curator wrote a file: for a later one to tell, should a build ever save something wrong.
  static const writer = 'Curator $appReleaseBuild';

  /// The entry a file whose stub is [stub] (`project.json`) is kept in, in CuraScript
  /// (`project.cura`).
  static String documentOf(String stub) => '${_nameOf(stub)}.cura';

  static String _nameOf(String stub) => stub.substring(0, stub.lastIndexOf('.'));

  /// Ids a module may have: not a folder the archive keeps for itself.
  static bool _isModuleId(String id) =>
      RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(id) && !const {'score', 'media', 'modules'}.contains(id);

  /// Writes a zip at [path] by [body], without ever leaving half a file there: into
  /// `<path>.saving`, then moved in. [body] adds the entries, and the files it opens to read
  /// go in the list it is given, to be closed once the zip is written. When anything fails,
  /// each of those is let go on its own and the half-written file removed, and the failure
  /// thrown on.
  static void writeFile(String path, void Function(ZipEncoder zip, List<InputFileStream> opened) body) {
    final temp = '$path.saving';
    final out = OutputFileStream(temp);
    // zlib's default level: ZipEncoder's own (1) is no faster here and makes a score 60 % bigger;
    // the best (9) takes twice as long for a few percent.
    final zip = ZipEncoder()..startEncode(out, level: DeflateLevel.defaultCompression);
    final opened = <InputFileStream>[];
    try {
      body(zip, opened);
      zip.endEncode();
      out.closeSync();
      for (final s in opened) {
        s.closeSync();
      }
      File(temp).renameSync(path);
    } catch (_) {
      // Each let go on its own: closing a file that couldn't be written fails again (the bytes it
      // couldn't write are still waiting), and the rest must go all the same.
      _letGo(out.closeSync);
      for (final s in opened) {
        _letGo(s.closeSync);
      }
      _letGo(() {
        final f = File(temp);
        if (f.existsSync()) f.deleteSync();
      });
      rethrow;
    }
  }

  /// Does [step] of a clean-up after a failure, which may fail too: the failure first met is the
  /// one to tell.
  static void _letGo(void Function() step) {
    try {
      step();
    } catch (_) {
      // (Gone as far as it could.)
    }
  }

  /// Adds the mimetype, the stubs (`project.json`, `manifest.json`) older Curators read, and the
  /// file in CuraScript: what it is, [manifest]'s fields (a project's score and media), and
  /// [state] as [modules] write it, with their files. [state]'s foreign modules go in as they
  /// came.
  static void write(ZipEncoder zip, ProjectState state,
      {required String mimeType, required String stub, required List<ProjectModule> modules, Map<String, Object?> manifest = const {}}) {
    final files = <ArchiveFile>[];
    void addFile(String entry, Uint8List bytes, {bool compress = true}) =>
        files.add(ArchiveFile.bytes(entry, bytes)..compression = compress ? CompressionType.deflate : CompressionType.none);
    final written = <CuraModule>[];
    for (final m in modules) {
      if (state.foreign.containsKey(m.id)) continue; // a newer version's, kept (below)
      written.add((id: m.id, version: m.version, optional: m.optional, data: m.write(state, addFile)));
    }
    for (final MapEntry(key: id, value: f) in state.foreign.entries) {
      written.add((id: id, version: f.version, optional: true, data: f.json));
      for (final MapEntry(key: entry, value: bytes) in f.files.entries) {
        addFile(entry, bytes);
      }
    }
    final document = CuraData.write(
      {'format': mimeType, 'layout': layout, 'writer': writer, ...manifest},
      modules: written,
      heading: const ['Written by Curator, in CuraScript: what the file is, then each of its modules.'],
    );
    zip.add(ArchiveFile.noCompress('mimetype', mimeType.length, ascii.encode(mimeType)));
    zip.add(ArchiveFile.string(stub, jsonEncode({'format': mimeType, 'version': stubVersion})));
    zip.add(ArchiveFile.string(manifestEntry, jsonEncode({'format': mimeType, 'layout': layout})));
    zip.add(ArchiveFile.bytes(documentOf(stub), utf8.encode(document)));
    files.forEach(zip.add);
  }

  /// Whether [archive] is in this layout, or layout 2; if not, it is older ([readLegacy]) or not
  /// Curator's.
  static bool isModular(Archive archive) => archive.findFile(manifestEntry) != null;

  /// [archive] opened: of [mimeType]'s kind (else [notOurs]), in a layout this build reads (else
  /// [newer]), its fields and its modules listed, from its file in CuraScript ([documentOf]
  /// [stub]) or, for layout 2, its manifest.json.
  static OpenedArchive open(Archive archive,
      {required String mimeType, required String stub, required String notOurs, required String newer}) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(ZipEntries.read(archive.findFile(manifestEntry)!, limit: maxJsonBytes)));
    } on FormatException {
      throw FormatException(notOurs);
    }
    if (json is! Map || json['format'] != mimeType) throw FormatException(notOurs);
    final stubbed = JsonReader(json, 'manifest');
    final layout = stubbed.number('layout')?.toInt() ?? 0;
    if (layout > ProjectArchive.layout) throw FormatException(newer);
    if (layout < 3) {
      final listed = stubbed.child('modules');
      return OpenedArchive._(archive, stubbed, layout, {
        for (final id in stubbed.map('modules').keys)
          id: (
            version: listed.child(id).number('version', required: true)!.toInt(),
            optional: listed.child(id).boolean('optional') == true,
            data: null,
            file: archive.findFile('modules/$id.json'),
          ),
      });
    }

    final name = documentOf(stub);
    final file = archive.findFile(name) ?? (throw FormatException('The project is damaged: $name is missing.'));
    // (Too big is said as ZipEntries says it, in the interface's language; not as damage.)
    final bytes = ZipEntries.read(file, limit: maxDocumentBytes);
    final CuraDocument document;
    try {
      document = CuraData.read(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw FormatException('The project is damaged: $name, ${e.message}');
    }
    final fields = JsonReader(document.fields, _nameOf(stub));
    if (fields.string('format') != mimeType) throw FormatException(notOurs);
    if ((fields.number('layout') ?? 0) > ProjectArchive.layout) throw FormatException(newer);
    return OpenedArchive._(archive, fields, layout, {
      for (final m in document.modules) m.id: (version: m.version, optional: m.optional, data: m.data, file: null),
    });
  }

  /// The state [opened]'s modules hold, read by [modules]. A module this build can't read
  /// (unknown, or a newer version of one) stops it ([newer]), unless the file says it may go
  /// unread: then it is kept as it came ([ProjectState.foreign]) when [keepForeign].
  static ProjectState read(OpenedArchive opened, List<ProjectModule> modules, {required String newer, bool keepForeign = true}) {
    final archive = opened.archive;
    final known = {for (final m in modules) m.id: m};
    final jsons = <String, Object?>{};
    final foreign = <String, ForeignModule>{};
    var foreignBytes = 0;
    Uint8List take(ArchiveFile file) {
      final bytes = ZipEntries.read(file, limit: maxForeignBytes - foreignBytes);
      foreignBytes += bytes.length;
      return bytes;
    }

    // A layout 2 module's JSON (too big said as such, not as JSON that isn't).
    Object? decoded(String id, ArchiveFile? file) {
      if (file == null) throw FormatException('The project is damaged: modules/$id.json is missing.');
      final bytes = ZipEntries.read(file, limit: maxJsonBytes);
      try {
        return jsonDecode(utf8.decode(bytes));
      } on FormatException {
        throw FormatException('The project is damaged: modules/$id.json is not JSON.');
      }
    }

    // A layout 2 module of a newer build's, as it came; null where it isn't what CuraScript
    // can write again as a module's (fields, of JSON's values no deeper than it reads), which
    // nothing here needs: kept, it would be a project saved that can't be opened again.
    Object? kept(ArchiveFile file) {
      final bytes = take(file);
      try {
        return switch (jsonDecode(utf8.decode(bytes))) {
          final Map<String, Object?> data when CuraData.holds(data) => data,
          _ => null,
        };
      } on FormatException {
        return null;
      }
    }

    // Each module's own files, by its id: their folder (`images/…`), found in one pass.
    Map<String, List<ArchiveFile>>? filesOf;
    for (final MapEntry(key: id, value: listed) in opened._modules.entries) {
      final module = known[id];
      if (module == null || listed.version > module.version) {
        if (!listed.optional) throw FormatException(newer);
        if (keepForeign && _isModuleId(id) && CuraData.isVersion(listed.version) && (listed.data != null || listed.file != null)) {
          if (listed.data ?? kept(listed.file!) case final Map<String, Object?> data) {
            filesOf ??= _byFolder(archive);
            foreign[id] = ForeignModule(version: listed.version, json: data, files: {
              for (final f in filesOf[id] ?? const <ArchiveFile>[]) f.name: take(f),
            });
          }
        }
        continue;
      }
      var json = listed.data ?? decoded(id, listed.file);
      for (var v = listed.version.clamp(1, module.version); v < module.version; v++) {
        if ((module.migrations[v], json) case (final migrate?, final Map<String, Object?> j)) json = migrate(j);
      }
      jsons[id] = json;
    }
    return _decode(archive, jsons, modules).copyWith(foreign: foreign);
  }

  /// [archive]'s files by the folder they are in (`images/a.png` in `images`); none at the top.
  static Map<String, List<ArchiveFile>> _byFolder(Archive archive) {
    final out = <String, List<ArchiveFile>>{};
    for (final f in archive.files) {
      final slash = f.name.indexOf('/');
      if (f.isFile && slash > 0) (out[f.name.substring(0, slash)] ??= []).add(f);
    }
    return out;
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

/// A file in [ProjectArchive]'s layout, opened ([ProjectArchive.open]): what it says it is and
/// holds besides its modules, and its modules listed.
final class OpenedArchive {
  OpenedArchive._(this.archive, this.manifest, this.layout, this._modules);

  final Archive archive;

  /// Its fields besides its modules: its kind, a project's score and recordings, named with
  /// their entries.
  final JsonReader manifest;

  /// The layout it was written in: [ProjectArchive.layout], or 2 (Curator 0.7 to 0.11's, its
  /// modules in JSON), which a save writes anew.
  final int layout;

  /// Its modules by id, in the file's order: each one's version, whether it may go unread, and
  /// its data (in CuraScript, read) or its JSON's entry (layout 2, read when wanted).
  final Map<String, ({int version, bool optional, Map<String, Object?>? data, ArchiveFile? file})> _modules;

  /// Whether a save writes it in a layout a Curator that opened it before can't read.
  bool get isOlder => layout < ProjectArchive.layout;
}
