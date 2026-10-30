import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import '../app_colors.dart' show ScorePaper;
import '../l10n/l10n.dart';
import '../video_frame.dart';
import '../web_page.dart';
import 'page_audio.dart';
import 'page_loader.dart';

/// A page: the score scrolling as it is heard, the transport at the foot (hidden while it plays
/// and the pointer rests), and what the export left the viewer to choose, in a side panel.
class PagePlayer extends StatefulWidget {
  const PagePlayer(this.loaded, {super.key, required this.audioFor});

  final LoadedPage loaded;

  /// The sound of a recording ([WebRecording.audio], beside the page; null: silent).
  final PageAudio Function(String? file) audioFor;

  @override
  State<PagePlayer> createState() => _PagePlayerState();
}

class _PagePlayerState extends State<PagePlayer> with SingleTickerProviderStateMixin {
  LoadedPage get _loaded => widget.loaded;
  WebPage get _page => _loaded.page;

  late int _recording = _page.recording.value;
  late double _speed = _page.speed.value;
  late bool _captions = _page.captions.value, _barNumbers = _page.barNumbers.value;
  late Map<String, PartShown> _shown = _page.instruments.value;

  late final CuratedScene _scene = CuratedScene(_loaded.score, style: RenderStyle(staffSpace: _page.staffSpace));
  late Curation _curation = _loaded.curation(_shown);
  late PageAudio _audio;
  late final Ticker _ticker = createTicker((_) => _tick());

  /// Seconds of the performance shown ([WebRecording.start]…[WebRecording.end]).
  final _time = ValueNotifier(0.0);
  final _controlsShown = ValueNotifier(true);
  DateTime _moved = DateTime.now();

  WebRecording get _heard => _page.recordings[_recording];

  @override
  void initState() {
    super.initState();
    _showSettings();
    _hear(_recording, at: _heard.start);
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _audio.dispose();
    _scene.dispose();
    _curation.dispose();
    _time.dispose();
    _controlsShown.dispose();
    super.dispose();
  }

  void _showSettings() => _scene.settings = _loaded.settings(captions: _captions, barNumbers: _barNumbers);

  /// Plays recording [index] from [at] (seconds of its performance).
  void _hear(int index, {required double at}) {
    _recording = index;
    _audio = widget.audioFor(_heard.audio)..speed = _speed;
    _scene.setTimeline(_loaded.timeline(_heard));
    _seek(at);
  }

  void _tick() {
    if (_audio.playing) {
      final t = _heard.start + _audio.position;
      if (t >= _heard.end) {
        _audio.pause();
        _seek(_heard.end);
        setState(() {}); // the button plays again
      } else {
        _time.value = t;
      }
    }
    final rest = _audio.playing && DateTime.now().difference(_moved) > const Duration(seconds: 3);
    _controlsShown.value = !rest;
  }

  void _seek(double t) {
    t = t.clamp(_heard.start, _heard.end);
    _audio.seek(t - _heard.start);
    _time.value = t;
  }

  Future<void> _playPause() async {
    if (_audio.playing) {
      _audio.pause();
    } else {
      if (_time.value >= _heard.end - 0.05) _seek(_heard.start);
      await _audio.play();
    }
    if (mounted) setState(() {});
  }

  void _woke() {
    _moved = DateTime.now();
    _controlsShown.value = true;
  }

  /// Another recording, from the same place in the score.
  void _pick(int index) {
    if (index == _recording) return;
    final old = _scene.timeline, playing = _audio.playing;
    final quarter = old.quarterAtSeconds(_time.value), pass = old.passAt(_time.value);
    _audio.dispose();
    final next = _loaded.timeline(_page.recordings[index]);
    _hear(index, at: next.secondsAtQuarter(quarter, pass: math.min(pass, next.passes.length - 1)));
    if (playing) _audio.play();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final brightness = dark ? Brightness.dark : Brightness.light;
    final paper = ScorePaper.paper(brightness), ink = ScorePaper.ink(brightness);
    final choices = _choices(context);
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft): _Skip(-5),
        SingleActivator(LogicalKeyboardKey.arrowRight): _Skip(5),
      },
      child: Actions(
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _playPause()),
          _Skip: CallbackAction<_Skip>(onInvoke: (s) => _seek(_time.value + s.seconds)),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: paper,
            endDrawer: choices.isEmpty ? null : Drawer(width: 320, child: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: choices))),
            body: MouseRegion(
              onHover: (_) => _woke(),
              child: GestureDetector(
                onTap: () {
                  _woke();
                  _playPause();
                },
                child: Stack(children: [
                  Positioned.fill(child: _score(paper, ink)),
                  Positioned(left: 0, right: 0, bottom: 0, child: _controls(context, choices.isNotEmpty)),
                ]),
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
        return Stack(children: [
          Positioned.fromRect(
            rect: frame.rect,
            child: RepaintBoundary(
              child: CustomPaint(
                size: Size.infinite,
                painter: _ScorePainter(this, frame.scale, dpr, paper, ink),
              ),
            ),
          ),
        ]);
      });

  Widget _controls(BuildContext context, bool hasChoices) {
    final theme = Theme.of(context);
    return ValueListenableBuilder(
      valueListenable: _controlsShown,
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
              tooltip: (_audio.playing ? 'Pause' : 'Play').tr,
              icon: Icon(_audio.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              onPressed: _playPause,
            ),
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: _time,
                builder: (context, t, _) => Row(children: [
                  Expanded(
                    child: Slider(
                      min: _heard.start,
                      max: math.max(_heard.end, _heard.start + 0.001),
                      value: t.clamp(_heard.start, _heard.end),
                      onChanged: _seek,
                    ),
                  ),
                  Text('${_clock(t - _heard.start)} / ${_clock(_heard.end - _heard.start)}',
                      style: theme.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                ]),
              ),
            ),
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

  static String _clock(double seconds) {
    final s = seconds.clamp(0, double.infinity).floor();
    return '${s ~/ 60}:${'${s % 60}'.padLeft(2, '0')}';
  }

  /// What the export left the viewer to choose.
  List<Widget> _choices(BuildContext context) {
    final theme = Theme.of(context), edits = _loaded.edits;
    Widget heading(String text) =>
        Padding(padding: const EdgeInsets.only(top: 16, bottom: 6), child: Text(text, style: theme.textTheme.titleSmall));
    final hasCaptions = (edits.extensions['captions'] ?? false) && edits.captions.isNotEmpty;
    return [
      if (_page.recording.open && _page.recordings.length > 1) ...[
        heading('Recording'.tr),
        RadioGroup<int>(
          groupValue: _recording,
          onChanged: (i) => _pick(i!),
          child: Column(children: [
            for (final (i, r) in _page.recordings.indexed)
              RadioListTile<int>(dense: true, contentPadding: EdgeInsets.zero, value: i, title: Text(r.label)),
          ]),
        ),
      ],
      if (_page.speed.open) ...[
        heading('Speed'.tr),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final s in WebPage.speeds)
            ChoiceChip(
              label: Text('$s×'),
              selected: _speed == s,
              onSelected: (_) => setState(() => _audio.speed = _speed = s),
            ),
        ]),
      ],
      if ((_page.captions.open && hasCaptions) || (_page.barNumbers.open && edits.barNumbers)) heading('Show'.tr),
      if (_page.captions.open && hasCaptions)
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('Captions'.tr),
          value: _captions,
          onChanged: (on) => setState(() {
            _captions = on;
            _showSettings();
          }),
        ),
      if (_page.barNumbers.open && edits.barNumbers)
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('Bar numbers'.tr),
          value: _barNumbers,
          onChanged: (on) => setState(() {
            _barNumbers = on;
            _showSettings();
          }),
        ),
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
                selected: {_shown[part.id] ?? PartShown.curated},
                onSelectionChanged: (s) => setState(() {
                  _shown = {..._shown, part.id: s.single};
                  _curation.dispose();
                  _curation = _loaded.curation(_shown);
                }),
              ),
            ]),
          ),
      ],
    ];
  }
}

class _Skip extends Intent {
  const _Skip(this.seconds);
  final double seconds;
}

class _ScorePainter extends CustomPainter {
  _ScorePainter(this.state, this.scale, this.devicePixelRatio, this.paper, this.ink) : super(repaint: state._time);
  final _PagePlayerState state;

  /// View points a layout point ([VideoFrame.scale]): 1 when filling the window.
  final double scale;
  final double devicePixelRatio;
  final Color paper, ink;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // As the editor's preview: laid out at the frame's layout size, scaled to fit.
    canvas
      ..clipRect(Offset.zero & size)
      ..scale(scale);
    state._scene.paint(canvas, size / scale,
        time: state._time.value,
        curation: state._curation,
        devicePixelRatio: devicePixelRatio * scale,
        end: state._heard.end,
        paper: paper,
        ink: ink);
  }

  @override
  bool shouldRepaint(_ScorePainter old) => true;
}
