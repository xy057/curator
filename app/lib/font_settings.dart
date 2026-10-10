/// Project Settings ▸ Fonts: the music font (a bundled SMuFL font, one installed with SMuFL
/// metadata, another installed one from the system's own font picker, or a font file) and
/// whether it is embedded, and the text font (Academico or any installed family) the score is
/// engraved in; with Captions on, the font its captions are drawn in (Default: the app's,
/// Settings ▸ Extension ▸ Captions). Every choice is made at once, as its own Undo step.
///
/// Settings ▸ Fonts: the same pickers (`forNewProjects`) for the fonts new projects start
/// with, by name: installed fonts only, as the app keeps no font file.
///
/// Each picker reads the fonts on this computer for itself (once an app run), so a search
/// result works as the page does.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_settings.dart';
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

/// The music font: the project's, or with [MusicFontPicker.forNewProjects] the one new
/// projects start with.
class MusicFontPicker extends StatefulWidget {
  const MusicFontPicker({super.key, required EditorController this.controller}) : settings = null;
  const MusicFontPicker.forNewProjects({super.key, required AppSettings this.settings}) : controller = null;
  final EditorController? controller;
  final AppSettings? settings;

  @override
  State<MusicFontPicker> createState() => _MusicFontPickerState();
}

class _MusicFontPickerState extends State<MusicFontPicker> {
  EditorController? get c => widget.controller;
  var _installed = const <({String name, FontFace face, String metadata})>[];
  List<String>? _families; // read for the new projects' font, to tell whether it is here
  String? _error;

  static const _installedFont = '\u0000installed', _fontFile = '\u0000file';

  @override
  void initState() {
    super.initState();
    MusicFont.installed().then((fonts) {
      if (mounted) setState(() => _installed = fonts);
    });
    if (c == null) {
      TextFonts.installed().then((families) {
        if (mounted) setState(() => _families = families);
      });
    }
  }

  String get _current => c?.fonts.music.name ?? widget.settings!.musicFont;

  bool get _missing {
    if (c case final c?) return c.fonts.music.isMissing;
    final name = _current.toLowerCase(), families = _families;
    return families != null &&
        MusicFont.bundledNamed(_current) == null &&
        !_installed.any((i) => i.name.toLowerCase() == name) &&
        !families.any((f) => f.toLowerCase() == name);
  }

  List<_MusicChoice> get _choices {
    final added = c?.addedFonts ?? const <MusicFont>[];
    final choices = [
      for (final f in MusicFont.bundled) (name: f.name, font: f, installed: null),
      for (final i in _installed)
        (
          name: i.name,
          font: added.where((f) => f.name == i.name).firstOrNull,
          installed: (face: i.face, metadata: i.metadata),
        ),
      for (final f in added.where((f) => !_installed.any((i) => i.name == f.name))) (name: f.name, font: f, installed: null),
    ];
    // One picked in the system's font picker, so the field shows it.
    if (!choices.any((m) => m.name == _current)) choices.add((name: _current, font: null, installed: null));
    return choices;
  }

  Future<void> _choose(String? name) async {
    setState(() => _error = null);
    try {
      switch (name) {
        case null:
          return;
        case _installedFont:
          if (await _pickInstalled() case final font?) await _apply(font);
        case _fontFile:
          if (await _pickFile() case final font?) await _apply(font, file: true);
        default:
          final choice = _choices.firstWhere((m) => m.name == name);
          if (c == null) return await _apply(MusicFont.missing(choice.name)); // kept by name only
          final font = choice.font ??
              switch (choice.installed) {
                final i? => await MusicFont.readFace(i.face, metadataPath: i.metadata),
                null => await MusicFont.findInstalled(choice.name) ?? (throw FormatException('${choice.name} not found.')),
              };
          await _apply(font);
      }
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  /// A file is embedded: elsewhere it can't be found by its name.
  Future<void> _apply(MusicFont font, {bool file = false}) async {
    if (c case final c?) return c.setFonts(c.fonts.copyWith(music: font), embed: file ? true : null);
    widget.settings!.musicFont = font.name;
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
      family = await _systemFonts.invokeMethod<String>('pickFont', {'family': _current});
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
        listenable: (c ?? widget.settings)!,
        builder: (context, _) {
          final choices = _choices;
          return _field(
            context,
            DropdownMenu<String>(
              key: ValueKey((_current, c?.fonts.music, choices.length)), // shows an Undo's font, and the list once read
              expandedInsets: EdgeInsets.zero,
              inputDecorationTheme: _compact(context),
              textStyle: _text,
              trailingIcon: _arrow(context),
              selectedTrailingIcon: _arrow(context),
              initialSelection: _current,
              requestFocusOnTap: false,
              menuHeight: 360,
              errorText: _error ?? (_missing ? 'Not installed' : null),
              dropdownMenuEntries: [
                for (final m in choices) DropdownMenuEntry(value: m.name, label: m.name),
                const DropdownMenuEntry(value: _installedFont, label: 'Installed Font…'),
                if (c != null) const DropdownMenuEntry(value: _fontFile, label: 'Font File…'),
              ],
              onSelected: _choose,
            ),
          );
        },
      );
}

/// The score's text font, or with [caption] the captions' ('' standing for Default, the app's);
/// with [TextFontPicker.forNewProjects] the one new projects start with.
class TextFontPicker extends StatefulWidget {
  const TextFontPicker({super.key, required EditorController this.controller, this.caption = false}) : settings = null;
  const TextFontPicker.forNewProjects({super.key, required AppSettings this.settings})
      : controller = null,
        caption = false;
  final EditorController? controller;
  final AppSettings? settings;
  final bool caption;

  @override
  State<TextFontPicker> createState() => _TextFontPickerState();
}

class _TextFontPickerState extends State<TextFontPicker> {
  EditorController? get c => widget.controller;
  List<String>? _installed;
  String? _error;

  /// A family that can't be read changes nothing, and says why (as the music font does).
  Future<void> _choose(String family) async {
    setState(() => _error = null);
    try {
      await c!.setFonts(c!.fonts.copyWith(text: family));
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
        listenable: (c ?? widget.settings)!,
        builder: (context, _) {
          final installed = _installed ?? const <String>[];
          final texts = [TextFonts.academico, ...installed.where((f) => f != TextFonts.academico)];
          final String value;
          final String? missing;
          if (c case final c?) {
            final score = c.score;
            if (score == null) return const SizedBox.shrink();
            if (widget.caption) {
              value = c.captions.font ?? '';
              missing = c.captions.fontFound ? null : 'Not installed';
            } else {
              value = c.fonts.text;
              missing = c.fonts.text != score.fonts.text || score.textFontFound ? null : 'Not installed';
            }
          } else {
            value = widget.settings!.textFont;
            missing = _installed == null || texts.contains(value) ? null : 'Not installed';
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
                if (c == null) {
                  widget.settings!.textFont = f;
                } else if (widget.caption) {
                  c!.captions.setFont(f.isEmpty ? null : f);
                } else {
                  _choose(f);
                }
              },
            ),
          );
        },
      );
}

/// Whether the music font is saved inside the project; with [EmbedFontSwitch.forNewProjects]
/// whether new projects start so.
class EmbedFontSwitch extends StatelessWidget {
  const EmbedFontSwitch({super.key, required EditorController this.controller}) : settings = null;
  const EmbedFontSwitch.forNewProjects({super.key, required AppSettings this.settings}) : controller = null;
  final EditorController? controller;
  final AppSettings? settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: (controller ?? settings)!,
        builder: (context, _) => Switch(
          value: controller?.embedFont ?? settings!.embedFont,
          onChanged: (v) => controller != null ? controller!.embedFont = v : settings!.embedFont = v,
        ),
      );
}
