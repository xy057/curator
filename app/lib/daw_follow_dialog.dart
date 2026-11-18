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

/// File ▸ Attacca ▸ Connect Attacca…: a recording in a DAW where Attacca is (see
/// docs/daw-link.md), the DAW's bar the score's bar 1 is at, whether to take the recording itself
/// (written out by the plug-in through ARA, an Attacca Capturer or not; Record from DAW… takes
/// the mix instead: [recordFromDaw]) and whether the playhead follows the
/// DAW's; then the sync follows the DAW's tempo there ([DawEditing.follow]). A project takes one
/// Attacca recording, for now: once it has one ([EditorController.attaccaTake]), only that one
/// is offered, and taken again it goes back into its take.
Future<void> showDawFollowDialog(BuildContext context, EditorController c) async {
  final link = DawLink.shared;
  final choice = await showAppDialog<_Choice>(context: context, builder: (_) => _FollowDialog(link: link, bound: c.attaccaTake?.daw));
  if (choice == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) => messenger.showSnackBar(SnackBar(content: Text(text)));
  // The recording itself, as Attacca (ARA) reads it.
  if (choice.recording &&
      !await _take(context, c, choice.session, choice.source,
          (progress) => link.recording(choice.session, choice.document.id, choice.source.id, progress: progress))) {
    return;
  }
  final taken = c.daw.follow(link, (document: choice.document.id, source: choice.source.id, region: null, bar: choice.bar, transport: choice.playhead));
  if (!taken) say('The DAW gives no tempo for this recording yet.'.tr);
}

/// File ▸ Attacca ▸ Record from DAW…: the recording followed as the DAW plays it, its mix over the
/// recording's span captured by Attacca Capturer (the DAW asked to play it), loaded in place of
/// the project's Attacca take as an ordinary recording (no longer the DAW's: the mix, not the
/// recording Attacca reads).
Future<void> recordFromDaw(BuildContext context, EditorController c) async {
  final link = DawLink.shared;
  final follow = c.daw.following, found = c.daw.document;
  if (follow == null || found == null) return;
  final (session, document) = found;
  final source = document.sources.where((s) => s.id == follow.source).firstOrNull;
  // The region followed: the DAW plays only it of the recording.
  final region = c.daw.region;
  // The one linked to the DAW's Attacca, in its window.
  final capturer = link.linkedCapturerOf(session);
  if (source == null || region == null || capturer == null) {
    await showAppDialog<void>(
      context: context,
      builder: (context) => AppDialog(
        title: Text('Record from DAW'.tr),
        content: SizedBox(
          width: dialogWidth(context, 360),
          child: Text(capturer != null
              ? 'The recording followed isn’t in the DAW.'.tr
              : link.capturersOf(session).isEmpty
                  ? 'Put Attacca Capturer on the DAW’s output.'.tr
                  : 'Choose the Capturer in Attacca’s window in the DAW.'.tr),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text('OK'.tr))],
      ),
    );
    return;
  }
  await _take(
    context,
    c,
    session,
    source,
    (progress) => link.capture(session, document.id, capturer,
        from: region.songAt(0),
        length: source.seconds,
        // The whole recording's length, lined up with it; only the region played must be heard.
        played: (start: region.start, end: region.start + region.length),
        name: source.name.isEmpty ? 'Recording'.tr : source.name,
        progress: progress),
    onCancel: () => link.cancelCapture(document.id, capturer),
  );
}

/// [source] of [session] fetched as a file by [fetch] while a dialog shows how far it has got,
/// then loaded into the project's Attacca take; false when it couldn't be. A capture ([onCancel]
/// given, which cancels it) is the DAW's mix recorded: the take becomes an ordinary recording,
/// no longer the DAW's.
Future<bool> _take(BuildContext context, EditorController c, DawSession session, DawSource source,
    Future<String> Function(void Function(double) progress) fetch, {VoidCallback? onCancel}) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) => messenger.showSnackBar(SnackBar(content: Text(text)));
  // While the DAW writes the recording out, or Attacca Capturer hears it as the DAW plays it.
  final capturing = onCancel != null;
  String? path;
  try {
    path = await withProgress(context, capturing ? 'Capturing the Recording'.tr : 'Getting the Recording'.tr, fetch,
        note: capturing ? 'Play it in the DAW if it doesn’t start.'.tr : null, onCancel: onCancel);
  } on DawLinkException catch (e) {
    if (e.reason != 'cancelled') say('Couldn’t get the recording from the DAW. {error}'.fill({'error': dawProblem(e.reason)}));
  }
  if (path == null) return false;
  try {
    await c.loadAudio(path, daw: capturing ? null : (host: session.host, source: source.id, name: source.name), intoAttacca: true);
  } catch (e) {
    say('Couldn’t load the recording. {error}'.fill({'error': describeError(e)}));
    return false;
  }
  return true;
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
  /// Connect Anyway, shown while ⌥ is held ([_option]).
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
            for (final s in {for (final s in widget.link.sessions) if (s.outdated) s.host: s}.values)
              Padding(padding: const EdgeInsets.only(top: 6), child: Text(attaccaOutdated(s), style: muted)),
          ];
          // Only DAWs Attacca doesn't support are here: said so; ⌥ shows Connect Anyway.
          final unsupported = {for (final s in widget.link.sessions) if (!s.supported && s.documents.isNotEmpty) s.host};
          if (chosen == null && !_anyDaw && unsupported.isNotEmpty) {
            final name = unsupported.where((h) => h.isNotEmpty).join(', ');
            return AppDialog(
              title: Text('Connect Attacca'.tr),
              content: SizedBox(
                width: dialogWidth(context, 360),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name.isEmpty ? 'This DAW isn’t supported by Attacca.'.tr : '{daw} isn’t supported by Attacca.'.fill({'daw': name})),
                  const SizedBox(height: 6),
                  Text('Attacca works in {daws}.'.fill({'daws': DawLink.supportedDaws.join(', ')}), style: muted),
                ]),
              ),
              actions: [
                if (_option) TextButton(onPressed: () => setState(() => _anyDaw = true), child: Text('Connect Anyway'.tr)),
                FilledButton(onPressed: () => Navigator.pop(context), child: Text('OK'.tr)),
              ],
            );
          }
          final bound = widget.bound;
          if (chosen == null && bound != null && widget.link.sessions.isNotEmpty) {
            // Its own Attacca recording isn't in the DAWs connected: no other is offered.
            return AppDialog(
              title: Text('Connect Attacca'.tr),
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
              title: Text('Connect Attacca'.tr),
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
            title: Text('Connect Attacca'.tr),
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
                AppCheckRow(value: _recording, onChanged: (v) => setState(() => _recording = v ?? false), label: 'Load ARA Clip'),
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
