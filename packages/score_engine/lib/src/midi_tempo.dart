
import 'package:flutter/foundation.dart';

import 'sync_map.dart';

/// A tempo from a point on: [quarter] (quarter notes from the start of the MIDI file) on,
/// [quartersPerMinute] quarter notes a minute.
typedef MidiTempo = ({double quarter, double quartersPerMinute});

/// The tempo map of a Standard MIDI File: its tempo changes, in quarter notes from its start.
///
/// The file's start is the start of the score (bar 1, or its upbeat), and the tempo holds
/// from one change to the next, as a sequencer plays it. Only the tempo is read: notes, time
/// signatures and the rest are left out (the beats come from the score, see `BeatGrid`).
@immutable
class MidiTempoMap {
  /// [tempos] in order, the first at quarter 0 (see [MidiTempoMap.read]).
  MidiTempoMap(this.name, List<MidiTempo> tempos) : tempos = List.unmodifiable(tempos) {
    if (tempos.isEmpty || tempos.first.quarter != 0) throw ArgumentError('A tempo map starts at quarter 0.');
  }

  /// The file's name, to show where the tempo comes from.
  final String name;

  /// Every change of tempo, in order; the first is at quarter 0.
  final List<MidiTempo> tempos;

  /// What a MIDI file without a tempo plays at (the standard's 500 000 µs a quarter).
  static const defaultQuartersPerMinute = 120.0;

  /// Reads the tempo map of a Standard MIDI File (`.mid`, also wrapped as RIFF `.rmi`).
  /// Throws a [FormatException] saying why when [bytes] isn't one, or keeps time in SMPTE
  /// frames (there is no tempo to read then).
  factory MidiTempoMap.read(Uint8List bytes, {String name = ''}) {
    var data = ByteData.sublistView(bytes);
    if (_tag(data, 0) == 'RIFF' && _tag(data, 8) == 'RMID') data = _riffData(data);
    if (_tag(data, 0) != 'MThd' || data.lengthInBytes < 14) throw const FormatException('This is not a MIDI file.');
    final headerLength = data.getUint32(4);
    final format = data.getUint16(8), division = data.getUint16(12);
    if (division & 0x8000 != 0) throw const FormatException('This MIDI file counts time in SMPTE frames, so it has no tempo map.');
    if (division == 0) throw const FormatException('This MIDI file is damaged: its header gives no ticks per quarter note.');

    final changes = <(int tick, int order, double qpm)>[];
    var at = 8 + headerLength, track = 0;
    while (at + 8 <= data.lengthInBytes) {
      final tag = _tag(data, at), length = data.getUint32(at + 4);
      final end = at + 8 + length;
      if (end > data.lengthInBytes) throw const FormatException('This MIDI file is cut short.');
      // A format 2 file holds independent songs: the first one is the one to follow.
      if (tag == 'MTrk' && (format != 2 || track == 0)) {
        for (final (tick, microseconds) in _tempoEvents(data, at + 8, end)) {
          changes.add((tick, changes.length, 60e6 / microseconds));
        }
      }
      if (tag == 'MTrk') track++;
      at = end;
    }
    if (track == 0) throw const FormatException('This MIDI file has no tracks.');

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

  /// When [quarter] sounds, in seconds from the start of the file.
  double secondsAt(double quarter) {
    var seconds = 0.0;
    for (var i = 0; i < tempos.length; i++) {
      final t = tempos[i];
      final end = i + 1 < tempos.length ? tempos[i + 1].quarter : double.infinity;
      if (quarter <= end) return seconds + (quarter - t.quarter) * 60 / t.quartersPerMinute;
      seconds += (end - t.quarter) * 60 / t.quartersPerMinute;
    }
    return seconds; // not reached: the last tempo runs on for ever
  }

  /// The anchors that make a [SyncMap] follow this tempo map exactly, with the file's start
  /// at [start] seconds: one where the score begins, one at each change of tempo inside it,
  /// and one at its end ([totalQuarters]). Between anchors a sync map's tempo is constant,
  /// as a MIDI file's is between changes.
  List<SyncAnchor> anchors({required double start, required double totalQuarters}) => [
        SyncAnchor(0, start),
        for (final t in tempos.skip(1))
          if (t.quarter < totalQuarters) SyncAnchor(t.quarter, start + secondsAt(t.quarter)),
        if (totalQuarters > 0) SyncAnchor(totalQuarters, start + secondsAt(totalQuarters)),
      ];

  @override
  bool operator ==(Object other) => other is MidiTempoMap && other.name == name && listEquals(other.tempos, tempos);
  @override
  int get hashCode => Object.hash(name, Object.hashAll(tempos));
  @override
  String toString() => 'MidiTempoMap($name, ${tempos.length} tempos)';

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
    throw const FormatException('This RIFF file holds no MIDI.');
  }

  /// Every Set Tempo event in the track between [at] and [end]: its tick and microseconds a
  /// quarter note.
  static Iterable<(int, int)> _tempoEvents(ByteData data, int at, int end) sync* {
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
        if (type == 0x2f) return; // end of track
      } else if (status == 0xf0 || status == 0xf7) {
        at += number(); // system exclusive
      } else if (status >= 0x80 && status < 0xf0) {
        running = status;
        at += (status & 0xf0) == 0xc0 || (status & 0xf0) == 0xd0 ? 1 : 2;
      } else {
        throw FormatException('This MIDI file is damaged: unknown event 0x${status.toRadixString(16)}.');
      }
    }
  }
}
