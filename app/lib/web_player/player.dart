import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import '../app_colors.dart' show ScorePaper;
import '../key_bindings.dart';
import '../l10n/l10n.dart';
import '../player_map_paint.dart';
import '../scene_views.dart';
import '../video_frame.dart';
import '../web_page.dart';
import 'page_api.dart';
import 'page_audio.dart';
import 'playing_page.dart';
import 'page_loader.dart';

/// A page: the score scrolling as it is heard, the transport at the foot (hidden while it plays
/// and the pointer rests), and what the export left the viewer to choose, in a side panel. What
/// plays and shows is a [PlayingPage]'s; the page's plugins ([plugins]) are answered by a
/// [PageApi], and what they add (buttons, options, keys, room at the edges) shows here.
class PagePlayer extends StatefulWidget {
  const PagePlayer(this.loaded, {super.key, required this.audioFor, this.plugins});

  final LoadedPage loaded;

  /// The sound of a recording ([WebRecording.audio], beside the page; null: silent).
  final PageAudio Function(String? file) audioFor;

  /// Starts the page's plugins ([WebPage.plugins]) over the api, and gives what tells them of
  /// what happens; null (or giving null): the page runs none.
  final Future<PageListener?> Function(PageApi api)? plugins;

  @override
  State<PagePlayer> createState() => _PagePlayerState();
}

class _PagePlayerState extends State<PagePlayer> with SingleTickerProviderStateMixin {
  late final PlayingPage _c = PlayingPage(widget.loaded, audioFor: widget.audioFor)..addListener(_changed);
  late final PageApi _api = PageApi(_c)
    ..addListener(_changed)
    ..onMessage = _message
    ..onShowOptions = (() => _scaffold.currentState?.openEndDrawer());
  late final Ticker _ticker = createTicker((_) => _c.tick());
  final _scaffold = GlobalKey<ScaffoldState>();

  LoadedPage get _loaded => widget.loaded;
  WebPage get _page => _loaded.page;
  WebRecording get _heard => _c.heard;

  /// Where the frame is in the player's own room (the window less what plugins' panels take).
  Rect _frame = Rect.zero;

  @override
  void initState() {
    super.initState();
    _ticker.start();
    if (widget.plugins case final start? when _page.plugins.isNotEmpty) {
      start(_api).then((listener) {
        if (mounted) _c.listener = listener;
      });
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _api.dispose();
    _c.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  void _message(String text) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));

  /// The frame is at [frame] in the player's room, [scale] of its points a layout point: the
  /// controller is told where that is in the window, once this frame is built (a plugin told
  /// of it may change what is being laid out).
  void _laidOut(Rect frame, double scale) {
    _frame = frame;
    final inWindow = frame.shift(Offset(_api.insets[0], _api.insets[1]));
    if (inWindow == _c.frame && scale == _c.frameScale) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _c.setFrame(inWindow, scale);
    });
  }

  /// A plugin's key first: it wins over the player's own.
  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _api.keys.isEmpty) return KeyEventResult.ignored;
    final id = switch (KeyChord.of(event)) { final chord? => _api.keys[chord], null => null };
    if (id == null) return KeyEventResult.ignored;
    _api.keyed(id);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final brightness = dark ? Brightness.dark : Brightness.light;
    final paper = ScorePaper.paper(brightness), ink = ScorePaper.ink(brightness);
    final choices = _choices(context);
    final [left, top, right, bottom] = _api.insets;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft): _Skip(-5),
        SingleActivator(LogicalKeyboardKey.arrowRight): _Skip(5),
      },
      child: Actions(
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _c.playPause()),
          _Skip: CallbackAction<_Skip>(onInvoke: (s) => _c.seek(_c.time.value + s.seconds)),
        },
        child: Focus(
          autofocus: true,
          onKeyEvent: _key,
          // The room plugins' panels take is left as paper: their elements lie over it.
          child: ColoredBox(
            color: paper,
            child: Padding(
              padding: EdgeInsets.fromLTRB(left, top, right, bottom),
              child: Scaffold(
                key: _scaffold,
                backgroundColor: paper,
                onEndDrawerChanged: (open) => _c.listener?.call('options', {'open': open}),
                endDrawer: choices.isEmpty ? null : Drawer(width: 320, child: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: choices))),
                body: MouseRegion(
                  onHover: (_) => _c.woke(),
                  child: GestureDetector(
                    onTapUp: (tap) {
                      _c.woke();
                      final at = tap.localPosition - _frame.topLeft;
                      if (!_c.clicked(at.dx, at.dy)) _c.playPause();
                    },
                    child: Stack(children: [
                      Positioned.fill(child: _c.shows == PageShows.map ? _playerMap(context) : _score(paper, ink)),
                      Positioned(left: 0, right: 0, bottom: 0, child: _controls(context, choices.isNotEmpty)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _score(Color paper, Color ink) => LayoutBuilder(builder: (context, constraints) {
        final ratio = _page.ratio, dpr = MediaQuery.devicePixelRatioOf(context);
        final frame = ratio == null ? VideoFrame.fill(constraints.biggest) : VideoFrame.fit(constraints.biggest, ratio, devicePixelRatio: dpr);
        _laidOut(frame.rect, frame.scale);
        return Stack(children: [
          Positioned.fromRect(
            rect: frame.rect,
            child: RepaintBoundary(
              child: CustomPaint(
                size: Size.infinite,
                painter: _ScorePainter(_c, frame.scale, dpr, paper, ink, Directionality.of(context)),
              ),
            ),
          ),
        ]);
      });

  Widget _playerMap(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
        const padding = EdgeInsets.fromLTRB(16, 16, 16, 80); // over the controls
        _laidOut(padding.deflateRect(Offset.zero & constraints.biggest), 1);
        return Padding(
          padding: padding,
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size.infinite,
              painter: PlayerMapPainter(map: _c.map!, pulses: _c.mapPulses, time: _c.time, textDirection: Directionality.of(context)),
            ),
          ),
        );
      });

  Widget _controls(BuildContext context, bool hasChoices) {
    final theme = Theme.of(context);
    return ValueListenableBuilder(
      valueListenable: _c.controlsShown,
      builder: (context, shown, child) => AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: const Duration(milliseconds: 190),
        child: IgnorePointer(ignoring: !shown, child: child),
      ),
      child: GestureDetector(
        onTap: () {}, // a tap on the bar isn't one on the score
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 12, offset: Offset(0, 2))],
          ),
          child: Row(children: [
            IconButton(
              tooltip: (_c.playing ? 'Pause' : 'Play').tr,
              icon: Icon(_c.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              onPressed: _c.playPause,
            ),
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: _c.time,
                builder: (context, t, _) => Row(children: [
                  Expanded(
                    child: Slider(
                      min: _heard.start,
                      max: math.max(_heard.end, _heard.start + 0.001),
                      value: t.clamp(_heard.start, _heard.end),
                      onChanged: _c.seek,
                    ),
                  ),
                  Text('${_clock(t - _heard.start)} / ${_clock(_heard.end - _heard.start)}',
                      style: theme.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                ]),
              ),
            ),
            if ((_c.map != null || _c.hasRows) && _page.view.open)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: SegmentedButton<PageShows>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  segments: [
                    if (_c.follows) ButtonSegment(value: PageShows.views, label: Text('Auto'.tr)),
                    // A MIDI project's score is its rows of notes, named as the app names them.
                    ButtonSegment(value: PageShows.score, label: Text(_loaded.score.isRoll ? 'MIDI View'.tr : 'Score'.tr)),
                    if (_c.hasRows) ButtonSegment(value: PageShows.midi, label: Text('MIDI View'.tr)),
                    if (_c.map != null) ButtonSegment(value: PageShows.map, label: Text('Player Map'.tr)),
                  ],
                  selected: {_c.shows},
                  onSelectionChanged: (s) => _c.shows = s.single,
                ),
              ),
            for (final button in _api.buttons) _pluginButton(button),
            if (hasChoices)
              Builder(
                builder: (context) => IconButton(
                  tooltip: 'Options'.tr,
                  icon: const Icon(Icons.tune_rounded),
                  onPressed: () => Scaffold.of(context).openEndDrawer(),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  /// A plugin's button: its icon, else its text (or its name) as its face; its name is its tip.
  /// (The name is the plugin's, translated by it: never through `.tr`.)
  Widget _pluginButton(PageButton button) {
    final run = button.enabled ? () => _api.pressed(button.id) : null;
    if (pageIcons[button.icon] case final icon? when button.text == null) {
      return IconButton(tooltip: button.title, isSelected: button.checked, icon: Icon(icon), onPressed: run);
    }
    const style = ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap);
    final face = Text(button.text ?? button.title);
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(
        message: button.title,
        child: button.checked ? FilledButton.tonal(style: style, onPressed: run, child: face) : TextButton(style: style, onPressed: run, child: face),
      ),
    );
  }

  static String _clock(double seconds) {
    final s = seconds.clamp(0, double.infinity).floor();
    return '${s ~/ 60}:${'${s % 60}'.padLeft(2, '0')}';
  }

  /// What the export left the viewer to choose, under the chapters to jump to; then what the
  /// page's plugins offer, each under its name.
  List<Widget> _choices(BuildContext context) {
    final theme = Theme.of(context), edits = _loaded.edits;
    Widget heading(String text) =>
        Padding(padding: const EdgeInsets.only(top: 16, bottom: 6), child: Text(text, style: theme.textTheme.titleSmall));
    final hasCaptions = _c.extensions.captions.isNotEmpty;
    final chapters = _c.chapters;
    return [
      if (chapters.isNotEmpty) ...[
        heading('Chapters'.tr),
        ValueListenableBuilder(
          valueListenable: _c.time,
          builder: (context, t, _) => Column(children: [
            for (final cue in chapters)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                selected: t - _heard.start >= cue.start - 1e-3 && t - _heard.start < cue.end - 1e-3,
                title: Text(cue.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Text(_clock(cue.start), style: theme.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                onTap: () => _c.seek(_heard.start + cue.start),
              ),
          ]),
        ),
      ],
      if (_page.recording.open && _page.recordings.length > 1) ...[
        heading('Recording'.tr),
        RadioGroup<int>(
          groupValue: _c.recording,
          onChanged: (i) => _c.pick(i!),
          child: Column(children: [
            for (final (i, r) in _page.recordings.indexed)
              RadioListTile<int>(dense: true, contentPadding: EdgeInsets.zero, value: i, title: Text(r.label)),
          ]),
        ),
      ],
      if (_page.speed.open) ...[
        heading('Speed'.tr),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final s in WebPage.speeds) ChoiceChip(label: Text('$s×'), selected: _c.speed == s, onSelected: (_) => _c.speed = s),
        ]),
      ],
      if ((_page.captions.open && hasCaptions) || (_page.barNumbers.open && edits.barNumbers)) heading('Show'.tr),
      if (_page.captions.open && hasCaptions)
        SwitchListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text('Captions'.tr), value: _c.captions, onChanged: (on) => _c.captions = on),
      if (_page.barNumbers.open && edits.barNumbers)
        SwitchListTile(
            dense: true, contentPadding: EdgeInsets.zero, title: Text('Bar numbers'.tr), value: _c.barNumbers, onChanged: (on) => _c.barNumbers = on),
      if (_page.instruments.open) ...[
        heading('Instruments'.tr),
        for (final part in _loaded.score.metadata.parts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Expanded(child: Text(edits.partNames[part.id]?.name ?? part.name, overflow: TextOverflow.ellipsis)),
              SegmentedButton<PartShown>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                segments: [
                  ButtonSegment(value: PartShown.curated, label: Text('Auto'.tr)),
                  ButtonSegment(value: PartShown.shown, label: Text('Show'.tr)),
                  ButtonSegment(value: PartShown.hidden, label: Text('Hide'.tr)),
                ],
                selected: {_c.shown[part.id] ?? PartShown.curated},
                onSelectionChanged: (s) => _c.show(part.id, s.single),
              ),
            ]),
          ),
      ],
      for (final (i, option) in _api.options.indexed) ...[
        if (i == 0 || _api.options[i - 1].group != option.group) heading(option.group),
        _pluginOption(option),
      ],
    ];
  }

  /// A plugin's row of Options: a switch, a choice among its options, or something to do.
  Widget _pluginOption(PageOption option) => switch (option.type) {
        'switch' => SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(option.label),
            value: option.value == true,
            onChanged: option.enabled ? (on) => _api.changed(option.id, on) : null,
          ),
        'choice' => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(option.label)),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final choice in option.options)
                  ChoiceChip(
                    label: Text(choice.label),
                    selected: option.value == choice.value,
                    onSelected: option.enabled ? (_) => _api.changed(option.id, choice.value) : null,
                  ),
              ]),
            ]),
          ),
        _ => Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: OutlinedButton(onPressed: option.enabled ? () => _api.pressed(option.id) : null, child: Text(option.label)),
            ),
          ),
      };
}

/// The icons a plugin's button may name (`Icon` in curator-web.d.ts).
const pageIcons = <String, IconData>{
  'play': Icons.play_arrow_rounded,
  'pause': Icons.pause_rounded,
  'stop': Icons.stop_rounded,
  'previous': Icons.skip_previous_rounded,
  'next': Icons.skip_next_rounded,
  'rewind': Icons.fast_rewind_rounded,
  'forward': Icons.fast_forward_rounded,
  'replay': Icons.replay_rounded,
  'loop': Icons.repeat_rounded,
  'shuffle': Icons.shuffle_rounded,
  'volume': Icons.volume_up_rounded,
  'mute': Icons.volume_off_rounded,
  'fullscreen': Icons.fullscreen_rounded,
  'exitFullscreen': Icons.fullscreen_exit_rounded,
  'link': Icons.link_rounded,
  'share': Icons.share_rounded,
  'copy': Icons.content_copy_rounded,
  'download': Icons.download_rounded,
  'info': Icons.info_outline_rounded,
  'help': Icons.help_outline_rounded,
  'settings': Icons.settings_rounded,
  'bookmark': Icons.bookmark_outline_rounded,
  'star': Icons.star_outline_rounded,
  'heart': Icons.favorite_outline_rounded,
  'search': Icons.search_rounded,
  'list': Icons.format_list_bulleted_rounded,
  'text': Icons.notes_rounded,
  'captions': Icons.closed_caption_outlined,
  'music': Icons.music_note_rounded,
  'piano': Icons.piano_rounded,
  'clock': Icons.schedule_rounded,
  'show': Icons.visibility_outlined,
  'hide': Icons.visibility_off_outlined,
  'zoomIn': Icons.zoom_in_rounded,
  'zoomOut': Icons.zoom_out_rounded,
  'close': Icons.close_rounded,
  'check': Icons.check_rounded,
  'add': Icons.add_rounded,
  'remove': Icons.remove_rounded,
  'more': Icons.more_horiz_rounded,
  'language': Icons.language_rounded,
};

class _Skip extends Intent {
  const _Skip(this.seconds);
  final double seconds;
}

class _ScorePainter extends CustomPainter {
  _ScorePainter(this.state, this.scale, this.devicePixelRatio, this.paper, this.ink, this.textDirection)
      // A PDF score's systems arrive as they are fetched: drawn again then.
      : super(repaint: Listenable.merge([state.time, ?state.loaded.score.pdf]));
  final PlayingPage state;

  /// View points a layout point ([VideoFrame.scale]): 1 when filling the window.
  final double scale;
  final double devicePixelRatio;
  final Color paper, ink;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // As the editor's preview: laid out at the frame's layout size, scaled to fit, showing the
    // views as the project has them (the score throughout, unless the viewer asks for them).
    canvas
      ..clipRect(Offset.zero & size)
      ..scale(scale);
    final s = state, time = s.time.value, end = s.heard.end, map = s.map;
    final views = s.shows == PageShows.views;
    // The score's notes in rows, where the viewer or a view of the lane's has the MIDI view.
    final rows = s.shows == PageShows.midi || (views && s.viewsRows) ? s.rowsScene : null;
    final only = s.shows == PageShows.midi ? SceneView.midi : SceneView.score;
    void draw(CuratedScene scene, Canvas canvas, Size layout) =>
        scene.paint(canvas, layout, time: time, curation: s.curation, devicePixelRatio: devicePixelRatio * scale, end: end, paper: paper, ink: ink);
    paintViews(
      canvas,
      size / scale,
      views ? s.timedViews.at(time) : (from: only, to: only, mix: 0.0),
      score: (canvas, layout) => draw(s.scene, canvas, layout),
      rows: rows == null ? null : (canvas, layout) => draw(rows, canvas, layout),
      map: !views || map == null ? null : (canvas, size) => PlayerMapPainter(map: map, pulses: s.mapPulses, time: s.time, textDirection: textDirection).paintAt(canvas, size, time),
      paper: paper,
      ink: ink,
      fade: s.scene.endFadeAt(time, end),
    );
  }

  @override
  bool shouldRepaint(_ScorePainter old) => true;
}
