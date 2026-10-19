import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';


Meter meter(String beats, String type) => Meter.fromMusicXML([(beats, type)])!;

void main() {
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
}
