import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'engraving.dart';
import 'engraving_writer.dart';
import 'midi_file.dart';
import 'midi_tempo.dart';
import 'number_text.dart';
import 'score_metadata.dart';
import 'spacers.dart';

/// How a MIDI score's rows are drawn (the MIDI menu's): equal looks draw it the same.
@immutable
class MidiLook {
  const MidiLook({this.rowHeight = 2.5, this.beatWidth = 4, this.sharedRange = false, this.velocity = true});

  /// A row's height and a quarter note's width, in staff spaces.
  final double rowHeight, beatWidth;

  /// Whether every row spans the same pitches (the piece's lowest to its highest), so a note's
  /// height says its register across instruments; else each spans its own instrument's.
  final bool sharedRange;

  /// Whether a note is as dark as it is loud (its velocity); else all are alike.
  final bool velocity;

  /// What [rowHeight] and [beatWidth] may be, and how much a step of the menu's changes them.
  static const rowHeights = (min: 1.0, max: 8.0), beatWidths = (min: 0.5, max: 24.0), step = 1.25;

  /// With rows a step taller ([by] 1) or shorter (−1), as far as [rowHeights] goes.
  MidiLook rows(int by) => copyWith(rowHeight: _stepped(rowHeight, by, rowHeights));

  /// With beats a step wider ([by] 1) or narrower (−1), as far as [beatWidths] goes.
  MidiLook beats(int by) => copyWith(beatWidth: _stepped(beatWidth, by, beatWidths));

  static double _stepped(double value, int by, ({double min, double max}) range) {
    final next = (value * math.pow(step, by)).clamp(range.min, range.max);
    // Rounded, so a step up and one down come back to the same value.
    return (next * 1000).roundToDouble() / 1000;
  }

  MidiLook copyWith({double? rowHeight, double? beatWidth, bool? sharedRange, bool? velocity}) => MidiLook(
      rowHeight: rowHeight ?? this.rowHeight,
      beatWidth: beatWidth ?? this.beatWidth,
      sharedRange: sharedRange ?? this.sharedRange,
      velocity: velocity ?? this.velocity);

  Map<String, Object?> toJson() => {'rowHeight': rowHeight, 'beatWidth': beatWidth, 'sharedRange': sharedRange, 'velocity': velocity};

  /// Reads [toJson]'s; what is missing or out of range is the standard's.
  factory MidiLook.fromJson(Map<String, Object?> json) {
    const standard = MidiLook();
    double size(Object? v, double otherwise, ({double min, double max}) range) =>
        v is num && v.isFinite ? v.toDouble().clamp(range.min, range.max).toDouble() : otherwise;
    return MidiLook(
        rowHeight: size(json['rowHeight'], standard.rowHeight, rowHeights),
        beatWidth: size(json['beatWidth'], standard.beatWidth, beatWidths),
        sharedRange: json['sharedRange'] is bool ? json['sharedRange'] as bool : standard.sharedRange,
        velocity: json['velocity'] is bool ? json['velocity'] as bool : standard.velocity);
  }

  @override
  bool operator ==(Object other) =>
      other is MidiLook &&
      other.rowHeight == rowHeight &&
      other.beatWidth == beatWidth &&
      other.sharedRange == sharedRange &&
      other.velocity == velocity;

  @override
  int get hashCode => Object.hash(rowHeight, beatWidth, sharedRange, velocity);
}

/// A MIDI file as a score: each channel of each track an instrument, its bars the file's time
/// signatures', its notes as played. [musicXML] is the score written for it, which everything
/// that reads a score reads (curation, sync, Align, Find Phrase); what is drawn is not
/// notation but its notes as bars of ink in a row an instrument ([engraving]), as long as
/// they sound and as high as they are.
class MidiScore {
  MidiScore._(this.musicXML, this.barLengths, this._drums, this._part, this._start, this._end, this._key, this._velocity);

  /// What the file is, as a score written for it ([ScoreMetadata] reads it): a part a channel
  /// of a track (`P1`…), its notes in voices none of which plays two at once.
  final String musicXML;

  /// Each bar's length, in quarter notes.
  final List<double> barLengths;

  // Every note: its part (0 the first), where it starts and ends (quarter notes from the
  // start), its key and velocity; and whether each part is drums.
  final List<bool> _drums;
  final Uint16List _part;
  final Float64List _start, _end;
  final Uint8List _key, _velocity;

  /// How many instruments it has, and notes.
  int get partCount => _drums.length;
  int get noteCount => _key.length;

  /// The most instruments a file may have, and bars: far more than any real piece's.
  static const maxParts = 512, maxBars = 100000;

  /// Reads the MIDI file [bytes]; [title], the score's when the file names none. Throws a
  /// [FormatException] saying why when it isn't one, or has no notes.
  static MidiScore read(Uint8List bytes, {String title = ''}) => MidiScore.of(MidiFile.read(bytes),
      tempo: MidiTempoMap.read(bytes).tempos.first.quartersPerMinute, title: title);

  /// The score [file] is, starting at [tempo] quarter notes a minute.
  factory MidiScore.of(MidiFile file, {double tempo = MidiTempoMap.defaultQuartersPerMinute, String title = ''}) {
    final voices = file.voices;
    if (voices.isEmpty) throw const FormatException('This MIDI file has no notes.');
    if (voices.length > maxParts) throw const FormatException('This MIDI file has too many tracks.');

    // Whole ticks a bar: a meter in notes shorter than a tick has the ticks made finer.
    var scale = 1;
    for (final m in file.meters) {
      while (m.count * file.division * scale * 4 % m.unit != 0) {
        scale *= 2;
      }
    }
    final divisions = file.division * scale;
    final length = file.length * scale;

    // The bars: each as long as the meter in force where it starts says (4/4 until one is).
    final bars = <({int start, int length, int count, int unit})>[];
    var meter = (count: 4, unit: 4), next = 0;
    for (var at = 0; at < length || bars.isEmpty;) {
      while (next < file.meters.length && file.meters[next].tick * scale <= at) {
        meter = (count: file.meters[next].count, unit: file.meters[next].unit);
        next++;
      }
      final ticks = meter.count * divisions * 4 ~/ meter.unit;
      bars.add((start: at, length: ticks, count: meter.count, unit: meter.unit));
      if (bars.length > maxBars) throw const FormatException('This MIDI file is too long.');
      at += ticks;
    }
    // The key in force where each bar starts.
    final fifths = <int>[];
    var key = 0, nextKey = 0;
    for (final bar in bars) {
      while (nextKey < file.keys.length && file.keys[nextKey].tick * scale <= bar.start) {
        key = file.keys[nextKey++].fifths;
      }
      fifths.add(key);
    }

    final names = _names(voices);
    final out = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">\n'
        '<score-partwise version="4.0">\n');
    final heading = file.title.isNotEmpty ? file.title : title;
    if (heading.isNotEmpty) out.write('  <work><work-title>${_escape(heading)}</work-title></work>\n');
    out.write('  <part-list>\n');
    for (final (i, v) in voices.indexed) {
      // The name says the family where it can; else the program does.
      final sound = InstrumentFamily.classify(name: names[i]) != InstrumentFamily.other
          ? null
          : v.isDrums
              ? 'drum.group.set'
              : switch (v.program) { final p? => _sound(p), null => null };
      out.write('    <score-part id="P${i + 1}"><part-name>${_escape(names[i])}</part-name>'
          '${sound == null ? '' : '<score-instrument id="P${i + 1}-I1"><instrument-name>${_escape(names[i])}</instrument-name>'
              '<instrument-sound>$sound</instrument-sound></score-instrument>'}</score-part>\n');
    }
    out.write('  </part-list>\n');

    final count = voices.fold(0, (n, v) => n + v.notes.length);
    final part = Uint16List(count), keys = Uint8List(count), velocities = Uint8List(count);
    final starts = Float64List(count), ends = Float64List(count);
    var n = 0;
    for (final (i, v) in voices.indexed) {
      out.write('  <part id="P${i + 1}">\n');
      // Each note in the first voice free where it starts (the notes of a chord, which start
      // and end together, in one), then cut at the barlines: a bar's pieces.
      final pieces = List<List<_Piece>?>.filled(bars.length, null);
      final voiceEnds = <int>[];
      var bar = 0, sum = 0;
      ({int start, int end, int voice})? chord;
      for (final note in v.notes) {
        final start = note.start * scale, end = note.end * scale;
        part[n] = i;
        keys[n] = note.key;
        velocities[n] = note.velocity;
        starts[n] = start / divisions;
        ends[n++] = end / divisions;
        sum += note.key;
        final int voice;
        if (chord != null && chord.start == start && chord.end == end) {
          voice = chord.voice;
        } else {
          final free = voiceEnds.indexWhere((e) => e <= start);
          voice = free < 0 ? voiceEnds.length : free;
          if (free < 0) {
            voiceEnds.add(end);
          } else {
            voiceEnds[free] = end;
          }
          chord = (start: start, end: end, voice: voice);
        }
        while (bar + 1 < bars.length && bars[bar + 1].start <= start) {
          bar++;
        }
        for (var b = bar; b < bars.length && bars[b].start < end; b++) {
          final from = math.max(start, bars[b].start), to = math.min(end, bars[b].start + bars[b].length);
          (pieces[b] ??= []).add(_Piece(voice, from - bars[b].start, to - bars[b].start, note.key, tiedBack: from > start, tiedOn: to < end));
        }
      }
      final low = !v.isDrums && v.notes.isNotEmpty && sum / v.notes.length < 55;
      for (final (b, bar) in bars.indexed) {
        out.write('    <measure number="${b + 1}">\n');
        final meterChange = b == 0 || bar.count != bars[b - 1].count || bar.unit != bars[b - 1].unit;
        final keyChange = b == 0 || fifths[b] != fifths[b - 1];
        if (meterChange || keyChange) {
          out.write('      <attributes>');
          if (b == 0) out.write('<divisions>$divisions</divisions>');
          if (keyChange) out.write('<key><fifths>${fifths[b]}</fifths></key>');
          if (meterChange) out.write('<time><beats>${bar.count}</beats><beat-type>${bar.unit}</beat-type></time>');
          if (b == 0) {
            out.write(v.isDrums
                ? '<clef><sign>percussion</sign></clef>'
                : '<clef><sign>${low ? 'F' : 'G'}</sign><line>${low ? 4 : 2}</line></clef>');
          }
          out.write('</attributes>\n');
        }
        if (b == 0 && i == 0) out.write('      <sound tempo="${plainNumber(tempo, digits: 3)}"/>\n');
        final own = pieces[b];
        if (own == null) {
          out.write('      <note><rest measure="yes"/><duration>${bar.length}</duration><voice>1</voice></note>\n');
        } else {
          // A voice at a time, the higher first of the notes starting together.
          own.sort((a, c) => a.voice != c.voice
              ? a.voice.compareTo(c.voice)
              : a.start != c.start
                  ? a.start.compareTo(c.start)
                  : c.key.compareTo(a.key));
          var cursor = 0, voice = own.first.voice;
          _Piece? before;
          for (final p in own) {
            if (p.voice != voice) {
              if (cursor > 0) out.write('      <backup><duration>$cursor</duration></backup>\n');
              cursor = 0;
              voice = p.voice;
              before = null;
            }
            final joins = before != null && before.start == p.start && before.end == p.end;
            if (!joins && p.start > cursor) out.write('      <forward><duration>${p.start - cursor}</duration></forward>\n');
            out
              ..write('      <note>')
              ..write(joins ? '<chord/>' : '')
              ..write(v.isDrums ? _unpitched(p.key) : _pitch(p.key, fifths[b]))
              ..write('<duration>${p.end - p.start}</duration>')
              ..write(p.tiedBack ? '<tie type="stop"/>' : '')
              ..write(p.tiedOn ? '<tie type="start"/>' : '')
              ..write('<voice>${p.voice + 1}</voice></note>\n');
            if (!joins) cursor = p.end;
            before = p;
          }
        }
        out.write('    </measure>\n');
      }
      out.write('  </part>\n');
    }
    out.write('</score-partwise>\n');
    return MidiScore._(out.toString(), [for (final b in bars) b.length / divisions], [for (final v in voices) v.isDrums], part, starts, ends,
        keys, velocities);
  }

  /// A name for each of [voices]: its track's, with what its channel plays when the track has
  /// several; a track without one, what it plays, or its number.
  static List<String> _names(List<MidiVoice> voices) {
    final perTrack = <int, int>{};
    for (final v in voices) {
      perTrack[v.track] = (perTrack[v.track] ?? 0) + 1;
    }
    String plays(MidiVoice v) => v.isDrums ? 'Drums' : switch (v.program) { final p? => programNames[p], null => 'Channel ${v.channel + 1}' };
    return [
      for (final v in voices)
        if (perTrack[v.track]! > 1)
          v.name.isEmpty ? plays(v) : '${v.name} (${plays(v)})'
        else if (v.name.isNotEmpty)
          v.name
        else if (v.isDrums || v.program != null)
          plays(v)
        else
          'Track ${v.track + 1}',
    ];
  }

  static String _escape(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  /// [key] spelled for a key of [fifths]: with flats in a flat key, else sharps.
  static String _pitch(int key, int fifths) {
    const sharps = [('C', 0), ('C', 1), ('D', 0), ('D', 1), ('E', 0), ('F', 0), ('F', 1), ('G', 0), ('G', 1), ('A', 0), ('A', 1), ('B', 0)];
    const flats = [('C', 0), ('D', -1), ('D', 0), ('E', -1), ('E', 0), ('F', 0), ('G', -1), ('G', 0), ('A', -1), ('A', 0), ('B', -1), ('B', 0)];
    final (step, alter) = (fifths < 0 ? flats : sharps)[key % 12];
    return '<pitch><step>$step</step>${alter == 0 ? '' : '<alter>$alter</alter>'}<octave>${key ~/ 12 - 1}</octave></pitch>';
  }

  /// A drum's [key] as an unpitched note, on the line or space its white key would be.
  static String _unpitched(int key) {
    const steps = ['C', 'C', 'D', 'D', 'E', 'F', 'F', 'G', 'G', 'A', 'A', 'B'];
    return '<unpitched><display-step>${steps[key % 12]}</display-step><display-octave>${key ~/ 12 - 1}</display-octave></unpitched>';
  }

  /// The MusicXML sound nearest General MIDI program [program] (0–127): what says an
  /// instrument's family ([InstrumentFamily.classify]) when its name doesn't.
  static String _sound(int program) => switch (program) {
        6 => 'keyboard.harpsichord',
        7 => 'keyboard.clavichord',
        < 8 => 'keyboard.piano',
        8 => 'keyboard.celesta',
        9 => 'pitched-percussion.glockenspiel',
        10 => 'pitched-percussion.music-box',
        11 => 'pitched-percussion.vibraphone',
        12 => 'pitched-percussion.marimba',
        13 => 'pitched-percussion.xylophone',
        14 => 'pitched-percussion.tubular-bells',
        15 => 'pluck.dulcimer',
        21 => 'keyboard.accordion',
        22 => 'wind.reed.harmonica',
        23 => 'keyboard.bandoneon',
        < 24 => 'keyboard.organ',
        < 32 => 'pluck.guitar',
        < 40 => 'pluck.bass',
        40 => 'strings.violin',
        41 => 'strings.viola',
        42 => 'strings.cello',
        43 => 'strings.contrabass',
        46 => 'pluck.harp',
        47 => 'drum.timpani',
        < 52 => 'strings.group',
        52 => 'voice.aa',
        53 => 'voice.oo',
        54 => 'voice.synth',
        55 => 'synth.effect',
        56 || 59 => 'brass.trumpet',
        57 => 'brass.trombone',
        58 => 'brass.tuba',
        60 => 'brass.french-horn',
        < 64 => 'brass.group',
        < 68 => 'wind.reed.saxophone',
        68 => 'wind.reed.oboe',
        69 => 'wind.reed.english-horn',
        70 => 'wind.reed.bassoon',
        71 => 'wind.reed.clarinet',
        72 => 'wind.flutes.flute.piccolo',
        73 => 'wind.flutes.flute',
        74 => 'wind.flutes.recorder',
        75 => 'wind.flutes.panpipes',
        76 => 'wind.flutes.blown-bottle',
        77 => 'wind.flutes.shakuhachi',
        78 => 'wind.flutes.whistle',
        79 => 'wind.flutes.ocarina',
        < 104 => 'synth.tone',
        104 => 'pluck.sitar',
        105 => 'pluck.banjo',
        106 => 'pluck.shamisen',
        107 => 'pluck.koto',
        108 => 'pitched-percussion.kalimba',
        109 => 'wind.pipes.bagpipes',
        110 => 'strings.fiddle',
        111 => 'wind.reed.shenai',
        112 => 'metal.bells.tinklebell',
        113 => 'metal.bells.agogo',
        114 => 'metal.steel-drums',
        115 => 'wood.wood-block',
        116 => 'drum.taiko',
        117 || 118 => 'drum.tom-tom',
        119 => 'metal.cymbal.reverse',
        _ => 'effect.fx',
      };

  /// The General MIDI programs' names, as the standard has them (0–127).
  static const programNames = [
    'Acoustic Grand Piano', 'Bright Acoustic Piano', 'Electric Grand Piano', 'Honky-tonk Piano', 'Electric Piano 1', 'Electric Piano 2', //
    'Harpsichord', 'Clavinet', 'Celesta', 'Glockenspiel', 'Music Box', 'Vibraphone', 'Marimba', 'Xylophone', 'Tubular Bells', 'Dulcimer', //
    'Drawbar Organ', 'Percussive Organ', 'Rock Organ', 'Church Organ', 'Reed Organ', 'Accordion', 'Harmonica', 'Tango Accordion', //
    'Acoustic Guitar (nylon)', 'Acoustic Guitar (steel)', 'Electric Guitar (jazz)', 'Electric Guitar (clean)', 'Electric Guitar (muted)', //
    'Overdriven Guitar', 'Distortion Guitar', 'Guitar Harmonics', 'Acoustic Bass', 'Electric Bass (finger)', 'Electric Bass (pick)', //
    'Fretless Bass', 'Slap Bass 1', 'Slap Bass 2', 'Synth Bass 1', 'Synth Bass 2', 'Violin', 'Viola', 'Cello', 'Contrabass', //
    'Tremolo Strings', 'Pizzicato Strings', 'Orchestral Harp', 'Timpani', 'String Ensemble 1', 'String Ensemble 2', 'Synth Strings 1', //
    'Synth Strings 2', 'Choir Aahs', 'Voice Oohs', 'Synth Voice', 'Orchestra Hit', 'Trumpet', 'Trombone', 'Tuba', 'Muted Trumpet', //
    'French Horn', 'Brass Section', 'Synth Brass 1', 'Synth Brass 2', 'Soprano Sax', 'Alto Sax', 'Tenor Sax', 'Baritone Sax', 'Oboe', //
    'English Horn', 'Bassoon', 'Clarinet', 'Piccolo', 'Flute', 'Recorder', 'Pan Flute', 'Blown Bottle', 'Shakuhachi', 'Whistle', 'Ocarina', //
    'Lead 1 (square)', 'Lead 2 (sawtooth)', 'Lead 3 (calliope)', 'Lead 4 (chiff)', 'Lead 5 (charang)', 'Lead 6 (voice)', 'Lead 7 (fifths)', //
    'Lead 8 (bass + lead)', 'Pad 1 (new age)', 'Pad 2 (warm)', 'Pad 3 (polysynth)', 'Pad 4 (choir)', 'Pad 5 (bowed)', 'Pad 6 (metallic)', //
    'Pad 7 (halo)', 'Pad 8 (sweep)', 'FX 1 (rain)', 'FX 2 (soundtrack)', 'FX 3 (crystal)', 'FX 4 (atmosphere)', 'FX 5 (brightness)', //
    'FX 6 (goblins)', 'FX 7 (echoes)', 'FX 8 (sci-fi)', 'Sitar', 'Banjo', 'Shamisen', 'Koto', 'Kalimba', 'Bagpipe', 'Fiddle', 'Shanai', //
    'Tinkle Bell', 'Agogo', 'Steel Drums', 'Woodblock', 'Taiko Drum', 'Melodic Tom', 'Synth Drum', 'Reverse Cymbal', 'Guitar Fret Noise', //
    'Breath Noise', 'Seashore', 'Bird Tweet', 'Telephone Ring', 'Helicopter', 'Applause', 'Gunshot',
  ];

  // MARK: Drawing

  /// Device units a staff space, as the other drawn scores have it.
  static const unit = 20.0;
  static const _lead = 2 * unit, _rowGap = 2 * unit;

  /// The engraving it is drawn as with [look]: a row for each of [metadata]'s parts (the score
  /// written for it, with any vertical spacers' parts after its own, each an empty row), the
  /// bars end to end, as wide as they are long. Each row holds its bars' barlines, faint, and
  /// its notes, on the paper an engraved score is on (no ground of its own); nothing in it is a
  /// clef, a key or a time signature, so the frozen zone has no room to keep.
  EngravingData engraving(ScoreMetadata metadata, [MidiLook look = const MidiLook()]) {
    final quarter = look.beatWidth * unit, height = look.rowHeight * unit;
    final measures = <MeasureLayout>[];
    var at = 0.0;
    for (final length in barLengths) {
      measures.add(MeasureLayout(
          left: _lead + at * quarter,
          right: _lead + (at + length) * quarter,
          duration: length,
          onsetTimes: Float64List(0),
          onsetXs: Float64List(0)));
      at += length;
    }
    final right = _lead + at * quarter;

    // Each part's lowest and highest key; with [MidiLook.sharedRange], the pitched parts' own
    // are all the piece's (a drum's keys are no pitches).
    final lows = List.filled(partCount, 127), highs = List.filled(partCount, 0);
    for (var i = 0; i < noteCount; i++) {
      lows[_part[i]] = math.min(lows[_part[i]], _key[i]);
      highs[_part[i]] = math.max(highs[_part[i]], _key[i]);
    }
    if (look.sharedRange) {
      var low = 127, high = 0;
      for (var p = 0; p < partCount; p++) {
        if (_drums[p]) continue;
        low = math.min(low, lows[p]);
        high = math.max(high, highs[p]);
      }
      for (var p = 0; p < partCount; p++) {
        if (_drums[p]) continue;
        lows[p] = low;
        highs[p] = high;
      }
    }

    final w = CommandWriter()..fontNames = const [];
    final barline = w.classOf('midiBarline'), note = w.classOf('midiNote');
    final staves = <StaffInfo>[];
    final tops = <int, double>{}; // part → its row's top
    final numbers = <int, int>{}; // part → its staff number
    for (final (row, part) in metadata.parts.indexed) {
      final n = part.staffNumbers.first, top = row * (height + _rowGap);
      staves.add(StaffInfo(n: n, top: top, height: height, lines: 0));
      if (Spacers.isSpacer(part.id)) continue;
      final index = (int.tryParse(part.id.substring(1)) ?? 0) - 1;
      if (index < 0 || index >= partCount) continue;
      tops[index] = top;
      numbers[index] = n;
      const line = 0.05 * unit; // half a barline's width
      for (final m in measures) {
        w.rect(n, barline, ui.Rect.fromLTRB(m.left - line, top, m.left + line, top + height), fade: 0.8);
      }
      w.rect(n, barline, ui.Rect.fromLTRB(right - line, top, right + line, top + height), fade: 0.8);
    }

    // A note's bar is as thick as a key's share of the row, within reason; a row spans an
    // octave at least, so two notes a step apart aren't its top and bottom.
    const pad = 0.2 * unit;
    for (var i = 0; i < noteCount; i++) {
      final p = _part[i], top = tops[p], n = numbers[p];
      if (top == null || n == null) continue;
      var low = lows[p], high = highs[p];
      if (high - low < 12) {
        final more = 12 - (high - low);
        low -= more ~/ 2;
        high += more - more ~/ 2;
      }
      final thickness = ((height - 2 * pad) / (high - low + 1)).clamp(0.26 * unit, 0.6 * unit).clamp(0.0, height - 2 * pad).toDouble();
      final y = top + pad + (high - _key[i]) / (high - low) * (height - 2 * pad - thickness);
      final x0 = _lead + _start[i] * quarter, x1 = _lead + _end[i] * quarter;
      // Cut a little short, so one struck again shows as two.
      final gap = math.min(0.15 * unit, (x1 - x0) * 0.3);
      w.rect(n, note, ui.Rect.fromLTRB(x0, y, math.max(x0 + 0.15 * unit, x1 - gap), y + thickness),
          fade: look.velocity ? 0.65 * (1 - (_velocity[i] / 127).clamp(0.0, 1.0)) : 0);
    }
    return w.build(null,
        staffSpace: unit, width: right + _lead, staves: staves, measures: measures, signatures: const [], warnings: const [], engravingDefaults: const {});
  }
}

/// A note's part in one bar, in ticks from the bar's start; [tiedBack] and [tiedOn]: it goes
/// on from the bar before, into the next.
class _Piece {
  _Piece(this.voice, this.start, this.end, this.key, {required this.tiedBack, required this.tiedOn});
  final int voice, start, end, key;
  final bool tiedBack, tiedOn;
}
