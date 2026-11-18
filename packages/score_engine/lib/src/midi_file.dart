import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// One event of a MIDI track, at [tick] from the track's start: a channel message ([status]
/// 0x80–0xEF, its data bytes [a] and [b], the second 0 when it has one) or a meta event
/// ([status] 0xFF, [a] its type, its data the [length] bytes from [b] in the file).
typedef MidiEvent = ({int tick, int status, int a, int b, int length});

/// A note of a MIDI file: [key] (60 is middle C) from [start] to [end], in ticks from the
/// file's start, struck at [velocity] (1–127).
typedef MidiNote = ({int start, int end, int key, int velocity});

/// One channel of a track of a MIDI file: what one instrument plays.
class MidiVoice {
  MidiVoice({required this.track, required this.channel, required this.name, required this.program, required this.notes});

  /// The track it is in (0 the file's first) and its channel (0–15; 9 is General MIDI's drums).
  final int track, channel;

  /// The track's name as the file gives it (its Track Name, else its Instrument Name); empty:
  /// it gives none.
  final String name;

  /// The General MIDI program the channel is first set to in the track (0–127); null: none is.
  final int? program;

  /// Its notes, in the order they start, the higher first of those starting together.
  final List<MidiNote> notes;

  /// Whether it is General MIDI's percussion: each key a drum, not a pitch.
  bool get isDrums => channel == 9;
}

/// A Standard MIDI File (`.mid`, also wrapped as RIFF `.rmi`) read whole: what each track
/// plays, and its meters, keys and name. (Its tempo map alone is a `MidiTempoMap`.)
class MidiFile {
  MidiFile._(this.division, this.voices, this.meters, this.keys, this.title, this.length);

  /// Ticks a quarter note.
  final int division;

  /// Each channel of each track that plays a note, in the file's order.
  final List<MidiVoice> voices;

  /// The time signatures, in order: from [tick] on, [count] notes of 1/[unit] a bar.
  final List<({int tick, int count, int unit})> meters;

  /// The key signatures, in order: from [tick] on, [fifths] sharps (flats when negative).
  final List<({int tick, int fifths})> keys;

  /// The name of the first track when it plays nothing (a sequence's name); else empty.
  final String title;

  /// Where its last note ends, in ticks.
  final int length;

  /// The most notes a file may hold: many times a long orchestral piece's, and a limit on
  /// what a damaged or hostile file can take.
  static const maxNotes = 2000000;

  /// Reads [bytes]. Throws a [FormatException] saying why when it isn't a MIDI file, is
  /// damaged, or counts time in SMPTE frames.
  factory MidiFile.read(Uint8List bytes) {
    final (data, division, tracks) = chunks(bytes);
    final voices = <MidiVoice>[];
    final meters = <({int tick, int count, int unit})>[];
    final keys = <({int tick, int fifths})>[];
    var title = '', count = 0, length = 0;
    for (final (t, (at, end)) in tracks.indexed) {
      String? name, instrument;
      final programs = <int, int>{};
      final notes = <int, List<MidiNote>>{}; // by channel
      final sounding = <int, List<(int tick, int velocity)>>{}; // channel << 7 | key → those held
      var last = 0;
      // The keys struck more often than let go: struck again while held with no note-off
      // between (a keyboard's, a sequencer's), or never let go. Paired first come first let
      // go, as the others are, each would leave a note held to the track's end; so a note-off
      // of theirs lets go of every one held.
      final unpaired = <int>{};
      {
        final held = <int, int>{};
        for (final e in events(data, at, end)) {
          if (e.status == 0xff) continue;
          final id = (e.status & 0x0f) << 7 | (e.a & 0x7f), n = held[id] ?? 0;
          switch (e.status & 0xf0) {
            case 0x90 when e.b & 0x7f > 0:
              held[id] = n + 1;
            case 0x80 || 0x90 when n > 0:
              held[id] = n - 1;
          }
        }
        unpaired.addAll(held.keys.where((id) => held[id]! > 0));
      }
      void release(int id, int tick) {
        final held = sounding[id];
        if (held == null || held.isEmpty) return;
        do {
          final (start, velocity) = held.removeAt(0);
          // One let go as it is struck (some drum tracks') is still a note: a sixteenth.
          final int stop = tick > start ? tick : start + math.max(1, division ~/ 4);
          (notes[id >> 7] ??= []).add((start: start, end: stop, key: id & 0x7f, velocity: velocity));
          if (++count > maxNotes) throw const FormatException('This MIDI file has too many notes.');
          // (One struck at this very tick stays held when another is let go by it.)
        } while (unpaired.contains(id) && held.isNotEmpty && held.first.$1 < tick);
      }

      for (final e in events(data, at, end)) {
        last = e.tick;
        if (e.status == 0xff) {
          String text() => utf8.decode(Uint8List.sublistView(data, e.b, e.b + e.length), allowMalformed: true).replaceAll('\x00', '').trim();
          switch (e.a) {
            case 0x03:
              name ??= text();
            case 0x04:
              instrument ??= text();
            case 0x58 when e.length >= 2:
              final unit = 1 << math.min(7, data.getUint8(e.b + 1)), beats = data.getUint8(e.b);
              if (beats > 0) meters.add((tick: e.tick, count: beats, unit: unit));
            case 0x59 when e.length >= 1:
              keys.add((tick: e.tick, fifths: math.max(-7, math.min(7, data.getInt8(e.b)))));
          }
          continue;
        }
        final channel = e.status & 0x0f, id = channel << 7 | (e.a & 0x7f);
        switch (e.status & 0xf0) {
          case 0x90 when e.b & 0x7f > 0:
            (sounding[id] ??= []).add((e.tick, e.b & 0x7f));
          case 0x80 || 0x90:
            release(id, e.tick);
          case 0xc0:
            programs.putIfAbsent(channel, () => e.a & 0x7f);
        }
      }
      // A note never let go ends with its track.
      for (final id in sounding.keys.toList()) {
        while (sounding[id]!.isNotEmpty) {
          release(id, last);
        }
      }
      if (t == 0 && notes.isEmpty) title = name ?? '';
      for (final channel in notes.keys.toList()..sort()) {
        final own = notes[channel]!..sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : b.key.compareTo(a.key));
        length = math.max(length, own.fold(0, (m, n) => math.max(m, n.end)));
        voices.add(MidiVoice(
            track: t,
            channel: channel,
            name: (name?.isNotEmpty ?? false) ? name! : instrument ?? '',
            program: programs[channel],
            notes: own));
      }
    }
    // In time order (a format 1 file may keep them in any track), those at one tick as read.
    List<T> inTime<T>(List<T> items, int Function(T) tickOf) {
      final order = [for (var i = 0; i < items.length; i++) i]
        ..sort((a, b) => tickOf(items[a]) != tickOf(items[b]) ? tickOf(items[a]).compareTo(tickOf(items[b])) : a.compareTo(b));
      return [for (final i in order) items[i]];
    }

    return MidiFile._(division, voices, inTime(meters, (m) => m.tick), inTime(keys, (k) => k.tick), title, length);
  }

  /// The file's data, its ticks a quarter note and the tracks to read (start and end of each
  /// one's events).
  static (ByteData, int, List<(int, int)>) chunks(Uint8List bytes) {
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

  /// Every channel message and meta event of the track between [at] and [end], in order
  /// (system exclusive ones are passed over); last, the track's end (a meta event of type
  /// 0x2F at its last tick, whether the track says so or not).
  static Iterable<MidiEvent> events(ByteData data, int at, int end) sync* {
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
        if (type == 0x2f) break; // end of track
        yield (tick: tick, status: status, a: type, b: at, length: length);
        at += length;
      } else if (status == 0xf0 || status == 0xf7) {
        at += number(); // system exclusive
      } else if (status >= 0x80 && status < 0xf0) {
        running = status;
        final one = (status & 0xf0) == 0xc0 || (status & 0xf0) == 0xd0;
        if (at + (one ? 1 : 2) > end) break; // cut short: the track ends here
        final a = byte(), b = one ? 0 : byte();
        yield (tick: tick, status: status, a: a, b: b, length: 0);
      } else {
        throw FormatException('This MIDI file is damaged: unknown event 0x${status.toRadixString(16)}.');
      }
    }
    yield (tick: tick, status: 0xff, a: 0x2f, b: at, length: 0);
  }
}
