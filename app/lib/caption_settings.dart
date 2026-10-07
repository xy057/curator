import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_settings.dart';

/// Settings ▸ Extension ▸ Captions ▸ settings: how captions look in every project. A project
/// may choose its own font (Project Settings ▸ Fonts).
class CaptionSettings extends StatefulWidget {
  const CaptionSettings({super.key, required this.settings});
  final AppSettings settings;

  @override
  State<CaptionSettings> createState() => _CaptionSettingsState();
}

class _CaptionSettingsState extends State<CaptionSettings> {
  var _installed = const <String>[];

  @override
  void initState() {
    super.initState();
    TextFonts.installed().then((families) {
      if (mounted) setState(() => _installed = families);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        Widget row(String label, Widget field) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                SizedBox(width: 88, child: Text(label)),
                Expanded(child: Align(alignment: Alignment.centerLeft, child: field)),
              ]),
            );
        Widget segments<T>(T value, List<(T, String)> choices, ValueChanged<T> onChanged) => SegmentedButton<T>(
              showSelectedIcon: false,
              segments: [for (final (v, label) in choices) ButtonSegment(value: v, label: Text(label))],
              selected: {value},
              onSelectionChanged: (v) => onChanged(v.single),
            );
        final families = [TextFonts.academico, ..._installed.where((f) => f != TextFonts.academico)];
        return SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            row(
              'Font',
              DropdownMenu<String>(
                key: ValueKey((s.captionFont, families.length)),
                expandedInsets: EdgeInsets.zero,
                initialSelection: s.captionFont,
                enableFilter: true,
                requestFocusOnTap: true,
                menuHeight: 320,
                dropdownMenuEntries: [
                  const DropdownMenuEntry(value: '', label: 'Score text'),
                  for (final f in families) DropdownMenuEntry(value: f, label: f),
                ],
                onSelected: (f) {
                  if (f != null) s.captionFont = f;
                },
              ),
            ),
            row('Position', segments(s.captionPosition, const [(CaptionPosition.bottom, 'Bottom'), (CaptionPosition.top, 'Top')], (v) => s.captionPosition = v)),
            row(
              'Countdown',
              segments(s.captionCountdown,
                  const [(CaptionCountdown.line, 'Line'), (CaptionCountdown.ring, 'Ring'), (CaptionCountdown.none, 'None')],
                  (v) => s.captionCountdown = v),
            ),
            row(
              'Size',
              segments(s.captionSize, const [(CaptionSize.small, 'S'), (CaptionSize.medium, 'M'), (CaptionSize.large, 'L')],
                  (v) => s.captionSize = v),
            ),
            const SizedBox(height: 8),
            _Preview(settings: s),
          ]),
        );
      },
    );
  }
}

/// A caption drawn as the settings make it, its countdown part run.
class _Preview extends StatelessWidget {
  const _Preview({required this.settings});
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final name = settings.captionFont;
    final family = name.isEmpty || name == TextFonts.academico ? TextFonts.familyOf(TextFonts.academico) : TextFonts.familyOf(name);
    return FutureBuilder<void>(
      future: name.isEmpty || name == TextFonts.academico
          ? null
          : TextFonts.faces(name).then((f) => f == null ? null : TextFonts.load(name, f)),
      builder: (context, _) => Container(
        height: 96,
        decoration: BoxDecoration(color: colors.scorePaper, border: Border.all(color: colors.line), borderRadius: BorderRadius.circular(8)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CustomPaint(
            size: Size.infinite,
            painter: _PreviewPainter(
              CaptionStyle(
                  fontFamily: family,
                  position: settings.captionPosition,
                  countdown: settings.captionCountdown,
                  size: settings.captionSize),
              colors.scoreInk,
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.style, this.ink);
  final CaptionStyle style;
  final Color ink;

  static const _captions = [Caption(0, 1, 'The horns answer, softly')];

  @override
  void paint(Canvas canvas, Size size) {
    CaptionBar(TextFonts.familyOf(TextFonts.academico), style)
        .paint(canvas, size, 6, const [(caption: 0, start: 0.0, end: 10.0)], _captions, ink);
  }

  @override
  bool shouldRepaint(_PreviewPainter old) => old.style != style || old.ink != ink;
}
