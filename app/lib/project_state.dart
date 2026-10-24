import 'dart:ui' show Color, Rect;

import 'package:flutter/foundation.dart';
import 'package:score_engine/score_engine.dart';

import 'image_patch.dart';

/// How a project keeps its recording.
enum MediaStorage {
  /// A copy travels inside the .ccs: bigger, but self-contained.
  embed,

  /// Only the recording's location is saved: small, but the file has to stay where it is.
  link,
}

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

/// [EditState.copyWith]'s "not given", told apart from null.
const _kept = Object();

/// The edits a project saves (everything but its image files and the view), at one moment:
/// what Undo steps through, and the heart of [ProjectState].
@immutable
class EditState {
  const EditState({
    this.lanes,
    this.transition,
    this.scrollFollow,
    this.anchors = const [],
    this.leadIn = 0,
    this.midi,
    this.partNames = const {},
    this.textEdits = const {},
    this.condensed = const {},
    this.pairs = const [],
    this.partOrder = const [],
    this.sections = const {},
    this.groupSections = false,
    this.barNumbers = true,
    this.colorNames = false,
    this.nameColors = const {},
    this.patches = const [],
    this.captions = const [],
    this.captionFont,
    this.fonts = ScoreFonts.standard,
    this.embedFont = true,
    this.engraving = const EngravingOptions(),
    this.mediaStorage,
    this.extensions = const {},
    this.textDynamics,
  });

  /// When each instrument is shown, with each region's own properties; null when the project
  /// has none saved (they are then filled from where each part plays). Never null in Undo.
  final Map<String, List<Region>>? lanes;

  /// Seconds for a staff to enter or leave where its region doesn't set its own; null: the
  /// default for new projects. Never null in Undo.
  final double? transition;

  /// How closely the scroll follows the notes, 0–1 (see [ScrollMap.follow]); null: the app's
  /// default (Save as default).
  final double? scrollFollow;

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

  /// The section the user put some instruments in (Project Settings ▸ Sections), by part id:
  /// a family's name (with that family) or one of the user's (`bracket-2`); null: none,
  /// standing alone. Others are in their own ([ScorePart.section]).
  final Map<String, String?> sections;

  /// Whether the score groups its instruments in sections, as printed ([CuratedScene.sections]).
  final bool groupSections;

  /// Whether every bar's number is shown above the staves, with the tempo marks at the left
  /// ([CuratedScene.barNumbers]); on for a new project.
  final bool barNumbers;

  /// Whether the instruments are named in their family's colour (Project Settings ▸
  /// Instruments, [CuratedScene.nameColors]).
  final bool colorNames;

  /// The colours the user gave some families' names; the others are [defaultNameColors]'.
  final Map<InstrumentFamily, Color> nameColors;

  /// Images on the score (Attach Image), bottom to top.
  final List<ImagePatch> patches;

  /// Captions under the score (Captions), in the order they were added.
  final List<Caption> captions;

  /// The font captions are drawn in (a text font family); null: the app's (Settings).
  final String? captionFont;

  /// The music and text fonts the score is engraved in. A music font the user added travels
  /// with the project (`fonts/<name>.font` and its SMuFL metadata, `fonts/<name>.json`).
  final ScoreFonts fonts;

  /// Whether an added music font travels with the project; false: only its name is saved, and
  /// it is looked for among the fonts installed where the project opens.
  final bool embedFont;

  /// The engraving options this project sets over the app's (Project Settings ▸ Engraving).
  final EngravingOptions engraving;

  /// Whether saves embed the recording or link to it (Project Settings ▸ Project Info); null:
  /// the app's (Settings, before projects had their own).
  final MediaStorage? mediaStorage;

  /// The extensions this project turned on or off (Project Settings ▸ Extensions), by
  /// [CuratorExtension.id]; one left out follows the app's.
  final Map<String, bool> extensions;

  /// Whether dynamics written as text are engraved as dynamics (Project Settings ▸ Flags,
  /// [TextDynamics]); null: the app's (Save as default).
  final bool? textDynamics;

  @override
  bool operator ==(Object other) =>
      other is EditState &&
      transition == other.transition &&
      scrollFollow == other.scrollFollow &&
      leadIn == other.leadIn &&
      midi == other.midi &&
      switch ((lanes, other.lanes)) {
        (final a?, final b?) => Curation.sameLanes(a, b),
        (final a, final b) => a == b,
      } &&
      listEquals(anchors, other.anchors) &&
      mapEquals(partNames, other.partNames) &&
      mapEquals(textEdits, other.textEdits) &&
      setEquals(condensed, other.condensed) &&
      listEquals(pairs, other.pairs) &&
      listEquals(partOrder, other.partOrder) &&
      mapEquals(sections, other.sections) &&
      groupSections == other.groupSections &&
      barNumbers == other.barNumbers &&
      colorNames == other.colorNames &&
      mapEquals(nameColors, other.nameColors) &&
      listEquals(patches, other.patches) &&
      listEquals(captions, other.captions) &&
      captionFont == other.captionFont &&
      fonts == other.fonts &&
      embedFont == other.embedFont &&
      engraving == other.engraving &&
      mediaStorage == other.mediaStorage &&
      mapEquals(extensions, other.extensions) &&
      textDynamics == other.textDynamics;

  @override
  int get hashCode => Object.hash(transition, leadIn, lanes?.length, anchors.length, partNames.length, textEdits.length);

  /// This state with the fields given instead of its own. A field that may be null is
  /// cleared by passing null ([lanes], [transition], [scrollFollow], [midi], [captionFont], [textDynamics]); left out, it stays.
  EditState copyWith({
    Object? lanes = _kept,
    Object? transition = _kept,
    Object? scrollFollow = _kept,
    List<SyncAnchor>? anchors,
    double? leadIn,
    Object? midi = _kept,
    Map<String, PartName>? partNames,
    Map<String, String>? textEdits,
    Set<String>? condensed,
    List<PlayerPair>? pairs,
    List<String>? partOrder,
    Map<String, String?>? sections,
    bool? groupSections,
    bool? barNumbers,
    bool? colorNames,
    Map<InstrumentFamily, Color>? nameColors,
    List<ImagePatch>? patches,
    List<Caption>? captions,
    Object? captionFont = _kept,
    ScoreFonts? fonts,
    bool? embedFont,
    EngravingOptions? engraving,
    MediaStorage? mediaStorage,
    Map<String, bool>? extensions,
    Object? textDynamics = _kept,
  }) =>
      EditState(
        lanes: identical(lanes, _kept) ? this.lanes : lanes as Map<String, List<Region>>?,
        transition: identical(transition, _kept) ? this.transition : transition as double?,
        scrollFollow: identical(scrollFollow, _kept) ? this.scrollFollow : scrollFollow as double?,
        anchors: anchors ?? this.anchors,
        leadIn: leadIn ?? this.leadIn,
        midi: identical(midi, _kept) ? this.midi : midi as MidiTempoMap?,
        partNames: partNames ?? this.partNames,
        textEdits: textEdits ?? this.textEdits,
        condensed: condensed ?? this.condensed,
        pairs: pairs ?? this.pairs,
        partOrder: partOrder ?? this.partOrder,
        sections: sections ?? this.sections,
        groupSections: groupSections ?? this.groupSections,
        barNumbers: barNumbers ?? this.barNumbers,
        colorNames: colorNames ?? this.colorNames,
        nameColors: nameColors ?? this.nameColors,
        patches: patches ?? this.patches,
        captions: captions ?? this.captions,
        captionFont: identical(captionFont, _kept) ? this.captionFont : captionFont as String?,
        fonts: fonts ?? this.fonts,
        embedFont: embedFont ?? this.embedFont,
        engraving: engraving ?? this.engraving,
        mediaStorage: mediaStorage ?? this.mediaStorage,
        extensions: extensions ?? this.extensions,
        textDynamics: identical(textDynamics, _kept) ? this.textDynamics : textDynamics as bool?,
      );
}

/// The colour each family's names take (Project Settings ▸ Instruments) until the user gives it
/// another: mid tones, read on white paper and on dark. Other instruments keep the ink.
const defaultNameColors = <InstrumentFamily, Color>{
  InstrumentFamily.woodwinds: Color(0xFF3B7DD8), // blue
  InstrumentFamily.brass: Color(0xFFD4A20C), // yellow
  InstrumentFamily.percussion: Color(0xFFC8553D), // red
  InstrumentFamily.keyboards: Color(0xFF8E5CC4), // violet
  InstrumentFamily.voices: Color(0xFF3F9A5A), // green
  InstrumentFamily.strings: Color(0xFFA86B3C), // wood
};

/// Everything a project stores besides the score and the recording (`project.json` →
/// `state`): the edits, the image files they show, and the view. Reading it checks every
/// field, so a damaged file says what is wrong instead of failing somewhere later.
///
/// The JSON is written by [toJson] for [ProjectState.version]. Files from older versions
/// go through [_migrations] first, one version at a time.
@immutable
class ProjectState {
  const ProjectState({this.edits = const EditState(), this.images = const {}, this.view = const ViewState()});

  final EditState edits;

  /// The image files [EditState.patches] show, by [PatchImage.id]. Not in the JSON: the
  /// project file keeps each as `images/<id>`.
  final Map<String, PatchImage> images;

  final ViewState view;

  /// The version [toJson] writes (the project file's format version): every save is in the
  /// newest format, whatever the project uses.
  static const version = 19;

  /// Upgrades a state written by version `n` to version `n + 1`. Add one entry whenever
  /// [toJson] changes shape, and bump [version]. Additive only: a new format adds fields (the
  /// entry gives an older file their defaults), never renames, removes or redefines one.
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
    13: (state) => state, // not embedding a font came in 14: every added font embedded
    14: (state) => state, // a MIDI tempo map's warps came in 15: none
    15: (state) => state, // instruments' sections came in 16: none, their own
    16: (state) => state, // grouping sections, and sections of the user's own, came in 17 (16's were families' names): off, none
    17: (state) => {...state, 'barNumbers': false}, // bar numbers came in 18: off, as made
    18: (state) => state, // names in their family's colour came in 19: off
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
      edits: EditState(
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
        scrollFollow: switch (curation.number('scrollFollow')) {
          final f? when f < 0 || f > 1 =>
            throw FormatException('The project is damaged: ${curation.where}.scrollFollow is not between 0 and 1.'),
          final f => f,
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
        sections: {
          for (final MapEntry(key: id, value: name) in r.map('sections').entries)
            id: switch (name) {
              'none' => null,
              final String n when n.trim().isNotEmpty => n,
              _ => throw FormatException('The project is damaged: ${r.where}.sections.$id is not a section.'),
            },
        },
        groupSections: r.boolean('groupSections') ?? false,
        barNumbers: r.boolean('barNumbers') ?? true,
        colorNames: r.boolean('colorNames') ?? false,
        // A family this version doesn't know is left out.
        nameColors: {
          for (final MapEntry(key: name, value: hex) in r.map('nameColors').entries)
            ?InstrumentFamily.values.asNameMap()[name]: _color(hex) ?? (throw FormatException('The project is damaged: ${r.where}.nameColors.$name is not a colour.')),
        },
        patches: patches,
        // Kept apart (those saved before captions couldn't overlap show as they did).
        captions: separateCaptions([
          for (final (i, caption) in r.list('captions').indexed) _caption(JsonReader(caption, '${r.where}.captions[$i]')),
        ]),
        captionFont: switch (r.child('fonts').string('caption')) {
          final f? when f.trim().isEmpty => throw FormatException('The project is damaged: ${r.where}.fonts.caption is empty.'),
          final f => f,
        },
        fonts: _fonts(r.child('fonts'), fontFiles),
        embedFont: r.child('fonts').boolean('embed') ?? true,
        // An option this version doesn't know (or no longer offers) is left out, as the app's are.
        engraving: EngravingOptions.fromJson(r.map('engraving'), keepDefault: true),
        mediaStorage: switch (r.string('mediaStorage')) {
          null => null,
          final s => MediaStorage.values.asNameMap()[s] ??
              (throw FormatException('The project is damaged: ${r.where}.mediaStorage is not embed or link.')),
        },
        // One this version doesn't know is kept, so a newer version's choice survives a save here.
        extensions: Map.unmodifiable({
          for (final MapEntry(key: name, value: on) in r.map('extensions').entries)
            name: on is bool ? on : throw FormatException('The project is damaged: ${r.where}.extensions.$name is not on or off.'),
        }),
        textDynamics: r.child('flags').boolean('textDynamics'),
      ),
      images: {for (final p in patches) p.image: images[p.image]!}, // only those on the score
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
              null when r.boolean('embed') == false => MusicFont.missing(name), // looked for when it opens
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
    final warps = <MidiWarp>[
      if (!r.isAbsent('warps'))
        for (final (i, w) in r.list('warps').indexed)
          switch (w) {
            [final num at, final num jumpTo] when at > 0 && jumpTo >= 0 && at.isFinite && jumpTo.isFinite =>
              (at: at.toDouble(), jumpTo: jumpTo.toDouble()),
            _ => throw FormatException('The project is damaged: ${r.where}.warps[$i] is not a quarter and where it jumps to.'),
          },
    ];
    return MidiTempoMap(r.string('name') ?? '', tempos, warps: warps);
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

  /// "#A86B3C"; null for anything else.
  static Color? _color(Object? hex) => switch (hex) {
        final String s when RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(s) => Color(0xFF000000 | int.parse(s.substring(1), radix: 16)),
        _ => null,
      };

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

  Map<String, Object?> toJson() {
    final EditState(:lanes, :transition, :scrollFollow, :anchors, :leadIn, :midi, :partNames, :textEdits, :condensed, :pairs, :partOrder,
        :sections, :groupSections, :barNumbers, :colorNames, :nameColors, :patches, :captions, :captionFont, :fonts, :embedFont, :engraving, :mediaStorage, :extensions, :textDynamics) = edits;
    // A missing font can't be embedded: it is looked for again next time.
    final embedded = embedFont && !fonts.music.isMissing;
    return {
      if (fonts != ScoreFonts.standard || captionFont != null || !embedded)
        'fonts': {
          if (fonts.music != MusicFont.bravura) 'music': fonts.music.name,
          if (fonts.text != TextFonts.academico) 'text': fonts.text,
          'caption': ?captionFont,
          if (!embedded) 'embed': false,
        },
      if (!engraving.isEmpty) 'engraving': engraving.toJson(),
      'mediaStorage': ?mediaStorage?.name,
      if (extensions.isNotEmpty) 'extensions': extensions,
      if (textDynamics != null) 'flags': {'textDynamics': textDynamics},
      'textEdits': textEdits,
      'condensed': [...condensed],
      'pairs': [for (final p in pairs) p.partIds],
      'partOrder': partOrder,
      if (groupSections) 'groupSections': true,
      if (!barNumbers) 'barNumbers': false,
      if (colorNames) 'colorNames': true,
      if (nameColors.isNotEmpty)
        'nameColors': {
          for (final MapEntry(key: family, value: color) in nameColors.entries)
            family.name: '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
        },
      if (sections.isNotEmpty)
        'sections': {for (final MapEntry(key: id, value: s) in sections.entries) id: s ?? 'none'},
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
        'scrollFollow': ?scrollFollow,
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
            if (midi.warps.isNotEmpty) 'warps': [for (final w in midi.warps) [w.at, w.jumpTo]],
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
