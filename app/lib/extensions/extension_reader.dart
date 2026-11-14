import 'package:score_engine/score_engine.dart';

import '../l10n/l10n.dart';
import '../project_state.dart';
import 'bundled.dart';

/// What an extension stands on where nothing is edited: a project being opened, a video's
/// export, a web page. It reads the data it saved and the score, and can change neither.
class ReadingHost extends ExtensionHost {
  ReadingHost(this.package, this.data, {this.scoreNow, this.timelineNow, this.onProblem});
  final ExtensionPackage package;

  /// The score and the performance as they are when asked; null: there is none.
  final LoadedScore? Function()? scoreNow;
  final ScoreTimeline? Function()? timelineNow;

  /// Told what goes wrong; null: it is kept quiet.
  final void Function(ExtensionProblem problem)? onProblem;

  @override
  final Object? data;
  @override
  int get revision => 0;
  @override
  void save(Object? json, {String? label}) => throw StateError('Nothing can be changed here.');
  @override
  LoadedScore? get score => scoreNow?.call();
  @override
  ScoreTimeline? get timeline => timelineNow?.call();
  @override
  BeatGrid? get beats => score?.beats;
  @override
  String get language => Strings.language.locale.toLanguageTag();
  // Curator's own extensions' texts are the app's, translated with it.
  @override
  String? translate(String text) => BundledExtensions.byId(package.id) == null ? null : Strings.tableOf(Strings.language)[text];
  @override
  void report(ExtensionProblem problem) => onProblem?.call(problem);
}

/// The extensions of a project, run to read it: what a video and a web page get from them.
/// Each extension that is on runs over the data as it was when this was made, so an export
/// under way isn't changed by an edit.
class ExtensionReaders {
  ExtensionReaders(EditState edits, Map<String, ExtensionPackage> carried,
      {required LoadedScore? Function() score, required ScoreTimeline? Function() timeline, void Function(ExtensionProblem problem)? onProblem}) {
    for (final p in [...BundledExtensions.packages, ...carried.values]) {
      if (!(edits.extensions[p.id] ?? false) || p.api > ExtensionApi.level) continue;
      _runtimes.add(ExtensionRuntime(p, ReadingHost(p, edits.extensionData[p.id], scoreNow: score, timelineNow: timeline, onProblem: onProblem)));
    }
  }

  /// None: a project without extensions.
  ExtensionReaders.none();

  final _runtimes = <ExtensionRuntime>[];

  /// The extensions that give chapters (`export.chapters`), by id.
  List<String> get chapterSources => [
        for (final r in _runtimes)
          if (r.wired('export', 'chapters')) r.id,
      ];

  /// The chapters of a video or a page showing [from]–[to] seconds of the performance, timed
  /// from [from]: the first extension's that has any. They are put in order and end to end,
  /// as a player expects, whatever the extension gave.
  List<ChapterCue> chapters(double from, double to) {
    for (final r in _runtimes) {
      final list = r.ask('export', 'chapters', args: [from, to]);
      if (list is! LuaTable) continue;
      final cues = <ChapterCue>[
        for (final cue in list.array)
          if (cue is LuaTable)
            if ((cue['from'], cue['to']) case (final num start, final num end) when start.isFinite && end.isFinite && end > start)
              (start: start.toDouble(), end: end.toDouble(), name: switch (cue['name']) { null => '', final v => Lua.show(v) }),
      ];
      if (cues.isNotEmpty) return cues;
    }
    return const [];
  }

  /// The band along the score's top ([bandsOf]), in the interface's language as it is now.
  List<ScoreBand> get bands => bandsOf(_runtimes);
}

/// The band along the score's top as [runtimes]' `band` sockets give it ({from, to, color,
/// label}): each stretch that has a length and a colour, the first extension's that has any.
List<ScoreBand> bandsOf(Iterable<ExtensionRuntime> runtimes) {
  for (final r in runtimes) {
    for (final node in r.nodes('band')) {
      final list = r.ask(node.id, 'areas', quiet: true);
      if (list is! LuaTable) continue;
      final bands = <ScoreBand>[
        for (final area in list.array)
          if (area is LuaTable)
            if ((area['from'], area['to'], luaColor(area['color'])) case (final num from, final num to, final color?) when from.isFinite && to.isFinite && to > from)
              ScoreBand(from.toDouble(), to.toDouble(), color, switch (area['label']) { null => '', final v => Lua.show(v) }),
      ];
      if (bands.isNotEmpty) return List.unmodifiable(bands);
    }
  }
  return const [];
}

/// [state] with every extension's data as its `project.load` gives it (checked, and brought to
/// the version the extension writes now). A [FormatException] when one refuses it: the project
/// is damaged.
ProjectState checkedExtensionData(ProjectState state) {
  var data = state.edits.extensionData;
  for (final p in [...BundledExtensions.packages, ...state.packages.values]) {
    final value = data[p.id];
    if (value == null || p.graph.wire('project', 'load') == null || p.api > ExtensionApi.level) continue;
    final runtime = ExtensionRuntime(p, ReadingHost(p, value));
    if (runtime.problems.isNotEmpty) continue; // its code doesn't read: said when it is turned on
    final Object? loaded;
    try {
      final result = runtime.invoke('project', 'load', [LuaJson.toLua(value), state.dataVersions[p.id] ?? 1]);
      loaded = result.isEmpty || result[0] == null ? value : LuaJson.fromLua(result[0], where: 'data');
    } on LuaError catch (e) {
      final where = switch (p.data['module']) { final String module => module, _ => 'extensiondata.${p.id}' };
      throw FormatException('The project is damaged: $where.${e.message}');
    }
    if (!LuaJson.same(loaded, value)) data = {...data, p.id: loaded};
  }
  return identical(data, state.edits.extensionData) ? state : state.copyWith(edits: state.edits.copyWith(extensionData: Map.unmodifiable(data)));
}

/// [state] with every extension's data moved to a score that replaced its own
/// (`project.replaced`): [at] gives where a place of the old score is in the new one, null when
/// it is gone; [end] is the new score's length, in quarters. Also what each lost, as it says it
/// ("2 chapters").
({ProjectState state, List<String> lost}) carriedExtensionData(ProjectState state, double? Function(double quarter) at, {required double end}) {
  var data = state.edits.extensionData;
  final lost = <String>[];
  final carry = LuaBuiltin('carry', (a) => [at(a.number(0, 'carry').toDouble())]);
  for (final p in [...BundledExtensions.packages, ...state.packages.values]) {
    final value = data[p.id];
    if (value == null || p.graph.wire('project', 'replaced') == null || p.api > ExtensionApi.level) continue;
    final runtime = ExtensionRuntime(p, ReadingHost(p, value));
    final result = runtime.fire('project', 'replaced', args: [LuaJson.toLua(value), carry, end]);
    if (result == null || result.isEmpty || result[0] == null) continue;
    final Object? moved;
    try {
      moved = LuaJson.fromLua(result[0], where: 'data');
    } on LuaError {
      continue;
    }
    if (!LuaJson.same(moved, value)) data = {...data, p.id: moved};
    if (result.length > 1 && result[1] is String) lost.add(result[1]! as String);
  }
  return (
    state: identical(data, state.edits.extensionData) ? state : state.copyWith(edits: state.edits.copyWith(extensionData: Map.unmodifiable(data))),
    lost: lost,
  );
}
