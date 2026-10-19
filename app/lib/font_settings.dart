/// Project Settings ▸ Engraving ▸ Fonts: the music font (a bundled SMuFL font, one installed with SMuFL
/// metadata, another installed one from the system's own font picker, or a font file) and
/// whether it is embedded, and the text font (Academico or any installed family) the score is
/// engraved in; with Captions on, the font its captions are drawn in (Default: the app's,
/// Settings ▸ Extensions ▸ Captions). Every choice is made at once, as its own Undo step.
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
import 'app_icons.dart';
import 'app_settings.dart';
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

/// The fonts a picker sets: the open project's ([ProjectFonts], each change an edit), or the
/// ones new projects start with ([NewProjectFonts], by name: the app keeps no font file).
sealed class FontTarget {
  const FontTarget();
  factory FontTarget.of(EditorController? controller, AppSettings? settings) =>
      controller != null ? ProjectFonts(controller) : NewProjectFonts(settings!);

  Listenable get listenable;

  /// The music font's name.
  String get music;

  /// What a choice is made for: a picker that answers late applies its choice only while this
  /// is the same (a project opened meanwhile isn't).
  Object? get session;

  /// Sets the music font; [file]: one from a font file, embedded (elsewhere it can't be found
  /// by its name).
  Future<void> setMusic(MusicFont font, {bool file = false});

  String get text;
  Future<void> setText(String family);

  bool get embed;
  set embed(bool value);

  /// Whether [embed] can be switched on: a missing font has nothing to embed.
  bool get canEmbed;
}

final class ProjectFonts extends FontTarget {
  const ProjectFonts(this.controller);
  final EditorController controller;

  @override
  Listenable get listenable => controller;
  @override
  String get music => controller.fonts.music.name;
  @override
  Object? get session => controller.source;
  @override
  Future<void> setMusic(MusicFont font, {bool file = false}) =>
      controller.setFonts(controller.fonts.copyWith(music: font), embed: file ? true : null);
  @override
  String get text => controller.fonts.text;
  @override
  Future<void> setText(String family) => controller.setFonts(controller.fonts.copyWith(text: family));
  @override
  bool get embed => controller.embedFont;
  @override
  set embed(bool value) => controller.embedFont = value;
  @override
  bool get canEmbed => controller.canEmbedFont;
}

final class NewProjectFonts extends FontTarget {
  const NewProjectFonts(this.settings);
  final AppSettings settings;

  @override
  Listenable get listenable => settings;
  @override
  String get music => settings.musicFont;
  @override
  Object? get session => settings;
  @override
  Future<void> setMusic(MusicFont font, {bool file = false}) async => settings.musicFont = font.name;
  @override
  String get text => settings.textFont;
  @override
  Future<void> setText(String family) async => settings.textFont = family;
  @override
  bool get embed => settings.embedFont;
  @override
  set embed(bool value) => settings.embedFont = value;
  @override
  bool get canEmbed => true;
}

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
  FontTarget get _target => FontTarget.of(widget.controller, widget.settings);
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
    if (_target is NewProjectFonts) {
      TextFonts.installed().then((families) {
        if (mounted) setState(() => _families = families);
      });
    }
  }

  bool get _missing {
    final name = _target.music;
    return switch (_target) {
      ProjectFonts(:final controller) => controller.fonts.music.isMissing,
      NewProjectFonts() => _families != null &&
          MusicFont.bundledNamed(name) == null &&
          !_installed.any((i) => MusicFont.isNamed(i.name, name)) &&
          !_families!.any((f) => MusicFont.isNamed(f, name)),
    };
  }

  List<_MusicChoice> get _choices {
    final added = switch (_target) {
      ProjectFonts(:final controller) => controller.addedFonts,
      NewProjectFonts() => const <MusicFont>[],
    };
    final current = _target.music;
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
    final target = _target, session = target.session;
    Future<void> apply(MusicFont font, {bool file = false}) async {
      if (target is ProjectFonts && (!mounted || !identical(target.session, session))) return;
      await target.setMusic(font, file: file);
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
          if (target is NewProjectFonts) return await apply(MusicFont.missing(choice.name)); // kept by name only
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
      family = await _systemFonts.invokeMethod<String>('pickFont', {'family': _target.music});
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
        listenable: _target.listenable,
        builder: (context, _) => SettingsDropdown<String>(
          value: _target.music,
          width: _fieldWidth,
          error: _error ?? (_missing ? 'Not installed' : null),
          onChanged: _choose,
          items: [
            for (final m in _choices) DropdownMenuItem(value: m.name, child: Text(m.name)),
            const DropdownMenuItem(value: _installedFont, child: Text('Installed Font…')),
            // Only a project keeps a font file.
            if (_target is ProjectFonts) const DropdownMenuItem(value: _fontFile, child: Text('Font File…')),
          ],
        ),
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
  FontTarget get _target => FontTarget.of(widget.controller, widget.settings);
  List<String>? _installed;
  String? _error;

  /// A family that can't be read changes nothing, and says why (as the music font does).
  Future<void> _choose(String family) async {
    setState(() => _error = null);
    try {
      await _target.setText(family);
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
        listenable: _target.listenable,
        builder: (context, _) {
          final installed = _installed ?? const <String>[];
          final texts = [TextFonts.academico, ...installed.where((f) => f != TextFonts.academico)];
          final String value;
          final String? missing;
          switch (_target) {
            case ProjectFonts(:final controller):
              final score = controller.score;
              if (score == null) return const SizedBox.shrink();
              if (widget.caption) {
                value = controller.captions.font ?? '';
                missing = controller.captions.fontFound ? null : 'Not installed';
              } else {
                value = controller.fonts.text;
                missing = value != score.fonts.text || score.textFontFound ? null : 'Not installed';
              }
            case NewProjectFonts(:final settings):
              value = settings.textFont;
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
                if (widget.caption) {
                  widget.controller!.captions.setFont(f.isEmpty ? null : f);
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
  Widget build(BuildContext context) {
    final target = FontTarget.of(controller, settings);
    return ListenableBuilder(
      listenable: target.listenable,
      builder: (context, _) => AppSwitch(
        value: target.embed,
        // A missing font can't be embedded: shown off and disabled, as it will be saved.
        onChanged: target.canEmbed ? (v) => target.embed = v : null,
      ),
    );
  }
}
