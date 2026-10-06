import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'editor_controller.dart';
import 'error_text.dart';
import 'ui_kit.dart';

/// Score ▸ Fonts…: the music font (a bundled SMuFL font, one installed with SMuFL metadata, or
/// a file) and the text font (Academico or any installed family) the score is engraved in;
/// with Captions on, the font its captions are drawn in (Default: the app's, Settings ▸
/// Extension ▸ Captions). Every choice is made at once, as its own Undo step.
Future<void> showFontsDialog(BuildContext context, EditorController c) => showAppDialog<void>(
  context: context,
  builder: (context) => _FontsDialog(controller: c),
);

class _FontsDialog extends StatefulWidget {
  const _FontsDialog({required this.controller});
  final EditorController controller;

  @override
  State<_FontsDialog> createState() => _FontsDialogState();
}

/// A music font offered: one ready to use, one installed (read when chosen), or a file to pick.
typedef _MusicChoice = ({String name, MusicFont? font, ({FontFace face, String metadata})? installed});

class _FontsDialogState extends State<_FontsDialog> {
  EditorController get c => widget.controller;

  // The fonts on this computer (read once an app run, shown when known).
  var _installedMusic = const <({String name, FontFace face, String metadata})>[];
  var _installedText = const <String>[];
  String? _error;

  static const _other = '\u0000other';

  List<_MusicChoice> get _musicChoices {
    final added = c.addedFonts.where((f) => !_installedMusic.any((i) => i.name == f.name));
    return [
      for (final f in MusicFont.bundled) (name: f.name, font: f, installed: null),
      for (final i in _installedMusic)
        (
          name: i.name,
          font: c.addedFonts.where((f) => f.name == i.name).firstOrNull,
          installed: (face: i.face, metadata: i.metadata),
        ),
      for (final f in added) (name: f.name, font: f, installed: null),
    ];
  }

  Future<void> _chooseMusic(String? name) async {
    setState(() => _error = null);
    try {
      if (name == _other) {
        final file = await openFile(acceptedTypeGroups: const [
          XTypeGroup(label: 'Fonts', extensions: ['otf', 'ttf'], uniformTypeIdentifiers: ['public.opentype-font', 'public.truetype-ttf-font']),
        ]);
        if (file == null) return;
        await c.setFonts(c.fonts.copyWith(music: await MusicFont.read(file.path)));
        return;
      }
      final choice = _musicChoices.firstWhere((m) => m.name == name);
      final font = choice.font ?? await MusicFont.readFace(choice.installed!.face, metadataPath: choice.installed!.metadata);
      await c.setFonts(c.fonts.copyWith(music: font));
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  @override
  void initState() {
    super.initState();
    MusicFont.installed().then((fonts) {
      if (mounted) setState(() => _installedMusic = fonts);
    });
    TextFonts.installed().then((families) {
      if (mounted) setState(() => _installedText = families);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final score = c.score;
        if (score == null) return const SizedBox.shrink();
        final colors = context.colors;
        final fonts = c.fonts;
        final texts = [TextFonts.academico, ..._installedText.where((f) => f != TextFonts.academico)];
        final missing = fonts.text != score.fonts.text || score.textFontFound ? null : 'Not installed';

        Widget row(String label, Widget field) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                SizedBox(width: 64, child: Text(label)),
                Expanded(child: field),
              ]),
            );

        return AlertDialog(
          title: Row(children: [
            const Expanded(child: Text('Fonts')),
            if (c.isReengraving) const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row(
                  'Music',
                  DropdownMenu<String>(
                    key: ValueKey(fonts.music),
                    expandedInsets: EdgeInsets.zero,
                    initialSelection: fonts.music.name,
                    requestFocusOnTap: false,
                    dropdownMenuEntries: [
                      for (final m in _musicChoices) DropdownMenuEntry(value: m.name, label: m.name),
                      const DropdownMenuEntry(value: _other, label: 'Other…'),
                    ],
                    onSelected: _chooseMusic,
                  ),
                ),
                row(
                  'Text',
                  DropdownMenu<String>(
                    key: ValueKey((fonts.text, texts.length)), // shows an Undo's font, and the list once read
                    expandedInsets: EdgeInsets.zero,
                    initialSelection: fonts.text,
                    enableFilter: true,
                    requestFocusOnTap: true,
                    menuHeight: 320,
                    errorText: missing,
                    dropdownMenuEntries: [for (final f in texts) DropdownMenuEntry(value: f, label: f)],
                    onSelected: (f) {
                      if (f != null) c.setFonts(fonts.copyWith(text: f));
                    },
                  ),
                ),
                if (c.captions.enabled)
                  row(
                    'Caption',
                    DropdownMenu<String>(
                      key: ValueKey((c.captions.font, texts.length)),
                      expandedInsets: EdgeInsets.zero,
                      initialSelection: c.captions.font ?? '',
                      enableFilter: true,
                      requestFocusOnTap: true,
                      menuHeight: 320,
                      errorText: c.captions.fontFound ? null : 'Not installed',
                      dropdownMenuEntries: [
                        const DropdownMenuEntry(value: '', label: 'Default'),
                        for (final f in texts) DropdownMenuEntry(value: f, label: f),
                      ],
                      onSelected: (f) {
                        if (f != null) c.captions.setFont(f.isEmpty ? null : f);
                      },
                    ),
                  ),
                if (_error != null) Text(_error!, style: TextStyle(fontSize: 12, color: colors.erase)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
          ],
        );
      },
    );
  }
}
