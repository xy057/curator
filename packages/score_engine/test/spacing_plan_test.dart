import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_score.dart';

void main() {
  late LoadedScore score;
  late CuratedScene scene;

  setUpAll(() async {
    final bytes = await File('assets/fonts/Bravura.otf').readAsBytes();
    await (FontLoader('packages/score_engine/Bravura')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    score = await LoadedScore.load(demoScore());
    scene = CuratedScene(score);
  });
  tearDownAll(() => scene.dispose());

  // A plan with an edge every two seconds, every other staff shown in every other segment;
  // [asked] collects the segments (their middles) it worked out.
  SpacingPlan plan(Set<double> asked) {
    final staves = scene.display.staves;
    return SpacingPlan.build(
      staves: staves,
      order: [for (var i = 0; i < staves.length; i++) (staffIndex: i, partId: '$i')],
      scrollMap: scene.scrollMap,
      edges: [for (var t = 2.0; t < score.duration; t += 2) (seconds: t, transition: 0.5)],
      isShown: (id, seconds) {
        asked.add(seconds);
        return int.parse(id).isEven || (seconds ~/ 2).isEven;
      },
      visibleLeft: 400,
      visibleRight: 1200,
      transition: 0.5,
      scale: scene.renderer.scale,
      metrics: const StackMetrics(availableHeight: 800, minGap: 12, maxGap: 80),
    );
  }

  test('a new plan works out only the segments a frame draws', () {
    final asked = <double>{};
    final p = plan(asked);
    expect(asked, isEmpty, reason: 'nothing until a frame asks');
    p.topsAt(9);
    expect(asked, hasLength(1), reason: 'the segment around 9 s, away from its edges');
    p.topsAt(10); // on an edge: blending two segments
    expect(asked, hasLength(2));
    p.topsAt(9.5);
    expect(asked, hasLength(2), reason: 'kept, not worked out again');
  });

  test('the segments come out the same in whatever order they are asked for', () {
    final forward = plan({}), backward = plan({});
    final times = [for (var t = -1.0; t < score.duration + 1; t += 0.37) t];
    final a = [for (final t in times) forward.topsAt(t)];
    final b = [for (final t in times.reversed) backward.topsAt(t)].reversed.toList();
    expect(a, b);
    expect(a.map((tops) => tops.toString()).toSet().length, greaterThan(1), reason: 'the staves move');
  });
}
