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
///     manifest.json      only for Curator 0.7 to 0.11.0-beta1, which read their modules from it: the
///                        kind of file and the layout, past theirs, so they ask for an update
///     project.cura       (settings.cura) the file in CuraScript ([CuraData]): the kind of file,
///                        the layout's version, what wrote it, the kind of file's own fields (a
///                        project's score and recordings), then each module ([ProjectModules]),
///                        its version, whether it may go unread, and its data
///     <id>/…             a module's own files (images/<id>, fonts/<name>.font)
///     …                  the kind of file's own (a project's score/ and media/)
///
/// [load] reads every layout a Curator has written, and [write] writes only the newest
/// (docs/project-format.md has them all, and the rules that keep them readable).
abstract final class ProjectArchive {
  /// The layout's version: changed only when the archive's own shape does (or CuraScript's
  /// notation, which an older build would read as damage), never for a module's
  /// ([ProjectModule.version]). 1: before modules, the stub all there was ([LegacyProject]);
  /// 2: Curator 0.7 to 0.11.0-beta1's, its manifest in manifest.json, each module in JSON,
  /// `modules/<id>.json`; 3: the file in CuraScript.
  static const layout = 3;

  /// What the stub says its format is: one past the last a file of layout 1 has.
  static const stubVersion = LegacyProject.lastVersion + 1;
  static const _manifest = 'manifest.json';

  /// The most a stub, a layout 2 manifest or module's JSON may unpack to; the most a file in
  /// CuraScript may; and modules this build can't read, with their files, together. What a
  /// project unpacks is counted as it comes ([ZipEntries]): a damaged or hostile file can't
  /// fill the memory or the disk.
  static const _maxJsonBytes = 64 << 20, _maxDocumentBytes = 128 << 20, _maxForeignBytes = 256 << 20;

  /// Which Curator wrote a file: for a later one to tell, should a build ever save something wrong.
  static const writer = 'Curator $appReleaseBuild';

  /// The entry a file whose stub is [stub] (`project.json`) is kept in, in CuraScript
  /// (`project.cura`).
  static String documentOf(String stub) => '${_nameOf(stub)}.cura';

  static String _nameOf(String stub) => stub.substring(0, stub.lastIndexOf('.'));

  /// Ids a module may have: not a folder the archive keeps for itself.
  static bool _isModuleId(String id) =>
      RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(id) && !const {'score', 'media', 'modules'}.contains(id);

  /// [entry], one of module [id]'s files: under `<id>/`, where a Curator that keeps the module
  /// unread keeps them with it ([ForeignModule]); anywhere else one would be lost there, or be
  /// taken for another's.
  static String _own(String id, String entry) =>
      entry.length > id.length + 1 && entry.startsWith('$id/') ? entry : throw StateError('The $id module’s file $entry is not under $id/.');

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
  /// file in CuraScript: what it is, [fields] (a project's score and media), and [state] as
  /// [modules] write it, with their files. [state]'s foreign modules go in as they came.
  static void write(ZipEncoder zip, ProjectState state,
      {required String mimeType, required String stub, required List<ProjectModule> modules, Map<String, Object?> fields = const {}}) {
    final files = <ArchiveFile>[];
    void addFile(String entry, Uint8List bytes, {bool compress = true}) =>
        files.add(ArchiveFile.bytes(entry, bytes)..compression = compress ? CompressionType.deflate : CompressionType.none);
    final written = <CuraModule>[];
    for (final m in modules) {
      if (!_isModuleId(m.id)) throw StateError('${m.id} is not a module’s id.');
      if (state.foreign.containsKey(m.id)) continue; // a newer version's, kept (below)
      final data = m.write(state, (entry, bytes, {compress = true}) => addFile(_own(m.id, entry), bytes, compress: compress));
      written.add((id: m.id, version: m.version, optional: m.optional, data: data));
    }
    for (final MapEntry(key: id, value: f) in state.foreign.entries) {
      written.add((id: id, version: f.version, optional: true, data: f.json));
      for (final MapEntry(key: entry, value: bytes) in f.files.entries) {
        addFile(entry, bytes);
      }
    }
    final document = CuraData.write(
      {'format': mimeType, 'layout': layout, 'writer': writer, ...fields},
      modules: written,
      heading: const ['Written by Curator, in CuraScript: what the file is, then each of its modules.'],
    );
    zip.add(ArchiveFile.noCompress('mimetype', mimeType.length, ascii.encode(mimeType)));
    zip.add(ArchiveFile.string(stub, jsonEncode({'format': mimeType, 'version': stubVersion})));
    zip.add(ArchiveFile.string(_manifest, jsonEncode({'format': mimeType, 'layout': layout})));
    zip.add(ArchiveFile.bytes(documentOf(stub), utf8.encode(document)));
    files.forEach(zip.add);
  }

  /// [archive] read, in whichever layout a Curator wrote it: of [mimeType]'s kind (else
  /// [notOurs]) and a layout this build reads (else [newer]). Its [fields] besides its modules
  /// (a project's kind, score and recordings), its [state] as [modules] read it, and its
  /// [layout] (one before this build's: a save writes it anew, which the build that wrote it
  /// can't read).
  ///
  /// Each module's data is brought from the version it was written in to the one here
  /// ([ProjectModule.upgrade]). A module this build can't read (unknown, or a newer version of
  /// one) stops it ([newer]), unless the file says it may go unread: then it is kept as it came
  /// ([ProjectState.foreign]) when [keepForeign]. Throws a [FormatException] saying what is wrong.
  static ({JsonReader fields, ProjectState state, int layout}) load(Archive archive,
      {required String mimeType,
      required String stub,
      required List<ProjectModule> modules,
      required String notOurs,
      required String newer,
      bool keepForeign = true}) {
    final known = {for (final m in modules) m.id: m};
    final _Listing listing;
    if (archive.findFile(_manifest) case final manifest?) {
      final stubbed = _json(manifest, 'manifest', notOurs: notOurs);
      if (stubbed.string('format') != mimeType) throw FormatException(notOurs);
      final layout = stubbed.number('layout')?.toInt() ?? 0;
      if (layout > ProjectArchive.layout) throw FormatException(newer);
      listing = layout < 3 ? _layout2(archive, stubbed) : _layout3(archive, stub, mimeType: mimeType, notOurs: notOurs, newer: newer);
    } else {
      listing = _layout1(archive, stub, known, mimeType: mimeType, notOurs: notOurs, newer: newer);
    }

    final jsons = <String, Object?>{};
    final foreign = <String, ForeignModule>{};
    var foreignBytes = 0;
    Uint8List take(ArchiveFile file) {
      final bytes = ZipEntries.read(file, limit: _maxForeignBytes - foreignBytes);
      foreignBytes += bytes.length;
      return bytes;
    }

    // A layout 2 module's JSON (too big said as such, not as JSON that isn't).
    Object? decoded(String id, ArchiveFile? file) {
      if (file == null) throw FormatException('The project is damaged: modules/$id.json is missing.');
      final bytes = ZipEntries.read(file, limit: _maxJsonBytes);
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
    for (final MapEntry(key: id, value: listed) in listing.modules.entries) {
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
      jsons[id] = module.upgrade(listed.data ?? decoded(id, listed.file), listed.version);
    }

    var state = const ProjectState();
    for (final m in modules) {
      state = m.read(JsonReader(jsons[m.id], m.id), state, (entry, {required limit}) => switch (archive.findFile(_own(m.id, entry))) {
            final f? when f.isFile => ZipEntries.read(f, limit: limit),
            _ => null,
          });
    }
    return (fields: listing.fields, state: state.copyWith(foreign: foreign), layout: listing.layout);
  }

  /// Layout 1, before modules ([LegacyProject]: Curator 0.6.1 and before): the stub held all of
  /// it, its edits in one `state`, dealt out here to the modules that hold them now ([known]'s),
  /// each in its first version.
  static _Listing _layout1(Archive archive, String stub, Map<String, ProjectModule> known,
      {required String mimeType, required String notOurs, required String newer}) {
    final fields = _json(archive.findFile(stub) ?? (throw FormatException(notOurs)), _nameOf(stub), notOurs: notOurs);
    if (fields.string('format') != mimeType) throw FormatException(notOurs);
    // One past the last format with no manifest beside it is a later layout's, its manifest lost.
    final version = fields.number('version')?.toInt() ?? 0;
    if (version > LegacyProject.lastVersion) throw FormatException(newer);
    return (
      fields: fields,
      layout: 1,
      modules: {
        for (final MapEntry(key: id, value: data) in LegacyProject.modules(fields.map('state'), version).entries)
          if (known.containsKey(id)) id: (version: LegacyProject.moduleVersion, optional: false, data: data, file: null),
      },
    );
  }

  /// Layout 2 (Curator 0.7 to 0.11.0-beta1): [manifest] has the fields and lists the modules,
  /// each one's version and whether it may go unread; each one's data is `modules/<id>.json`,
  /// read when it is wanted.
  static _Listing _layout2(Archive archive, JsonReader manifest) {
    final listed = manifest.child('modules');
    return (
      fields: manifest,
      layout: 2,
      modules: {
        for (final id in manifest.map('modules').keys)
          id: (
            version: listed.child(id).number('version', required: true)!.toInt(),
            optional: listed.child(id).boolean('optional') == true,
            data: null,
            file: archive.findFile('modules/$id.json'),
          ),
      },
    );
  }

  /// Layout 3: the file in CuraScript ([documentOf] [stub]) has the fields, then the modules.
  static _Listing _layout3(Archive archive, String stub, {required String mimeType, required String notOurs, required String newer}) {
    final name = documentOf(stub);
    final file = archive.findFile(name) ?? (throw FormatException('The project is damaged: $name is missing.'));
    // (Too big is said as ZipEntries says it, in the interface's language; not as damage.)
    final bytes = ZipEntries.read(file, limit: _maxDocumentBytes);
    final CuraDocument document;
    try {
      document = CuraData.read(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw FormatException('The project is damaged: $name, ${e.message}');
    }
    final fields = JsonReader(document.fields, _nameOf(stub));
    if (fields.string('format') != mimeType) throw FormatException(notOurs);
    if ((fields.number('layout') ?? 0) > layout) throw FormatException(newer);
    return (
      fields: fields,
      layout: 3,
      modules: {
        for (final m in document.modules) m.id: (version: m.version, optional: m.optional, data: m.data, file: null),
      },
    );
  }

  /// [file]'s JSON object, [where] its name in a message; [notOurs] for anything else.
  static JsonReader _json(ArchiveFile file, String where, {required String notOurs}) {
    final bytes = ZipEntries.read(file, limit: _maxJsonBytes);
    try {
      if (jsonDecode(utf8.decode(bytes)) case final Map<String, Object?> json) return JsonReader(json, where);
    } on FormatException {
      // (Below.)
    }
    throw FormatException(notOurs);
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
}

/// What a file says it is and holds besides its modules, the layout it is in, and its modules by
/// id in the file's order: each one's version, whether it may go unread, and its data (read
/// already) or, in layout 2, its JSON's entry (read when it is wanted).
typedef _Listing = ({
  JsonReader fields,
  int layout,
  Map<String, ({int version, bool optional, Map<String, Object?>? data, ArchiveFile? file})> modules,
});
