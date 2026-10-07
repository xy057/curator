import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:score_engine/score_engine.dart';

import 'image_patch.dart';

/// An instrument's name as the user set it: the full name and the short one.
typedef PartName = ({String name, String abbreviation});

/// How the editor was left: restored when the project opens, but not an edit.
@immutable
class ViewState {
  const ViewState({this.staffSpace, this.grid, this.snapTapsToOnsets, this.time});

  /// Null: not saved, keep the editor's own.
  final double? staffSpace;
  final SyncGrid? grid;
  final bool? snapTapsToOnsets;
  final double? time;
}

/// Everything a project stores besides the score and the recording (`project.json` →
/// `state`): the edits, and the view. Reading it checks every field, so a damaged file says
/// what is wrong instead of failing somewhere later.
///
/// The JSON is written by [toJson] for [ProjectState.version]. Files from older versions
/// go through [_migrations] first, one version at a time.
@immutable
class ProjectState {
  const ProjectState({
    this.lanes,
    this.transition,
    this.anchors = const [],
    this.leadIn = 0,
    this.midi,
    this.partNames = const {},
    this.textEdits = const {},
    this.condensed = const {},
    this.pairs = const [],
    this.partOrder = const [],
    this.patches = const [],
    this.images = const {},
    this.captions = const [],
    this.captionFont,
    this.fonts = ScoreFonts.standard,
    this.engraving = const EngravingOptions(),
    this.view = const ViewState(),
  });

  /// The version [toJson] writes (the project file's format version).
  static const version = 13;

  /// When each instrument is shown, with each region's own properties; null when the project
  /// has none saved (they are then filled from where each part plays).
  final Map<String, List<Region>>? lanes;

  /// Seconds for a staff to enter or leave where its region doesn't set its own; null: the
  /// default for new projects.
  final double? transition;

  /// The tempo track: where the score is pinned to the recording (warps among them), and the
  /// start before any anchor.
  final List<SyncAnchor> anchors;
  final double leadIn;

  /// The MIDI tempo map the sync follows instead of [anchors] (which are kept for when it
  /// goes), its start at [leadIn]; null: the anchors.
  final MidiTempoMap? midi;

  /// Instrument names set by the user, by part id.
  final Map<String, PartName> partNames;

  /// Score texts changed by the user: text id → new text ('' removes it).
  final Map<String, String> textEdits;

  /// The pairs of players that share a staff while both are shown (CondensedGroup ids).
  final Set<String> condensed;

  /// Pairs of players the user made (Flute 1 + Oboe 1), besides the score's own; a player in
  /// one leaves the built-in pair (see [CondensingOptions.pairs]).
  final List<PlayerPair> pairs;

  /// The instruments top to bottom (part ids), when the user moved some; empty: the score's
  /// order. Parts it lacks follow in score order.
  final List<String> partOrder;

  /// Images on the score (Attach Image), bottom to top.
  final List<ImagePatch> patches;

  /// The image files [patches] show, by [PatchImage.id]. Not in the JSON: the project file
  /// keeps each as `images/<id>`.
  final Map<String, PatchImage> images;

  /// Captions under the score (Captions), in the order they were added.
  final List<Caption> captions;

  /// The font captions are drawn in (a text font family); null: the app's (Settings).
  final String? captionFont;

  /// The music and text fonts the score is engraved in. A music font the user added travels
  /// with the project (`fonts/<name>.font` and its SMuFL metadata, `fonts/<name>.json`).
  final ScoreFonts fonts;

  /// The engraving options this project sets over the app's (Project Settings ▸ Engraving).
  final EngravingOptions engraving;

  final ViewState view;

  /// Upgrades a state written by version `n` to version `n + 1`. Add one entry whenever
  /// [toJson] changes shape, and bump [version].
  static final Map<int, Map<String, Object?> Function(Map<String, Object?>)> _migrations = {
    1: (state) => {...state, 'condensed': const <String>[]}, // condensing came in 2: nothing condensed
    2: (state) => {...state, 'pairs': const <Object?>[]}, // the user's own pairs came in 3: none
    3: (state) => state, // warps came in 4 (an anchor's `jumpTo`): none, so nothing to change
    4: (state) => state, // the instruments' order came in 5: none saved is the score's
    5: (state) => state, // a region's own transitions came in 6: none, the project's
    6: (state) => state, // MIDI tempo maps came in 7: none, the anchors
    7: (state) => state, // images on the score came in 8: none
    8: (state) => state, // fonts came in 9: none saved is Bravura and Academico
    9: (state) => state, // an image's ink came in 10: none is its own colours
    10: (state) => state, // captions came in 11: none
    11: (state) => state, // a caption font came in 12: none is the app's
    12: (state) => state, // a project's engraving options came in 13: none, the app's
  };

  /// Reads a saved state written by format [savedVersion]. Throws a [FormatException] that
  /// names the damaged field.
  /// [images] are the image files the project holds (see [images]; those not on the score
  /// are left out); [fontFiles] its music
  /// fonts' files and metadata, by name (see [fonts]).
  factory ProjectState.fromJson(Map<String, Object?> json,
      {int savedVersion = version,
      Map<String, PatchImage> images = const {},
      Map<String, ({Uint8List file, Uint8List? metadata})> fontFiles = const {}}) {
    var state = json;
    // The first format is 1: a file claiming one before it (-1e9) is read as 1, not stepped
    // up from there.
    for (var v = savedVersion.clamp(1, version); v < version; v++) {
      final migrate = _migrations[v];
      if (migrate != null) state = migrate(state);
    }
    final r = JsonReader(state, 'state');
    final curation = r.child('curation');
    final sync = r.child('sync');
    final view = r.child('view');
    final patches = [
      for (final (i, patch) in r.list('patches').indexed) _patch(JsonReader(patch, '${r.where}.patches[$i]'), images),
    ];
    return ProjectState(
      lanes: curation.isAbsent('lanes')
          ? null
          : {
              for (final MapEntry(key: id, value: lane) in curation.map('lanes').entries)
                id: [
                  for (final (i, region) in JsonReader.listAt(lane, '${curation.where}.lanes.$id').indexed)
                    _region(JsonReader(region, '${curation.where}.lanes.$id[$i]')),
                ],
            },
      transition: switch (curation.number('transition')) {
        final s? when s < 0 || s > maxTransition =>
          throw FormatException('The project is damaged: ${curation.where}.transition is not a length of time.'),
        final s => s,
      },
      anchors: [
        for (final (i, anchor) in sync.list('anchors').indexed)
          () {
            final a = JsonReader(anchor, '${sync.where}.anchors[$i]');
            return SyncAnchor(a.number('quarter', required: true)!, a.number('seconds', required: true)!,
                jumpTo: a.number('jumpTo'));
          }(),
      ]..sort((a, b) => a.seconds.compareTo(b.seconds)),
      leadIn: sync.number('leadIn') ?? 0,
      midi: sync.isAbsent('midi') ? null : _midi(sync.child('midi')),
      partNames: {
        for (final id in r.map('partNames').keys)
          id: () {
            final p = r.child('partNames').child(id);
            return (name: p.string('name', required: true)!, abbreviation: p.string('abbreviation') ?? '');
          }(),
      },
      textEdits: {
        for (final id in r.map('textEdits').keys) id: r.child('textEdits').string(id, required: true)!,
      },
      condensed: {
        for (final (i, id) in r.list('condensed').indexed)
          id is String ? id : throw FormatException('The project is damaged: ${r.where}.condensed[$i] is not text.'),
      },
      pairs: [
        for (final (i, pair) in r.list('pairs').indexed)
          switch (pair) {
            [final String a, final String b] when a != b => PlayerPair(a, b),
            _ => throw FormatException('The project is damaged: ${r.where}.pairs[$i] is not two part ids.'),
          },
      ],
      partOrder: [
        for (final (i, id) in r.list('partOrder').indexed)
          id is String ? id : throw FormatException('The project is damaged: ${r.where}.partOrder[$i] is not text.'),
      ],
      patches: patches,
      images: {for (final p in patches) p.image: images[p.image]!}, // only those on the score
      // Kept apart (those saved before captions couldn't overlap show as they did).
      captions: separateCaptions([
        for (final (i, caption) in r.list('captions').indexed) _caption(JsonReader(caption, '${r.where}.captions[$i]')),
      ]),
      captionFont: switch (r.child('fonts').string('caption')) {
        final f? when f.trim().isEmpty => throw FormatException('The project is damaged: ${r.where}.fonts.caption is empty.'),
        final f => f,
      },
      fonts: _fonts(r.child('fonts'), fontFiles),
      // An option this version doesn't know (or no longer offers) is left out, as the app's are.
      engraving: EngravingOptions.fromJson(r.map('engraving'), keepDefault: true),
      view: ViewState(
        staffSpace: view.number('staffSpace'),
        grid: switch (view.string('grid')) {
          null => null,
          final name =>
            SyncGrid.values.asNameMap()[name] ?? (throw FormatException('The project is damaged: ${view.where}.grid "$name" is unknown.')),
        },
        snapTapsToOnsets: view.boolean('snapTapsToOnsets'),
        time: view.number('time'),
      ),
    );
  }

  static ScoreFonts _fonts(JsonReader r, Map<String, ({Uint8List file, Uint8List? metadata})> files) {
    final music = r.string('music');
    final text = r.string('text');
    if (text != null && text.trim().isEmpty) throw FormatException('The project is damaged: ${r.where}.text is empty.');
    return ScoreFonts(
      music: switch (music) {
        null => MusicFont.bravura,
        final name => MusicFont.bundledNamed(name) ??
            switch (files[name]) {
              null => throw FormatException('The project is damaged: the music font $name is missing.'),
              final f => MusicFont.added(family: name, file: f.file, metadata: f.metadata),
            },
      },
      text: text ?? TextFonts.academico,
    );
  }

  static MidiTempoMap _midi(JsonReader r) {
    final tempos = <MidiTempo>[
      for (final (i, t) in r.list('tempos').indexed)
        switch (t) {
          [final num q, final num qpm] when q >= 0 && qpm > 0 && q.isFinite && qpm.isFinite =>
            (quarter: q.toDouble(), quartersPerMinute: qpm.toDouble()),
          _ => throw FormatException('The project is damaged: ${r.where}.tempos[$i] is not a quarter and a tempo.'),
        },
    ];
    for (var i = 0; i < tempos.length; i++) {
      if (i == 0 ? tempos[i].quarter != 0 : tempos[i].quarter <= tempos[i - 1].quarter) {
        throw FormatException('The project is damaged: ${r.where}.tempos are out of order.');
      }
    }
    if (tempos.isEmpty) throw FormatException('The project is damaged: ${r.where}.tempos is empty.');
    return MidiTempoMap(r.string('name') ?? '', tempos);
  }

  static ImagePatch _patch(JsonReader r, Map<String, PatchImage> images) {
    final image = r.string('image', required: true)!;
    // Saved as images/<id> as it is: a name that would change there (a/b.png, a:b.png) would
    // leave the patch without its image when opened again.
    if (!PatchImage.isId(image)) throw FormatException('The project is damaged: the image of ${r.where} is not a file name.');
    if (!images.containsKey(image)) throw FormatException('The project is damaged: the image of ${r.where} is missing.');
    double size(String key) {
      final v = r.number(key, required: true)!;
      if (!(v > 0) || !v.isFinite) throw FormatException('The project is damaged: ${r.where}.$key is not a size.');
      return v;
    }

    final crop = switch (r.list('crop')) {
      [] => ImagePatch.full,
      [final num l, final num t, final num rt, final num b] when 0 <= l && l < rt && rt <= 1 && 0 <= t && t < b && b <= 1 =>
        Rect.fromLTRB(l.toDouble(), t.toDouble(), rt.toDouble(), b.toDouble()),
      _ => throw FormatException('The project is damaged: ${r.where}.crop is not a part of the image.'),
    };
    final quarter = r.number('quarter', required: true)!, top = r.number('top', required: true)!;
    if (!quarter.isFinite || !top.isFinite) throw FormatException('The project is damaged: ${r.where} is not placed.');
    return ImagePatch(
        image: image, quarter: quarter, top: top, width: size('width'), height: size('height'), crop: crop, ink: r.boolean('ink') ?? false);
  }

  static Caption _caption(JsonReader r) {
    final start = r.number('start', required: true)!, end = r.number('end', required: true)!;
    if (start < 0) throw FormatException('The project is damaged: ${r.where} starts before the score.');
    if (end <= start) throw FormatException('The project is damaged: ${r.where} ends before it starts.');
    return Caption(start, end, r.string('text', required: true)!);
  }

  /// The longest a staff may take to glide in or out, seconds (far more than any dialog offers).
  static const maxTransition = 60.0;

  static Region _region(JsonReader r) {
    final start = r.number('start', required: true)!, end = r.number('end', required: true)!;
    if (start < 0) throw FormatException('The project is damaged: ${r.where} starts before the score.');
    if (end < start) throw FormatException('The project is damaged: ${r.where} ends before it starts.');
    double? seconds(String key) {
      final s = r.number(key);
      if (s != null && (s < 0 || s > maxTransition)) {
        throw FormatException('The project is damaged: ${r.where}.$key is not a length of time.');
      }
      return s;
    }

    return Region(start, end, transitionIn: seconds('transitionIn'), transitionOut: seconds('transitionOut'));
  }

  Map<String, Object?> toJson() => {
        if (fonts != ScoreFonts.standard || captionFont != null)
          'fonts': {
            if (fonts.music != MusicFont.bravura) 'music': fonts.music.name,
            if (fonts.text != TextFonts.academico) 'text': fonts.text,
            'caption': ?captionFont,
          },
        if (!engraving.isEmpty) 'engraving': engraving.toJson(),
        'textEdits': textEdits,
        'condensed': [...condensed],
        'pairs': [for (final p in pairs) p.partIds],
        'partOrder': partOrder,
        'patches': [
          for (final p in patches)
            {
              'image': p.image,
              'quarter': p.quarter,
              'top': p.top,
              'width': p.width,
              'height': p.height,
              if (p.crop != ImagePatch.full) 'crop': [p.crop.left, p.crop.top, p.crop.right, p.crop.bottom],
              if (p.ink) 'ink': true,
            },
        ],
        'captions': [
          for (final c in captions) {'start': c.start, 'end': c.end, 'text': c.text},
        ],
        'partNames': {
          for (final MapEntry(key: id, value: p) in partNames.entries) id: {'name': p.name, 'abbreviation': p.abbreviation},
        },
        'curation': {
          'transition': ?transition,
          'lanes': {
            for (final MapEntry(key: id, value: lane) in (lanes ?? const <String, List<Region>>{}).entries)
              id: [for (final r in lane) {'start': r.start, 'end': r.end, 'transitionIn': ?r.transitionIn, 'transitionOut': ?r.transitionOut}],
          },
        },
        'sync': {
          'leadIn': leadIn,
          if (midi case final midi?)
            'midi': {
              'name': midi.name,
              'tempos': [for (final t in midi.tempos) [t.quarter, t.quartersPerMinute]],
            },
          'anchors': [
            for (final a in anchors) {'quarter': a.quarter, 'seconds': a.seconds, 'jumpTo': ?a.jumpTo},
          ],
        },
        'view': {
          'staffSpace': ?view.staffSpace,
          'grid': ?view.grid?.name,
          'snapTapsToOnsets': ?view.snapTapsToOnsets,
          'time': ?view.time,
        },
      };
}

/// Typed access to one object of a project's JSON, with its path for error messages
/// ("The project is damaged: state.sync.anchors[3].seconds is not a number.").
class JsonReader {
  JsonReader(Object? value, this.where)
      : _map = value == null
            ? const {}
            : value is Map
                ? value.cast<String, Object?>()
                : throw FormatException('The project is damaged: $where is not an object.');

  final Map<String, Object?> _map;
  final String where;

  static List<Object?> listAt(Object? value, String where) =>
      value is List ? value : throw FormatException('The project is damaged: $where is not a list.');

  bool isAbsent(String key) => _map[key] == null;

  JsonReader child(String key) => JsonReader(_map[key], _join(key));
  Map<String, Object?> map(String key) => child(key)._map;
  List<Object?> list(String key) => _map[key] == null ? const [] : listAt(_map[key], _join(key));

  /// A number no bigger than [maxNumber] either way: JSON can say 1e999, which reads as
  /// infinity, and every time, position and size in a project is far smaller.
  double? number(String key, {bool required = false}) {
    final value = _typed<num>(key, 'a number', required)?.toDouble();
    if (value != null && !(value.abs() <= maxNumber)) throw FormatException('The project is damaged: ${_join(key)} is out of range.');
    return value;
  }

  static const maxNumber = 1e9;
  String? string(String key, {bool required = false}) => _typed<String>(key, 'text', required);
  bool? boolean(String key) => _typed<bool>(key, 'true or false', false);

  T? _typed<T>(String key, String kind, bool required) {
    final value = _map[key];
    if (value == null && !required) return null;
    if (value is T) return value;
    throw FormatException('The project is damaged: ${_join(key)} is not $kind.');
  }

  String _join(String key) => '$where.$key';
}
