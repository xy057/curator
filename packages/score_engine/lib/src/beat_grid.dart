import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'search.dart';

/// A time signature, as the beats a musician counts in one bar.
@immutable
class Meter {
  const Meter(this.beatLengths, this.label);

  /// Quarter-note beats, for scores without a time signature.
  static const quarters = Meter([1, 1, 1, 1], '4/4');

  /// Length of each beat in quarter notes: 6/8 → [1.5, 1.5], 2+2+3/8 → [1, 1, 1.5].
  final List<double> beatLengths;

  /// As written, e.g. "6/8".
  final String label;

  double get barLength => beatLengths.fold(0.0, (a, b) => a + b);

  /// From MusicXML `<beats>` / `<beat-type>` pairs (usually one; composite meters have
  /// several). Returns null for something unreadable.
  ///
  /// Compound meters (6/8, 9/8, 12/8, 12/16 …) beat in dotted notes; simple ones in the
  /// lower number (4/4 in quarters, 2/2 in halves, 3/8 in eighths). An additive numerator
  /// ("2+2+3") gives one beat per group.
  static Meter? fromMusicXML(List<(String beats, String beatType)> pairs) {
    final lengths = <double>[];
    final label = <String>[];
    for (final (beats, beatType) in pairs) {
      final type = int.tryParse(beatType.trim());
      final groups = [for (final g in beats.split('+')) int.tryParse(g.trim())];
      // No real meter has hundreds of beats; a number like 900000000 would be a list that long.
      if (type == null || type <= 0 || type > _maxBeats || groups.isEmpty || groups.length > _maxBeats) return null;
      if (groups.any((g) => g == null || g <= 0 || g > _maxBeats)) return null;
      final unit = 4 / type;
      if (groups.length > 1) {
        lengths.addAll([for (final g in groups) g! * unit]);
      } else {
        final n = groups.single!;
        final compound = type >= 8 && n > 3 && n % 3 == 0;
        lengths.addAll(compound ? List.filled(n ~/ 3, 3 * unit) : List.filled(n, unit));
      }
      label.add('${beats.trim()}/$type');
    }
    return lengths.isEmpty || lengths.length > _maxBeats ? null : Meter(List.unmodifiable(lengths), label.join('+'));
  }

  static const _maxBeats = 256;

  @override
  bool operator ==(Object other) => other is Meter && other.label == label && listEquals(other.beatLengths, beatLengths);
  @override
  int get hashCode => Object.hash(label, Object.hashAll(beatLengths));
}

/// Where the beats fall in every bar, following the time signatures: the finer grid the
/// timeline snaps to and draws, and what "bar 12, beat 2" means.
class BeatGrid {
  /// [meters] has one entry per measure (null: carry on with quarters); [pickups] are the
  /// incomplete measures (MusicXML `implicit`) whose beats count back from their end.
  BeatGrid(List<double> measureStarts, {List<Meter?> meters = const [], Set<int> pickups = const {}})
      : measureStarts = List.unmodifiable(measureStarts),
        _beats = List.unmodifiable([
          for (var m = 0; m + 1 < measureStarts.length; m++)
            _beatsOf(measureStarts[m], measureStarts[m + 1] - measureStarts[m],
                (m < meters.length ? meters[m] : null) ?? Meter.quarters, pickups.contains(m)),
        ]);

  final List<double> measureStarts;
  final List<List<double>> _beats;

  static List<double> _beatsOf(double start, double length, Meter meter, bool pickup) {
    final lengths = meter.beatLengths;
    final offsets = <double>[];
    if (pickup && length < meter.barLength - 1e-9) {
      // An upbeat: the beats that lead into the next barline.
      var at = length - meter.barLength;
      for (final l in lengths) {
        if (at > 1e-9) offsets.add(at);
        at += l;
      }
      offsets.insert(0, 0);
    } else {
      // Longer than the meter says (a cadenza bar, a missing time change): keep counting.
      var at = 0.0;
      for (var i = 0; at < length - 1e-9; i++) {
        offsets.add(at);
        at += lengths[i % lengths.length];
      }
      if (offsets.isEmpty) offsets.add(0);
    }
    return List.unmodifiable([for (final o in offsets) start + o]);
  }

  double get totalQuarters => measureStarts.last;

  /// The measure containing [quarter] (the last one for the very end).
  int measureAt(double quarter) => segmentAt(measureStarts.length, quarter + 1e-9, (i) => measureStarts[i]);

  /// Beat starts in measure [m] as score quarters; the first is the barline.
  List<double> beatsIn(int m) => m >= 0 && m < _beats.length ? _beats[m] : [measureStarts[m.clamp(0, measureStarts.length - 1)]];

  /// The beat containing [quarter]: its start and end.
  ({double start, double end}) beatAt(double quarter) {
    final m = measureAt(quarter);
    final beats = beatsIn(m);
    var i = beats.length - 1;
    while (i > 0 && beats[i] > quarter + 1e-9) {
      i--;
    }
    final end = i + 1 < beats.length ? beats[i + 1] : measureStarts[math.min(m + 1, measureStarts.length - 1)];
    return (start: beats[i], end: math.max(end, beats[i]));
  }

  /// Bar and beat of [quarter], both from 0; [beat] has a fraction between beats.
  ({int measure, double beat}) position(double quarter) {
    final m = measureAt(quarter);
    final beats = beatsIn(m);
    final b = beatAt(quarter);
    final index = beats.indexOf(b.start);
    final length = b.end - b.start;
    return (measure: m, beat: index + (length > 0 ? ((quarter - b.start) / length).clamp(0.0, 1.0) : 0));
  }

  /// A score position as people write it: "12.3" is bar 12, beat 3, counting beats the way
  /// the time signature does (6/8 has two). Between beats the fraction of the beat follows
  /// ("12.1.50": half-way through beat 1). [compact] writes a barline as just "12".
  String format(double quarter, {bool compact = false}) {
    final (:measure, :beat) = position(quarter);
    final whole = (beat - beat.roundToDouble()).abs() < 1e-6;
    if (compact && whole && beat.round() == 0) return '${measure + 1}';
    return '${measure + 1}.${whole ? beat.round() + 1 : (beat + 1).toStringAsFixed(2)}';
  }

  /// Reads [format]'s "12", "12.3" or "12.1.50" back into a score position; null when it
  /// isn't one. The end of the piece is the bar after the last.
  double? parse(String text) {
    final match = RegExp(r'^\s*(\d+)(?:\.(\d+(?:\.\d+)?))?\s*$').firstMatch(text);
    // A bar number too long for an int ("99999999999999999999") is no bar.
    final bar = match == null ? null : int.tryParse(match[1]!);
    if (bar == null) return null;
    return quarterAt(bar - 1, double.parse(match![2] ?? '1') - 1);
  }

  /// The inverse of [position]: null when bar [measure] has no such beat. The end of the
  /// piece is beat 0 of the bar after the last.
  double? quarterAt(int measure, double beat) {
    if (measure < 0 || beat < 0) return null;
    if (measure >= measureStarts.length - 1) return measure == measureStarts.length - 1 && beat == 0 ? totalQuarters : null;
    final beats = beatsIn(measure);
    final i = beat.floor();
    if (i >= beats.length) return null;
    final end = i + 1 < beats.length ? beats[i + 1] : measureStarts[measure + 1];
    return beats[i] + (beat - i) * (end - beats[i]);
  }
}
