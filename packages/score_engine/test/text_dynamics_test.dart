import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';
import 'package:score_engine/src/engraving.dart';

/// One bar, as Sibelius wrote it: an "f" as a dynamic, then one typed as text in Maestro.
const _sibelius = '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.0">
  <part-list><score-part id="P1"><part-name>Trumpet</part-name></score-part></part-list>
  <part id="P1"><measure number="1">
    <attributes><divisions>1</divisions><key><fifths>0</fifths></key><time><beats>2</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
    <direction><direction-type><dynamics default-y="-76" font-family="Maestro"><f/></dynamics></direction-type></direction>
    <note><pitch><step>B</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type></note>
    <direction><direction-type><words default-x="263" default-y="-70" justify="left" font-family="Maestro" font-weight="bold">F</words></direction-type></direction>
    <note><pitch><step>F</step><octave>5</octave></pitch><duration>1</duration><type>quarter</type></note>
  </measure></part>
</score-partwise>''';

/// How many drawing commands each class of Verovio element made.
int _drawnBy(EngravingData data, String className) {
  final index = data.classNames.indexOf(className);
  return [
    for (var i = 0; i < data.commandCount; i++)
      if (data.commandInts[i * Cmd.words + Cmd.classIndex] == index) i,
  ].length;
}

void main() {
  test('engraved as a dynamic, or as text with the flag off', () async {
    final score = await LoadedScore.load(_sibelius);
    expect(score.textDynamics, isTrue);
    final asText = await score.withEdits(textDynamics: false);
    expect(asText.textDynamics, isFalse);
    // Both "f"s are dynamics (a glyph each); off, the second is text.
    expect(_drawnBy(score.engraving, 'dynam'), 2);
    expect(_drawnBy(asText.engraving, 'dynam'), 1);
    expect(_drawnBy(asText.engraving, 'text'), _drawnBy(score.engraving, 'text') + 1);
    // The text is still listed as the file has it, so saved edits keep their ids.
    expect(score.texts.map((t) => (t.id, t.text)), asText.texts.map((t) => (t.id, t.text)));
  });
}
