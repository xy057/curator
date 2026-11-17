import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'midi_tempo.dart';
import 'search.dart';

/// A DAW's document as Attacca reads it there (see *Attacca* in docs/daw-link.md): its
/// musical contexts (the tempo map, bar and key signatures each has), its tracks, its
/// recordings and the regions placing them in the song. Read from what the plug-in sends
/// ([DawDocument.fromJson]); every time is in seconds, every position in quarter notes, both
/// from the start of the song.
@immutable
class DawDocument {
  const DawDocument({required this.id, required this.name, this.contexts = const [], this.tracks = const [], this.sources = const [], this.regions = const []});

  /// The plug-in's own name for the document, new each time the DAW opens it.
  final String id;

  /// The DAW project's name, or '' when the DAW gives none.
  final String name;
  final List<DawContext> contexts;
  final List<DawTrack> tracks;
  final List<DawSource> sources;
  final List<DawRegion> regions;

  /// Reads a `document` message. Throws a [FormatException] saying what isn't right; what a
  /// later plug-in may add is passed over.
  factory DawDocument.fromJson(Map<String, Object?> json) {
    final id = _string(json, 'id');
    if (id == null || id.isEmpty) throw const FormatException('A DAW document without an id.');
    List<T> each<T>(String key, T Function(Map<String, Object?> json) read) => switch (json[key]) {
          null => const [],
          final List<Object?> list => [
              for (final e in list)
                if (e is Map<String, Object?>) read(e) else throw FormatException('$key holds something not an object.'),
            ],
          _ => throw FormatException('$key is not a list.'),
        };
    return DawDocument(
      id: id,
      name: _string(json, 'name') ?? '',
      contexts: each('contexts', DawContext.fromJson),
      tracks: each('tracks', DawTrack.fromJson)..sort((a, b) => a.order.compareTo(b.order)),
      sources: each('sources', DawSource.fromJson),
      regions: each('regions', DawRegion.fromJson)..sort((a, b) => a.start.compareTo(b.start)),
    );
  }

  DawContext? context(String? id) => contexts.where((c) => c.id == id).firstOrNull ?? (contexts.length == 1 ? contexts.first : null);
  DawTrack? track(String? id) => tracks.where((t) => t.id == id).firstOrNull;
  DawSource? source(String? id) => sources.where((s) => s.id == id).firstOrNull;
  DawRegion? region(String? id) => regions.where((r) => r.id == id).firstOrNull;

  /// The regions playing [source], in song order.
  List<DawRegion> regionsOf(String source) => [for (final r in regions) if (r.source == source) r];

  /// The region of [source] playing at song time [seconds]: the one sounding then, else the
  /// nearest (the first before the song reaches any).
  DawRegion? regionAt(String source, double seconds) {
    final of = regionsOf(source);
    if (of.isEmpty) return null;
    for (final r in of) {
      if (seconds >= r.start && seconds < r.start + r.length) return r;
    }
    return of.lastWhere((r) => r.start <= seconds, orElse: () => of.first);
  }
}

/// A DAW's musical context: one timeline of tempo, bars and keys (most DAWs have one a song).
@immutable
class DawContext {
  DawContext({required this.id, this.name = '', List<DawTempo> tempo = const [], List<DawBar> bars = const [], this.keys = const []})
      : tempo = List.unmodifiable(tempo),
        bars = List.unmodifiable(bars);

  final String id;
  final String name;

  /// The tempo map: where song seconds meet quarters, in order. Between two the tempo is
  /// constant; before the first and after the last it is as next to them (ARA's rule). Empty
  /// when the DAW gives none.
  final List<DawTempo> tempo;

  /// The bar signatures, each from its position on.
  final List<DawBar> bars;
  final List<DawKey> keys;

  factory DawContext.fromJson(Map<String, Object?> json) {
    final tempo = <DawTempo>[
      for (final e in _list(json, 'tempo'))
        switch (e) {
          [final num s, final num q] when s.isFinite && q.isFinite => (seconds: s.toDouble(), quarter: q.toDouble()),
          _ => throw const FormatException('A tempo entry that is not seconds and quarters.'),
        },
    ];
    for (var i = 1; i < tempo.length; i++) {
      if (!(tempo[i].seconds > tempo[i - 1].seconds && tempo[i].quarter > tempo[i - 1].quarter)) {
        throw const FormatException('The tempo map goes back.');
      }
    }
    return DawContext(
      id: _string(json, 'id') ?? '',
      name: _string(json, 'name') ?? '',
      tempo: tempo,
      bars: [
        for (final e in _list(json, 'bars'))
          switch (e) {
            [final num n, final num d, final num q] when n > 0 && d > 0 && q.isFinite => (numerator: n.toInt(), denominator: d.toInt(), quarter: q.toDouble()),
            _ => throw const FormatException('A bar signature that is not a numerator, a denominator and a position.'),
          },
      ]..sort((a, b) => a.quarter.compareTo(b.quarter)),
      keys: [
        for (final e in _list(json, 'keys'))
          if (e is Map<String, Object?> && e['at'] is num && e['root'] is num)
            DawKey(root: (e['root']! as num).toInt(), quarter: (e['at']! as num).toDouble(), name: _string(e, 'name') ?? '', minor: _minor(e['intervals'])),
      ],
    );
  }

  /// Whether a tempo can be read: two entries at least.
  bool get hasTempo => tempo.length >= 2;

  /// Quarter notes a minute from [i] to the next entry (the last stretch's after the last).
  double _qpm(int i) {
    final a = tempo[math.min(i, tempo.length - 2)], b = tempo[math.min(i, tempo.length - 2) + 1];
    return (b.quarter - a.quarter) / (b.seconds - a.seconds) * 60;
  }

  /// The tempo at [quarter], in quarter notes a minute.
  double quartersPerMinuteAt(double quarter) => _qpm(math.max(0, lastAtOrBefore(tempo.length, quarter, (i) => tempo[i].quarter)));

  /// When the song reaches [quarter].
  double secondsAt(double quarter) {
    final i = math.max(0, lastAtOrBefore(tempo.length, quarter, (i) => tempo[i].quarter));
    return tempo[i].seconds + (quarter - tempo[i].quarter) * 60 / _qpm(i);
  }

  /// Where the song is at [seconds], in quarters (the inverse of [secondsAt]).
  double quarterAt(double seconds) {
    final i = math.max(0, lastAtOrBefore(tempo.length, seconds, (i) => tempo[i].seconds));
    return tempo[i].quarter + (seconds - tempo[i].seconds) * _qpm(i) / 60;
  }

  /// Where bar [bar] starts, in quarters: bar 1 starts at the song's start (quarter 0) when a
  /// barline falls there, else at the first barline after it; 4/4 when the DAW gives no bars.
  double barStart(int bar) {
    final signatures = bars.isEmpty ? const [(numerator: 4, denominator: 4, quarter: 0.0)] : bars;
    var s = 0, at = signatures.first.quarter;
    // On to the next barline: a bar of the signature in force, cut short where the next begins.
    void next() {
      final b = signatures[s], change = s + 1 < signatures.length ? signatures[s + 1].quarter : double.infinity;
      at = math.min(at + b.numerator * 4 / b.denominator, change);
      if (at >= change - 1e-9) s++;
    }

    while (at < -1e-9) {
      next();
    }
    for (var n = 1; n < bar; n++) {
      next();
    }
    return at;
  }

  /// The tempo map the recording [region] plays has in it, as Curator follows a MIDI file's
  /// ([MidiTempoMap]): the score starting [pickup] quarters before where the DAW's bar [bar]
  /// does (an upbeat before bar 1), and when that is in the recording ([start], in its own
  /// seconds: where the region places it). Null when the DAW gives no tempo.
  ({MidiTempoMap map, double start})? tempoFor(DawRegion region, {required String name, int bar = 1, double pickup = 0}) {
    if (!hasTempo) return null;
    final from = barStart(bar) - pickup;
    final tempos = <MidiTempo>[(quarter: 0, quartersPerMinute: _round(quartersPerMinuteAt(from)))];
    for (var i = 0; i < tempo.length - 1; i++) {
      final q = tempo[i].quarter - from;
      if (q <= 1e-9) continue;
      final qpm = _round(_qpm(i));
      if (qpm != tempos.last.quartersPerMinute) tempos.add((quarter: q, quartersPerMinute: qpm));
    }
    return (map: MidiTempoMap(name, tempos), start: region.sourceAt(secondsAt(from)));
  }

  /// A tempo to a millionth of a beat a minute: the same DAW tempo read twice is the same.
  static double _round(double qpm) => (qpm * 1e6).roundToDouble() / 1e6;

  static bool _minor(Object? intervals) =>
      intervals is List && intervals.length == 12 && intervals[3] is num && intervals[4] is num && (intervals[3] as num) > 0 && (intervals[4] as num) == 0;
}

/// Where song time meets the music: [seconds] and [quarter] from the song's start.
typedef DawTempo = ({double seconds, double quarter});

/// A bar signature from [quarter] on.
typedef DawBar = ({int numerator, int denominator, double quarter});

/// A key from [quarter] on: [root] on the circle of fifths (0 C, 1 G, -1 F, …).
@immutable
class DawKey {
  const DawKey({required this.root, required this.quarter, this.name = '', this.minor = false});
  final int root;
  final double quarter;
  final String name;
  final bool minor;
}

/// A track (ARA's region sequence).
@immutable
class DawTrack {
  const DawTrack({required this.id, required this.name, this.order = 0, this.color, this.context});
  final String id;
  final String name;
  final int order;

  /// 0xAARRGGBB, or null.
  final int? color;
  final String? context;

  factory DawTrack.fromJson(Map<String, Object?> json) => DawTrack(
        id: _string(json, 'id') ?? '',
        name: _string(json, 'name') ?? '',
        order: (json['order'] as num?)?.toInt() ?? 0,
        color: _color(json['color']),
        context: _string(json, 'context'),
      );
}

/// A recording in the DAW (ARA's audio source).
@immutable
class DawSource {
  const DawSource({required this.id, required this.name, required this.rate, required this.frames, this.channels = 1, this.readable = true, this.problem});

  /// Its persistent ID: the same each time the DAW opens the project.
  final String id;
  final String name;
  final double rate;
  final int frames;
  final int channels;

  /// Whether the DAW lets its samples be read now (Curator may then ask for it as a file).
  final bool readable;

  /// Why the plug-in can't hold it ("too long", "out of memory"), or null.
  final String? problem;

  double get seconds => rate > 0 ? frames / rate : 0;

  factory DawSource.fromJson(Map<String, Object?> json) => DawSource(
        id: _string(json, 'id') ?? '',
        name: _string(json, 'name') ?? '',
        rate: (json['rate'] as num?)?.toDouble() ?? 0,
        frames: (json['frames'] as num?)?.toInt() ?? 0,
        channels: (json['channels'] as num?)?.toInt() ?? 1,
        readable: json['access'] != false,
        problem: _string(json, 'problem'),
      );
}

/// A region: part of a recording ([from], [span] seconds of it) placed in the song at [start]
/// for [length] seconds on a track.
@immutable
class DawRegion {
  const DawRegion({required this.id, required this.source, required this.start, required this.length, this.from = 0, double? span, this.name = '', this.track, this.color})
      : span = span ?? length;
  final String id;
  final String source;
  final double start;
  final double length;
  final double from;
  final double span;
  final String name;
  final String? track;
  final int? color;

  /// Where song time [seconds] is in the recording (Attacca plays it unstretched).
  double sourceAt(double seconds) => seconds - start + from;

  /// When the recording's [seconds] sound in the song.
  double songAt(double seconds) => seconds - from + start;

  factory DawRegion.fromJson(Map<String, Object?> json) {
    double number(String key) => switch (json[key]) {
          final num n when n.isFinite => n.toDouble(),
          _ => throw FormatException('A region without $key.'),
        };
    return DawRegion(
      id: _string(json, 'id') ?? '',
      source: _string(json, 'source') ?? '',
      start: number('start'),
      length: number('length'),
      from: number('from'),
      span: number('span'),
      name: _string(json, 'name') ?? '',
      track: _string(json, 'track'),
      color: _color(json['color']),
    );
  }
}

/// Where the DAW is playing, as the plug-in last heard: [seconds] from the song's start,
/// [quarters] there (null when the DAW doesn't say), its [tempo] (0 when it doesn't).
typedef DawTransport = ({bool playing, double seconds, double? quarters, double tempo});

/// Reads a `transport` message.
DawTransport dawTransportOf(Map<String, Object?> json) => (
      playing: json['playing'] == true,
      seconds: switch (json['seconds']) { final num n when n.isFinite => n.toDouble(), _ => 0 },
      quarters: switch (json['quarters']) { final num n when n.isFinite && n >= 0 => n.toDouble(), _ => null },
      tempo: switch (json['tempo']) { final num n when n.isFinite && n > 0 => n.toDouble(), _ => 0 },
    );

String? _string(Map<String, Object?> json, String key) => json[key] is String ? json[key]! as String : null;

List<Object?> _list(Map<String, Object?> json, String key) => switch (json[key]) {
      null => const [],
      final List<Object?> list => list,
      _ => throw FormatException('$key is not a list.'),
    };

int? _color(Object? value) {
  if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) return null;
  return 0xff000000 | int.parse(value.substring(1), radix: 16);
}
