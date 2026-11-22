import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:score_engine/score_engine.dart';

import '../extensions/extension_reader.dart';
import '../web_page.dart';
import 'page_audio.dart';
import 'page_loader.dart';

/// What a page's plugins hear of: [event] happened, with [data] (JSON). True when one of them
/// asks that the player not do what it otherwise would (a click's play or pause).
typedef PageListener = bool Function(String event, Map<String, Object?> data);

/// A page as it plays: what is heard, where it is, and what the viewer (or a plugin) has chosen
/// of what shows; no widget. [PagePlayer] draws it and calls [tick] each frame; [PageApi]
/// answers the page's plugins from it. It tells its listeners when anything but the [time] is
/// other than it was, and [listener] (the plugins) of everything that happens.
class PlayingPage extends ChangeNotifier {
  PlayingPage(this.loaded, {required this.audioFor}) {
    _showSettings();
    _hear(_recording, at: heard.start);
    // Not in the middle of the music, where a view first shows them.
    if (_shows == PageShows.midi || viewsRows) rowsScene;
  }

  final LoadedPage loaded;

  /// The sound of a recording ([WebRecording.audio], beside the page; null: silent).
  final PageAudio Function(String? file) audioFor;

  WebPage get page => loaded.page;

  // MARK: What the viewer chose

  int get recording => _recording;
  late int _recording = page.recording.value.clamp(0, page.recordings.length - 1);

  double get speed => _speed;
  late double _speed = page.speed.value;

  bool get captions => _captions;
  bool get barNumbers => _barNumbers;
  late bool _captions = page.captions.value, _barNumbers = page.barNumbers.value;

  /// Each instrument shown other than as curated, by part id.
  Map<String, PartShown> get shown => _shown;
  late Map<String, PartShown> _shown = page.instruments.value;

  double _volume = 1;
  bool _muted = false;

  /// The project's player map (null: none).
  late final PlayerMap? map = loaded.edits.playerMap;

  /// What the project's Video tab shows when ([SceneView]): the page follows it, as a video does.
  late final StepLane<SceneView> views = (loaded.edits.automation ?? Automation.none).steps(SceneViews.target);

  /// Whether the score's notes can be shown in rows where it is engraved (the MIDI view of a
  /// score that is notation; a MIDI project's score is rows already).
  late final bool hasRows = loaded.score.hasRows;

  /// Whether a view of the lane's is the MIDI view (and the score has one).
  late final bool viewsRows = hasRows && views.stretches.any((s) => s.value.kind.showsRows);

  /// Whether there are views to follow: a stretch showing what the page has, a map or the
  /// score's notes in rows.
  late final bool follows = views.stretches.any((s) => s.value.kind.showsRows ? hasRows : map != null);

  /// What the page can show, in the order its switch has them.
  late final List<PageShows> available = [
    if (follows) PageShows.views,
    PageShows.score,
    if (hasRows) PageShows.midi,
    if (map != null) PageShows.map,
  ];

  /// What shows, as the export set it and the viewer (if it is theirs to change) has it since:
  /// the score where the page hasn't what it names (no map, no notes to draw in rows, no views
  /// to follow).
  PageShows get shows => _shows;
  late PageShows _shows = available.contains(page.view.value) ? page.view.value : PageShows.score;

  // MARK: What is drawn

  late final CuratedScene scene = CuratedScene(loaded.score, style: RenderStyle(staffSpace: page.staffSpace));

  /// The score's notes in rows ([LoadedScore.rows]), a scene beside the score's: made when
  /// first shown (a browser has no isolate to spare), before the page shows where it is to
  /// from the start.
  CuratedScene? _rows;

  CuratedScene? get rowsScene {
    if (!hasRows) return null;
    return _rows ??= CuratedScene(loaded.score.rows(loaded.edits.midiLook), style: RenderStyle(staffSpace: page.staffSpace))
      ..settings = scene.settings
      ..setTimeline(scene.timeline);
  }

  /// The views in the recording heard's time.
  TimedSteps<SceneView> get timedViews => _timedViews.of(views, scene.timeline);
  final _timedViews = TimedStepsCache<SceneView>();

  Curation get curation => _curation;
  late Curation _curation = loaded.curation(_shown);

  /// The page's extensions (those on in its project), reading the recording heard.
  late final ExtensionReaders extensions = loaded.extensions(() => scene.timeline);

  /// The page's chapters as the recording heard has them, timed from its start: none while
  /// no extension that is on gives any (Chapters).
  List<ChapterCue> get chapters => _chapters ??= extensions.chapters(heard.start, heard.end);
  List<ChapterCue>? _chapters;

  /// The score's bars, numbered as the project counts them.
  late final BeatGrid beats = loaded.score.beats.countedFrom(loaded.edits.firstBar ?? 1);

  /// The score's notes as loud as its dynamics have them, read the first time the map shows (a
  /// browser has no isolate to spare); the pulses, as the recording heard plays them.
  PlayerNotes? _notes;
  PlayerPulses? _pulses;

  PlayerPulses get mapPulses {
    if (map == null) return PlayerPulses.none;
    final score = loaded.score;
    _notes ??= !score.hasNotes ? PlayerNotes.none : PlayerNotes.ofScore(score.musicXML, score.timeline.measureStarts);
    return _pulses ??= PlayerPulses(_notes!, scene.timeline);
  }

  void _showSettings() {
    scene.settings = loaded.settings(captions: _captions, barNumbers: _barNumbers, bands: extensions);
    _rows?.settings = scene.settings;
  }

  // MARK: What is heard

  PageAudio get audio => _audio;
  late PageAudio _audio;

  WebRecording get heard => page.recordings[_recording];

  /// Seconds of the performance shown ([WebRecording.start]…[WebRecording.end]).
  final time = ValueNotifier(0.0);

  /// Seconds into what is heard, as the transport counts them and plugins are told.
  double get now => time.value - heard.start;
  double get duration => heard.end - heard.start;

  bool get playing => _audio.playing;

  /// Plays recording [index] from [at] (seconds of its performance).
  void _hear(int index, {required double at}) {
    _recording = index;
    _audio = audioFor(heard.audio)
      ..speed = _speed
      ..volume = _volume
      ..muted = _muted;
    scene.setTimeline(loaded.timeline(heard));
    _rows?.setTimeline(scene.timeline);
    _pulses = null; // as this recording plays the notes
    _chapters = null;
    _moveTo(at);
  }

  void _moveTo(double t) {
    t = t.clamp(heard.start, heard.end);
    _audio.seek(t - heard.start);
    time.value = t;
  }

  /// Moves to [t], seconds of the performance.
  void seek(double t) {
    _moveTo(t);
    _tell('seek', {'time': now});
  }

  Future<void> play() async {
    if (_audio.playing) return;
    if (time.value >= heard.end - 0.05) _moveTo(heard.start);
    try {
      await _audio.play();
    } catch (_) {
      // The browser lets no sound start before the viewer has clicked or pressed a key (a
      // plugin asked too early): it stays where it is.
    }
    _watch();
  }

  void pause() {
    _audio.pause();
    _watch();
  }

  Future<void> playPause() async => _audio.playing ? pause() : await play();

  /// Another recording, from the same place in the score.
  void pick(int index) {
    if (index == _recording || index < 0 || index >= page.recordings.length) return;
    final old = scene.timeline, playing = _audio.playing;
    final quarter = old.quarterAtSeconds(time.value), pass = old.passAt(time.value);
    _audio.dispose();
    final next = loaded.timeline(page.recordings[index]);
    _hear(index, at: next.secondsAtQuarter(quarter, pass: math.min(pass, next.passes.length - 1)));
    if (playing) _audio.play();
    notifyListeners();
    _tell('recording', {'index': index});
  }

  set speed(double value) {
    value = value.clamp(0.25, 4.0);
    if (value == _speed) return;
    _audio.speed = _speed = value;
    notifyListeners();
    _tell('speed', {'speed': value});
  }

  double get volume => _volume;
  set volume(double value) => _audio.volume = _volume = value.clamp(0.0, 1.0);

  bool get muted => _muted;
  set muted(bool value) => _audio.muted = _muted = value;

  // MARK: What shows

  set captions(bool on) {
    if (on == _captions) return;
    _captions = on;
    _showSettings();
    notifyListeners();
    _tell('captions', {'on': on});
  }

  set barNumbers(bool on) {
    if (on == _barNumbers) return;
    _barNumbers = on;
    _showSettings();
    notifyListeners();
    _tell('barNumbers', {'on': on});
  }

  /// Shows what the page has ([available]); anything else is left.
  set shows(PageShows value) {
    if (value == _shows || !available.contains(value)) return;
    _shows = value;
    notifyListeners();
    _tell('view', {'shows': value.name});
  }

  /// Shows instrument [part] as its lane says, always or never.
  void show(String part, PartShown how) {
    if ((_shown[part] ?? PartShown.curated) == how) return;
    _shown = {..._shown, part: how};
    _curation.dispose();
    _curation = loaded.curation(_shown);
    notifyListeners();
    _tell('instruments', const {});
  }

  /// Where the score's frame is in the window, and how many of its points a layout point is
  /// ([VideoFrame.scale]): as the player last laid it out.
  Rect get frame => _frame;
  double get frameScale => _frameScale;
  Rect _frame = Rect.zero;
  double _frameScale = 1;

  void setFrame(Rect frame, double scale) {
    if (frame == _frame && scale == _frameScale) return;
    _frame = frame;
    _frameScale = scale;
    _tell('resize', {'frame': rectJson(frame)});
  }

  static Map<String, Object?> rectJson(Rect r) => {'x': r.left, 'y': r.top, 'width': r.width, 'height': r.height};

  /// The scene whose music scrolls in the frame now; null while the map shows in its place.
  CuratedScene? get scrolling => switch (_shows) {
        PageShows.map => null,
        PageShows.midi => rowsScene,
        _ => scene,
      };

  // MARK: The transport

  /// Whether the transport shows: it rests while the page plays and the pointer is still, and
  /// stays away while [controlsHidden].
  final controlsShown = ValueNotifier(true);
  DateTime _moved = DateTime.now();

  bool get controlsHidden => _controlsHidden;
  bool _controlsHidden = false;
  set controlsHidden(bool hidden) {
    if (hidden == _controlsHidden) return;
    _controlsHidden = hidden;
    _rest();
  }

  /// The pointer moved: the transport is back.
  void woke() {
    _moved = DateTime.now();
    _rest();
  }

  void _rest() {
    final shown = !_controlsHidden && !(_audio.playing && DateTime.now().difference(_moved) > const Duration(seconds: 3));
    if (shown == controlsShown.value) return;
    controlsShown.value = shown;
    _tell('controls', {'visible': shown});
  }

  // MARK: As it plays

  /// The page's plugins, once they have started; null: none.
  PageListener? get listener => _listener;
  PageListener? _listener;
  set listener(PageListener? value) {
    _listener = value;
    // Told of what changes from now.
    _toldTime = time.value;
    _toldBar = _barNow;
    _toldChapter = _chapterNow;
  }

  bool _tell(String event, Map<String, Object?> data) => _listener?.call(event, data) ?? false;

  /// The score was clicked at ([x], [y]), points from the frame's left and top: true when a
  /// plugin asks that the player not play or pause for it.
  bool clicked(double x, double y) =>
      _listener != null && _tell('click', {'x': x, 'y': y, 'quarter': scrolling?.quarterAtFrameX(x / _frameScale, time.value, _frame.size / _frameScale)});

  bool _wasPlaying = false;
  double _toldTime = 0;
  int _toldBar = -1, _toldChapter = -1;

  int get _barNow => beats.measureAt(scene.timeline.quarterAtSeconds(time.value)).clamp(0, beats.measureStarts.length - 2);

  int get _chapterNow {
    final t = now;
    return chapters.indexWhere((c) => t >= c.start - 1e-3 && t < c.end - 1e-3);
  }

  /// Bar [index] (from 0), as plugins are told of one.
  Map<String, Object?> barJson(int index) {
    final starts = beats.measureStarts;
    return {'index': index, 'number': beats.barNumber(index), 'start': starts[index], 'length': starts[index + 1] - starts[index]};
  }

  /// Each frame: the time follows the sound, which stops at the end.
  void tick() {
    var ended = false;
    if (_audio.playing) {
      final t = heard.start + _audio.position;
      if (t >= heard.end) {
        _audio.pause();
        _moveTo(heard.end);
        ended = true;
      } else {
        time.value = t;
      }
    }
    _watch();
    if (ended) _tell('ended', const {});
    _rest();
  }

  /// Tells of what is other than it was last told: whether it plays (the browser may stop a
  /// sound itself, and a plugin through its element), the time, the bar and the chapter.
  void _watch() {
    if (_audio.playing != _wasPlaying) {
      _wasPlaying = _audio.playing;
      notifyListeners(); // the button plays or pauses
      _tell(_wasPlaying ? 'play' : 'pause', const {});
    }
    if (_listener == null || time.value == _toldTime) return;
    _toldTime = time.value;
    _tell('time', {'time': now});
    if (_barNow case final bar when bar != _toldBar) {
      _toldBar = bar;
      _tell('bar', barJson(bar));
    }
    if (_chapterNow case final chapter when chapter != _toldChapter) {
      _toldChapter = chapter;
      _tell('chapter', {'index': chapter});
    }
  }

  @override
  void dispose() {
    _listener = null;
    _audio.dispose();
    scene.dispose();
    _rows?.dispose();
    _curation.dispose();
    time.dispose();
    controlsShown.dispose();
    super.dispose();
  }
}
