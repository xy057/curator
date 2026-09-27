import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';
import 'package:score_engine/src/display_list.dart';
import 'package:score_engine/src/engraving.dart';

/// One bar: a four-note chord with an arpeggio sign.
const _arpeggio = '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="4.0">
  <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
  <part id="P1"><measure number="1">
    <attributes><divisions>1</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
    <note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><type>whole</type><notations><arpeggiate/></notations></note>
    <note><chord/><pitch><step>E</step><octave>4</octave></pitch><duration>4</duration><type>whole</type><notations><arpeggiate/></notations></note>
    <note><chord/><pitch><step>G</step><octave>4</octave></pitch><duration>4</duration><type>whole</type><notations><arpeggiate/></notations></note>
    <note><chord/><pitch><step>C</step><octave>5</octave></pitch><duration>4</duration><type>whole</type><notations><arpeggiate/></notations></note>
  </measure></part>
</score-partwise>''';

void main() {
  test('an arpeggio wiggle stands upright, as Verovio turns it', () async {
    final score = await LoadedScore.load(_arpeggio);
    final data = score.engraving;
    final arpeg = data.classNames.indexOf('arpeg');
    expect(arpeg, isNonNegative, reason: 'the chord has an arpeggio');
    final glyphs = [
      for (var i = 0; i < data.commandCount; i++)
        if (data.commandInts[i * Cmd.words + Cmd.classIndex] == arpeg) i,
    ];
    expect(glyphs, isNotEmpty);
    for (final i in glyphs) {
      expect(data.commandFloats[i * Cmd.words + Cmd.rotation], -90);
    }
    // The wiggle's ink runs up the chord: taller than wide.
    var box = ui.Rect.zero;
    for (final i in glyphs) {
      final b = i * Cmd.words + Cmd.bounds;
      final r = ui.Rect.fromLTWH(data.commandFloats[b], data.commandFloats[b + 1], data.commandFloats[b + 2], data.commandFloats[b + 3]);
      box = box == ui.Rect.zero ? r : box.expandToInclude(r);
    }
    expect(box.height, greaterThan(box.width * 2));
    // …and draws as a turned glyph.
    final display = ScoreDisplayList.build(data, const RenderStyle());
    expect(display.staves.single.items.whereType<RotatedGlyphItem>(), isNotEmpty);
  });
}
