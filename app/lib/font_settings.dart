/// Project Settings ▸ Engraving ▸ Fonts: the music font (a bundled SMuFL font, one installed with SMuFL
/// metadata, another installed one from the system's own font picker, or a font file) and
/// whether it is embedded, and the text font (Academico or any installed family) the score is
/// engraved in; with Captions on, the font its captions are drawn in (Default: the app's,
/// Project Settings ▸ Extensions ▸ Captions). Every choice is made at once, as its own Undo step.
///
/// New projects start with the fonts of the one last saved as the default (Save as default).
///
/// Each picker reads the fonts on this computer for itself (once an app run), so a search
/// result works as the page does.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'editor_controller.dart';
import 'error_text.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';

const _fieldWidth = 230.0;

/// As compact as the other settings' controls (a 32-point field, 13-point text).
InputDecorationTheme _compact(BuildContext context) {
  final border = OutlineInputBorder(
      borderRadius: AppStyle.of(context).radius(8), borderSide: BorderSide(color: context.colors.line));
  return InputDecorationTheme(
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    constraints: const BoxConstraints.tightFor(height: 32),
    suffixIconConstraints: const BoxConstraints.tightFor(width: 32, height: 32),
    border: border,
    enabledBorder: border,
  );
}

const _text = TextStyle(fontSize: 13);

/// A field as compact as the other settings' controls: the menu's arrow button no bigger than
/// the field, so it sits in its middle.
Widget _field(BuildContext context, Widget menu) => SizedBox(
      width: _fieldWidth,
      child: IconButtonTheme(
        data: IconButtonThemeData(
          style: IconButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(24, 24),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
        child: menu,
      ),
    );

/// The other settings' dropdown arrow.
Widget _arrow(BuildContext context) => Icon(AppIcon.select.of(context), size: 16, color: context.colors.textMuted);

/// A music font offered: one ready to use, one installed (read when chosen), or a file to pick.
typedef _MusicChoice = ({String name, MusicFont? font, ({FontFace face, String metadata})? installed});

/// The project's music font.
class MusicFontPicker extends StatefulWidget {
  const MusicFontPicker({super.key, required this.controller});
  final EditorController controller;

  @override
  State<MusicFontPicker> createState() => _MusicFontPickerState();
}

class _MusicFontPickerState extends State<MusicFontPicker> {
  EditorController get c => widget.controller;
  var _installed = const <({String name, FontFace face, String metadata})>[];
  String? _error;

  static const _installedFont = '\u0000installed', _fontFile = '\u0000file';

  @override
  void initState() {
    super.initState();
    MusicFont.installed().then((fonts) {
      if (mounted) setState(() => _installed = fonts);
    });
  }

  List<_MusicChoice> get _choices {
    final added = c.addedFonts;
    final current = c.fonts.music.name;
    final choices = [
      for (final f in MusicFont.bundled) (name: f.name, font: f, installed: null),
      for (final i in _installed)
        (
          name: i.name,
          font: added.where((f) => MusicFont.isNamed(i.name, f.name)).firstOrNull,
          installed: (face: i.face, metadata: i.metadata),
        ),
      for (final f in added.where((f) => !_installed.any((i) => MusicFont.isNamed(i.name, f.name)))) (name: f.name, font: f, installed: null),
    ];
    // One picked in the system's font picker, so the field shows it.
    if (!choices.any((m) => m.name == current)) choices.add((name: current, font: null, installed: null));
    return choices;
  }

  Future<void> _choose(String? name) async {
    setState(() => _error = null);
    // The project the choice is for: a picker answers late (macOS's Fonts panel when it closes,
    // which may be after these settings closed and another project opened).
    final session = c.source;
    Future<void> apply(MusicFont font, {bool file = false}) async {
      if (!mounted || !identical(c.source, session)) return;
      await c.setFonts(c.fonts.copyWith(music: font), embed: file ? true : null);
    }

    try {
      switch (name) {
        case null:
          return;
        case _installedFont:
          if (await _pickInstalled() case final font?) await apply(font);
        case _fontFile:
          if (await _pickFile() case final font?) await apply(font, file: true);
        default:
          final choice = _choices.firstWhere((m) => m.name == name);
          final font = choice.font ??
              switch (choice.installed) {
                final i? => await MusicFont.readFace(i.face, metadataPath: i.metadata),
                null => await MusicFont.findInstalled(choice.name) ?? (throw FormatException('${choice.name} not found.')),
              };
          await apply(font);
      }
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  Future<MusicFont?> _pickFile() async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Fonts', extensions: ['otf', 'ttf'], uniformTypeIdentifiers: ['public.opentype-font', 'public.truetype-ttf-font']),
    ]);
    return file == null ? null : MusicFont.read(file.path);
  }

  /// One installed, from the system's font picker (a file where there is none), so it can be
  /// found by name where the project opens.
  Future<MusicFont?> _pickInstalled() async {
    final String? family;
    try {
      family = await _systemFonts.invokeMethod<String>('pickFont', {'family': c.fonts.music.name});
    } on MissingPluginException {
      return _pickFile(); // no picker here (Linux, tests)
    }
    if (family == null || family.isEmpty) return null;
    return await MusicFont.findInstalled(family) ?? (throw FormatException('$family not found.'));
  }

  /// The system's font picker (the runners: macOS's Fonts panel, Windows' Font dialog): the
  /// family chosen, null when none was.
  static const _systemFonts = MethodChannel('curated_score/fonts');

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) => SettingsDropdown<String>(
          value: c.fonts.music.name,
          width: _fieldWidth,
          error: _error ?? (c.fonts.music.isMissing ? 'Not installed' : null),
          onChanged: _choose,
          items: [
            for (final m in _choices) DropdownMenuItem(value: m.name, child: Text(m.name)),
            const DropdownMenuItem(value: _installedFont, child: Text('Installed Font…')),
            const DropdownMenuItem(value: _fontFile, child: Text('Font File…')),
          ],
        ),
      );
}

/// The score's text font, or with [caption] the captions' ('' standing for Default, the app's).
class TextFontPicker extends StatefulWidget {
  const TextFontPicker({super.key, required this.controller, this.caption = false});
  final EditorController controller;
  final bool caption;

  @override
  State<TextFontPicker> createState() => _TextFontPickerState();
}

class _TextFontPickerState extends State<TextFontPicker> {
  EditorController get c => widget.controller;
  List<String>? _installed;
  String? _error;

  /// A family that can't be read changes nothing, and says why (as the music font does).
  Future<void> _choose(String family) async {
    setState(() => _error = null);
    try {
      await c.setFonts(c.fonts.copyWith(text: family));
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  @override
  void initState() {
    super.initState();
    TextFonts.installed().then((families) {
      if (mounted) setState(() => _installed = families);
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final installed = _installed ?? const <String>[];
          final texts = [TextFonts.academico, ...installed.where((f) => f != TextFonts.academico)];
          final score = c.score;
          if (score == null) return const SizedBox.shrink();
          final String value;
          final String? missing;
          if (widget.caption) {
            value = c.captions.font ?? '';
            missing = c.captions.fontFound ? null : 'Not installed';
          } else {
            value = c.fonts.text;
            missing = value != score.fonts.text || score.textFontFound ? null : 'Not installed';
          }
          return _field(
            context,
            DropdownMenu<String>(
              key: ValueKey((value, texts.length)), // shows an Undo's font, and the list once read
              expandedInsets: EdgeInsets.zero,
              inputDecorationTheme: _compact(context),
              textStyle: _text,
              trailingIcon: _arrow(context),
              selectedTrailingIcon: _arrow(context),
              initialSelection: value,
              enableFilter: true,
              requestFocusOnTap: true,
              menuHeight: 320,
              errorText: widget.caption ? missing : _error ?? missing,
              dropdownMenuEntries: [
                if (widget.caption) const DropdownMenuEntry(value: '', label: 'Default'),
                for (final f in texts) DropdownMenuEntry(value: f, label: f),
              ],
              onSelected: (f) {
                if (f == null) return;
                if (widget.caption) {
                  c.captions.setFont(f.isEmpty ? null : f);
                } else {
                  _choose(f);
                }
              },
            ),
          );
        },
      );
}

/// Whether the project's music font is saved inside it.
class EmbedFontSwitch extends StatelessWidget {
  const EmbedFontSwitch({super.key, required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => AppSwitch(
          value: controller.embedFont,
          // A missing font can't be embedded: shown off and disabled, as it will be saved.
          onChanged: controller.canEmbedFont ? (v) => controller.embedFont = v : null,
        ),
      );
}
