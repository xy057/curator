import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart' show DawTrack, ScorePart;

import 'app_colors.dart';
import 'app_icons.dart';
import 'daw_follow_dialog.dart';
import 'daw_link.dart';
import 'dialog_kit.dart';
import 'editor_controller.dart';
import 'error_text.dart';
import 'l10n/l10n.dart';
import 'menu_kit.dart';
import 'project_state.dart';
import 'ui_kit.dart';

/// File ▸ Attacca ▸ Capture Stems… (greyed out for now), while a DAW is followed: the tracks of its song
/// to keep as stems ([StemEditing.capture]), each as the song plays it over the recording
/// followed. All but the recording's own track are picked at first.
Future<void> showStemCaptureDialog(BuildContext context, EditorController c) async {
  final link = DawLink.shared;
  final found = c.daw.document;
  if (found == null) return;
  final document = found.$2, followed = c.daw.region;
  final tracks = [
    for (final t in [...document.tracks]..sort((a, b) => a.order.compareTo(b.order)))
      if (document.regions.any((r) => r.track == t.id)) t,
  ];
  final picked = await showAppDialog<List<DawTrack>>(
      context: context, builder: (_) => _CaptureDialog(tracks: tracks, recordingTrack: followed?.track));
  if (picked == null || picked.isEmpty || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  final failed = await withProgress(context, 'Capturing Stems'.tr, (progress) => c.stems.capture(link, picked, progress: progress));
  final captured = picked.length - failed.length;
  messenger.showSnackBar(SnackBar(
    content: Text([
      if (captured > 0) 'Stems captured: {count}'.fill({'count': captured}),
      for (final MapEntry(key: name, value: e) in failed.entries)
        '{name}: {error}'.fill({'name': name, 'error': e is DawLinkException ? dawProblem(e.reason) : describeError(e)}),
    ].join('\n')),
  ));
}

class _CaptureDialog extends StatefulWidget {
  const _CaptureDialog({required this.tracks, required this.recordingTrack});
  final List<DawTrack> tracks;
  final String? recordingTrack;

  @override
  State<_CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends State<_CaptureDialog> {
  late final _picked = {for (final t in widget.tracks) if (t.id != widget.recordingTrack) t.id};

  @override
  Widget build(BuildContext context) {
    final tracks = widget.tracks;
    return AppDialog(
      title: Text('Capture Stems'.tr),
      content: SizedBox(
        width: dialogWidth(context, 360),
        child: tracks.isEmpty
            ? Text('No tracks with recordings.'.tr)
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    for (final t in tracks)
                      AppCheckRow(
                        value: _picked.contains(t.id),
                        named: true,
                        label: t.name.isEmpty ? 'Track'.tr : t.name,
                        trailing: StemSwatch(color: t.color),
                        onChanged: (v) => setState(() => v == true ? _picked.add(t.id) : _picked.remove(t.id)),
                      ),
                  ]),
                ),
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        FilledButton(
          onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, [for (final t in tracks) if (_picked.contains(t.id)) t]),
          child: Text('Capture'.tr),
        ),
      ],
    );
  }
}

/// A track's or stem's colour (0xAARRGGBB, from the DAW), as a small dot; none, nothing.
class StemSwatch extends StatelessWidget {
  const StemSwatch({super.key, required this.color});
  final int? color;

  @override
  Widget build(BuildContext context) => color == null
      ? const SizedBox.shrink()
      : Container(
          width: 10,
          height: 10,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(color: Color(color!), shape: BoxShape.circle),
        );
}

/// Project Settings ▸ Project Info ▸ Stems ▸ Edit…: each stem, the part of the score it plays,
/// and Remove.
Future<void> showStemsDialog(BuildContext context, EditorController c) =>
    showAppDialog<void>(context: context, builder: (_) => _StemsDialog(c));

class _StemsDialog extends StatelessWidget {
  const _StemsDialog(this.c);
  final EditorController c;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final stems = c.stems.list, parts = c.score?.metadata.parts ?? const [];
          return AppDialog(
            title: Text('Stems'.trIn('audio')),
            content: SizedBox(
              width: dialogWidth(context, 440),
              child: stems.isEmpty
                  ? Text('None.'.tr)
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 420),
                      child: SingleChildScrollView(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          for (final s in stems) _row(context, s, parts),
                        ]),
                      ),
                    ),
            ),
            actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text('Done'.tr))],
          );
        },
      );

  Widget _row(BuildContext context, Stem s, List<ScorePart> parts) {
    final missing = c.stems.fileOf(s.id) == null;
    return SizedBox(
      height: dialogRowHeight(context) + 8,
      child: Row(children: [
        SizedBox(width: 22, child: StemSwatch(color: s.color)),
        Expanded(
          child: Text(s.name, overflow: TextOverflow.ellipsis, style: missing ? TextStyle(color: context.colors.textMuted) : null),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 180,
          child: AppDropdown<String>(
            value: s.part ?? '',
            isExpanded: true,
            dense: true,
            items: [
              DropdownMenuItem(value: '', child: Text('No Part'.tr)),
              for (final p in parts) DropdownMenuItem(value: p.id, child: Text(c.partNameOf(p.id), overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => c.stems.setPart(s.id, v == null || v.isEmpty ? null : v),
          ),
        ),
        const SizedBox(width: 4),
        ToolbarButton(icon: AppIcon.delete.of(context), tooltip: 'Remove'.tr, onPressed: () => c.stems.remove(s.id)),
      ]),
    );
  }
}
