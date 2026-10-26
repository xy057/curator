import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_settings.dart';
import 'dialog_kit.dart';
import 'ui_kit.dart';
import 'l10n/l10n.dart';

/// Project Settings ▸ Extensions ▸ Captions ▸ settings: how captions look in every project: font,
/// countdown, size, alignment and a backing. A project
/// may choose its own font (Project Settings ▸ Engraving).
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
                SizedBox(width: 88, child: Text(label.tr)),
                Expanded(child: Align(alignment: Alignment.centerLeft, child: field)),
              ]),
            );
        Widget segments<T>(T value, List<(T, String)> choices, ValueChanged<T> onChanged) => AppSegmented<T>(
              segments: [for (final (v, label) in choices) ButtonSegment(value: v, label: Text(label.tr))],
              selected: value,
              onChanged: onChanged,
            );
        final families = [TextFonts.academico, ..._installed.where((f) => f != TextFonts.academico)];
        return SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            row(
              'Font',
              dialogMenuField(
                context,
                menu: (decoration, textStyle, arrow) => DropdownMenu<String>(
                  key: ValueKey((s.captionFont, families.length)),
                  expandedInsets: EdgeInsets.zero,
                  inputDecorationTheme: decoration,
                  textStyle: textStyle,
                  trailingIcon: arrow,
                  selectedTrailingIcon: arrow,
                  initialSelection: s.captionFont,
                  enableFilter: true,
                  requestFocusOnTap: true,
                  menuHeight: 320,
                  dropdownMenuEntries: [
                    DropdownMenuEntry(value: '', label: 'Score text'.tr),
                    for (final f in families) DropdownMenuEntry(value: f, label: f),
                  ],
                  onSelected: (f) {
                    if (f != null) s.captionFont = f;
                  },
                ),
              ),
            ),
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
            row(
              'Align',
              segments(s.captionAlign,
                  const [(CaptionAlign.left, 'Left'), (CaptionAlign.center, 'Center'), (CaptionAlign.right, 'Right')],
                  (v) => s.captionAlign = v),
            ),
            row('Backing', AppSwitch(value: s.captionPlate, onChanged: (v) => s.captionPlate = v)),
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
        decoration: BoxDecoration(color: colors.scorePaper, border: Border.all(color: colors.line), borderRadius: AppStyle.of(context).radius(8)),
        child: ClipRRect(
          borderRadius: AppStyle.of(context).radius(8),
          child: CustomPaint(
            size: Size.infinite,
            painter: _PreviewPainter(
              CaptionStyle(
                  fontFamily: family,
                  countdown: settings.captionCountdown,
                  size: settings.captionSize,
                  align: settings.captionAlign,
                  plate: settings.captionPlate),
              colors.scoreInk,
              colors.scorePaper,
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.style, this.ink, this.paper);
  final CaptionStyle style;
  final Color ink, paper;

  static List<Caption> get _captions => [Caption(0, 1, 'The *horns* answer, softly'.tr)];

  @override
  void paint(Canvas canvas, Size size) {
    CaptionBar(TextFonts.familyOf(TextFonts.academico), style)
        .paint(canvas, size, 6, const [(caption: 0, start: 0.0, end: 10.0)], _captions, ink, paper: paper);
  }

  @override
  bool shouldRepaint(_PreviewPainter old) => old.style != style || old.ink != ink || old.paper != paper;
}
