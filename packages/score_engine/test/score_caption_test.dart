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

  test('of two spans starting together, the later caption shows', () {
    final spans = captionSpans([for (var i = 0; i < 40; i++) Caption(i * 4.0, i * 4.0 + 4, '$i'), const Caption(0, 2, 'late')], map());
    expect(spans.first.caption, 0);
    expect(spans.first.end, 0, reason: 'cut to nothing');
    expect(spans[1], (caption: 40, start: 0.0, end: 1.0));
  });

  test('captions never overlap: one running into the next ends where it starts', () {
    expect(separateCaptions(const [Caption(0, 64, 'A'), Caption(16, 24, 'B'), Caption(30, 40, 'C')]),
        const [Caption(0, 16, 'A'), Caption(16, 24, 'B'), Caption(30, 40, 'C')]);
    expect(separateCaptions(const [Caption(8, 16, 'B'), Caption(8, 12, 'A')]), const [Caption(8, 12, 'A')],
        reason: 'of two starting together the later is kept');
    const apart = [Caption(0, 4, 'A'), Caption(4, 8, 'B')];
    expect(identical(separateCaptions(apart)[0], apart[0]), isTrue);
  });

  test('the room around a place: between its neighbours, none inside a caption', () {
    const captions = [Caption(4, 8, 'A'), Caption(16, 20, 'B')];
    expect(captionRoom(captions, 10, 64), (from: 8.0, to: 16.0));
    expect(captionRoom(captions, 8, 64), (from: 8.0, to: 16.0), reason: 'a caption\'s end is free');
    expect(captionRoom(captions, 4, 64), isNull, reason: 'its start is not');
    expect(captionRoom(captions, 2, 64), (from: 0.0, to: 4.0));
    expect(captionRoom(captions, 5, 64, except: 0), (from: 0.0, to: 16.0));
    expect(captionOverlapping(captions, 6, 18), 0);
    expect(captionOverlapping(captions, 8, 16), isNull);
    expect(captionOverlapping(captions, 6, 18, except: 0), 1);
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
