import 'dart:ui';

import 'package:score_engine/score_engine.dart';

/// Draws the score laid out at [layout] points (its frame, or its part of a split's): the scene
/// at a time.
typedef PaintScore = void Function(Canvas canvas, Size layout);

/// Draws the player map into [size] points.
typedef PaintMap = void Function(Canvas canvas, Size size);

/// Draws a frame of [frame] points as the View lane has it ([TimedSteps.at]): one view, or two
/// crossfading. The preview, a video's frames and a web page draw the same frame this way. With
/// no [map] (a project without one) a view with the map is the score alone, as the MIDI view is
/// with no [rows] (the score's notes in rows, [LoadedScore.rows]: a score without notes, or one
/// that is rows already). [paper] goes under the map where the score isn't; [ink] edges an
/// inset map; [fade] (0–1, [CuratedScene.endFadeAt]) fades the map to paper as the score fades
/// at the end.
///
/// A crossfade draws both views, each into its own layer, added by their shares: exact for
/// see-through paper too.
void paintViews(Canvas canvas, Size frame, StepMix<SceneView> mix,
    {required PaintScore score, PaintScore? rows, PaintMap? map, required Color paper, required Color ink, double fade = 0}) {
  void view(SceneView v) => _paintView(canvas, frame, v, score: score, rows: rows, map: map, paper: paper, ink: ink, fade: fade);
  final from = mix.from.where(map: map != null, rows: rows != null), to = mix.to.where(map: map != null, rows: rows != null);
  final share = mix.mix;
  if (share <= 0 || from == to) return view(from);
  if (share >= 1) return view(to);
  final bounds = Offset.zero & frame;
  canvas.saveLayer(bounds, Paint());
  canvas.saveLayer(bounds, Paint()..color = Color.fromRGBO(0, 0, 0, 1 - share));
  view(from);
  canvas.restore();
  canvas.saveLayer(
      bounds,
      Paint()
        ..blendMode = BlendMode.plus
        ..color = Color.fromRGBO(0, 0, 0, share));
  view(to);
  canvas.restore();
  canvas.restore();
}

/// Points of room round the map, at a frame's layout size (540 on its short side).
const _mapMargin = 18.0, _insetMargin = 6.0;

void _paintView(Canvas canvas, Size frame, SceneView view,
    {required PaintScore score, required PaintScore? rows, required PaintMap? map, required Color paper, required Color ink, required double fade}) {
  final place = view.place(frame);
  if (place.score case final rect?) {
    canvas
      ..save()
      ..clipRect(rect)
      ..translate(rect.left, rect.top);
    final scale = rect.height / place.scoreLayout.height;
    if (scale != 1) canvas.scale(scale);
    (place.rows ? rows ?? score : score)(canvas, place.scoreLayout);
    canvas.restore();
  }
  final rect = place.map;
  if (rect == null || map == null) return;
  final margin = place.inset ? _insetMargin : _mapMargin;
  // On see-through paper, painting paper over it would show nothing: it fades out instead.
  final fadeLayer = fade > 0 && paper.a < 1;
  if (fadeLayer) canvas.saveLayer(rect.inflate(4), Paint()..color = Color.fromRGBO(0, 0, 0, 1 - fade));
  if (place.inset) {
    // A card of paper over the score, edged as a frame is.
    final card = RRect.fromRectAndRadius(rect, const Radius.circular(6));
    canvas
      ..drawRRect(card.shift(const Offset(0, 1.5)), Paint()..color = const Color(0x22000000))
      ..drawRRect(card, Paint()..color = paper.withValues(alpha: 1))
      ..drawRRect(
          card,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = ink.withValues(alpha: 0.15));
  } else {
    canvas.drawRect(rect, Paint()..color = paper);
  }
  canvas
    ..save()
    ..clipRect(rect)
    ..translate(rect.left + margin, rect.top + margin);
  map(canvas, Size(rect.width - 2 * margin, rect.height - 2 * margin));
  canvas.restore();
  if (fadeLayer) {
    canvas.restore();
  } else if (fade > 0) {
    canvas.drawRect(rect.inflate(4), Paint()..color = paper.withValues(alpha: fade));
  }
}
