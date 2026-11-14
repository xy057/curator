part of '../editor_controller.dart';

/// An item of an extension's markers lane: from score quarter [at] on, named [label].
typedef LaneItem = ({double at, String label});

/// A stretch of an extension's spans lane: score quarters [start] to [end], named [label]
/// (null: nothing) and in [color] (null: as a region is drawn).
typedef LaneStretch = ({double start, double end, String? label, Color? color});

/// Extensions run from packages ([ExtensionPackage]: Curator's own, bundled with the app, and
/// those a project carries): which the project can turn on, the ones running (an
/// [ExtensionRuntime] each, started and stopped as the project's switches say), what each keeps
/// in the project ([EditState.extensionData]: an edit, so Undo, opening and closing take it),
/// and what is selected in their lanes.
class ExtensionEditing {
  ExtensionEditing._(this._editor);
  final EditorController _editor;

  Map<String, ExtensionPackage> _carried = const {};
  Map<String, int> _versions = const {};
  final _runtimes = <String, ExtensionRuntime>{};
  int _revision = 0;

  /// The window dialogs open over; null: none to show them in.
  BuildContext? Function()? window;

  /// What went wrong in extensions, the newest last, and the lines they printed.
  final problems = ValueNotifier<List<ExtensionProblem>>(const []);
  final log = ValueNotifier<List<String>>(const []);

  /// The extensions the project carries, by id.
  Map<String, ExtensionPackage> get carried => _carried;

  /// Every package this project can turn on: Curator's own, then those it carries.
  List<ExtensionPackage> get packages => [...BundledExtensions.packages, ..._carried.values];

  ExtensionPackage? package(String id) => _carried[id] ?? BundledExtensions.byId(id);

  /// The extensions running: on in this project, with a score open.
  Iterable<ExtensionRuntime> get running => _runtimes.values;
  ExtensionRuntime? runtime(String id) => _runtimes[id];

  /// What extension [id] keeps in the project, as JSON.
  Object? data(String id) => _editor._doc.extensionData[id];

  // MARK: The project's packages

  /// Adds [package] to the project (in place of the one it carries with that id), off until
  /// its switch is turned. Not an Undo step, but saved with the project.
  void add(ExtensionPackage package) {
    if (!ExtensionPackage.isThirdPartyId(package.id)) throw const FormatException('The extension has no id Curator can use.');
    if (_carried[package.id] == package) return;
    _carried = Map.unmodifiable({..._carried, package.id: package});
    _stop(package.id);
    _sync();
    _packagesChanged();
  }

  /// Takes extension [id] out of the project, with its switch; what it saved stays, for when
  /// it is added again.
  void remove(String id) {
    if (!_carried.containsKey(id)) return;
    _stop(id);
    _carried = Map.unmodifiable({..._carried}..remove(id));
    _packagesChanged();
  }

  void _packagesChanged() {
    final e = _editor;
    e.editRevision.value++;
    e._showSettings();
    e._changed();
  }

  // MARK: Running

  void _load(ProjectState state) {
    _carried = state.packages;
    _versions = state.dataVersions;
    _revision++;
  }

  void _reset() {
    for (final id in _runtimes.keys.toList()) {
      _stop(id);
    }
    _carried = const {};
    _versions = const {};
    _selection.clear();
    _revision++;
  }

  /// Starts and stops runtimes as the project's switches say.
  void _sync() {
    final e = _editor;
    final shown = _inScene;
    try {
      _startAndStop();
    } finally {
      // A band or captions came or went with their extension: the scene shows what there is now.
      if (shown || _inScene) {
        e.captions._follow();
        e._showSettings();
        e.playback._markDirty(); // the preview repaints only when asked
      }
    }
  }

  /// Whether an extension that is on puts something in the scene: a band, captions, pictures,
  /// spacers.
  bool get _inScene => _runtimes.values.any(_showsInScene);
  static bool _showsInScene(ExtensionRuntime r) => r.graph.nodes.any((n) => const {'band', 'captions', 'images', 'spacers'}.contains(n.type));

  void _startAndStop() {
    final e = _editor;
    for (final p in packages) {
      final on = e._score != null && e.extensionOn(p.id), running = _runtimes[p.id];
      if (!on) {
        if (running != null) _stop(p.id);
      } else if (running == null || !identical(running.package, p)) {
        _stop(p.id);
        _start(p);
      }
    }
    for (final id in _runtimes.keys.toList()) {
      if (package(id) == null) _stop(id);
    }
  }

  void _start(ExtensionPackage p) {
    if (p.api > ExtensionApi.level) {
      _report(ExtensionProblem(p.id, '{name} needs a newer Curator.'.fill({'name': p.name})));
      return;
    }
    final runtime = _runtimes[p.id] = ExtensionRuntime(p, _Host(this, p));
    _bands = null;
    _captions = null;
    _sockets();
    runtime.fire('project', 'opened');
  }

  void _stop(String id) {
    final runtime = _runtimes.remove(id);
    if (runtime == null) return;
    _selection.remove(id);
    _reading.remove(id);
    _bands = null; // its band goes with it
    _captions = null;
    _sockets();
    if (runtime.nodes('images').isNotEmpty && _imager == null) _editor.images._deselect(); // nothing to select now
    _items.removeWhere((key, _) => key.$1 == id);
    _stretches.removeWhere((key, _) => key.$1 == id);
    _spans.removeWhere((key, _) => key.$1 == id);
  }

  /// Runs [package] again from its files: after its code was changed.
  void restart(String id) {
    _stop(id);
    _sync();
    _editor._showSettings();
    _editor._changed();
  }

  /// Whether the project uses extension [id]: what its `project.used` says, or else whether it
  /// has saved anything. Asked of one that is off too, so a project can offer to turn it on.
  bool uses(String id) {
    final p = package(id);
    if (p == null) return false;
    // A font chosen for its captions is a use of them.
    if (_editor.captions._font != null && p.graph.nodes.any((n) => n.type == 'captions')) return true;
    // So are the spacers there are, of one that turns them on.
    if ((_editor._doc.spacers.isNotEmpty || _editor._doc.gaps.isNotEmpty) && p.graph.nodes.any((n) => n.type == 'spacers')) return true;
    final value = data(id);
    final saved = switch (value) { null => false, final Map<Object?, Object?> m => m.isNotEmpty, final List<Object?> l => l.isNotEmpty, _ => true };
    if (p.graph.wire('project', 'used') == null || _editor._score == null) return saved;
    final runtime = _runtimes[id] ?? ExtensionRuntime(p, ReadingHost(p, value, scoreNow: () => _editor._score, timelineNow: () => _editor.timeline));
    return switch (runtime.ask('project', 'used')) { null => saved, final v => v != false };
  }

  /// The version each extension's data is saved with: the one its package writes, or for one
  /// that isn't here the one it came with.
  Map<String, int> get _savedVersions => {
        for (final id in _editor._doc.extensionData.keys) id: package(id)?.dataVersion ?? _versions[id] ?? 1,
      };

  /// The extensions that are on, run to read the project as it is now: what a video or a page
  /// gets from them.
  ExtensionReaders readers() =>
      ExtensionReaders(_editor.projectState.edits, _carried, score: () => _editor._score, timeline: () => _editor.timeline);

  /// Whether an extension that is on gives a video or a page chapters (Chapters, with some).
  bool get exportsChapters => _editor._score != null && readers().chapters(0, math.max(_editor.timeline.endSeconds, _editor.playback.duration)).isNotEmpty;

  // MARK: Data

  void _save(String id, Object? json, String? label) {
    final e = _editor;
    if (e._score == null) throw StateError('No project is open.');
    if (LuaJson.same(e._doc.extensionData[id], json)) return;
    e._doc = e._doc.copyWith(extensionData: Map.unmodifiable({...e._doc.extensionData, id: json}));
    _revision++;
    e._showSettings();
    if (_runtimes[id] case final r? when _showsInScene(r)) e.playback._markDirty(); // the preview repaints only when asked
    e._edited();
    _runtimes[id]?.fire('project', 'changed');
  }

  /// Undo or Redo put [after] where [before] was: the extensions whose data differs are told.
  void _restored(EditState before, EditState after) {
    _revision++;
    for (final runtime in _runtimes.values.toList()) {
      if (!identical(before.extensionData[runtime.id], after.extensionData[runtime.id])) runtime.fire('project', 'changed');
    }
    _selection.clear(); // what was selected may be gone
  }

  void _report(ExtensionProblem problem) {
    debugPrint('Extension ${problem.extension}: ${problem.message}');
    final all = [...problems.value, problem];
    problems.value = List.unmodifiable(all.length > 50 ? all.sublist(all.length - 50) : all);
  }

  void _print(String id, String line) {
    final all = [...log.value, line];
    log.value = List.unmodifiable(all.length > 200 ? all.sublist(all.length - 200) : all);
  }

  /// Forgets the problems and lines of extension [id] (all, when null): its code was run again.
  void clearProblems([String? id]) {
    problems.value = id == null ? const [] : List.unmodifiable(problems.value.where((p) => p.extension != id));
    if (id == null) log.value = const [];
  }

  // MARK: Lanes

  /// What is selected in each extension's lanes: item `index` of lane `lane` (a node of its
  /// connector). One to an extension, as each of the app's own lanes had its own.
  final _selection = <String, ({String lane, int index})>{};

  /// Whether anything is selected in an extension's lane.
  bool get hasSelection => _selection.isNotEmpty;

  /// The item selected in [lane] of extension [id]; null: none.
  int? selectedIn(String id, String lane) => switch (_selection[id]) {
        final s? when s.lane == lane => s.index,
        _ => null,
      };

  void select(String id, String lane, int? index) {
    final next = index == null || index < 0 || !_runtimes.containsKey(id) ? null : (lane: lane, index: index);
    if (next == _selection[id]) return;
    next == null ? _selection.remove(id) : _selection[id] = next;
    _editor._changed();
  }

  /// Selects nothing in any extension's lane: something else was clicked, and the Delete key
  /// goes to that.
  void deselect() {
    if (_selection.isEmpty) return;
    _selection.clear();
    _editor._changed();
  }

  /// The extensions with something selected, in the order they are listed, each with its lane.
  Iterable<({ExtensionRuntime runtime, String lane, int index})> get _selected sync* {
    for (final p in packages) {
      final s = _selection[p.id], runtime = _runtimes[p.id];
      if (s != null && runtime != null) yield (runtime: runtime, lane: s.lane, index: s.index);
    }
  }

  /// Delete: the selected item's lane removes it (the first extension's with one).
  void removeSelected() {
    final s = _selected.firstOrNull;
    if (s == null) return;
    _selection.remove(s.runtime.id);
    s.runtime.fire(s.lane, 'remove', args: [s.index + 1]);
    _editor._changed();
  }

  /// ←/→ with an item selected in a lane that takes them (`nudge`): whether one did.
  bool nudgeSelected(int direction, {required bool fine}) {
    final s = _selected.where((s) => s.runtime.wired(s.lane, 'nudge')).firstOrNull;
    s?.runtime.fire(s.lane, 'nudge', args: [s.index + 1, direction, fine]);
    return s != null;
  }

  /// [ / ] with an item selected in a lane that takes them (`trim`): whether one did.
  bool trimSelected({required bool start}) {
    final s = _selected.where((s) => s.runtime.wired(s.lane, 'trim')).firstOrNull;
    s?.runtime.fire(s.lane, 'trim', args: [s.index + 1, start ? 'start' : 'end']);
    return s != null;
  }

  /// The lanes running extensions show, in the order pinned under the ruler.
  List<({ExtensionRuntime runtime, GraphNode node, num order})> get lanes => [
        for (final r in _runtimes.values)
          for (final node in r.nodes('lane')) (runtime: r, node: node, order: _order(node)),
      ]..sort((a, b) => a.order.compareTo(b.order));

  static num _order(GraphNode node) => switch (node.props['order']) { final num n => n, _ => 100 };

  final _items = <(String, String), ({int revision, LoadedScore? score, AppLanguage language, List<LaneItem> items})>{};
  final _stretches = <(String, String), ({int revision, LoadedScore? score, AppLanguage language, List<LaneStretch> items})>{};
  final _spans = <(String, String), ({List<LaneItem> items, ScoreTimeline timeline, double end, List<MarkerSpan> spans})>{};

  /// What lane [node] of [runtime] shows (its `items`), asked again once the project's data,
  /// the score or the language changes: a lane is painted every frame while the music plays.
  List<LaneItem> items(ExtensionRuntime runtime, GraphNode node) {
    final key = (runtime.id, node.id), kept = _items[key], score = _editor._score, language = Strings.language;
    if (kept != null && kept.revision == _revision && identical(kept.score, score) && kept.language == language) return kept.items;
    final list = runtime.ask(node.id, 'items', quiet: true);
    final items = List<LaneItem>.unmodifiable([
      if (list is LuaTable)
        for (final item in list.array)
          if (item is LuaTable)
            if (item['at'] case final num at when at.isFinite) (at: at.toDouble(), label: switch (item['label']) { null => '', final v => Lua.show(v) }),
    ]);
    _items[key] = (revision: _revision, score: score, language: language, items: items);
    return items;
  }

  /// What a spans lane shows (its `items`: {from, to, label, color}), kept as [items] are.
  List<LaneStretch> stretches(ExtensionRuntime runtime, GraphNode node) {
    final key = (runtime.id, node.id), kept = _stretches[key], score = _editor._score, language = Strings.language;
    if (kept != null && kept.revision == _revision && identical(kept.score, score) && kept.language == language) return kept.items;
    final list = runtime.ask(node.id, 'items', quiet: true);
    final items = List<LaneStretch>.unmodifiable([
      if (list is LuaTable)
        for (final item in list.array)
          if (item is LuaTable)
            if ((item['from'], item['to']) case (final num from, final num to) when from.isFinite && to.isFinite)
              (start: from.toDouble(), end: to.toDouble(), label: switch (item['label']) { null => null, final v => Lua.show(v) }, color: luaColor(item['color'])),
    ]);
    _stretches[key] = (revision: _revision, score: score, language: language, items: items);
    return items;
  }

  /// The [items] of a markers lane in time ([markerSpans]), the last to [end] seconds.
  List<MarkerSpan> spans(ExtensionRuntime runtime, GraphNode node, {required double end}) {
    final key = (runtime.id, node.id), kept = _spans[key], items = this.items(runtime, node), timeline = _editor.timeline;
    if (kept != null && identical(kept.items, items) && identical(kept.timeline, timeline) && kept.end == end) return kept.spans;
    final spans = markerSpans([for (final item in items) item.at], timeline, end: end);
    _spans[key] = (items: items, timeline: timeline, end: end, spans: spans);
    return spans;
  }

  /// The commands [runtime] offers as buttons on the name of [lane].
  Iterable<GraphNode> commands(ExtensionRuntime runtime, {required String lane}) =>
      runtime.nodes('command').where((n) => (n.props['where'] ?? 'lane') == 'lane' && n.props['lane'] == lane);

  /// The commands the running extensions offer in a menu of the preview: [where] is "preview"
  /// (a right-click on the score) or "caption" (on the caption showing: its extension's only).
  List<({ExtensionRuntime runtime, GraphNode command})> menu(String where) => [
        for (final r in where == 'caption' ? [?_captioner?.runtime] : _runtimes.values)
          for (final n in r.nodes('command'))
            if (n.props['where'] == where) (runtime: r, command: n),
      ];

  /// Whether [command] can be chosen now: what its `enabled` says ([at]: the place clicked in
  /// the preview, or the caption's index); always, with none wired.
  bool canRun(ExtensionRuntime runtime, GraphNode command, [Object? at]) =>
      !runtime.wired(command.id, 'enabled') || runtime.ask(command.id, 'enabled', args: [?at], quiet: true) == true;

  // MARK: Captions

  /// The extension whose captions show: the first that is on with a `captions` socket.
  ({ExtensionRuntime runtime, GraphNode node})? get _captioner {
    for (final r in _runtimes.values) {
      for (final node in r.nodes('captions')) {
        return (runtime: r, node: node);
      }
    }
    return null;
  }

  /// Whether an extension that is on gives captions.
  bool get hasCaptions => _captioner != null;

  ({int revision, LoadedScore? score, List<Caption> captions})? _captions;

  /// The captions under the score ([captionsOf]), asked again once the project's data or the
  /// score changes.
  List<Caption> get captions {
    final kept = _captions, score = _editor._score;
    if (kept != null && kept.revision == _revision && identical(kept.score, score)) return kept.captions;
    final captions = captionsOf(_runtimes.values);
    _captions = (revision: _revision, score: score, captions: captions);
    return captions;
  }

  /// The caption showing (an index into [captions]) was double-clicked in the preview.
  void openCaption(int index) {
    if (_captioner case (:final runtime, :final node)) runtime.fire(node.id, 'open', args: [index + 1]);
  }

  /// The extensions (on or off) that give captions: those with a `captions` socket.
  List<String> get captionSources => [
        for (final p in packages)
          if (p.graph.nodes.any((n) => n.type == 'captions')) p.id,
      ];

  /// Whether a video can have subtitles written beside it: captions, and an extension that
  /// gives them as subtitles (`export.subtitles`).
  bool get exportsSubtitles => captions.isNotEmpty && _runtimes.values.any((r) => r.wired('export', 'subtitles'));

  /// The app's settings changed: what an extension keeps for every project may have (its
  /// captions' look).
  void followSettings() => _editor.captions._follow();

  // MARK: Images and spacers

  /// The extension whose pictures are on the score, running: the first that is on with an
  /// `images` socket. And whether one that is on turns the spacers on (a `spacers` socket).
  ExtensionRuntime? _imager;
  bool _spacers = false;

  void _sockets() {
    _imager = _runtimes.values.where((r) => r.nodes('images').isNotEmpty).firstOrNull;
    _spacers = _runtimes.values.any((r) => r.nodes('spacers').isNotEmpty);
  }

  /// Whether an extension that is on puts pictures on the score, and whether one turns the
  /// spacers on.
  bool get hasImages => _imager != null;
  bool get hasSpacers => _spacers;

  /// The extensions (on or off) that put pictures on the score: those with an `images` socket.
  List<ExtensionPackage> get _imagePackages => [
        for (final p in packages)
          if (p.graph.nodes.any((n) => n.type == 'images')) p,
      ];

  List<String> get imageSources => [for (final p in _imagePackages) p.id];

  final _pictures = <String, ({int revision, LoadedScore? score, ExtensionRuntime? runtime, List<ImagePatch> pictures})>{};

  /// What reads the pictures of [p]: it running, or while it is off one run over what it saved
  /// (the pictures stay in the project); null: it has none.
  ExtensionRuntime? _pictureReader(ExtensionPackage p) {
    if (_runtimes[p.id] case final running?) return running;
    final value = data(p.id);
    if (value == null || p.api > ExtensionApi.level || _editor._score == null) return null;
    return ExtensionRuntime(p, ReadingHost(p, value, scoreNow: () => _editor._score, timelineNow: () => _editor.timeline));
  }

  /// The pictures of [p] ([picturesOf]), asked again once the project's data or the score
  /// changes, or it is turned on or off.
  List<ImagePatch> _picturesOf(ExtensionPackage p) {
    final kept = _pictures[p.id], score = _editor._score, running = _runtimes[p.id];
    if (kept != null && kept.revision == _revision && identical(kept.score, score) && (running == null || identical(kept.runtime, running))) return kept.pictures;
    final runtime = _pictureReader(p);
    final pictures = runtime == null ? const <ImagePatch>[] : picturesOf(runtime);
    _pictures[p.id] = (revision: _revision, score: score, runtime: runtime, pictures: pictures);
    return pictures;
  }

  /// The pictures on the score: those of the extension that is on with an `images` socket,
  /// else of the first there is (off: none is drawn, and all are kept).
  List<ImagePatch> get pictures {
    final running = _imager;
    final p = running != null ? running.package : _imagePackages.firstOrNull;
    return p == null ? const [] : _picturesOf(p);
  }

  /// The names of the image files every extension's pictures show, on or off: what the project
  /// keeps.
  Iterable<String> get _imagesShown sync* {
    for (final p in _imagePackages) {
      for (final picture in _picturesOf(p)) {
        yield picture.image;
      }
    }
  }

  /// The image files named [gone] were let go: every state Undo keeps is rewritten without the
  /// pictures showing them (each extension's `images.without`), so Undo never brings one back
  /// without its file. No Undo step.
  void _withoutImages(Set<String> gone) {
    final e = _editor, names = LuaTable.list(gone.toList());
    for (final p in _imagePackages) {
      final node = p.graph.nodes.firstWhere((n) => n.type == 'images');
      if (p.graph.wire(node.id, 'without') == null) continue;
      final runtime = _runtimes[p.id] ?? (p.api > ExtensionApi.level ? null : ExtensionRuntime(p, ReadingHost(p, data(p.id), onProblem: _report)));
      if (runtime == null) continue;
      // The states share what didn't change between them: each is asked about once.
      final asked = Map<Object, Object?>.identity();
      Object? without(Object? saved) {
        if (saved == null) return null;
        return asked.putIfAbsent(saved, () {
          final result = runtime.ask(node.id, 'without', args: [LuaJson.toLua(saved), names]);
          if (result == null) return saved;
          try {
            final json = LuaJson.fromLua(result, where: 'data');
            return LuaJson.same(json, saved) ? saved : json;
          } on LuaError {
            return saved;
          }
        });
      }

      EditState change(EditState state) {
        final saved = state.extensionData[p.id], next = without(saved);
        return identical(next, saved) ? state : state.copyWith(extensionData: Map.unmodifiable({...state.extensionData, p.id: next}));
      }

      e._history.rewrite(e._editState, change);
      if (e._committed case final committed?) e._committed = change(committed);
    }
  }

  // MARK: The band

  ({int revision, LoadedScore? score, AppLanguage language, List<ScoreBand> bands})? _bands;

  /// The band along the score's top: what the running extensions' `band` sockets give, asked
  /// again once the project's data, the score or the language changes.
  List<ScoreBand> get bands {
    final kept = _bands, score = _editor._score, language = Strings.language;
    if (kept != null && kept.revision == _revision && identical(kept.score, score) && kept.language == language) return kept.bands;
    final bands = bandsOf(_runtimes.values);
    _bands = (revision: _revision, score: score, language: language, bands: bands);
    return bands;
  }

  /// The band's names follow the interface's [language] (Settings ▸ General ▸ Language), once
  /// it has switched to it.
  void followLanguage(AppLanguage language) {
    final kept = _bands;
    if (kept == null || kept.bands.isEmpty || language.resolved == kept.language) return;
    scheduleMicrotask(() {
      if (_editor._disposed) return;
      _editor._showSettings();
      _editor.playback._markDirty();
    });
  }

  // MARK: The score's music

  /// The extensions reading the score's music (`score.music`), each with what it calls then.
  final _reading = <String, LuaFunction>{};

  /// On an isolate, from a static function: a closure made beside one that uses the controller
  /// would take it along.
  static Future<ScoreMusic> _musicOff(String xml, List<double> starts) => Isolate.run(() => readScoreMusic(xml, starts));

  /// Reads the score's music for [runtime] off the main isolate, then calls [done] with it
  /// (nil when the score has changed meanwhile).
  void _readMusic(ExtensionRuntime runtime, LuaFunction done) {
    final score = _editor._score;
    if (score == null) throw LuaError("'score.music' needs a score, and none is open");
    if (_reading.containsKey(runtime.id)) throw LuaError("'score.music' is reading the score already");
    _reading[runtime.id] = done;
    _editor._changed();
    unawaited(_musicRead(runtime, done, score));
  }

  Future<void> _musicRead(ExtensionRuntime runtime, LuaFunction done, LoadedScore score) async {
    final e = _editor, id = runtime.id;
    ScoreMusic? music;
    try {
      music = await _musicOff(score.musicXML, score.timeline.measureStarts);
    } finally {
      // Stopped meanwhile (its switch, another project): nothing is called.
      if (identical(_reading[id], done)) {
        _reading.remove(id);
        if (!e._disposed) {
          if (identical(_runtimes[id], runtime)) runtime.call(done, args: [identical(e._score, score) && music != null ? scoreMusicTable(music) : null], where: 'score.music');
          e._changed();
        }
      }
    }
  }

  // MARK: What the editor gives Lua

  void _install(ExtensionRuntime runtime) {
    final e = _editor, id = runtime.id;
    String lane(List<Object?> a, String fn) {
      final name = a.string(0, fn);
      if (runtime.graph.node(name)?.type != 'lane') throw LuaError("the connector has no lane '$name'");
      return name;
    }

    runtime.library('lanes', {
      'selected': (a) {
        final index = selectedIn(id, lane(a, 'lanes.selected'));
        return [index == null ? null : index + 1];
      },
      'select': (a) {
        final index = a.integerOr(1, 'lanes.select');
        select(id, lane(a, 'lanes.select'), index == null ? null : index - 1);
        return const [];
      },
    });
    runtime.library('editor', {
      'playhead': (a) => [e.playback.time.value],
      'seek': (a) {
        e.playback.seek(a.number(0, 'editor.seek').toDouble());
        return const [];
      },
      'beat': (a) {
        final q = a.number(0, 'editor.beat').toDouble(), pass = (a.integerOr(1, 'editor.beat') ?? 1) - 1;
        final beat = beatInLanes(e, q, pass: pass.clamp(0, e.timeline.passes.length - 1));
        return [beat.start, beat.end];
      },
      'snap': (a) {
        final q = a.number(0, 'editor.snap').toDouble(), pass = (a.integerOr(1, 'editor.snap') ?? 1) - 1;
        return [snapInLanes(e, q, pass: pass.clamp(0, e.timeline.passes.length - 1))];
      },
    });
    // The grid the keys step by: bars, or beats.
    double grid(List<Object?> a, String fn, double Function(SyncMap sync, double q, SyncGrid grid) at) {
      final q = a.number(0, fn).toDouble();
      final unit = switch (a.stringOr(1, fn)) { null || 'bar' => SyncGrid.bar, 'beat' => SyncGrid.beat, final u => throw LuaError("bad argument #2 to '$fn' ('bar' or 'beat' expected, got '$u')") };
      final sync = e._sync;
      if (sync == null) throw LuaError("'$fn' needs a score, and none is open");
      return at(sync, q, unit);
    }

    runtime.library('editor', {
      'next': (a) => [grid(a, 'editor.next', (sync, q, unit) => sync.nextGrid(q, unit))],
      'previous': (a) => [grid(a, 'editor.previous', (sync, q, unit) => sync.previousGrid(q, unit))],
      'nearest': (a) => [grid(a, 'editor.nearest', (sync, q, unit) => sync.nearestGrid(q, unit))],
    });
    runtime.library('score', {
      'music': (a) {
        _readMusic(runtime, a.function(0, 'score.music'));
        return const [];
      },
    });
    runtime.library('ui', {
      'form': (a) {
        final spec = a.table(0, 'ui.form'), context = window?.call();
        if (context == null) throw LuaError('there is no window to show a form in');
        showExtensionForm(context, runtime, spec);
        return const [];
      },
      'message': (a) {
        final text = a.string(0, 'ui.message'), context = window?.call();
        if (context == null) throw LuaError('there is no window to show a message in');
        showExtensionMessage(context, text);
        return const [];
      },
      'ask': (a) {
        final spec = a.table(0, 'ui.ask'), context = window?.call();
        if (context == null) throw LuaError('there is no window to ask in');
        showExtensionAsk(context, runtime, spec);
        return const [];
      },
      'sheet': (a) {
        final spec = a.table(0, 'ui.sheet'), context = window?.call();
        if (context == null) throw LuaError('there is no window to show a sheet in');
        final handle = SheetHandle();
        showExtensionSheet(context, runtime, spec, handle);
        return [handle.table];
      },
      'open_file': (a) {
        openExtensionFile(runtime, a.table(0, 'ui.open_file'));
        return const [];
      },
      'save_file': (a) {
        final spec = a.table(0, 'ui.save_file'), context = window?.call();
        if (context == null) throw LuaError('there is no window to save from');
        saveExtensionFile(context, runtime, spec);
        return const [];
      },
    });
  }
}

/// What an extension running in the editor stands on.
class _Host extends ExtensionHost {
  _Host(this._x, this._package);
  final ExtensionEditing _x;
  final ExtensionPackage _package;

  EditorController get _e => _x._editor;

  @override
  Object? get data => _e._doc.extensionData[_package.id];
  @override
  int get revision => _x._revision;
  @override
  void save(Object? json, {String? label}) => _x._save(_package.id, json, label);
  @override
  Object? get settings => _e.extensionSettings?.call(_package.id);
  @override
  void saveSettings(Object? json) => _e.saveExtensionSettings?.call(_package.id, json);
  @override
  LoadedScore? get score => _e._score;
  @override
  ScoreTimeline? get timeline => _e._score == null ? null : _e.timeline;
  @override
  BeatGrid? get beats => _e._score?.beats;
  @override
  String get language => Strings.language.locale.toLanguageTag();
  // Curator's own extensions' texts are the app's, translated with it.
  @override
  String? translate(String text) => BundledExtensions.byId(_package.id) == null ? null : Strings.tableOf(Strings.language)[text];
  @override
  void report(ExtensionProblem problem) => _x._report(problem);
  @override
  void print(String extension, String line) => _x._print(extension, line);

  @override
  void install(ExtensionRuntime runtime) => _x._install(runtime);
}
