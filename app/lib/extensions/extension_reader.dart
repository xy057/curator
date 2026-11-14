import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:score_engine/score_engine.dart';

import '../image_patch.dart';
import '../l10n/l10n.dart';
import '../project_state.dart';
import 'bundled.dart';

/// What an extension stands on where nothing is edited: a project being opened, a video's
/// export, a web page. It reads the data it saved and the score, and can change neither.
class ReadingHost extends ExtensionHost {
  ReadingHost(this.package, this.data, {this.scoreNow, this.timelineNow, this.onProblem, this.settingsNow, this.onSaveSettings});
  final ExtensionPackage package;

  /// What the extension keeps for every project, and what keeps it; null: nothing, and it
  /// can't be changed here.
  final Object? Function()? settingsNow;
  final void Function(Object? json)? onSaveSettings;

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
  Object? get settings => settingsNow?.call();
  @override
  void saveSettings(Object? json) => onSaveSettings == null ? super.saveSettings(json) : onSaveSettings!(json);
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

  /// The captions under the score ([captionsOf]).
  List<Caption> get captions => captionsOf(_runtimes);

  /// The pictures on the score ([picturesOf]): the first extension's that has the socket.
  List<ImagePatch> get pictures {
    for (final r in _runtimes) {
      if (r.nodes('images').isNotEmpty) return picturesOf(r);
    }
    return const [];
  }

  /// The subtitles of a video showing [from]–[to] seconds of the performance, as a SubRip
  /// file's text (`export.subtitles`): the first extension's that gives any; null: none.
  String? subtitles(double from, double to) {
    for (final r in _runtimes) {
      if (r.ask('export', 'subtitles', args: [from, to]) case final String text) return text;
    }
    return null;
  }
}

/// The captions under the score as [runtimes]' `captions` sockets give them ({from, to, text}):
/// the first extension's that has the socket. Each stands where it does in the extension's own
/// list (`captions.open` is told its place there): one that doesn't read shows nothing.
List<Caption> captionsOf(Iterable<ExtensionRuntime> runtimes) {
  for (final r in runtimes) {
    for (final node in r.nodes('captions')) {
      final list = r.ask(node.id, 'list', quiet: true);
      return List.unmodifiable([
        if (list is LuaTable)
          for (final c in list.array)
            switch (c) {
              final LuaTable c => switch ((c['from'], c['to'], c['text'])) {
                  (final num from, final num to, final String text) when from.isFinite && to.isFinite => Caption(from.toDouble(), to.toDouble(), text),
                  _ => const Caption(0, 0, ''),
                },
              _ => const Caption(0, 0, ''),
            },
      ]);
    }
  }
  return const [];
}

/// The pictures on the score as [runtime]'s `images` socket gives them ({image, at, top,
/// width, height, crop, ink}). Each stands where it does in the extension's own list
/// (`images.change` is told its place there): one that doesn't read is kept, with no image
/// to draw.
List<ImagePatch> picturesOf(ExtensionRuntime runtime) {
  for (final node in runtime.nodes('images')) {
    final list = runtime.ask(node.id, 'list', quiet: true);
    return List.unmodifiable([
      if (list is LuaTable)
        for (final p in list.array) _picture(p),
    ]);
  }
  return const [];
}

ImagePatch _picture(Object? picture) {
  if (picture is LuaTable) {
    if ((picture['image'], picture['at'], picture['top'], picture['width'], picture['height'])
        case (final String image, final num at, final num top, final num width, final num height)
        when at.isFinite && top.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0) {
      final crop = switch (picture['crop']) {
        final LuaTable c => switch ((c['left'], c['top'], c['right'], c['bottom'])) {
            (final num l, final num t, final num r, final num b) when 0 <= l && l < r && r <= 1 && 0 <= t && t < b && b <= 1 =>
              Rect.fromLTRB(l.toDouble(), t.toDouble(), r.toDouble(), b.toDouble()),
            _ => ImagePatch.full,
          },
        _ => ImagePatch.full,
      };
      return ImagePatch(
          image: image, quarter: at.toDouble(), top: top.toDouble(), width: width.toDouble(), height: height.toDouble(), crop: crop, ink: picture['ink'] == true);
    }
  }
  return const ImagePatch(image: '', quarter: 0, top: 0, width: 1, height: 1);
}

/// [patch] as an `images` socket is handed a picture.
LuaTable pictureTable(ImagePatch patch) => LuaTable.map({
      'image': patch.image,
      'at': patch.quarter,
      'top': patch.top,
      'width': patch.width,
      'height': patch.height,
      if (patch.crop != ImagePatch.full)
        'crop': LuaTable.map({'left': patch.crop.left, 'top': patch.crop.top, 'right': patch.crop.right, 'bottom': patch.crop.bottom}),
      'ink': patch.ink,
    });

bool _has(ExtensionPackage package, String socket) => package.graph.nodes.any((n) => n.type == socket);

/// Whether an extension that is on in [edits] (one of Curator's own, or of [carried]) has a
/// [socket]: what its being on turns on in the app (`spacers`).
bool socketOn(EditState edits, Map<String, ExtensionPackage> carried, String socket) => [...BundledExtensions.packages, ...carried.values]
    .any((p) => (edits.extensions[p.id] ?? false) && p.api <= ExtensionApi.level && _has(p, socket));

/// The image files the pictures of [state]'s extensions show (those with an `images` socket,
/// on or off), by name, in the order first shown: the ones a project keeps.
Map<String, PatchImage> imagesShown(ProjectState state) {
  final shown = <String, PatchImage>{};
  for (final p in [...BundledExtensions.packages, ...state.packages.values]) {
    final value = state.edits.extensionData[p.id];
    if (value == null || !_has(p, 'images') || p.api > ExtensionApi.level) continue;
    for (final picture in picturesOf(ExtensionRuntime(p, ReadingHost(p, value)))) {
      if (state.images[picture.image] case final image?) shown[picture.image] = image;
    }
  }
  return shown;
}

/// How an extension asks its captions to look (`captions.style`): the font (a text font's
/// family; '': the score's text font), the countdown, the size, the side and the backing.
typedef CaptionAsk = ({String font, CaptionCountdown countdown, CaptionSize size, CaptionAlign align, bool plate});

/// A `captions.style` as it is read: what is left out or isn't known is as captions are at
/// first (a line, medium, centred, no backing).
CaptionAsk captionAsk(Object? style) {
  T named<T extends Enum>(List<T> values, Object? name, T otherwise) => values.where((v) => v.name == name).firstOrNull ?? otherwise;
  final t = style is LuaTable ? style : LuaTable();
  return (
    font: switch (t['font']) { final String s => s, _ => '' },
    countdown: named(CaptionCountdown.values, t['countdown'], CaptionCountdown.line),
    size: named(CaptionSize.values, t['size'], CaptionSize.medium),
    align: named(CaptionAlign.values, t['align'], CaptionAlign.center),
    plate: t['plate'] == true,
  );
}

/// What the first of [runtimes] with a `captions` socket asks its captions to look like.
CaptionAsk captionAskOf(Iterable<ExtensionRuntime> runtimes) {
  for (final r in runtimes) {
    for (final node in r.nodes('captions')) {
      return captionAsk(r.wired(node.id, 'style') ? r.ask(node.id, 'style', quiet: true) : null);
    }
  }
  return captionAsk(null);
}

/// The family the scene draws captions in for the text font named [name] ('' : the score's
/// own, null), read and registered first when it is an installed one; `found` is false when
/// it isn't installed here or can't be read (the score's text font stands in). At once when
/// there is nothing to read.
FutureOr<({String? family, bool found})> captionFamily(String name) {
  if (name.isEmpty) return (family: null, found: true);
  if (name == TextFonts.academico) return (family: TextFonts.familyOf(name), found: true);
  return () async {
    try {
      final faces = await TextFonts.faces(name);
      if (faces == null) return (family: null, found: false);
      await TextFonts.load(name, faces);
      return (family: TextFonts.familyOf(name), found: true);
    } catch (_) {
      return (family: null, found: false); // its files can't be read: as if not installed
    }
  }();
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
    // As it is written, to the letter: a place read as 7 is kept as 7.0, as the extension has it.
    if (jsonEncode(loaded) != jsonEncode(value)) data = {...data, p.id: loaded};
  }
  return identical(data, state.edits.extensionData) ? state : state.copyWith(edits: state.edits.copyWith(extensionData: Map.unmodifiable(data)));
}

/// [state] with every extension's data moved to a score that replaced its own
/// (`project.replaced`): [at] gives where a place of the old score is in the new one, null when
/// it is gone; [end] is the new score's length, in quarters. Also what each lost, as it says it
/// ("2 chapters"; what was lost of the pictures on the score last, as it always was said), and
/// the image files no picture shows any more let go.
({ProjectState state, List<String> lost}) carriedExtensionData(ProjectState state, double? Function(double quarter) at, {required double end}) {
  var data = state.edits.extensionData;
  final lost = <String>[], lostPictures = <String>[];
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
    if (result.length > 1 && result[1] is String) (_has(p, 'images') ? lostPictures : lost).add(result[1]! as String);
  }
  final carried = identical(data, state.edits.extensionData) ? state : state.copyWith(edits: state.edits.copyWith(extensionData: Map.unmodifiable(data)));
  return (
    state: carried.copyWith(images: imagesShown(carried)),
    lost: [...lost, ...lostPictures],
  );
}
