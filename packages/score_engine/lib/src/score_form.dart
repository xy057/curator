import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import 'midi_tempo.dart';

/// What one bar's barlines and directions say about the form.
@immutable
class BarForm {
  const BarForm({
    this.forward = false,
    this.backward,
    this.afterJump = false,
    this.endings,
    this.endingStart = false,
    this.segnos = const {},
    this.codas = const {},
    this.daCapo = false,
    this.dalSegno,
    this.toCoda,
    this.fine = false,
  });

  /// A forward repeat at its start.
  final bool forward;

  /// A backward repeat at its end: how many times the stretch is played (2 by default).
  final int? backward;

  /// Whether that repeat is still taken after a D.C. or D.S. (`after-jump`).
  final bool afterJump;

  /// The numbers of the ending (volta) it is in: played on those times through.
  final Set<int>? endings;

  /// Whether an ending starts with it (the bars after it in [endings] are in the same one).
  final bool endingStart;

  /// Names of the segnos and codas at its start (a symbol without a name: '').
  final Set<String> segnos, codas;

  /// At its end: back to the start (D.C.), to a segno (D.S., its name), to a coda (To Coda,
  /// after a D.C. or D.S.), or the end of the piece (Fine, after a D.C. or D.S.).
  final bool daCapo;
  final String? dalSegno, toCoda;
  final bool fine;

  bool get jumps => forward || backward != null || endings != null || daCapo || dalSegno != null;
}

/// The form a score's repeats, endings, D.C., D.S., To Coda and Fine give it: the order its
/// bars are played in, and the warps a MIDI file playing it so would need.
@immutable
class ScoreForm {
  const ScoreForm(this.bars);

  /// A score read straight through.
  static const straight = ScoreForm([]);

  /// One per bar, in score order.
  final List<BarForm> bars;

  /// Whether anything makes it other than straight through.
  bool get hasJumps => bars.any((b) => b.jumps);

  /// Reads the barlines (repeats, endings) of the first part and the `<sound>` jumps and
  /// markers of every part, with a segno or coda symbol counting as a marker.
  static ScoreForm fromDocument(XmlDocument doc) {
    final parts = doc.rootElement.findElements('part').toList();
    if (parts.isEmpty) return straight;
    final measures = parts.first.findElements('measure').toList();
    final segnos = [for (final _ in measures) <String>{}], codas = [for (final _ in measures) <String>{}];
    final daCapo = List.filled(measures.length, false), fine = List.filled(measures.length, false);
    final dalSegno = List<String?>.filled(measures.length, null), toCoda = List<String?>.filled(measures.length, null);
    for (final part in parts) {
      for (final (i, measure) in part.findElements('measure').take(measures.length).indexed) {
        for (final sound in measure.findAllElements('sound')) {
          String? value(String name) => sound.getAttribute(name)?.trim();
          if (value('segno') case final name?) segnos[i].add(name);
          if (value('coda') case final name?) codas[i].add(name);
          if (value('dacapo') == 'yes') daCapo[i] = true;
          if (value('dalsegno') case final name?) dalSegno[i] = name;
          if (value('tocoda') case final name?) toCoda[i] = name;
          if (value('fine') != null) fine[i] = true;
        }
        for (final type in measure.findAllElements('direction-type')) {
          if (type.findElements('segno').isNotEmpty && segnos[i].isEmpty) segnos[i].add('');
          if (type.findElements('coda').isNotEmpty && codas[i].isEmpty) codas[i].add('');
        }
      }
    }

    final forward = List.filled(measures.length, false), afterJump = List.filled(measures.length, false);
    final backward = List<int?>.filled(measures.length, null);
    final endings = List<Set<int>?>.filled(measures.length, null);
    final endingStart = List.filled(measures.length, false);
    Set<int>? open; // the ending started and not yet stopped
    for (final (i, measure) in measures.indexed) {
      Set<int>? stopped;
      for (final barline in measure.findElements('barline')) {
        final left = barline.getAttribute('location') == 'left';
        final repeat = barline.getElement('repeat');
        if (repeat != null) {
          if (repeat.getAttribute('direction') == 'forward') {
            forward[i] = true;
          } else if (!left) {
            final times = int.tryParse(repeat.getAttribute('times')?.trim() ?? '');
            backward[i] = times != null && times > 1 ? times : 2;
            afterJump[i] = repeat.getAttribute('after-jump') == 'yes';
          }
        }
        final ending = barline.getElement('ending');
        if (ending == null) continue;
        final numbers = _endingNumbers(ending.getAttribute('number') ?? '');
        if (ending.getAttribute('type') == 'start') {
          open = numbers.isEmpty ? {1} : numbers;
          endingStart[i] = true;
        } else if (open == null && numbers.isNotEmpty) {
          stopped = numbers; // a stop without its start: an ending of this bar alone
          endingStart[i] = true;
        } else {
          stopped = open;
        }
      }
      endings[i] = open ?? stopped;
      if (stopped != null) open = null;
    }

    return ScoreForm(List.unmodifiable([
      for (var i = 0; i < measures.length; i++)
        BarForm(
          forward: forward[i],
          backward: backward[i],
          afterJump: afterJump[i],
          endings: endings[i],
          endingStart: endingStart[i],
          segnos: segnos[i],
          codas: codas[i],
          daCapo: daCapo[i],
          dalSegno: dalSegno[i],
          toCoda: toCoda[i],
          fine: fine[i],
        ),
    ]));
  }

  /// "1", "1, 2", "1-3" (and "1." etc.).
  static Set<int> _endingNumbers(String text) {
    final out = <int>{};
    for (final m in RegExp(r'(\d+)(?:\s*[-–]\s*(\d+))?').allMatches(text)) {
      final from = int.parse(m.group(1)!), to = int.tryParse(m.group(2) ?? '') ?? from;
      for (var n = from; n <= math.min(to, from + 32); n++) {
        out.add(n);
      }
    }
    return out;
  }

  /// The bars (indices) in the order they are played: a repeat goes back to the last forward
  /// repeat (or where the stretch began) as many times as it says, an ending is played on its
  /// times through, D.C. and D.S. are taken once, and after one repeats are left out (unless
  /// `after-jump`), the last ending is played, To Coda jumps on and Fine stops.
  List<int> playedOrder() {
    final n = bars.length;
    // The last bar of the ending each bar is in, and the highest number of its group of
    // endings (those following one another).
    final endingEnd = List<int>.filled(n, -1), groupMost = List<int>.filled(n, 0), lastEnding = List.filled(n, false);
    for (var i = 0; i < n;) {
      if (bars[i].endings == null) {
        i++;
        continue;
      }
      final group = <(int, int)>[];
      while (i < n && bars[i].endings != null) {
        final start = i;
        while (i + 1 < n && bars[i + 1].endings != null && !bars[i + 1].endingStart) {
          i++;
        }
        group.add((start, i));
        i++;
        if (i < n && bars[i].endings != null && bars[i].forward) break;
      }
      final most = group.map((g) => bars[g.$1].endings!.reduce(math.max)).reduce(math.max);
      for (final (gi, (start, end)) in group.indexed) {
        for (var b = start; b <= end; b++) {
          endingEnd[b] = end;
          groupMost[b] = most;
          lastEnding[b] = gi == group.length - 1;
        }
      }
    }
    int? marker(Set<String> Function(BarForm) of, String name, bool Function(int) where) {
      int? any;
      for (var i = 0; i < n; i++) {
        if (!where(i)) continue;
        final names = of(bars[i]);
        if (names.contains(name)) return i;
        if (names.isNotEmpty) any ??= i;
      }
      return any;
    }

    final out = <int>[];
    final sent = <int, int>{}; // a backward repeat → times it has sent back
    final taken = <int>{}; // the D.C. / D.S. / To Coda taken
    var i = 0, pass = 1, sectionStart = 0, jumped = false;
    void jump(int to) {
      i = to;
      sectionStart = to;
      pass = 1;
      sent.clear();
    }

    while (i < n && out.length < n * 32) {
      final bar = bars[i];
      if (bar.forward && sectionStart != i) {
        sectionStart = i;
        pass = 1;
      }
      if (bar.endings != null) {
        final plays = jumped && !bar.afterJump ? lastEnding[i] : bar.endings!.contains(pass);
        if (!plays) {
          i = endingEnd[i] + 1;
          continue;
        }
      }
      out.add(i);

      if (jumped && bar.fine) break;
      if (jumped && bar.toCoda != null && taken.add(-i - 1)) {
        final coda = marker((b) => b.codas, bar.toCoda!, (j) => j > i);
        if (coda != null) {
          jump(coda);
          continue;
        }
      }
      if (bar.backward != null && (!jumped || bar.afterJump)) {
        final times = bar.endings != null ? math.max(bar.backward!, groupMost[i]) : bar.backward!;
        final count = sent[i] ?? 0;
        if (count + 1 < times) {
          sent[i] = count + 1;
          pass = count + 2;
          i = sectionStart;
          continue;
        }
        sent.remove(i);
      }
      if (bar.daCapo && taken.add(i)) {
        jumped = true;
        jump(0);
        continue;
      }
      if (bar.dalSegno != null && taken.add(i)) {
        final segno = marker((b) => b.segnos, bar.dalSegno!, (j) => j <= i);
        if (segno != null) {
          jumped = true;
          jump(segno);
          continue;
        }
      }
      // On past a stretch's last repeat, or out of its endings: a new stretch.
      if ((bar.backward != null && bar.endings == null) || (bar.endings != null && (i + 1 >= n || bars[i + 1].endings == null))) {
        sectionStart = i + 1;
        pass = 1;
      }
      i++;
    }
    return out;
  }

  /// The warps a MIDI file playing this form needs, for bars starting at [measureStarts]
  /// (score quarters, the end of the last bar included): one wherever the next bar played
  /// isn't the next in the score. None when the score is straight through or the bars don't
  /// match [measureStarts].
  List<MidiWarp> warps(List<double> measureStarts) {
    if (measureStarts.length != bars.length + 1) return const [];
    final order = playedOrder();
    final out = <MidiWarp>[];
    var at = 0.0;
    for (final (k, b) in order.indexed) {
      at += measureStarts[b + 1] - measureStarts[b];
      if (k + 1 < order.length && order[k + 1] != b + 1) out.add((at: at, jumpTo: measureStarts[order[k + 1]]));
    }
    return out;
  }

  /// How long the form plays, in quarters (the score's length when straight through).
  double playedQuarters(List<double> measureStarts) {
    if (measureStarts.length != bars.length + 1) return measureStarts.isEmpty ? 0 : measureStarts.last;
    return playedOrder().fold(0.0, (sum, b) => sum + measureStarts[b + 1] - measureStarts[b]);
  }
}
