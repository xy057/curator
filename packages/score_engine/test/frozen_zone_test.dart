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

  test('a change to C major takes over the zone, and draws a natural for each accidental it cancels in the scrolling score', () async {
    // B major from bar 5, then C major at bar 17: Oboe 1 drops five sharps, the clarinets
    // (written D major at both ends of the piece, C♯ major between) only those beyond two.
    final changes = await LoadedScore.load(demoScoreWithKeyChanges({5: 5, 17: 0}));
    final data = changes.engraving;
    int staff(String part) => changes.metadata.parts.firstWhere((p) => p.name == part).staffNumbers.first;
    List<int> glyphs(String part, int fifths) {
      final sig = data.signatures.whereType<KeySignature>().lastWhere((k) => k.staff == staff(part) && k.fifths == fifths);
      return [for (var i = sig.commandStart; i < sig.commandStart + sig.commandCount; i++) data.commandInts[i * Cmd.words + Cmd.codepoint]];
    }

    const natural = 0xE261, sharp = 0xE262;
    expect(glyphs('Oboe 1', 0), List.filled(5, natural));
    expect(glyphs('Violin I', 0), List.filled(5, natural));
    expect(glyphs('Clarinet in B♭ 1', 2), List.filled(2, sharp), reason: 'fewer sharps cancel nothing unless the score asks');

    // The zone takes over the change to no key signature too, though only naturals are drawn for it.
    final scene = CuratedScene(changes);
    addTearDown(scene.dispose);
    int? fifths(String part, int bar) => scene.renderer.frozen!.stateAt(staff(part), data.measures[bar - 1].onsetXs.first).key?.fifths;
    expect(fifths('Oboe 1', 16), 5);
    expect(fifths('Oboe 1', 17), 0);
    expect(fifths('Violin I', 30), 0);
    expect(fifths('Clarinet in B♭ 1', 17), 2); // written D major

    final c = Curation(changes.metadata.parts.map((p) => p.id))..transition = 0.4;
    c.setLane(changes.metadata.parts.firstWhere((p) => p.name == 'Oboe 1').id, [Region(0, changes.timeline.measureStarts.last)]);
    double column(int bar) => scene.keyColumnAt(changes.timeline.secondsAtQuarter(changes.timeline.measureStarts[bar - 1]), c, const ui.Size(1280, 720));
    expect(column(12), closeTo(1.0 + 5 * 1.1, 1e-9));
    expect(column(20), 0, reason: 'the column closes after the sharps leave');
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

  test("a handwritten font's tall time signature digits meet on the middle line instead of overlapping", () async {
    final work = Directory.systemTemp.createTempSync('zone_fonts');
    FontResources.workDirectory = work.path;
    addTearDown(() {
      FontResources.workDirectory = null;
      work.deleteSync(recursive: true);
    });
    final bytes = await File('assets/fonts/Petaluma.otf').readAsBytes();
    await (FontLoader('packages/score_engine/Petaluma')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    final score = await LoadedScore.load(demoScore(), fonts: const ScoreFonts(music: MusicFont.petaluma));
    final curation = Curation(score.metadata.parts.map((p) => p.id));
    for (final p in score.metadata.parts) {
      curation.setLane(p.id, [Region(0, score.timeline.measureStarts.last)]);
    }
    final scene = CuratedScene(score);
    addTearDown(scene.dispose);
    const size = ui.Size(800, 600);
    final image = scene.renderFrame(800, 600, time: 0.5, curation: curation, devicePixelRatio: 1);
    final pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    image.dispose();
    final sp = scene.style.staffSpace, right = scene.renderer.musicLeftFor(scene.keyColumnAt(0.5, curation, size));
    final staff = scene.layoutAt(0.5, curation, size).placements.firstWhere((p) => p.y > 4 * sp);
    final middle = staff.y + 2 * sp;
    // Rows with ink in the 6/8's columns: Petaluma's 6 is 2.9 staff spaces tall, its 8 3.4.
    final rows = [
      for (var y = (middle - 4 * sp).round(); y <= (middle + 4 * sp).round(); y++)
        if ([for (var x = (right - 3 * sp).round(); x < (right - 1.5 * sp).round(); x++) pixels[(y * 800 + x) * 4]].any((v) => v < 128)) y,
    ];
    final tall = (rows.last - rows.first) / sp;
    expect(tall, greaterThan(5.4), reason: 'one number a half height either side of the middle line, not a staff space');
  });
}
