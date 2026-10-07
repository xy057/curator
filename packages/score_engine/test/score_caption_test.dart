import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

/// A caption bar's frame: [paper] with the caption drawn on it at [time] (shown 0–10 s).
class _Frame {
  _Frame(this.pixels, this.width, this.height, this.paper);
  final ByteData pixels;
  final int width, height;
  final int paper;

  int at(int x, int y) => pixels.getUint32((y * width + x) * 4);
  bool inked(int x, int y) => at(x, y) != paper;

  /// The box around everything drawn, or null.
  ui.Rect? get ink {
    int? l, t, r, b;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (!inked(x, y)) continue;
        l = l == null || x < l ? x : l;
        r = r == null || x > r ? x : r;
        t ??= y;
        b = y;
      }
    }
    return l == null ? null : ui.Rect.fromLTRB(l.toDouble(), t!.toDouble(), r! + 1.0, b! + 1.0);
  }

  /// How far the darkest (on light paper) or lightest pixel strays from the paper, 0–255.
  int get strongest {
    var most = 0;
    for (var i = 0; i < pixels.lengthInBytes; i += 4) {
      final d = (pixels.getUint8(i) - (paper >> 24 & 0xff)).abs();
      if (d > most) most = d;
    }
    return most;
  }
}

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

  group('how a caption is drawn', () {
    const size = ui.Size(800, 300), family = 'packages/score_engine/Academico';
    const white = ui.Color(0xFFFFFFFF), black = ui.Color(0xFF000000);
    const spans = [(caption: 0, start: 0.0, end: 10.0)];
    const captions = [Caption(0, 4, 'The horns answer')];

    setUpAll(() async {
      final loader = FontLoader(family);
      for (final face in ['Regular', 'Italic', 'Bold', 'BoldItalic']) {
        loader.addFont(Future.value(ByteData.sublistView(File('assets/fonts/Academico-$face.otf').readAsBytesSync())));
      }
      await loader.load();
    });

    Future<_Frame> frame(double time, {CaptionStyle style = const CaptionStyle(), ui.Color paper = white, ui.Color ink = black}) async {
      final bar = CaptionBar(family, style);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)..drawColor(paper, ui.BlendMode.src);
      bar.paint(canvas, size, time, spans, captions, ink);
      bar.dispose();
      final image = recorder.endRecording().toImageSync(size.width.toInt(), size.height.toInt());
      final pixels = (await image.toByteData())!;
      image.dispose();
      final argb = paper.toARGB32();
      return _Frame(pixels, size.width.toInt(), size.height.toInt(), (argb << 8 | argb >> 24) & 0xFFFFFFFF);
    }

    test('only while its time runs, centred under the staves, fading in and out', () async {
      expect((await frame(-0.01)).ink, isNull);
      expect((await frame(10)).ink, isNull);
      final shown = await frame(5);
      final box = shown.ink!;
      expect(box.center.dx, closeTo(size.width / 2, 2));
      expect(box.top, greaterThan(size.height * 0.75), reason: 'at the bottom of the frame');
      expect(shown.strongest, greaterThan(240), reason: 'in full ink');
      final fadingIn = await frame(0.1), fadingOut = await frame(9.9);
      expect(fadingIn.strongest, allOf(greaterThan(0), lessThan(shown.strongest)));
      expect(fadingOut.strongest, allOf(greaterThan(0), lessThan(shown.strongest)));
    });

    test('it rises 4 points into place as it fades in', () async {
      final settled = (await frame(5)).ink!.top, early = (await frame(0.05)).ink!.top;
      expect(early - settled, allOf(greaterThan(2.5), lessThanOrEqualTo(4.5)));
    });

    test('the hairline draws in to its middle as the time runs out', () async {
      final y = (size.height - 16).round();
      Future<int> strongWidth(double t) async {
        final f = await frame(t);
        var n = 0;
        for (var x = 0; x < f.width; x++) {
          if ([y - 1, y].any((y) => (f.at(x, y) >> 24 & 0xff) < 200)) n++; // the half-strength part, not the faint track
        }
        return n;
      }

      final early = await strongWidth(2.5), late = await strongWidth(7.5);
      expect(late, greaterThan(0));
      expect(early / late, closeTo(3, 0.5), reason: '75% of it left, then 25%');
      final none = await frame(5, style: const CaptionStyle(countdown: CaptionCountdown.none));
      expect([for (var x = 0; x < none.width; x++) none.inked(x, y)], everyElement(isFalse), reason: 'no countdown: no line');
    });

    test('the ring sits left of the text', () async {
      final line = (await frame(5)).ink!, ring = (await frame(5, style: const CaptionStyle(countdown: CaptionCountdown.ring))).ink!;
      expect(ring.left, lessThan(line.left - 10));
      expect(ring.bottom, lessThan(line.bottom), reason: 'no hairline under it');
    });

    test('on top it is drawn above the staves; large is larger', () async {
      final top = (await frame(5, style: const CaptionStyle(position: CaptionPosition.top))).ink!;
      expect(top.bottom, lessThan(size.height / 4));
      final small = (await frame(5, style: const CaptionStyle(size: CaptionSize.small))).ink!;
      final large = (await frame(5, style: const CaptionStyle(size: CaptionSize.large))).ink!;
      expect(large.width, greaterThan(small.width * 1.2));
      expect(CaptionBar(family, const CaptionStyle(size: CaptionSize.large)).reserve,
          greaterThan(CaptionBar(family, const CaptionStyle(size: CaptionSize.small)).reserve));
    });

    test('in the ink it is given: light on dark paper', () async {
      const paper = ui.Color(0xFF101010), ink = ui.Color(0xFFF0F0F0);
      final f = await frame(5, paper: paper, ink: ink);
      final colours = {for (var i = 0; i < f.pixels.lengthInBytes; i += 4) f.pixels.getUint32(i)};
      expect(colours, contains(0xF0F0F0FF), reason: 'the ink, full strength in the text');
      for (final c in colours) {
        final (r, g, b) = (c >> 24 & 0xff, c >> 16 & 0xff, c >> 8 & 0xff);
        expect((r - g).abs() + (g - b).abs(), lessThan(6), reason: 'only greys between paper and ink');
      }
    });
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
