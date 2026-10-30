import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_settings.dart';
import 'dialog_kit.dart';
import 'editor_controller.dart';
import 'export_dialog.dart';
import 'extensions/extension.dart';
import 'l10n/l10n.dart';
import 'ui_kit.dart';
import 'video_export.dart';
import 'web_export.dart';
import 'web_guide.dart';
import 'web_page.dart';

/// File ▸ Export to Web…: what the page shows (its title, bars, frame, recordings, captions and
/// images) and, for each thing a viewer could choose, what they see first and whether they may.
Future<void> showWebExportDialog(BuildContext context, EditorController controller, AppSettings settings,
    {required String suggestedName}) {
  controller.playback.pause();
  return showAppDialog<void>(
    context: context,
    barrierDismissible: false, // closing while it writes would leave half a folder
    builder: (context) => _WebExportDialog(controller: controller, settings: settings, suggestedName: suggestedName),
  );
}

enum _Stage { setup, writing, done, failed }

class _WebExportDialog extends StatefulWidget {
  const _WebExportDialog({required this.controller, required this.settings, required this.suggestedName});
  final EditorController controller;
  final AppSettings settings;
  final String suggestedName;

  @override
  State<_WebExportDialog> createState() => _WebExportDialogState();
}

class _WebExportDialogState extends State<_WebExportDialog> {
  EditorController get _c => widget.controller;

  late final _title = TextEditingController(text: widget.suggestedName);
  late final _bars = _c.score!.timeline.measureStarts.length - 1;
  late final _from = TextEditingController(text: '1'), _to = TextEditingController(text: '$_bars');
  late double? _ratio = widget.settings.previewVideoFrame ? widget.settings.videoRatio.value : null;

  late final _takes = _c.pageState.takes;
  late final _hasCaptions = _c.extensionOn(Extensions.captions.id) && _c.captions.captions.isNotEmpty;
  late final _hasImages = _c.extensionOn(Extensions.attachImage.id) && _c.images.patches.isNotEmpty;
  late final _hasBarNumbers = _c.pageState.barNumbers;

  /// Recordings heard whole as well as the performance (with two or more).
  late Set<String> _whole = {if (_takes.length > 1) for (final t in _takes) t.id};
  bool _captions = true, _images = true;

  var _recording = const WebChoice(0, open: true);
  var _speed = const WebChoice(1.0, open: true);
  var _captionsShown = const WebChoice(true, open: true);
  var _barNumbersShown = const WebChoice(true, open: true);
  var _instruments = const WebChoice(<String, PartShown>{}, open: true);

  var _stage = _Stage.setup;
  String? _error, _output;
  late final Future<bool> _available = WebExport.available();

  /// The page's folder, once written.
  String? get _folder => _stage == _Stage.done ? File(_output!).parent.path : null;

  int? get _first => int.tryParse(_from.text);
  int? get _last => int.tryParse(_to.text);
  bool get _barsOk => switch ((_first, _last)) { (final f?, final l?) => f >= 1 && f <= l && l <= _bars, _ => false };

  /// What the page offers to hear: the performance, then each recording heard whole.
  List<String> get _recordings => [
        if (_takes.isNotEmpty) 'Performance'.tr,
        for (final t in _takes)
          if (_whole.contains(t.id)) t.label,
      ];

  @override
  void dispose() {
    _title.dispose();
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final location = await getSaveLocation(suggestedName: _title.text.trim().isEmpty ? widget.suggestedName : _title.text.trim());
    if (location == null || !mounted) return;
    setState(() {
      _stage = _Stage.writing;
      _error = null;
    });
    final recordings = _recordings.length;
    try {
      _output = await WebExport.write(
        _c,
        location.path,
        page: WebPage(
          title: _title.text.trim().isEmpty ? widget.suggestedName : _title.text.trim(),
          staffSpace: _c.staffSpace,
          ratio: _ratio,
          firstBar: _first!,
          lastBar: _last!,
          recordings: const [],
          captionStyle: _c.captions.style,
          instruments: _instruments,
          recording: _recording.copyWith(value: _recording.value.clamp(0, recordings == 0 ? 0 : recordings - 1)),
          captions: _captionsShown,
          barNumbers: _barNumbersShown,
          speed: _speed,
        ),
        takes: [for (final t in _takes) if (_whole.contains(t.id)) t.id],
        captions: _captions,
        images: _images,
      );
      if (mounted) setState(() => _stage = _Stage.done);
    } on VideoExportException catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _stage == _Stage.writing;
    return AppDialog(
      title: Text('Export to Web'.tr),
      content: SizedBox(
        width: dialogWidth(context, 440),
        child: IgnorePointer(
          ignoring: _stage != _Stage.setup,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: _fields(context)),
        ),
      ),
      status: switch (_stage) {
        _Stage.setup => FutureBuilder(
            future: _available,
            builder: (context, ok) => ok.data == false ? Text('This build of Curator has no web player.'.tr) : const SizedBox(),
          ),
        _Stage.writing => Row(children: [
            const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Text('Writing…'.tr),
          ]),
        _Stage.done => null,
        _Stage.failed => Tip(message: _error ?? '', child: Text(_error ?? '', maxLines: 1, overflow: TextOverflow.ellipsis)),
      },
      leading: [
        TextButton(onPressed: busy ? null : () => showWebGuide(context, folder: _folder), child: Text('How to Publish'.tr)),
      ],
      actions: switch (_stage) {
        _Stage.setup || _Stage.writing => [
            TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: Text('Cancel'.tr)),
            FutureBuilder(
              future: _available,
              builder: (context, ok) =>
                  FilledButton(onPressed: !busy && ok.data == true && _barsOk ? _start : null, child: Text('Export…'.tr)),
            ),
          ],
        _Stage.done => [
            TextButton(onPressed: () => revealInFileManager(_output!), child: Text(revealLabel)),
            TextButton(onPressed: () => WebPreview.open(_folder!), child: Text('Open in Browser'.tr)),
            FilledButton(onPressed: () => Navigator.pop(context), child: Text('Done'.tr)),
          ],
        _Stage.failed => [
            TextButton(onPressed: () => Navigator.pop(context), child: Text('Close'.tr)),
            FilledButton(onPressed: () => setState(() => _stage = _Stage.setup), child: Text('Back'.tr)),
          ],
      },
    );
  }

  List<Widget> _fields(BuildContext context) {
    final gap = SizedBox(height: dialogGap(context) + 8);
    final ratios = [
      (null as double?, 'Window'),
      for (final r in VideoRatio.presets) (r.value, r.label),
      if (_ratio case final r? when !VideoRatio.presets.any((p) => p.value == r)) (r, widget.settings.videoRatio.label),
    ];
    final formatters = [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)];
    Widget bar(String label, TextEditingController text) => Expanded(
          child: AppTextField(
            label: label,
            controller: text,
            bad: !_barsOk,
            keyboardType: TextInputType.number,
            inputFormatters: formatters,
            onChanged: (_) => setState(() {}),
          ),
        );
    final choices = _recordings;
    return [
      const ExportHeading('Page'),
      AppTextField(label: 'Title', controller: _title),
      SizedBox(height: dialogGap(context)),
      Row(children: [bar('From bar', _from), const SizedBox(width: 12), bar('To bar', _to)]),
      const SizedBox(height: 6),
      ExportRow(
        label: 'Frame',
        child: ExportSelect<double?>(value: _ratio, items: [for (final (v, name) in ratios) (v, name, true)], onChanged: (r) => setState(() => _ratio = r)),
      ),
      if (_hasCaptions) ExportRow(label: 'Captions', child: AppSwitch(value: _captions, onChanged: (v) => setState(() => _captions = v))),
      if (_hasImages) ExportRow(label: 'Images', child: AppSwitch(value: _images, onChanged: (v) => setState(() => _images = v))),
      if (_takes.length > 1) ...[
        gap,
        const ExportHeading('Recordings'),
        AppCheckRow(value: true, onChanged: (_) {}, label: 'Performance'),
        for (final t in _takes)
          AppCheckRow(
            value: _whole.contains(t.id),
            label: t.label,
            onChanged: (on) => setState(() => _whole = on == true ? {..._whole, t.id} : {..._whole}..remove(t.id)),
          ),
      ],
      gap,
      const ExportHeading('Viewer'),
      const _ViewerHeader(),
      if (choices.length > 1)
        _ViewerRow(
          label: 'Recording',
          open: _recording.open,
          onOpen: (v) => setState(() => _recording = _recording.copyWith(open: v)),
          child: ExportSelect<int>(
            value: _recording.value.clamp(0, choices.length - 1),
            items: [for (final (i, name) in choices.indexed) (i, name, true)],
            onChanged: (i) => setState(() => _recording = _recording.copyWith(value: i)),
          ),
        ),
      _ViewerRow(
        label: 'Speed',
        open: _speed.open,
        onOpen: (v) => setState(() => _speed = _speed.copyWith(open: v)),
        child: ExportSelect<double>(
          value: _speed.value,
          items: [for (final s in WebPage.speeds) (s, '$s×', true)],
          onChanged: (s) => setState(() => _speed = _speed.copyWith(value: s)),
        ),
      ),
      if (_hasCaptions && _captions)
        _ViewerRow(
          label: 'Captions',
          open: _captionsShown.open,
          onOpen: (v) => setState(() => _captionsShown = _captionsShown.copyWith(open: v)),
          child: AppSwitch(value: _captionsShown.value, onChanged: (v) => setState(() => _captionsShown = _captionsShown.copyWith(value: v))),
        ),
      if (_hasBarNumbers)
        _ViewerRow(
          label: 'Bar numbers',
          open: _barNumbersShown.open,
          onOpen: (v) => setState(() => _barNumbersShown = _barNumbersShown.copyWith(open: v)),
          child: AppSwitch(
              value: _barNumbersShown.value, onChanged: (v) => setState(() => _barNumbersShown = _barNumbersShown.copyWith(value: v))),
        ),
      _ViewerRow(
        label: 'Instruments',
        open: _instruments.open,
        onOpen: (v) => setState(() => _instruments = _instruments.copyWith(open: v)),
        child: Text('As curated'.tr, style: TextStyle(fontSize: 14, color: context.colors.textMuted)),
      ),
    ];
  }
}

/// Over the viewer's rows: which column is what they may change.
class _ViewerHeader extends StatelessWidget {
  const _ViewerHeader();

  @override
  Widget build(BuildContext context) => Row(children: [
        const Spacer(),
        Text('Viewer can change'.tr, style: TextStyle(fontSize: 12.5, color: context.colors.textMuted)),
      ]);
}

/// A thing the viewer could choose: what they see at first ([child]), and whether they may
/// change it ([open]).
class _ViewerRow extends StatelessWidget {
  const _ViewerRow({required this.label, required this.open, required this.onOpen, required this.child});
  final String label;
  final bool open;
  final ValueChanged<bool> onOpen;
  final Widget child;

  @override
  Widget build(BuildContext context) => ExportRow(
        label: label,
        child: Row(children: [
          Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
          const SizedBox(width: 16),
          SizedBox(width: 40, child: Center(child: Checkbox(value: open, onChanged: (v) => onOpen(v ?? false)))),
        ]),
      );
}
