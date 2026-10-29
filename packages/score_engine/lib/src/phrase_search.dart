import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:xml/xml.dart';

import 'curated_scene.dart';
import 'display_list.dart';
import 'engraving.dart';

/// A written note value, as Find Phrase enters them.
enum NoteValue {
  whole(4, 'whole', 0),
  half(2, 'half', 0),
  quarter(1, 'quarter', 0),
  eighth(0.5, 'eighth', 1),
  sixteenth(0.25, '16th', 2),
  thirtySecond(0.125, '32nd', 3);

  const NoteValue(this.quarters, this.type, this.beams);
  final double quarters;

  /// MusicXML's `<type>`.
  final String type;

  /// How many beams (or flags) it has.
  final int beams;
}

/// A note or rest of a [Phrase]: a pitch spelled as written (C–B, an alteration, an octave, middle
/// C being C4) and a written length.
class PhraseNote {
  const PhraseNote({this.step, this.alter = 0, this.octave = 4, this.value = NoteValue.quarter, this.dotted = false});

  /// A rest of [value].
  const PhraseNote.rest({this.value = NoteValue.quarter, this.dotted = false})
      : step = null,
        alter = 0,
        octave = 4;

  /// 0–6 for C–B; null for a rest.
  final int? step;

  /// Semitones up (a sharp, 1) or down (a flat, -1).
  final int alter;
  final int octave;
  final NoteValue value;
  final bool dotted;

  bool get isRest => step == null;

  static const letters = 'CDEFGAB';
  static const _semitones = [0, 2, 4, 5, 7, 9, 11];

  /// Its MIDI pitch (middle C 60); null for a rest.
  int? get midi => switch (step) { final s? => 12 * (octave + 1) + _semitones[s] + alter, null => null };

  /// Its place on the staff: 7 a letter's octave plus the letter (C4 is 28).
  int get diatonic => octave * 7 + (step ?? 6);

  double get quarters => value.quarters * (dotted ? 1.5 : 1);

  /// Letter [step] (0–6) in the octave that brings it nearest to [near] (a MIDI pitch; middle C's
  /// octave without one), as notation programs place a typed letter.
  static PhraseNote nearest(int step, int? near, {NoteValue value = NoteValue.quarter, bool dotted = false}) {
    if (near == null) return PhraseNote(step: step, value: value, dotted: dotted);
    var best = PhraseNote(step: step, octave: 0, value: value, dotted: dotted);
    for (var octave = 0; octave <= 8; octave++) {
      final note = PhraseNote(step: step, octave: octave, value: value, dotted: dotted);
      if ((note.midi! - near).abs() < (best.midi! - near).abs()) best = note;
    }
    return best;
  }

  /// MIDI pitch [midi] spelled as a piano's black keys are named going up: sharps.
  static PhraseNote ofMidi(int midi, {NoteValue value = NoteValue.quarter, bool dotted = false}) {
    final pc = midi % 12, octave = midi ~/ 12 - 1;
    final step = _semitones.lastIndexWhere((s) => s <= pc);
    return PhraseNote(step: step, alter: pc - _semitones[step], octave: octave, value: value, dotted: dotted);
  }

  /// [diatonic] steps up (or down), its alteration kept.
  PhraseNote stepped(int diatonic) {
    if (step == null) return this;
    final d = this.diatonic + diatonic;
    return copyWith(step: d % 7, octave: (d ~/ 7).clamp(0, 8));
  }

  PhraseNote copyWith({int? step, int? alter, int? octave, NoteValue? value, bool? dotted}) => PhraseNote(
      step: step ?? this.step,
      alter: alter ?? this.alter,
      octave: octave ?? this.octave,
      value: value ?? this.value,
      dotted: dotted ?? this.dotted);

  @override
  bool operator ==(Object other) =>
      other is PhraseNote &&
      other.step == step &&
      other.alter == alter &&
      other.octave == octave &&
      other.value == value &&
      other.dotted == dotted;

  @override
  int get hashCode => Object.hash(step, alter, octave, value, dotted);
}

/// The clef a [Phrase] is written in: only how it looks, as the search goes by sounding pitch.
enum PhraseClef {
  /// Treble, or bass while the notes lie mostly below middle C.
  auto('G', 2, 0, 0xE050),
  treble('G', 2, 0, 0xE050),
  treble8vb('G', 2, -1, 0xE052),
  alto('C', 3, 0, 0xE05C),
  tenor('C', 4, 0, 0xE05C),
  bass('F', 4, 0, 0xE062);

  const PhraseClef(this.sign, this.line, this.octave, this.glyph);

  /// MusicXML's `<sign>` and `<line>` (from the bottom), and `<clef-octave-change>`.
  final String sign;
  final int line, octave;

  /// Its SMuFL glyph.
  final int glyph;

  /// The note on its top line, as [PhraseNote.diatonic] counts.
  int get topLine {
    final onLine = switch (sign) { 'G' => 4 * 7 + 4, 'C' => 4 * 7, _ => 3 * 7 + 3 } + 7 * octave; // G4, C4, F3
    return onLine + 2 * (5 - line);
  }
}

/// A melody to look for in the score (Find Phrase).
class Phrase {
  const Phrase(this.notes, {this.clef = PhraseClef.auto});
  static const empty = Phrase([]);

  final List<PhraseNote> notes;

  /// The clef chosen; [shownClef] the one it is written in.
  final PhraseClef clef;

  bool get isEmpty => notes.isEmpty;
  Iterable<PhraseNote> get pitched => notes.where((n) => !n.isRest);

  /// [clef], or for [PhraseClef.auto] bass while its notes lie mostly below middle C, else treble.
  PhraseClef get shownClef {
    if (clef != PhraseClef.auto) return clef;
    final pitches = [for (final n in pitched) n.midi!];
    return pitches.isNotEmpty && pitches.reduce((a, b) => a + b) / pitches.length < 57 ? PhraseClef.bass : PhraseClef.treble;
  }

  /// Where each note starts, in quarters.
  List<double> get starts {
    final starts = <double>[];
    var at = 0.0;
    for (final n in notes) {
      starts.add(at);
      at += n.quarters;
    }
    return starts;
  }

  /// One bar of it in MusicXML, for Verovio: a hidden time signature as long as the notes, eighths
  /// and shorter beamed within each quarter, and no barline at its end.
  String musicXML() {
    const divisions = 8; // 32nds dotted are the shortest: 1.5 of these
    final clef = shownClef;
    final xml = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8"?><score-partwise version="4.0">')
      ..write('<part-list><score-part id="P1"><part-name print-object="no">Phrase</part-name></score-part></part-list>')
      ..write('<part id="P1"><measure number="1"><attributes><divisions>${divisions * 2}</divisions>')
      ..write('<key print-object="no"><fifths>0</fifths></key>');
    final total = notes.fold(0.0, (t, n) => t + n.quarters);
    final sixtyFourths = math.max(16, (total * 16).round());
    xml
      ..write('<time print-object="no"><beats>$sixtyFourths</beats><beat-type>64</beat-type></time>')
      ..write('<clef><sign>${clef.sign}</sign><line>${clef.line}</line>'
          '${clef.octave == 0 ? '' : '<clef-octave-change>${clef.octave}</clef-octave-change>'}</clef>')
      ..write('</attributes>');
    if (notes.isEmpty) {
      xml.write('<note print-object="no"><rest/><duration>${divisions * 2}</duration><type>quarter</type></note>');
    }
    final beams = _beams();
    for (final (i, n) in notes.indexed) {
      xml.write('<note>');
      if (n.midi == null) {
        xml.write('<rest/>');
      } else {
        xml.write('<pitch><step>${PhraseNote.letters[n.step!]}</step>${n.alter == 0 ? '' : '<alter>${n.alter}</alter>'}<octave>${n.octave}</octave></pitch>');
      }
      xml.write('<duration>${(n.quarters * divisions * 2).round()}</duration><voice>1</voice><type>${n.value.type}</type>');
      if (n.dotted) xml.write('<dot/>');
      if (n.midi != null && n.alter != 0) {
        xml.write('<accidental>${const {-2: 'flat-flat', -1: 'flat', 1: 'sharp', 2: 'double-sharp'}[n.alter]}</accidental>');
      }
      for (final (level, kind) in beams[i].indexed) {
        xml.write('<beam number="${level + 1}">$kind</beam>');
      }
      xml.write('</note>');
    }
    xml.write('<barline location="right"><bar-style>none</bar-style></barline></measure></part></score-partwise>');
    return xml.toString();
  }

  /// Each note's beams, a MusicXML `<beam>` per level: notes of an eighth or shorter beamed
  /// together while they lie within one quarter; a rest breaks them.
  List<List<String>> _beams() {
    final result = [for (final _ in notes) <String>[]];
    final starts = this.starts;
    var i = 0;
    while (i < notes.length) {
      final beat = starts[i].floor();
      var j = i;
      while (j < notes.length &&
          !notes[j].isRest &&
          notes[j].value.beams > 0 &&
          starts[j] + notes[j].quarters <= beat + 1 + 1e-9) {
        j++;
      }
      if (j - i >= 2) {
        for (var level = 1; level <= 3; level++) {
          for (var k = i; k < j; k++) {
            if (notes[k].value.beams < level) continue;
            final before = k > i && notes[k - 1].value.beams >= level;
            final after = k + 1 < j && notes[k + 1].value.beams >= level;
            final kind = before && after
                ? 'continue'
                : before
                    ? 'end'
                    : after
                        ? 'begin'
                        : k == i
                            ? 'forward hook'
                            : 'backward hook';
            if (level == 1 || result[k].length == level - 1) result[k].add(kind);
          }
        }
      }
      i = math.max(j, i + 1);
    }
    return result;
  }
}

/// One voice of one instrument through the score, as it sounds: a chord is its top note, tied
/// notes are one, grace and cue notes are left out. A rest longer than a 4/4 bar ends it.
class ScoreLine {
  ScoreLine._(this.partId, this.staff, this.starts, this.ends, this.pitches);

  final String partId;

  /// The staff of the part (1 its first) it starts on.
  final int staff;

  /// Score quarters where each note starts and ends.
  final Float64List starts, ends;

  /// Each note's sounding MIDI pitch.
  final Int32List pitches;

  int get length => pitches.length;

  /// Every line of [musicXML]'s notes; [measureStarts] puts its bars in score quarters.
  static List<ScoreLine> read(String musicXML, List<double> measureStarts) {
    final lines = <ScoreLine>[];
    final root = XmlDocument.parse(musicXML).rootElement;
    int? number(XmlElement? e) => int.tryParse(e?.innerText.trim() ?? '');
    for (final part in root.findElements('part')) {
      final id = part.getAttribute('id') ?? '';
      final voices = <String, _LineBuilder>{};
      var divisions = 1, transpose = 0;
      for (final (m, measure) in part.findElements('measure').indexed) {
        if (m + 1 >= measureStarts.length) break;
        var cursor = 0, lastStart = 0;
        for (final e in measure.childElements) {
          switch (e.name.local) {
            case 'attributes':
              divisions = math.max(1, number(e.getElement('divisions')) ?? divisions);
              if (e.getElement('transpose') case final t?) {
                transpose = (number(t.getElement('chromatic')) ?? 0) + 12 * (number(t.getElement('octave-change')) ?? 0);
              }
            case 'backup':
              cursor = math.max(0, cursor - (number(e.getElement('duration')) ?? 0));
            case 'forward':
              cursor += number(e.getElement('duration')) ?? 0;
            case 'note':
              if (e.getElement('grace') != null || e.getElement('cue') != null) continue;
              final duration = number(e.getElement('duration')) ?? 0;
              final chord = e.getElement('chord') != null;
              final start = chord ? lastStart : cursor;
              if (!chord) {
                lastStart = cursor;
                cursor += duration;
              }
              final pitch = e.getElement('pitch');
              if (pitch == null) continue; // a rest, or unpitched percussion
              final step = PhraseNote.letters.indexOf(pitch.getElement('step')?.innerText.trim() ?? '');
              final octave = number(pitch.getElement('octave'));
              if (step < 0 || octave == null) continue;
              final alter = (double.tryParse(pitch.getElement('alter')?.innerText.trim() ?? '') ?? 0).round();
              final midi = PhraseNote(step: step, alter: alter, octave: octave).midi! + transpose;
              final from = measureStarts[m] + start / divisions;
              final voice = e.getElement('voice')?.innerText.trim() ?? '1';
              final tied = e.findElements('tie').any((t) => t.getAttribute('type') == 'stop');
              final line = voices.putIfAbsent(voice, () => _LineBuilder(id, number(e.getElement('staff')) ?? 1));
              line.add(from, from + duration / divisions, midi, chord: chord, tied: tied, flush: lines.add);
          }
        }
      }
      for (final line in voices.values) {
        line.flush(lines.add);
      }
    }
    return lines;
  }
}

class _LineBuilder {
  _LineBuilder(this.partId, this.staff);
  final String partId;
  int staff;
  final _starts = <double>[], _ends = <double>[], _pitches = <int>[];

  void add(double start, double end, int midi, {required bool chord, required bool tied, required void Function(ScoreLine) flush}) {
    final last = _pitches.length - 1;
    if (last >= 0 && chord && (_starts[last] - start).abs() < 1e-9) {
      _pitches[last] = math.max(_pitches[last], midi);
      return;
    }
    if (last >= 0 && tied && _pitches[last] == midi && (_ends[last] - start).abs() < 1e-6) {
      _ends[last] = end;
      return;
    }
    if (last >= 0 && start - _ends[last] > 4 + 1e-9) this.flush(flush);
    if (start < (_starts.lastOrNull ?? double.negativeInfinity)) return; // out of order: a damaged file
    _starts.add(start);
    _ends.add(end);
    _pitches.add(midi);
  }

  void flush(void Function(ScoreLine) to) {
    if (_pitches.isNotEmpty) {
      to(ScoreLine._(partId, staff, Float64List.fromList(_starts), Float64List.fromList(_ends), Int32List.fromList(_pitches)));
    }
    _starts.clear();
    _ends.clear();
    _pitches.clear();
  }
}

/// Where a phrase was found: notes [first]–[last] of [line], from score quarter [start] to [end].
class PhraseMatch {
  const PhraseMatch(this.line, this.first, this.last, {required this.similarity, required this.transposition});
  final ScoreLine line;
  final int first, last;

  /// 1 for the phrase exactly, down to [PhraseSearch.minSimilarity].
  final double similarity;

  /// Semitones from the phrase as entered to the score's notes (0 unless in any key).
  final int transposition;

  String get partId => line.partId;
  double get start => line.starts[first];
  double get end => line.ends[last];
}

/// Looks for a phrase in every [ScoreLine] of a score, by its notes' pitches (or, [anyKey], the
/// steps between them, so it is found in any key) and, with [rhythm], the time from each note to
/// the next. Exactly, or [similar]: an edit distance under which a note may be wrong (a step or two
/// costing half), longer or shorter, missing or extra, each costing up to a note, and a match is
/// kept while it costs at most [1 - minSimilarity] of the phrase.
abstract final class PhraseSearch {
  static const minSimilarity = 0.65;

  static List<PhraseMatch> find(Phrase phrase, List<ScoreLine> lines,
      {bool similar = false, bool anyKey = true, bool rhythm = true, int limit = 500}) {
    final notes = phrase.notes;
    final pitches = <int>[], gaps = <double?>[];
    var at = 0.0;
    double? last;
    for (final n in notes) {
      if (n.midi case final midi?) {
        if (last != null) gaps.add(at - last);
        pitches.add(midi);
        last = at;
      }
      at += n.quarters;
    }
    if (pitches.isEmpty) return const [];
    gaps.add(null); // the last note's: as long as it likes
    // A single note in any key would be every note.
    final intervals = anyKey && pitches.length > 1;
    final keys = intervals ? [for (var i = 1; i < pitches.length; i++) pitches[i] - pitches[i - 1]] : pitches;
    final times = intervals ? gaps.sublist(0, gaps.length - 1) : gaps;
    final n = keys.length;
    final maxCost = similar ? (1 - minSimilarity) * n + 1e-9 : 1e-9;

    final found = <PhraseMatch>[];
    for (final line in lines) {
      final count = intervals ? line.length - 1 : line.length;
      if (count <= 0 || (!similar && count < n)) continue;
      int keyAt(int j) => intervals ? line.pitches[j + 1] - line.pitches[j] : line.pitches[j];
      double gapAt(int j) => j + 1 < line.length ? line.starts[j + 1] - line.starts[j] : line.ends[j] - line.starts[j];
      double cost(int i, int j) {
        final d = (keys[i] - keyAt(j)).abs();
        var c = d == 0 ? 0.0 : d <= 2 ? 0.5 : 1.0;
        if (rhythm && times[i] != null) {
          final ratio = (math.log(times[i]! / gapAt(j)) / math.ln2).abs();
          if (ratio > 1e-6) c += math.min(0.5, 0.25 + ratio / 4);
        }
        return math.min(1, c);
      }

      // Sellers' approximate matching: the whole phrase against any stretch of the line, a column
      // per element of the line, each cell carrying where its alignment began.
      var cost0 = List<double>.generate(n + 1, (i) => i.toDouble()), from0 = List<int>.filled(n + 1, 0);
      var cost1 = List<double>.filled(n + 1, 0), from1 = List<int>.filled(n + 1, 0);
      final candidates = <({int from, int to, double cost})>[];
      for (var j = 0; j < count; j++) {
        cost1[0] = 0;
        from1[0] = j + 1;
        for (var i = 1; i <= n; i++) {
          var best = cost0[i - 1] + cost(i - 1, j), start = i == 1 ? j : from0[i - 1];
          if (similar) {
            if (cost0[i] + 1 < best) (best, start) = (cost0[i] + 1, from0[i]); // an extra note in the score
            if (cost1[i - 1] + 1 < best) (best, start) = (cost1[i - 1] + 1, from1[i - 1]); // one missing
          }
          cost1[i] = best;
          from1[i] = start;
        }
        if (cost1[n] <= maxCost && from1[n] <= j) candidates.add((from: from1[n], to: j, cost: cost1[n]));
        (cost0, cost1) = (cost1, cost0);
        (from0, from1) = (from1, from0);
      }
      // The best of those that overlap.
      candidates.sort((a, b) => a.cost != b.cost ? a.cost.compareTo(b.cost) : a.from.compareTo(b.from));
      final taken = <({int from, int to})>[];
      for (final c in candidates) {
        if (taken.any((t) => c.from <= t.to && t.from <= c.to)) continue;
        taken.add((from: c.from, to: c.to));
        final first = c.from, lastNote = intervals ? c.to + 1 : c.to;
        found.add(PhraseMatch(line, first, lastNote,
            similarity: (1 - c.cost / n).clamp(0, 1).toDouble(), transposition: anyKey ? line.pitches[first] - pitches.first : 0));
      }
    }
    found.sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : b.similarity.compareTo(a.similarity));
    return found.length > limit ? found.sublist(0, limit) : found;
  }
}

/// A [Phrase] engraved by Verovio, to draw in the find window: its clef and notes (the staff lines
/// are the caller's, as long as it likes), in Verovio's units.
class PhrasePicture {
  PhrasePicture._(this.phrase, this._list, this.noteXs);

  final Phrase phrase;
  final ScoreDisplayList _list;

  /// Where each note of the phrase is drawn (its notehead's left).
  final List<double> noteXs;

  EngravingData get _data => _list.data;
  double get staffSpace => _data.staffSpace;

  /// The top staff line's y.
  double get staffTop => _data.staves.first.top;

  /// Around everything it draws (null for nothing).
  late final ui.Rect? ink = _list.staves.first.items.fold<ui.Rect?>(null, (r, i) => r?.expandToInclude(i.bounds) ?? i.bounds);

  /// Where the music ends.
  double get right => _list.staves.first.items.fold(0.0, (r, i) => math.max(r, i.bounds.right));

  static Future<PhrasePicture> engrave(Phrase phrase, {String? resourceDirectory}) async {
    final data = await Engraver.engrave(phrase.musicXML(), resourceDirectory: resourceDirectory ?? engineResourceDirectory());
    final list = ScoreDisplayList.build(data, const RenderStyle());
    final measure = data.measures.firstOrNull;
    double xOf(double start) {
      if (measure == null) return 0;
      for (var k = 0; k < measure.onsetTimes.length; k++) {
        if ((measure.onsetTimes[k] - start).abs() < 1e-6) return measure.onsetXs[k];
      }
      return measure.left;
    }

    return PhrasePicture._(phrase, list, [for (final s in phrase.starts) xOf(s)]);
  }

  /// The note a staff position [y] (Verovio's units) stands for, in this picture's clef.
  PhraseNote noteAt(double y, {NoteValue value = NoteValue.quarter, bool dotted = false}) {
    final top = phrase.shownClef.topLine;
    final d = top - ((y - staffTop) / (staffSpace / 2)).round();
    return PhraseNote(step: d % 7, octave: (d ~/ 7).clamp(0, 8), value: value, dotted: dotted);
  }

  /// Draws it in [ink], at its own units (scale the canvas first).
  void paint(ui.Canvas canvas, ui.Color ink) {
    final layer = _list.staves.first, bounds = this.ink;
    if (bounds == null) return;
    canvas.saveLayer(bounds.inflate(staffSpace), ui.Paint()..colorFilter = ui.ColorFilter.mode(ink, ui.BlendMode.srcIn));
    for (final item in layer.items) {
      item.paint(canvas);
    }
    canvas.restore();
  }

  void dispose() => _list.dispose();
}
