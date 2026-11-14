part of '../editor_controller.dart';

/// An item of an extension's markers lane: from score quarter [at] on, named [label].
typedef LaneItem = ({double at, String label});

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
    _selected = null;
    _revision++;
  }

  /// Starts and stops runtimes as the project's switches say.
  void _sync() {
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
    runtime.fire('project', 'opened');
  }

  void _stop(String id) {
    if (_runtimes.remove(id) == null) return;
    if (_selected?.extension == id) _selected = null;
    _items.removeWhere((key, _) => key.$1 == id);
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
    e._edited();
    _runtimes[id]?.fire('project', 'changed');
  }

  /// Undo or Redo put [after] where [before] was: the extensions whose data differs are told.
  void _restored(EditState before, EditState after) {
    _revision++;
    for (final runtime in _runtimes.values.toList()) {
      if (!identical(before.extensionData[runtime.id], after.extensionData[runtime.id])) runtime.fire('project', 'changed');
    }
    final selected = _selected;
    if (selected != null && !identical(before.extensionData[selected.extension], after.extensionData[selected.extension])) _selected = null;
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

  /// What is selected in an extension's lane: item [index] of lane [lane] (a node of its
  /// connector); null: nothing.
  ({String extension, String lane, int index})? get selected => _selected;
  ({String extension, String lane, int index})? _selected;

  /// The item selected in [lane] of extension [id]; null: none.
  int? selectedIn(String id, String lane) => switch (_selected) {
        final s? when s.extension == id && s.lane == lane => s.index,
        _ => null,
      };

  void select(String id, String lane, int? index) {
    final next = index == null || index < 0 || !_runtimes.containsKey(id) ? null : (extension: id, lane: lane, index: index);
    if (next == _selected) return;
    _selected = next;
    _editor._changed();
  }

  /// Delete: the selected item's lane removes it.
  void removeSelected() {
    final s = _selected;
    if (s == null) return;
    _selected = null;
    _runtimes[s.extension]?.fire(s.lane, 'remove', args: [s.index + 1]);
    _editor._changed();
  }

  /// The lanes running extensions show, in the order pinned under the ruler.
  List<({ExtensionRuntime runtime, GraphNode node, num order})> get lanes => [
        for (final r in _runtimes.values)
          for (final node in r.nodes('lane')) (runtime: r, node: node, order: _order(node)),
      ]..sort((a, b) => a.order.compareTo(b.order));

  static num _order(GraphNode node) => switch (node.props['order']) { final num n => n, _ => 100 };

  final _items = <(String, String), ({int revision, LoadedScore? score, List<LaneItem> items})>{};
  final _spans = <(String, String), ({List<LaneItem> items, ScoreTimeline timeline, double end, List<MarkerSpan> spans})>{};

  /// What lane [node] of [runtime] shows (its `items`), asked again once the project's data or
  /// the score changes: a lane is painted every frame while the music plays.
  List<LaneItem> items(ExtensionRuntime runtime, GraphNode node) {
    final key = (runtime.id, node.id), kept = _items[key], score = _editor._score;
    if (kept != null && kept.revision == _revision && identical(kept.score, score)) return kept.items;
    final list = runtime.ask(node.id, 'items', quiet: true);
    final items = List<LaneItem>.unmodifiable([
      if (list is LuaTable)
        for (final item in list.array)
          if (item is LuaTable)
            if (item['at'] case final num at when at.isFinite) (at: at.toDouble(), label: switch (item['label']) { null => '', final v => Lua.show(v) }),
    ]);
    _items[key] = (revision: _revision, score: score, items: items);
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

  /// The commands [runtime] offers: with [lane], the buttons on that lane's name.
  Iterable<GraphNode> commands(ExtensionRuntime runtime, {String? lane}) => runtime.nodes('command').where((n) =>
      lane == null ? n.props['where'] == 'preview' : (n.props['where'] ?? 'lane') == 'lane' && n.props['lane'] == lane);

  /// Whether [command] can be chosen now: what its `enabled` says; always, with none wired.
  bool canRun(ExtensionRuntime runtime, GraphNode command) =>
      !runtime.wired(command.id, 'enabled') || runtime.ask(command.id, 'enabled', quiet: true) == true;

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
