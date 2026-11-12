import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'dialog_kit.dart';
import 'downloader.dart';
import 'l10n/l10n.dart';
import 'lilypond.dart';
import 'ui_kit.dart';

/// Engraves [source] with LilyPond in a dialog saying so, Cancel stopping it. Where LilyPond isn't
/// here yet, the dialog first offers to download it (as Settings ▸ Download Hub does), and does
/// once the user agrees. Null when cancelled; throws what running LilyPond threw.
Future<LilyPondRun?> engraveWithLilyPond(BuildContext context, LilySource source) async {
  final outcome = await showAppDialog<_Outcome>(
      context: context, barrierDismissible: false, builder: (_) => LilyPondDialog(source: source));
  if (outcome?.error case final error?) Error.throwWithStackTrace(error, outcome!.stack ?? StackTrace.current);
  return outcome?.run;
}

typedef _Outcome = ({LilyPondRun? run, Object? error, StackTrace? stack});

/// [engraveWithLilyPond]'s dialog.
@visibleForTesting
class LilyPondDialog extends StatefulWidget {
  const LilyPondDialog({super.key, required this.source});
  final LilySource source;

  @override
  State<LilyPondDialog> createState() => _LilyPondDialogState();
}

class _LilyPondDialogState extends State<LilyPondDialog> {
  final _installer = LilyPondInstaller.instance;

  /// Whether this dialog started the download: Cancel stops it then (not one Settings started).
  bool _downloading = false;

  /// The engraving under way, once LilyPond is here.
  DownloadCancel? _engraving;

  @override
  void initState() {
    super.initState();
    _installer.addListener(_installed);
    if (LilyPond.installed) _engrave();
  }

  @override
  void dispose() {
    _installer.removeListener(_installed);
    super.dispose();
  }

  void _installed() {
    if (!mounted) return;
    if (_engraving == null && !_installer.busy && LilyPond.installed) {
      _engrave();
    } else {
      setState(() {});
    }
  }

  void _download() {
    setState(() => _downloading = true);
    _installer.install();
  }

  Future<void> _engrave() async {
    final cancel = _engraving = DownloadCancel();
    if (mounted) setState(() {});
    _Outcome outcome;
    try {
      outcome = (run: await LilyPond.engrave(widget.source, cancel: cancel), error: null, stack: null);
    } catch (e, stack) {
      outcome = (run: null, error: e, stack: stack);
    }
    if (mounted && !cancel.cancelled) Navigator.pop(context, outcome);
  }

  void _cancel() {
    _engraving?.cancel();
    if (_downloading && _installer.busy) _installer.cancel();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.source.name, package = LilyPond.package;
    int mb(int bytes) => (bytes / 1e6).round();
    final cancel = OutlinedButton(onPressed: _cancel, child: Text('Cancel'.tr));
    Widget bar(double? value) => LinearProgressIndicator(value: value, minHeight: 4, borderRadius: AppStyle.of(context).radius(2));
    Widget body(List<Widget> children) => SizedBox(
          width: dialogWidth(context, 380),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, spacing: 12, children: children),
        );
    final muted = TextStyle(color: context.colors.textMuted);
    if (_engraving != null) {
      return AppDialog(
        title: Text('Engraving “{name}”'.fill({'name': name})),
        content: body([const SizedBox(height: 4), bar(null)]),
        actions: [cancel],
        onEscape: _cancel,
      );
    }
    final failed = _installer.stage == LilyPondStage.failed;
    return AppDialog(
      title: Text('Download LilyPond?'.tr),
      content: body(switch (_installer.stage) {
        _ when package == null => [Text('Not available for this computer.'.tr)],
        LilyPondStage.downloading => [
            bar(_installer.total == 0 ? null : _installer.received / _installer.total),
            Text('Downloading… {received} of {total} MB'.fill({'received': mb(_installer.received), 'total': mb(package.size)}),
                style: muted),
          ],
        LilyPondStage.unpacking => [bar(null), Text('Installing…'.tr, style: muted)],
        _ => [
            Text('“{name}” is engraved with LilyPond ({size} MB).'.fill({'name': name, 'size': mb(package.size)})),
            if (failed) Text(describeLilyPondFailure(_installer.failure), style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
      }),
      actions: [
        cancel,
        if (package != null && !_installer.busy)
          FilledButton(onPressed: _download, child: Text((failed ? 'Try Again' : 'Download').tr)),
      ],
      onEscape: _cancel,
    );
  }
}

/// The system's monospace font, as the app shows code: LilyPond's source, what it said.
const monospace = TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'monospace']);

/// [problem] as LilyPond says it: `score.ly:12:5: syntax error…`.
String describeLilyProblem(LilyProblem problem) => switch (problem) {
      LilyProblem(:final file?, :final line?, :final column?) => '$file:$line:$column: ${problem.message}',
      _ => problem.message,
    };

/// The errors in what LilyPond said ([run]), as it says them: what it left out of the score.
List<String> lilyPondErrors(LilyPondRun run) => [
      for (final p in run.problems)
        if (p.error) describeLilyProblem(p),
    ];

/// LilyPond engraved nothing of [name] ([run]): its errors, or the end of what it said. With
/// [canEdit], Edit… is offered beside OK: true when it is chosen.
Future<bool> showLilyPondErrors(BuildContext context, String name, LilyPondRun run, {bool canEdit = false}) async {
  final errors = lilyPondErrors(run);
  final lines = errors.isNotEmpty ? errors : run.log.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
  final text = lines.length > 40 ? lines.sublist(lines.length - 40).join('\n') : lines.join('\n');
  return await showAppDialog<bool>(
        context: context,
        builder: (context) => AppDialog(
          title: Text('LilyPond couldn’t engrave “{name}”'.fill({'name': name})),
          content: SizedBox(
            width: dialogWidth(context, 560),
            child:
                text.isEmpty ? Text('Nothing to engrave.'.tr) : SelectableText(text, style: monospace.copyWith(fontSize: 12.5, height: 1.45)),
          ),
          actions: [
            if (canEdit) OutlinedButton(onPressed: () => Navigator.pop(context, true), child: Text('Edit…'.tr)),
            FilledButton(onPressed: () => Navigator.pop(context), child: Text('OK'.tr)),
          ],
        ),
      ) ??
      false;
}
