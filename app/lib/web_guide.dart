import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'dialog_kit.dart';
import 'export_dialog.dart' show ExportHeading;
import 'l10n/l10n.dart';
import 'ui_kit.dart';
import 'updater.dart' show openInBrowser;
import 'web_export.dart';

/// Export to Web's guide: trying a page on this computer, and putting it online. With [folder]
/// (a page just exported) its commands name it and it can be opened here.
Future<void> showWebGuide(BuildContext context, {String? folder}) => showAppDialog<void>(
      context: context,
      builder: (context) => _WebGuide(folder: folder),
    );

class _WebGuide extends StatelessWidget {
  const _WebGuide({this.folder});
  final String? folder;

  @override
  Widget build(BuildContext context) {
    final path = folder ?? (Platform.isWindows ? r'C:\path\to\page' : 'path/to/page');
    final serve = Platform.isWindows ? 'cd /d "$path" && py -m http.server 8000' : 'cd "$path" && python3 -m http.server 8000';
    const gap = SizedBox(height: 20);
    return AppDialog(
      title: Text('Publishing a Page'.tr),
      content: SizedBox(
        width: dialogWidth(context, 440),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          const ExportHeading('On This Computer'),
          _Text('A browser won’t open a page from disk: double-clicking index.html shows nothing. Serve the folder instead.'),
          if (folder case final folder?) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(onPressed: () => WebPreview.open(folder), child: Text('Open in Browser'.tr)),
            ),
            const SizedBox(height: 10),
            _Text('Curator serves it while it’s open. Or, in a terminal:'),
          ] else
            _Text('After exporting, Open in Browser does it for you. Or, in a terminal:'),
          const SizedBox(height: 8),
          _Command(serve),
          const SizedBox(height: 8),
          _Text('Then open localhost:8000. Safari may not play the recording from this server; Chrome and Firefox will.'),
          gap,
          const ExportHeading('Online'),
          _Text('Upload the whole folder, index.html with score beside it, to any web host. It works at a site’s top or in a folder of it.'),
          const SizedBox(height: 10),
          _Host('GitHub Pages', 'Add the files to a repository, then Settings ▸ Pages ▸ Deploy from a branch.',
              'https://docs.github.com/pages/getting-started-with-github-pages/creating-a-github-pages-site'),
          _Host('Netlify', 'Drag the folder onto Netlify Drop.', 'https://app.netlify.com/drop'),
          _Host('Your own server', 'Copy the folder into the site, as you’d copy any file to it.', null),
          const SizedBox(height: 10),
          _Text('Installed fonts go with the page: publish it only where their licenses allow.'),
          const SizedBox(height: 10),
          _Text('To change it, export again into the same folder and upload it again.'),
        ]),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text('Done'.tr))],
    );
  }
}

class _Text extends StatelessWidget {
  const _Text(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text.tr, style: TextStyle(fontSize: 13.5, height: 1.4, color: context.colors.text));
}

/// A command to type in a terminal, with a button that copies it.
class _Command extends StatelessWidget {
  const _Command(this.command);
  final String command;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(color: colors.line.withValues(alpha: 0.35), borderRadius: AppStyle.of(context).radius(7)),
      child: Row(children: [
        Expanded(
          child: SelectableText(command,
              style: TextStyle(fontSize: 12.5, fontFamily: 'Menlo', fontFamilyFallback: const ['Consolas', 'monospace'], color: colors.text)),
        ),
        Tip(
          message: 'Copy',
          child: IconButton(
            icon: Icon(AppIcon.copy.of(context), size: 16, color: colors.textMuted),
            onPressed: () => Clipboard.setData(ClipboardData(text: command)),
          ),
        ),
      ]),
    );
  }
}

/// A place to put a page: its name, how, and a link to its own help.
class _Host extends StatelessWidget {
  const _Host(this.name, this.how, this.url);
  final String name, how;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 120, child: Text(name.tr, style: TextStyle(fontSize: 13.5, height: 1.4, fontWeight: FontWeight.w600, color: colors.text))),
        Expanded(child: _Text(how)),
        if (url case final url?)
          Tip(
            message: 'Open in the browser',
            child: IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(AppIcon.popOut.of(context), size: 14, color: colors.textMuted),
              onPressed: () => openInBrowser(url),
            ),
          )
        else
          const SizedBox(width: 40),
      ]),
    );
  }
}
