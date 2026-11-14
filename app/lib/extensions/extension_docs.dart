import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import '../app_colors.dart';
import '../app_icons.dart';
import '../dialog_kit.dart';
import '../edit_dialogs.dart' show confirmSavePath;
import '../error_text.dart';
import '../l10n/l10n.dart';
import '../ui_kit.dart';
import 'bundled.dart';

/// The guide the extension editor's Help shows.
const extensionGuideAsset = 'assets/help/extensions.md';

/// What the pack's README says: what is in it, and how one is written, for a model handed the
/// folder to write an extension from. In English, as the docs are.
const _packReadme = '''
# Curator extension docs

Everything needed to write an extension (a `.cpe` package) for Curator, for a person or an AI
assistant.

- `extension-api.md`: the guide to writing an extension, then the reference: every socket with
  its ports and properties, every Lua function. Read this first.
- `api.json`: the same reference as data.
- `examples/`: Curator's own extensions, each a folder laid out as a package is
  (`extension.json`, `connect.json`, `src/*.lua`, `README.md`). They are working code.

## For an AI assistant

- An extension is a folder (zipped as `.cpe`) of `extension.json`, `connect.json` and Lua files
  under `src/`. Give every file in full.
- Curator calls only what `connect.json` wires: each wire is `["node.port", "file.lua#function"]`.
  A function nothing is wired to is never called by Curator.
- Use only the sockets, ports and functions in `extension-api.md` at or below the API level
  you write in `extension.json` (`"api"`). Do not invent others; `curator.has("name")` says
  whether one is there.
- Lua draws nothing and builds no interface: it describes (a lane's items, a form's rows), and
  Curator draws it. Places are in quarter notes from the start of the score, lists start at 1.
- Keep what is saved in `curator.data()` and save it with `curator.save("…")`: one Undo step.
- An id of your own has a dot: `com.example.notes`.
- Start from the example nearest what is asked: `chapters` (markers in a lane, a video's
  chapters), `tonality` (stretches in a lane, a band over the score), `captions` (text under
  the score, a sheet, files, settings), `attachImage` (pictures on the score).
''';

/// The docs as a zip to hand to a person or a model: a README saying what is in it, the guide
/// and reference as one Markdown file, the API as JSON, and each of [examples] (Curator's own
/// extensions) as a folder. The same bytes for the same docs.
Uint8List extensionDocsPack(String guide, {required List<ExtensionPackage> examples}) {
  final at = DateTime.utc(2000).millisecondsSinceEpoch ~/ 1000;
  final archive = Archive();
  void add(String path, List<int> bytes) => archive.add(ArchiveFile.bytes('curator-extension-docs/$path', bytes)..lastModTime = at);
  add('README.md', utf8.encode(_packReadme.trimLeft()));
  add('extension-api.md', utf8.encode(ExtensionApi.docs(guide)));
  add('api.json', utf8.encode(const JsonEncoder.withIndent('  ').convert(ExtensionApi.toJson())));
  for (final p in examples) {
    p.files.forEach((path, bytes) => add('examples/${p.id}/$path', bytes));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// The head of the editor's Reference and Help: its [title], Copy (the docs whole, as
/// Markdown, to paste to a model or a note) and Download (the pack: [extensionDocsPack]).
class ExtensionDocsBar extends StatefulWidget {
  const ExtensionDocsBar({super.key, required this.title});
  final String title;

  @override
  State<ExtensionDocsBar> createState() => _ExtensionDocsBarState();
}

class _ExtensionDocsBarState extends State<ExtensionDocsBar> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: ExtensionApi.docs(await rootBundle.loadString(extensionGuideAsset))));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (mounted) setState(() => _copied = false);
  }

  Future<void> _download() async {
    final location = await getSaveLocation(
        acceptedTypeGroups: const [XTypeGroup(label: 'Zip', extensions: ['zip'])], suggestedName: 'Curator Extension Docs.zip');
    if (location == null || !mounted) return;
    final path = await confirmSavePath(context, location.path, 'zip');
    if (path == null) return;
    try {
      await File(path).writeAsBytes(extensionDocsPack(await rootBundle.loadString(extensionGuideAsset), examples: BundledExtensions.packages));
    } on FileSystemException catch (e) {
      if (!mounted) return;
      await showAppDialog<void>(
        context: context,
        builder: (context) => AppDialog(
          title: Text('Couldn’t Save the Docs'.tr),
          content: Text(describeError(e)),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text('OK'.tr))],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: 36,
      padding: const EdgeInsets.only(left: 16, right: 6),
      decoration: BoxDecoration(color: colors.chrome, border: Border(bottom: BorderSide(color: colors.line))),
      child: Row(children: [
        Expanded(child: Text(widget.title, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: colors.text))),
        ToolbarButton(icon: (_copied ? AppIcon.check : AppIcon.copy).of(context), tooltip: 'Copy Docs'.tr, onPressed: _copy),
        ToolbarButton(icon: AppIcon.fetch.of(context), tooltip: 'Download Docs for AI…'.tr, onPressed: _download),
      ]),
    );
  }
}
