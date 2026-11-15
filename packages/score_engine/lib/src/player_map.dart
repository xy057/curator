import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'score_metadata.dart';
import 'scroll_map.dart';
import 'sounding_notes.dart';

/// What a seat or a section plays: part [part]'s staff [staff] (1 its first; null: every staff
/// of it). [name] is the part's name when it was linked, which finds it again in another score
/// ([PlayerMap.relinked]).
@immutable
class PlayerLink {
  const PlayerLink(this.part, {this.staff, this.name = ''});
  final String part;
  final int? staff;
  final String name;

  /// What [PlayerPulses] knows its notes by.
  String get key => staff == null ? part : '$part#$staff';

  PlayerLink withStaff(int? staff) => PlayerLink(part, staff: staff, name: name);

  Map<String, Object?> toJson() => {'part': part, 'staff': ?staff, 'name': name};

  static PlayerLink fromJson(Object? json, String where) {
    final m = _map(json, where);
    final part = m['part'];
    if (part is! String || part.isEmpty) throw FormatException('$where.part is not a part.');
    final staff = m['staff'];
    if (staff != null && (staff is! num || staff != staff.roundToDouble() || staff < 1 || staff > 64)) {
      throw FormatException('$where.staff is not a staff.');
    }
    final name = m['name'] ?? '';
    if (name is! String) throw FormatException('$where.name is not text.');
    return PlayerLink(part, staff: (staff as num?)?.toInt(), name: name);
  }

  @override
  bool operator ==(Object other) => other is PlayerLink && other.part == part && other.staff == staff && other.name == name;
  @override
  int get hashCode => Object.hash(part, staff, name);
  @override
  String toString() => 'PlayerLink($key)';
}

/// A player: a dot at [x], [y] of the stage (0–1 across and down), playing [link] (null: what its
/// section plays).
@immutable
class MapSeat {
  const MapSeat(this.x, this.y, {this.link});
  final double x, y;
  final PlayerLink? link;

  MapSeat at(double x, double y) => MapSeat(x, y, link: link);
  MapSeat linked(PlayerLink? link) => MapSeat(x, y, link: link);

  @override
  bool operator ==(Object other) => other is MapSeat && other.x == x && other.y == y && other.link == link;
  @override
  int get hashCode => Object.hash(x, y, link);
}

/// How [MapSection.arranged] seats a section's players.
enum SeatShape { rows, arc, line }

/// A group of players seen as one: a name drawn at [labelX], [labelY], a colour (0xAARRGGBB), the
/// size of its dots (across, as a part of the stage's height) and its [seats]. [link] is what
/// they play unless a seat says otherwise.
@immutable
class MapSection {
  const MapSection({
    required this.name,
    required this.color,
    this.size = defaultSize,
    required this.labelX,
    required this.labelY,
    this.link,
    this.seats = const [],
  });

  static const defaultSize = 0.055, minSize = 0.015, maxSize = 0.2;

  final String name;
  final int color;
  final double size;
  final double labelX, labelY;
  final PlayerLink? link;
  final List<MapSeat> seats;

  /// What seat [i] plays: its own link, else the section's.
  PlayerLink? linkOf(int i) => seats[i].link ?? link;

  MapSection copyWith({String? name, int? color, double? size, double? labelX, double? labelY, List<MapSeat>? seats}) => MapSection(
        name: name ?? this.name,
        color: color ?? this.color,
        size: size ?? this.size,
        labelX: labelX ?? this.labelX,
        labelY: labelY ?? this.labelY,
        link: link,
        seats: seats ?? this.seats,
      );

  MapSection linked(PlayerLink? link) =>
      MapSection(name: name, color: color, size: size, labelX: labelX, labelY: labelY, link: link, seats: seats);

  /// Moved by [dx], [dy], its name with it.
  MapSection moved(double dx, double dy) => copyWith(
        labelX: labelX + dx,
        labelY: labelY + dy,
        seats: [for (final s in seats) s.at(s.x + dx, s.y + dy)],
      );

  /// The middle of its seats (its name's place when it has none).
  ({double x, double y}) get center {
    if (seats.isEmpty) return (x: labelX, y: labelY);
    var x = 0.0, y = 0.0;
    for (final s in seats) {
      x += s.x;
      y += s.y;
    }
    return (x: x / seats.length, y: y / seats.length);
  }

  /// [count] players seated as [shape] about where its seats are now, on a stage [aspect] wide
  /// to its height, each keeping its own link in order (new ones with none); its name just
  /// under them.
  MapSection arranged(SeatShape shape, int count, {double aspect = PlayerMap.defaultAspect}) {
    count = count.clamp(1, PlayerMap.maxSeats);
    final c = center, pitch = size * 1.45; // in stage heights
    final points = <({double x, double y})>[];
    switch (shape) {
      case SeatShape.line:
        for (var i = 0; i < count; i++) {
          points.add((x: (i - (count - 1) / 2) * pitch, y: 0));
        }
      case SeatShape.rows:
        final columns = math.max(1, (math.sqrt(count * 2)).ceil()), rows = (count / columns).ceil();
        for (var i = 0; i < count; i++) {
          final row = i ~/ columns, inRow = row == rows - 1 ? count - row * columns : columns;
          points.add((x: (i % columns - (inRow - 1) / 2) * pitch, y: (row - (rows - 1) / 2) * pitch));
        }
      case SeatShape.arc:
        // Facing the front: a bow whose middle is furthest back.
        final radius = math.max(pitch * count / math.pi, pitch * 1.5), step = count == 1 ? 0.0 : math.min(pitch / radius, math.pi / (count - 1));
        for (var i = 0; i < count; i++) {
          final a = (i - (count - 1) / 2) * step;
          points.add((x: radius * math.sin(a), y: radius * (1 - math.cos(a)) - radius * 0.3));
        }
    }
    var bottom = 0.0;
    for (final p in points) {
      bottom = math.max(bottom, p.y);
    }
    return copyWith(
      seats: [
        for (final (i, p) in points.indexed) MapSeat(c.x + p.x / aspect, c.y + p.y, link: i < seats.length ? seats[i].link : null),
      ],
      labelX: c.x,
      labelY: c.y + bottom + size * 1.3,
    );
  }

  Map<String, Object?> toJson() => {
        'name': name,
        'color': '#${(color & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
        'size': _round(size),
        'label': [_round(labelX), _round(labelY)],
        'link': ?link?.toJson(),
        'seats': [
          for (final s in seats) [_round(s.x), _round(s.y), ?s.link?.toJson()],
        ],
      };

  static MapSection fromJson(Object? json, String where) {
    final m = _map(json, where);
    final name = m['name'] ?? '';
    if (name is! String) throw FormatException('$where.name is not text.');
    final color = switch (m['color']) {
      final String hex when RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex) => 0xFF000000 | int.parse(hex.substring(1), radix: 16),
      _ => throw FormatException('$where.color is not a colour.'),
    };
    final size = _number(m['size'] ?? defaultSize, '$where.size');
    if (size < minSize || size > maxSize) throw FormatException('$where.size is out of range.');
    final label = _numbers(m['label'], '$where.label', 2);
    final seats = m['seats'] ?? const [];
    if (seats is! List || seats.length > PlayerMap.maxSeats) throw FormatException('$where.seats is not a list of seats.');
    return MapSection(
      name: name,
      color: color,
      size: size,
      labelX: label[0],
      labelY: label[1],
      link: m['link'] == null ? null : PlayerLink.fromJson(m['link'], '$where.link'),
      seats: [
        for (final (i, s) in seats.indexed)
          switch (s) {
            [final x, final y] || [final x, final y, null] =>
              MapSeat(_place(x, '$where.seats[$i]'), _place(y, '$where.seats[$i]')),
            [final x, final y, final link] =>
              MapSeat(_place(x, '$where.seats[$i]'), _place(y, '$where.seats[$i]'), link: PlayerLink.fromJson(link, '$where.seats[$i][2]')),
            _ => throw FormatException('$where.seats[$i] is not a seat.'),
          },
      ],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MapSection &&
      other.name == name &&
      other.color == color &&
      other.size == size &&
      other.labelX == labelX &&
      other.labelY == labelY &&
      other.link == link &&
      listEquals(other.seats, seats);
  @override
  int get hashCode => Object.hash(name, color, size, labelX, labelY, link, seats.length);
}

/// The smart seatings ([PlayerMap.smart]).
enum SeatingPreset {
  /// Violins I and II at the left, violas and cellos at the right, basses behind the cellos;
  /// winds, brass and percussion in rows behind.
  american,

  /// Violins I and II facing each other across the front, cellos and violas between them, basses
  /// behind the cellos.
  european,

  /// Every instrument on a bow facing the front, in the score's order: a chamber group, a band.
  ensemble,
}

/// A picture of where the players sit (View ▸ Show Player Map): [sections] of dots on a stage
/// [aspect] wide to its height, each linked to the instruments and staves it plays, so that each
/// note played makes its players swell and fade ([PlayerPulses]).
///
/// Kept by a project (the `playermap` module) and as a file of its own (`.cpm`, [encode],
/// [decode]): JSON naming each linked part by its id and name, so another score finds them by
/// name ([relinked]).
@immutable
class PlayerMap {
  const PlayerMap({this.sections = const [], this.aspect = defaultAspect});

  static const defaultAspect = 16 / 9, maxSections = 200, maxSeats = 400;

  /// The height of a section's name, as a part of the stage's.
  static const labelSize = 0.034;
  static const fileFormat = 'application/x-curator-player-map', fileVersion = 1, fileExtension = 'cpm';

  final List<MapSection> sections;
  final double aspect;

  PlayerMap withSections(List<MapSection> sections) => PlayerMap(sections: List.unmodifiable(sections), aspect: aspect);

  /// Every link a seat plays by, once each.
  Set<PlayerLink> get links => {
        for (final section in sections)
          for (var i = 0; i < section.seats.length; i++) ?section.linkOf(i),
      };

  Map<String, Object?> toJson() => {
        'aspect': _round(aspect),
        'sections': [for (final s in sections) s.toJson()],
      };

  /// What [json] holds, checked; a [FormatException] naming the damaged field otherwise.
  static PlayerMap fromJson(Object? json, String where) {
    final m = _map(json, where);
    final aspect = _number(m['aspect'] ?? defaultAspect, '$where.aspect');
    if (aspect < 0.25 || aspect > 4) throw FormatException('$where.aspect is out of range.');
    final sections = m['sections'] ?? const [];
    if (sections is! List || sections.length > maxSections) throw FormatException('$where.sections is not a list of sections.');
    return PlayerMap(
      aspect: aspect,
      sections: List.unmodifiable([for (final (i, s) in sections.indexed) MapSection.fromJson(s, '$where.sections[$i]')]),
    );
  }

  /// A `.cpm` file's text.
  String encode() => const JsonEncoder.withIndent('  ').convert({'format': fileFormat, 'version': fileVersion, 'map': toJson()});

  /// What a `.cpm` file holds; a [FormatException] when it isn't one, or is of a later version.
  static PlayerMap decode(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const FormatException('It isn’t a player map.');
    }
    if (json is! Map || json['format'] != fileFormat) throw const FormatException('It isn’t a player map.');
    final version = json['version'];
    if (version is! num || version > fileVersion) throw const FormatException('It needs a newer version of Curator.');
    return fromJson(json['map'], 'map');
  }

  /// This map's links made [parts]'s: one naming a part of the same name (whatever its id: a
  /// map from another score) is that part's, else one whose id is a part's of no other name
  /// keeps it; the rest play nothing. A staff past the part's last is the whole part.
  PlayerMap relinked(List<ScorePart> parts, {String Function(ScorePart)? nameOf}) {
    String name(ScorePart p) => nameOf?.call(p) ?? p.name;
    final byName = <String, ScorePart>{};
    for (final p in parts) {
      byName.putIfAbsent(_plain(name(p)), () => p);
      byName.putIfAbsent(_plain(p.name), () => p);
    }
    final byId = {for (final p in parts) p.id: p};
    PlayerLink? relink(PlayerLink? link) {
      if (link == null) return null;
      final part = (link.name.isEmpty ? null : byName[_plain(link.name)]) ??
          switch (byId[link.part]) {
            final p? when link.name.isEmpty || _plain(name(p)) == _plain(link.name) || _plain(p.name) == _plain(link.name) => p,
            _ => null,
          };
      if (part == null) return null;
      final staff = link.staff != null && link.staff! <= part.staffNumbers.length ? link.staff : null;
      return PlayerLink(part.id, staff: staff, name: name(part));
    }

    return withLinks(relink);
  }

  /// This map with each link made what [to] makes it (null: playing nothing).
  PlayerMap withLinks(PlayerLink? Function(PlayerLink? link) to) => withSections([
        for (final s in sections) s.linked(to(s.link)).copyWith(seats: [for (final seat in s.seats) seat.linked(to(seat.link))]),
      ]);

  /// A seating of [parts] (in the score's order, named by [nameOf]) as [preset] places them:
  /// each instrument found by its name and sound, its players counted from its name ("Horn
  /// 1.2", "Trumpets I–III") and staves, an instrument of several numbered parts (Flute 1, Flute
  /// 2) one section of a seat each; the whole fitted to the stage.
  static PlayerMap smart(List<ScorePart> parts, {SeatingPreset preset = SeatingPreset.american, String Function(ScorePart)? nameOf}) =>
      _Seating(parts, preset, nameOf ?? (p) => p.name).map();

  @override
  bool operator ==(Object other) => other is PlayerMap && other.aspect == aspect && listEquals(other.sections, sections);
  @override
  int get hashCode => Object.hash(aspect, sections.length);
}

// MARK: Pulses

/// When each linked instrument's notes sound in a performance, to make its players swell: a note
/// makes them [level] 1 at once, fading to nothing over a time its length sets ([envelope]), a
/// short note quickly, a long one slowly; while one still sounds they stay a little lit ([held]).
/// A function of time alone, as a frame is.
class PlayerPulses {
  PlayerPulses._(this._events);

  /// No notes: nothing ever swells.
  static final none = PlayerPulses._(const {});

  /// The swell's rise, and the shortest and longest fade, in seconds.
  static const attack = 0.025, shortest = 0.15, longest = 3.0;

  /// How lit players stay while a note of theirs sounds past its fade.
  static const held = 0.2;

  final Map<String, _Events> _events;

  /// [notes] (each as [soundingNotes] reads it, ties carried on) as [timeline] plays them, pass
  /// by pass, for what [links] play.
  factory PlayerPulses.of(Iterable<SoundingNote> notes, ScoreTimeline timeline, Iterable<PlayerLink> links) {
    final keys = {for (final l in links) l.key};
    if (keys.isEmpty) return none;
    // Each note once, ties joined to the note they carry on.
    final joined = <({String part, int staff, double start, double end})>[];
    final open = <(String, int, String, int), int>{};
    for (final n in notes) {
      if (!keys.contains(n.partId) && !keys.contains('${n.partId}#${n.staff}')) continue;
      final at = (n.partId, n.staff, n.voice, n.midi);
      if (open[at] case final i? when n.tied && (joined[i].end - n.start).abs() < 1e-6) {
        final j = joined[i];
        joined[i] = (part: j.part, staff: j.staff, start: j.start, end: n.end);
        continue;
      }
      open[at] = joined.length;
      joined.add((part: n.partId, staff: n.staff, start: n.start, end: n.end));
    }
    final passes = timeline.passes, byKey = <String, List<(double, double)>>{};
    for (final n in joined) {
      for (final (k, p) in passes.indexed) {
        if (n.start < p.start - 1e-9 || n.start >= p.end - 1e-9) continue;
        final on = timeline.secondsAtQuarter(n.start, pass: k), off = timeline.secondsAtQuarter(math.min(n.end, p.end), pass: k);
        final event = (on, math.max(0.0, off - on));
        if (keys.contains(n.part)) (byKey[n.part] ??= []).add(event);
        final staff = '${n.part}#${n.staff}';
        if (keys.contains(staff)) (byKey[staff] ??= []).add(event);
      }
    }
    return PlayerPulses._({for (final MapEntry(:key, :value) in byKey.entries) key: _Events.of(value)});
  }

  /// How swollen players playing [link] are at [seconds]: 0 at rest, 1 at a note's start.
  double level(PlayerLink? link, double seconds) {
    if (link == null) return 0;
    return _events[link.key]?.level(seconds) ?? 0;
  }

  /// A note's swell [since] seconds after it started, for a note [length] seconds long: up over
  /// [attack], then down over its fade, which is about as long as the note ([shortest] to
  /// [longest]), quickly at first.
  static double envelope(double since, double length) {
    if (since < 0) return 0;
    if (since < attack) return since / attack;
    final fade = fadeOf(length), left = 1 - (since - attack) / fade;
    return left <= 0 ? 0 : left * left;
  }

  /// How long a note [length] seconds long takes to fade.
  static double fadeOf(double length) => (length * 0.9 + 0.1).clamp(shortest, longest);
}

/// One instrument's (or staff's) notes in a performance: onsets in order, their lengths, and the
/// latest end of any note up to each.
class _Events {
  _Events(this.onsets, this.lengths, this.ends);
  final Float64List onsets, lengths, ends;

  factory _Events.of(List<(double, double)> events) {
    events.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : b.$2.compareTo(a.$2));
    // A chord's notes are one onset: its longest.
    final kept = <(double, double)>[];
    for (final e in events) {
      if (kept.isNotEmpty && (kept.last.$1 - e.$1).abs() < 1e-4) continue;
      kept.add(e);
    }
    final onsets = Float64List(kept.length), lengths = Float64List(kept.length), ends = Float64List(kept.length);
    var end = double.negativeInfinity;
    for (final (i, (on, length)) in kept.indexed) {
      onsets[i] = on;
      lengths[i] = length;
      end = math.max(end, on + length);
      ends[i] = end;
    }
    return _Events(onsets, lengths, ends);
  }

  double level(double t) {
    // The last onset at or before t.
    var lo = 0, hi = onsets.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (onsets[mid] <= t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final last = lo - 1;
    if (last < 0) return 0;
    var level = ends[last] > t ? PlayerPulses.held : 0.0;
    const window = PlayerPulses.attack + PlayerPulses.longest;
    for (var i = last; i >= 0 && t - onsets[i] < window; i--) {
      level = math.max(level, PlayerPulses.envelope(t - onsets[i], lengths[i]));
      if (level >= 1) break;
    }
    return level;
  }
}

// MARK: Smart seating

/// What an instrument is to a seating.
enum _Role {
  violin1, violin2, viola, cello, bass, //
  flute, oboe, clarinet, bassoon, saxophone,
  horn, trumpet, trombone, tuba,
  timpani, percussion,
  harp, keyboard,
  voice, solo, other;

  bool get isString => index <= bass.index;
}

/// The colours of a seating's families (0xAARRGGBB): strings warm, woodwinds slate, brass gold,
/// percussion violet, keyboards and harp green, voices teal, soloists pale.
abstract final class MapColors {
  static const strings = 0xFFC2461C, woodwinds = 0xFF4F6D8C, brass = 0xFFC9A227, percussion = 0xFF9B59B6;
  static const keyboards = 0xFF3E9E72, voices = 0xFF2E9BB0, solo = 0xFFE8DCC8, other = 0xFF8C8C8C;

  /// Every one, in the order the map's editor offers them.
  static const all = [strings, woodwinds, brass, percussion, keyboards, voices, solo, other];
}

/// A section as seating finds it: its role, name, seats' links and its own.
typedef _Group = ({_Role role, String name, List<PlayerLink?> seats, PlayerLink? link});

/// Where a section is seated: its points, its name's place.
typedef _At = ({List<({double x, double y})> points, double lx, double ly});

class _Seating {
  _Seating(this.parts, this.preset, this.nameOf);
  final List<ScorePart> parts;
  final SeatingPreset preset;
  final String Function(ScorePart) nameOf;

  /// Gaps in seats: between rows and between sections side by side.
  static const _row = 1.0, _gap = 0.7, _dot = 0.62;

  PlayerMap map() {
    final groups = _groups();
    if (groups.isEmpty) return const PlayerMap();
    final placed = preset == SeatingPreset.ensemble ? _bow(groups) : _orchestra(groups);
    return _fitted(placed);
  }

  // MARK: Who plays

  static final _numbers = RegExp(r'\b(\d+|[ivx]+)\b(?:\s*(?:[-–—]|to)\s*\b(\d+|[ivx]+)\b)?', caseSensitive: false);

  static int? _value(String token) {
    final n = int.tryParse(token);
    if (n != null) return n;
    const roman = {'i': 1, 'ii': 2, 'iii': 3, 'iv': 4, 'v': 5, 'vi': 6, 'vii': 7, 'viii': 8, 'ix': 9, 'x': 10};
    return roman[token.toLowerCase()];
  }

  /// The players a name counts ("Horn 1.2" 2, "Trumpets I–III" 3, "Flute 2" 1); null when it
  /// numbers none. "in B♭", "in F" and the like aren't numbers.
  static ({int count, int? first})? _counted(String name) {
    // "2 Flutes", "3 Trumpets": a count before the instrument.
    if (RegExp(r'^\s*(\d+)\s+\p{L}', unicode: true).firstMatch(name) case final m?) {
      final n = int.parse(m.group(1)!);
      if (n > 0 && n <= 16) return (count: n, first: 1);
    }
    final plain = name.replaceAll(RegExp(r'\bin\s+[A-Ha-h][♭♯b#]?(?=\s|$)'), ' ').replaceAll(RegExp(r'\b[Aa]\s*2\b'), '');
    final found = [
      for (final m in _numbers.allMatches(plain))
        if (_value(m.group(1)!) case final a? when a > 0 && a <= 16) (a, m.group(2) == null ? null : _value(m.group(2)!)),
    ];
    if (found.isEmpty) return null;
    if (found case [(final a, final int b)]) {
      return b > a && b - a < 12 ? (count: b - a + 1, first: a) : (count: 1, first: a);
    }
    return (count: found.length, first: found.first.$1);
  }

  _Role _role(ScorePart p, bool choir) {
    final name = '${nameOf(p)} ${p.name} ${p.abbreviation}'.toLowerCase(), sound = (p.sound ?? '').toLowerCase();
    bool has(String pattern) => RegExp(pattern).hasMatch(name);
    if (has(r'\bsolo\b|soloist')) return _Role.solo;
    if (sound.startsWith('strings.cello') || has(r'cello|\bvc\b|\bvlc\b')) return _Role.cello;
    if (sound.startsWith('strings.viola') || has(r'viola|\bvla\b|\bva\b|bratsche')) return _Role.viola;
    if (sound.startsWith('strings.contrabass') || has(r'contrabass(?!o)|double bass|kontrabass(?!o)|\bcb\b|\bd\.?b\.?\b|basses')) return _Role.bass;
    if (sound.startsWith('strings.violin') || has(r'violin|\bvln?\b|violine|\bvl\b')) {
      final second = has(r'(violin|vln?|violine|vl)\.?\s*(2|ii)\b') || has(r'\bsecond\b|\b2nd\b');
      final first = has(r'(violin|vln?|violine|vl)\.?\s*(1|i)\b') || has(r'\bfirst\b|\b1st\b');
      return second && !first ? _Role.violin2 : _Role.violin1;
    }
    if (has(r'harp')) return _Role.harp;
    if (sound.startsWith('keyboard.') || has(r'piano|celest|organ|harpsichord|cembalo|clavi|keyboard|synth')) return _Role.keyboard;
    if (has(r'piccolo|flute|\bfl\b|\bpicc?\b|flauto|flöte')) return _Role.flute;
    if (has(r'oboe|cor anglais|english horn|\bob\b|\bc\.?a\.?\b')) return _Role.oboe;
    if (has(r'clarinet|\bcl\b|clarinetto|klarinette')) return _Role.clarinet;
    if (has(r'bassoon|\bbsn\b|\bfg\b|fagott')) return _Role.bassoon;
    if (has(r'sax')) return _Role.saxophone;
    if (has(r'horn|\bhn\b|\bcor\b|corno')) return _Role.horn;
    if (has(r'trumpet|cornet|\btpt?\b|\btr\b|tromba|trompete|flugel')) return _Role.trumpet;
    if (has(r'trombone|\btbn?\b|posaune|euphonium')) return _Role.trombone;
    if (has(r'tuba|cimbasso')) return _Role.tuba;
    if (has(r'timpani|\btimp|pauken')) return _Role.timpani;
    if (p.isUnpitchedPercussion ||
        has(r'percussion|drum|cymbal|triangle|glock|xylo|vibra|marimba|bells|tam-?tam|gong|snare|tambourine|perc\b|chimes|wood ?block')) {
      return _Role.percussion;
    }
    if (sound.startsWith('voice.') || has(r'soprano|\balto\b|tenor|baritone|choir|chorus|voice|\bsatb\b|mezzo') || (choir && has(r'\bbass\b'))) {
      return _Role.voice;
    }
    if (has(r'\bbass\b')) return _Role.bass;
    return switch (p.family) {
      InstrumentFamily.woodwinds => _Role.flute,
      InstrumentFamily.brass => _Role.horn,
      InstrumentFamily.percussion => _Role.percussion,
      InstrumentFamily.keyboards => _Role.keyboard,
      InstrumentFamily.voices => _Role.voice,
      InstrumentFamily.strings => _Role.violin1,
      InstrumentFamily.other => _Role.other,
    };
  }

  /// A section's name for several parts: their names with their players' numbers taken off,
  /// when that leaves them all the same; else the first's.
  String _nameFor(List<ScorePart> group) {
    final names = [for (final p in group) nameOf(p)];
    if (names.length == 1) return names.first;
    final first = _bare(names.first);
    if (first.isEmpty || !names.every((n) => _bare(n) == first)) return names.first;
    return names.first.replaceAll(_numbers, '').replaceAll(RegExp(r'[\s.,&+/–—-]+$'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// A name without its players' numbers: "Flute 1" and "Flute 2" are "Flute".
  static String _bare(String n) =>
      n.replaceAll(_numbers, '').replaceAll(RegExp(r'[\s.,&+/–—-]+$'), '').replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  /// The sections, each with its role, name, the parts it is made of and its seats' links.
  List<_Group> _groups() {
    final choir = parts.any((p) => RegExp(r'soprano|\balto\b|tenor', caseSensitive: false).hasMatch(nameOf(p)));
    final roles = [for (final p in parts) _role(p, choir)];
    // Violins unnumbered: the first is the firsts, the next the seconds.
    if (!roles.contains(_Role.violin2)) {
      final violins = [for (final (i, r) in roles.indexed) if (r == _Role.violin1) i];
      if (violins.length >= 2) roles[violins[1]] = _Role.violin2;
    }
    final orchestra = preset != SeatingPreset.ensemble;
    final out = <_Group>[];
    final taken = <int>{};
    for (var i = 0; i < parts.length; i++) {
      if (taken.contains(i)) continue;
      final role = roles[i];
      // Parts of one instrument numbered apart (Flute 1, Flute 2) make one section; in an
      // orchestra, strings and voices stay a section each.
      final group = [i];
      if (!(orchestra && (role.isString || role == _Role.voice)) && role != _Role.solo && role != _Role.other) {
        for (var j = i + 1; j < parts.length; j++) {
          if (!taken.contains(j) && roles[j] == role && _bare(nameOf(parts[j])) == _bare(nameOf(parts[i]))) group.add(j);
        }
      }
      taken.addAll(group);
      final members = [for (final j in group) parts[j]];
      PlayerLink linkTo(ScorePart p, [int? staff]) => PlayerLink(p.id, staff: staff, name: nameOf(p));
      if (role.isString && orchestra) {
        out.add((role: role, name: _nameFor(members), seats: List.filled(_strings(role), null), link: linkTo(members.first)));
        continue;
      }
      if (role == _Role.voice && orchestra) {
        out.add((role: role, name: _nameFor(members), seats: List.filled(8, null), link: linkTo(members.first)));
        continue;
      }
      final seats = <PlayerLink?>[];
      for (final p in members) {
        final staves = p.shownStaffNumbers.isEmpty ? p.staffNumbers : p.shownStaffNumbers;
        final counted = _counted(nameOf(p))?.count ?? 1;
        final keyboard = role == _Role.keyboard || role == _Role.harp;
        if (!keyboard && staves.length > 1 && staves.length == counted) {
          // A player a staff.
          for (final (k, _) in staves.indexed) {
            seats.add(linkTo(p, k + 1));
          }
        } else {
          for (var k = 0; k < (keyboard ? 1 : counted.clamp(1, 8)); k++) {
            seats.add(linkTo(p));
          }
        }
      }
      final one = members.length == 1 && seats.every((s) => s?.staff == null);
      out.add((
        role: role,
        name: _nameFor(members),
        seats: one ? List.filled(seats.length, null) : seats,
        link: one ? linkTo(members.first) : null,
      ));
    }
    return out;
  }

  int _strings(_Role role) => switch (role) {
        _Role.violin1 => 12,
        _Role.violin2 => 10,
        _Role.viola => 8,
        _Role.cello => 8,
        _ => 6,
      };

  static int _colorOf(_Role role) => switch (role) {
        _ when role.isString => MapColors.strings,
        _Role.flute || _Role.oboe || _Role.clarinet || _Role.bassoon || _Role.saxophone => MapColors.woodwinds,
        _Role.horn || _Role.trumpet || _Role.trombone || _Role.tuba => MapColors.brass,
        _Role.timpani || _Role.percussion => MapColors.percussion,
        _Role.harp || _Role.keyboard => MapColors.keyboards,
        _Role.voice => MapColors.voices,
        _Role.solo => MapColors.solo,
        _ => MapColors.other,
      };

  // MARK: Where they sit
  //
  // Laid out in seats (a seat's pitch is 1), the conductor at (0, 0), the players above (y < 0),
  // then fitted to the stage.

  /// A seated section: its points, its name's place.
  static _At _placed(List<({double x, double y})> points, double lx, double ly) =>
      (points: points, lx: lx, ly: ly);

  /// Points of a ring's sector from angle [a] to [b] (0 the left, π the right, over the back),
  /// rows from radius [r0] out, filled front first; its rows' count.
  static (List<({double x, double y})>, int) _sector(int count, double a, double b, double r0) {
    final points = <({double x, double y})>[];
    var row = 0;
    while (points.length < count) {
      final r = r0 + row * _row, fits = math.max(1, ((b - a) * r / 1.08).floor()), n = math.min(fits, count - points.length);
      final step = (b - a) / fits, start = a + (b - a - step * (n - 1)) / 2;
      for (var k = 0; k < n; k++) {
        final t = n == 1 ? (a + b) / 2 : start + step * k;
        points.add((x: -r * math.cos(t), y: -r * math.sin(t)));
      }
      row++;
    }
    return (points, row);
  }

  /// Points of a straight row of [count] centred at [x], [y].
  static List<({double x, double y})> _line(int count, double x, double y) =>
      [for (var k = 0; k < count; k++) (x: x + (k - (count - 1) / 2), y: y)];

  List<(_Draft, _At)> _orchestra(List<_Group> groups) {
    final out = <(_Draft, _At)>[];
    void add(_Group g, _At at) => out.add((_Draft(g.name, _colorOf(g.role), g.link, g.seats), at));
    List<_Group> of(Set<_Role> roles) => [for (final g in groups) if (roles.contains(g.role)) g];

    // The strings: a fan around the conductor, in sectors as wide as their players.
    const r0 = 3.4;
    final front = of({_Role.violin1, _Role.violin2, _Role.viola, _Role.cello});
    final order = preset == SeatingPreset.european
        ? const [_Role.violin1, _Role.cello, _Role.viola, _Role.violin2]
        : const [_Role.violin1, _Role.violin2, _Role.viola, _Role.cello];
    front.sort((a, b) => order.indexOf(a.role).compareTo(order.indexOf(b.role)));
    final total = front.fold(0, (n, g) => n + g.seats.length);
    var angle = 0.04 * math.pi, rows = 0;
    final spread = 0.92 * math.pi, fans = <(_Group, List<({double x, double y})>)>[];
    for (final g in front) {
      final width = spread * g.seats.length / total;
      final (points, n) = _sector(g.seats.length, angle, angle + width, r0);
      rows = math.max(rows, n);
      fans.add((g, points));
      angle += width;
    }
    // Their names along the front, each under its middle (moved apart once fitted).
    var front0 = 0.0;
    for (final (_, points) in fans) {
      for (final p in points) {
        front0 = math.max(front0, p.y);
      }
    }
    for (final (g, points) in fans) {
      add(g, _placed(points, points.fold(0.0, (x, p) => x + p.x) / points.length, front0 + 0.9));
    }
    var back = r0 + math.max(rows, front.isEmpty ? 0 : 2) * _row; // just behind the strings

    // The basses: an arc at the outer side behind the cellos (the right; at the left in a European
    // seating), their name beyond it.
    for (final g in of({_Role.bass})) {
      final r = back + 0.3, width = math.max(0.16 * math.pi, (g.seats.length / 2 + 0.5) / r);
      final (a, b) = preset == SeatingPreset.european ? (0.04 * math.pi, 0.04 * math.pi + width) : (0.96 * math.pi - width, 0.96 * math.pi);
      final (points, _) = _sector(g.seats.length, a, b, r);
      final top = points.reduce((p, q) => q.y < p.y ? q : p);
      add(g, _placed(points, top.x, top.y - 0.85));
    }
    back += 0.6;

    // Rows behind: each a few sections side by side, centred; names under the first row's,
    // over the others'.
    var y = -back;
    void row(List<_Group> sections, {required bool namesUnder}) {
      if (sections.isEmpty) return;
      final width = sections.fold(0.0, (w, g) => w + g.seats.length - 1) + _gap * 2 * (sections.length - 1);
      var left = -width / 2;
      for (final g in sections) {
        final n = g.seats.length, mid = left + (n - 1) / 2;
        add(g, _placed(_line(n, mid, y), mid, y + (namesUnder ? 0.85 : -0.85)));
        left += n - 1 + _gap * 2;
      }
    }

    // The woodwinds in two rows: flutes and oboes, clarinets and bassoons (saxophones after them).
    final flutes = of({_Role.flute, _Role.oboe}), reeds = of({_Role.clarinet, _Role.bassoon, _Role.saxophone});
    if (flutes.isNotEmpty) {
      row(flutes, namesUnder: true);
      y -= _row * 2;
    }
    if (reeds.isNotEmpty) {
      row(reeds, namesUnder: false);
      y -= _row * 2;
    }
    // The brass: horns at the left, trumpets, trombones and tuba to the right.
    final brass = of({_Role.horn, _Role.trumpet, _Role.trombone, _Role.tuba});
    if (brass.isNotEmpty) {
      row(brass, namesUnder: false);
      y -= _row * 2;
    }
    // Timpani and percussion at the back, what else there is beside them.
    final drums = [...of({_Role.timpani, _Role.percussion}), ...of({_Role.other})];
    if (drums.isNotEmpty) {
      row(drums, namesUnder: false);
      y -= _row * 2;
    }
    // Voices on risers at the very back.
    final voices = of({_Role.voice});
    if (voices.isNotEmpty) {
      row(voices, namesUnder: false);
      y -= _row * 2;
    }

    // The harp and keyboards at the left, beside the first violins.
    var ky = -1.2;
    for (final g in of({_Role.harp, _Role.keyboard})) {
      final x = (preset == SeatingPreset.european ? 1 : -1) * (back + 1.2);
      add(g, _placed(_line(g.seats.length, x, ky), x, ky + 0.85));
      ky -= 2.2;
    }
    // Soloists at the front, by the conductor.
    final solos = of({_Role.solo});
    if (solos.isNotEmpty) {
      final saved = y;
      y = 0.6;
      row(solos, namesUnder: true);
      y = saved;
    }
    return out;
  }

  /// Every section on bows facing the front, in the score's order, the front bow first; each
  /// takes as much of its bow as its players or its name needs, its name on the bow's inner side.
  List<(_Draft, _At)> _bow(List<_Group> groups) {
    const pitch = 1.1, between = 2.6, spread = 0.84 * math.pi;
    double widthOf(_Group g) => math.max(g.seats.length * pitch, math.min(g.name.length, 24) * 0.32 + 0.7);
    final widths = [for (final g in groups) widthOf(g)];
    final total = widths.fold(0.0, (a, b) => a + b);
    final bows = total <= 16 ? 1 : (total <= 44 ? 2 : 3);
    final r0 = math.max(2.6, (total * 1.08 / spread - between * bows * (bows - 1) / 2) / bows);
    final out = <(_Draft, _At)>[];
    var next = 0;
    for (var b = 0; b < bows && next < groups.length; b++) {
      final r = r0 + b * between, room = spread * r;
      final these = <int>[];
      var used = 0.0;
      while (next < groups.length && (b == bows - 1 || these.isEmpty || used + widths[next] <= room * 1.02)) {
        these.add(next);
        used += widths[next++];
      }
      // Centred about the middle of the back, as many radians as its sections take.
      var t = math.pi / 2 - used / r / 2;
      for (final k in these) {
        final g = groups[k], width = widths[k] / r, mid = t + width / 2, step = pitch / r;
        final points = [
          for (var s = 0; s < g.seats.length; s++)
            () {
              final a = mid + (s - (g.seats.length - 1) / 2) * step;
              return (x: -r * math.cos(a), y: -r * math.sin(a));
            }(),
        ];
        final low = points.fold(-double.infinity, (y, p) => math.max(y, p.y));
        out.add((_Draft(g.name, _colorOf(g.role), g.link, g.seats), _placed(points, -r * math.cos(mid), low + 0.85)));
        t += width;
      }
    }
    return out;
  }

  /// The seating scaled to fill the stage, a margin round it: wider than it is laid out, up to
  /// [stretch] times, where the stage is (the dots stay round); then names that would overlap
  /// moved apart.
  PlayerMap _fitted(List<(_Draft, _At)> placed) {
    const aspect = PlayerMap.defaultAspect, margin = 0.07, stretch = 1.7;
    // A name's half width and height in seats, at a scale: [PlayerMap.labelSize] of the stage's
    // height a letter, about half as wide.
    var x0 = double.infinity, x1 = double.negativeInfinity, y0 = double.infinity, y1 = double.negativeInfinity;
    for (final (_, at) in placed) {
      for (final p in [...at.points, (x: at.lx, y: at.ly)]) {
        x0 = math.min(x0, p.x - 0.5);
        x1 = math.max(x1, p.x + 0.5);
        y0 = math.min(y0, p.y - 0.5);
        y1 = math.max(y1, p.y + 0.5);
      }
    }
    var kx = (1 - 2 * margin) * aspect / math.max(1e-6, x1 - x0), ky = (1 - 2 * margin) / math.max(1e-6, y1 - y0);
    kx = math.min(kx, ky * stretch);
    ky = math.min(ky, kx * stretch);
    final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
    double sx(double x) => 0.5 + (x - cx) * kx / aspect;
    double sy(double y) => 0.5 + (y - cy) * ky;
    final size = (_dot * math.min(kx, ky)).clamp(MapSection.minSize, 0.085);
    final labels = [for (final (_, at) in placed) (x: sx(at.lx), y: sy(at.ly))];
    final halves = [for (final (d, _) in placed) (w: d.name.length * PlayerMap.labelSize * 0.29 / aspect + 0.008, h: PlayerMap.labelSize * 0.62)];
    for (var round = 0; round < 60; round++) {
      var moved = false;
      for (var a = 0; a < labels.length; a++) {
        for (var b = a + 1; b < labels.length; b++) {
          final dx = labels[b].x - labels[a].x, dy = labels[b].y - labels[a].y;
          final ox = halves[a].w + halves[b].w - dx.abs(), oy = halves[a].h + halves[b].h - dy.abs();
          if (ox <= 0 || oy <= 0) continue;
          moved = true;
          // Apart sideways, the shorter way.
          final push = ox / 2 + 0.002, sign = dx < 0 ? -1.0 : 1.0;
          labels[a] = (x: labels[a].x - sign * push, y: labels[a].y);
          labels[b] = (x: labels[b].x + sign * push, y: labels[b].y);
        }
      }
      if (!moved) break;
    }
    return PlayerMap(
      sections: List.unmodifiable([
        for (final (i, (draft, at)) in placed.indexed)
          MapSection(
            name: draft.name,
            color: draft.color,
            size: size,
            labelX: labels[i].x,
            labelY: labels[i].y,
            link: draft.link,
            seats: [for (final (k, p) in at.points.indexed) MapSeat(sx(p.x), sy(p.y), link: draft.seats[k])],
          ),
      ]),
    );
  }
}

/// A section before it has a place.
class _Draft {
  _Draft(this.name, this.color, this.link, this.seats);
  final String name;
  final int color;
  final PlayerLink? link;
  final List<PlayerLink?> seats;
}

// MARK: JSON

Map<String, Object?> _map(Object? json, String where) =>
    json is Map<String, Object?> ? json : (json is Map ? json.cast<String, Object?>() : throw FormatException('$where is not an object.'));

double _number(Object? value, String where) =>
    value is num && value.isFinite ? value.toDouble() : throw FormatException('$where is not a number.');

/// A place on the stage: a little past its edges is allowed (a seat dragged off them).
double _place(Object? value, String where) {
  final v = _number(value, where);
  if (v < -1 || v > 2) throw FormatException('$where is off the stage.');
  return v;
}

List<double> _numbers(Object? value, String where, int count) {
  if (value is! List || value.length != count) throw FormatException('$where is not $count numbers.');
  return [for (final v in value) _place(v, where)];
}

double _round(double v) => (v * 10000).roundToDouble() / 10000;

/// A name as compared: lower case, spaces and dots alike.
String _plain(String name) => name.toLowerCase().replaceAll(RegExp(r'[\s.]+'), ' ').trim();
