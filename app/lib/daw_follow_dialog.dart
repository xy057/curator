import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart' show DawDocument, DawSource;

import 'app_colors.dart';
import 'daw_link.dart';
import 'dialog_kit.dart';
import 'editor_controller.dart';
import 'project_state.dart' show TakeDaw;
import 'error_text.dart';
import 'l10n/l10n.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';

/// File ▸ Attacca ▸ Follow DAW…: a recording in a DAW where Attacca is (see
/// docs/daw-link.md), the DAW's bar the score's bar 1 is at, whether to take the recording itself
/// (written out by the plug-in, then loaded as the focus's) and whether the playhead follows the
/// DAW's; then the sync follows the DAW's tempo there ([DawEditing.follow]). A project takes one
/// Attacca recording, for now: once it has one ([EditorController.attaccaTake]), only that one
/// is offered, and taken again it goes back into its take.
Future<void> showDawFollowDialog(BuildContext context, EditorController c) async {
  final link = DawLink.shared;
  final choice = await showAppDialog<_Choice>(context: context, builder: (_) => _FollowDialog(link: link, bound: c.attaccaTake?.daw));
  if (choice == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) => messenger.showSnackBar(SnackBar(content: Text(text)));
  if (choice.recording) {
    final done = ValueNotifier<double>(0);
    // With an Attacca Capturer in the DAW, the mix as it plays there over the recording's span;
    // else the recording itself, as Attacca reads it.
    final capturer = choice.session.capturers.firstOrNull;
    final region = choice.document.regionsOf(choice.source.id).firstOrNull;
    final dialog = showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _Fetching(
        done: done,
        capturing: capturer != null,
        onCancel: capturer == null ? null : () => link.cancelCapture(choice.session, choice.document.id, capturer),
      ),
    );
    String? path;
    try {
      path = capturer != null && region != null
          ? await link.capture(choice.session, choice.document.id, capturer,
              from: region.songAt(0),
              length: choice.source.seconds,
              name: choice.source.name.isEmpty ? 'Recording'.tr : choice.source.name,
              progress: (d) => done.value = d)
          : await link.recording(choice.session, choice.document.id, choice.source.id, progress: (d) => done.value = d);
    } on DawLinkException catch (e) {
      if (e.reason != 'cancelled') say('Couldn’t get the recording from the DAW. {error}'.fill({'error': dawProblem(e.reason)}));
    }
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    await dialog;
    done.dispose();
    if (path == null) return;
    try {
      final source = choice.source;
      await c.loadAudio(path, daw: (host: choice.session.host, source: source.id, name: source.name));
    } catch (e) {
      say('Couldn’t load the recording. {error}'.fill({'error': describeError(e)}));
      return;
    }
  }
  final taken = c.daw.follow(link, (document: choice.document.id, source: choice.source.id, region: null, bar: choice.bar, transport: choice.playhead));
  if (!taken) say('The DAW gives no tempo for this recording yet.'.tr);
}

/// What to do about [session]'s outdated Attacca ([DawSession.outdated]): reopen the DAW when
/// the newer one is installed already (a DAW keeps the one it loaded until then), else update it.
String attaccaOutdated(DawSession session) {
  final reopen = (AttaccaPlugIns.installedBuild() ?? 0) > session.build;
  if (session.host.isEmpty) return reopen ? 'Attacca in the DAW is outdated: reopen the DAW.'.tr : 'Attacca in the DAW is outdated: update it in Settings ▸ General.'.tr;
  final daw = {'daw': session.host};
  return reopen ? 'Attacca in {daw} is outdated: reopen {daw}.'.fill(daw) : 'Attacca in {daw} is outdated: update it in Settings ▸ General.'.fill(daw);
}

/// What the plug-in said went wrong ([DawLinkException.reason]), in words.
String dawProblem(String reason) => switch (reason) {
      'too long' => 'It is too long.'.tr,
      'out of memory' => 'The DAW is out of memory.'.tr,
      'unreadable' => 'The DAW doesn’t let it be read yet.'.tr,
      'empty' => 'Nothing plays there.'.tr,
      'gone' => 'It is no longer in the DAW.'.tr,
      'disconnected' => 'The DAW disconnected.'.tr,
      'capturer' => 'Attacca Capturer captures in its place.'.tr,
      _ => 'The file couldn’t be written.'.tr,
    };

typedef _Choice = ({DawSession session, DawDocument document, DawSource source, int bar, bool recording, bool playhead});

class _FollowDialog extends StatefulWidget {
  const _FollowDialog({required this.link, this.bound});
  final DawLink link;

  /// The project's Attacca recording, if it has one: the only one offered.
  final TakeDaw? bound;

  @override
  State<_FollowDialog> createState() => _FollowDialogState();
}

class _FollowDialogState extends State<_FollowDialog> {
  /// The recording chosen: its document's id and its own.
  (String, String)? _key;
  final _bar = TextEditingController(text: '1');
  bool _recording = true, _playhead = true;

  /// Whether DAWs Attacca doesn't support are offered too ([DawSession.supported]): the hidden
  /// Follow Anyway, shown while ⌥ is held ([_option]).
  bool _anyDaw = false, _option = HardwareKeyboard.instance.isAltPressed;

  bool _keys(KeyEvent _) {
    final option = HardwareKeyboard.instance.isAltPressed;
    if (option != _option && mounted) setState(() => _option = option);
    return false;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_keys);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_keys);
    _bar.dispose();
    super.dispose();
  }

  /// Every recording placed in a song, in every DAW connected (that Attacca supports, unless
  /// [_anyDaw]).
  List<({DawSession session, DawDocument document, DawSource source})> get _recordings => [
        for (final (session, document) in widget.link.documents)
          if (_anyDaw || session.supported)
            for (final source in document.sources)
              if (document.regionsOf(source.id).isNotEmpty && (widget.bound == null || widget.bound!.source == source.id))
                (session: session, document: document, source: source),
      ];

  int? get _barValue => switch (int.tryParse(_bar.text.trim())) { final n? when n >= 1 && n <= 9999 => n, _ => null };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.link,
        builder: (context, _) {
          final recordings = _recordings;
          final chosen = recordings.where((r) => (r.document.id, r.source.id) == _key).firstOrNull ?? recordings.firstOrNull;
          final muted = TextStyle(fontSize: 12, color: context.colors.textMuted);
          // A DAW whose Attacca is older than Curator: said, whatever else is.
          final outdated = [
            for (final s in widget.link.sessions)
              if (s.outdated) Padding(padding: const EdgeInsets.only(top: 6), child: Text(attaccaOutdated(s), style: muted)),
          ];
          // Only DAWs Attacca doesn't support are here: said so; ⌥ shows Follow Anyway.
          final unsupported = {for (final s in widget.link.sessions) if (!s.supported && s.documents.isNotEmpty) s.host};
          if (chosen == null && !_anyDaw && unsupported.isNotEmpty) {
            final name = unsupported.where((h) => h.isNotEmpty).join(', ');
            return AppDialog(
              title: Text('Follow DAW'.tr),
              content: SizedBox(
                width: dialogWidth(context, 360),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name.isEmpty ? 'This DAW isn’t supported by Attacca.'.tr : '{daw} isn’t supported by Attacca.'.fill({'daw': name})),
                  const SizedBox(height: 6),
                  Text('Attacca works in {daws}.'.fill({'daws': DawLink.supportedDaws.join(', ')}), style: muted),
                ]),
              ),
              actions: [
                if (_option) TextButton(onPressed: () => setState(() => _anyDaw = true), child: Text('Follow Anyway'.tr)),
                FilledButton(onPressed: () => Navigator.pop(context), child: Text('OK'.tr)),
              ],
            );
          }
          final bound = widget.bound;
          if (chosen == null && bound != null && widget.link.sessions.isNotEmpty) {
            // Its own Attacca recording isn't in the DAWs connected: no other is offered.
            return AppDialog(
              title: Text('Follow DAW'.tr),
              content: SizedBox(
                width: dialogWidth(context, 360),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('This project’s Attacca recording isn’t open in a DAW.'.tr),
                  const SizedBox(height: 6),
                  Text([bound.name, if (bound.host.isNotEmpty) bound.host].join(' · '), style: muted),
                ]),
              ),
              actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text('OK'.tr))],
            );
          }
          if (chosen == null) {
            // Connected, yet no recording: Attacca is on an insert only (or on no track) there.
            final connected = {for (final s in widget.link.sessions) if (s.host.isNotEmpty) s.host}.join(', ');
            final (said, hint) = !widget.link.listening
                ? ('Curator isn’t listening for Attacca.'.tr, 'Turn it on in Settings ▸ General.'.tr)
                : widget.link.sessions.isEmpty
                    ? ('No DAW connected.'.tr, 'Put Attacca on a track in your DAW.'.tr)
                    : (connected.isEmpty ? 'Attacca isn’t on a recording in the DAW.'.tr : 'Attacca isn’t on a recording in {daw}.'.fill({'daw': connected}),
                        'Add it to a track as an ARA extension, not as an insert.'.tr);
            return AppDialog(
              title: Text('Follow DAW'.tr),
              content: SizedBox(
                width: dialogWidth(context, 360),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(said),
                  const SizedBox(height: 6),
                  Text(hint, style: muted),
                  ...outdated,
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
                  onChanged: widget.bound != null ? null : (k) => setState(() => _key = k),
                ),
                if (widget.bound != null) ...[
                  const SizedBox(height: 4),
                  Text('One Attacca recording per project.'.tr, style: muted),
                ],
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
                // Taken as the mix, through Attacca Capturer, as the DAW plays it.
                if (_recording && chosen.session.capturers.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 28, bottom: 4),
                    child: Text('Captured by Attacca Capturer as the DAW plays it.'.tr, style: muted),
                  ),
                AppCheckRow(value: _playhead, onChanged: (v) => setState(() => _playhead = v ?? false), label: 'Follow the DAW’s playhead'),
                ...outdated,
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

/// While the DAW writes the recording out, or ([capturing]) Attacca Capturer hears it as the
/// DAW plays it: how far it has got; a capture can be cancelled.
class _Fetching extends StatelessWidget {
  const _Fetching({required this.done, this.capturing = false, this.onCancel});
  final ValueNotifier<double> done;
  final bool capturing;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) => AppDialog(
        title: Text(capturing ? 'Capturing the Recording'.tr : 'Getting the Recording'.tr),
        content: SizedBox(
          width: dialogWidth(context, 320),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            ValueListenableBuilder<double>(
              valueListenable: done,
              builder: (context, d, _) => LinearProgressIndicator(value: d > 0 ? d : null),
            ),
            if (capturing) ...[
              const SizedBox(height: 10),
              Text('Play it in the DAW if it doesn’t start.'.tr, style: TextStyle(fontSize: 12, color: context.colors.textMuted)),
            ],
          ]),
        ),
        actions: [if (onCancel case final cancel?) TextButton(onPressed: cancel, child: Text('Cancel'.tr))],
      );
}
