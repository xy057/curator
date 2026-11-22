import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:score_engine/score_engine.dart' show WebPluginPackage, WebPluginSetting;

import 'app_colors.dart';
import 'app_icons.dart';
import 'app_settings.dart';
import 'dialog_kit.dart';
import 'edit_dialogs.dart' show saveFileAs;
import 'editor_controller.dart';
import 'error_text.dart';
import 'export_dialog.dart';
import 'l10n/l10n.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';
import 'updater.dart' show appReleaseBuild;
import 'video_export.dart';
import 'web_export.dart';
import 'web_guide.dart';
import 'web_page.dart';
import 'web_plugin_docs.dart';
import 'web_plugins.dart';

/// File ▸ Export to Web…: what the page shows (its title, bars, frame, recordings, captions and
/// images), for each thing a viewer could choose, what they see first and whether they may, and
/// the web plugins the page runs ([WebPlugins]: ticked, added from a file, set).
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
  late double? _ratio = widget.settings.videoRatio.value;

  late final _takes = _c.pageState.takes;
  late final _hasCaptions = _c.extensions.captions.isNotEmpty;
  late final _hasChapters = _c.extensions.exportsChapters;
  late final _hasImages = _c.images.enabled && _c.images.patches.isNotEmpty;
  late final _hasBarNumbers = _c.pageState.barNumbers;
  late final _hasPlayerMap = _c.playerMap.map != null;

  /// Whether the score's notes can be shown in rows where it is engraved (the MIDI view).
  late final _hasMidiView = _c.hasMidiView;

  /// Whether the Video tab's View lane shows anything the page can: a map, or the MIDI view.
  late final _hasViews = _c.automation.views.stretches.any((s) => s.value.kind.showsRows ? _hasMidiView : _hasPlayerMap);

  /// Recordings heard whole as well as the performance (with two or more).
  late Set<String> _whole = {if (_takes.length > 1) for (final t in _takes) t.id};
  bool _captions = true, _chapters = true, _images = true;

  var _recording = const WebChoice(0, open: true);
  var _speed = const WebChoice(1.0, open: true);
  var _captionsShown = const WebChoice(true, open: true);
  var _barNumbersShown = const WebChoice(true, open: true);
  var _instruments = const WebChoice(<String, PartShown>{}, open: true);
  late var _view = WebChoice(_hasViews ? PageShows.views : PageShows.score, open: true);

  /// The web plugins there are, once they are read: the ticked ones go into the page.
  WebPlugins? _plugins;

  @override
  void initState() {
    super.initState();
    WebPlugins.load(widget.settings).then((plugins) {
      if (!mounted) return plugins.dispose();
      setState(() => _plugins = plugins..addListener(_pluginsChanged));
    });
  }

  void _pluginsChanged() => setState(() {});

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
    _plugins?.dispose();
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
    final plugins = _plugins?.chosen ?? const [];
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
          view: _hasPlayerMap || _hasMidiView ? _view : const WebChoice(PageShows.score),
          plugins: [for (final p in plugins) p.plugin],
        ),
        plugins: [for (final p in plugins) p.package],
        takes: [for (final t in _takes) if (_whole.contains(t.id)) t.id],
        captions: _captions,
        chapters: _chapters,
        images: _images,
      );
      if (mounted) setState(() => _stage = _Stage.done);
    } catch (e) {
      // Whatever went wrong: left writing, the dialog could never be closed.
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _error = e is VideoExportException ? e.message : describeError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _stage == _Stage.writing;
    return AppDialog(
      // A click outside doesn't close it (see showWebExportDialog), but Esc does, as Cancel would.
      onEscape: busy ? null : () => Navigator.pop(context),
      title: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Expanded(child: Text('Export to Web'.tr)),
        // The Curator that writes the page, and so its player.
        Text('Curator $appReleaseBuild', style: TextStyle(fontSize: 13, fontWeight: FontWeight.normal, color: context.colors.textMuted)),
      ]),
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
            builder: (context, ok) => ok.data == false ? Text('This build of Curator has no web player.'.tr) : _fontsNotice(),
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

  /// The fonts installed here that go with the page: their licences decide whether it may be published.
  Widget _fontsNotice() {
    final fonts = WebExport.installedFonts(_c, captions: _captions);
    if (fonts.isEmpty) return const SizedBox();
    final text = 'Includes installed fonts ({fonts}): publish only if their licenses allow.'.fill({'fonts': fonts.join(', ')});
    return Tip(message: text, child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis));
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
      if (_hasChapters) ExportRow(label: 'Chapters', child: AppSwitch(value: _chapters, onChanged: (v) => setState(() => _chapters = v))),
      if (_hasImages) ExportRow(label: 'Images', child: AppSwitch(value: _images, onChanged: (v) => setState(() => _images = v))),
      if (_takes.length > 1) ...[
        gap,
        const ExportHeading('Recordings'),
        AppCheckRow(value: true, onChanged: (_) {}, label: 'Performance'),
        for (final t in _takes)
          AppCheckRow(
            value: _whole.contains(t.id),
            label: t.label,
            named: true,
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
            named: true, // recordings' names, the performance's translated already
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
      if (_hasPlayerMap || _hasMidiView)
        // What the frame shows: left to the viewer, or as set here (the View lane's views, kept to).
        _ViewerRow(
          label: 'View',
          open: _view.open,
          onOpen: (v) => setState(() => _view = _view.copyWith(open: v)),
          child: ExportSelect<PageShows>(
            named: true, // translated here
            value: _view.value,
            items: [
              if (_hasViews) (PageShows.views, 'As in Video tab'.tr, true),
              (PageShows.score, _c.isMidi ? 'MIDI View'.tr : 'Score'.tr, true),
              if (_hasMidiView) (PageShows.midi, 'MIDI View'.tr, true),
              if (_hasPlayerMap) (PageShows.map, 'Player Map'.tr, true),
            ],
            onChanged: (v) => setState(() => _view = _view.copyWith(value: v)),
          ),
        ),
      _ViewerRow(
        label: 'Instruments',
        open: _instruments.open,
        onOpen: (v) => setState(() => _instruments = _instruments.copyWith(open: v)),
        child: Text('As curated'.tr, style: TextStyle(fontSize: 14, color: context.colors.textMuted)),
      ),
      if (_plugins case final plugins?) ...[
        gap,
        ExportHeading('Plugins', trailing: _PluginsMenu(plugins)),
        for (final p in plugins.packages) _PluginRow(plugins, p),
      ],
    ];
  }
}

/// By Plugins: a web plugin added from its file, and the docs for writing one.
class _PluginsMenu extends StatelessWidget {
  const _PluginsMenu(this.plugins);
  final WebPlugins plugins;

  static const _types = XTypeGroup(label: 'Curator Web Plugin', extensions: [WebPluginPackage.fileExtension]);

  /// Adds the plugin in the .cwp file the user chooses, in place of the one the app has with
  /// its id.
  Future<void> _add(BuildContext context) async {
    final file = await openFile(acceptedTypeGroups: const [_types]);
    if (file == null) return;
    try {
      plugins.add(WebPluginPackage.read(await File(file.path).readAsBytes()));
    } on FormatException catch (e) {
      if (context.mounted) await showNotice(context, 'Couldn’t Add the Plugin'.tr, e.message.tr);
    } on FileSystemException catch (e) {
      if (context.mounted) await showNotice(context, 'Couldn’t Add the Plugin'.tr, describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) => AppPopupMenuButton<VoidCallback>(
        tooltip: 'More'.tr,
        iconSize: 18,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 150),
        icon: Icon(AppIcon.more.of(context), color: context.colors.textMuted),
        onSelected: (action) => action(),
        itemBuilder: (_) => [
          menuItem(context, value: () => _add(context), child: Text('Add Plugin from File…'.tr)),
          menuItem(context,
              value: () => saveFileAs(context,
                  types: const [XTypeGroup(label: 'Zip', extensions: ['zip'])],
                  suggestedName: 'Curator Web Plugin Docs.zip',
                  extension: 'zip',
                  failTitle: 'Couldn’t Save the Docs'.tr,
                  write: (file) async => file.writeAsBytes(await webPluginPack())),
              child: Text('Download Docs for AI…'.tr)),
        ],
      );
}

/// A web plugin: ticked, it goes into the page. Its settings (those plugin.json lists) and,
/// for one the user added, Remove are at the row's end.
class _PluginRow extends StatelessWidget {
  const _PluginRow(this.plugins, this.package);
  final WebPlugins plugins;
  final WebPluginPackage package;

  @override
  Widget build(BuildContext context) {
    final own = plugins.isOwn(package.id), colors = context.colors;
    Widget button(String tip, AppIcon icon, VoidCallback onPressed) => Tip(
          message: tip,
          child: IconButton(
            iconSize: 16,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            color: colors.textMuted,
            onPressed: onPressed,
            icon: Icon(icon.of(context)),
          ),
        );
    final row = AppCheckRow(
      value: plugins.isOn(package.id),
      label: package.name,
      named: !own, // its maker's name for it
      onChanged: (on) => plugins.turn(package.id, on ?? false),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (package.settings.isNotEmpty) button('Settings…'.tr, AppIcon.settings, () => _showSettings(context)),
        if (!own) button('Remove'.tr, AppIcon.delete, () => plugins.remove(package.id)),
      ]),
    );
    final summary = own ? package.summary.tr : package.summary;
    return summary.isEmpty ? row : Tip(message: summary, child: row);
  }

  /// The plugin's settings, each kept as it is set.
  Future<void> _showSettings(BuildContext context) => showAppDialog<void>(
        context: context,
        builder: (context) => ListenableBuilder(
          listenable: plugins,
          builder: (context, _) {
            final own = plugins.isOwn(package.id), values = plugins.settingsOf(package);
            return AppDialog(
              title: Text(own ? package.name.tr : package.name),
              content: SizedBox(
                width: dialogWidth(context, 380),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final setting in package.settings)
                    if (_SettingField(setting, values[setting.id]!, own: own, onChanged: (v) => plugins.set(package, setting.id, v)) case final field)
                      // A text has its name over it, as the dialog's other fields have.
                      setting.type == 'text' ? Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: field) : ExportRow(label: setting.label, child: field),
                ]),
              ),
              actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text('Done'.tr))],
            );
          },
        ),
      );
}

/// One setting of a web plugin's: a switch, a choice among its options, or a text.
class _SettingField extends StatefulWidget {
  const _SettingField(this.setting, this.value, {required this.own, required this.onChanged});
  final WebPluginSetting setting;
  final Object value;

  /// Whether the plugin is Curator's own: its options' names are the interface's, translated.
  final bool own;
  final ValueChanged<Object> onChanged;

  @override
  State<_SettingField> createState() => _SettingFieldState();
}

class _SettingFieldState extends State<_SettingField> {
  late final _text = TextEditingController(text: widget.setting.type == 'text' ? widget.value as String : '');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (widget.setting.type) {
        'switch' => AppSwitch(value: widget.value == true, onChanged: widget.onChanged),
        'choice' => ExportSelect<String>(
            named: !widget.own,
            value: widget.value as String,
            items: [for (final o in widget.setting.options) (o.value, o.label, true)],
            onChanged: widget.onChanged,
          ),
        _ => AppTextField(label: widget.setting.label, controller: _text, maxLength: 200, onChanged: widget.onChanged),
      };
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
