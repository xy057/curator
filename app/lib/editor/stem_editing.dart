part of '../editor_controller.dart';

/// The project's stems ([EditState.stems]): what single tracks of a DAW play, each kept apart
/// in a file of its own (FLAC) in time with a take, for hearing one instrument alone or
/// bringing it forward. Captured from the DAW followed through Attacca ([capture]): each
/// track as the song plays it, over the followed recording's length, so its first sample is
/// the recording's first. Adding and removing stems, and naming their parts, are no Undo steps,
/// as with recordings.
class StemEditing {
  StemEditing._(this._editor);

  final EditorController _editor;

  /// Each stem's file, by id: unpacked with the project, or captured into a scratch folder
  /// ([_scratch]) that goes with it.
  final _files = <String, String>{};
  final _scratch = <String, Directory>{};

  /// The stems, in the order captured.
  List<Stem> get list => _editor._doc.stems;

  /// The file of stem [id]; null when it has none (a project's file was missing it).
  String? fileOf(String id) => _files[id];

  /// The project opened has its stems' files at [paths] (by id).
  void _opened(Map<String, String> paths) => _files.addAll(paths);

  /// Lets go of every file (the project closes).
  void _reset() {
    _files.clear();
    for (final folder in _scratch.values) {
      ScratchSpace.release(folder);
    }
    _scratch.clear();
  }

  /// Captures [tracks] of the DAW document followed ([DawEditing.document]) as stems in [link],
  /// one after another; a track captured before (by name, in time with the same take) is
  /// replaced, keeping its part. [progress] hears how far all of it has got, 0–1. Returns what
  /// went wrong with each track that couldn't be captured, by its name: the plug-in's word
  /// ([DawLinkException.reason]), or a conversion's error.
  Future<Map<String, Object>> capture(DawLink link, List<DawTrack> tracks, {void Function(double done)? progress}) async {
    final follow = _editor.daw.following, found = _editor.daw.document;
    final region = found == null || follow == null ? null : _editor.daw._regionIn(found.$2);
    if (found == null || region == null) return {for (final t in tracks) t.name: const DawLinkException('gone')};
    final (session, document) = found;
    // The recording followed: where it starts in the song, and as long as it is here (else there).
    // (In time with the project's Attacca take, which has the recording followed; else the focus.)
    final take = _editor._doc.attaccaTake?.id ?? _editor._doc.focus;
    final length = (take == null ? null : _editor.audio.trackOf(take)?.length) ?? document.source(follow!.source)?.seconds ?? region.span;
    final from = region.songAt(0);
    final failed = <String, Object>{};
    for (final (i, track) in tracks.indexed) {
      final name = track.name.isEmpty ? 'Track'.tr : track.name;
      try {
        final wav = await link.stem(session, document.id, track.id,
            from: from, length: length, progress: (d) => progress?.call((i + d) / tracks.length));
        final folder = ScratchSpace.folder('stem');
        final String flac;
        try {
          flac = await MediaConverter.toFlac(wav, folder.path);
        } catch (_) {
          ScratchSpace.release(folder);
          rethrow;
        } finally {
          // The plug-in's file is Curator's cache's: kept as FLAC, it is no longer needed.
          try {
            File(wav).deleteSync();
          } catch (_) {}
        }
        if (_editor._disposed) {
          ScratchSpace.release(folder);
          break;
        }
        _put(Stem(_newId(), name, color: track.color, take: take, part: _partFor(name)), flac, folder);
      } catch (e) {
        failed[name] = e;
      }
      progress?.call((i + 1) / tracks.length);
    }
    return failed;
  }

  /// [stem] kept, its file at [path] in [folder]: in place of one by the same name with the
  /// same take (which keeps its id and part), else after the others.
  void _put(Stem stem, String path, Directory folder) {
    final before = list.where((s) => s.name == stem.name && s.take == stem.take).firstOrNull;
    final kept = before == null ? stem : Stem(before.id, stem.name, color: stem.color, take: stem.take, offset: stem.offset, part: before.part);
    _letGo(kept.id);
    _files[kept.id] = path;
    _scratch[kept.id] = folder;
    _editor._everywhere((s) => s.copyWith(stems: before == null ? [...s.stems, kept] : [for (final x in s.stems) x.id == kept.id ? kept : x]));
    _editor._edited();
    _editor._changed();
  }

  /// Adds the audio file at [path] as a stem named [name] in time with the focus's recording
  /// (from its start), playing [part]; for a stem from elsewhere than a DAW, and for tests.
  @visibleForTesting
  void debugAdd(String name, String path, {int? color, String? part}) {
    final folder = ScratchSpace.folder('stem');
    _put(Stem(_newId(), name, color: color, take: _editor._doc.focus, part: part), path, folder);
  }

  /// Takes stem [id] out of the project, with its file.
  void remove(String id) {
    if (!list.any((s) => s.id == id)) return;
    _letGo(id);
    _editor._everywhere((s) => s.copyWith(stems: [for (final x in s.stems) if (x.id != id) x]));
    _editor._edited();
    _editor._changed();
  }

  /// Stem [id] plays [part] of the score (null: not known).
  void setPart(String id, String? part) {
    if (!list.any((s) => s.id == id && s.part != part)) return;
    _editor._everywhere((s) => s.copyWith(stems: [for (final x in s.stems) x.id == id ? x.copyWith(part: part) : x]));
    _editor._edited();
    _editor._changed();
  }

  void _letGo(String id) {
    _files.remove(id);
    if (_scratch.remove(id) case final folder?) ScratchSpace.release(folder);
  }

  String _newId() {
    var n = 1;
    while (list.any((s) => s.id == 'stem-$n')) {
      n++;
    }
    return 'stem-$n';
  }

  /// The part of the score a track named [name] plays, by its name ("Violin I" for "Violins 1"),
  /// when exactly one part's name matches; else null.
  String? _partFor(String name) {
    final score = _editor._score;
    if (score == null) return null;
    String plain(String text) => text
        .toLowerCase()
        .replaceAllMapped(RegExp(r'\b(i{1,3}|iv)\b'), (m) => '${const {'i': 1, 'ii': 2, 'iii': 3, 'iv': 4}[m[1]]}')
        .replaceAll(RegExp(r'[^a-z0-9À-￿]+'), '')
        .replaceAll(RegExp(r's(?=\d|$)'), '');
    final wanted = plain(name);
    if (wanted.isEmpty) return null;
    final matches = [
      for (final p in score.metadata.parts)
        if (plain(_editor.partNameOf(p.id)) case final n when n.isNotEmpty && (n == wanted || n.startsWith(wanted) || wanted.startsWith(n))) p.id,
    ];
    final exact = [for (final id in matches) if (plain(_editor.partNameOf(id)) == wanted) id];
    if (exact.length == 1) return exact.single;
    return matches.length == 1 ? matches.single : null;
  }
}
