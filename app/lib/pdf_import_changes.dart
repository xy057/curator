import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'dialog_kit.dart';
import 'l10n/l10n.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';

/// What the import's dialogs for a bar's changes and a staff's instrument (`pdf_import.dart`)
/// ask: a tempo mark, a key, time signature or clef where it changes, an instrument's name.

/// A change set ([value]) or taken away (null); a dialog cancelled returns no [PdfChange] at all.
class PdfChange<T> {
  const PdfChange(this.value);
  final T? value;
}

const pdfKeyNames = ['C♭', 'G♭', 'D♭', 'A♭', 'E♭', 'B♭', 'F', 'C', 'G', 'D', 'A', 'E', 'B', 'F♯', 'C♯'];

String pdfKeyName(int fifths) => pdfKeyNames[fifths.clamp(-7, 7) + 7];

String pdfClefName(PdfClef c) => switch (c) {
      PdfClef.treble => 'Treble',
      PdfClef.treble8vb => 'Treble 8vb',
      PdfClef.alto => 'Alto',
      PdfClef.tenor => 'Tenor',
      PdfClef.bass => 'Bass',
      PdfClef.percussion => 'Percussion',
    };

/// The buttons every change dialog ends with: Remove (when there is one to take away), Cancel
/// and OK.
({List<Widget> leading, List<Widget> actions}) _buttons<T>(BuildContext context,
        {required bool removable, required VoidCallback? onOk}) =>
    (
      leading: [
        if (removable) TextButton(onPressed: () => Navigator.pop(context, PdfChange<T>(null)), child: Text('Remove'.tr)),
      ],
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        FilledButton(onPressed: onOk, child: Text('OK'.tr)),
      ],
    );

/// A tempo mark at bar [bar]: its words and speed. At the first bar the speed is the score's
/// ([tempo]) and must be given; elsewhere a mark may say only words ("rit.").
Future<PdfChange<PdfTempo>?> showPdfTempoDialog(BuildContext context, {required int bar, PdfTempo? mark, required double tempo}) =>
    showAppDialog<PdfChange<PdfTempo>>(context: context, builder: (_) => _TempoDialog(bar: bar, mark: mark, tempo: tempo));

class _TempoDialog extends StatefulWidget {
  const _TempoDialog({required this.bar, required this.mark, required this.tempo});
  final int bar;
  final PdfTempo? mark;
  final double tempo;

  @override
  State<_TempoDialog> createState() => _TempoDialogState();
}

class _TempoDialogState extends State<_TempoDialog> {
  late final _words = TextEditingController(text: widget.mark?.words ?? '');
  late final _bpm = TextEditingController(text: switch (widget.bar == 0 ? widget.tempo : widget.mark?.bpm) {
    null => '',
    final v => v == v.roundToDouble() ? '${v.round()}' : '$v',
  });

  bool get _start => widget.bar == 0;

  /// The speed typed: null when there is none (allowed past the first bar); NaN when it isn't one.
  double? get _speed {
    final t = _bpm.text.trim();
    if (t.isEmpty) return _start ? double.nan : null;
    final v = double.tryParse(t);
    return v != null && v >= 10 && v <= 400 ? v : double.nan;
  }

  bool get _ok => !(_speed?.isNaN ?? false) && (_start || _words.text.trim().isNotEmpty || _speed != null);

  void _apply() {
    if (!_ok) return;
    Navigator.pop(context, PdfChange(PdfTempo(_words.text.trim(), _speed)));
  }

  @override
  void dispose() {
    _words.dispose();
    _bpm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final buttons = _buttons<PdfTempo>(context, removable: !_start && widget.mark != null, onOk: _ok ? _apply : null);
    return AppDialog(
      title: Text('Tempo'.tr),
      content: SizedBox(
        width: dialogWidth(context, 360),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AppTextField(
            controller: _words,
            label: 'Text',
            hint: 'Allegro',
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _apply(),
          ),
          SizedBox(height: dialogGap(context)),
          AppTextField(
            controller: _bpm,
            label: '♩ =',
            hint: _start ? null : '—',
            bad: _speed?.isNaN ?? false,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _apply(),
          ),
        ]),
      ),
      leading: buttons.leading,
      actions: buttons.actions,
    );
  }
}

/// A key signature from bar [bar] on, for every instrument: read as written for [readAs] (a
/// transposing instrument's staff shows its own), kept as the concert key, which each
/// instrument's staves then show transposed. [concert]: the change there is; [inForce] the
/// concert key otherwise.
Future<PdfChange<int>?> showPdfKeyDialog(BuildContext context,
        {required int bar, int? concert, required int inForce, required SpacerKey readAs, required List<PdfInstrument> instruments}) =>
    showAppDialog<PdfChange<int>>(
        context: context,
        builder: (_) => _KeyDialog(bar: bar, concert: concert, inForce: inForce, readAs: readAs, instruments: instruments));

class _KeyDialog extends StatefulWidget {
  const _KeyDialog({required this.bar, required this.concert, required this.inForce, required this.readAs, required this.instruments});
  final int bar;
  final int? concert;
  final int inForce;
  final SpacerKey readAs;
  final List<PdfInstrument> instruments;

  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  late SpacerKey _readAs = widget.readAs;
  late int _written = _readAs.keyOf(widget.concert ?? widget.inForce);

  int get _concert => _readAs.concertOf(_written);

  @override
  Widget build(BuildContext context) {
    // Concert, and each transposition an instrument is in, named by the first one in it.
    final readings = <SpacerKey, String>{SpacerKey.c: 'Concert'.tr};
    for (final i in widget.instruments) {
      if (i.key != SpacerKey.c) readings.putIfAbsent(i.key, () => i.name);
    }
    if (!readings.containsKey(_readAs)) readings[_readAs] = 'in {key}'.fill({'key': _readAs.label});
    final buttons = _buttons<int>(context,
        removable: widget.bar > 0 && widget.concert != null, onOk: () => Navigator.pop(context, PdfChange(_concert)));
    return AppDialog(
      title: Text('Key Signature'.tr),
      content: SizedBox(
        width: dialogWidth(context, 360),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AppDropdown<SpacerKey>(
            value: _readAs,
            isExpanded: true,
            label: 'Read as',
            items: [for (final MapEntry(:key, :value) in readings.entries) DropdownMenuItem(value: key, child: Text(value))],
            onChanged: (k) {
              if (k == null) return;
              // The same key kept, read the other way.
              setState(() {
                final concert = _concert;
                _readAs = k;
                _written = k.keyOf(concert);
              });
            },
          ),
          SizedBox(height: dialogGap(context)),
          AppDropdown<int>(
            value: _written,
            isExpanded: true,
            label: 'Key',
            items: [for (var f = -7; f <= 7; f++) DropdownMenuItem(value: f, child: Text(pdfKeyName(f)))],
            onChanged: (f) => setState(() => _written = f ?? _written),
          ),
          if (_readAs != SpacerKey.c) ...[
            const SizedBox(height: 8),
            Text('Concert: {key}'.fill({'key': pdfKeyName(_concert)}),
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ]),
      ),
      leading: buttons.leading,
      actions: buttons.actions,
    );
  }
}

/// A time signature from bar [bar] on: [title] says whose. [meter]: the change there is;
/// [inForce] the meter otherwise. [removable]: whether there is one to take away.
Future<PdfChange<PdfMeter>?> showPdfTimeDialog(BuildContext context,
        {required String title, PdfMeter? meter, required PdfMeter inForce, required bool removable}) =>
    showAppDialog<PdfChange<PdfMeter>>(
        context: context, builder: (_) => _TimeDialog(title: title, meter: meter, inForce: inForce, removable: removable));

class _TimeDialog extends StatefulWidget {
  const _TimeDialog({required this.title, required this.meter, required this.inForce, required this.removable});
  final String title;
  final PdfMeter? meter;
  final PdfMeter inForce;
  final bool removable;

  @override
  State<_TimeDialog> createState() => _TimeDialogState();
}

class _TimeDialogState extends State<_TimeDialog> {
  late final _text = TextEditingController(text: '${widget.meter ?? widget.inForce}');

  PdfMeter? get _meter => PdfMeter.parse(_text.text);

  void _apply() {
    if (_meter case final meter?) Navigator.pop(context, PdfChange(meter));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final buttons = _buttons<PdfMeter>(context, removable: widget.removable, onOk: _meter == null ? null : _apply);
    return AppDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: dialogWidth(context, 320),
        child: AppTextField(
          controller: _text,
          label: 'Time',
          hint: '3/4',
          autofocus: true,
          bad: _meter == null,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _apply(),
        ),
      ),
      leading: buttons.leading,
      actions: buttons.actions,
    );
  }
}

/// A clef from bar [bar] on, on one staff: [title] says whose. [clef]: the change there is;
/// [inForce] the clef otherwise.
Future<PdfChange<PdfClef>?> showPdfClefDialog(BuildContext context,
        {required String title, PdfClef? clef, required PdfClef inForce, required bool removable}) =>
    showAppDialog<PdfChange<PdfClef>>(
        context: context, builder: (_) => _ClefDialog(title: title, clef: clef, inForce: inForce, removable: removable));

class _ClefDialog extends StatefulWidget {
  const _ClefDialog({required this.title, required this.clef, required this.inForce, required this.removable});
  final String title;
  final PdfClef? clef;
  final PdfClef inForce;
  final bool removable;

  @override
  State<_ClefDialog> createState() => _ClefDialogState();
}

class _ClefDialogState extends State<_ClefDialog> {
  late PdfClef _clef = widget.clef ?? widget.inForce;

  @override
  Widget build(BuildContext context) {
    final buttons = _buttons<PdfClef>(context, removable: widget.removable, onOk: () => Navigator.pop(context, PdfChange(_clef)));
    return AppDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: dialogWidth(context, 320),
        child: AppDropdown<PdfClef>(
          value: _clef,
          isExpanded: true,
          label: 'Clef',
          items: [for (final c in PdfClef.values) DropdownMenuItem(value: c, child: Text(pdfClefName(c).tr))],
          onChanged: (c) => setState(() => _clef = c ?? _clef),
        ),
      ),
      leading: buttons.leading,
      actions: buttons.actions,
    );
  }
}

/// An instrument's name, short name and transposition, named from a staff ([isNew]: one made
/// for it). The transposition follows the name ("Clarinet in B♭") until it is picked.
Future<PdfInstrument?> showPdfInstrumentDialog(BuildContext context, PdfInstrument instrument, {bool isNew = false}) =>
    showAppDialog<PdfInstrument>(context: context, builder: (_) => _InstrumentDialog(instrument: instrument, isNew: isNew));

class _InstrumentDialog extends StatefulWidget {
  const _InstrumentDialog({required this.instrument, required this.isNew});
  final PdfInstrument instrument;
  final bool isNew;

  @override
  State<_InstrumentDialog> createState() => _InstrumentDialogState();
}

class _InstrumentDialogState extends State<_InstrumentDialog> {
  late final _name = TextEditingController(text: widget.isNew ? '' : widget.instrument.name);
  late final _short = TextEditingController(text: widget.isNew ? '' : widget.instrument.abbreviation);
  late final _focus = FocusNode();
  late SpacerKey _key = widget.isNew ? SpacerKey.c : widget.instrument.key;
  bool _keyPicked = false;

  @override
  void initState() {
    super.initState();
    // Typed over: the name selected.
    _name.selection = TextSelection(baseOffset: 0, extentOffset: _name.text.length);
  }

  @override
  void dispose() {
    _name.dispose();
    _short.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _ok => _name.text.trim().isNotEmpty;

  void _named(String name) {
    if (_keyPicked) return setState(() {});
    final from = widget.isNew ? widget.instrument.copyWith(key: SpacerKey.c) : widget.instrument;
    setState(() => _key = from.renamed(name.trim()).key);
  }

  void _apply() {
    if (!_ok) return;
    Navigator.pop(context, widget.instrument.copyWith(name: _name.text.trim(), abbreviation: _short.text.trim(), key: _key));
  }

  void _insert(String symbol) {
    final sel = _name.selection;
    final at = sel.isValid ? sel.start : _name.text.length;
    _name.value = TextEditingValue(
      text: _name.text.replaceRange(at, sel.isValid ? sel.end : at, symbol),
      selection: TextSelection.collapsed(offset: at + symbol.length),
    );
    _named(_name.text);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: Text((widget.isNew
              ? 'New Instrument'
              : widget.instrument.blank
                  ? 'Rename Lane'
                  : 'Rename Instrument')
          .tr),
      content: SizedBox(
        width: dialogWidth(context, 360),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AppTextField(
            controller: _name,
            focusNode: _focus,
            label: 'Name',
            autofocus: true,
            onChanged: _named,
            onSubmitted: (_) => _apply(),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, children: [
            for (final symbol in const ['♭', '♯', '♮'])
              AppChip(label: symbol, tooltip: 'Insert {symbol}'.fill({'symbol': symbol}), onPressed: () => _insert(symbol)),
          ]),
          // A blank lane is only named.
          if (!widget.instrument.blank) ...[
            SizedBox(height: dialogGap(context)),
            Row(children: [
              Expanded(child: AppTextField(controller: _short, label: 'Short name', onSubmitted: (_) => _apply())),
              const SizedBox(width: 12),
              Expanded(
                child: AppDropdown<SpacerKey>(
                  value: _key,
                  isExpanded: true,
                  label: 'Transposition',
                  items: [
                    for (final k in SpacerKey.values)
                      DropdownMenuItem(value: k, child: Text(k == SpacerKey.c ? 'None'.tr : 'in {key}'.fill({'key': k.label}))),
                  ],
                  onChanged: (k) => setState(() {
                    _key = k ?? _key;
                    _keyPicked = true;
                  }),
                ),
              ),
            ]),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        FilledButton(onPressed: _ok ? _apply : null, child: Text((widget.isNew ? 'Add' : 'Rename').tr)),
      ],
    );
  }
}
