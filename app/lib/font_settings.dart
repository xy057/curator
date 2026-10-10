/// Project Settings ▸ Fonts: the music font (a bundled SMuFL font, one installed with SMuFL
/// metadata, or another: a file while it is embedded, else one chosen in the system's own font
/// picker) and whether it is embedded, and the text font (Academico or any installed family) the score is
/// engraved in; with Captions on, the font its captions are drawn in (Default: the app's,
/// Settings ▸ Extension ▸ Captions). Every choice is made at once, as its own Undo step.
///
/// Each picker reads the fonts on this computer for itself (once an app run), so a search
/// result works as the page does.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'editor_controller.dart';
import 'error_text.dart';

const _fieldWidth = 230.0;

/// As compact as the other settings' controls (a 32-point field, 13-point text).
InputDecorationTheme _compact(BuildContext context) {
  final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: context.colors.line));
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
Widget _arrow(BuildContext context) => Icon(Icons.unfold_more_rounded, size: 16, color: context.colors.textMuted);

/// A music font offered: one ready to use, one installed (read when chosen), or a file to pick.
typedef _MusicChoice = ({String name, MusicFont? font, ({FontFace face, String metadata})? installed});

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

  static const _other = '\u0000other';

  @override
  void initState() {
    super.initState();
    MusicFont.installed().then((fonts) {
      if (mounted) setState(() => _installed = fonts);
    });
  }

  List<_MusicChoice> get _choices {
    final added = c.addedFonts.where((f) => !_installed.any((i) => i.name == f.name));
    return [
      for (final f in MusicFont.bundled) (name: f.name, font: f, installed: null),
      for (final i in _installed)
        (
          name: i.name,
          font: c.addedFonts.where((f) => f.name == i.name).firstOrNull,
          installed: (face: i.face, metadata: i.metadata),
        ),
      for (final f in added) (name: f.name, font: f, installed: null),
    ];
  }

  Future<void> _choose(String? name) async {
    setState(() => _error = null);
    try {
      if (name == _other) {
        final font = c.embedFont ? await _pickFile() : await _pickInstalled();
        if (font != null) await c.setFonts(c.fonts.copyWith(music: font));
        return;
      }
      final choice = _choices.firstWhere((m) => m.name == name);
      final font = choice.font ?? await MusicFont.readFace(choice.installed!.face, metadataPath: choice.installed!.metadata);
      await c.setFonts(c.fonts.copyWith(music: font));
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  /// An embedded font: any font file.
  Future<MusicFont?> _pickFile() async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Fonts', extensions: ['otf', 'ttf'], uniformTypeIdentifiers: ['public.opentype-font', 'public.truetype-ttf-font']),
    ]);
    return file == null ? null : MusicFont.read(file.path);
  }

  /// A font that isn't embedded: one installed, from the system's font picker (a file where
  /// there is none), so it can be found by name where the project opens.
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
        builder: (context, _) => _field(
          context,
          DropdownMenu<String>(
            key: ValueKey((c.fonts.music, _installed.length)), // shows an Undo's font, and the list once read
            expandedInsets: EdgeInsets.zero,
            inputDecorationTheme: _compact(context),
            textStyle: _text,
            trailingIcon: _arrow(context),
            selectedTrailingIcon: _arrow(context),
            initialSelection: c.fonts.music.name,
            requestFocusOnTap: false,
            errorText: _error ?? (c.fonts.music.isMissing ? 'Not installed' : null),
            dropdownMenuEntries: [
              for (final m in _choices) DropdownMenuEntry(value: m.name, label: m.name),
              const DropdownMenuEntry(value: _other, label: 'Other…'),
            ],
            onSelected: _choose,
          ),
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
  var _installed = const <String>[];
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
          final score = c.score;
          if (score == null) return const SizedBox.shrink();
          final texts = [TextFonts.academico, ..._installed.where((f) => f != TextFonts.academico)];
          final String value;
          final String? missing;
          if (widget.caption) {
            value = c.captions.font ?? '';
            missing = c.captions.fontFound ? null : 'Not installed';
          } else {
            value = c.fonts.text;
            missing = c.fonts.text != score.fonts.text || score.textFontFound ? null : 'Not installed';
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

/// Whether the music font is saved inside the project.
class EmbedFontSwitch extends StatelessWidget {
  const EmbedFontSwitch({super.key, required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Switch(value: controller.embedFont, onChanged: (v) => controller.embedFont = v),
      );
}
