import 'dart:io';

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

  test('the zone shows each part\'s opening clef, written key and time; a key change takes it over once it passes', () {
    expect(stateAt('Oboe 1', 3).key?.fifths ?? 0, 0); // C major
    expect(stateAt('Clarinet in B♭ 1', 3).key?.fifths, 2); // written D major
    expect(stateAt('Horn in F 1', 3).key?.fifths, 1); // written G major
    expect(stateAt('Bassoon 1', 3).clef?.shape, ClefShape.f);
    expect(stateAt('Viola', 3).clef?.shape, ClefShape.c);
    expect(stateAt('Snare Drum', 3).clef?.shape, ClefShape.percussion);
    for (final part in ['Oboe 1', 'Horn in F 1', 'Bassoon 1']) {
      final time = stateAt(part, 3).time;
      expect((time?.count, time?.unit), (6, 8), reason: part);
    }
    // The opening time signature is pinned there, and left out of the scrolling score.
    final opening = score.engraving.signatures.whereType<TimeSignature>().where((t) => t.x < score.engraving.measures.first.onsetXs.first);
    expect(opening, isNotEmpty);
    for (final t in opening) {
      expect(scene.renderer.frozen!.openingCommands, contains(t.commandStart));
    }

    expect(stateAt('Oboe 1', 27).key?.fifths ?? 0, 0); // not yet
    expect(stateAt('Oboe 1', 29).key?.fifths, -4);
    expect(stateAt('Clarinet in B♭ 1', 29).key?.fifths, -2);
    expect(stateAt('Horn in F 1', 29).key?.fifths, -3);
    expect(stateAt('Trumpet in B♭ 1', 29).key?.fifths, -2);
  });

  test("the zone is laid out for the music font's own glyphs and lines", () async {
    final work = Directory.systemTemp.createTempSync('zone_fonts');
    FontResources.workDirectory = work.path;
    addTearDown(() {
      FontResources.workDirectory = null;
      work.deleteSync(recursive: true);
    });
    final thin = EngraveOption.byKey('engravingDefaults.thinBarlineThickness')!;
    final petaluma = await LoadedScore.load(demoScoreWithKeyChange(bar: 5, concertFifths: 3),
        fonts: const ScoreFonts(music: MusicFont.petaluma), options: const EngravingOptions().withValue(thin, 0.3));
    final bravura = await LoadedScore.load(demoScoreWithKeyChange(bar: 5, concertFifths: 3));
    // Petaluma's sharp is 380 units wide to Bravura's 249, its widest clef 776 to 699, its
    // widest digit 680 to 470: each takes Bravura's room in that proportion.
    expect(petaluma.engraving.glyphs[0xE262]?.advance, 380 / 250);
    double sharps(LoadedScore score) {
      final n = score.metadata.parts.firstWhere((p) => p.name == 'Oboe 1').staffNumbers.first;
      return FrozenZone(score.engraving, const RenderStyle()).keyColumnChanges(n).single.after;
    }

    expect(sharps(bravura), closeTo(1.0 + 3 * 1.1, 1e-9));
    expect(sharps(petaluma), closeTo(1.0 + 3 * 1.1 * 380 / 249, 1e-9));
    final style = const RenderStyle();
    double width(LoadedScore score) => FrozenZone(score.engraving, style).widthFor(0) / style.staffSpace;
    expect(width(petaluma) - width(bravura), closeTo(2.8 * (776 / 699 - 1) + 1.9 * (680 / 470 - 1), 1e-9));
    // The lines are the engraving's: a thin barline as the user set it.
    expect(petaluma.engraving.engravingDefaults['thinBarlineThickness'], 0.3);
    expect(bravura.engraving.engravingDefaults['thinBarlineThickness'], 0.16);
  });
}
