import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'hex_color.dart';
import 'score_dynamics.dart';
import 'score_metadata.dart';
import 'search.dart';
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

/// What a section or a map covers of the stage (0–1 across and down), names and dots alike.
typedef StageBox = ({double left, double top, double right, double bottom});

/// How [MapSection.arranged] seats a section's players: as Smart Seating seated them
/// ([MapSection.auto]), or in rows, a bow or a line.
enum SeatShape { auto, rows, arc, line }

/// The ways a [SeatPlan] seats players.
enum SeatPlanKind {
  /// Straight rows, the front one's middle at the plan's place, [SeatPlan.across] a row (null:
  /// one row), the rest behind it.
  rows,

  /// A sector of rings about the plan's place (where the conductor stands), from angle
  /// [SeatPlan.from] to [SeatPlan.to], rows from [SeatPlan.radius] out, each as full as its
  /// width holds: a string section's fan.
  sector,

  /// Bows about the plan's place, centred at angle [SeatPlan.mid], from [SeatPlan.radius] out,
  /// [SeatPlan.across] a bow (null: as many as fit).
  bow,
}

/// How a section's players are seated, so that more or fewer are seated the same way
/// ([MapSection.withCount]): about a place [x], [y] of the stage, in units [unitX] of its width
/// across and [unitY] of its height down (a seat is [pitch] units from the next). Angles are 0 at
/// the left, π/2 straight back, π at the right; rows go back from the front.
@immutable
class SeatPlan {
  const SeatPlan(
    this.kind, {
    required this.x,
    required this.y,
    required this.unitX,
    required this.unitY,
    this.radius = 0,
    this.from = 0,
    this.to = math.pi,
    this.mid = math.pi / 2,
    this.across,
    this.behind = false,
  });

  /// From a seat to the next along a row or bow, and along a sector's ring; from a ring to the next.
  static const pitch = 1.1, ringPitch = 1.08, ringGap = 1.0;

  final SeatPlanKind kind;
  final double x, y, unitX, unitY;
  final double radius, from, to, mid;
  final int? across;

  /// The section's name behind its back row, not in front of its front one.
  final bool behind;

  SeatPlan _with({double? x, double? y, double? unitX, double? unitY}) => SeatPlan(
        kind,
        x: x ?? this.x,
        y: y ?? this.y,
        unitX: unitX ?? this.unitX,
        unitY: unitY ?? this.unitY,
        radius: radius,
        from: from,
        to: to,
        mid: mid,
        across: across,
        behind: behind,
      );

  SeatPlan moved(double dx, double dy) => _with(x: x + dx, y: y + dy);

  /// Scaled by [f] about [cx], [cy] of the stage.
  SeatPlan scaled(double f, double cx, double cy) => _with(x: cx + (x - cx) * f, y: cy + (y - cy) * f, unitX: unitX * f, unitY: unitY * f);

  /// [count] seats in units about the place, each with its row (0 the front).
  List<({double x, double y, int row})> places(int count) {
    final out = <({double x, double y, int row})>[];
    for (var row = 0; out.length < count; row++) {
      final left = count - out.length;
      switch (kind) {
        case SeatPlanKind.rows:
          final n = math.min(across ?? left, left);
          for (var k = 0; k < n; k++) {
            out.add((x: (k - (n - 1) / 2) * pitch, y: -row * pitch, row: row));
          }
        case SeatPlanKind.sector:
          final r = radius + row * ringGap, fits = math.max(1, ((to - from) * r / ringPitch).floor()), n = math.min(fits, left);
          final step = (to - from) / fits, start = from + (to - from - step * (n - 1)) / 2;
          for (var k = 0; k < n; k++) {
            final t = n == 1 ? (from + to) / 2 : start + step * k;
            out.add((x: -r * math.cos(t), y: -r * math.sin(t), row: row));
          }
        case SeatPlanKind.bow:
          final r = math.max(0.5, radius + row * ringGap);
          final fits = across ?? math.max(1, (0.96 * math.pi * r / pitch).floor()), n = math.min(fits, left), step = pitch / r;
          for (var k = 0; k < n; k++) {
            final t = mid + (k - (n - 1) / 2) * step;
            out.add((x: -r * math.cos(t), y: -r * math.sin(t), row: row));
          }
      }
    }
    return out;
  }

  /// [count] seats' places on the stage.
  List<MapSeat> seats(int count) => [for (final p in places(count)) MapSeat(x + p.x * unitX, y + p.y * unitY)];

  /// Where the name [name] of [count] players of dots [size] across goes on a stage [aspect]
  /// wide: by the middle of the front row (the back's when [behind]), clear of its dots.
  ({double x, double y}) label(int count, {required String name, required double size, required double aspect}) {
    final rows = count < 1 ? 1 : places(count).last.row + 1, row = behind ? rows - 1 : 0;
    // The name's half width and height, a dot's radius and a gap, in units.
    final hw = labelHalfWidth(name, aspect) / unitX, hh = labelHalfHeight / unitY;
    final clear = (size / 2 + 0.006) / unitY;
    final ({double x, double y}) at;
    if (kind == SeatPlanKind.sector) {
      // Towards the place (in front) or away from it (behind), as far as the name's box reaches that way.
      final r = radius + row * ringGap, t = (from + to) / 2, c = math.cos(t), s = math.sin(t), out = behind ? -1.0 : 1.0;
      final d = clear + c.abs() * hw + s.abs() * hh;
      at = (x: -r * c + out * c * d, y: -r * s + out * s * d);
    } else {
      // Under the row's middle (over it, behind), clear of its seats under (over) the name.
      final all = places(count), these = [for (final p in all) if (p.row == row) p];
      final mx = (these.first.x + these.last.x) / 2, rx = clear * unitY / unitX;
      var edge = behind ? double.infinity : double.negativeInfinity;
      for (final p in all) {
        if ((p.x - mx).abs() < hw + rx) edge = behind ? math.min(edge, p.y) : math.max(edge, p.y);
      }
      at = (x: mx, y: behind ? edge - clear - hh : edge + clear + hh);
    }
    return (x: x + at.x * unitX, y: y + at.y * unitY);
  }

  /// About how wide [name] is drawn, in ems (its height): a Chinese, Japanese or Korean
  /// character (or another drawn as wide) one, any other a little over half.
  static double labelEms(String name) {
    var ems = 0.0;
    for (final r in name.runes) {
      final wide = r >= 0x1100 &&
          (r <= 0x115F || // Hangul Jamo
              (r >= 0x2E80 && r <= 0xA4CF) || // CJK radicals … kana … ideographs … Yi
              (r >= 0xAC00 && r <= 0xD7A3) || // Hangul syllables
              (r >= 0xF900 && r <= 0xFAFF) || // compatibility ideographs
              (r >= 0xFE30 && r <= 0xFE4F) || // compatibility forms
              (r >= 0xFF00 && r <= 0xFF60) || // full-width forms
              (r >= 0xFFE0 && r <= 0xFFE6) ||
              (r >= 0x1F300 && r <= 0x1FAFF) || // emoji
              (r >= 0x20000 && r <= 0x3FFFD)); // ideographs beyond the first plane
      ems += wide ? 1.0 : 0.58;
    }
    return ems;
  }

  /// Half a section's name's width (of the stage's) and height (of its height).
  static double labelHalfWidth(String name, double aspect) => labelEms(name) * PlayerMap.labelSize * 0.5 / aspect + 0.008;
  static const labelHalfHeight = PlayerMap.labelSize * 0.62;

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'at': [_round(x), _round(y)],
        'unit': [_round(unitX), _round(unitY)],
        if (kind != SeatPlanKind.rows) 'radius': _round(radius),
        if (kind == SeatPlanKind.sector) 'angles': [_round(from), _round(to)],
        if (kind == SeatPlanKind.bow) 'mid': _round(mid),
        'across': ?across,
        if (behind) 'behind': true,
      };

  static SeatPlan fromJson(Object? json, String where) {
    final m = _map(json, where);
    final kind = SeatPlanKind.values.where((k) => k.name == m['kind']).firstOrNull ?? (throw FormatException('$where.kind is not a plan.'));
    double number(Object? v, String field, double lo, double hi) {
      final n = _number(v, '$where.$field');
      if (n < lo || n > hi) throw FormatException('$where.$field is out of range.');
      return n;
    }

    final at = m['at'], unit = m['unit'], angles = m['angles'] ?? const [0, math.pi];
    if (at is! List || at.length != 2 || unit is! List || unit.length != 2 || angles is! List || angles.length != 2) {
      throw FormatException('$where is not a plan.');
    }
    final across = m['across'];
    if (across != null && (across is! num || across != across.roundToDouble() || across < 1 || across > PlayerMap.maxSeats)) {
      throw FormatException('$where.across is not a count.');
    }
    return SeatPlan(
      kind,
      x: number(at[0], 'at', -20, 20),
      y: number(at[1], 'at', -20, 20),
      unitX: number(unit[0], 'unit', 1e-4, 1),
      unitY: number(unit[1], 'unit', 1e-4, 1),
      radius: number(m['radius'] ?? 0, 'radius', 0, 400),
      from: number(angles[0], 'angles', -7, 7),
      to: number(angles[1], 'angles', -7, 7),
      mid: number(m['mid'] ?? math.pi / 2, 'mid', -7, 7),
      across: (across as num?)?.toInt(),
      behind: m['behind'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SeatPlan &&
      other.kind == kind &&
      other.x == x &&
      other.y == y &&
      other.unitX == unitX &&
      other.unitY == unitY &&
      other.radius == radius &&
      other.from == from &&
      other.to == to &&
      other.mid == mid &&
      other.across == across &&
      other.behind == behind;
  @override
  int get hashCode => Object.hash(kind, x, y, unitX, unitY, radius, from, to, mid, across, behind);
}

/// A group of players seen as one: a name drawn at [labelX], [labelY], a colour (0xAARRGGBB), the
/// size of its dots (across, as a part of the stage's height) and its [seats]. [link] is what
/// they play unless a seat says otherwise; [plan] how they are seated, so that more or fewer
/// are seated the same way (null: a map made before plans, seen from its seats when asked), and
/// [auto] how Smart Seating seated them, to go back to (null: none did).
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
    this.plan,
    this.auto,
  });

  static const defaultSize = 0.055, minSize = 0.015, maxSize = 0.2;

  final String name;
  final int color;
  final double size;
  final double labelX, labelY;
  final PlayerLink? link;
  final List<MapSeat> seats;
  final SeatPlan? plan, auto;

  /// What seat [i] plays: its own link, else the section's.
  PlayerLink? linkOf(int i) => seats[i].link ?? link;

  /// Whether one of its players plays nothing: no link of its own, nor the section's.
  bool get hasUnlinked => link == null && seats.any((s) => s.link == null);

  /// With player [i] made [seat].
  MapSection withSeat(int i, MapSeat seat) => copyWith(seats: [for (final (j, s) in seats.indexed) j == i ? seat : s]);

  MapSection copyWith({String? name, int? color, double? size, double? labelX, double? labelY, List<MapSeat>? seats, SeatPlan? plan, SeatPlan? auto}) =>
      MapSection(
        name: name ?? this.name,
        color: color ?? this.color,
        size: size ?? this.size,
        labelX: labelX ?? this.labelX,
        labelY: labelY ?? this.labelY,
        link: link,
        seats: seats ?? this.seats,
        plan: plan ?? this.plan,
        auto: auto ?? this.auto,
      );

  MapSection linked(PlayerLink? link) =>
      MapSection(name: name, color: color, size: size, labelX: labelX, labelY: labelY, link: link, seats: seats, plan: plan, auto: auto);

  /// Moved by [dx], [dy], its name and plan with it.
  MapSection moved(double dx, double dy) => copyWith(
        labelX: labelX + dx,
        labelY: labelY + dy,
        seats: [for (final s in seats) s.at(s.x + dx, s.y + dy)],
        plan: plan?.moved(dx, dy),
        auto: auto?.moved(dx, dy),
      );

  /// Scaled by [f] about [cx], [cy] of the stage, its dots too.
  MapSection scaled(double f, double cx, double cy) => copyWith(
        size: (size * f).clamp(minSize, maxSize),
        labelX: cx + (labelX - cx) * f,
        labelY: cy + (labelY - cy) * f,
        seats: [for (final s in seats) s.at(cx + (s.x - cx) * f, cy + (s.y - cy) * f)],
        plan: plan?.scaled(f, cx, cy),
        auto: auto?.scaled(f, cx, cy),
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

  /// What its name covers of a stage [aspect] wide (its place alone, with no name).
  StageBox labelBounds([double aspect = PlayerMap.defaultAspect]) {
    final w = name.isEmpty ? 0.0 : SeatPlan.labelHalfWidth(name, aspect), h = name.isEmpty ? 0.0 : SeatPlan.labelHalfHeight;
    return (left: labelX - w, top: labelY - h, right: labelX + w, bottom: labelY + h);
  }

  /// What its dots and name cover of a stage [aspect] wide.
  StageBox bounds([double aspect = PlayerMap.defaultAspect]) {
    final rx = size / 2 / aspect, ry = size / 2;
    var box = name.isEmpty && seats.isNotEmpty
        ? (left: double.infinity, top: double.infinity, right: double.negativeInfinity, bottom: double.negativeInfinity)
        : labelBounds(aspect);
    for (final s in seats) {
      box = (
        left: math.min(box.left, s.x - rx),
        top: math.min(box.top, s.y - ry),
        right: math.max(box.right, s.x + rx),
        bottom: math.max(box.bottom, s.y + ry),
      );
    }
    return box;
  }

  /// Moved by [dx], [dy] as a drag or an arrow moves it (all of it; its name alone for [label];
  /// player [seat] alone), but never off the stage: only as far as keeps what moves on it. What
  /// is off it already goes no further off.
  MapSection dragged(double dx, double dy, {int? seat, bool label = false, double aspect = PlayerMap.defaultAspect}) {
    final box = label
        ? labelBounds(aspect)
        : switch (seat) {
            final i? => (left: seats[i].x - size / 2 / aspect, top: seats[i].y - size / 2, right: seats[i].x + size / 2 / aspect, bottom: seats[i].y + size / 2),
            null => bounds(aspect),
          };
    double kept(double d, double lo, double hi) {
      final a = -lo, b = 1 - hi;
      return d.clamp(math.min(math.min(a, b), 0.0), math.max(math.max(a, b), 0.0));
    }

    dx = kept(dx, box.left, box.right);
    dy = kept(dy, box.top, box.bottom);
    if (label) return copyWith(labelX: labelX + dx, labelY: labelY + dy);
    if (seat != null) return withSeat(seat, seats[seat].at(seats[seat].x + dx, seats[seat].y + dy));
    return moved(dx, dy);
  }

  /// [count] players seated by [plan], each keeping its own link in order (new ones with none),
  /// its name where the plan puts it.
  MapSection planned(SeatPlan plan, int count, {double aspect = PlayerMap.defaultAspect}) {
    count = count.clamp(1, PlayerMap.maxSeats);
    final label = plan.label(count, name: name, size: size, aspect: aspect);
    return copyWith(
      seats: [for (final (i, s) in plan.seats(count).indexed) i < seats.length ? s.linked(seats[i].link) : s],
      labelX: label.x,
      labelY: label.y,
      plan: plan,
    );
  }

  /// [count] players seated as [shape] about where its seats are now (as Smart Seating seated
  /// them, moved as the section was, for [SeatShape.auto]), on a stage [aspect] wide to its
  /// height, each keeping its own link in order (new ones with none); its name by them.
  MapSection arranged(SeatShape shape, int count, {double aspect = PlayerMap.defaultAspect}) {
    count = count.clamp(1, PlayerMap.maxSeats);
    final c = center, unit = size * 1.45 / SeatPlan.pitch; // a seat's pitch, in stage heights
    final SeatPlan plan;
    switch (shape) {
      case SeatShape.auto:
        plan = auto ?? _seen(aspect);
      case SeatShape.line:
        plan = SeatPlan(SeatPlanKind.rows, x: c.x, y: c.y, unitX: unit / aspect, unitY: unit);
      case SeatShape.rows:
        final across = math.max(1, (math.sqrt(count * 2)).ceil()), rows = (count / across).ceil();
        plan = SeatPlan(SeatPlanKind.rows, x: c.x, y: c.y + (rows - 1) / 2 * SeatPlan.pitch * unit, unitX: unit / aspect, unitY: unit, across: across);
      case SeatShape.arc:
        // Facing the front: a bow whose middle is furthest back, the bow's middle where they were.
        final radius = math.max(count * SeatPlan.pitch / (0.7 * math.pi), 1.6);
        plan = SeatPlan(SeatPlanKind.bow, x: c.x, y: c.y + radius * 0.75 * unit, unitX: unit / aspect, unitY: unit, radius: radius);
    }
    return planned(plan, count, aspect: aspect);
  }

  /// The shape [arranged] would give its seats as they are.
  SeatShape get shape => switch (plan) {
        final p? when p == auto => SeatShape.auto,
        SeatPlan(kind: SeatPlanKind.rows, across: null) => SeatShape.line,
        SeatPlan(kind: SeatPlanKind.rows) => SeatShape.rows,
        null => _seen().across == null ? SeatShape.line : SeatShape.rows,
        _ => SeatShape.arc,
      };

  /// [count] players seated as its [plan] seats them (or as its seats are, in rows, when it has
  /// none), each keeping its own link in order; its name where it was beside them.
  MapSection withCount(int count, {double aspect = PlayerMap.defaultAspect}) {
    final own = plan;
    final next = planned(own ?? _seen(aspect), count, aspect: aspect);
    if (own == null) return next;
    // A name moved from its plan's place stays as far from it.
    final was = own.label(seats.length, name: name, size: size, aspect: aspect);
    return next.copyWith(labelX: next.labelX + labelX - was.x, labelY: next.labelY + labelY - was.y);
  }

  /// Without player [i]: the rest seated anew as its plan seats one fewer ([withCount]), each
  /// keeping what it plays. Its last player stays.
  MapSection withoutSeat(int i, {double aspect = PlayerMap.defaultAspect}) {
    if (seats.length < 2) return this;
    final links = [for (final (j, s) in seats.indexed) if (j != i) s.link];
    final fewer = withCount(seats.length - 1, aspect: aspect);
    return fewer.copyWith(seats: [for (final (j, s) in fewer.seats.indexed) s.linked(links[j])]);
  }

  /// Its seats seen as rows: as many a row as its widest, its front row's middle the place.
  SeatPlan _seen([double aspect = PlayerMap.defaultAspect]) {
    final unit = size * 1.45 / SeatPlan.pitch;
    if (seats.isEmpty) return SeatPlan(SeatPlanKind.rows, x: labelX, y: labelY, unitX: unit / aspect, unitY: unit);
    final byY = [...seats]..sort((a, b) => b.y.compareTo(a.y));
    final rows = <List<MapSeat>>[[byY.first]];
    for (final s in byY.skip(1)) {
      if (rows.last.last.y - s.y < unit * SeatPlan.pitch * 0.5) {
        rows.last.add(s);
      } else {
        rows.add([s]);
      }
    }
    final front = rows.first, across = rows.fold(0, (n, r) => math.max(n, r.length));
    return SeatPlan(
      SeatPlanKind.rows,
      x: center.x,
      y: front.fold(0.0, (y, s) => y + s.y) / front.length,
      unitX: unit / aspect,
      unitY: unit,
      across: rows.length == 1 ? null : across,
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
        'plan': ?plan?.toJson(),
        // Smart Seating's: the plan's own while the section is seated by it.
        if (auto != null) 'auto': auto == plan ? true : auto!.toJson(),
      };

  static MapSection fromJson(Object? json, String where) {
    final m = _map(json, where);
    final name = m['name'] ?? '';
    if (name is! String) throw FormatException('$where.name is not text.');
    final color = argbOfHex(m['color']) ?? (throw FormatException('$where.color is not a colour.'));
    final size = _number(m['size'] ?? defaultSize, '$where.size');
    if (size < minSize || size > maxSize) throw FormatException('$where.size is out of range.');
    final label = _numbers(m['label'], '$where.label', 2);
    final seats = m['seats'] ?? const [];
    // (A section has a seat at least: with none, whatever asks where it is has nothing to ask.)
    if (seats is! List || seats.isEmpty || seats.length > PlayerMap.maxSeats) throw FormatException('$where.seats is not a list of seats.');
    final plan = m['plan'] == null ? null : SeatPlan.fromJson(m['plan'], '$where.plan');
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
      plan: plan,
      auto: switch (m['auto']) {
        null => null,
        true => plan ?? (throw FormatException('$where.auto has no plan.')),
        final auto => SeatPlan.fromJson(auto, '$where.auto'),
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MapSection &&
          other.name == name &&
          other.color == color &&
          other.size == size &&
          other.labelX == labelX &&
          other.labelY == labelY &&
          other.link == link &&
          other.plan == plan &&
          other.auto == auto &&
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

  /// With section [k] made [section], nothing else moved ([roomFor] makes room for it).
  PlayerMap withSection(int k, MapSection section) => withSections([...sections]..[k] = section);

  /// Without section [k].
  PlayerMap without(int k) => withSections([...sections]..removeAt(k));

  /// With [section] added, last: moved the shortest way that leaves it clear of the others and
  /// on the stage (where it is, when it is clear there, or when nowhere near is).
  PlayerMap adding(MapSection section) => withSections([
        ...sections,
        sections.any((s) => _covers(s, section)) ? _cleared(section, sections, onStage: true) ?? section : section,
      ]);

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

  /// What its sections' dots and names cover of the stage; null with none.
  StageBox? get bounds {
    StageBox? all;
    for (final s in sections) {
      final box = s.bounds(aspect);
      all = all == null
          ? box
          : (
              left: math.min(all.left, box.left),
              top: math.min(all.top, box.top),
              right: math.max(all.right, box.right),
              bottom: math.max(all.bottom, box.bottom),
            );
    }
    return all;
  }

  /// This map with section [k] made [section], the sections it would now cover moved out of its
  /// way (each away from it, and those they would then cover in turn; one it covered already, set
  /// there by hand, stays), and the whole made smaller where it would leave the stage (or reach
  /// further off it than it did).
  PlayerMap roomFor(int k, MapSection section) {
    final out = withSection(k, section).sections.toList();
    final settled = <int>{k}, queue = [k];
    for (var head = 0; head < queue.length; head++) {
      final i = queue[head];
      for (var j = 0; j < out.length; j++) {
        if (settled.contains(j) || !_covers(out[i], out[j]) || _covers(sections[i], sections[j])) continue;
        out[j] = _cleared(out[j], [for (final m in settled) out[m]], from: out[i].center) ?? out[j];
        settled.add(j);
        queue.add(j);
      }
    }
    const margin = 0.01;
    final was = bounds ?? (left: margin, top: margin, right: 1 - margin, bottom: 1 - margin);
    return withSections(out)._keptIn((
      left: math.min(margin, was.left),
      top: math.min(margin, was.top),
      right: math.max(1 - margin, was.right),
      bottom: math.max(1 - margin, was.bottom),
    ));
  }

  /// [section] moved the shortest way that leaves it clear of every one of [others] (of the ways
  /// leading away from [from], when given; only to where all of it is on the stage, for
  /// [onStage]); null when no way a good part of the stage long does.
  MapSection? _cleared(MapSection section, List<MapSection> others, {({double x, double y})? from, bool onStage = false}) {
    var ax = 0.0, ay = -1.0;
    if (from != null) {
      final to = section.center, x = (to.x - from.x) * aspect, y = to.y - from.y, d = math.sqrt(x * x + y * y);
      if (d >= 1e-6) (ax, ay) = (x / d, y / d);
    }
    MapSection? best;
    var bestStep = 121;
    for (var w = 0; w < 24; w++) {
      final dx = math.cos(w * math.pi / 12), dy = math.sin(w * math.pi / 12);
      if (from != null && dx * ax + dy * ay < 0.2) continue;
      for (var step = 1; step < bestStep; step++) {
        final moved = section.moved(dx * 0.006 * step / aspect, dy * 0.006 * step);
        if (onStage) {
          // Further this way only leaves it further.
          final box = moved.bounds(aspect);
          if (box.left < 0 || box.right > 1 || box.top < 0 || box.bottom > 1) break;
        }
        if (others.any((o) => _covers(o, moved))) continue;
        (best, bestStep) = (moved, step);
        break;
      }
    }
    return best;
  }

  /// Whether [a]'s dots or name and [b]'s meet (a dot's width apart at the least).
  bool _covers(MapSection a, MapSection b) {
    final gap = math.max(a.size, b.size) * 0.15;
    final boxes = [for (final s in [a, b]) s.name.isEmpty ? null : (x: s.labelX * aspect, y: s.labelY, w: SeatPlan.labelHalfWidth(s.name, aspect) * aspect, h: SeatPlan.labelHalfHeight)];
    bool dotInBox(MapSeat p, double r, ({double x, double y, double w, double h})? box) =>
        box != null && (p.x * aspect - box.x).abs() < box.w + r + gap && (p.y - box.y).abs() < box.h + r + gap;
    for (final p in a.seats) {
      for (final q in b.seats) {
        final dx = (p.x - q.x) * aspect, dy = p.y - q.y, r = (a.size + b.size) / 2 + gap;
        if (dx * dx + dy * dy < r * r) return true;
      }
      if (dotInBox(p, a.size / 2, boxes[1])) return true;
    }
    for (final q in b.seats) {
      if (dotInBox(q, b.size / 2, boxes[0])) return true;
    }
    final (p, q) = (boxes[0], boxes[1]);
    return p != null && q != null && (p.x - q.x).abs() < p.w + q.w && (p.y - q.y).abs() < p.h + q.h;
  }

  /// The map moved, and made smaller when that isn't enough, so that every dot and name is in
  /// [room] of the stage.
  PlayerMap _keptIn(StageBox room) {
    var map = this;
    for (var round = 0; round < 4; round++) {
      final box = map.bounds;
      if (box == null || (box.left >= room.left && box.right <= room.right && box.top >= room.top && box.bottom <= room.bottom)) return map;
      final f = math.min(1.0, math.min((room.right - room.left) / (box.right - box.left), (room.bottom - room.top) / (box.bottom - box.top)));
      // Into the room: as little as moves it in.
      double into(double lo, double hi, double from, double to) => lo < from ? from - lo : (hi > to ? to - hi : 0);
      if (f >= 1) {
        final dx = into(box.left, box.right, room.left, room.right), dy = into(box.top, box.bottom, room.top, room.bottom);
        return map.withSections([for (final s in map.sections) s.moved(dx, dy)]);
      }
      // Smaller about the middle of what it covers, then that put at the room's middle.
      final cx = (box.left + box.right) / 2, cy = (box.top + box.bottom) / 2;
      final dx = (room.left + room.right) / 2 - cx, dy = (room.top + room.bottom) / 2 - cy;
      map = map.withSections([for (final s in map.sections) s.scaled(f * 0.98, cx, cy).moved(dx, dy)]);
    }
    return map;
  }

  /// A seating of [parts] (in the score's order, named by [nameOf]) as [preset] places them:
  /// each instrument found by its name and sound, its players counted from its name ("Horn
  /// 1.2", "Trumpets I–III") and staves, an instrument of several numbered parts (Flute 1, Flute
  /// 2) one section of a seat each; the whole fitted to the stage.
  static PlayerMap smart(List<ScorePart> parts, {SeatingPreset preset = SeatingPreset.american, String Function(ScorePart)? nameOf}) =>
      _Seating(parts, preset, nameOf ?? (p) => p.name).map();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PlayerMap && other.aspect == aspect && listEquals(other.sections, sections);
  @override
  int get hashCode => Object.hash(aspect, sections.length);
}

// MARK: Pulses

/// A score's notes as a player map hears them: for each instrument, and each staff of it, where
/// its notes start and end in the score (quarters; ties joined, a chord one note) and how far each
/// swells its players ([PlayerPulses.strengthOf] its dynamic). Read once for a score ([of]: the
/// work of it, so done on another isolate where there is one), whatever plays it and however fast.
class PlayerNotes {
  PlayerNotes._(this._spans);

  /// No notes.
  static final none = PlayerNotes._(const {});

  /// By [PlayerLink.key].
  final Map<String, _Spans> _spans;

  /// The notes of the score [musicXML], whose bars start at [measureStarts], unpitched ones too,
  /// each as loud as its dynamics say: what the app, a video and a web page pulse the map with.
  factory PlayerNotes.ofScore(String musicXML, List<double> measureStarts) =>
      PlayerNotes.of(soundingNotes(musicXML, measureStarts, unpitched: true), dynamics: ScoreDynamics.read(musicXML, measureStarts));

  /// [notes] (each as [soundingNotes] reads it, ties carried on), each as loud as [dynamics]
  /// says (none: all mf).
  factory PlayerNotes.of(Iterable<SoundingNote> notes, {ScoreDynamics? dynamics}) {
    final loud = dynamics ?? ScoreDynamics.none;
    final byStaff = <String, Map<int, List<_Span>>>{};
    // Each note once, ties joined to the note they carry on.
    final open = <(String, int, String, int), _Span>{};
    for (final n in notes) {
      final at = (n.partId, n.staff, n.voice, n.midi);
      if (open[at] case final span? when n.tied && (span.end - n.start).abs() < 1e-6) {
        span.end = n.end;
        continue;
      }
      final span = open[at] = _Span(n.start, n.end);
      ((byStaff[n.partId] ??= {})[n.staff] ??= []).add(span);
    }
    final out = <String, _Spans>{};
    for (final MapEntry(key: part, value: staves) in byStaff.entries) {
      _Spans pack(List<_Span> spans) => _Spans.of(spans, (start) => PlayerPulses.strengthOf(loud.at(part, start)));
      for (final MapEntry(key: staff, value: spans) in staves.entries) {
        out['$part#$staff'] = pack(spans);
      }
      // The whole instrument: its one staff's, or all of them together.
      out[part] = staves.length == 1 ? out['$part#${staves.keys.single}']! : pack([for (final spans in staves.values) ...spans]);
    }
    return PlayerNotes._(out);
  }
}

/// A note from where it starts to where it (and what is tied to it) ends, in score quarters.
class _Span {
  _Span(this.start, this.end);
  final double start;
  double end;
}

/// One instrument's (or staff's) notes in the score, in order: where each starts and ends, and
/// how far it swells its players; a chord is one, its longest.
class _Spans {
  _Spans(this.starts, this.ends, this.strengths);
  final Float64List starts, ends, strengths;

  factory _Spans.of(List<_Span> spans, double Function(double start) strength) {
    spans.sort((a, b) => a.start.compareTo(b.start));
    final starts = Float64List(spans.length), ends = Float64List(spans.length);
    var n = 0;
    for (final s in spans) {
      if (n > 0 && s.start - starts[n - 1] < 1e-9) {
        if (s.end > ends[n - 1]) ends[n - 1] = s.end;
        continue;
      }
      starts[n] = s.start;
      ends[n++] = s.end;
    }
    final strengths = Float64List(n);
    for (var i = 0; i < n; i++) {
      strengths[i] = strength(starts[i]);
    }
    return _Spans(Float64List.sublistView(starts, 0, n), Float64List.sublistView(ends, 0, n), strengths);
  }
}

/// When each instrument's notes sound in a performance, to make its players swell: a note makes
/// them swell at once, as far as how loud it is played ([strengthOf] its [ScoreDynamics] level: a
/// pp note a little, an ff one nearly to [level] 1), fading to nothing over a time its length sets
/// ([envelope]), a short note quickly, a long one slowly; while one still sounds they stay a
/// little lit ([held], as loud). A function of time alone, as a frame is.
///
/// Made in no time, for a performance changes as often as a beat is dragged: an instrument's
/// notes are put in the performance's seconds the first time one is asked of ([level]), so only
/// those a map links ever are, and whatever a map links it asks the same pulses.
class PlayerPulses {
  PlayerPulses(this._notes, this._timeline);

  /// No notes: nothing ever swells.
  static final none = PlayerPulses(PlayerNotes.none, null);

  /// [notes] as [timeline] plays them, each as loud as [dynamics] says ([PlayerNotes.of]).
  factory PlayerPulses.of(Iterable<SoundingNote> notes, ScoreTimeline timeline, {ScoreDynamics? dynamics}) =>
      PlayerPulses(PlayerNotes.of(notes, dynamics: dynamics), timeline);

  /// The swell's rise, and the shortest and longest fade, in seconds.
  static const attack = 0.025, shortest = 0.15, longest = 3.0;

  /// How lit players stay while a note of theirs sounds past its fade.
  static const held = 0.2;

  final PlayerNotes _notes;
  final ScoreTimeline? _timeline;

  /// Each link's notes in the performance's seconds, once asked for (null: it has none).
  final _events = <PlayerLink, _Events?>{};

  /// How far a note played at dynamic [level] (0–1, [ScoreDynamics]) swells its players.
  static double strengthOf(double level) => 0.15 + 0.85 * level.clamp(0.0, 1.0);

  /// The notes of [key] as the timeline plays them, pass by pass.
  _Events? _played(String key) {
    final spans = _notes._spans[key], timeline = _timeline;
    if (spans == null || timeline == null) return null;
    final passes = timeline.passes, starts = spans.starts;
    // A pass plays the notes that start in it.
    int firstFrom(double quarter) {
      var lo = 0, hi = starts.length;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (starts[mid] < quarter) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      return lo;
    }

    final from = [for (final p in passes) firstFrom(p.start - 1e-9)], to = [for (final p in passes) firstFrom(p.end - 1e-9)];
    var count = 0;
    for (var k = 0; k < passes.length; k++) {
      count += math.max(0, to[k] - from[k]);
    }
    final onsets = Float64List(count), lengths = Float64List(count), strengths = Float64List(count);
    var n = 0, inOrder = true;
    for (final (k, p) in passes.indexed) {
      for (var i = from[k]; i < to[k]; i++) {
        final on = timeline.secondsAtQuarter(starts[i], pass: k);
        if (n > 0 && on < onsets[n - 1]) inOrder = false;
        onsets[n] = on;
        lengths[n] = math.max(0.0, timeline.secondsAtQuarter(math.min(spans.ends[i], p.end), pass: k) - on);
        strengths[n++] = spans.strengths[i];
      }
    }
    return _Events.of(onsets, lengths, strengths, inOrder: inOrder);
  }

  /// How swollen players playing [link] are at [seconds]: 0 at rest, 1 at a note's start.
  double level(PlayerLink? link, double seconds) {
    if (link == null || _timeline == null) return 0;
    var events = _events[link];
    if (events == null && !_events.containsKey(link)) events = _events[link] = _played(link.key);
    return events?.level(seconds) ?? 0;
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

/// One instrument's (or staff's) notes in a performance: onsets in order, their lengths and
/// strengths, and the latest end of any note up to each.
class _Events {
  _Events(this.onsets, this.lengths, this.strengths, this.ends);
  final Float64List onsets, lengths, strengths, ends;

  /// [onsets] with their [lengths] and [strengths] (the lists are used, and changed); sorted
  /// first unless [inOrder].
  factory _Events.of(Float64List onsets, Float64List lengths, Float64List strengths, {required bool inOrder}) {
    if (!inOrder) {
      // A performance whose passes aren't played one after another.
      final order = [for (var i = 0; i < onsets.length; i++) i]..sort((a, b) => onsets[a].compareTo(onsets[b]));
      Float64List by(Float64List list) => Float64List.fromList([for (final i in order) list[i]]);
      (onsets, lengths, strengths) = (by(onsets), by(lengths), by(strengths));
    }
    // Notes that start together are one onset: its longest, as loud as its loudest.
    var n = 0;
    for (var i = 0; i < onsets.length; i++) {
      if (n > 0 && onsets[i] - onsets[n - 1] < 1e-4) {
        lengths[n - 1] = math.max(lengths[n - 1], lengths[i]);
        strengths[n - 1] = math.max(strengths[n - 1], strengths[i]);
        continue;
      }
      onsets[n] = onsets[i];
      lengths[n] = lengths[i];
      strengths[n++] = strengths[i];
    }
    final ends = Float64List(n);
    var end = double.negativeInfinity;
    for (var i = 0; i < n; i++) {
      end = math.max(end, onsets[i] + lengths[i]);
      ends[i] = end;
    }
    return _Events(Float64List.sublistView(onsets, 0, n), Float64List.sublistView(lengths, 0, n), Float64List.sublistView(strengths, 0, n), ends);
  }

  double level(double t) {
    // The last onset at or before t.
    final last = lastAtOrBefore(onsets.length, t, (i) => onsets[i]);
    if (last < 0) return 0;
    var level = 0.0;
    const window = PlayerPulses.attack + PlayerPulses.longest;
    for (var i = last; i >= 0 && t - onsets[i] < window; i--) {
      level = math.max(level, PlayerPulses.envelope(t - onsets[i], lengths[i]) * strengths[i]);
    }
    // Held: a little lit while a note sounds, as loud as the last begun.
    if (ends[last] > t) level = math.max(level, PlayerPulses.held * strengths[last]);
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

class _Seating {
  _Seating(this.parts, this.preset, this.nameOf);
  final List<ScorePart> parts;
  final SeatingPreset preset;
  final String Function(ScorePart) nameOf;

  /// A dot's width, and the gap between sections side by side, in seats.
  static const _dot = 0.62, _gap = 0.9;

  /// How many seats an em of a name takes across: a guess, then what the first fitting found.
  double _perEm = 0.47;

  /// About how many seats a name of [name] takes across (a very long one counted as 28 letters).
  double _nameWidth(String name) => math.min(SeatPlan.labelEms(name), 28 * 0.58) * _perEm + 0.5;

  PlayerMap map() {
    final groups = _groups();
    if (groups.isEmpty) return const PlayerMap();
    List<(_Draft, SeatPlan)> placed() => preset == SeatingPreset.ensemble ? _bow(groups) : _orchestra(groups);
    // Seated again with names as wide as the scale it was fitted at makes them.
    final first = _fitted(placed());
    _perEm = PlayerMap.labelSize / (first.sections.first.size / _dot);
    return _fitted(placed());
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

  /// What [p] is: by its name (and its abbreviation), an instrument's own name before a word
  /// several share ("Contrabass Clarinet" a clarinet, "Bass Trombone" a trombone, "Tubular Bells"
  /// no tuba), else by its sound (a name in a language these patterns don't know), else its family.
  _Role _role(ScorePart p, bool choir) {
    final name = '${nameOf(p)} ${p.name} ${p.abbreviation}'.toLowerCase(), sound = (p.sound ?? '').toLowerCase();
    bool has(String pattern) => RegExp(pattern).hasMatch(name);
    bool sounds(String ids) => RegExp('^(?:$ids)').hasMatch(sound);
    if (has(r'\bsolo\b|soloist')) return _Role.solo;
    if (sound.startsWith('strings.cello') || has(r'cello|\bvc\b|\bvlc\b')) return _Role.cello;
    if (sound.startsWith('strings.viola') || has(r'viola|\bvla\b|\bva\b|bratsche')) return _Role.viola;
    if (sound.startsWith('strings.contrabass')) return _Role.bass;
    if (sound.startsWith('strings.violin') || has(r'violin|\bvln?\b|violine|\bvl\b')) {
      final second = has(r'(violin|vln?|violine|vl)\.?\s*(2|ii)\b') || has(r'\bsecond\b|\b2nd\b');
      final first = has(r'(violin|vln?|violine|vl)\.?\s*(1|i)\b') || has(r'\bfirst\b|\b1st\b');
      return second && !first ? _Role.violin2 : _Role.violin1;
    }
    if (has(r'harp(?!sichord)|\bhp\b|\bhrp\b|\barpa\b|harfe')) return _Role.harp;
    if (sound.startsWith('keyboard.') || has(r'piano|\bpno\b|\bpf\b|klavier|celest|organ|harpsichord|cembalo|clavi|keyboard|synth')) {
      return _Role.keyboard;
    }
    if (has(r'piccolo(?!\s+(trumpet|trompete|tromba))|flute|\bfl\b|\bpicc?\b|flauto|flöte')) return _Role.flute;
    if (has(r'oboe|cor anglais|english horn|englisch ?horn|corno inglese|\bob\b|\bc\.?a\.?\b')) return _Role.oboe;
    if (has(r'clarinet|basset|\bcl\b|klarinette')) return _Role.clarinet;
    if (has(r'bassoon|\bbsn\b|\bfg\b|fagott')) return _Role.bassoon;
    if (has(r'sax(?!horn)')) return _Role.saxophone;
    if (has(r'(?<!flugel)(?<!flügel)horn|\bhn\b|\bcor\b|corno')) return _Role.horn;
    if (has(r'trumpet|cornet|\btpt?\b|\btr\b|tromba|trompete|fl[uü]gel')) return _Role.trumpet;
    if (has(r'trombone|\btbn?\b|posaune|euphonium')) return _Role.trombone;
    if (has(r'\btub(a|as|en)\b|\btba\b|cimbasso|sousaphone')) return _Role.tuba;
    // After the winds and brass: theirs of that name are no string basses ("Piccolo in D♭" neither).
    if (has(r'contrabass|double bass|kontrabass|\bcb\b|(?<!\bin\s)\bd\.?b\.?\b|basses')) return _Role.bass;
    if (has(r'timpani|\btimp|pauken')) return _Role.timpani;
    if (p.isUnpitchedPercussion ||
        has(r'percussion|drum|cymbal|triangle|glock|xylo|vibra|marimba|bells|tam-?tam|gong|snare|tambourine|perc\b|chimes|wood ?block')) {
      return _Role.percussion;
    }
    if (sound.startsWith('voice.') || has(r'soprano|\balto\b|tenor|baritone|choir|chorus|voice|\bsatb\b|mezzo') || (choir && has(r'\bbass\b'))) {
      return _Role.voice;
    }
    if (has(r'\bbass\b')) return _Role.bass;
    if (sounds(r'wind\.flutes')) return _Role.flute;
    if (sounds(r'wind\.reed\.(oboe|english-horn|heckelphone)')) return _Role.oboe;
    if (sounds(r'wind\.reed\.(clarinet|basset-horn)')) return _Role.clarinet;
    if (sounds(r'wind\.reed\.(bassoon|contrabassoon)')) return _Role.bassoon;
    if (sounds(r'wind\.reed\.saxophone')) return _Role.saxophone;
    if (sounds(r'brass\.(french-horn|horn|wagner-tuba)')) return _Role.horn;
    if (sounds(r'brass\.(trumpet|cornet|flugelhorn|bugle)')) return _Role.trumpet;
    if (sounds(r'brass\.(trombone|euphonium|baritone)')) return _Role.trombone;
    if (sounds(r'brass\.(tuba|sousaphone|helicon)')) return _Role.tuba;
    if (sounds(r'drum\.timpani')) return _Role.timpani;
    if (sounds(r'pluck\.harp')) return _Role.harp;
    return switch (p.family) {
      InstrumentFamily.woodwinds => _Role.flute,
      InstrumentFamily.brass => _Role.horn,
      InstrumentFamily.percussion => _Role.percussion,
      InstrumentFamily.keyboards => _Role.keyboard,
      InstrumentFamily.voices => _Role.voice,
      // A guitar, a mandolin: no section of violins.
      InstrumentFamily.strings => sound.startsWith('pluck.') ? _Role.other : _Role.violin1,
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
  // Planned in seats (a seat's pitch about 1), the conductor at (0, 0), the players behind
  // (y < 0), then fitted to the stage.

  static SeatPlan _plan(SeatPlanKind kind, {double x = 0, double y = 0, double radius = 0, double from = 0, double to = math.pi, double mid = math.pi / 2, int? across, bool behind = false}) =>
      SeatPlan(kind, x: x, y: y, unitX: 1, unitY: 1, radius: radius, from: from, to: to, mid: mid, across: across, behind: behind);

  /// How far from the conductor [plan]'s [count] seats reach.
  static double _reach(SeatPlan plan, int count) =>
      plan.places(count).fold(0.0, (r, p) => math.max(r, math.sqrt(math.pow(plan.x + p.x, 2) + math.pow(plan.y + p.y, 2))));

  List<(_Draft, SeatPlan)> _orchestra(List<_Group> groups) {
    final out = <(_Draft, SeatPlan)>[];
    void add(_Group g, SeatPlan plan) => out.add((_Draft(g.name, _colorOf(g.role), g.link, g.seats), plan));
    List<_Group> of(Set<_Role> roles) => [for (final g in groups) if (roles.contains(g.role)) g];
    final european = preset == SeatingPreset.european;
    const edge = 0.03 * math.pi;

    // The strings: a fan around the conductor two or three rows deep, in sectors as wide as their
    // players, each name just inside its front row.
    final front = of({_Role.violin1, _Role.violin2, _Role.viola, _Role.cello});
    final order = european
        ? const [_Role.violin1, _Role.cello, _Role.viola, _Role.violin2]
        : const [_Role.violin1, _Role.violin2, _Role.viola, _Role.cello];
    front.sort((a, b) => order.indexOf(a.role).compareTo(order.indexOf(b.role)));
    final total = front.fold(0, (n, g) => n + g.seats.length);
    const spread = math.pi - 2 * edge;
    final r0 = math.max(3.6, total * SeatPlan.ringPitch / (2.6 * spread) - 0.8);
    var angle = edge, back = front.isEmpty ? 1.5 : r0;
    for (final g in front) {
      final width = spread * g.seats.length / total, plan = _plan(SeatPlanKind.sector, radius: r0, from: angle, to: angle + width);
      add(g, plan);
      back = math.max(back, _reach(plan, g.seats.length));
      angle += width;
    }

    // At the sides, just outside the fan: the basses behind the cellos (the right; the left in a
    // European seating), the harp and keyboards on the other side; their names beyond them.
    final sideR = back + 1.1;
    var sides = 0.0;
    for (final (k, list) in [of({_Role.bass}), of({_Role.harp, _Role.keyboard})].indexed) {
      final right = (k == 0) != european;
      var a = edge;
      for (final g in list) {
        final width = math.max(1.6, (g.seats.length / 2 + 0.5) * SeatPlan.ringPitch) / sideR;
        final (from, to) = right ? (math.pi - a - width, math.pi - a) : (a, a + width);
        add(g, _plan(SeatPlanKind.sector, radius: sideR, from: from, to: to, behind: true));
        a += width + 0.25 / sideR;
      }
      sides = math.max(sides, a - edge);
    }

    // Rows behind, gently curved (about a point in front of the conductor), each a few sections
    // side by side, centred, pushed back where their ends would meet what is at the sides; each
    // name in front of its section.
    var r = back + 1.8;
    final flat = back * 0.9, sideAngle = edge + sides + 0.04 * math.pi;
    final sideX = sides == 0 ? double.infinity : sideR * math.cos(sideAngle) - 0.6, sideTop = -(sideR + 2.4) * math.sin(sideAngle);
    void row(List<_Group> sections, {int Function(int count)? across, bool behind = false}) {
      if (sections.isEmpty) return;
      final widths = [
        for (final g in sections) math.max((across?.call(g.seats.length) ?? g.seats.length) * SeatPlan.pitch, _nameWidth(g.name)),
      ];
      final width = widths.fold(0.0, (a, b) => a + b) + _gap * (sections.length - 1);
      for (var k = 0; k < 60; k++) {
        final radius = r + flat, half = math.min(0.48 * math.pi, width / radius / 2);
        if (radius * math.sin(half) <= sideX || flat - radius * math.cos(half) < sideTop) break;
        r += 0.5;
      }
      final radius = r + flat;
      var t = math.pi / 2 - width / radius / 2, deepest = 0;
      for (final (k, g) in sections.indexed) {
        final n = across?.call(g.seats.length);
        final plan = _plan(SeatPlanKind.bow, y: flat, radius: radius, mid: t + widths[k] / radius / 2, across: n, behind: behind);
        add(g, plan);
        deepest = math.max(deepest, plan.places(g.seats.length).last.row);
        t += (widths[k] + _gap) / radius;
      }
      r += deepest * SeatPlan.ringGap + 2.4;
    }

    // The woodwinds in two rows: flutes and oboes, clarinets and bassoons (saxophones after them);
    // the brass behind (horns at the left), timpani and percussion behind them, what else there
    // is beside them; the choir on risers at the back, its names over it.
    row(of({_Role.flute, _Role.oboe}));
    row(of({_Role.clarinet, _Role.bassoon, _Role.saxophone}));
    row(of({_Role.horn, _Role.trumpet, _Role.trombone, _Role.tuba}));
    row([...of({_Role.timpani, _Role.percussion}), ...of({_Role.other})]);
    row(of({_Role.voice}), across: (n) => n >= 6 ? (n / 2).ceil() : n, behind: true);

    // Soloists at the front, by the conductor, side by side.
    final solos = of({_Role.solo});
    if (solos.isNotEmpty) {
      final widths = [for (final g in solos) math.max(g.seats.length * SeatPlan.pitch, _nameWidth(g.name))];
      var x = -(widths.fold(0.0, (a, b) => a + b) + _gap * (solos.length - 1)) / 2;
      for (final (k, g) in solos.indexed) {
        add(g, _plan(SeatPlanKind.rows, x: x + widths[k] / 2, y: 1.0));
        x += widths[k] + _gap;
      }
    }
    return out;
  }

  /// Every section on bows facing the front, in the score's order, the front bow first; each
  /// takes as much of its bow as its players or its name needs, its name in front of it.
  List<(_Draft, SeatPlan)> _bow(List<_Group> groups) {
    const between = 2.4, spread = 0.84 * math.pi;
    final widths = [for (final g in groups) math.max(g.seats.length * SeatPlan.pitch, _nameWidth(g.name))];
    final total = widths.fold(0.0, (a, b) => a + b) + _gap * (groups.length - 1);
    // As many bows as hold them, each from a quarter of the stage's height back.
    final bows = (total / 17).ceil().clamp(1, 6);
    final r0 = math.max(2.6, (total / spread - between * bows * (bows - 1) / 2) / bows);
    final out = <(_Draft, SeatPlan)>[];
    var next = 0;
    // Each bow as much of the whole as its length is of theirs, so each spans about as wide.
    final lengths = [for (var b = 0; b < bows; b++) r0 + b * between], all = lengths.fold(0.0, (a, b) => a + b);
    for (var b = 0; b < bows && next < groups.length; b++) {
      final r = lengths[b], share = total * r / all;
      final these = <int>[];
      var used = 0.0;
      while (next < groups.length && (b == bows - 1 || these.isEmpty || used + _gap + widths[next] / 2 <= share)) {
        if (these.isNotEmpty) used += _gap;
        these.add(next);
        used += widths[next++];
      }
      // Centred about the middle of the back, as many radians as its sections take.
      var t = math.pi / 2 - used / r / 2;
      for (final k in these) {
        final g = groups[k];
        out.add((_Draft(g.name, _colorOf(g.role), g.link, g.seats), _plan(SeatPlanKind.bow, radius: r, mid: t + widths[k] / r / 2)));
        t += (widths[k] + _gap) / r;
      }
    }
    return out;
  }

  /// The seating scaled to fill the stage, names and all, a margin round it: wider than it is
  /// planned, up to [stretch] times, where the stage is (the dots stay round), its dots never
  /// bigger than a few players' worth; then names that would overlap moved apart.
  PlayerMap _fitted(List<(_Draft, SeatPlan)> placed) {
    const aspect = PlayerMap.defaultAspect, margin = 0.06, stretch = 1.6, biggest = 0.07;
    var x0 = double.infinity, x1 = double.negativeInfinity, y0 = double.infinity, y1 = double.negativeInfinity;
    for (final (d, plan) in placed) {
      for (final p in plan.places(d.seats.length)) {
        x0 = math.min(x0, plan.x + p.x - 0.5);
        x1 = math.max(x1, plan.x + p.x + 0.5);
        y0 = math.min(y0, plan.y + p.y - 0.5);
        y1 = math.max(y1, plan.y + p.y + 0.5);
      }
    }
    final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
    var kx = (1 - 2 * margin) * aspect / math.max(1e-6, x1 - x0), ky = (1 - 2 * margin) / math.max(1e-6, y1 - y0);
    kx = math.min(kx, ky * stretch);
    ky = math.min(ky, kx * stretch);
    List<MapSection> at(double kx, double ky) {
      final k = math.min(kx, ky), size = (_dot * k).clamp(MapSection.minSize, biggest);
      return [
        for (final (d, plan) in placed)
          () {
            final stage = SeatPlan(plan.kind,
                x: 0.5 + (plan.x - cx) * kx / aspect,
                y: 0.5 + (plan.y - cy) * ky,
                unitX: kx / aspect,
                unitY: ky,
                radius: plan.radius,
                from: plan.from,
                to: plan.to,
                mid: plan.mid,
                across: plan.across,
                behind: plan.behind);
            final seats = [for (final l in d.seats) MapSeat(0, 0, link: l)];
            return MapSection(name: d.name, color: d.color, size: size, labelX: 0, labelY: 0, link: d.link, seats: seats, auto: stage)
                .planned(stage, d.seats.length, aspect: aspect);
          }(),
      ];
    }

    // Its names are as big at any scale: smaller until they too are on the stage.
    var sections = at(kx, ky);
    for (var round = 0; round < 6; round++) {
      var a0 = double.infinity, a1 = double.negativeInfinity, b0 = double.infinity, b1 = double.negativeInfinity;
      for (final s in sections) {
        final w = SeatPlan.labelHalfWidth(s.name, aspect), h = SeatPlan.labelHalfHeight;
        for (final (x, y, hw, hh) in [for (final p in s.seats) (p.x, p.y, s.size / 2 / aspect, s.size / 2), (s.labelX, s.labelY, w, h)]) {
          a0 = math.min(a0, x - hw);
          a1 = math.max(a1, x + hw);
          b0 = math.min(b0, y - hh);
          b1 = math.max(b1, y + hh);
        }
      }
      final f = math.min((1 - 2 * margin) / (a1 - a0), (1 - 2 * margin) / (b1 - b0));
      // A few players aren't blown up to fill the stage.
      final most = biggest / _dot / math.min(kx, ky);
      final g = math.min(f, most);
      if ((g - 1).abs() < 0.01) {
        sections = [for (final s in sections) s.moved(0.5 - (a0 + a1) / 2, 0.5 - (b0 + b1) / 2)];
        break;
      }
      kx *= g;
      ky *= g;
      sections = at(kx, ky);
      if (round == 5) {
        sections = [for (final s in sections) s.moved(0.5 - (a0 + a1) / 2, 0.5 - (b0 + b1) / 2)];
      }
    }

    // Names that would overlap moved apart sideways, the shorter way.
    final labels = [for (final s in sections) (x: s.labelX, y: s.labelY)];
    final halves = [for (final s in sections) (w: SeatPlan.labelHalfWidth(s.name, aspect), h: SeatPlan.labelHalfHeight)];
    for (var round = 0; round < 60; round++) {
      var moved = false;
      for (var a = 0; a < labels.length; a++) {
        for (var b = a + 1; b < labels.length; b++) {
          final dx = labels[b].x - labels[a].x, dy = labels[b].y - labels[a].y;
          final ox = halves[a].w + halves[b].w - dx.abs(), oy = halves[a].h + halves[b].h - dy.abs();
          if (ox <= 0 || oy <= 0) continue;
          moved = true;
          final push = ox / 2 + 0.002, sign = dx < 0 ? -1.0 : 1.0;
          labels[a] = (x: labels[a].x - sign * push, y: labels[a].y);
          labels[b] = (x: labels[b].x + sign * push, y: labels[b].y);
        }
      }
      if (!moved) break;
    }
    return PlayerMap(sections: List.unmodifiable([for (final (i, s) in sections.indexed) s.copyWith(labelX: labels[i].x, labelY: labels[i].y)]));
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

/// A place on the stage: a little past its edges is allowed (a seat dragged off them); one
/// further off is brought back to there, not refused (a project must open whatever was dragged).
double _place(Object? value, String where) => _number(value, where).clamp(-1.0, 2.0);

List<double> _numbers(Object? value, String where, int count) {
  if (value is! List || value.length != count) throw FormatException('$where is not $count numbers.');
  return [for (final v in value) _place(v, where)];
}

double _round(double v) => (v * 10000).roundToDouble() / 10000;

/// A name as compared: lower case, spaces and dots alike.
String _plain(String name) => name.toLowerCase().replaceAll(RegExp(r'[\s.]+'), ' ').trim();
