import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

/// A partwise score of one part, a bar for each of [bars] (what goes inside its `<measure>`,
/// besides a whole note), its first bar in 4/4.
String score(List<String> bars, {int parts = 1}) => '''
<score-partwise version="4.0"><part-list>${[for (var p = 1; p <= parts; p++) '<score-part id="P$p"><part-name>P$p</part-name></score-part>'].join()}</part-list>
${[
      for (var p = 1; p <= parts; p++)
        '<part id="P$p">${[
          for (final (i, bar) in bars.indexed)
            '<measure number="${i + 1}">${i == 0 ? '<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>' : ''}'
                '${p == 1 ? bar : _barlinesOnly(bar)}<note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration></note></measure>',
        ].join()}</part>',
    ].join()}
</score-partwise>''';

/// Only the barlines of [bar]: what other parts repeat.
String _barlinesOnly(String bar) => RegExp(r'<barline.*?</barline>').allMatches(bar).map((m) => m[0]).join();

const forward = '<barline location="left"><repeat direction="forward"/></barline>';
String backward([int? times]) => '<barline location="right"><repeat direction="backward"${times == null ? '' : ' times="$times"'}/></barline>';
String endingStart(String n) => '<barline location="left"><ending number="$n" type="start"/></barline>';
String endingStop(String n, {String type = 'stop', int? repeatTimes, bool repeat = false}) =>
    '<barline location="right"><ending number="$n" type="$type"/>${repeat || repeatTimes != null ? '<repeat direction="backward"${repeatTimes == null ? '' : ' times="$repeatTimes"'}/>' : ''}</barline>';
String sound(String attributes) => '<direction><direction-type><words>x</words></direction-type><sound $attributes/></direction>';
const segnoSymbol = '<direction><direction-type><segno/></direction-type></direction>';
const codaSymbol = '<direction><direction-type><coda/></direction-type></direction>';

List<int> order(List<String> bars) => ScoreMetadata.read(score(bars)).form.playedOrder();

void main() {
  test('straight through: every bar once, no warps', () {
    final form = ScoreMetadata.read(score(['', '', ''])).form;
    expect(form.hasJumps, isFalse);
    expect(form.playedOrder(), [0, 1, 2]);
    expect(form.warps([0, 4, 8, 12]), isEmpty);
  });

  test('a repeat goes back to its forward repeat, or the start without one', () {
    expect(order(['', forward, backward(), '']), [0, 1, 2, 1, 2, 3]);
    expect(order(['', backward(), '']), [0, 1, 0, 1, 2]);
    expect(order([forward, backward(3)]), [0, 1, 0, 1, 0, 1], reason: 'times="3"');
    expect(order(['', backward(), forward, backward()]), [0, 1, 0, 1, 2, 3, 2, 3]);
    expect(order(['', backward(), '', backward()]), [0, 1, 0, 1, 2, 3, 2, 3], reason: 'the next stretch starts after the last repeat');
  });

  test('first and second endings', () {
    final bars = [forward, '', endingStart('1') + endingStop('1', repeat: true), endingStart('2') + endingStop('2', type: 'discontinue'), ''];
    expect(order(bars), [0, 1, 2, 0, 1, 3, 4]);
    // A two-bar first ending.
    expect(order(['', endingStart('1'), endingStop('1', repeat: true), endingStart('2') + endingStop('2'), '']), [0, 1, 2, 0, 3, 4]);
  });

  test('an ending for two times through, then a third', () {
    final bars = ['', endingStart('1, 2') + endingStop('1, 2', repeat: true), endingStart('3') + endingStop('3', type: 'discontinue')];
    expect(order(bars), [0, 1, 0, 1, 0, 2], reason: 'the repeat counts as many times as the endings need');
  });

  test('D.C. al Fine: repeats left out after the jump', () {
    final bars = [forward, backward() + sound('fine="yes"'), '', sound('dacapo="yes"')];
    expect(order(bars), [0, 1, 0, 1, 2, 3, 0, 1]);
  });

  test('D.C. takes the last ending', () {
    final bars = ['', endingStart('1') + endingStop('1', repeat: true), endingStart('2') + endingStop('2'), sound('dacapo="yes"')];
    expect(order(bars), [0, 1, 0, 2, 3, 0, 2, 3]);
  });

  test('a repeat with after-jump is taken after a D.C. too', () {
    final bars = ['', '<barline location="right"><repeat direction="backward" after-jump="yes"/></barline>', sound('dacapo="yes"')];
    expect(order(bars), [0, 1, 0, 1, 2, 0, 1, 0, 1, 2]);
  });

  test('D.S. al Coda by name, and by symbols alone', () {
    final named = ['', sound('segno="segno"'), sound('tocoda="coda"'), sound('dalsegno="segno"'), sound('coda="coda"')];
    expect(order(named), [0, 1, 2, 3, 1, 2, 4]);
    final symbols = ['', segnoSymbol, sound('tocoda="x"') + codaSymbol, sound('dalsegno="y"'), codaSymbol, ''];
    expect(order(symbols), [0, 1, 2, 3, 1, 2, 4, 5], reason: 'the coda after the To Coda');
  });

  test('a jump is taken once', () {
    expect(order(['', sound('dacapo="yes"'), sound('dacapo="yes"')]), [0, 1, 0, 1, 2, 0, 1, 2]);
  });

  test('repeats are read from the first part, jumps from any part', () {
    final xml = score(['', backward(), ''], parts: 2).replaceFirst('<part id="P2"><measure number="1">', '<part id="P2"><measure number="1">${sound('segno="s"')}');
    final form = ScoreMetadata.read(xml).form;
    expect(form.bars[0].segnos, {'s'});
    expect(form.playedOrder(), [0, 1, 0, 1, 2]);
  });

  test('warps jump where the next bar played isn’t the next in the score', () {
    final form = ScoreMetadata.read(score(['', forward, endingStart('1') + endingStop('1', repeat: true), endingStart('2') + endingStop('2'), ''])).form;
    final starts = <double>[0, 1, 5, 9, 13, 17]; // an upbeat of a quarter
    expect(form.warps(starts), [(at: 9.0, jumpTo: 1.0), (at: 13.0, jumpTo: 9.0)], reason: 'back, then over the first ending');
    expect(form.playedQuarters(starts), 1 + 4 + 4 + 4 + 4 + 4);
    // The warps make a MIDI tempo map walk the same passes.
    final map = MidiTempoMap('m', [(quarter: 0, quartersPerMinute: 60)], warps: form.warps(starts));
    expect(map.fits(17), isTrue);
    expect(map.arrivals(17), [9.0, 5.0]);
    expect(form.warps([0, 4]), isEmpty, reason: 'bars that don’t match the score');
  });

  test('a form that never ends stops', () {
    final form = ScoreForm([const BarForm(forward: true, backward: 1 << 30)]);
    expect(form.playedOrder().length, lessThanOrEqualTo(32));
  });
}
