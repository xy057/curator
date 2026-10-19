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

  test('one shows at a time: a caption ends where the next starts; empty ones never show', () {
    final spans = captionSpans(const [Caption(8, 16, 'B'), Caption(0, 12, 'A'), Caption(20, 24, '  ')], map());
    expect(spans, [(caption: 1, start: 0.0, end: 4.0), (caption: 0, start: 4.0, end: 8.0)]);
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
  });

}
