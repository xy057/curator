import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'engraving.dart' show ClefShape;
import 'spacers.dart' show SpacerKey;

/// A clef an instrument of a PDF score is read in: the frozen zone draws it, and the score
/// written for the PDF ([PdfScoreLayout.musicXML]) has it.
enum PdfClef {
  treble('G', 2, 0, ClefShape.g),
  treble8vb('G', 2, -1, ClefShape.g),
  alto('C', 3, 0, ClefShape.c),
  tenor('C', 4, 0, ClefShape.c),
  bass('F', 4, 0, ClefShape.f),
  percussion('percussion', 3, 0, ClefShape.percussion);

  const PdfClef(this.sign, this.line, this.octave, this.shape);
  final String sign;
  final int line;
  final int octave;
  final ClefShape shape;

  static PdfClef named(String? name) => values.where((c) => c.name == name).firstOrNull ?? treble;

  /// The pitch on its middle line, MusicXML's step and octave: what a bar played is written as.
  (String, int) get middle => switch (this) {
        treble => ('B', 4),
        treble8vb => ('B', 3),
        alto => ('C', 4),
        tenor => ('A', 3),
        bass => ('D', 3),
        percussion => ('B', 4),
      };

  /// The clef an instrument of this name is usually written in.
  static PdfClef forName(String name) {
    final n = name.toLowerCase();
    bool has(List<String> words) => words.any(n.contains);
    if (has(['viola', 'vla', 'bratsche', 'alto '])) return n.contains('sax') ? treble : alto;
    if (has(['cello', 'vc', 'violoncell', 'bass', 'basso', 'contrab', 'fagott', 'bassoon', 'fg', 'trombon', 'tuba', 'timpan', 'pauk', 'bari'])) {
      return n.contains('clar') || n.contains('sax') ? treble : bass;
    }
    if (has(['tenor']) && !has(['sax', 'horn'])) return treble8vb;
    if (has(['drum', 'percus', 'cymbal', 'tamb', 'triang'])) return percussion;
    return treble;
  }
}

/// One instrument of a PDF score: a part of the score written for it ([PdfScoreLayout.musicXML]).
@immutable
class PdfInstrument {
  const PdfInstrument(
      {required this.id,
      required this.name,
      this.abbreviation = '',
      this.clef = PdfClef.treble,
      this.staves = 1,
      this.key = SpacerKey.c,
      this.divisi = 1});

  /// Its part's id (`P1`…), kept while it is renamed or moved.
  final String id;
  final String name;
  final String abbreviation;
  final PdfClef clef;

  /// How many staves it is printed on (a piano's two).
  final int staves;

  /// Its transposition: the key signature it is written in, from the concert key.
  final SpacerKey key;

  /// How many staves a section of one staff divides onto at most (divisi): each after its first
  /// a player of its own ([players]), its staves those that say so ([PdfStaff.staff]), silent
  /// where the section plays as one.
  final int divisi;

  /// Its players, each a part of the score: itself, and its divisi's further staves (`P6d2`…,
  /// "Violin I 2").
  List<({String id, String name, String abbreviation, int division})> get players => [
        (id: id, name: name, abbreviation: abbreviation, division: 1),
        if (staves == 1)
          for (var k = 2; k <= divisi; k++)
            (id: '${id}d$k', name: '$name $k', abbreviation: abbreviation.isEmpty ? '' : '$abbreviation $k', division: k),
      ];

  PdfInstrument copyWith({String? name, String? abbreviation, PdfClef? clef, int? staves, SpacerKey? key, int? divisi}) => PdfInstrument(
      id: id,
      name: name ?? this.name,
      abbreviation: abbreviation ?? this.abbreviation,
      clef: clef ?? this.clef,
      staves: staves ?? this.staves,
      key: key ?? this.key,
      divisi: divisi ?? this.divisi);

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'abbreviation': abbreviation,
        'clef': clef.name,
        'staves': staves,
        'key': key.name,
        if (divisi > 1) 'divisi': divisi,
      };

  static PdfInstrument fromJson(Map<String, Object?> json) => PdfInstrument(
        id: _string(json, 'id'),
        name: _string(json, 'name'),
        abbreviation: json['abbreviation'] as String? ?? '',
        clef: PdfClef.named(json['clef'] as String?),
        staves: ((json['staves'] as num?)?.toInt() ?? 1).clamp(1, 4),
        key: SpacerKey.named(json['key'] as String?),
        divisi: ((json['divisi'] as num?)?.toInt() ?? 1).clamp(1, 4),
      );

  @override
  bool operator ==(Object other) =>
      other is PdfInstrument &&
      other.divisi == divisi &&
      other.id == id &&
      other.name == name &&
      other.abbreviation == abbreviation &&
      other.clef == clef &&
      other.staves == staves &&
      other.key == key;

  @override
  int get hashCode => Object.hash(id, name, abbreviation, clef, staves, key, divisi);
}

/// A staff as printed in one system: where its lines are (points, from the page's top) and whose
/// it is.
@immutable
class PdfStaff {
  const PdfStaff({required this.top, required this.space, this.lines = 5, this.part, this.staff = 1});

  /// The top line's y, points from the page's top.
  final double top;

  /// The distance between two lines, points.
  final double space;
  final int lines;

  /// The instrument it is ([PdfInstrument.id]); null: no one's (left out of the score).
  final String? part;

  /// Which of the instrument's staves it is, from 1; of a one-staff instrument's, which of its
  /// divisi ([PdfInstrument.divisi]).
  final int staff;

  double get bottom => top + (math.max(1, lines) - 1) * space;
  double get middle => (top + bottom) / 2;

  PdfStaff copyWith({double? top, double? space, int? lines, String? Function()? part, int? staff}) => PdfStaff(
      top: top ?? this.top,
      space: space ?? this.space,
      lines: lines ?? this.lines,
      part: part == null ? this.part : part(),
      staff: staff ?? this.staff);

  Map<String, Object?> toJson() => {'top': _round(top), 'space': _round(space), 'lines': lines, 'part': part, 'staff': staff};

  static PdfStaff fromJson(Map<String, Object?> json) => PdfStaff(
        top: _number(json, 'top'),
        space: _positive(json, 'space'),
        lines: ((json['lines'] as num?)?.toInt() ?? 5).clamp(1, 6),
        part: json['part'] as String?,
        staff: ((json['staff'] as num?)?.toInt() ?? 1).clamp(1, 4),
      );

  @override
  bool operator ==(Object other) =>
      other is PdfStaff && other.top == top && other.space == space && other.lines == lines && other.part == part && other.staff == staff;

  @override
  int get hashCode => Object.hash(top, space, lines, part, staff);
}

/// How a barline is drawn: what it means for the score's form.
enum PdfBarlineKind {
  normal,
  double,
  end,
  repeatStart,
  repeatEnd,
  repeatBoth;

  static PdfBarlineKind named(String? name) => values.where((k) => k.name == name).firstOrNull ?? normal;
}

@immutable
class PdfBarline {
  const PdfBarline(this.x, [this.kind = PdfBarlineKind.normal]);

  /// Points from the page's left.
  final double x;
  final PdfBarlineKind kind;

  PdfBarline copyWith({double? x, PdfBarlineKind? kind}) => PdfBarline(x ?? this.x, kind ?? this.kind);

  @override
  bool operator ==(Object other) => other is PdfBarline && other.x == x && other.kind == kind;

  @override
  int get hashCode => Object.hash(x, kind);
}

/// How far one staff's ink reaches in one bar of a system, staff spaces above its top line and
/// below its bottom one, and whether anything is played there (more than a rest).
typedef PdfInk = ({double above, double below, bool played});

/// One system of the PDF: its staves, where its music starts and ends, and its barlines.
@immutable
class PdfSystem {
  const PdfSystem({
    required this.page,
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
    required this.staves,
    this.cuts = const [],
    this.barlines = const [],
    this.ink,
  });

  final int page;

  /// What may belong to it, points from the page's top: nothing above [top] or below [bottom]
  /// is in any staff's part.
  final double top, bottom;

  /// Where its music starts (past the clefs and key signatures at its start) and ends (its
  /// staves' right end), points from the page's left.
  final double left, right;

  /// Top to bottom.
  final List<PdfStaff> staves;

  /// Between each staff and the next, where one's part ends and the next one's begins (points
  /// from the page's top); [staves] − 1 of them. What crosses a cut goes with the staff where
  /// most of it is.
  final List<double> cuts;

  /// Left to right, past [left]; the last at [right] unless the bar goes on in the next system.
  final List<PdfBarline> barlines;

  /// Per staff, per bar ([segments]): how far its ink reaches. Null until measured.
  final List<List<PdfInk>>? ink;

  /// The staff space its bars are measured in: its staves' middle one.
  double get space {
    if (staves.isEmpty) return 6;
    final spaces = [for (final s in staves) s.space]..sort();
    return spaces[spaces.length ~/ 2];
  }

  /// Its bars' left and right ends, left to right: between [left], the barlines and [right].
  List<(double, double)> get segments {
    final out = <(double, double)>[];
    var from = left;
    for (final b in barlines) {
      if (b.x <= from + 0.5) continue;
      out.add((from, math.min(b.x, right)));
      from = b.x;
    }
    if (right - from > space) out.add((from, right));
    return out;
  }

  /// Whether its last bar goes on in the next system (no barline at its end).
  bool get continues => barlines.isEmpty || right - barlines.last.x > space;

  /// The cut between staff [i] and the one below, or the middle between them when none is set.
  double cutAfter(int i) => i < cuts.length ? cuts[i] : (staves[i].bottom + staves[i + 1].top) / 2;

  /// The band of staff [i]: from the cut above it (or [top]) to the cut below it (or [bottom]).
  (double, double) bandOf(int i) => (i == 0 ? top : cutAfter(i - 1), i == staves.length - 1 ? bottom : cutAfter(i));

  PdfSystem copyWith({
    double? top,
    double? bottom,
    double? left,
    double? right,
    List<PdfStaff>? staves,
    List<double>? cuts,
    List<PdfBarline>? barlines,
    List<List<PdfInk>>? Function()? ink,
  }) =>
      PdfSystem(
        page: page,
        top: top ?? this.top,
        bottom: bottom ?? this.bottom,
        left: left ?? this.left,
        right: right ?? this.right,
        staves: staves ?? this.staves,
        cuts: cuts ?? this.cuts,
        barlines: barlines ?? this.barlines,
        ink: ink == null ? this.ink : ink(),
      );

  Map<String, Object?> toJson() => {
        'page': page,
        'top': _round(top),
        'bottom': _round(bottom),
        'left': _round(left),
        'right': _round(right),
        'staves': [for (final s in staves) s.toJson()],
        'cuts': [for (final c in cuts) _round(c)],
        'barlines': [
          for (final b in barlines) [_round(b.x), b.kind.name],
        ],
        if (ink case final ink?)
          'ink': [
            for (final staff in ink)
              [
                for (final i in staff) [_round(i.above), _round(i.below), i.played ? 1 : 0],
              ],
          ],
      };

  static PdfSystem fromJson(Map<String, Object?> json) {
    final staves = [for (final s in _list(json, 'staves')) PdfStaff.fromJson(_map(s, 'staves'))];
    final barlines = [
      for (final b in _list(json, 'barlines'))
        if (b case [final num x, final String kind]) PdfBarline(x.toDouble(), PdfBarlineKind.named(kind)) else throw _bad('barlines'),
    ]..sort((a, b) => a.x.compareTo(b.x));
    final ink = json['ink'] == null
        ? null
        : [
            for (final staff in _list(json, 'ink'))
              [
                for (final i in staff is List ? staff : throw _bad('ink'))
                  if (i case [final num above, final num below, final num played])
                    (above: above.toDouble(), below: below.toDouble(), played: played != 0)
                  else
                    throw _bad('ink'),
              ],
          ];
    return PdfSystem(
      page: (json['page'] as num?)?.toInt() ?? (throw _bad('page')),
      top: _number(json, 'top'),
      bottom: _number(json, 'bottom'),
      left: _number(json, 'left'),
      right: _number(json, 'right'),
      staves: staves,
      cuts: [for (final c in _list(json, 'cuts')) c is num ? c.toDouble() : throw _bad('cuts')],
      barlines: barlines,
      ink: ink != null && ink.length == staves.length ? ink : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PdfSystem &&
      other.page == page &&
      other.top == top &&
      other.bottom == bottom &&
      other.left == left &&
      other.right == right &&
      listEquals(other.staves, staves) &&
      listEquals(other.cuts, cuts) &&
      listEquals(other.barlines, barlines) &&
      _sameInk(other.ink, ink);

  @override
  int get hashCode => Object.hash(page, top, bottom, left, right, Object.hashAll(staves), Object.hashAll(barlines));

  static bool _sameInk(List<List<PdfInk>>? a, List<List<PdfInk>>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!listEquals(a[i], b[i])) return false;
    }
    return true;
  }
}

/// A part of a page left out of every staff (a page number, a stray mark), points.
@immutable
class PdfMask {
  const PdfMask(this.page, this.rect);
  final int page;
  final ui.Rect rect;

  List<Object> toJson() => [page, _round(rect.left), _round(rect.top), _round(rect.right), _round(rect.bottom)];

  static PdfMask fromJson(Object? json) => switch (json) {
        [final num page, final num l, final num t, final num r, final num b] =>
          PdfMask(page.toInt(), ui.Rect.fromLTRB(l.toDouble(), t.toDouble(), r.toDouble(), b.toDouble())),
        _ => throw _bad('masks'),
      };

  @override
  bool operator ==(Object other) => other is PdfMask && other.page == page && other.rect == rect;

  @override
  int get hashCode => Object.hash(page, rect);
}

/// A piece of one bar: a stretch of one system (a bar may run on from one system into the next).
typedef PdfPiece = ({int system, double left, double right});

/// A time signature: "3/4", "6/8", "2+3/8".
@immutable
class PdfMeter {
  const PdfMeter(this.beats, this.unit);

  /// The numerator as written ("2+3").
  final String beats;
  final int unit;

  static const common = PdfMeter('4', 4);

  /// Quarters in a bar.
  double get quarters => beats.split('+').map((b) => int.tryParse(b.trim()) ?? 0).fold(0, (a, b) => a + b) * 4 / unit;

  @override
  String toString() => '$beats/$unit';

  /// "3/4", "2+3/8"; null for anything else.
  static PdfMeter? parse(String text) {
    final m = RegExp(r'^\s*(\d+(?:\s*\+\s*\d+)*)\s*/\s*(1|2|4|8|16|32)\s*$').firstMatch(text);
    if (m == null) return null;
    final meter = PdfMeter(m[1]!.replaceAll(' ', ''), int.parse(m[2]!));
    return meter.quarters > 0 && meter.quarters <= 64 ? meter : null;
  }

  @override
  bool operator ==(Object other) => other is PdfMeter && other.beats == beats && other.unit == unit;

  @override
  int get hashCode => Object.hash(beats, unit);
}

/// How a PDF score is read: its instruments, its systems (staves and barlines, each staff
/// someone's), what is left out, and the meter and key it is in. Its bars run through the systems
/// in order; [musicXML] writes the score the rest of Curator reads (bars, beats, parts, where each
/// plays), while the scene draws the PDF itself ([PdfScoreArt]).
class PdfScoreLayout {
  PdfScoreLayout({
    this.title = '',
    required this.pages,
    this.instruments = const [],
    this.systems = const [],
    this.masks = const [],
    this.meter = PdfMeter.common,
    this.fifths = 0,
    this.meters = const {},
    this.keys = const {},
    this.pickup = 0,
    this.tempo = 100,
  });

  final String title;

  /// Each page's size, points.
  final List<ui.Size> pages;
  final List<PdfInstrument> instruments;

  /// In reading order: page by page, top to bottom.
  final List<PdfSystem> systems;
  final List<PdfMask> masks;

  /// The meter and (concert) key it starts in, and where they change (by bar index).
  final PdfMeter meter;
  final int fifths;
  final Map<int, PdfMeter> meters;
  final Map<int, int> keys;

  /// The first bar's length in quarters when it is an upbeat; 0 when it is whole.
  final double pickup;

  /// Quarters a minute, before a recording sets the tempo.
  final double tempo;

  PdfScoreLayout copyWith({
    String? title,
    List<PdfInstrument>? instruments,
    List<PdfSystem>? systems,
    List<PdfMask>? masks,
    PdfMeter? meter,
    int? fifths,
    Map<int, PdfMeter>? meters,
    Map<int, int>? keys,
    double? pickup,
    double? tempo,
  }) =>
      PdfScoreLayout(
        title: title ?? this.title,
        pages: pages,
        instruments: instruments ?? this.instruments,
        systems: systems ?? this.systems,
        masks: masks ?? this.masks,
        meter: meter ?? this.meter,
        fifths: fifths ?? this.fifths,
        meters: meters ?? this.meters,
        keys: keys ?? this.keys,
        pickup: pickup ?? this.pickup,
        tempo: tempo ?? this.tempo,
      );

  PdfInstrument? instrument(String? id) => instruments.where((i) => i.id == id).firstOrNull;

  /// The part of the score [staff] is printed for ([PdfInstrument.players]): its instrument's, or
  /// one of its divisi's; null: no one's.
  String? partOf(PdfStaff staff) {
    final i = instrument(staff.part);
    if (i == null) return null;
    if (i.staves > 1 || staff.staff <= 1) return i.id;
    return staff.staff <= i.divisi ? '${i.id}d${staff.staff}' : null;
  }

  /// Which of its part's staves [staff] is, from 1.
  int staffInPart(PdfStaff staff) => (instrument(staff.part)?.staves ?? 1) > 1 ? staff.staff : 1;

  /// The instrument a part of the score is ([partOf]), and which of its divisi.
  (PdfInstrument, int)? playerOf(String partId) {
    for (final i in instruments) {
      for (final p in i.players) {
        if (p.id == partId) return (i, p.division);
      }
    }
    return null;
  }

  /// Every bar, in order, as the pieces of systems it is printed in.
  late final List<List<PdfPiece>> bars = () {
    final out = <List<PdfPiece>>[];
    var goesOn = false;
    for (final (s, system) in systems.indexed) {
      final segments = system.segments;
      for (final (i, (left, right)) in segments.indexed) {
        final piece = (system: s, left: left, right: right);
        if (i == 0 && goesOn && out.isNotEmpty) {
          out.last = [...out.last, piece];
        } else {
          out.add([piece]);
        }
      }
      goesOn = segments.isNotEmpty && system.continues;
    }
    return out;
  }();

  /// The bar each system's segments are, by system: segment index → bar index.
  late final List<List<int>> barOfSegment = () {
    final out = [for (final _ in systems) <int>[]];
    for (final (bar, pieces) in bars.indexed) {
      for (final p in pieces) {
        out[p.system].add(bar);
      }
    }
    return out;
  }();

  /// The meter in force in bar [bar].
  PdfMeter meterAt(int bar) {
    var at = -1;
    for (final k in meters.keys) {
      if (k <= bar && k > at) at = k;
    }
    return meters[at] ?? meter;
  }

  /// Bar [bar]'s length in quarters.
  double quartersOf(int bar) => bar == 0 && pickup > 0 ? pickup : meterAt(bar).quarters;

  /// Staves each instrument is printed on in the score written for it, numbered through the score
  /// as MusicXML numbers them (from 1): instrument id → its first staff's number.
  Map<String, int> get firstStaff {
    final out = <String, int>{};
    var n = 1;
    for (final i in instruments) {
      out[i.id] = n;
      n += i.staves;
    }
    return out;
  }

  /// The score written for it: a part per instrument, a bar per bar with its meter, key, clef
  /// and barlines, where each bar an instrument plays in the PDF holds one note on its middle line
  /// and every other a bar's rest. What Curator reads of a score (its bars, beats and form, its
  /// parts and where each plays) comes from it; nothing of it is drawn.
  String musicXML() {
    final out = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">\n'
        '<score-partwise version="4.0">\n');
    if (title.isNotEmpty) out.write('  <work><work-title>${_escape(title)}</work-title></work>\n');
    out.write('  <part-list>\n');
    for (final i in instruments) {
      for (final p in i.players) {
        out.write('    <score-part id="${_escape(p.id)}"><part-name>${_escape(p.name)}</part-name>'
            '${p.abbreviation.isEmpty ? '' : '<part-abbreviation>${_escape(p.abbreviation)}</part-abbreviation>'}</score-part>\n');
      }
    }
    out.write('  </part-list>\n');
    const divisions = 24;
    final played = this.played;
    for (final (instrument, player) in [
      for (final i in instruments)
        for (final p in i.players) (i, p),
    ]) {
      out.write('  <part id="${_escape(player.id)}">\n');
      final playing = played[player.id] ?? const [];
      for (var bar = 0; bar < bars.length; bar++) {
        final implicit = bar == 0 && pickup > 0;
        out.write('    <measure number="${implicit ? 0 : (pickup > 0 ? bar : bar + 1)}"${implicit ? ' implicit="yes"' : ''}>\n');
        final meterChange = bar == 0 || meters.containsKey(bar), keyChange = bar == 0 || keys.containsKey(bar);
        if (meterChange || keyChange) {
          out.write('      <attributes>');
          if (bar == 0) out.write('<divisions>$divisions</divisions>');
          if (keyChange) out.write('<key><fifths>${instrument.key.keyOf(keys[bar] ?? fifths)}</fifths></key>');
          if (meterChange) {
            final m = meterAt(bar);
            out.write('<time><beats>${m.beats}</beats><beat-type>${m.unit}</beat-type></time>');
          }
          if (bar == 0) {
            if (instrument.staves > 1) out.write('<staves>${instrument.staves}</staves>');
            for (var s = 1; s <= instrument.staves; s++) {
              final clef = instrument.staves > 1 && s > 1 ? PdfClef.bass : instrument.clef;
              out.write('<clef${instrument.staves > 1 ? ' number="$s"' : ''}><sign>${clef.sign}</sign><line>${clef.line}</line>'
                  '${clef.octave != 0 ? '<clef-octave-change>${clef.octave}</clef-octave-change>' : ''}</clef>');
            }
          }
          out.write('</attributes>\n');
        }
        if (bar == 0) out.write('      <direction placement="above"><direction-type><words/></direction-type><sound tempo="${_round(tempo)}"/></direction>\n');
        if (_barlineBefore(bar) case final kind?) {
          out.write('      <barline location="left"><bar-style>heavy-light</bar-style>${kind == PdfBarlineKind.repeatStart || kind == PdfBarlineKind.repeatBoth ? '<repeat direction="forward"/>' : ''}</barline>\n');
        }
        final length = (quartersOf(bar) * divisions).round();
        final plays = bar < playing.length && playing[bar];
        for (var s = 1; s <= instrument.staves; s++) {
          if (s > 1) out.write('      <backup><duration>$length</duration></backup>\n');
          final staff = instrument.staves > 1 ? '<staff>$s</staff>' : '';
          if (plays) {
            final clef = instrument.staves > 1 && s > 1 ? PdfClef.bass : instrument.clef;
            final (step, octave) = clef.middle;
            final pitch = clef == PdfClef.percussion
                ? '<unpitched><display-step>$step</display-step><display-octave>$octave</display-octave></unpitched>'
                : '<pitch><step>$step</step><octave>$octave</octave></pitch>';
            out.write('      <note>$pitch<duration>$length</duration><voice>$s</voice>$staff</note>\n');
          } else {
            out.write('      <note><rest measure="yes"/><duration>$length</duration><voice>$s</voice>$staff</note>\n');
          }
        }
        if (_barlineAfter(bar) case final kind?) {
          final style = switch (kind) {
            PdfBarlineKind.end => 'light-heavy',
            PdfBarlineKind.double => 'light-light',
            PdfBarlineKind.repeatEnd || PdfBarlineKind.repeatBoth => 'light-heavy',
            _ => 'regular',
          };
          out.write('      <barline location="right"><bar-style>$style</bar-style>'
              '${kind == PdfBarlineKind.repeatEnd || kind == PdfBarlineKind.repeatBoth ? '<repeat direction="backward"/>' : ''}</barline>\n');
        }
        out.write('    </measure>\n');
      }
      out.write('  </part>\n');
    }
    out.write('</score-partwise>\n');
    return out.toString();
  }

  /// The barline that ends bar [bar] when it isn't a plain one.
  PdfBarlineKind? _barlineAfter(int bar) {
    final last = bars[bar].last, system = systems[last.system];
    for (final b in system.barlines) {
      if ((b.x - last.right).abs() < 0.5) return b.kind == PdfBarlineKind.normal || b.kind == PdfBarlineKind.repeatStart ? null : b.kind;
    }
    return null;
  }

  /// A repeat that starts at bar [bar]: the barline before it says so.
  PdfBarlineKind? _barlineBefore(int bar) {
    if (bar == 0) return null;
    final kind = _barlineAfterAny(bar - 1);
    return kind == PdfBarlineKind.repeatStart || kind == PdfBarlineKind.repeatBoth ? kind : null;
  }

  PdfBarlineKind? _barlineAfterAny(int bar) {
    final last = bars[bar].last, system = systems[last.system];
    for (final b in system.barlines) {
      if ((b.x - last.right).abs() < 0.5) return b.kind;
    }
    return null;
  }

  /// Part id ([PdfInstrument.players]) → for each bar, whether it plays there: printed on a
  /// staff of its own in that bar's system, with more than a rest in it (as measured,
  /// [PdfSystem.ink]; played when not measured).
  Map<String, List<bool>> get played {
    final out = {
      for (final i in instruments)
        for (final p in i.players) p.id: List.filled(bars.length, false),
    };
    for (final (bar, pieces) in bars.indexed) {
      for (final piece in pieces) {
        final system = systems[piece.system];
        final segment = barOfSegment[piece.system].indexOf(bar);
        for (final (s, staff) in system.staves.indexed) {
          final list = out[partOf(staff)];
          if (list == null) continue;
          final ink = system.ink;
          if (ink == null || segment < 0 || segment >= ink[s].length || ink[s][segment].played) list[bar] = true;
        }
      }
    }
    return out;
  }

  Map<String, Object?> toJson() => {
        'title': title,
        'pages': [
          for (final p in pages) [_round(p.width), _round(p.height)],
        ],
        'instruments': [for (final i in instruments) i.toJson()],
        'systems': [for (final s in systems) s.toJson()],
        'masks': [for (final m in masks) m.toJson()],
        'meter': '$meter',
        'fifths': fifths,
        'meters': {for (final MapEntry(:key, :value) in meters.entries) '$key': '$value'},
        'keys': {for (final MapEntry(:key, :value) in keys.entries) '$key': value},
        'pickup': pickup,
        'tempo': tempo,
      };

  /// Reads what [toJson] wrote; throws a [FormatException] naming the damaged field.
  static PdfScoreLayout fromJson(Map<String, Object?> json) {
    final pages = [
      for (final p in _list(json, 'pages'))
        if (p case [final num w, final num h] when w > 0 && h > 0) ui.Size(w.toDouble(), h.toDouble()) else throw _bad('pages'),
    ];
    final systems = [for (final s in _list(json, 'systems')) PdfSystem.fromJson(_map(s, 'systems'))];
    if (systems.any((s) => s.page < 0 || s.page >= pages.length)) throw _bad('systems');
    final instruments = [for (final i in _list(json, 'instruments')) PdfInstrument.fromJson(_map(i, 'instruments'))];
    if (instruments.map((i) => i.id).toSet().length != instruments.length) throw _bad('instruments');
    PdfMeter meter(Object? text) => text is String ? PdfMeter.parse(text) ?? (throw _bad('meter')) : throw _bad('meter');
    return PdfScoreLayout(
      title: json['title'] as String? ?? '',
      pages: pages,
      instruments: instruments,
      systems: systems,
      masks: [for (final m in _list(json, 'masks')) PdfMask.fromJson(m)],
      meter: json['meter'] == null ? PdfMeter.common : meter(json['meter']),
      fifths: ((json['fifths'] as num?)?.toInt() ?? 0).clamp(-7, 7),
      meters: {
        for (final MapEntry(:key, :value) in _map(json['meters'] ?? const {}, 'meters').entries)
          int.tryParse(key) ?? (throw _bad('meters')): meter(value),
      },
      keys: {
        for (final MapEntry(:key, :value) in _map(json['keys'] ?? const {}, 'keys').entries)
          int.tryParse(key) ?? (throw _bad('keys')): value is num ? value.toInt().clamp(-7, 7) : throw _bad('keys'),
      },
      pickup: ((json['pickup'] as num?)?.toDouble() ?? 0).clamp(0, 64),
      tempo: ((json['tempo'] as num?)?.toDouble() ?? 100).clamp(10, 1000),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PdfScoreLayout &&
      other.title == title &&
      listEquals(other.pages, pages) &&
      listEquals(other.instruments, instruments) &&
      listEquals(other.systems, systems) &&
      listEquals(other.masks, masks) &&
      other.meter == meter &&
      other.fifths == fifths &&
      mapEquals(other.meters, meters) &&
      mapEquals(other.keys, keys) &&
      other.pickup == pickup &&
      other.tempo == tempo;

  @override
  int get hashCode => Object.hash(title, Object.hashAll(instruments), Object.hashAll(systems), Object.hashAll(masks), meter, fifths, pickup, tempo);
}

double _round(double v) => (v * 100).roundToDouble() / 100;

String _escape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

FormatException _bad(String what) => FormatException('$what is damaged.');

List<Object?> _list(Map<String, Object?> json, String key) => switch (json[key]) {
      null => const [],
      final List<Object?> list => list,
      _ => throw _bad(key),
    };

Map<String, Object?> _map(Object? value, String key) => value is Map ? value.cast<String, Object?>() : throw _bad(key);

String _string(Map<String, Object?> json, String key) => switch (json[key]) {
      final String s when s.isNotEmpty => s,
      _ => throw _bad(key),
    };

double _number(Map<String, Object?> json, String key) => switch (json[key]) {
      final num n when n.isFinite && n.abs() < 1e6 => n.toDouble(),
      _ => throw _bad(key),
    };

double _positive(Map<String, Object?> json, String key) {
  final n = _number(json, key);
  return n > 0 ? n : throw _bad(key);
}
