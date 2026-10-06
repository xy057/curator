import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'captions_dialog.dart';
import 'editor_controller.dart';
import 'lanes_common.dart';
import 'ui_kit.dart';

/// The Captions lane (the Captions extension): pinned under the bar ruler in both tabs, never
/// scrolled, moved or unpinned. Each caption is a block where it shows, its text inside.
/// A click on empty space moves the playhead; a double-click anywhere opens the Captions
/// sheet (on a caption: its row).
class CaptionLane extends StatefulWidget {
  const CaptionLane({super.key, required this.controller});
  final EditorController controller;

  static const height = 26.0;

  @override
  State<CaptionLane> createState() => _CaptionLaneState();
}

class _CaptionLaneState extends State<CaptionLane> {
  EditorController get c => widget.controller;
  Duration? _lastClick;
  Offset? _downAt;

  List<CaptionSpan> get _spans => captionSpans(c.captions.captions, c.timeline);

  /// The caption drawn under [x], an index into the captions.
  int? _captionAt(double x) {
    for (final s in _spans) {
      if (x >= c.viewport.x(s.start) && x <= c.viewport.x(s.end)) return s.caption;
    }
    return null;
  }

  /// How many clicks [e] ends (1 or 2), handled as the button comes up like the lane names;
  /// 0 when it was no click (a drag).
  int _clicks(PointerUpEvent e) {
    final down = _downAt;
    _downAt = null;
    if (down == null || (e.position - down).distance > 6) return 0;
    final last = _lastClick;
    final double = last != null && e.timeStamp - last < const Duration(milliseconds: 350);
    _lastClick = double ? null : e.timeStamp;
    return double ? 2 : 1;
  }

  void _down(PointerDownEvent e) => _downAt = e.buttons == kPrimaryButton ? e.position : null;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: CaptionLane.height,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: kLaneHeaderWidth,
          child: Listener(
            onPointerDown: _down,
            onPointerUp: (e) {
              if (_clicks(e) == 2) showCaptionsDialog(context, c);
            },
            child: LaneLabel(
              height: CaptionLane.height,
              color: colors.accentWash,
              trailing: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Tip(message: 'Pinned', child: Icon(Icons.push_pin, size: 13, color: colors.textMuted)),
              ),
              child: const Text('Captions', style: TextStyle(fontWeight: FontWeight.w500)),
            ),
          ),
        ),
        Expanded(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerUp: (e) {
              final x = e.localPosition.dx, clicks = _clicks(e);
              if (clicks == 2) {
                showCaptionsDialog(context, c, focus: _captionAt(x));
              } else if (clicks == 1 && _captionAt(x) == null) {
                c.playback.seek(c.viewport.seconds(x).clamp(0.0, c.playback.duration));
              }
            },
            child: DecoratedBox(
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.line))),
              child: CustomPaint(
                size: Size.infinite,
                painter: _CaptionLanePainter(this, colors, Listenable.merge([c, c.playback.time, c.viewport])),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _CaptionLanePainter extends CustomPainter {
  _CaptionLanePainter(this.s, this.colors, Listenable repaint) : super(repaint: repaint);
  final _CaptionLaneState s;
  final AppColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final c = s.c;
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.accentWash);
    paintBarGrid(canvas, size, c, colors);
    final captions = c.captions.captions;
    for (final span in s._spans) {
      final x0 = c.viewport.x(span.start), x1 = c.viewport.x(span.end);
      if (x1 < 0 || x0 > size.width) continue;
      final rect = RRect.fromLTRBR(x0 + 0.5, 4, x1 - 0.5, size.height - 4, const Radius.circular(4));
      canvas.drawRRect(rect, Paint()..color = colors.surface);
      canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = colors.textMuted.withValues(alpha: 0.5),
      );
      if (x1 - x0 < 16) continue;
      final text = TextPainter(
        text: TextSpan(text: captions[span.caption].text, style: TextStyle(fontSize: 11, color: colors.text)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: x1 - x0 - 12);
      text.paint(canvas, Offset(x0 + 6, rect.center.dy - text.height / 2));
      text.dispose();
    }
    paintPlayhead(canvas, size, c, colors);
  }

  @override
  bool shouldRepaint(_CaptionLanePainter old) => true;
}
