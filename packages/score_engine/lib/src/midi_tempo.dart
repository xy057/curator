
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'sync_map.dart';

/// A tempo from a point on: [quarter] (quarter notes from the start of the MIDI file) on,
/// [quartersPerMinute] quarter notes a minute.
typedef MidiTempo = ({double quarter, double quartersPerMinute});

/// A jump in the score as the MIDI file plays on: at [at] (quarter notes from the start of the
/// file) the score goes on from [jumpTo] (score quarters): back for a repeat, on to a coda.
typedef MidiWarp = ({double at, double jumpTo});

/// The tempo map of a Standard MIDI File: its tempo changes, in quarter notes from its start.
///
/// The file's start is the start of the score (bar 1, or its upbeat), and the tempo holds
/// from one change to the next, as a sequencer plays it. Only the tempo is read: notes, time
/// signatures and the rest are left out (the beats come from the score, see `BeatGrid`).
@immutable
class MidiTempoMap {
  /// [tempos] in order, the first at quarter 0 (see [MidiTempoMap.read]).
  MidiTempoMap(this.name, List<MidiTempo> tempos, {List<MidiWarp> warps = const []})
      : tempos = List.unmodifiable(tempos),
        warps = List.unmodifiable([...warps]..sort((a, b) => a.at.compareTo(b.at))) {
    if (tempos.isEmpty || tempos.first.quarter != 0) throw ArgumentError('A tempo map starts at quarter 0.');
  }

  /// The file's name, to show where the tempo comes from.
  final String name;

  /// Every change of tempo, in order; the first is at quarter 0.
  final List<MidiTempo> tempos;

  /// Where the score jumps as the file plays on (repeats played out), in order. The file
  /// counts quarters as played, so its quarter `q` is in the score where the jumps before it
  /// put it (see [anchors]).
  final List<MidiWarp> warps;

  /// What a MIDI file without a tempo plays at (the standard's 500 000 µs a quarter).
  static const defaultQuartersPerMinute = 120.0;

  /// Reads the tempo map of a Standard MIDI File (`.mid`, also wrapped as RIFF `.rmi`).
  /// Throws a [FormatException] saying why when [bytes] isn't one, or keeps time in SMPTE
  /// frames (there is no tempo to read then).
  factory MidiTempoMap.read(Uint8List bytes, {String name = ''}) {
    final (data, division, tracks) = _tracks(bytes);
    final changes = <(int tick, int order, double qpm)>[];
    for (final (at, end) in tracks) {
      for (final (tick, microseconds) in _tempoEvents(data, at, end)) {
        if (microseconds != null) changes.add((tick, changes.length, 60e6 / microseconds));
      }
    }

    // In time order; of several changes at one tick, the last read wins.
    changes.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    final tempos = <MidiTempo>[(quarter: 0, quartersPerMinute: defaultQuartersPerMinute)];
    for (final (tick, _, qpm) in changes) {
      final quarter = tick / division;
      if (quarter == tempos.last.quarter) tempos.removeLast();
      if (tempos.isEmpty || tempos.last.quartersPerMinute != qpm) tempos.add((quarter: quarter, quartersPerMinute: qpm));
    }
    return MidiTempoMap(name, tempos);
  }

  /// How long the Standard MIDI File [bytes] plays, in quarter notes: to its last track's end.
  /// Throws a [FormatException] as [MidiTempoMap.read] does.
  static double lengthOf(Uint8List bytes) {
    final (data, division, tracks) = _tracks(bytes);
    var last = 0;
    for (final (at, end) in tracks) {
      last = math.max(last, _tempoEvents(data, at, end).last.$1);
    }
    return last / division;
  }

  /// The file's data, its ticks a quarter note and the tracks to read (start and end of each
  /// one's events).
  static (ByteData, int, List<(int, int)>) _tracks(Uint8List bytes) {
    var data = ByteData.sublistView(bytes);
    if (_tag(data, 0) == 'RIFF' && _tag(data, 8) == 'RMID') data = _riffData(data);
    if (_tag(data, 0) != 'MThd' || data.lengthInBytes < 14) throw const FormatException('This isn’t a MIDI file.');
    final headerLength = data.getUint32(4);
    final format = data.getUint16(8), division = data.getUint16(12);
    if (division & 0x8000 != 0) throw const FormatException('This MIDI file counts time in SMPTE frames, so it has no tempo map.');
    if (division == 0) throw const FormatException('This MIDI file is damaged: its header gives no ticks per quarter note.');

    final tracks = <(int, int)>[];
    var at = 8 + headerLength, track = 0;
    while (at + 8 <= data.lengthInBytes) {
      final tag = _tag(data, at), length = data.getUint32(at + 4);
      final end = at + 8 + length;
      if (end > data.lengthInBytes) throw const FormatException('This MIDI file is cut short.');
      // A format 2 file holds independent songs: the first one is the one to follow.
      if (tag == 'MTrk' && (format != 2 || track == 0)) tracks.add((at + 8, end));
      if (tag == 'MTrk') track++;
      at = end;
    }
    if (track == 0) throw const FormatException('This MIDI file has no tracks.');
    return (data, division, tracks);
  }

  /// When [quarter] sounds, in seconds from the start of the file.
  double secondsAt(double quarter) {
    final i = _lastAtOrBefore(quarter, (i) => tempos[i].quarter);
    final t = tempos[i];
    return _starts[i] + (quarter - t.quarter) * 60 / t.quartersPerMinute;
  }

  /// Where [seconds] from the start of the file falls, in quarter notes (the inverse of
  /// [secondsAt]).
  double quarterAt(double seconds) {
    final i = _lastAtOrBefore(seconds, (i) => _starts[i]);
    final t = tempos[i];
    return t.quarter + (seconds - _starts[i]) * t.quartersPerMinute / 60;
  }

  /// When each change sounds, in seconds from the start of the file: a map with a change a
  /// beat (a performance's) has thousands, and the Audio tab asks for each on every frame.
  late final List<double> _starts = () {
    final out = List<double>.filled(tempos.length, 0);
    for (var i = 1; i < tempos.length; i++) {
      final t = tempos[i - 1];
      out[i] = out[i - 1] + (tempos[i].quarter - t.quarter) * 60 / t.quartersPerMinute;
    }
    return out;
  }();

  /// The last change whose [key] is at or before [value] (the first before them all).
  int _lastAtOrBefore(double value, double Function(int i) key) {
    var lo = 0, hi = tempos.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (key(mid) <= value) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  // MARK: Editing

  /// Change [index] moved to [quarter] (kept strictly between its neighbours; the first stays
  /// at 0) at [quartersPerMinute]. It stays even when it repeats the tempo before it, as it is
  /// still being dragged.
  MidiTempoMap moved(int index, {required double quarter, required double quartersPerMinute}) {
    if (index < 0 || index >= tempos.length || !(quartersPerMinute > 0)) return this;
    final previous = index > 0 ? tempos[index - 1].quarter : null;
    final next = index + 1 < tempos.length ? tempos[index + 1].quarter : null;
    if (previous == null || quarter <= previous || (next != null && quarter >= next)) quarter = tempos[index].quarter;
    return MidiTempoMap(name, [...tempos]..[index] = (quarter: quarter, quartersPerMinute: quartersPerMinute), warps: warps);
  }

  /// A change at [quarter] keeping the tempo there (a point to drag from), kept although it
  /// repeats the tempo before it. The map as it is when a change is already there, or
  /// [quarter] is before the start.
  MidiTempoMap inserted(double quarter) {
    if (!(quarter > 0) || tempos.any((t) => t.quarter == quarter)) return this;
    final at = tempos.lastWhere((t) => t.quarter < quarter);
    return MidiTempoMap(name, [...tempos, (quarter: quarter, quartersPerMinute: at.quartersPerMinute)]
      ..sort((a, b) => a.quarter.compareTo(b.quarter)), warps: warps);
  }

  /// [changes] (in order) drawn over the changes from the first of them up to [until], as a
  /// sequencer's draw tool does: the last drawn tempo then holds to the next change after it.
  /// Drawn changes repeating the tempo before them are left out, as is a change at [until]
  /// repeating the last drawn; changes elsewhere stay as they are.
  MidiTempoMap drawn(List<MidiTempo> changes, {required double until}) {
    if (changes.isEmpty) return this;
    final from = changes.first.quarter;
    final all = [
      for (final t in tempos)
        if (t.quarter < from || t.quarter >= until) t,
      ...changes,
    ]..sort((a, b) => a.quarter.compareTo(b.quarter));
    return MidiTempoMap(name, [
      for (final (i, t) in all.indexed)
        if (i == 0 || t.quarter < from || t.quarter > until || t.quartersPerMinute != all[i - 1].quartersPerMinute) t,
    ], warps: warps);
  }

  /// Without the changes at [indices] (the first, at quarter 0, always stays).
  MidiTempoMap removed(Set<int> indices) => MidiTempoMap(name, [
        for (final (i, t) in tempos.indexed)
          if (i == 0 || !indices.contains(i)) t,
      ], warps: warps);

  /// The same tempos with [warps] instead.
  MidiTempoMap withWarps(List<MidiWarp> warps) => MidiTempoMap(name, tempos, warps: warps);

  /// The same warps under another tempo map (another file read in place of this one).
  MidiTempoMap withWarpsOf(MidiTempoMap? other) => other == null ? this : withWarps(other.warps);

  /// Each warp's arrival in the score (where it jumps from), up to the first that doesn't fit
  /// a score of [totalQuarters]: each must arrive further on than the one before went on
  /// from, inside the score, and go on from inside it, somewhere else (as [SyncMap] keeps
  /// them). Those from that one on are left out ([anchors]) until edited ([fits]).
  List<double> arrivals(double totalQuarters) {
    final result = <double>[];
    var start = 0.0, at = 0.0;
    for (final w in warps) {
      final arrive = start + w.at - at;
      if (w.at <= at + 1e-6 ||
          arrive > totalQuarters + 1e-9 ||
          w.jumpTo < 0 ||
          w.jumpTo >= totalQuarters ||
          (w.jumpTo - arrive).abs() < 1e-6) {
        break;
      }
      result.add(arrive);
      start = w.jumpTo;
      at = w.at;
    }
    return result;
  }

  /// Whether every warp fits a score of [totalQuarters] (see [arrivals]).
  bool fits(double totalQuarters) => arrivals(totalQuarters).length == warps.length;

  /// The warps of hand-set [anchors], where a file played as they are would jump.
  static List<MidiWarp> warpsOf(List<SyncAnchor> anchors) {
    final result = <MidiWarp>[];
    var start = 0.0, at = 0.0;
    for (final a in anchors) {
      if (!a.isWarp) continue;
      at += a.quarter - start;
      result.add((at: at, jumpTo: a.jumpTo!));
      start = a.jumpTo!;
    }
    return result;
  }

  /// The anchors that make a [SyncMap] follow this tempo map exactly, with the file's start
  /// at [start] seconds: one where the score begins, one at each change of tempo inside it, a
  /// warp at each of [warps], and one at the score's end ([totalQuarters]) as the file last
  /// reaches it. Between anchors a sync map's tempo is constant, as a MIDI file's is between
  /// changes. Warps that don't fit the score (see [arrivals]) are left out, from the first that
  /// doesn't on.
  List<SyncAnchor> anchors({required double start, required double totalQuarters}) {
    final result = [SyncAnchor(0, start)];
    double seconds(double at) => start + secondsAt(at);
    // The pass so far: from score quarter [from], which the file reaches at its quarter [at].
    var from = 0.0, at = 0.0;
    void changes(double until) {
      for (final t in tempos.skip(1)) {
        if (t.quarter > at && t.quarter < until) result.add(SyncAnchor(from + t.quarter - at, seconds(t.quarter)));
      }
    }

    final arrivals = this.arrivals(totalQuarters);
    for (final (i, arrive) in arrivals.indexed) {
      final w = warps[i];
      changes(w.at);
      result.add(SyncAnchor(arrive, seconds(w.at), jumpTo: w.jumpTo));
      from = w.jumpTo;
      at = w.at;
    }
    final end = at + totalQuarters - from;
    changes(end);
    if (end > at) result.add(SyncAnchor(totalQuarters, seconds(end)));
    return result;
  }

  @override
  bool operator ==(Object other) => other is MidiTempoMap && other.name == name && listEquals(other.tempos, tempos) && listEquals(other.warps, warps);
  @override
  int get hashCode => Object.hash(name, Object.hashAll(tempos), Object.hashAll(warps));
  @override
  String toString() => 'MidiTempoMap($name, ${tempos.length} tempos, ${warps.length} warps)';

  // MARK: Reading

  static String _tag(ByteData data, int at) =>
      at + 4 > data.lengthInBytes ? '' : String.fromCharCodes([for (var i = 0; i < 4; i++) data.getUint8(at + i)]);

  /// The MIDI file inside a RIFF `.rmi` (its `data` chunk).
  static ByteData _riffData(ByteData riff) {
    var at = 12;
    while (at + 8 <= riff.lengthInBytes) {
      final length = riff.getUint32(at + 4, Endian.little);
      if (_tag(riff, at) == 'data') {
        final end = at + 8 + length;
        if (end > riff.lengthInBytes) break;
        return ByteData.sublistView(riff, at + 8, end);
      }
      at += 8 + length + (length & 1);
    }
    throw const FormatException('This RIFF file has no MIDI data.');
  }

  /// Every Set Tempo event in the track between [at] and [end]: its tick and microseconds a
  /// quarter note; last, the track's end (its tick, no microseconds).
  static Iterable<(int, int?)> _tempoEvents(ByteData data, int at, int end) sync* {
    int byte() {
      if (at >= end) throw const FormatException('This MIDI file is damaged: a track ends in the middle of an event.');
      return data.getUint8(at++);
    }

    int number() {
      var value = 0;
      for (var i = 0; i < 4; i++) {
        final b = byte();
        value = (value << 7) | (b & 0x7f);
        if (b < 0x80) return value;
      }
      throw const FormatException('This MIDI file is damaged: a length runs over four bytes.');
    }

    var tick = 0;
    int? running;
    while (at < end) {
      tick += number();
      var status = byte();
      if (status < 0x80) {
        // Running status: the byte read is the first data byte of the last message's kind.
        if (running == null) throw const FormatException('This MIDI file is damaged: an event has no status.');
        at--;
        status = running;
      }
      if (status == 0xff) {
        final type = byte(), length = number();
        if (at + length > end) throw const FormatException('This MIDI file is damaged: an event runs past its track.');
        if (type == 0x51 && length == 3) {
          final microseconds = data.getUint8(at) << 16 | data.getUint8(at + 1) << 8 | data.getUint8(at + 2);
          if (microseconds > 0) yield (tick, microseconds);
        }
        at += length;
        if (type == 0x2f) break; // end of track
      } else if (status == 0xf0 || status == 0xf7) {
        at += number(); // system exclusive
      } else if (status >= 0x80 && status < 0xf0) {
        running = status;
        at += (status & 0xf0) == 0xc0 || (status & 0xf0) == 0xd0 ? 1 : 2;
      } else {
        throw FormatException('This MIDI file is damaged: unknown event 0x${status.toRadixString(16)}.');
      }
    }
    yield (tick, null);
  }
}
