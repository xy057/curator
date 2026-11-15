import 'dart:math' as math;

import 'package:xml/xml.dart';

/// How loud each part plays through a score, 0 (silent) to 1 (ffff), as its dynamics say: a mark
/// holds until the next (mf before the first); a hairpin goes from where it starts to the mark it
/// reaches (a step louder or softer where none follows); an accent (sf, sfz, fz, rf) is one
/// moment's, and fp, sfp and the like an accent then their soft mark. What the player map's
/// swells are scaled by ([PlayerPulses.of]).
class ScoreDynamics {
  ScoreDynamics._(this._parts);

  /// No dynamics: every part mf.
  static final none = ScoreDynamics._(const {});

  /// Before any mark.
  static const standard = 0.6;

  /// A mark's level.
  static const levels = {
    'pppppp': 0.06, 'ppppp': 0.1, 'pppp': 0.14, 'ppp': 0.2, 'pp': 0.3, 'p': 0.4, 'mp': 0.5, //
    'mf': 0.6, 'f': 0.74, 'ff': 0.86, 'fff': 0.93, 'ffff': 0.97, 'fffff': 1.0, 'ffffff': 1.0,
    'n': 0.05,
  };

  /// An accent's level for its moment, and the mark it leaves behind (null: the one before).
  static const accents = <String, (double, String?)>{
    'sf': (0.86, null), 'sfz': (0.9, null), 'sffz': (0.95, null), 'fz': (0.86, null), 'rf': (0.8, null), 'rfz': (0.84, null),
    'fp': (0.74, 'p'), 'sfp': (0.86, 'p'), 'sfpp': (0.86, 'pp'), 'sfzp': (0.9, 'p'), 'pf': (0.74, 'f'),
  };

  /// A hairpin's step where no mark ends it.
  static const step = 0.14;

  final Map<String, _PartDynamics> _parts;

  /// How loud part [part] plays at score quarter [quarter].
  double at(String part, double quarter) => _parts[part]?.at(quarter) ?? standard;

  /// The dynamics of [musicXML], whose bars [measureStarts] puts in score quarters.
  static ScoreDynamics read(String musicXML, List<double> measureStarts) {
    final root = XmlDocument.parse(musicXML).rootElement;
    int? number(XmlElement? e) => int.tryParse(e?.innerText.trim() ?? '');
    final parts = <String, _PartDynamics>{};
    for (final part in root.findElements('part')) {
      final marks = <(double, double)>[], moments = <(double, double)>[];
      final wedges = <(double, double, bool)>[];
      final open = <String, (double, bool)>{};
      var divisions = 1;
      for (final (m, measure) in part.findElements('measure').indexed) {
        if (m + 1 >= measureStarts.length) break;
        var cursor = 0, lastStart = 0;
        for (final e in measure.childElements) {
          switch (e.name.local) {
            case 'attributes':
              divisions = math.max(1, number(e.getElement('divisions')) ?? divisions);
            case 'backup':
              cursor = math.max(0, cursor - (number(e.getElement('duration')) ?? 0));
            case 'forward':
              cursor += number(e.getElement('duration')) ?? 0;
            case 'note':
              if (e.getElement('grace') != null || e.getElement('cue') != null) continue;
              if (e.getElement('chord') == null) {
                lastStart = cursor;
                cursor += number(e.getElement('duration')) ?? 0;
              }
              // A dynamic written on the note itself (<notations><dynamics>): its moment.
              for (final d in e.findAllElements('dynamics')) {
                _mark(d, measureStarts[m] + lastStart / divisions, marks, moments);
              }
            case 'direction':
              final at = measureStarts[m] + (cursor + (number(e.getElement('offset')) ?? 0)) / divisions;
              for (final type in e.findElements('direction-type')) {
                for (final d in type.findElements('dynamics')) {
                  _mark(d, at, marks, moments);
                }
                for (final w in type.findElements('wedge')) {
                  final id = w.getAttribute('number') ?? '1';
                  switch (w.getAttribute('type')) {
                    case 'crescendo':
                      open[id] = (at, true);
                    case 'diminuendo':
                      open[id] = (at, false);
                    case 'stop':
                      if (open.remove(id) case (final start, final louder)) wedges.add((start, at, louder));
                  }
                }
              }
          }
        }
      }
      if (marks.isNotEmpty || moments.isNotEmpty || wedges.isNotEmpty) parts[part.getAttribute('id') ?? ''] = _PartDynamics.of(marks, moments, wedges);
    }
    return ScoreDynamics._(parts);
  }

  static void _mark(XmlElement dynamics, double at, List<(double, double)> marks, List<(double, double)> moments) {
    for (final d in dynamics.childElements) {
      final name = d.name.local;
      if (levels[name] case final level?) {
        marks.add((at, level));
      } else if (accents[name] case (final level, final after)) {
        moments.add((at, level));
        if (after != null) marks.add((at, levels[after]!));
      }
    }
  }
}

/// One part's dynamics: its marks in order (each holding until the next), its hairpins as ramps
/// from one level to another, its accents' moments.
class _PartDynamics {
  _PartDynamics(this.marks, this.ramps, this.moments);
  final List<(double, double)> marks;
  final List<(double start, double end, double from, double to)> ramps;
  final List<(double, double)> moments;

  factory _PartDynamics.of(List<(double, double)> marks, List<(double, double)> moments, List<(double, double, bool)> wedges) {
    marks.sort((a, b) => a.$1.compareTo(b.$1));
    wedges.sort((a, b) => a.$1.compareTo(b.$1));
    double markAt(double q) {
      var level = ScoreDynamics.standard;
      for (final (at, l) in marks) {
        if (at > q + 1e-9) break;
        level = l;
      }
      return level;
    }

    final ramps = <(double, double, double, double)>[];
    final added = <(double, double)>[];
    for (final (start, end, louder) in wedges) {
      if (end <= start + 1e-9) continue;
      final from = ramps.isNotEmpty && ramps.last.$2 >= start - 1e-9 ? ramps.last.$4 : markAt(start);
      // The mark it reaches: at its end or within a beat after; else a step on.
      final reached = marks.where((m) => m.$1 >= end - 1e-9 && m.$1 <= end + 1).firstOrNull?.$2;
      final to = (reached ?? from + (louder ? ScoreDynamics.step : -ScoreDynamics.step)).clamp(0.05, 1.0);
      ramps.add((start, end, from, to));
      // Where no mark ends it, it leaves its level until the next.
      if (reached == null) added.add((end, to));
    }
    final all = [...marks, ...added]..sort((a, b) => a.$1.compareTo(b.$1));
    moments.sort((a, b) => a.$1.compareTo(b.$1));
    return _PartDynamics(all, ramps, moments);
  }

  double at(double q) {
    for (final (at, level) in moments) {
      if ((at - q).abs() < 1e-6) return level;
      if (at > q) break;
    }
    for (final (start, end, from, to) in ramps) {
      if (q >= start - 1e-9 && q < end - 1e-9) return from + (to - from) * (q - start) / (end - start);
    }
    var level = ScoreDynamics.standard;
    for (final (at, l) in marks) {
      if (at > q + 1e-9) break;
      level = l;
    }
    return level;
  }
}
