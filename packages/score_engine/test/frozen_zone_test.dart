import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_score.dart';

void main() {
  late LoadedScore score;
  late CuratedScene scene;

  setUpAll(() async {
    // The demo with a change to A♭ major (concert) at bar 29.
    score = await LoadedScore.load(demoScoreWithKeyChange(bar: 29, concertFifths: -4));
    scene = CuratedScene(score);
  });

  int staffOf(String name) => score.metadata.parts.firstWhere((p) => p.name == name).staffNumbers.first;

  ({ClefSignature? clef, KeySignature? key, TimeSignature? time}) stateAt(String part, int measureIndex) {
    final measure = score.engraving.measures[measureIndex];
    return scene.renderer.frozen!.stateAt(staffOf(part), measure.onsetXs.first);
  }

  test('the zone shows each part\'s opening clef and written key', () {
    expect(stateAt('Oboe 1', 3).key?.fifths ?? 0, 0); // C major
    expect(stateAt('Clarinet in B♭ 1', 3).key?.fifths, 2); // written D major
    expect(stateAt('Horn in F 1', 3).key?.fifths, 1); // written G major
    expect(stateAt('Bassoon 1', 3).clef?.shape, ClefShape.f);
    expect(stateAt('Viola', 3).clef?.shape, ClefShape.c);
    expect(stateAt('Snare Drum', 3).clef?.shape, ClefShape.percussion);
  });

  test('a key change takes over the zone once it passes, in each part\'s written key', () {
    expect(stateAt('Oboe 1', 27).key?.fifths ?? 0, 0); // not yet
    expect(stateAt('Oboe 1', 29).key?.fifths, -4);
    expect(stateAt('Clarinet in B♭ 1', 29).key?.fifths, -2);
    expect(stateAt('Horn in F 1', 29).key?.fifths, -3);
    expect(stateAt('Trumpet in B♭ 1', 29).key?.fifths, -2);
  });

  test('the opening time signature is pinned in the zone and left out of the scrolling score', () {
    final zone = scene.renderer.frozen!;
    for (final part in ['Oboe 1', 'Horn in F 1', 'Bassoon 1']) {
      final time = stateAt(part, 3).time;
      expect((time?.count, time?.unit), (6, 8), reason: part);
    }
    final opening = score.engraving.signatures.whereType<TimeSignature>().where((t) => t.x < score.engraving.measures.first.onsetXs.first);
    expect(opening, isNotEmpty);
    for (final t in opening) {
      expect(zone.openingCommands, contains(t.commandStart));
    }
  });

  test('an additive time signature is pinned as written, and beats in its groups', () async {
    final additive = await LoadedScore.load(demoScoreWithBeats('2+2+2'));
    final time = additive.engraving.signatures.whereType<TimeSignature>().first;
    expect((time.count, time.unit), (6, 8));
    expect(time.summands, [2, 2, 2]);
    expect(additive.beats.beatsIn(1), [3, 4, 5]); // three crotchet groups, not two dotted ones
    final wider = CuratedScene(additive);
    expect(wider.renderer.frozen!.width, greaterThan(scene.renderer.frozen!.width), reason: '"2+2+2" takes more room than "6"');
    wider.dispose();
  });
}
