import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_settings.dart';
import 'editor_controller.dart';

/// Settings ▸ Advanced ▸ Engrave Option: every Verovio option that is safe to change
/// ([EngraveOption.all]) by its code name, for those who know Verovio. A change is saved at
/// once (for every score) and re-engraves the open score, shown beside the list.
Future<void> showEngraveOptionsDialog(BuildContext context, AppSettings settings, {EditorController? controller}) =>
    showDialog<void>(
      context: context,
      builder: (context) => _EngraveOptionsDialog(settings: settings, controller: controller),
    );

class _EngraveOptionsDialog extends StatefulWidget {
  const _EngraveOptionsDialog({required this.settings, this.controller});
  final AppSettings settings;
  final EditorController? controller;

  @override
  State<_EngraveOptionsDialog> createState() => _EngraveOptionsDialogState();
}

class _EngraveOptionsDialogState extends State<_EngraveOptionsDialog> {
  final _search = TextEditingController();

  /// Where the preview shows the score: the playhead's time until scrubbed.
  late double _time = widget.controller?.playback.time.value ?? 0;

  AppSettings get settings => widget.settings;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(32),
      child: ListenableBuilder(
        listenable: Listenable.merge([settings, _search, ?widget.controller]),
        builder: (context, _) {
          final c = widget.controller;
          final preview = c?.scene != null && c?.curation != null;
          return SizedBox(
            width: preview ? math.min(1200, size.width - 64) : 400,
            height: (size.height - 64).clamp(360, 760),
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: 400, child: _list(context)),
              if (preview) ...[
                VerticalDivider(width: 1, color: colors.line),
                Expanded(child: _preview(context, c!)),
              ],
            ]),
          );
        },
      ),
    );
  }

  Widget _list(BuildContext context) {
    final colors = context.colors;
    final options = settings.engravingOptions;
    final q = _search.text.trim().toLowerCase();
    final shown = [for (final o in EngraveOption.all) if (o.key.toLowerCase().contains(q)) o];
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: colors.line));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        child: Row(children: [
          Expanded(
            child: SizedBox(
              height: 30,
              child: TextField(
                controller: _search,
                style: const TextStyle(fontSize: 12.5),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search',
                  prefixIcon: Icon(Icons.search, size: 15, color: colors.textMuted),
                  prefixIconConstraints: const BoxConstraints(minWidth: 30),
                  contentPadding: const EdgeInsets.symmetric(vertical: 7),
                  border: border,
                  enabledBorder: border,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            tooltip: 'Reset all',
            onPressed: options.isEmpty ? null : () => settings.engravingOptions = const EngravingOptions(),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
          ),
        ]),
      ),
      Divider(height: 1, color: colors.line),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: shown.length,
          itemBuilder: (context, i) {
            final option = shown[i];
            return _OptionRow(
              option: option,
              value: options.valueOf(option),
              changed: options.isChanged(option),
              onChanged: (v) => settings.engravingOptions = settings.engravingOptions.withValue(option, v),
            );
          },
        ),
      ),
    ]);
  }

  Widget _preview(BuildContext context, EditorController c) {
    final colors = context.colors;
    final duration = c.playback.duration;
    final time = _time.clamp(0.0, math.max(duration, 0.0)).toDouble();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: Stack(children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _PreviewPainter(c.scene!, c.curation!, time, MediaQuery.devicePixelRatioOf(context),
                    colors.scorePaper, colors.scoreInk),
              ),
            ),
          ),
          if (c.isReengraving)
            const Positioned(
              right: 12,
              top: 12,
              child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ]),
      ),
      Divider(height: 1, color: colors.line),
      SizedBox(
        height: 36,
        child: Slider(
          value: time,
          max: math.max(duration, 0.001),
          onChanged: (t) => setState(() => _time = t),
        ),
      ),
    ]);
  }
}

/// The open score at [time], drawn as the score view and a video frame draw it.
class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.scene, this.curation, this.time, this.devicePixelRatio, this.paper, this.ink);
  final CuratedScene scene;
  final Curation curation;
  final double time;
  final double devicePixelRatio;
  final Color paper, ink;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.drawColor(paper, BlendMode.src);
    scene.paint(canvas, size,
        time: time, curation: curation, devicePixelRatio: devicePixelRatio, paper: paper, ink: ink);
  }

  @override
  bool shouldRepaint(_PreviewPainter old) =>
      old.scene != scene ||
      old.curation != curation ||
      old.time != time ||
      old.devicePixelRatio != devicePixelRatio ||
      old.paper != paper ||
      old.ink != ink;
}

/// One option: its code name, its value, and a reset once changed.
class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.option, required this.value, required this.changed, required this.onChanged});
  final EngraveOption option;
  final Object value;
  final bool changed;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final control = switch (option.kind) {
      EngraveOptionKind.number || EngraveOptionKind.integer =>
        _NumberField(option: option, value: value as num, onChanged: onChanged),
      EngraveOptionKind.toggle => SizedBox(
          height: 28,
          child: FittedBox(child: Switch(value: value as bool, onChanged: onChanged)),
        ),
      EngraveOptionKind.choice => DropdownButton<String>(
          value: value as String,
          isDense: true,
          underline: const SizedBox.shrink(),
          style: TextStyle(fontSize: 12.5, color: colors.text),
          items: [for (final c in option.choices) DropdownMenuItem(value: c, child: Text(c))],
          onChanged: onChanged,
        ),
    };
    final range = switch (option.kind) {
      EngraveOptionKind.number || EngraveOptionKind.integer =>
        '${formatOptionValue(option.min!)}–${formatOptionValue(option.max!)}, ',
      _ => '',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 1, 4, 1),
      child: Row(children: [
        Expanded(
          child: Tooltip(
            message: '${range}default ${formatOptionValue(option.defaultValue)}',
            waitDuration: const Duration(milliseconds: 500),
            child: Text(
              option.key,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'Menlo',
                fontFamilyFallback: const ['Consolas', 'DejaVu Sans Mono', 'monospace'],
                fontWeight: changed ? FontWeight.w600 : FontWeight.normal,
                color: changed ? colors.accentStrong : colors.text,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        control,
        SizedBox(
          width: 32,
          child: changed
              ? IconButton(
                  icon: const Icon(Icons.restart_alt_rounded, size: 15),
                  tooltip: 'Reset',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onChanged(null),
                )
              : null,
        ),
      ]),
    );
  }
}

/// A value as the list shows it: numbers without trailing zeros.
String formatOptionValue(Object value) => switch (value) {
      int() => '$value',
      double() => value.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), ''),
      bool() => value ? 'on' : 'off',
      _ => '$value',
    };

/// A number typed in: taken (and clamped into range) on Return or when focus leaves; anything
/// unreadable puts the value back.
class _NumberField extends StatefulWidget {
  const _NumberField({required this.option, required this.value, required this.onChanged});
  final EngraveOption option;
  final num value;
  final ValueChanged<Object?> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final _text = TextEditingController(text: formatOptionValue(widget.value));
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_focus.hasFocus) _text.text = formatOptionValue(widget.value);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final typed = num.tryParse(_text.text.trim().replaceAll(',', '.'));
    final value = typed == null ? null : widget.option.coerce(typed);
    if (value != null && value != widget.value) widget.onChanged(value);
    _text.text = formatOptionValue(value ?? widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: BorderSide(color: colors.line));
    return SizedBox(
      width: 64,
      height: 26,
      child: TextField(
        controller: _text,
        focusNode: _focus,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: const TextStyle(fontSize: 12.5),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
          border: border,
          enabledBorder: border,
        ),
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}
