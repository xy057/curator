/// The score editor's model: a MusicXML score open for editing, its measures read as voices of
/// events and written again, and the edits the editor makes (notes put in over what was there,
/// as Dorico does, pitches, rhythms, ties, slurs, articulations, dynamics, clefs, keys, time
/// signatures, bars, barlines, lyrics, tuplets), each an Undo step.
library;

import 'dart:math' as math;

import 'package:xml/xml.dart';

// MARK: Time

/// An exact time or length in quarter notes.
class Frac implements Comparable<Frac> {
  factory Frac(int n, [int d = 1]) {
    if (d == 0) throw ArgumentError('Zero denominator');
    if (d < 0) (n, d) = (-n, -d);
    final g = _gcd(n.abs(), d);
    return Frac._(n ~/ g, d ~/ g);
  }
  const Frac._(this.n, this.d);

  static const zero = Frac._(0, 1);
  static const one = Frac._(1, 1);

  final int n, d;

  Frac operator +(Frac o) => Frac(n * o.d + o.n * d, d * o.d);
  Frac operator -(Frac o) => Frac(n * o.d - o.n * d, d * o.d);
  Frac operator *(Frac o) => Frac(n * o.n, d * o.d);
  Frac operator /(Frac o) => Frac(n * o.d, d * o.n);
  Frac operator -() => Frac._(-n, d);
  bool operator <(Frac o) => n * o.d < o.n * d;
  bool operator <=(Frac o) => n * o.d <= o.n * d;
  bool operator >(Frac o) => n * o.d > o.n * d;
  bool operator >=(Frac o) => n * o.d >= o.n * d;
  bool get isZero => n == 0;
  bool get isPositive => n > 0;
  double toDouble() => n / d;

  /// Whether this is a whole number of [o]s.
  bool isMultipleOf(Frac o) => (this / o).d == 1;

  static Frac min(Frac a, Frac b) => a <= b ? a : b;
  static Frac max(Frac a, Frac b) => a >= b ? a : b;

  @override
  int compareTo(Frac o) => (n * o.d).compareTo(o.n * d);
  @override
  bool operator ==(Object other) => other is Frac && other.n == n && other.d == d;
  @override
  int get hashCode => Object.hash(n, d);
  @override
  String toString() => d == 1 ? '$n' : '$n/$d';
}

int _gcd(int a, int b) {
  while (b != 0) {
    (a, b) = (b, a % b);
  }
  return a == 0 ? 1 : a;
}

int _lcm(int a, int b) => a ~/ _gcd(a, b) * b;

// MARK: Rhythm and pitch

/// A written note value, MusicXML's `<type>`.
enum NoteType {
  breve('breve', 8, 1, 0),
  whole('whole', 4, 1, 0),
  half('half', 2, 1, 0),
  quarter('quarter', 1, 1, 0),
  eighth('eighth', 1, 2, 1),
  sixteenth('16th', 1, 4, 2),
  thirtySecond('32nd', 1, 8, 3),
  sixtyFourth('64th', 1, 16, 4),
  hundredTwentyEighth('128th', 1, 32, 5);

  const NoteType(this.type, this._n, this._d, this.beams);

  /// MusicXML's name for it.
  final String type;
  final int _n, _d;

  /// How many beams (or flags) it has.
  final int beams;

  Frac get quarters => Frac(_n, _d);

  /// Dorico's keys: 1 a 128th … 6 a quarter … 9 a breve.
  int get digit => 9 - index;
  static NoteType? ofDigit(int digit) => digit >= 1 && digit <= 9 ? values[9 - digit] : null;

  static NoteType? named(String? type) {
    for (final t in values) {
      if (t.type == type) return t;
    }
    return type == 'long' ? breve : null;
  }
}

/// [actual] notes in the time of [normal] [unit]s: a triplet of eighths is 3:2 eighths.
class Tuplet {
  const Tuplet(this.actual, this.normal, this.unit);
  final int actual, normal;
  final NoteType unit;

  /// How long the whole tuplet lasts.
  Frac get span => unit.quarters * Frac(normal);

  /// Dorico's tuplet popover: `3` (a triplet), `3:2`, `5:4`…, of [unit]s.
  static Tuplet? parse(String text, NoteType unit) {
    final m = RegExp(r'^\s*(\d+)\s*(?::\s*(\d+))?\s*$').firstMatch(text);
    if (m == null) return null;
    // (Digits too many for an int are no number.)
    final actual = int.tryParse(m.group(1)!);
    if (actual == null || actual < 2 || actual > 32) return null;
    final normal = m.group(2) != null ? int.tryParse(m.group(2)!) : _normalFor(actual);
    if (normal == null || normal < 1 || normal > 32 || actual == normal) return null;
    return Tuplet(actual, normal, unit);
  }

  /// The power of two just below [actual] (3 → 2, 5 → 4), or 3 for a duplet.
  static int _normalFor(int actual) {
    if (actual == 2) return 3;
    var p = 1;
    while (p * 2 < actual) {
      p *= 2;
    }
    return p;
  }

  @override
  bool operator ==(Object other) => other is Tuplet && other.actual == actual && other.normal == normal && other.unit == unit;
  @override
  int get hashCode => Object.hash(actual, normal, unit);
  @override
  String toString() => '$actual:$normal';
}

/// A note value with its dots, in a tuplet or not.
class Rhythm {
  const Rhythm(this.type, {this.dots = 0, this.tuplet});
  final NoteType type;
  final int dots;
  final Tuplet? tuplet;

  /// Its length as written, before a tuplet shortens it.
  Frac get plainLength {
    var length = type.quarters, add = type.quarters;
    for (var i = 0; i < dots; i++) {
      add = add * Frac(1, 2);
      length = length + add;
    }
    return length;
  }

  Frac get length => tuplet == null ? plainLength : plainLength * Frac(tuplet!.normal, tuplet!.actual);

  Rhythm withDots(int dots) => Rhythm(type, dots: dots, tuplet: tuplet);

  /// [length] as notes tied one to the next, longest first.
  static List<Rhythm> express(Frac length, {Tuplet? tuplet}) {
    var plain = tuplet == null ? length : length * Frac(tuplet.actual, tuplet.normal);
    final out = <Rhythm>[];
    while (plain.isPositive) {
      Rhythm? best;
      for (final type in NoteType.values) {
        for (var dots = 0; dots <= 2; dots++) {
          final r = Rhythm(type, dots: dots);
          if (r.plainLength <= plain && (best == null || r.plainLength > best.plainLength)) best = r;
        }
      }
      if (best == null) break; // shorter than a 128th: no note can say it
      out.add(Rhythm(best.type, dots: best.dots, tuplet: tuplet));
      plain = plain - best.plainLength;
    }
    return out;
  }

  /// Rests from [from] to [to] (times in the bar), each starting where its own length divides
  /// the bar, longest first; dotted ones on the [beat] of a compound meter.
  static List<Rhythm> restsBetween(Frac from, Frac to, {Frac? beat, Tuplet? tuplet, Frac? tupletStart}) {
    if (tuplet != null) {
      // Inside a tuplet: by the tuplet's own clock, from its start.
      final origin = tupletStart ?? from;
      final scale = Frac(tuplet.actual, tuplet.normal);
      return [
        for (final r in restsBetween((from - origin) * scale, (to - origin) * scale)) Rhythm(r.type, dots: r.dots, tuplet: tuplet),
      ];
    }
    final out = <Rhythm>[];
    var p = from;
    final compound = beat != null && beat.d == 2 && beat.n % 3 == 0;
    while (p < to) {
      Rhythm? best;
      for (final type in NoteType.values) {
        for (var dots = 0; dots <= (compound ? 1 : 0); dots++) {
          final r = Rhythm(type, dots: dots), length = r.plainLength;
          if (length > to - p) continue;
          final aligned = dots == 0 ? p.isMultipleOf(length) : (p.isMultipleOf(beat!) && length.isMultipleOf(beat));
          if (aligned && (best == null || length > best.plainLength)) best = r;
        }
      }
      if (best == null) {
        out.addAll(express(to - p));
        break;
      }
      out.add(best);
      p = p + best.plainLength;
    }
    return out;
  }

  @override
  bool operator ==(Object other) => other is Rhythm && other.type == type && other.dots == dots && other.tuplet == tuplet;
  @override
  int get hashCode => Object.hash(type, dots, tuplet);
}

/// A written pitch: [step] 0–6 for C–B, [alter] in semitones, [octave] with middle C in 4.
class Pitch {
  const Pitch(this.step, this.octave, [this.alter = 0]);
  final int step, octave, alter;

  static const steps = 'CDEFGAB';
  static const _semitones = [0, 2, 4, 5, 7, 9, 11];

  /// Counts staff positions: one a step.
  int get diatonic => octave * 7 + step;
  int get midi => (octave + 1) * 12 + _semitones[step] + alter;

  static Pitch fromDiatonic(int diatonic, [int alter = 0]) => Pitch(diatonic % 7, diatonic ~/ 7 - (diatonic < 0 && diatonic % 7 != 0 ? 1 : 0), alter);

  /// [step] at the octave nearest [near], as notation programs place a typed letter.
  static Pitch nearest(int step, Pitch near, {int alter = 0}) {
    Pitch? best;
    for (var octave = near.octave - 1; octave <= near.octave + 1; octave++) {
      final p = Pitch(step, octave, alter);
      if (best == null || (p.diatonic - near.diatonic).abs() < (best.diatonic - near.diatonic).abs()) best = p;
    }
    return best!;
  }

  Pitch withAlter(int alter) => Pitch(step, octave, alter);

  /// How a key of [fifths] alters [step]: sharps F C G D A E B, flats the other way.
  static int keyAlter(int step, int fifths) {
    const sharps = [3, 0, 4, 1, 5, 2, 6];
    if (fifths > 0) return sharps.take(fifths).contains(step) ? 1 : 0;
    if (fifths < 0) return sharps.reversed.take(-fifths).contains(step) ? -1 : 0;
    return 0;
  }

  String get name => '${steps[step]}${switch (alter) { -2 => '𝄫', -1 => '♭', 1 => '♯', 2 => '𝄪', _ => '' }}$octave';

  @override
  bool operator ==(Object other) => other is Pitch && other.step == step && other.octave == octave && other.alter == alter;
  @override
  int get hashCode => Object.hash(step, octave, alter);
  @override
  String toString() => name;
}

/// A clef as MusicXML writes it.
class Clef {
  const Clef(this.sign, this.line, [this.octave = 0]);
  static const treble = Clef('G', 2);
  final String sign;
  final int line, octave;

  /// The pitch on its middle line (a percussion clef's is the treble's).
  Pitch get middle {
    final onLine = switch (sign) { 'F' => Pitch(3, 3).diatonic, 'C' => Pitch(0, 4).diatonic, _ => Pitch(4, 4).diatonic } + 7 * octave;
    final lineOf = sign == 'percussion' || sign == 'TAB' ? 2 : line;
    return Pitch.fromDiatonic(onLine + 2 * (3 - lineOf));
  }

  bool get isPercussion => sign == 'percussion' || sign == 'TAB' || sign == 'none';

  /// The clef popover's names (Dorico's, in short).
  static Clef? named(String text) => switch (text.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]'), '')) {
        'treble' || 'g' || 'violin' => const Clef('G', 2),
        'treble8vb' || 'g8vb' || 'tenorg' || 'treble8' => const Clef('G', 2, -1),
        'treble8va' || 'g8va' => const Clef('G', 2, 1),
        'bass' || 'f' => const Clef('F', 4),
        'bass8vb' || 'f8vb' => const Clef('F', 4, -1),
        'bass8va' || 'f8va' => const Clef('F', 4, 1),
        'alto' || 'c' || 'viola' || 'c3' => const Clef('C', 3),
        'tenor' || 'c4' => const Clef('C', 4),
        'soprano' || 'c1' => const Clef('C', 1),
        'mezzosoprano' || 'mezzo' || 'c2' => const Clef('C', 2),
        'baritone' || 'c5' => const Clef('C', 5),
        'percussion' || 'perc' || 'neutral' => const Clef('percussion', 3),
        _ => null,
      };

  XmlElement toXml(int? number) => _el('clef', [
        _text('sign', sign),
        if (!isPercussion) _text('line', '$line'),
        if (octave != 0) _text('clef-octave-change', '$octave'),
      ], {'number': ?number?.toString()});

  static Clef fromXml(XmlElement clef) => Clef(
        _childText(clef, 'sign') ?? 'G',
        int.tryParse(_childText(clef, 'line') ?? '') ?? (_childText(clef, 'sign') == 'F' ? 4 : _childText(clef, 'sign') == 'C' ? 3 : 2),
        int.tryParse(_childText(clef, 'clef-octave-change') ?? '') ?? 0,
      );

  @override
  bool operator ==(Object other) => other is Clef && other.sign == sign && other.line == line && other.octave == octave;
  @override
  int get hashCode => Object.hash(sign, line, octave);
}

/// A time signature: [beats] as written (`3`, `2+2+3`) over [beatType].
class TimeSig {
  const TimeSig(this.beats, this.beatType, {this.symbol});
  final String beats;
  final int beatType;

  /// `common` or `cut`, drawn as a symbol.
  final String? symbol;

  List<int> get summands => [for (final s in beats.split('+')) int.tryParse(s.trim()) ?? 0];
  int get count => summands.fold(0, (a, b) => a + b);
  Frac get length => Frac(count * 4, beatType);

  /// Where beams break in a bar: each beat (a dotted one in a compound meter, each group of an
  /// additive one), a whole bar of 3/8.
  List<Frac> get beamGroups {
    final unit = Frac(4, beatType);
    if (summands.length > 1) return [for (final s in summands) unit * Frac(s)];
    if (beatType >= 8) {
      if (count % 3 == 0 && count > 3) return List.filled(count ~/ 3, unit * Frac(3));
      return [length];
    }
    return List.filled(count, unit);
  }

  /// The beat of a compound meter (a dotted quarter in 6/8), else the written beat.
  Frac get beat => beatType >= 8 && count % 3 == 0 && count > 3 ? Frac(12, beatType) : Frac(4, beatType);

  /// The time signature popover: `3/4`, `6/8`, `2+2+3/8`, `C`, `cut`.
  static TimeSig? parse(String text) {
    final t = text.trim().toLowerCase();
    if (t == 'c' || t == 'common') return const TimeSig('4', 4, symbol: 'common');
    if (t == '¢' || t == 'cut' || t == 'c|') return const TimeSig('2', 2, symbol: 'cut');
    final m = RegExp(r'^(\d+(?:\s*\+\s*\d+)*)\s*/\s*(\d+)$').firstMatch(t);
    if (m == null) return null;
    final beatType = int.tryParse(m.group(2)!);
    final beats = m.group(1)!.replaceAll(' ', '');
    if (beatType == null || ![1, 2, 4, 8, 16, 32].contains(beatType)) return null;
    final meter = TimeSig(beats, beatType);
    if (meter.count < 1 || meter.count > 64) return null;
    return meter;
  }

  XmlElement toXml() => _el('time', [_text('beats', beats), _text('beat-type', '$beatType')], {'symbol': ?symbol});

  @override
  String toString() => '$beats/$beatType';
}

/// A key signature: [fifths] (sharps up, flats down), major or minor.
class KeySig {
  const KeySig(this.fifths, {this.minor = false});
  final int fifths;
  final bool minor;

  static const _majors = {'cb': -7, 'gb': -6, 'db': -5, 'ab': -4, 'eb': -3, 'bb': -2, 'f': -1, 'c': 0, 'g': 1, 'd': 2, 'a': 3, 'e': 4, 'b': 5, 'f#': 6, 'c#': 7};

  /// The key popover: `G`, `Eb` or `E♭` (major), `f#` lowercase (minor), `2#`, `3b`, `0`.
  static KeySig? parse(String text) {
    var t = text.trim().replaceAll('♭', 'b').replaceAll('♯', '#');
    final counted = RegExp(r'^([0-7])\s*([#b]?)$').firstMatch(t);
    if (counted != null) {
      final n = int.parse(counted.group(1)!);
      return KeySig(counted.group(2) == 'b' ? -n : n);
    }
    final words = RegExp(r'^([A-Ga-g][#b]?)\s*(major|minor|maj|min|m)?$').firstMatch(t);
    if (words == null) return null;
    final letter = words.group(1)!, quality = words.group(2);
    final minor = quality == null ? letter[0] == letter[0].toLowerCase() : quality.startsWith('min') || quality == 'm';
    t = letter.toLowerCase();
    final major = _majors[t];
    if (major == null) {
      // Minor keys: three fifths under their relative major.
      const minors = {'ab': -7, 'eb': -6, 'bb': -5, 'f': -4, 'c': -3, 'g': -2, 'd': -1, 'a': 0, 'e': 1, 'b': 2, 'f#': 3, 'c#': 4, 'g#': 5, 'd#': 6, 'a#': 7};
      final m = minors[t];
      return m == null ? null : KeySig(m, minor: true);
    }
    if (!minor) return KeySig(major);
    final m = major - 3;
    return m < -7 ? null : KeySig(m, minor: true);
  }
}

// MARK: Positions

/// A voice of a part: its staff (1-based in the part) and MusicXML's voice.
class VoiceKey implements Comparable<VoiceKey> {
  const VoiceKey(this.staff, this.voice);
  final int staff;
  final String voice;

  int get _number => int.tryParse(voice) ?? 99;

  @override
  int compareTo(VoiceKey o) => staff != o.staff ? staff.compareTo(o.staff) : _number != o._number ? _number.compareTo(o._number) : voice.compareTo(o.voice);
  @override
  bool operator ==(Object other) => other is VoiceKey && other.staff == staff && other.voice == voice;
  @override
  int get hashCode => Object.hash(staff, voice);
  @override
  String toString() => '$staff/$voice';
}

/// A place in the score: a part's voice, a bar (0-based) and a time in it.
class ScorePosition {
  const ScorePosition(this.part, this.voice, this.measure, this.time);
  final int part;
  final VoiceKey voice;
  final int measure;
  final Frac time;

  int get staff => voice.staff;

  ScorePosition at(int measure, Frac time) => ScorePosition(part, voice, measure, time);
  ScorePosition inVoice(VoiceKey voice) => ScorePosition(part, voice, measure, time);

  @override
  bool operator ==(Object other) => other is ScorePosition && other.part == part && other.voice == voice && other.measure == measure && other.time == time;
  @override
  int get hashCode => Object.hash(part, voice, measure, time);
  @override
  String toString() => 'P$part $voice m$measure @$time';
}

/// A note, chord or rest as the editor sees it ([EditableScore.locate]).
class EventInfo {
  const EventInfo({
    required this.position,
    required this.length,
    required this.ids,
    required this.pitches,
    required this.rhythm,
    required this.tiedOn,
  });
  final ScorePosition position;
  final Frac length;

  /// Its notes' ids, the chord's from the first written; one for a rest.
  final List<String> ids;

  /// Empty for a rest.
  final List<Pitch> pitches;

  /// As written (null for a whole-bar rest).
  final Rhythm? rhythm;

  /// Whether its notes are tied on to the next.
  final bool tiedOn;

  bool get isRest => pitches.isEmpty;
  Frac get end => position.time + length;
}

/// What a note to put in is: its [rhythm] and [pitches] (none: a rest). [templates] are notes to
/// copy (a pasted or lengthened note keeps its articulations, lyrics…); [tieFrom] ties it from the
/// note before.
class InputItem {
  const InputItem(this.rhythm, this.pitches, {this.templates, this.tieFrom = false});
  final Rhythm rhythm;
  final List<Pitch> pitches;
  final List<XmlElement>? templates;
  final bool tieFrom;
  Frac get length => rhythm.length;
}

/// Notes copied (⌘C): each event's offset from the first, and its notes as written.
class CopiedMusic {
  const CopiedMusic(this.events);
  final List<({Frac offset, Frac length, Rhythm? rhythm, List<XmlElement> notes})> events;
  bool get isEmpty => events.isEmpty;
  Frac get length => events.isEmpty ? Frac.zero : events.last.offset + events.last.length;
}

/// A part of the score: [id], [name], how many staves it has.
class EditPart {
  EditPart._(this.id, this.name, this.element);
  final String id;
  final String name;
  final XmlElement element;
  final List<XmlElement> _measures = [];
  int divisions = 1;
  int staves = 1;
  List<_Context>? _contexts;
}

/// What is in force at the start of a bar, before its own changes.
class _Context {
  const _Context({required this.divisions, required this.key, required this.meter, required this.clefs, required this.transpose, required this.staves});
  final int divisions;
  final KeySig key;
  final TimeSig? meter;
  final Map<int, Clef> clefs;
  final XmlElement? transpose;
  final int staves;

  _Context copyWith({int? divisions, KeySig? key, TimeSig? meter, Map<int, Clef>? clefs, XmlElement? transpose, int? staves}) => _Context(
        divisions: divisions ?? this.divisions,
        key: key ?? this.key,
        meter: meter ?? this.meter,
        clefs: clefs ?? this.clefs,
        transpose: transpose ?? this.transpose,
        staves: staves ?? this.staves,
      );

  Clef clef(int staff) => clefs[staff] ?? Clef.treble;
}

// MARK: Measure contents

class _Event {
  _Event(this.start, this.length, this.notes, [List<XmlElement>? graces]) : graces = graces ?? [];
  Frac start, length;
  final List<XmlElement> notes;
  final List<XmlElement> graces;
  Frac get end => start + length;
  XmlElement get main => notes.first;
  bool get isRest => main.getElement('rest') != null;
  bool get isMeasureRest => main.getElement('rest')?.getAttribute('measure') == 'yes';
  Tuplet? get tuplet => _tupletOf(main);
}

class _Other {
  _Other(this.time, this.element) : staff = int.tryParse(_childText(element, 'staff') ?? '');
  final Frac time;
  final XmlElement element;
  final int? staff;
}

/// One bar of a part, read: its voices' events and everything else at its time.
class _Content {
  final voices = <VoiceKey, List<_Event>>{};
  final others = <_Other>[];
  final trailing = <VoiceKey, List<XmlElement>>{};
  Frac length = Frac.zero;

  Iterable<_Event> get events => voices.values.expand((e) => e);
}

VoiceKey _voiceOf(XmlElement element) =>
    VoiceKey(int.tryParse(_childText(element, 'staff') ?? '') ?? 1, _childText(element, 'voice')?.trim() ?? '1');

_Content _read(XmlElement measure, int divisions) {
  final c = _Content();
  var cursor = Frac.zero;
  _Event? last;
  final graces = <VoiceKey, List<XmlElement>>{};
  for (final child in measure.childElements) {
    switch (child.name.local) {
      case 'note':
        final key = _voiceOf(child);
        if (child.getElement('grace') != null) {
          graces.putIfAbsent(key, () => []).add(child);
          continue;
        }
        final length = Frac(int.tryParse(_childText(child, 'duration')?.trim() ?? '') ?? 0, divisions);
        if (child.getElement('chord') != null && last != null) {
          last.notes.add(child);
          continue;
        }
        final e = _Event(cursor, length, [child], graces.remove(key));
        c.voices.putIfAbsent(key, () => []).add(e);
        last = e;
        cursor = cursor + length;
        c.length = Frac.max(c.length, cursor);
      case 'backup':
        cursor = Frac.max(Frac.zero, cursor - Frac(int.tryParse(_childText(child, 'duration')?.trim() ?? '') ?? 0, divisions));
        last = null;
      case 'forward':
        cursor = cursor + Frac(int.tryParse(_childText(child, 'duration')?.trim() ?? '') ?? 0, divisions);
        c.length = Frac.max(c.length, cursor);
        last = null;
      default:
        c.others.add(_Other(cursor, child));
    }
  }
  c.trailing.addAll(graces);
  for (final events in c.voices.values) {
    _stableSort(events, (a, b) => a.start.compareTo(b.start));
  }
  return c;
}

/// A stable sort (List.sort isn't).
void _stableSort<T>(List<T> list, int Function(T, T) compare) {
  if (list.length < 2) return;
  final copy = [...list];
  final indexed = [for (var i = 0; i < copy.length; i++) i]
    ..sort((a, b) {
      final c = compare(copy[a], copy[b]);
      return c != 0 ? c : a.compareTo(b);
    });
  for (var i = 0; i < indexed.length; i++) {
    list[i] = copy[indexed[i]];
  }
}

/// [c] written as a bar again in [original]'s place: each voice from the bar's start (a
/// `<backup>` between them, a `<forward>` over a gap), and everything else at its time, in the
/// voice that has a note starting or ending there.
XmlElement _write(XmlElement original, _Content c, int divisions, {required bool multiStaff}) {
  final out = XmlElement.tag('measure', attributes: [for (final a in original.attributes) a.copy()]);
  void add(XmlNode node) => out.children.add(node.hasParent ? node.copy() : node);
  XmlElement span(String name, Frac length, [VoiceKey? voice]) => _el(name, [
        _text('duration', '${(length * Frac(divisions)).n}'),
        if (voice != null) _text('voice', voice.voice),
        if (voice != null && multiStaff) _text('staff', '${voice.staff}'),
      ]);

  final voices = c.voices.keys.where((k) => c.voices[k]!.isNotEmpty).toList()..sort();
  final start = <XmlElement>[], end = <XmlElement>[], timed = <_Other>[];
  for (final o in c.others) {
    if (o.element.name.local == 'barline') {
      switch (o.element.getAttribute('location') ?? 'right') {
        case 'left':
          start.add(o.element);
        case 'right':
          end.add(o.element);
        default:
          timed.add(o);
      }
    } else if (o.time.isZero) {
      start.add(o.element);
    } else {
      timed.add(o);
    }
  }
  bool boundary(List<_Event> events, Frac t) => events.any((e) => e.start == t || e.end == t);
  final assigned = <VoiceKey, Map<Frac, List<XmlElement>>>{};
  final late = <_Other>[];
  for (final o in timed) {
    VoiceKey? target;
    for (final v in voices) {
      if ((o.staff == null || v.staff == o.staff) && boundary(c.voices[v]!, o.time)) {
        target = v;
        break;
      }
    }
    target ??= voices.where((v) => boundary(c.voices[v]!, o.time)).firstOrNull;
    if (target == null) {
      late.add(o);
    } else {
      assigned.putIfAbsent(target, () => {}).putIfAbsent(o.time, () => []).add(o.element);
    }
  }

  start.forEach(add);
  var cursor = Frac.zero;
  for (final v in voices) {
    if (cursor.isPositive) add(span('backup', cursor));
    cursor = Frac.zero;
    final pending = assigned[v] ?? {};
    void emitAt(Frac t) => pending.remove(t)?.forEach(add);
    for (final e in c.voices[v]!) {
      if (e.start > cursor) {
        emitAt(cursor);
        add(span('forward', e.start - cursor, v));
        cursor = e.start;
      }
      emitAt(cursor);
      e.graces.forEach(add);
      for (final (i, note) in e.notes.indexed) {
        _setChord(note, i > 0);
        _setDuration(note, e.length, divisions);
        _setVoice(note, v, multiStaff);
        add(note);
      }
      cursor = e.end;
    }
    emitAt(cursor);
    c.trailing.remove(v)?.forEach(add);
    // Anything at a time that only fell inside a gap.
    for (final entry in pending.entries) {
      for (final element in entry.value) {
        late.add(_Other(entry.key, element));
      }
    }
  }
  for (final graces in c.trailing.values) {
    graces.forEach(add);
  }
  _stableSort(late, (a, b) => b.time.compareTo(a.time));
  for (final o in late) {
    if (o.time < cursor) add(span('backup', cursor - o.time));
    if (o.time > cursor) add(span('forward', o.time - cursor));
    cursor = o.time;
    add(o.element);
  }
  end.forEach(add);
  return out;
}

// MARK: Note elements

/// MusicXML's order of a note's children, which the schema fixes.
const _noteOrder = [
  'grace', 'cue', 'chord', 'pitch', 'unpitched', 'rest', 'duration', 'tie', 'instrument', 'footnote', 'level', 'voice', 'type',
  'dot', 'accidental', 'time-modification', 'stem', 'notehead', 'notehead-text', 'staff', 'beam', 'notations', 'lyric', 'play', 'listen',
];

XmlElement _el(String name, [List<XmlNode> children = const [], Map<String, String> attributes = const {}]) =>
    XmlElement.tag(name, attributes: [for (final a in attributes.entries) XmlAttribute(XmlName.qualified(a.key), a.value)], children: children);

XmlElement _text(String name, String value, [Map<String, String> attributes = const {}]) => _el(name, [XmlText(value)], attributes);

String? _childText(XmlElement element, String name) => element.getElement(name)?.innerText;

/// Puts [child] among [note]'s children where the schema has it.
void _insertNoteChild(XmlElement note, XmlElement child) {
  final rank = _noteOrder.indexOf(child.name.local);
  final children = note.children;
  for (var i = 0; i < children.length; i++) {
    final c = children[i];
    if (c is XmlElement && _noteOrder.indexOf(c.name.local) > rank) {
      children.insert(i, child);
      return;
    }
  }
  children.add(child);
}

void _removeChildren(XmlElement element, String name) {
  for (final c in element.findElements(name).toList()) {
    c.remove();
  }
}

void _setNoteChild(XmlElement note, String name, String? value) {
  _removeChildren(note, name);
  if (value != null) _insertNoteChild(note, _text(name, value));
}

void _setChord(XmlElement note, bool chord) {
  final has = note.getElement('chord') != null;
  if (chord && !has) _insertNoteChild(note, _el('chord'));
  if (!chord && has) _removeChildren(note, 'chord');
}

void _setDuration(XmlElement note, Frac length, int divisions) => _setNoteChild(note, 'duration', '${(length * Frac(divisions)).n}');

void _setVoice(XmlElement note, VoiceKey voice, bool multiStaff) {
  _setNoteChild(note, 'voice', voice.voice);
  if (multiStaff || note.getElement('staff') != null) _setNoteChild(note, 'staff', '${voice.staff}');
}

void _setRhythm(XmlElement note, Rhythm? rhythm) {
  _removeChildren(note, 'type');
  _removeChildren(note, 'dot');
  _removeChildren(note, 'time-modification');
  if (rhythm == null) return;
  _insertNoteChild(note, _text('type', rhythm.type.type));
  for (var i = 0; i < rhythm.dots; i++) {
    _insertNoteChild(note, _el('dot'));
  }
  if (rhythm.tuplet case final t?) {
    _insertNoteChild(
        note, _el('time-modification', [_text('actual-notes', '${t.actual}'), _text('normal-notes', '${t.normal}'), _text('normal-type', t.unit.type)]));
  }
}

Rhythm? _rhythmOf(XmlElement note) {
  final type = NoteType.named(_childText(note, 'type')?.trim());
  if (type == null) return null;
  return Rhythm(type, dots: note.findElements('dot').length, tuplet: _tupletOf(note));
}

Tuplet? _tupletOf(XmlElement note) {
  final tm = note.getElement('time-modification');
  if (tm == null) return null;
  final actual = int.tryParse(_childText(tm, 'actual-notes') ?? ''), normal = int.tryParse(_childText(tm, 'normal-notes') ?? '');
  if (actual == null || normal == null || actual == normal) return null;
  final unit = NoteType.named(_childText(tm, 'normal-type')?.trim()) ?? NoteType.named(_childText(note, 'type')?.trim()) ?? NoteType.eighth;
  return Tuplet(actual, normal, unit);
}

Pitch? _pitchOf(XmlElement note) {
  if (note.getElement('pitch') case final p?) {
    final step = Pitch.steps.indexOf(_childText(p, 'step')?.trim() ?? '');
    if (step < 0) return null;
    return Pitch(step, int.tryParse(_childText(p, 'octave') ?? '') ?? 4, (double.tryParse(_childText(p, 'alter') ?? '') ?? 0).round());
  }
  if (note.getElement('unpitched') case final u?) {
    final step = Pitch.steps.indexOf(_childText(u, 'display-step')?.trim() ?? '');
    if (step < 0) return null;
    return Pitch(step, int.tryParse(_childText(u, 'display-octave') ?? '') ?? 4);
  }
  return null;
}

void _setPitch(XmlElement note, Pitch pitch) {
  if (note.getElement('unpitched') != null) {
    _removeChildren(note, 'unpitched');
    _insertNoteChild(note, _el('unpitched', [_text('display-step', Pitch.steps[pitch.step]), _text('display-octave', '${pitch.octave}')]));
    return;
  }
  _removeChildren(note, 'rest');
  _removeChildren(note, 'pitch');
  _insertNoteChild(
      note,
      _el('pitch', [
        _text('step', Pitch.steps[pitch.step]),
        if (pitch.alter != 0) _text('alter', '${pitch.alter}'),
        _text('octave', '${pitch.octave}'),
      ]));
}

bool _tiedOn(XmlElement note) => note.findElements('tie').any((t) => t.getAttribute('type') == 'start');
bool _tiedFrom(XmlElement note) => note.findElements('tie').any((t) => t.getAttribute('type') == 'stop');

XmlElement _notations(XmlElement note) {
  if (note.getElement('notations') case final n?) return n;
  final n = _el('notations');
  _insertNoteChild(note, n);
  return n;
}

void _dropEmptyNotations(XmlElement note) {
  for (final n in note.findElements('notations').toList()) {
    for (final group in ['articulations', 'ornaments', 'technical']) {
      for (final g in n.findElements(group).toList()) {
        if (g.childElements.isEmpty) g.remove();
      }
    }
    if (n.childElements.isEmpty) n.remove();
  }
}

/// Ties [note] on (`start`) or from (`stop`) as both `<tie>` (sound) and `<tied>` (drawn).
void _setTie(XmlElement note, String type, bool on) {
  for (final t in note.findElements('tie').where((t) => t.getAttribute('type') == type).toList()) {
    t.remove();
  }
  if (note.getElement('notations') case final n?) {
    for (final t in n.findElements('tied').where((t) => t.getAttribute('type') == type).toList()) {
      t.remove();
    }
  }
  if (on) {
    _insertNoteChild(note, _el('tie', const [], {'type': type}));
    final n = _notations(note);
    n.children.insert(0, _el('tied', const [], {'type': type}));
  }
  _dropEmptyNotations(note);
}

// MARK: The score

/// A MusicXML score (partwise) open in the score editor. Bars are never changed in place: an
/// edit writes a bar anew in its place, so Undo only puts the bars it had back.
class EditableScore {
  EditableScore._(this._document, this.parts);

  /// Reads [musicXML]; throws a [FormatException] for what it can't edit (a timewise score).
  factory EditableScore.parse(String musicXML) {
    final document = XmlDocument.parse(musicXML);
    final root = document.rootElement;
    if (root.name.local != 'score-partwise') {
      throw const FormatException('Only partwise MusicXML can be edited.');
    }
    final names = <String, String>{};
    for (final p in root.findAllElements('score-part')) {
      final name = _childText(p, 'part-name')?.trim();
      names[p.getAttribute('id') ?? ''] = (name == null || name.isEmpty ? _childText(p, 'part-abbreviation')?.trim() : name) ?? '';
    }
    final parts = <EditPart>[];
    for (final element in root.findElements('part')) {
      final id = element.getAttribute('id') ?? '';
      final part = EditPart._(id, names[id] ?? id, element);
      part._measures.addAll(element.findElements('measure'));
      parts.add(part);
    }
    if (parts.isEmpty || parts.first._measures.isEmpty) throw const FormatException('The score has no bars.');
    // Every edit takes a bar of each part: one with fewer has none there.
    if (parts.any((p) => p._measures.length != parts.first._measures.length)) {
      throw const FormatException('The instruments have different numbers of bars.');
    }
    final score = EditableScore._(document, parts);
    for (final part in parts) {
      score._normalizeDivisions(part);
    }
    score._tagAll();
    score._indexAll();
    return score;
  }

  final XmlDocument _document;
  final List<EditPart> parts;
  int _nextId = 1;
  final _where = <String, ({int part, int measure})>{};

  int get measureCount => parts.first._measures.length;

  /// Bars written since [takeChanged] last asked; null: every bar from [_changedFrom] on.
  final _changed = <int>{};
  int? _changedFrom;

  /// The bars changed since the last call (their indices now), and from which bar on every one
  /// may have (bars added or deleted), if any.
  ({Set<int> bars, int? from}) takeChanged() {
    final out = (bars: {..._changed}, from: _changedFrom);
    _changed.clear();
    _changedFrom = null;
    return out;
  }

  // MARK: Ids

  /// What the editor tells apart on the engraving: notes and rests, directions, dynamics,
  /// hairpins' starts, slurs' starts. An id the file had is kept aside and given back on export.
  static const _tagged = {'note', 'direction', 'dynamics', 'wedge', 'slur'};

  void _tagAll() {
    for (final part in parts) {
      for (final m in part._measures) {
        _tagIn(m);
      }
    }
  }

  void _tagIn(XmlElement root) {
    for (final e in root.descendantElements) {
      if (!_tagged.contains(e.name.local)) continue;
      if (e.name.local == 'wedge' && e.getAttribute('type') == 'stop') continue;
      if (e.name.local == 'slur' && e.getAttribute('type') != 'start') continue;
      final id = e.getAttribute('id');
      if (id != null && id.startsWith('cxe')) {
        final n = int.tryParse(id.substring(3));
        if (n != null) _nextId = math.max(_nextId, n + 1);
        continue;
      }
      if (id != null) e.setAttribute('cxe-orig', id);
      e.setAttribute('id', 'cxe${_nextId++}');
    }
  }

  /// [element] and what's in it given ids of their own (a copy of notes).
  void _retag(XmlElement element) {
    for (final e in [element, ...element.descendantElements]) {
      if (e.getAttribute('id')?.startsWith('cxe') ?? false) {
        e.setAttribute('id', null);
        e.setAttribute('cxe-orig', null);
      }
    }
    _tagIn(_el('x', [element]));
    element.remove();
  }

  void _indexAll() {
    _where.clear();
    _indexFrom(0);
  }

  /// The bars from [from] on found again by their ids (bars put in or taken out before them
  /// moved them).
  void _indexFrom(int from) {
    for (final (p, part) in parts.indexed) {
      for (var m = from; m < part._measures.length; m++) {
        _indexMeasure(p, m, part._measures[m]);
      }
    }
  }

  void _indexMeasure(int part, int measure, XmlElement element) {
    for (final e in element.descendantElements) {
      final id = e.getAttribute('id');
      if (id != null && id.startsWith('cxe')) _where[id] = (part: part, measure: measure);
    }
  }

  /// A bar that is leaving its place: its ids are nothing in the score until a bar that has
  /// them is put there.
  void _unindexMeasure(int part, int measure, XmlElement element) {
    for (final e in element.descendantElements) {
      final id = e.getAttribute('id');
      if (id != null && _where[id] == (part: part, measure: measure)) _where.remove(id);
    }
  }

  /// Whether [id] is something in the score now.
  bool has(String id) => _where.containsKey(id);

  // MARK: Divisions

  /// Every bar of [part] in one `<divisions>`: the least all its values divide.
  void _normalizeDivisions(EditPart part) {
    var all = 1;
    var any = false;
    for (final m in part._measures) {
      for (final d in m.findAllElements('divisions')) {
        final v = int.tryParse(d.innerText.trim());
        if (v != null && v > 0) {
          all = any ? _lcm(all, v) : v;
          any = true;
        }
      }
    }
    // Rescale bar by bar, each from the divisions in force there.
    final changed = part._measures.any((m) => m.findAllElements('divisions').any((d) => (int.tryParse(d.innerText.trim()) ?? all) != all));
    if (changed) {
      var current = 1;
      for (var i = 0; i < part._measures.length; i++) {
        final copy = part._measures[i].copy();
        var factor = all ~/ current;
        for (final child in copy.childElements) {
          if (child.name.local == 'attributes') {
            final d = child.getElement('divisions');
            final v = int.tryParse(d?.innerText.trim() ?? '');
            if (v != null && v > 0) {
              current = v;
              factor = all ~/ v;
              d!.innerText = '$all';
            }
          }
          _scaleDurations(child, factor);
        }
        part._measures[i].replace(copy);
        part._measures[i] = copy;
      }
    }
    part.divisions = any ? all : 1;
    if (!any) {
      // A file with no divisions at all: give its first bar one.
      final first = part._measures.first;
      final copy = first.copy();
      _attributesAtStart(copy).children.insert(0, _text('divisions', '1'));
      first.replace(copy);
      part._measures[0] = copy;
    }
    part.staves = 1;
    for (final m in part._measures) {
      for (final s in m.findAllElements('staves')) {
        part.staves = math.max(part.staves, int.tryParse(s.innerText.trim()) ?? 1);
      }
    }
  }

  static void _scaleDurations(XmlElement element, int factor) {
    if (factor == 1) return;
    void scale(XmlElement? e) {
      if (e == null) return;
      final v = num.tryParse(e.innerText.trim());
      if (v != null) e.innerText = '${(v * factor).round()}';
    }

    switch (element.name.local) {
      case 'note' || 'backup' || 'forward' || 'figured-bass':
        scale(element.getElement('duration'));
      case 'direction' || 'harmony' || 'sound':
        scale(element.getElement('offset'));
    }
  }

  /// [part]'s divisions made fine enough for [length]s and times like it: every bar rescaled.
  /// (They are engraved as they were, so none is said to have changed: the first triplet typed
  /// would have every chunk of the score engraved again.)
  void _ensureDivisions(EditPart part, Iterable<Frac> times) {
    var needed = 1;
    for (final t in times) {
      needed = _lcm(needed, t.d);
    }
    if (part.divisions % needed == 0) return;
    final next = _lcm(part.divisions, needed), factor = next ~/ part.divisions;
    for (var i = 0; i < part._measures.length; i++) {
      final copy = part._measures[i].copy();
      for (final child in copy.childElements) {
        if (child.name.local == 'attributes') {
          if (child.getElement('divisions') case final d?) d.innerText = '$next';
        }
        _scaleDurations(child, factor);
      }
      part._measures[i].replace(copy);
      part._measures[i] = copy;
    }
    part.divisions = next;
    part._contexts = null;
  }

  // MARK: Contexts

  /// What is in force where bar [m] of [part] starts. Kept bar by bar and worked out as far as
  /// asked: a bar written again leaves those before it as they were ([_contextsStaleFrom]).
  _Context _contextBefore(EditPart part, int m) {
    final known = part._contexts ??= [];
    if (known.isEmpty) {
      known.add(_Context(divisions: part.divisions, key: const KeySig(0), meter: null, clefs: const {}, transpose: null, staves: 1));
    }
    while (known.length <= m) {
      var context = known.last;
      for (final a in part._measures[known.length - 1].findElements('attributes')) {
        context = _applyAttributes(context, a);
      }
      known.add(context);
    }
    return known[m];
  }

  /// Bar [m] of [part] was written again: what is in force after it may have changed.
  static void _contextsStaleFrom(EditPart part, int m) {
    if (part._contexts case final known? when known.length > m + 1) known.length = m + 1;
  }

  static _Context _applyAttributes(_Context context, XmlElement a) {
    var c = context;
    if (a.getElement('key') case final key?) {
      final fifths = int.tryParse(_childText(key, 'fifths')?.trim() ?? '');
      if (fifths != null) c = c.copyWith(key: KeySig(fifths, minor: _childText(key, 'mode')?.trim() == 'minor'));
    }
    if (a.getElement('time') case final time?) {
      final beats = _childText(time, 'beats')?.trim(), type = int.tryParse(_childText(time, 'beat-type')?.trim() ?? '');
      // (One that says no length, a beat type of 0 or beats that are no numbers, is none: a bar
      // of no length could never be filled.)
      final meter = beats == null || type == null || type < 1 ? null : TimeSig(beats, type, symbol: time.getAttribute('symbol'));
      if (meter != null && meter.count >= 1) c = c.copyWith(meter: meter);
    }
    if (a.getElement('staves') case final s?) c = c.copyWith(staves: int.tryParse(s.innerText.trim()) ?? c.staves);
    final clefs = a.findElements('clef').toList();
    if (clefs.isNotEmpty) {
      c = c.copyWith(clefs: {
        ...c.clefs,
        for (final clef in clefs) int.tryParse(clef.getAttribute('number') ?? '') ?? 1: Clef.fromXml(clef),
      });
    }
    if (a.getElement('transpose') case final t?) c = c.copyWith(transpose: t);
    return c;
  }

  /// What is in force in bar [m] of [part] at [time] (its own changes up to then included).
  _Context _contextAt(int part, int m, Frac time) {
    final p = parts[part];
    var context = _contextBefore(p, m);
    for (final o in _view(part, m).others) {
      if (o.time > time) break;
      if (o.element.name.local == 'attributes') context = _applyAttributes(context, o.element);
    }
    return context;
  }

  /// The clef of [staff] in bar [m] at [time].
  Clef clefAt(int part, int staff, int m, Frac time) => _contextAt(part, m, time).clef(staff);

  /// The key in force in bar [m] (concert or written, as the part writes it).
  KeySig keyAt(int part, int m, Frac time) => _contextAt(part, m, time).key;

  /// The time signature in force in bar [m] (after its own).
  TimeSig? meterAt(int m) => _contextAt(0, m, Frac.zero).meter;

  /// How long bar [m] is: its time signature's length, or what it holds (an upbeat, a bar
  /// with no time signature).
  Frac barLength(int m) {
    final measure = parts.first._measures[m];
    final held = parts.indexed.fold(Frac.zero, (a, p) => Frac.max(a, _view(p.$1, m).length));
    if (measure.getAttribute('implicit') == 'yes') return held.isPositive ? held : (meterAt(m)?.length ?? Frac(4));
    return meterAt(m)?.length ?? (held.isPositive ? held : Frac(4));
  }

  /// The bar's number as the score prints it.
  String barNumber(int m) => parts.first._measures[m].getAttribute('number') ?? '${m + 1}';

  // MARK: Reading bars

  final _views = Expando<_Content>();

  /// Bar [m] of [part] as it is (never changed: edits work on [_mutable]).
  _Content _view(int part, int m) {
    final measure = parts[part]._measures[m];
    return _views[measure] ??= _read(measure, parts[part].divisions);
  }

  _Content _mutable(int part, int m) => _read(parts[part]._measures[m].copy(), parts[part].divisions);

  /// Puts [content] in bar [m] of [part], after tidying the voices in [voices].
  void _commit(int part, int m, _Content content, {Iterable<VoiceKey> voices = const []}) {
    final p = parts[part];
    for (final v in {...voices}) {
      _tidy(part, m, content, v);
    }
    for (final staff in {for (final v in voices) v.staff}) {
      _respell(part, m, content, staff);
    }
    final before = p.divisions;
    _ensureDivisions(p, [for (final e in content.events) ...[e.start, e.length], for (final o in content.others) o.time]);
    if (p.divisions != before) {
      for (final o in content.others) {
        _scaleDurations(o.element, p.divisions ~/ before);
        if (o.element.name.local == 'attributes') {
          if (o.element.getElement('divisions') case final d?) d.innerText = '${p.divisions}';
        }
      }
    }
    final old = p._measures[m];
    final written = _write(old, content, p.divisions, multiStaff: p.staves > 1);
    _tagIn(written);
    _unindexMeasure(part, m, old);
    old.replace(written);
    p._measures[m] = written;
    _indexMeasure(part, m, written);
    _changed.add(m);
    _contextsStaleFrom(p, m);
  }

  // MARK: Undo

  final _undo = <_Step>[], _redo = <_Step>[];
  bool _editing = false;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Runs [change] as one Undo step (nested calls join the outer one). Nothing changed, no step.
  T edit<T>(T Function() change) {
    if (_editing) return change();
    _editing = true;
    final bars = [for (final p in parts) List.of(p._measures)], divisions = [for (final p in parts) p.divisions];
    try {
      return change();
    } finally {
      _editing = false;
      final step = _stepBackTo(bars, divisions);
      if (step != null) {
        _undo.add(step);
        _redo.clear();
        if (_undo.length > 500) _undo.removeAt(0);
      }
    }
  }

  /// What takes the score back to [bars] (each part's, as they were): the bars that differ, or
  /// all of a part's when it has more or fewer now. Null: nothing differs.
  _Step? _stepBackTo(List<List<XmlElement>> bars, List<int> divisions) {
    final whole = <List<XmlElement>?>[], some = <Map<int, XmlElement>>[];
    var any = false;
    for (final (i, p) in parts.indexed) {
      final now = p._measures, was = bars[i];
      if (now.length != was.length) {
        whole.add(was);
        some.add(const {});
        any = true;
        continue;
      }
      final differ = <int, XmlElement>{
        for (var m = 0; m < now.length; m++)
          if (!identical(now[m], was[m])) m: was[m],
      };
      whole.add(null);
      some.add(differ);
      any = any || differ.isNotEmpty;
    }
    return any ? _Step(whole, some, divisions) : null;
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_take(_undo.removeLast()));
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_take(_redo.removeLast()));
  }

  /// Puts [step]'s bars back, and returns the step that undoes that. Only the bars it names are
  /// touched: a step of one bar costs one bar, however long the score.
  _Step _take(_Step step) {
    final count = measureCount;
    final back = _stepBackToNow();
    var counted = false;
    for (final (i, p) in parts.indexed) {
      final now = p._measures;
      var all = step.whole[i];
      if (all == null && step.bars[i].values.any((bar) => bar.hasParent)) {
        // A bar to put back is in the part now, at another place: every bar set, as when their
        // number changed (an element is in one place at a time).
        all = List.of(now);
        for (final MapEntry(key: m, value: bar) in step.bars[i].entries) {
          all[m] = bar;
        }
      }
      if (all != null) {
        back.whole[i] = List.of(now);
        // Bars that differ are written again in the engraving.
        for (var m = 0; m < math.max(now.length, all.length); m++) {
          if (m >= now.length || m >= all.length || !identical(now[m], all[m])) _changed.add(m);
        }
        p.element.children.clear();
        p.element.children.addAll(all);
        now
          ..clear()
          ..addAll(all);
        counted = true;
      } else {
        final bars = back.bars[i] = <int, XmlElement>{};
        for (final MapEntry(key: m, value: bar) in step.bars[i].entries) {
          final old = now[m];
          bars[m] = old;
          _unindexMeasure(i, m, old);
          old.replace(bar);
          now[m] = bar;
          _indexMeasure(i, m, bar);
          _changed.add(m);
        }
      }
      if (all != null || p.divisions != step.divisions[i]) {
        p._contexts = null;
      } else if (step.bars[i].isNotEmpty) {
        _contextsStaleFrom(p, step.bars[i].keys.reduce(math.min));
      }
      p.divisions = step.divisions[i];
    }
    if (measureCount != count) _markFrom(math.min(count, measureCount));
    if (counted) _indexAll();
    return back;
  }

  _Step _stepBackToNow() => _Step([for (final _ in parts) null], [for (final _ in parts) const {}], [for (final p in parts) p.divisions]);

  void _markFrom(int m) => _changedFrom = _changedFrom == null ? m : math.min(_changedFrom!, m);

  // MARK: Writing out

  /// The score as MusicXML, without the editor's ids (a file's own given back).
  String toMusicXML() => _document
      .toXmlString()
      .replaceAll(RegExp(r' id="cxe\d+"'), '')
      .replaceAll(' cxe-orig="', ' id="');

  late final String _header = () {
    final root = _document.rootElement;
    final b = StringBuffer();
    for (final child in root.childElements) {
      if (child.name.local == 'part' || child.name.local == 'credit') continue;
      b.write(child.toXmlString());
    }
    return b.toString();
  }();

  /// Bars [from] to [to] (exclusive) as a score of their own, ids kept, for the editor's
  /// engraving: the first starts with what is in force there (clefs, key, time, divisions,
  /// transposition). What the first bar changes is said: [timeShown] whether the time signature,
  /// [clefsShown] and [keysShown] the staves (numbered across the parts) whose clef or key.
  ({String xml, bool timeShown, Set<int> clefsShown, Set<int> keysShown}) chunk(int from, int to) {
    final version = _document.rootElement.getAttribute('version') ?? '4.0';
    final b = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><score-partwise version="$version">')..write(_header);
    var timeShown = from == 0;
    final clefsShown = <int>{}, keysShown = <int>{};
    var staff = 0; // staves of the parts before, as Verovio numbers them
    for (final part in parts) {
      b.write('<part id="${_escape(part.id)}">');
      for (var m = from; m < to && m < part._measures.length; m++) {
        final measure = part._measures[m];
        if (m == from && from > 0) {
          // What the bar itself changes, against what was in force before it: shown at the
          // chunk's start; what is only carried in is not.
          final before = _contextBefore(part, m);
          if (_attributesAtStartOrNull(measure) case final own?) {
            final after = _applyAttributes(before, own);
            final (t0, t1) = (before.meter, after.meter);
            if (t1 != null && (t0 == null || t0.beats != t1.beats || t0.beatType != t1.beatType || t0.symbol != t1.symbol)) timeShown = true;
            final keyChanged = own.getElement('key') != null && (after.key.fifths != before.key.fifths || after.key.minor != before.key.minor);
            for (var s = 1; s <= part.staves; s++) {
              if (keyChanged) keysShown.add(staff + s);
              if (after.clef(s) != before.clef(s)) clefsShown.add(staff + s);
            }
          }
          final copy = measure.copy();
          _carry(copy, _contextBefore(part, m), part.staves);
          b.write(copy.toXmlString());
        } else {
          b.write(_xml[measure] ??= measure.toXmlString());
        }
      }
      b.write('</part>');
      staff += part.staves;
    }
    b.write('</score-partwise>');
    return (xml: b.toString(), timeShown: timeShown, clefsShown: clefsShown, keysShown: keysShown);
  }

  /// Each bar as text: a bar is never changed (an edit writes another in its place), so it is
  /// written out once, not at every engraving of its chunk.
  final _xml = Expando<String>();

  static String _escape(String s) => s.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;');

  /// [measure] given what [context] has in force, where its own first `<attributes>` lacks it.
  void _carry(XmlElement measure, _Context context, int staves) {
    final a = _attributesAtStart(measure);
    void ensure(String name, List<XmlElement> Function() make, {bool Function(XmlElement)? matches}) {
      final have = a.findElements(name).where(matches ?? (_) => true);
      if (have.isNotEmpty) return;
      final order = ['footnote', 'level', 'divisions', 'key', 'time', 'staves', 'part-symbol', 'instruments', 'clef', 'staff-details', 'transpose'];
      for (final e in make()) {
        final rank = order.indexOf(name);
        final at = a.children.indexWhere((c) => c is XmlElement && order.indexOf(c.name.local) > rank);
        at < 0 ? a.children.add(e) : a.children.insert(at, e);
      }
    }

    ensure('divisions', () => [_text('divisions', '${context.divisions}')]);
    ensure('key', () => [_el('key', [_text('fifths', '${context.key.fifths}'), if (context.key.minor) _text('mode', 'minor')])]);
    if (context.meter case final meter?) ensure('time', () => [meter.toXml()]);
    if (staves > 1) ensure('staves', () => [_text('staves', '$staves')]);
    for (var s = 1; s <= staves; s++) {
      ensure('clef', () => [context.clef(s).toXml(staves > 1 ? s : null)],
          matches: (c) => (int.tryParse(c.getAttribute('number') ?? '') ?? 1) == s);
    }
    if (context.transpose case final t?) ensure('transpose', () => [t.copy()]);
  }

  static XmlElement? _attributesAtStartOrNull(XmlElement measure) {
    for (final child in measure.childElements) {
      switch (child.name.local) {
        case 'attributes':
          return child;
        case 'note' || 'backup' || 'forward':
          return null;
      }
    }
    return null;
  }

  /// [measure]'s `<attributes>` before its first note, made if it has none.
  static XmlElement _attributesAtStart(XmlElement measure) {
    if (_attributesAtStartOrNull(measure) case final a?) return a;
    final a = _el('attributes');
    var at = 0;
    for (final (i, child) in measure.children.indexed) {
      if (child is XmlElement && (child.name.local == 'print' || (child.name.local == 'barline' && child.getAttribute('location') == 'left'))) at = i + 1;
    }
    measure.children.insert(at, a);
    return a;
  }

  // MARK: Finding things

  /// The note, chord or rest whose note has [id].
  EventInfo? locate(String id) {
    final where = _where[id];
    if (where == null) return null;
    final content = _view(where.part, where.measure);
    for (final entry in content.voices.entries) {
      for (final e in entry.value) {
        if (e.notes.any((n) => n.getAttribute('id') == id)) return _info(where.part, where.measure, entry.key, e);
      }
    }
    return null;
  }

  /// Where the direction, dynamic, hairpin or slur with [id] is: its bar and part.
  ({int part, int measure})? whereIs(String id) => _where[id];

  /// Whether [id] is a note or rest's (else a direction's, a dynamic's…).
  bool isNote(String id) => locate(id) != null;

  EventInfo _info(int part, int m, VoiceKey voice, _Event e) => EventInfo(
        position: ScorePosition(part, voice, m, e.start),
        length: e.length,
        ids: [for (final n in e.notes) ?n.getAttribute('id')],
        pitches: e.isRest ? const [] : [for (final n in e.notes) ?_pitchOf(n)],
        rhythm: e.isMeasureRest ? null : _rhythmOf(e.main),
        tiedOn: e.notes.any(_tiedOn),
      );

  /// Every note, chord and rest of [voice] in bar [m], in time order.
  List<EventInfo> eventsIn(int part, int m, VoiceKey voice) => [for (final e in _view(part, m).voices[voice] ?? const <_Event>[]) _info(part, m, voice, e)];

  /// The voices that have notes in bar [m] of [part].
  List<VoiceKey> voicesIn(int part, int m) => _view(part, m).voices.keys.toList()..sort();

  /// The note, chord or rest after [e] in its voice (on into the next bars); null at the end.
  EventInfo? next(EventInfo e) {
    final p = e.position;
    for (var m = p.measure; m < measureCount; m++) {
      for (final x in eventsIn(p.part, m, p.voice)) {
        if (m > p.measure || x.position.time > p.time) return x;
      }
    }
    return null;
  }

  /// The one before it; null at the start.
  EventInfo? previous(EventInfo e) {
    final p = e.position;
    for (var m = p.measure; m >= 0; m--) {
      for (final x in eventsIn(p.part, m, p.voice).reversed) {
        if (m < p.measure || x.position.time < p.time) return x;
      }
    }
    return null;
  }

  /// What sounds in [staff] of [part] at [time] of bar [m]: [voice]'s if it has one there, else
  /// any voice's on that staff.
  EventInfo? eventAt(int part, int staff, int m, Frac time, {String? voice}) {
    final content = _view(part, m);
    final keys = content.voices.keys.where((k) => k.staff == staff).toList()..sort();
    if (voice != null) keys.sort((a, b) => (a.voice == voice ? 0 : 1).compareTo(b.voice == voice ? 0 : 1));
    for (final k in keys) {
      for (final e in content.voices[k]!) {
        if (e.start <= time && time < e.end) return _info(part, m, k, e);
      }
    }
    return null;
  }

  /// [time] of bar [m] as the start of the note or rest (of any part) that is there, when one
  /// is: a place read off the engraving ([EditGalley.timeAtX]) is only near it where the time
  /// is a seventh or a ninth (a septuplet's second note), and a note put in a hair before
  /// another would cut it short.
  Frac onsetAt(int m, Frac time) {
    for (var p = 0; p < parts.length; p++) {
      for (final e in _view(p, m).events) {
        if ((e.start - time).toDouble().abs() < 1e-3) return e.start;
      }
    }
    return time;
  }

  /// The note, chord or rest of [at]'s voice that ends where [at] is (the one just put in).
  EventInfo? eventBefore(ScorePosition at) {
    final m = at.time.isZero ? at.measure - 1 : at.measure;
    if (m < 0 || m >= measureCount) return null;
    final events = eventsIn(at.part, m, at.voice);
    final end = at.time.isZero ? barLength(m) : at.time;
    return events.where((e) => e.end == end).lastOrNull ?? events.where((e) => e.position.time < end).lastOrNull;
  }

  /// The voice a staff is written in by default: the lowest it has in bar [m] or near it, else
  /// voice 1 on the first staff and 5, 9… on the others (as exporters number them).
  VoiceKey defaultVoice(int part, int staff, int m) {
    for (var d = 0; d < 8; d++) {
      for (final i in {m - d, m + d}) {
        if (i < 0 || i >= measureCount) continue;
        final keys = _view(part, i).voices.keys.where((k) => k.staff == staff).toList()..sort();
        if (keys.isNotEmpty) return keys.first;
      }
    }
    return VoiceKey(staff, '${(staff - 1) * 4 + 1}');
  }

  /// The pitch of the last note before [at] in its voice (a few bars back at most); else the
  /// clef's middle line.
  Pitch pitchBefore(ScorePosition at) {
    for (var m = at.measure; m >= math.max(0, at.measure - 8); m--) {
      for (final e in eventsIn(at.part, m, at.voice).reversed) {
        if (m == at.measure && e.position.time >= at.time) continue;
        if (!e.isRest && e.pitches.isNotEmpty) return e.pitches.first;
      }
    }
    return clefAt(at.part, at.staff, at.measure, at.time).middle;
  }

  /// Bar [m]'s time [t] as bar and beat, for the status line.
  String describe(int m, Frac t) {
    final meter = meterAt(m), beat = meter?.beat ?? Frac.one;
    final beats = t / beat;
    final whole = beats.n ~/ beats.d, rest = beats - Frac(whole);
    return '${barNumber(m)}.${whole + 1}${rest.isZero ? '' : ' +$rest'}';
  }

  // MARK: Input

  /// Puts [items] in one after another from [at], over what was there (a note longer than what
  /// is left of a bar ties on into the next; past the last bar, bars are added). Returns where
  /// the next would go.
  ScorePosition input(ScorePosition at, List<InputItem> items) => edit(() {
        var pos = at;
        for (final item in items) {
          var remaining = item.length;
          var first = true;
          while (remaining.isPositive) {
            while (pos.measure >= measureCount) {
              addBars(measureCount, 1);
            }
            final length = barLength(pos.measure);
            if (pos.time >= length) {
              pos = pos.at(pos.measure + 1, Frac.zero);
              continue;
            }
            final piece = Frac.min(remaining, length - pos.time);
            remaining = remaining - piece;
            final rhythms = piece == item.length ? [item.rhythm] : Rhythm.express(piece, tuplet: item.rhythm.tuplet);
            final content = _mutable(pos.part, pos.measure);
            final made = <_Event>[];
            var t = pos.time;
            for (final (i, r) in rhythms.indexed) {
              final e = _makeEvent(pos.part, pos.voice, t, r, item.pitches, templates: item.templates, keepIds: first && i == 0);
              if (item.pitches.isNotEmpty) {
                final tieFrom = (first && i == 0) ? item.tieFrom : true;
                final tieOn = i < rhythms.length - 1 || remaining.isPositive;
                for (final n in e.notes) {
                  _setTie(n, 'stop', tieFrom);
                  _setTie(n, 'start', tieOn);
                }
              }
              made.add(e);
              t = t + r.length;
            }
            _overwrite(content, pos.voice, pos.time, t, made);
            _commit(pos.part, pos.measure, content, voices: [pos.voice]);
            if (first && item.tieFrom && item.pitches.isNotEmpty) _tieBack(pos);
            first = false;
            pos = t >= length ? pos.at(pos.measure + 1, Frac.zero) : pos.at(pos.measure, t);
          }
        }
        return pos;
      });

  /// The note before [at] in its voice tied on to the one at [at] (Dorico's T).
  void _tieBack(ScorePosition at) {
    final here = eventAt(at.part, at.staff, at.measure, at.time, voice: at.voice.voice);
    if (here == null) return;
    final before = previous(here);
    if (before == null || before.isRest) return;
    _editNotes(before, (notes) {
      for (final n in notes) {
        if (here.pitches.any((p) => p.midi == _pitchOf(n)?.midi)) _setTie(n, 'start', true);
      }
    });
  }

  _Event _makeEvent(int part, VoiceKey voice, Frac start, Rhythm rhythm, List<Pitch> pitches, {List<XmlElement>? templates, bool keepIds = false}) {
    final multi = parts[part].staves > 1;
    final notes = <XmlElement>[];
    if (pitches.isEmpty) {
      final note = _el('note', [_el('rest'), _text('duration', '0'), _text('voice', voice.voice)]);
      _setRhythm(note, rhythm);
      if (multi) _setNoteChild(note, 'staff', '${voice.staff}');
      notes.add(note);
    } else {
      for (final (i, pitch) in pitches.indexed) {
        final template = templates != null && i < templates.length ? templates[i] : null;
        final XmlElement note;
        if (template != null) {
          note = template.copy();
          if (!keepIds) _retag(note);
          _removeChildren(note, 'beam');
          _removeChildren(note, 'chord');
          for (final n in note.findElements('notations')) {
            for (final t in n.findElements('tuplet').toList()) {
              t.remove();
            }
          }
          if (!keepIds) {
            for (final n in note.findElements('notations')) {
              for (final s in n.findElements('slur').toList()) {
                s.remove();
              }
            }
          }
          _dropEmptyNotations(note);
          if (note.getElement('rest') != null) {
            _removeChildren(note, 'rest');
            _insertNoteChild(note, _el('pitch'));
          }
          _setPitch(note, pitch);
        } else {
          note = _el('note', [_text('duration', '0'), _text('voice', voice.voice)]);
          _setPitch(note, pitch);
        }
        _setRhythm(note, rhythm);
        _setVoice(note, voice, multi);
        notes.add(note);
      }
    }
    return _Event(start, rhythm.length, notes);
  }

  /// [made] put in [voice] from [from] to [to] over what was there: a note begun before keeps
  /// its start, shortened; what runs on past [to] is a rest from there.
  void _overwrite(_Content content, VoiceKey voice, Frac from, Frac to, List<_Event> made) {
    final events = content.voices[voice] ?? [];
    final out = <_Event>[];
    for (final e in events) {
      if (e.end <= from || e.start >= to) {
        out.add(e);
        continue;
      }
      if (e.start < from) out.addAll(_shortened(e, from - e.start));
      if (e.end > to) out.addAll(_rests(voice, to, e.end, tuplet: e.tuplet, tupletStart: _tupletStartOf(events, e)));
    }
    out.addAll(made);
    _stableSort(out, (a, b) => a.start.compareTo(b.start));
    content.voices[voice] = out;
  }

  /// Where the tuplet [e] is in starts (its first note of that tuplet in a row).
  Frac? _tupletStartOf(List<_Event> events, _Event e) {
    final t = e.tuplet;
    if (t == null) return null;
    var start = e.start;
    final i = events.indexOf(e);
    for (var k = i - 1; k >= 0; k--) {
      if (events[k].tuplet != t || events[k].end != start) break;
      start = events[k].start;
    }
    // Within its span: tuplets in a row are span after span.
    final into = e.start - start;
    final spans = (into / t.span);
    return start + t.span * Frac(spans.n ~/ spans.d);
  }

  /// [e] cut to [length]: notes tied one to the next, or rests.
  List<_Event> _shortened(_Event e, Frac length) {
    if (e.isRest) return _rests(_voiceOf(e.main), e.start, e.start + length, tuplet: e.tuplet);
    final rhythms = Rhythm.express(length, tuplet: e.tuplet);
    final out = <_Event>[];
    var t = e.start;
    final tiedFrom = e.notes.map(_tiedFrom).toList();
    for (final (i, r) in rhythms.indexed) {
      final notes = i == 0 ? e.notes : [for (final n in e.notes) n.copy()];
      if (i > 0) {
        for (final n in notes) {
          _retag(n);
          for (final lyric in n.findElements('lyric').toList()) {
            lyric.remove();
          }
        }
      }
      for (final (k, n) in notes.indexed) {
        _setRhythm(n, r);
        _setTie(n, 'stop', i > 0 || tiedFrom[k]);
        _setTie(n, 'start', i < rhythms.length - 1);
      }
      out.add(_Event(t, r.length, notes, i == 0 ? e.graces : null));
      t = t + r.length;
    }
    return out;
  }

  List<_Event> _rests(VoiceKey voice, Frac from, Frac to, {Tuplet? tuplet, Frac? tupletStart, Frac? beat}) {
    final out = <_Event>[];
    var t = from;
    for (final r in Rhythm.restsBetween(from, to, beat: beat, tuplet: tuplet, tupletStart: tupletStart)) {
      final note = _el('note', [_el('rest'), _text('duration', '0'), _text('voice', voice.voice)]);
      _setRhythm(note, r);
      out.add(_Event(t, r.length, [note]));
      t = t + r.length;
    }
    return out;
  }

  // MARK: Tidying a bar

  /// A voice made tidy after an edit: rests in a row joined, the first voice of a staff kept
  /// whole (rests in its gaps), a voice of rests only taken out (the first: a bar's rest), beams
  /// and tuplet brackets drawn again.
  void _tidy(int part, int m, _Content content, VoiceKey voice) {
    final events = content.voices[voice];
    if (events == null) return;
    final length = barLength(m);
    final meter = _contextAt(part, m, Frac.zero).meter;
    final primary = content.voices.keys.where((k) => k.staff == voice.staff && content.voices[k]!.any((e) => !e.isRest)).fold<VoiceKey?>(
            null, (a, k) => a == null || k.compareTo(a) < 0 ? k : a) ??
        content.voices.keys.where((k) => k.staff == voice.staff).reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
    final isPrimary = voice == primary;

    // Rests in a row (outside tuplets) as few as the meter allows; gaps of the first voice filled.
    final out = <_Event>[];
    var t = Frac.zero;
    var i = 0;
    while (i < events.length) {
      final e = events[i];
      if (e.start > t && isPrimary) out.addAll(_rests(voice, t, e.start, beat: meter?.beat));
      if (e.isRest && e.tuplet == null && e.graces.isEmpty && e.main.getElement('notations') == null) {
        var end = e.end;
        var k = i + 1;
        while (k < events.length &&
            events[k].start == end &&
            events[k].isRest &&
            events[k].tuplet == null &&
            events[k].graces.isEmpty &&
            events[k].main.getElement('notations') == null) {
          end = events[k].end;
          k++;
        }
        if (k > i + 1 || e.isMeasureRest || !(_rhythmOf(e.main)?.length == e.length)) {
          out.addAll(_rests(voice, e.start, end, beat: meter?.beat));
        } else {
          out.add(e);
        }
        t = end;
        i = k;
        continue;
      }
      out.add(e);
      t = e.end;
      i++;
    }
    if (isPrimary && t < length) out.addAll(_rests(voice, t, length, beat: meter?.beat));

    if (out.every((e) => e.isRest) && out.every((e) => e.main.getElement('notations') == null)) {
      if (!isPrimary || content.voices.keys.any((k) => k.staff == voice.staff && k != voice && content.voices[k]!.any((e) => !e.isRest))) {
        content.voices.remove(voice);
        return;
      }
      // A bar's rest.
      final note = _el('note', [_el('rest', const [], {'measure': 'yes'}), _text('duration', '0'), _text('voice', voice.voice)]);
      content.voices[voice] = [_Event(Frac.zero, length, [note])];
      return;
    }
    content.voices[voice] = out;
    _rebeam(out, meter, length);
    _bracketTuplets(out);
  }

  /// Beams for [events]: eighths and shorter beamed within each beat group, broken by rests.
  void _rebeam(List<_Event> events, TimeSig? meter, Frac barLength) {
    for (final e in events) {
      for (final n in e.notes) {
        _removeChildren(n, 'beam');
      }
    }
    final groups = meter?.beamGroups ?? [barLength];
    int groupOf(Frac t) {
      var edge = Frac.zero;
      for (final (i, g) in groups.indexed) {
        edge = edge + g;
        if (t < edge) return i;
      }
      return groups.length;
    }

    int beamsOf(_Event e) => e.isRest ? 0 : (_rhythmOf(e.main)?.type.beams ?? 0);
    var run = <_Event>[];
    void flush() {
      if (run.length >= 2) {
        final depth = run.map(beamsOf).reduce(math.max);
        for (var level = 1; level <= depth; level++) {
          for (var k = 0; k < run.length; k++) {
            if (beamsOf(run[k]) < level) continue;
            final before = k > 0 && beamsOf(run[k - 1]) >= level, after = k < run.length - 1 && beamsOf(run[k + 1]) >= level;
            final value = level == 1
                ? (k == 0 ? 'begin' : k == run.length - 1 ? 'end' : 'continue')
                : before && after
                    ? 'continue'
                    : before
                        ? 'end'
                        : after
                            ? 'begin'
                            : (k == 0 ? 'forward hook' : 'backward hook');
            _insertNoteChild(run[k].main, _text('beam', value, {'number': '$level'}));
          }
        }
      }
      run = [];
    }

    for (final e in events) {
      final beamable = beamsOf(e) > 0 && e.graces.isEmpty;
      if (!beamable) {
        flush();
        continue;
      }
      if (run.isNotEmpty && (groupOf(e.start) != groupOf(run.first.start) || run.last.end != e.start)) flush();
      run.add(e);
    }
    flush();
  }

  /// Tuplet brackets drawn again over [events]: a run of one ratio, span by span.
  void _bracketTuplets(List<_Event> events) {
    for (final e in events) {
      for (final n in e.main.findElements('notations')) {
        for (final t in n.findElements('tuplet').toList()) {
          t.remove();
        }
      }
      _dropEmptyNotations(e.main);
    }
    var i = 0;
    while (i < events.length) {
      final t = events[i].tuplet;
      if (t == null) {
        i++;
        continue;
      }
      final start = events[i].start, end = start + t.span;
      var k = i;
      while (k + 1 < events.length && events[k + 1].tuplet == t && events[k + 1].start < end && events[k + 1].start == events[k].end) {
        k++;
      }
      _notations(events[i].main).children.add(_el('tuplet', const [], {'type': 'start', 'bracket': events.sublist(i, k + 1).every((e) => !e.isRest && _beamsOfType(e) > 0) ? 'no' : 'yes'}));
      _notations(events[k].main).children.add(_el('tuplet', const [], {'type': 'stop'}));
      i = k + 1;
    }
  }

  static int _beamsOfType(_Event e) => _rhythmOf(e.main)?.type.beams ?? 0;

  /// Accidentals on [staff] of bar [m] as its key and the notes before them in the bar ask; a
  /// cautionary one kept.
  void _respell(int part, int m, _Content content, int staff) {
    final fifths = _contextAt(part, m, Frac.zero).key.fifths;
    final events = [
      for (final entry in content.voices.entries)
        if (entry.key.staff == staff) ...entry.value,
    ];
    _stableSort(events, (a, b) => a.start.compareTo(b.start));
    final state = <int, int>{};
    for (final e in events) {
      if (e.isRest) continue;
      for (final note in e.notes) {
        if (note.getElement('unpitched') != null) continue;
        final p = _pitchOf(note);
        if (p == null) continue;
        final current = state[p.diatonic] ?? Pitch.keyAlter(p.step, fifths);
        final existing = note.getElement('accidental');
        final kept = existing != null && (existing.getAttribute('cautionary') == 'yes' || existing.getAttribute('editorial') == 'yes' || existing.getAttribute('parentheses') == 'yes');
        String? want;
        if (_tiedFrom(note)) {
          want = null; // a tied note says nothing
          if (e.start.isPositive) state[p.diatonic] = p.alter;
        } else if (p.alter != current) {
          want = switch (p.alter) { -2 => 'flat-flat', -1 => 'flat', 1 => 'sharp', 2 => 'double-sharp', _ => 'natural' };
          state[p.diatonic] = p.alter;
        }
        if (want == null && kept) continue;
        if (existing?.innerText.trim() == want && want != null) continue;
        _removeChildren(note, 'accidental');
        if (want != null) _insertNoteChild(note, _text('accidental', want));
      }
    }
  }

  // MARK: Editing notes

  /// [e]'s notes changed by [change], then its bar tidied.
  void _editNotes(EventInfo e, void Function(List<XmlElement> notes) change) => edit(() {
        final p = e.position;
        final content = _mutable(p.part, p.measure);
        final event = content.voices[p.voice]?.where((x) => x.start == p.time).firstOrNull;
        if (event == null) return;
        change(event.notes);
        _commit(p.part, p.measure, content, voices: [p.voice]);
      });

  /// The events of [ids] (notes, chords, rests), each once, in score order.
  List<EventInfo> eventsOf(Iterable<String> ids) {
    final seen = <String>{};
    final out = <EventInfo>[];
    for (final id in ids) {
      final e = locate(id);
      if (e == null || !seen.add(e.ids.first)) continue;
      out.add(e);
    }
    out.sort((a, b) {
      final p = a.position, q = b.position;
      if (p.part != q.part) return p.part.compareTo(q.part);
      if (p.measure != q.measure) return p.measure.compareTo(q.measure);
      if (p.time != q.time) return p.time.compareTo(q.time);
      return p.voice.compareTo(q.voice);
    });
    return out;
  }

  /// Deletes what [ids] are: a note becomes a rest (one of a chord only leaves it), a rest in a
  /// voice of its own goes, a direction, dynamic, hairpin or slur is taken out.
  void delete(Iterable<String> ids) => edit(() {
        final notes = <String>{}, others = <String>{};
        for (final id in ids) {
          (isNote(id) ? notes : others).add(id);
        }
        for (final id in others) {
          _deleteMarking(id);
        }
        for (final e in eventsOf(notes)) {
          final current = locate(e.ids.first);
          if (current == null) continue;
          final chosen = current.ids.where(notes.contains).toSet();
          final p = current.position;
          final content = _mutable(p.part, p.measure);
          final events = content.voices[p.voice]!;
          final index = events.indexWhere((x) => x.start == p.time);
          final event = events[index];
          if (!event.isRest && chosen.length < event.notes.length) {
            event.notes.removeWhere((n) => chosen.contains(n.getAttribute('id')));
          } else {
            final rests = _rests(p.voice, event.start, event.end, tuplet: event.tuplet, tupletStart: _tupletStartOf(events, event));
            events
              ..removeAt(index)
              ..insertAll(index, rests);
          }
          _commit(p.part, p.measure, content, voices: [p.voice]);
        }
      });

  void _deleteMarking(String id) {
    final where = _where[id];
    if (where == null) return;
    final content = _mutable(where.part, where.measure);
    XmlElement? found;
    for (final o in content.others) {
      if (o.element.getAttribute('id') == id) found = o.element;
      for (final d in o.element.descendantElements) {
        if (d.getAttribute('id') == id) found = d;
      }
    }
    for (final e in content.events) {
      for (final n in e.notes) {
        for (final d in n.descendantElements) {
          if (d.getAttribute('id') == id) found = d;
        }
      }
    }
    if (found == null) return;
    switch (found.name.local) {
      case 'slur':
        final number = found.getAttribute('number') ?? '1';
        final note = found.ancestors.whereType<XmlElement>().firstWhere((a) => a.name.local == 'note');
        found.remove();
        for (final n in note.findElements('notations')) {
          if (n.childElements.isEmpty) n.remove();
        }
        _commit(where.part, where.measure, content);
        _removeStop(where.part, where.measure, (e) => e.name.local == 'slur' && e.getAttribute('type') == 'stop' && (e.getAttribute('number') ?? '1') == number,
            after: _timeOfNote(content, note));
      case 'wedge':
        final number = found.getAttribute('number') ?? '1';
        final direction = found.ancestors.whereType<XmlElement>().firstWhere((a) => a.name.local == 'direction');
        final time = content.others.firstWhere((o) => o.element == direction).time;
        content.others.removeWhere((o) => o.element == direction);
        _commit(where.part, where.measure, content);
        _removeStop(where.part, where.measure, (e) => e.name.local == 'wedge' && e.getAttribute('type') == 'stop' && (e.getAttribute('number') ?? '1') == number,
            after: time, whole: true);
      default:
        final direction = found.name.local == 'direction' ? found : found.ancestors.whereType<XmlElement>().where((a) => a.name.local == 'direction').firstOrNull;
        if (direction == null) return;
        content.others.removeWhere((o) => o.element == direction);
        _commit(where.part, where.measure, content);
    }
  }

  Frac _timeOfNote(_Content content, XmlElement note) {
    for (final e in content.events) {
      if (e.notes.contains(note)) return e.start;
    }
    return Frac.zero;
  }

  /// Takes out the first element [matches] after [after] in bar [m] of [part] or the bars after
  /// (the end of a slur or hairpin); [whole]: its direction with it.
  void _removeStop(int part, int m, bool Function(XmlElement) matches, {required Frac after, bool whole = false}) {
    for (var i = m; i < measureCount && i < m + 64; i++) {
      final view = _view(part, i);
      final candidates = <(Frac, XmlElement)>[
        for (final o in view.others)
          for (final d in o.element.descendantElements)
            if (matches(d)) (o.time, d),
        for (final e in view.events)
          for (final n in e.notes)
            for (final d in n.descendantElements)
              if (matches(d)) (e.start, d),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      for (final (t, _) in candidates) {
        if (i == m && t < after) continue;
        final content = _mutable(part, i);
        for (final o in [...content.others]) {
          if (o.time != t) continue;
          final d = o.element.descendantElements.where(matches).firstOrNull;
          if (d == null) continue;
          if (whole) {
            content.others.remove(o);
          } else {
            d.remove();
          }
          _commit(part, i, content);
          return;
        }
        for (final e in content.events) {
          if (e.start != t) continue;
          for (final n in e.notes) {
            final d = n.descendantElements.where(matches).firstOrNull;
            if (d == null) continue;
            d.remove();
            _dropEmptyNotations(n);
            _commit(part, i, content);
            return;
          }
        }
      }
    }
  }

  /// Notes of [ids] given [type] (and [dots]): each starting where it did, over what follows
  /// (tied on past the barline), or followed by a rest if shorter (Dorico's duration keys).
  void setRhythm(Iterable<String> ids, NoteType type, {int? dots}) => edit(() {
        for (final e in eventsOf(ids).reversed.toList()) {
          final current = locate(e.ids.first);
          if (current == null) continue;
          final rhythm = Rhythm(type, dots: dots ?? (current.rhythm?.type == type ? current.rhythm!.dots : 0), tuplet: current.rhythm?.tuplet);
          _respace(current, rhythm);
        }
      });

  /// Each note of [ids] with a dot or without (`.`).
  void toggleDot(Iterable<String> ids) => edit(() {
        for (final e in eventsOf(ids).reversed.toList()) {
          final current = locate(e.ids.first);
          final r = current?.rhythm;
          if (current == null || r == null) continue;
          _respace(current, r.withDots(r.dots == 0 ? 1 : 0));
        }
      });

  void _respace(EventInfo e, Rhythm rhythm) {
    final view = _view(e.position.part, e.position.measure).voices[e.position.voice]!.firstWhere((x) => x.start == e.position.time);
    input(e.position, [InputItem(rhythm, e.pitches, templates: e.isRest ? null : view.notes, tieFrom: view.notes.any(_tiedFrom))]);
  }

  /// Notes of [ids] moved [steps] staff positions (within the key: Dorico's ⌥↑ / ⌥↓), or by
  /// [octaves], keeping their accidentals.
  void transpose(Iterable<String> ids, {int steps = 0, int octaves = 0}) => edit(() {
        final chosen = {...ids};
        for (final e in eventsOf(ids)) {
          if (e.isRest) continue;
          final key = keyAt(e.position.part, e.position.measure, e.position.time).fifths;
          _editNotes(e, (notes) {
            for (final n in notes) {
              if (!chosen.contains(n.getAttribute('id'))) continue;
              final p = _pitchOf(n);
              if (p == null) continue;
              final moved = octaves != 0 ? Pitch(p.step, p.octave + octaves, p.alter) : Pitch.fromDiatonic(p.diatonic + steps);
              _setPitch(n, octaves != 0 ? moved : moved.withAlter(Pitch.keyAlter(moved.step, key)));
            }
          });
        }
      });

  /// Notes of [ids] given [alter] (−1 a flat, 0 a natural, 1 a sharp: Dorico's − 0 =).
  void setAlter(Iterable<String> ids, int alter) => edit(() {
        final chosen = {...ids};
        for (final e in eventsOf(ids)) {
          if (e.isRest) continue;
          _editNotes(e, (notes) {
            for (final n in notes) {
              if (!chosen.contains(n.getAttribute('id'))) continue;
              final p = _pitchOf(n);
              if (p != null && n.getElement('pitch') != null) _setPitch(n, p.withAlter(alter));
            }
          });
        }
      });

  /// [pitch] added to the chord or rest at [at] (a rest becomes the note).
  void addToChord(ScorePosition at, Pitch pitch) => edit(() {
        final e = eventAt(at.part, at.staff, at.measure, at.time, voice: at.voice.voice);
        if (e == null) return;
        if (e.pitches.any((p) => p.midi == pitch.midi && p.step == pitch.step)) return;
        if (e.isRest) {
          final r = e.rhythm ?? Rhythm.express(e.length).first;
          input(e.position, [InputItem(r, [pitch])]);
          return;
        }
        _editNotes(e, (notes) {
          final note = notes.first.copy();
          _retag(note);
          for (final x in ['lyric', 'notations', 'beam', 'accidental']) {
            _removeChildren(note, x);
          }
          _setPitch(note, pitch);
          for (final t in notes.first.findElements('tie')) {
            _setTie(note, t.getAttribute('type') ?? 'start', true);
          }
          notes.add(note);
        });
      });

  /// Each note of [ids] tied on to the next of its pitch in its voice, or its tie taken off.
  void toggleTie(Iterable<String> ids) => edit(() {
        for (final e in eventsOf(ids).reversed.toList()) {
          if (e.isRest) continue;
          final after = next(e);
          if (e.tiedOn) {
            _editNotes(e, (notes) {
              for (final n in notes) {
                _setTie(n, 'start', false);
              }
            });
            if (after != null && !after.isRest) {
              _editNotes(after, (notes) {
                for (final n in notes) {
                  _setTie(n, 'stop', false);
                }
              });
            }
            continue;
          }
          if (after == null || after.isRest) continue;
          final shared = {for (final p in e.pitches) p.midi}.intersection({for (final p in after.pitches) p.midi});
          if (shared.isEmpty) continue;
          _editNotes(e, (notes) {
            for (final n in notes) {
              if (shared.contains(_pitchOf(n)?.midi)) _setTie(n, 'start', true);
            }
          });
          _editNotes(after, (notes) {
            for (final n in notes) {
              if (shared.contains(_pitchOf(n)?.midi)) _setTie(n, 'stop', true);
            }
          });
        }
      });

  /// A slur from the first of [ids]'s notes to the last (in the first one's voice), or the one
  /// there taken off.
  void toggleSlur(Iterable<String> ids) => edit(() {
        final events = eventsOf(ids).where((e) => !e.isRest).toList();
        if (events.isEmpty) return;
        final first = events.first;
        final same = events.where((e) => e.position.part == first.position.part && e.position.voice == first.position.voice).toList();
        final last = same.length > 1 ? same.last : next(first);
        if (last == null || last.isRest) return;
        final view = _view(first.position.part, first.position.measure).voices[first.position.voice]!.firstWhere((x) => x.start == first.position.time);
        final starts = view.main.findElements('notations').expand((n) => n.findElements('slur')).where((s) => s.getAttribute('type') == 'start').toList();
        if (starts.isNotEmpty) {
          _deleteMarking(starts.first.getAttribute('id') ?? '');
          return;
        }
        _editNotes(first, (notes) => _notations(notes.first).children.add(_el('slur', const [], {'type': 'start', 'number': '1'})));
        _editNotes(last, (notes) => _notations(notes.first).children.add(_el('slur', const [], {'type': 'stop', 'number': '1'})));
      });

  /// [name] (an articulation: `accent`, `staccato`, `tenuto`, `strong-accent`, `staccatissimo`,
  /// `breath-mark`, `caesura`; a `fermata`; an ornament: `trill-mark`, `mordent`,
  /// `inverted-mordent`, `turn`) put on each note of [ids], or taken off if all have it.
  void toggleMark(Iterable<String> ids, String name, {Map<String, String> attributes = const {}}) => edit(() {
        final events = eventsOf(ids).where((e) => !e.isRest || name == 'fermata').toList();
        if (events.isEmpty) return;
        final group = switch (name) {
          'fermata' => null,
          'trill-mark' || 'mordent' || 'inverted-mordent' || 'turn' => 'ornaments',
          _ => 'articulations',
        };
        bool hasIt(XmlElement note) => note.findElements('notations').any((n) =>
            group == null ? n.findElements(name).isNotEmpty : n.findElements(group).any((g) => g.findElements(name).isNotEmpty));
        final all = events.every((e) {
          final view = _view(e.position.part, e.position.measure).voices[e.position.voice]!.firstWhere((x) => x.start == e.position.time);
          return hasIt(view.main);
        });
        for (final e in events) {
          _editNotes(e, (notes) {
            final note = notes.first;
            if (all) {
              for (final n in note.findElements('notations')) {
                if (group == null) {
                  _removeChildren(n, name);
                } else {
                  for (final g in n.findElements(group)) {
                    _removeChildren(g, name);
                  }
                }
              }
              _dropEmptyNotations(note);
            } else if (!hasIt(note)) {
              final n = _notations(note);
              final mark = _el(name, const [], attributes);
              if (group == null) {
                n.children.add(mark);
              } else {
                var g = n.getElement(group);
                if (g == null) n.children.add(g = _el(group));
                g.children.add(mark);
              }
            }
          });
        }
      });

  /// [text] as the lyric (verse [verse]) of the note [id]; a trailing `-` joins it to the next
  /// syllable. Empty takes it off.
  void setLyric(String id, String text, {int verse = 1}) => edit(() {
        final e = locate(id);
        if (e == null || e.isRest) return;
        final before = previous(e);
        var hyphenBefore = false;
        if (before != null && !before.isRest) {
          final view = _view(before.position.part, before.position.measure).voices[before.position.voice]!.firstWhere((x) => x.start == before.position.time);
          final lyric = view.main.findElements('lyric').where((l) => (l.getAttribute('number') ?? '1') == '$verse').firstOrNull;
          final syllabic = lyric == null ? null : _childText(lyric, 'syllabic')?.trim();
          hyphenBefore = syllabic == 'begin' || syllabic == 'middle';
        }
        var t = text.trim();
        final hyphenAfter = t.endsWith('-');
        if (hyphenAfter) t = t.substring(0, t.length - 1).trim();
        _editNotes(e, (notes) {
          final note = notes.first;
          for (final l in note.findElements('lyric').where((l) => (l.getAttribute('number') ?? '1') == '$verse').toList()) {
            l.remove();
          }
          if (t.isEmpty) return;
          final syllabic = hyphenBefore && hyphenAfter
              ? 'middle'
              : hyphenBefore
                  ? 'end'
                  : hyphenAfter
                      ? 'begin'
                      : 'single';
          _insertNoteChild(note, _el('lyric', [_text('syllabic', syllabic), _text('text', t)], {'number': '$verse'}));
        });
      });

  /// The lyric (verse [verse]) of the note [id], as typed: a `-` after a syllable joined on.
  String lyricOf(String id, {int verse = 1}) {
    final e = locate(id);
    if (e == null) return '';
    final view = _view(e.position.part, e.position.measure).voices[e.position.voice]!.firstWhere((x) => x.start == e.position.time);
    final lyric = view.main.findElements('lyric').where((l) => (l.getAttribute('number') ?? '1') == '$verse').firstOrNull;
    if (lyric == null) return '';
    final syllabic = _childText(lyric, 'syllabic')?.trim();
    return '${_childText(lyric, 'text') ?? ''}${syllabic == 'begin' || syllabic == 'middle' ? '-' : ''}';
  }

  // MARK: Markings

  /// A direction at [at] (its staff): [types] are its `<direction-type>`s' contents.
  void addDirection(ScorePosition at, List<XmlElement> types, {String placement = 'above', XmlElement? sound}) => edit(() {
        final content = _mutable(at.part, at.measure);
        final direction = _el('direction', [
          for (final t in types) _el('direction-type', [t]),
          if (parts[at.part].staves > 1) _text('staff', '${at.staff}'),
          ?sound,
        ], {'placement': placement});
        _insertOther(content, at.time, direction);
        _commit(at.part, at.measure, content);
      });

  /// [element] among [content]'s others at [time], after those there already.
  void _insertOther(_Content content, Frac time, XmlElement element) {
    var at = content.others.length;
    for (final (i, o) in content.others.indexed) {
      if (o.time > time) {
        at = i;
        break;
      }
    }
    content.others.insert(at, _Other(time, element));
  }

  /// A dynamic ([mark]: `p`, `mf`, `sfz`…) at [at], below the staff.
  void addDynamic(ScorePosition at, String mark) => addDirection(at, [_el('dynamics', [_el(mark)])], placement: 'below');

  /// The dynamics MusicXML has an element for.
  static const dynamics = {
    'pppppp', 'ppppp', 'pppp', 'ppp', 'pp', 'p', 'mp', 'mf', 'f', 'ff', 'fff', 'ffff', 'fffff', 'ffffff', //
    'fp', 'fz', 'pf', 'rf', 'rfz', 'sf', 'sffz', 'sfp', 'sfpp', 'sfz', 'sfzp', 'n',
  };

  /// A hairpin (`crescendo` or `diminuendo`) from [from] to [to] (a time in a later bar may be
  /// its end), below the staff.
  void addHairpin(ScorePosition from, ScorePosition to, {required bool crescendo}) => edit(() {
        final stop = _el('direction', [
          _el('direction-type', [_el('wedge', const [], {'type': 'stop', 'number': '1'})]),
          if (parts[from.part].staves > 1) _text('staff', '${from.staff}'),
        ], {'placement': 'below'});
        final content = _mutable(to.part, to.measure);
        _insertOther(content, to.time, stop);
        _commit(to.part, to.measure, content);
        addDirection(from, [_el('wedge', const [], {'type': crescendo ? 'crescendo' : 'diminuendo', 'number': '1'})], placement: 'below');
      });

  /// A tempo at [at] (on the top staff of the first part): [words] and a metronome mark of
  /// [perMinute] [unit]s (dotted: [dotted]); either may be missing.
  void addTempo(ScorePosition at, {String? words, NoteType unit = NoteType.quarter, bool dotted = false, double? perMinute}) {
    if ((words == null || words.isEmpty) && perMinute == null) return;
    final types = <XmlElement>[
      if (words != null && words.isNotEmpty) _text('words', words, {'font-weight': 'bold'}),
      if (perMinute != null)
        _el('metronome', [_text('beat-unit', unit.type), if (dotted) _el('beat-unit-dot'), _text('per-minute', _number(perMinute))], {'parentheses': 'no'}),
    ];
    final quarters = Rhythm(unit, dots: dotted ? 1 : 0).plainLength.toDouble();
    addDirection(ScorePosition(0, defaultVoice(0, 1, at.measure), at.measure, at.time), types,
        sound: perMinute == null ? null : _el('sound', const [], {'tempo': _number(perMinute * quarters)}));
  }

  static String _number(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2);

  /// Text above the staff at [at].
  void addText(ScorePosition at, String text, {bool below = false, bool italic = false}) =>
      addDirection(at, [_text('words', text, {if (italic) 'font-style': 'italic'})], placement: below ? 'below' : 'above');

  // MARK: Clefs, keys, time signatures

  /// [clef] on [at]'s staff from [at] on.
  void setClef(ScorePosition at, Clef clef) => edit(() {
        final p = parts[at.part];
        final content = _mutable(at.part, at.measure);
        final number = p.staves > 1 ? at.staff : null;
        if (at.time.isZero) {
          final a = _startAttributes(content);
          for (final c in a.findElements('clef').where((c) => (int.tryParse(c.getAttribute('number') ?? '') ?? 1) == at.staff).toList()) {
            c.remove();
          }
          _insertAttribute(a, clef.toXml(number));
        } else {
          content.others.removeWhere((o) =>
              o.time == at.time &&
              o.element.name.local == 'attributes' &&
              o.element.childElements.every((c) => c.name.local == 'clef' && (int.tryParse(c.getAttribute('number') ?? '') ?? 1) == at.staff));
          _insertOther(content, at.time, _el('attributes', [clef.toXml(number)]));
        }
        _commit(at.part, at.measure, content);
      });

  /// The `<attributes>` at [content]'s start, made if it has none.
  XmlElement _startAttributes(_Content content) {
    for (final o in content.others) {
      if (o.time.isPositive) break;
      if (o.element.name.local == 'attributes') return o.element;
    }
    final a = _el('attributes');
    var at = 0;
    for (final (i, o) in content.others.indexed) {
      if (o.time.isPositive) break;
      if (o.element.name.local == 'print' || (o.element.name.local == 'barline' && o.element.getAttribute('location') == 'left')) at = i + 1;
    }
    content.others.insert(at, _Other(Frac.zero, a));
    return a;
  }

  static void _insertAttribute(XmlElement attributes, XmlElement child) {
    const order = ['footnote', 'level', 'divisions', 'key', 'time', 'staves', 'part-symbol', 'instruments', 'clef', 'staff-details', 'transpose', 'directive', 'measure-style'];
    final rank = order.indexOf(child.name.local);
    final at = attributes.children.indexWhere((c) => c is XmlElement && order.indexOf(c.name.local) > rank);
    at < 0 ? attributes.children.add(child) : attributes.children.insert(at, child);
  }

  /// The key [key] (concert pitch) from bar [m] on, in every part but those on a percussion
  /// clef, each written in its own transposition.
  void setKey(int m, KeySig key) => edit(() {
        final end = _nextChange(m, 'key');
        for (final (i, p) in parts.indexed) {
          final context = _contextAt(i, m, Frac.zero);
          if (context.clefs.values.isNotEmpty && context.clefs.values.every((c) => c.isPercussion)) continue;
          final written = (key.fifths + _fifthsOf(context.transpose)).clamp(-7, 7);
          final content = _mutable(i, m);
          final a = _startAttributes(content);
          _removeChildren(a, 'key');
          _insertAttribute(a, _el('key', [_text('fifths', '$written'), if (key.minor) _text('mode', 'minor')]));
          _commit(i, m, content);
          // Accidentals follow the new key up to the next one.
          for (var k = m; k < end; k++) {
            final c = _mutable(i, k);
            for (var s = 1; s <= p.staves; s++) {
              _respell(i, k, c, s);
            }
            _commit(i, k, c);
          }
        }
      });

  /// How many fifths a part's transposition moves its written key: a B♭ instrument's is two
  /// sharps more than concert pitch.
  static int _fifthsOf(XmlElement? transpose) {
    if (transpose == null) return 0;
    final chromatic = int.tryParse(_childText(transpose, 'chromatic')?.trim() ?? '') ?? 0;
    var f = (-chromatic * 7) % 12;
    if (f > 6) f -= 12;
    return f;
  }

  /// The bar after [m] that changes [what] (`key`, `time`), or the end.
  int _nextChange(int m, String what) {
    for (var k = m + 1; k < measureCount; k++) {
      for (final p in parts) {
        if (_attributesAtStartOrNull(p._measures[k])?.getElement(what) != null) return k;
      }
    }
    return measureCount;
  }

  /// The time signature [meter] from bar [m] on, in every part: the bars up to the next time
  /// signature hold as much as it says (what runs past is cut, a bar short is filled with rests).
  void setTime(int m, TimeSig meter) => edit(() {
        final end = _nextChange(m, 'time');
        for (var i = 0; i < parts.length; i++) {
          final content = _mutable(i, m);
          final a = _startAttributes(content);
          _removeChildren(a, 'time');
          _insertAttribute(a, meter.toXml());
          _commit(i, m, content);
        }
        for (var k = m; k < end; k++) {
          _fitBar(k, meter.length);
        }
      });

  /// Bar [m] of every part made [length] long.
  void _fitBar(int m, Frac length) {
    if (parts.first._measures[m].getAttribute('implicit') == 'yes') return;
    for (var i = 0; i < parts.length; i++) {
      final content = _mutable(i, m);
      for (final voice in content.voices.keys.toList()) {
        final events = content.voices[voice]!;
        final kept = <_Event>[];
        for (final e in events) {
          if (e.isMeasureRest) {
            e.length = length;
            kept.add(e);
          } else if (e.end <= length) {
            kept.add(e);
          } else if (e.start < length) {
            kept.addAll(_shortened(e, length - e.start));
          }
        }
        content.voices[voice] = kept;
      }
      content.others.removeWhere((o) => o.time > length && o.element.name.local != 'barline');
      _commit(i, m, content, voices: content.voices.keys.toList());
    }
  }

  // MARK: Bars

  /// [count] empty bars put in before bar [at] (at [measureCount]: added at the end), each a
  /// bar's rest on every staff, as long as the time signature in force says.
  void addBars(int at, int count) => edit(() {
        if (count <= 0) return;
        final index = at.clamp(0, measureCount);
        final atEnd = index == measureCount;
        final reference = index == 0 ? 0 : index - 1;
        final length = index < measureCount ? (meterAt(index)?.length ?? barLength(index)) : (meterAt(reference)?.length ?? barLength(reference));
        for (final (i, p) in parts.indexed) {
          _ensureDivisions(p, [length]);
          final made = <XmlElement>[];
          for (var k = 0; k < count; k++) {
            final shell = _el('measure', const [], {'number': '0'});
            final c = _Content();
            if (index == 0 && k == 0) {
              // Before the first bar: what the score began with leads the new first bar.
              if (_attributesAtStartOrNull(p._measures.first) case final a?) c.others.add(_Other(Frac.zero, a.copy()));
            }
            for (var s = 1; s <= p.staves; s++) {
              final voice = _voiceNear(i, s, reference) ?? VoiceKey(s, '${(s - 1) * 4 + 1}');
              final note = _el('note', [_el('rest', const [], {'measure': 'yes'}), _text('duration', '0'), _text('voice', voice.voice)]);
              c.voices[voice] = [_Event(Frac.zero, length, [note])];
            }
            final written = _write(shell, c, p.divisions, multiStaff: p.staves > 1);
            _tagIn(written);
            made.add(written);
          }
          if (index == 0) {
            final first = p._measures.first.copy();
            _attributesAtStartOrNull(first)?.remove();
            p._measures.first.replace(first);
            p._measures[0] = first;
          }
          if (atEnd) {
            // A final barline stays at the end.
            bool isEnd(XmlElement b) => (b.getAttribute('location') ?? 'right') == 'right' && b.getElement('repeat') == null;
            final last = p._measures.last;
            final ending = last.findElements('barline').where(isEnd).firstOrNull;
            if (ending != null) {
              final copy = last.copy();
              copy.findElements('barline').where(isEnd).toList().forEach((b) => b.remove());
              last.replace(copy);
              p._measures[p._measures.length - 1] = copy;
              made.last.children.add(ending.copy());
            }
          }
          for (final (k, measure) in made.indexed) {
            if (index + k < p._measures.length) {
              p.element.children.insert(p.element.children.indexOf(p._measures[index + k]), measure);
            } else {
              p.element.children.add(measure);
            }
            p._measures.insert(index + k, measure);
          }
          p._contexts = null;
        }
        _renumber();
        _indexFrom(math.max(0, index - 1));
        _markFrom(math.max(0, index - 1));
      });

  VoiceKey? _voiceNear(int part, int staff, int m) {
    if (m < 0 || m >= measureCount) return null;
    final keys = _view(part, m).voices.keys.where((k) => k.staff == staff).toList()..sort();
    return keys.firstOrNull;
  }

  /// Bars [from] to [from] + [count] taken out of every part (never all of them): the clefs,
  /// key, time and divisions they set carry on to the bar after, unless it sets its own.
  void deleteBars(int from, int count) => edit(() {
        final to = math.min(measureCount, from + count);
        if (from < 0 || from >= to || to - from >= measureCount) return;
        for (final p in parts) {
          // What the deleted bars set, the last of each (a clef by its staff).
          final carried = <String, XmlElement>{};
          for (var k = from; k < to; k++) {
            for (final child in _attributesAtStartOrNull(p._measures[k])?.childElements ?? const <XmlElement>[]) {
              carried['${child.name.local}#${child.getAttribute('number') ?? ''}'] = child;
            }
          }
          if (to < measureCount && carried.isNotEmpty) {
            final copy = p._measures[to].copy();
            final a = _attributesAtStart(copy);
            for (final MapEntry(key: key, value: child) in carried.entries) {
              final has = a.childElements.any((c) => '${c.name.local}#${c.getAttribute('number') ?? ''}' == key);
              if (!has) _insertAttribute(a, child.copy());
            }
            p._measures[to].replace(copy);
            p._measures[to] = copy;
          }
          if (to >= measureCount && from > 0) {
            // The last bars go: their final barline moves to the bar that is last now.
            bool isEnd(XmlElement b) => (b.getAttribute('location') ?? 'right') == 'right';
            final ending = p._measures.last.findElements('barline').where(isEnd).firstOrNull;
            if (ending != null) {
              final before = p._measures[from - 1].copy();
              before.findElements('barline').where(isEnd).toList().forEach((b) => b.remove());
              before.children.add(ending.copy());
              p._measures[from - 1].replace(before);
              p._measures[from - 1] = before;
            }
          }
          for (var k = to - 1; k >= from; k--) {
            _unindexMeasure(parts.indexOf(p), k, p._measures[k]);
            p._measures[k].remove();
            p._measures.removeAt(k);
          }
          p._contexts = null;
        }
        _renumber();
        _indexFrom(math.max(0, from - 1));
        _markFrom(math.max(0, from - 1));
      });

  /// Bars numbered again from the first, an upbeat (`implicit`) as 0.
  void _renumber() {
    for (final p in parts) {
      var n = p._measures.first.getAttribute('implicit') == 'yes' ? 0 : 1;
      for (var m = 0; m < p._measures.length; m++) {
        final measure = p._measures[m];
        if (measure.getAttribute('number') != '$n') {
          final copy = measure.copy()..setAttribute('number', '$n');
          measure.replace(copy);
          p._measures[m] = copy;
          _changed.add(m);
        }
        n++;
      }
    }
  }

  /// The barlines the bars popover takes: `|` plain, `||` double, `|]` final, `!` dashed, `:|`
  /// an end repeat and `|:` a start repeat (both at the end of the bar), `:|:` both.
  static const barlineTypes = ['|', '||', '|]', '!', ':|', '|:', ':|:'];

  /// The barline at the end of bar [m] in every part as [type] ([barlineTypes]); a start
  /// repeat opens the bar after (or bar [m], when it is the first). False if [type] is none.
  bool setBarline(int m, String type) {
    final t = type.replaceAll(' ', '');
    if (!barlineTypes.contains(t)) return false;
    edit(() {
      final endRepeat = t == ':|' || t == ':|:', startRepeat = t == '|:' || t == ':|:';
      final opened = m == 0 && t == '|:' ? 0 : m + 1;
      for (var i = 0; i < parts.length; i++) {
        if (!(m == 0 && t == '|:')) {
          final content = _mutable(i, m);
          content.others.removeWhere((o) => o.element.name.local == 'barline' && (o.element.getAttribute('location') ?? 'right') == 'right');
          final right = switch (t) {
            '||' => _el('barline', [_text('bar-style', 'light-light')], {'location': 'right'}),
            '|]' => _el('barline', [_text('bar-style', 'light-heavy')], {'location': 'right'}),
            '!' => _el('barline', [_text('bar-style', 'dashed')], {'location': 'right'}),
            _ when endRepeat => _el('barline', [_text('bar-style', 'light-heavy'), _el('repeat', const [], {'direction': 'backward'})], {'location': 'right'}),
            _ => null,
          };
          if (right != null) content.others.add(_Other(barLength(m), right));
          _commit(i, m, content);
        }
        if (opened < measureCount) {
          final c = _mutable(i, opened);
          final had = c.others.any((o) => o.element.name.local == 'barline' && o.element.getAttribute('location') == 'left');
          if (startRepeat || had) {
            c.others.removeWhere((o) => o.element.name.local == 'barline' && o.element.getAttribute('location') == 'left');
            if (startRepeat) {
              c.others.insert(
                  0, _Other(Frac.zero, _el('barline', [_text('bar-style', 'heavy-light'), _el('repeat', const [], {'direction': 'forward'})], {'location': 'left'})));
            }
            _commit(i, opened, c);
          }
        }
      }
    });
    return true;
  }

  // MARK: Copy and paste

  /// The notes and rests of [ids] in the first one's voice, from the first to the last.
  CopiedMusic copy(Iterable<String> ids) {
    final events = eventsOf(ids);
    if (events.isEmpty) return const CopiedMusic([]);
    final first = events.first;
    final same = events.where((e) => e.position.part == first.position.part && e.position.voice == first.position.voice).toList();
    final last = same.last;
    final out = <({Frac offset, Frac length, Rhythm? rhythm, List<XmlElement> notes})>[];
    var e = first;
    var offset = Frac.zero;
    while (true) {
      final view = _view(e.position.part, e.position.measure).voices[e.position.voice]!.firstWhere((x) => x.start == e.position.time);
      out.add((offset: offset, length: e.length, rhythm: e.rhythm, notes: e.isRest ? const [] : [for (final n in view.notes) n.copy()]));
      offset = offset + e.length;
      if (identical(e, last) || e.ids.first == last.ids.first) break;
      final after = next(e);
      if (after == null) break;
      e = after;
    }
    return CopiedMusic(out);
  }

  /// [music] put in from [at] over what was there; returns where it ends.
  ScorePosition paste(ScorePosition at, CopiedMusic music) => input(at, [
        for (final e in music.events)
          for (final r in e.rhythm != null && e.rhythm!.length == e.length ? [e.rhythm!] : Rhythm.express(e.length))
            InputItem(r, [for (final n in e.notes) ?_pitchOf(n)], templates: e.notes.isEmpty ? null : e.notes),
      ]);
}

/// An Undo step: for each part the bars to put back, by their place ([bars]), or every bar it
/// had when their number changed ([whole]), and its divisions.
class _Step {
  _Step(this.whole, this.bars, this.divisions);
  final List<List<XmlElement>?> whole;
  final List<Map<int, XmlElement>> bars;
  final List<int> divisions;
}
