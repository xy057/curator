import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

void main() {
  // 16 bars of 4/4 at ♩ = 120: a bar is 2 s.
  final starts = [for (var i = 0; i <= 16; i++) i * 4.0];
  SyncMap map() => SyncMap(measureStarts: starts, defaultTempo: 120);

  test('a caption shows while its music sounds', () {
    final spans = captionSpans(const [Caption(4, 12, 'Horns')], map());
    expect(spans, [(caption: 0, start: 2.0, end: 6.0)]);
  });

  test('one shows at a time: a caption ends where the next starts; empty ones never show', () {
    final spans = captionSpans(const [Caption(8, 16, 'B'), Caption(0, 12, 'A'), Caption(20, 24, '  ')], map());
    expect(spans, [(caption: 1, start: 0.0, end: 4.0), (caption: 0, start: 4.0, end: 8.0)]);
  });

  test('a caption in a repeat shows in each pass that plays it', () {
    final m = map()
      ..addAnchor(const SyncAnchor(0, 0))
      ..addAnchor(const SyncAnchor(32, 16, jumpTo: 0));
    final spans = captionSpans(const [Caption(4, 8, 'Again')], m);
    expect(spans.length, 2);
    expect(spans[0].start, closeTo(2, 1e-9));
    expect(spans[1].start, closeTo(18, 1e-9));
  });
}
