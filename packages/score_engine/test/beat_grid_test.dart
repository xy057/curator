import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_score.dart';

Meter meter(String beats, String type) => Meter.fromMusicXML([(beats, type)])!;

void main() {
  test('beats follow the kind of time signature', () {
    expect(meter('4', '4').beatLengths, [1, 1, 1, 1]);
    expect(meter('2', '2').beatLengths, [2, 2]); // alla breve: two minims
    expect(meter('6', '8').beatLengths, [1.5, 1.5]); // compound duple: two dotted crotchets
    expect(meter('9', '8').beatLengths, [1.5, 1.5, 1.5]);
    expect(meter('12', '16').beatLengths, [0.75, 0.75, 0.75, 0.75]);
    expect(meter('3', '8').beatLengths, [0.5, 0.5, 0.5]); // simple: three quavers
    expect(meter('2+2+3', '8').beatLengths, [1, 1, 1.5]); // additive
    expect(meter('6', '8').label, '6/8');
    expect(Meter.fromMusicXML([('x', '4')]), isNull);
  });

  test('a grid mixes meters, and an upbeat counts back from the barline', () {
    // Bar 1: a one-quaver upbeat in 6/8 · bar 2: 6/8 · bar 3: 3/4.
    final grid = BeatGrid([0, 0.5, 3.5, 6.5],
        meters: [meter('6', '8'), meter('6', '8'), meter('3', '4')], pickups: {0});
    expect(grid.beatsIn(0), [0]); // the upbeat is the tail of a beat: only its barline
    expect(grid.beatsIn(1), [0.5, 2]);
    expect(grid.beatsIn(2), [3.5, 4.5, 5.5]);

    expect(grid.beatAt(2.7), (start: 2.0, end: 3.5));
    expect(grid.position(2.75), (measure: 1, beat: 1.5));
    expect(grid.quarterAt(1, 1.5), 2.75);
    expect(grid.quarterAt(1, 2), isNull); // 6/8 has two beats
    expect(grid.quarterAt(3, 0), 6.5); // the end of the piece
  });

  test('a longer upbeat keeps its own beats', () {
    final grid = BeatGrid([0, 2, 6], meters: [meter('4', '4'), meter('4', '4')], pickups: {0});
    expect(grid.beatsIn(0), [0, 1]); // beats 3 and 4 of a 4/4 bar
  });

  test('the sync grid taps and shifts by the real beats', () {
    final sync = SyncMap(measureStarts: [0, 3, 6, 9], defaultTempo: 120, beats: BeatGrid([0, 3, 6, 9], meters: List.filled(3, meter('6', '8'))));
    expect(sync.nextGrid(3, SyncGrid.beat), 4.5);
    expect(sync.nearestGrid(4, SyncGrid.beat), 4.5);
    expect(sync.beats.format(4.5), '2.2');
  });

  test('time signatures are read from MusicXML', () {
    final metadata = ScoreMetadata.read(demoScore());
    expect(metadata.meters.first?.label, '6/8');
    expect(metadata.meters.first?.beatLengths, [1.5, 1.5]);
    expect(metadata.meters, hasLength(metadata.activeMeasures.values.first.length));
  });

  test('positions are written and read as bar.beat, in the meter\'s own beats', () {
    final sixEight = Meter.fromMusicXML([('6', '8')]);
    final grid = BeatGrid([0, 3, 6, 10], meters: [sixEight, sixEight, Meter.quarters]);
    expect(grid.format(3), '2.1');
    expect(grid.format(3, compact: true), '2');
    expect(grid.format(4.5), '2.2'); // the second dotted crotchet
    expect(grid.format(3.75), '2.1.50');
    expect(grid.format(4.5, compact: true), '2.2');
    for (final q in [0.0, 3.0, 4.5, 3.75, 8.0]) {
      expect(grid.parse(grid.format(q)), q);
    }
    expect(grid.parse('2.3'), isNull); // no third beat in 6/8
    expect(grid.parse('4'), 10); // the end of the piece
    expect(grid.parse('two'), isNull);
  });

  test('the score\'s tempo is the first <sound tempo> above 0', () {
    String score(List<String> tempos) => '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Flute</part-name></score-part></part-list>
<part id="P1">${[for (final (i, t) in tempos.indexed) '<measure number="${i + 1}"><direction><sound tempo="$t"/></direction></measure>'].join()}</part>
</score-partwise>''';
    expect(ScoreMetadata.read(score(['0', 'NaN', 'INF', '-60', 'Infinity', '72'])).tempo, 72);
    expect(ScoreMetadata.read(score(['0'])).tempo, isNull, reason: 'none: the default tempo is used');
  });
}
