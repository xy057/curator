import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import 'search.dart';
import 'sounding_notes.dart';

/// A key (the Tonality extension): its [tonic] as fifths from C on the line of fifths (G 1,
/// F −1, F♯ 6, B♭ −2), major or [minor]. The keys there are have a key signature of seven
/// sharps or flats at most ([all]).
@immutable
class MusicKey {
  const MusicKey(this.tonic, {this.minor = false});

  /// The key whose key signature has [signature] fifths, major or [minor].
  const MusicKey.of(int signature, {this.minor = false}) : tonic = minor ? signature + 3 : signature;

  final int tonic;
  final bool minor;

  /// Its key signature's fifths: sharps up, flats down.
  int get signature => minor ? tonic - 3 : tonic;

  /// The tonic's pitch class: C 0 … B 11.
  int get pitchClass => tonic * 7 % 12;

  /// Whether it is one of [all].
  bool get isValid => signature >= -7 && signature <= 7;

  /// Each key signature's major key and its minor, C♭ major to C♯ major and A♭ minor to A♯
  /// minor, in the order of their signatures.
  static final all = List<MusicKey>.unmodifiable([
    for (var s = -7; s <= 7; s++) ...[MusicKey.of(s), MusicKey.of(s, minor: true)],
  ]);

  /// The tonic as written, a letter and its accidental: C, F♯, B♭.
  String get tonicName {
    final i = tonic + 1; // F 0, C 1 … B 6
    final accidentals = (i / 7).floor();
    return 'FCGDAEB'[i % 7] + (accidentals > 0 ? '♯' * accidentals : '♭' * -accidentals);
  }

  /// Its name in English: "F major", "C♯ minor".
  String get name => '$tonicName ${minor ? 'minor' : 'major'}';

  /// Its colour in the tonality bar: its tonic's place on the circle of fifths as a hue, so keys
  /// a fifth apart are neighbours (the sharp keys cool, the flat ones warm) and two spelled
  /// differently (F♯, G♭) are one colour; a minor key darker than a major one. Every one is as
  /// light as the others (OKLCH), so the paper-coloured names on them read alike.
  ui.Color get color => _colors.putIfAbsent((tonic % 12, minor), () => _oklch(minor ? 0.52 : 0.64, minor ? 0.085 : 0.1, 130.0 + 30 * (tonic % 12)));
  static final _colors = <(int, bool), ui.Color>{};

  @override
  bool operator ==(Object other) => other is MusicKey && other.tonic == tonic && other.minor == minor;
  @override
  int get hashCode => Object.hash(tonic, minor);
  @override
  String toString() => 'MusicKey($name)';
}

/// The sRGB colour of OKLCH lightness [l], chroma [c] and hue [hue] (degrees), clipped to sRGB.
ui.Color _oklch(double l, double c, double hue) {
  final h = hue * math.pi / 180, a = c * math.cos(h), b = c * math.sin(h);
  double cube(double v) => v * v * v;
  final l3 = cube(l + 0.3963377774 * a + 0.2158037573 * b);
  final m3 = cube(l - 0.1055613458 * a - 0.0638541728 * b);
  final s3 = cube(l - 0.0894841775 * a - 1.2914855480 * b);
  double encoded(double v) {
    v = v.clamp(0.0, 1.0);
    return v <= 0.0031308 ? 12.92 * v : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
  }

  return ui.Color.from(
    alpha: 1,
    red: encoded(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
    green: encoded(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
    blue: encoded(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3),
  );
}

/// A key area (the Tonality extension): the music from score quarter [at] on, up to the next
/// area, in [key]; named in the tonality bar by [label], the user's own marking (null: the
/// key's name).
@immutable
class KeyArea {
  const KeyArea(this.at, this.key, [this.label]);
  final double at;
  final MusicKey key;
  final String? label;

  KeyArea copyWith({double? at, MusicKey? key, Object? label = _kept}) =>
      KeyArea(at ?? this.at, key ?? this.key, identical(label, _kept) ? this.label : label as String?);
  static const _kept = Object();

  @override
  bool operator ==(Object other) => other is KeyArea && other.at == at && other.key == key && other.label == label;
  @override
  int get hashCode => Object.hash(at, key, label);
  @override
  String toString() => 'KeyArea($at, ${key.name}${label == null ? '' : ', "$label"'})';
}

/// The longest marking a key area keeps.
const maxKeyLabel = 40;

/// [areas] as they are kept: in the score's order, one to a place (of two at one place, the
/// later in the list stays), keys there are only ([MusicKey.isValid]), markings trimmed (an
/// empty one is none).
List<KeyArea> tidyKeyAreas(List<KeyArea> areas) {
  final byPlace = <int, KeyArea>{};
  for (final a in areas) {
    if (!a.at.isFinite || a.at < 0 || !a.key.isValid) continue;
    var label = a.label?.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (label != null && label.length > maxKeyLabel) label = label.substring(0, maxKeyLabel);
    // To the millionth of a quarter, as chapters are placed.
    byPlace[(a.at * 1e6).round()] = KeyArea(a.at, a.key, label == null || label.isEmpty ? null : label);
  }
  return [for (final key in byPlace.keys.toList()..sort()) byPlace[key]!];
}

/// A key signature of a score at concert pitch: from bar [measure] (an index) on, [fifths];
/// [minor] as the parts say (`<mode>`; null: none says).
typedef ConcertKeySignature = ({int measure, int fifths, bool? minor});

/// The key signatures of [musicXML] at concert pitch, in order, each where it changes. Where
/// the parts differ (horns written without one, a part's own change), most of them win, a part
/// at concert pitch counting twice; unpitched percussion has no say.
List<ConcertKeySignature> concertKeySignatures(String musicXML) => _concertKeySignatures(XmlDocument.parse(musicXML).rootElement);

List<ConcertKeySignature> _concertKeySignatures(XmlElement root) {
  int? number(XmlElement? e) => int.tryParse(e?.innerText.trim() ?? '');
  // Each part's keys, as they change: (measure, concert fifths, mode) and whether it transposes.
  final parts = <List<(int, int, bool?, bool)>>[];
  for (final part in root.findElements('part')) {
    final keys = <(int, int, bool?, bool)>[];
    var chromatic = 0, percussion = false;
    for (final (m, measure) in part.findElements('measure').indexed) {
      for (final attributes in measure.findElements('attributes')) {
        if (attributes.getElement('transpose') case final t?) chromatic = number(t.getElement('chromatic')) ?? 0;
        if (attributes.findElements('clef').any((c) => c.getElement('sign')?.innerText.trim() == 'percussion')) percussion = true;
        final key = attributes.getElement('key');
        final fifths = number(key?.getElement('fifths'));
        if (fifths == null) continue;
        // A transposing part is written that many fifths from concert pitch (a B♭ part two sharper).
        var shift = (-chromatic * 7) % 12;
        if (shift > 6) shift -= 12;
        var concert = fifths - shift;
        if (concert > 7) concert -= 12;
        if (concert < -7) concert += 12;
        final mode = key!.getElement('mode')?.innerText.trim();
        keys.add((m, concert, mode == 'minor' ? true : (mode == 'major' ? false : null), chromatic % 12 != 0));
      }
    }
    if (!percussion && keys.isNotEmpty) parts.add(keys);
  }
  final changes = {for (final keys in parts) for (final k in keys) k.$1}.toList()..sort();
  final out = <ConcertKeySignature>[];
  for (final m in changes) {
    final votes = <int, double>{}, modes = <int, List<bool?>>{};
    for (final keys in parts) {
      final now = keys.lastWhere((k) => k.$1 <= m, orElse: () => (-1, 0, null, false));
      if (now.$1 < 0) continue;
      votes[now.$2] = (votes[now.$2] ?? 0) + (now.$4 ? 1 : 2);
      (modes[now.$2] ??= []).add(now.$3);
    }
    if (votes.isEmpty) continue;
    final fifths = votes.entries.reduce((a, b) => b.value > a.value || (b.value == a.value && b.key.abs() < a.key.abs()) ? b : a).key;
    final said = modes[fifths]!.nonNulls;
    final minors = said.where((v) => v).length;
    final bool? minor = said.isEmpty || minors * 2 == said.length ? null : minors * 2 > said.length;
    if (out.lastOrNull case final last? when last.fifths == fifths && last.minor == minor) continue;
    out.add((measure: m, fifths: fifths, minor: minor));
  }
  return out;
}

/// Krumhansl and Kessler's profiles: how well each pitch class from the tonic up fits a major
/// and a minor key, as listeners rated them.
const _majorProfile = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const _minorProfile = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];

/// Find Keys: where the music of [musicXML] is in which key, as key areas starting at bars
/// ([measureStarts], score quarters). Each bar is heard as how long each pitch class sounds in
/// it and the bars either side (the lowest note of each chord counting twice), and is most like
/// one key's profile ([_majorProfile], [_minorProfile]); a key is held until the music has been
/// in another for long enough to outweigh changing twice ([_changeCost]), and the key
/// signature in force leans toward its own major and minor, toward the one its `<mode>` says
/// most. A change heard a bar or two from a change of key signature is moved to it, and a key is
/// spelled as near the key signature as it can be (G♭ major among flats, F♯ major among
/// sharps). A score without notes (a PDF's) has its key signatures' keys, major unless they say
/// minor; one without bars, none.
List<KeyArea> findKeys(String musicXML, List<double> measureStarts) {
  final bars = measureStarts.length - 1;
  if (bars <= 0) return const [];
  final root = XmlDocument.parse(musicXML).rootElement;
  final signatures = _concertKeySignatures(root);
  final notes = soundingNotes(musicXML, measureStarts).toList();
  if (notes.isEmpty) {
    // Nothing to hear (a PDF score's): the key signatures alone, major unless they say minor.
    return [
      for (final s in signatures)
        if (s.measure < bars) KeyArea(measureStarts[math.max(0, s.measure)], MusicKey.of(s.fifths, minor: s.minor ?? false)),
    ];
  }

  // How long each pitch class sounds in each bar, in quarters.
  final heard = [for (var b = 0; b < bars; b++) Float64List(12)];
  void sound(int pc, double start, double end) {
    var b = segmentAt(measureStarts.length, start, (i) => measureStarts[i]);
    for (; b < bars && measureStarts[b] < end; b++) {
      final overlap = math.min(end, measureStarts[b + 1]) - math.max(start, measureStarts[b]);
      if (overlap > 0) heard[b][pc] += overlap;
    }
  }

  final lowest = <int, SoundingNote>{};
  for (final n in notes) {
    if (n.end <= n.start) continue;
    sound(n.midi % 12, n.start, n.end);
    if (n.tied) continue;
    final onset = (n.start * 1e4).round();
    if (lowest[onset] case final low? when low.midi <= n.midi) continue;
    lowest[onset] = n;
  }
  for (final n in lowest.values) {
    sound(n.midi % 12, n.start, n.end);
  }

  // Each bar's likeness to each key (0–11 major on C…B, 12–23 minor), heard with the bars
  // either side, as Pearson's correlation with the key's profile.
  final profiles = [
    for (final profile in [_majorProfile, _minorProfile])
      for (var tonic = 0; tonic < 12; tonic++) [for (var pc = 0; pc < 12; pc++) profile[(pc - tonic) % 12]],
  ];
  const window = [0.25, 0.5, 1.0, 0.5, 0.25];
  final likeness = [for (var b = 0; b < bars; b++) Float64List(24)];
  for (var b = 0; b < bars; b++) {
    final h = Float64List(12);
    for (var d = -2; d <= 2; d++) {
      if (b + d < 0 || b + d >= bars) continue;
      for (var pc = 0; pc < 12; pc++) {
        h[pc] += heard[b + d][pc] * window[d + 2];
      }
    }
    if (h.every((v) => v == 0)) continue; // silence: no key more than another
    for (var k = 0; k < 24; k++) {
      likeness[b][k] = _correlation(h, profiles[k]);
    }
  }

  // The key signature in force at each bar.
  final signatureAt = List<ConcertKeySignature?>.filled(bars, null);
  for (final (i, s) in signatures.indexed) {
    final end = i + 1 < signatures.length ? signatures[i + 1].measure : bars;
    for (var b = math.max(0, s.measure); b < math.min(end, bars); b++) {
      signatureAt[b] = s;
    }
  }
  if (signatures.isNotEmpty) {
    for (var b = 0; b < math.min(signatures.first.measure, bars); b++) {
      signatureAt[b] = signatures.first;
    }
  }

  // The likeliest keys through the piece (Viterbi): each bar weighs as long as it lasts.
  final score = Float64List(24);
  final from = [for (var b = 0; b < bars; b++) Int8List(24)];
  for (var b = 0; b < bars; b++) {
    final length = (measureStarts[b + 1] - measureStarts[b]).clamp(0.25, 16.0);
    final signature = signatureAt[b];
    var best = 0;
    for (var k = 1; k < 24; k++) {
      if (score[k] > score[best]) best = k;
    }
    final before = Float64List.fromList(score);
    for (var k = 0; k < 24; k++) {
      final stay = before[k], change = b == 0 ? before[k] : before[best] - _changeCost;
      from[b][k] = stay >= change ? k : best;
      var lean = 0.0;
      if (signature != null) {
        final minor = k >= 12, tonicOfSignature = MusicKey.of(signature.fifths, minor: minor).pitchClass;
        if (k % 12 == tonicOfSignature) lean = signature.minor == minor ? _modeLean : (signature.minor == null ? _signatureLean : _signatureLean / 2);
      }
      score[k] = math.max(stay, change) + length * (likeness[b][k] + lean);
    }
  }
  final keys = Int8List(bars);
  var k = 0;
  for (var i = 1; i < 24; i++) {
    if (score[i] > score[k]) k = i;
  }
  for (var b = bars - 1; b >= 0; b--) {
    keys[b] = k;
    k = from[b][k];
  }

  // Where the key changes; one heard a bar or two from a change of key signature (the bars
  // either side lean it early or late) moves there.
  final changes = <(int, int)>[
    for (var b = 0; b < bars; b++)
      if (b == 0 || keys[b] != keys[b - 1]) (b, keys[b]),
  ];
  final signed = {for (final s in signatures) if (s.measure > 0 && s.measure < bars) s.measure};
  for (var i = 1; i < changes.length; i++) {
    final (b, key) = changes[i];
    final lo = changes[i - 1].$1 + 1, hi = i + 1 < changes.length ? changes[i + 1].$1 - 1 : bars - 1;
    final near = [for (var d = 0; d <= 2; d++) ...{b - d, b + d}].where((s) => s >= lo && s <= hi && signed.contains(s)).firstOrNull;
    if (near != null) changes[i] = (near, key);
  }
  return [
    for (final (b, key) in changes) KeyArea(measureStarts[b], _spelled(key % 12, minor: key >= 12, near: signatureAt[b]?.fifths ?? 0)),
  ];
}

/// What a change of key costs Find Keys, in bars' likeness (a quarter's worth of a key's
/// correlation with the music): the music has to be in another key for a few bars, more for one
/// it soon leaves again.
const _changeCost = 6.0;

/// How much the key signature in force leans toward its own two keys, a quarter's worth, and
/// toward the one its `<mode>` names.
const _signatureLean = 0.08, _modeLean = 0.14;

/// The key on [pitchClass], spelled with its key signature as near [near] fifths as it can be.
MusicKey _spelled(int pitchClass, {required bool minor, required int near}) {
  final tonic = pitchClass * 7 % 12; // the inverse of fifths → pitch class: 7 × 7 ≡ 1 (mod 12)
  MusicKey? best;
  for (final t in [tonic - 12, tonic, tonic + 12]) {
    final key = MusicKey(t, minor: minor);
    if (!key.isValid) continue;
    final distance = (key.signature - near).abs(), bestDistance = best == null ? 99 : (best.signature - near).abs();
    if (distance < bestDistance || (distance == bestDistance && key.signature.abs() < best!.signature.abs())) best = key;
  }
  return best!;
}

double _correlation(List<double> a, List<double> b) {
  var meanA = 0.0, meanB = 0.0;
  for (var i = 0; i < 12; i++) {
    meanA += a[i];
    meanB += b[i];
  }
  meanA /= 12;
  meanB /= 12;
  var ab = 0.0, aa = 0.0, bb = 0.0;
  for (var i = 0; i < 12; i++) {
    final x = a[i] - meanA, y = b[i] - meanB;
    ab += x * y;
    aa += x * x;
    bb += y * y;
  }
  return aa <= 0 || bb <= 0 ? 0 : ab / math.sqrt(aa * bb);
}
