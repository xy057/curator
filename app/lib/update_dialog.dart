// The update window: a newer release's version, what its description on GitHub says is new, and
// its download. Opened by Settings ▸ About ▸ Updates' Update… and the launch notice's.
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'app_colors.dart';
import 'dialog_kit.dart';
import 'export_dialog.dart' show revealInFileManager, revealLabel;
import 'file_names.dart';
import 'l10n/l10n.dart';
import 'markdown_text.dart';
import 'ui_kit.dart';
import 'updater.dart';

/// The update window for [release]: its notes on [groupColor] (Settings' group fill), then what
/// [updater] is doing with it: Download, how far that has got, Show in Finder.
Future<void> showUpdateDialog(BuildContext context,
        {required Updater updater, required Release release, required Color Function(BuildContext) groupColor}) =>
    showAppDialog<void>(context: context, builder: (_) => _UpdateDialog(updater, release, groupColor));

/// Where the updates stand, in a line: About's Updates row, the update window's foot.
String updateHelp(UpdateStatus status) => switch (status) {
      UpdateIdle() => 'From GitHub.'.tr,
      UpdateChecking() => 'Checking…'.tr,
      UpToDate() => 'Curator is up to date! ☆'.tr,
      UpdateAvailable(:final release) when release.download == null =>
        'Curator {version} is out, but not for this system yet.'.fill({'version': release.version}),
      UpdateAvailable(:final release) => 'Curator {version} is available! ☆'.fill({'version': release.version}),
      UpdateDownloading(:final release) => 'Downloading {version}…'.fill({'version': release.version}),
      UpdateDownloaded(:final path) => '${'Saved “{name}”.'.fill({'name': fileNameOf(path)})} '
          '${(Platform.isWindows ? 'Close Curator, then replace its folder with the unzipped one.' : 'Unzip it and replace this app with it.').tr}',
      UpdateFailed(:final message) => message.tr,
    };

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog(this.updater, this.release, this.groupColor);
  final Updater updater;
  final Release release;
  final Color Function(BuildContext) groupColor;

  /// `2026-11-13`, in this computer's time.
  static String _day(DateTime time) {
    final t = time.toLocal();
    return '${t.year}-${'${t.month}'.padLeft(2, '0')}-${'${t.day}'.padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = AppStyle.of(context);
    final size = MediaQuery.sizeOf(context);
    final muted = TextStyle(fontSize: 12.5, color: colors.textMuted);
    final have = 'You have {version}'.fill({'version': '$appVersion ($appBuild)'});
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        // What the updater is doing with this release: another's download isn't this window's.
        final status = switch (updater.status) {
          UpdateDownloading(release: final r) || UpdateDownloaded(release: final r) || UpdateFailed(release: final r?)
              when r.version == release.version =>
            updater.status,
          _ => UpdateAvailable(release),
        };
        final download = Text('Download {version}'.fill({'version': release.version}));
        final page = Text('Open Release Page'.tr);
        final Widget action = switch (status) {
          UpdateDownloading() => FilledButton(onPressed: null, child: download),
          UpdateDownloaded(:final path) => FilledButton(onPressed: () => revealInFileManager(path), child: Text(revealLabel)),
          UpdateFailed() => FilledButton(onPressed: () => updater.download(release), child: Text('Try Again'.tr)),
          _ when release.download == null => FilledButton(onPressed: () => openInBrowser(release.pageUrl), child: page),
          _ => FilledButton(onPressed: () => updater.download(release), child: download),
        };
        return AppDialog(
          title: Row(children: [
            Flexible(child: Text('Curator ${release.version}', overflow: TextOverflow.ellipsis)),
            if (release.prerelease) ...[const SizedBox(width: 10), _Tag('Pre-release'.tr)],
          ]),
          content: SizedBox(
            // As wide as a dialog goes, less its padding; the notes as tall as there's room.
            width: (size.width - 64 - (style.isCarbon ? 32 : 48)).clamp(420, 620),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(release.published == null ? have : '${_day(release.published!)}  ·  $have', style: muted),
              const SizedBox(height: 10),
              SizedBox(
                height: (size.height - 320).clamp(160, 400),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: groupColor(context), borderRadius: style.radius(10)),
                  child: release.notes.isEmpty
                      ? Center(child: Text('No release notes.'.tr, style: TextStyle(fontSize: 13, color: colors.textMuted)))
                      : SelectionArea(
                          child: SingleChildScrollView(
                            primary: false,
                            padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
                            child: MarkdownText(release.notes, onLink: (link) => openInBrowser('$link')),
                          ),
                        ),
                ),
              ),
              if (status is! UpdateAvailable) ...[
                const SizedBox(height: 12),
                if (status case UpdateDownloading(:final progress)) ...[
                  LinearProgressIndicator(value: progress, borderRadius: style.radius(2)),
                  const SizedBox(height: 8),
                ],
                Text(
                  updateHelp(status),
                  style: muted.copyWith(height: 1.35, color: status is UpdateFailed ? Theme.of(context).colorScheme.error : null),
                ),
              ],
            ]),
          ),
          leading: [if (release.download != null) TextButton(onPressed: () => openInBrowser(release.pageUrl), child: page)],
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text('Close'.tr)),
            action,
          ],
        );
      },
    );
  }
}

/// A small rounded label in the accent, beside the window's title: Pre-release.
class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = Theme.of(context).brightness == Brightness.dark ? colors.accent : colors.accentStrong;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)), // a tag: a pill in Carbon too
      child: Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, height: 1.2, letterSpacing: 0, color: color)),
    );
  }
}
