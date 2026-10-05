import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';
import 'package:score_engine/src/engraving.dart';

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

  test('a change to C major draws a natural for each accidental it cancels, in the scrolling score', () async {
    // B major from bar 5, then C major at bar 17: Oboe 1 drops five sharps, the clarinets
    // (written D major at both ends of the piece, C♯ major between) only those beyond two.
    final changes = await LoadedScore.load(demoScoreWithKeyChanges({5: 5, 17: 0}));
    final data = changes.engraving;
    List<int> glyphs(String part, int fifths) {
      final n = changes.metadata.parts.firstWhere((p) => p.name == part).staffNumbers.first;
      final sig = data.signatures.whereType<KeySignature>().lastWhere((k) => k.staff == n && k.fifths == fifths);
      return [for (var i = sig.commandStart; i < sig.commandStart + sig.commandCount; i++) data.commandInts[i * Cmd.words + Cmd.codepoint]];
    }

    const natural = 0xE261, sharp = 0xE262;
    expect(glyphs('Oboe 1', 0), List.filled(5, natural));
    expect(glyphs('Violin I', 0), List.filled(5, natural));
    expect(glyphs('Clarinet in B♭ 1', 2), List.filled(2, sharp), reason: 'fewer sharps cancel nothing unless the score asks');
  });

  test('a change to no key signature takes over the zone too, though only naturals are drawn for it', () async {
    // B major from bar 5, then C major at bar 17.
    final changes = await LoadedScore.load(demoScoreWithKeyChanges({5: 5, 17: 0}));
    final scene = CuratedScene(changes);
    int? fifths(String part, int bar) {
      final n = changes.metadata.parts.firstWhere((p) => p.name == part).staffNumbers.first;
      return scene.renderer.frozen!.stateAt(n, changes.engraving.measures[bar - 1].onsetXs.first).key?.fifths;
    }

    expect(fifths('Oboe 1', 16), 5);
    expect(fifths('Oboe 1', 17), 0);
    expect(fifths('Violin I', 30), 0);
    expect(fifths('Clarinet in B♭ 1', 17), 2); // written D major

    final c = Curation(changes.metadata.parts.map((p) => p.id))..transition = 0.4;
    c.setLane(changes.metadata.parts.firstWhere((p) => p.name == 'Oboe 1').id, [Region(0, changes.timeline.measureStarts.last)]);
    double column(int bar) => scene.keyColumnAt(changes.timeline.secondsAtQuarter(changes.timeline.measureStarts[bar - 1]), c, const ui.Size(1280, 720));
    expect(column(12), closeTo(1.0 + 5 * 1.1, 1e-9));
    expect(column(20), 0, reason: 'the column closes after the sharps leave');
    scene.dispose();
  });

  test('a hidden key change shows no key signature, as the score does', () async {
    final hidden = await LoadedScore.load(
        demoScoreWithKeyChange(bar: 5, concertFifths: 3).replaceAll('<key><fifths>3</fifths>', '<key print-object="no"><fifths>3</fifths>'));
    final scene = CuratedScene(hidden);
    final n = hidden.metadata.parts.firstWhere((p) => p.name == 'Oboe 1').staffNumbers.first;
    expect(scene.renderer.frozen!.stateAt(n, hidden.engraving.measures[6].onsetXs.first).key?.fifths ?? 0, 0);
    scene.dispose();
  });

  test('an instrument on more than one staff is joined by a brace at the left; one on a single staff is not', () async {
    final score = await LoadedScore.load(flutePianoScore);
    final scene = CuratedScene(score);
    const size = ui.Size(800, 400);
    final piano = score.metadata.parts.firstWhere((p) => p.name == 'Piano');
    final c = Curation(score.metadata.parts.map((p) => p.id));
    for (final p in score.metadata.parts) {
      c.setLane(p.id, [Region(0, score.timeline.measureStarts.last)]);
    }
    final layout = scene.layoutAt(1, c, size);
    final brace = layout.braces.single;
    final pianoTops = [
      for (final p in layout.placements)
        if (piano.staffNumbers.contains(scene.display.staves[p.staffIndex].info.n)) p.y,
    ];
    expect([for (final s in brace.staves) s.top], pianoTops);

    // Drawn just left of the zone, between the piano's staves, and the starting line joins them.
    await (FontLoader('packages/score_engine/Bravura')
          ..addFont(Future.value(ByteData.sublistView(File('assets/fonts/Bravura.otf').readAsBytesSync()))))
        .load();
    final image = scene.renderFrame(size.width.toInt(), size.height.toInt(), time: 1, curation: c, devicePixelRatio: 1);
    final pixels = (await image.toByteData())!;
    final y = ((brace.staves.first.top + brace.staves.first.height + brace.staves.last.top) / 2).round();
    final sp = scene.style.staffSpace, left = scene.style.headerWidth;
    final inked = [
      for (var x = (left - 1.4 * sp).floor(); x < left - 0.3 * sp; x++)
        if (pixels.getUint8((y * size.width.toInt() + x) * 4) < 128) x,
    ];
    expect(inked, isNotEmpty, reason: 'the brace crosses the gap between the staves');
    expect(pixels.getUint8((y * size.width.toInt() + left.round()) * 4), lessThan(128), reason: 'the starting line runs on between them');
    image.dispose();

    c.setLane(piano.id, []);
    expect(scene.layoutAt(1, c, size).braces, isEmpty, reason: 'no brace while the piano is hidden');
    scene.dispose();
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
    expect(wider.renderer.frozen!.maxWidth, greaterThan(scene.renderer.frozen!.maxWidth), reason: '"2+2+2" takes more room than "6"');
    wider.dispose();
  });

  group('the key column', () {
    const size = ui.Size(1280, 720);
    String idOf(String name) => score.metadata.parts.firstWhere((p) => p.name == name).id;
    double secondsAt(int bar) => score.timeline.secondsAtQuarter(score.timeline.measureStarts[bar - 1]);
    double end() => score.timeline.measureStarts.last;
    const twoSharps = 1.0 + 2 * 1.1, fourFlats = 1.0 + 4 * 1.0;

    Curation curation(Map<String, List<Region>> lanes) {
      final c = Curation(score.metadata.parts.map((p) => p.id))..transition = 0.4;
      lanes.forEach((name, regions) => c.setLane(idOf(name), regions));
      return c;
    }

    /// Every fully shown staff's key signature fits the column where the zone's edge is.
    void expectKeysFit(Curation c, double from, double to) {
      final zone = scene.renderer.frozen!;
      final s = scene.renderer.scale, pointerX = scene.renderer.pointerX(size.width);
      for (var t = from; t <= to; t += 0.02) {
        final column = scene.keyColumnAt(t, c, size);
        final edgeX = scene.scrollMap.xAt(t) - (pointerX - scene.renderer.musicLeftFor(column)) / s;
        for (final p in scene.layoutAt(t, c, size).placements) {
          if (p.opacity < 1) continue; // still gliding in or out
          final n = scene.display.staves[p.staffIndex].info.n;
          expect(zone.keyColumnIn(n, edgeX, edgeX), lessThanOrEqualTo(column + 1e-9), reason: 'staff $n at $t s');
        }
      }
    }

    test('is as wide as the widest key of the staves shown: it closes when they leave and opens when they return', () {
      final c = curation({
        'Oboe 1': [Region(0, end())], // C major: no key signature
        'Clarinet in B♭ 1': [Region(0, score.timeline.measureStarts[10]), Region(score.timeline.measureStarts[19], end())], // D major
      });
      final leaves = secondsAt(11), returns = secondsAt(20);
      expect(scene.keyColumnAt(leaves - 1, c, size), closeTo(twoSharps, 1e-9));
      final midway = scene.keyColumnAt(leaves, c, size);
      expect(midway, inExclusiveRange(0, twoSharps), reason: 'glides over the transition time');
      expect(scene.keyColumnAt(leaves + 0.21, c, size), 0);
      expect(scene.keyColumnAt(returns - 0.21, c, size), 0);
      expect(scene.keyColumnAt(returns + 0.21, c, size), closeTo(twoSharps, 1e-9));
      expect(scene.renderer.musicLeftFor(0), lessThan(scene.renderer.musicLeftFor(twoSharps)), reason: 'the music starts further left');
      expectKeysFit(c, leaves - 1, returns + 1);
    });

    test('with nothing shown needing a key signature, there is none', () {
      final c = curation({'Oboe 1': [Region(0, score.timeline.measureStarts[20])]});
      expect(scene.keyColumnAt(secondsAt(5), c, size), 0);
      expect(scene.renderer.frozen!.maxKeyColumn, greaterThan(0), reason: 'the piece has key signatures elsewhere');
    });

    test('opens ahead of a wider key, so it is never cut off as it takes over', () {
      final c = curation({'Oboe 1': [Region(0, end())]}); // C major, then A♭ major at bar 29
      final zone = scene.renderer.frozen!;
      final s = scene.renderer.scale, pointerX = scene.renderer.pointerX(size.width);
      final oboe = staffOf('Oboe 1');
      // The first frame at which the zone shows A♭ major.
      var t = secondsAt(26);
      while (zone.stateAt(oboe,
                  scene.scrollMap.xAt(t) - (pointerX - scene.renderer.musicLeftFor(scene.keyColumnAt(t, c, size))) / s)
              .key
              ?.fifths ==
          0) {
        t += 0.01;
      }
      expect(scene.keyColumnAt(secondsAt(26), c, size), 0);
      expect(scene.keyColumnAt(t, c, size), closeTo(fourFlats, 1e-9), reason: 'fully open as the key arrives');
      expect(scene.keyColumnAt(t - 0.2, c, size), inExclusiveRange(0, fourFlats), reason: 'opening as it approaches');
      expect(scene.keyColumnAt(t + 5, c, size), closeTo(fourFlats, 1e-9));
      expectKeysFit(c, t - 2, t + 2);
    });
  });
}
