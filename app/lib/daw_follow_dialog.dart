import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart' show DawDocument, DawSource;

import 'app_colors.dart';
import 'daw_link.dart';
import 'dialog_kit.dart';
import 'editor_controller.dart';
import 'error_text.dart';
import 'l10n/l10n.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';

/// The Audio tab's Sync menu ▸ Follow DAW…: a recording in a DAW where Curator Link is (see
/// docs/daw-link.md), the DAW's bar the score's bar 1 is at, whether to take the recording itself
/// (written out by the plug-in, then loaded as the focus's) and whether the playhead follows the
/// DAW's; then the sync follows the DAW's tempo there ([DawEditing.follow]).
Future<void> showDawFollowDialog(BuildContext context, EditorController c) async {
  final link = DawLink.shared;
  final choice = await showAppDialog<_Choice>(context: context, builder: (_) => _FollowDialog(link: link));
  if (choice == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) => messenger.showSnackBar(SnackBar(content: Text(text)));
  if (choice.recording) {
    final done = ValueNotifier<double>(0);
    final dialog = showAppDialog<void>(context: context, barrierDismissible: false, builder: (_) => _Fetching(done: done));
    String? path;
    try {
      path = await link.recording(choice.session, choice.document.id, choice.source.id, progress: (d) => done.value = d);
    } on DawLinkException catch (e) {
      say('Couldn’t get the recording from the DAW. {error}'.fill({'error': _reason(e.reason)}));
    }
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    await dialog;
    done.dispose();
    if (path == null) return;
    try {
      await c.loadAudio(path);
    } catch (e) {
      say('Couldn’t load the recording. {error}'.fill({'error': describeError(e)}));
      return;
    }
  }
  final taken = c.daw.follow(link, (document: choice.document.id, source: choice.source.id, region: null, bar: choice.bar, transport: choice.playhead));
  if (!taken) say('The DAW gives no tempo for this recording yet.'.tr);
}

/// What the plug-in said went wrong, in words.
String _reason(String reason) => switch (reason) {
      'too long' => 'It is too long.'.tr,
      'out of memory' => 'The DAW is out of memory.'.tr,
      'unreadable' => 'The DAW doesn’t let it be read yet.'.tr,
      'gone' => 'It is no longer in the DAW.'.tr,
      'disconnected' => 'The DAW disconnected.'.tr,
      _ => 'The file couldn’t be written.'.tr,
    };

typedef _Choice = ({DawSession session, DawDocument document, DawSource source, int bar, bool recording, bool playhead});

class _FollowDialog extends StatefulWidget {
  const _FollowDialog({required this.link});
  final DawLink link;

  @override
  State<_FollowDialog> createState() => _FollowDialogState();
}

class _FollowDialogState extends State<_FollowDialog> {
  /// The recording chosen: its document's id and its own.
  (String, String)? _key;
  final _bar = TextEditingController(text: '1');
  bool _recording = true, _playhead = true;

  @override
  void dispose() {
    _bar.dispose();
    super.dispose();
  }

  /// Every recording placed in a song, in every DAW connected.
  List<({DawSession session, DawDocument document, DawSource source})> get _recordings => [
        for (final (session, document) in widget.link.documents)
          for (final source in document.sources)
            if (document.regionsOf(source.id).isNotEmpty) (session: session, document: document, source: source),
      ];

  int? get _barValue => switch (int.tryParse(_bar.text.trim())) { final n? when n >= 1 && n <= 9999 => n, _ => null };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.link,
        builder: (context, _) {
          final recordings = _recordings;
          final chosen = recordings.where((r) => (r.document.id, r.source.id) == _key).firstOrNull ?? recordings.firstOrNull;
          if (chosen == null) {
            final muted = TextStyle(fontSize: 12, color: context.colors.textMuted);
            return AppDialog(
              title: Text('Follow DAW'.tr),
              content: SizedBox(
                width: dialogWidth(context, 360),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.link.listening ? 'No DAW connected.'.tr : 'Curator isn’t listening for Curator Link.'.tr),
                  const SizedBox(height: 6),
                  Text(widget.link.listening ? 'Put Curator Link on a track in your DAW.'.tr : 'Turn it on in Settings ▸ General.'.tr, style: muted),
                ]),
              ),
              actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text('OK'.tr))],
            );
          }
          final bar = _barValue;
          final hosts = {for (final r in recordings) r.session.host}.length;
          String label(({DawSession session, DawDocument document, DawSource source}) r) {
            final name = r.source.name.isEmpty ? 'Recording'.tr : r.source.name;
            return hosts > 1 && r.session.host.isNotEmpty ? '$name · ${r.session.host}' : name;
          }

          return AppDialog(
            title: Text('Follow DAW'.tr),
            content: SizedBox(
              width: dialogWidth(context, 360),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                AppDropdown<(String, String)>(
                  value: (chosen.document.id, chosen.source.id),
                  isExpanded: true,
                  label: 'Recording',
                  items: [
                    for (final r in recordings) DropdownMenuItem(value: (r.document.id, r.source.id), child: Text(label(r), overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (k) => setState(() => _key = k),
                ),
                SizedBox(height: dialogGap(context)),
                AppTextField(
                  controller: _bar,
                  label: 'DAW bar of the score’s bar 1',
                  bad: bar == null,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => setState(() {}),
                ),
                SizedBox(height: dialogGap(context)),
                AppCheckRow(value: _recording, onChanged: (v) => setState(() => _recording = v ?? false), label: 'Use this recording'),
                AppCheckRow(value: _playhead, onChanged: (v) => setState(() => _playhead = v ?? false), label: 'Follow the DAW’s playhead'),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
              FilledButton(
                onPressed: bar == null
                    ? null
                    : () => Navigator.pop<_Choice>(context, (
                          session: chosen.session,
                          document: chosen.document,
                          source: chosen.source,
                          bar: bar,
                          recording: _recording,
                          playhead: _playhead,
                        )),
                child: Text('Follow'.tr),
              ),
            ],
          );
        },
      );
}

/// While the DAW writes the recording out: how far it has got.
class _Fetching extends StatelessWidget {
  const _Fetching({required this.done});
  final ValueNotifier<double> done;

  @override
  Widget build(BuildContext context) => AppDialog(
        title: Text('Getting the Recording'.tr),
        content: SizedBox(
          width: dialogWidth(context, 320),
          child: ValueListenableBuilder<double>(
            valueListenable: done,
            builder: (context, d, _) => LinearProgressIndicator(value: d > 0 ? d : null),
          ),
        ),
        actions: const [],
      );
}
