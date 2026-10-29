import 'dart:ui' show Color;

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
    this.motion,
    this.typography,
    this.anchors = const [],
    this.leadIn = 0,
    this.midi,
    this.takes = const [],
    this.heard,
    this.partNames = const {},
    this.textEdits = const {},
    this.condensed = const {},
    this.pairs = const [],
    this.partOrder = const [],
    this.sections = const {},
    this.groupSections = false,
    this.barNumbers = true,
    this.playheadColor,
    this.colorNames = false,
    this.nameColors = const {},
    this.nameGroups = const [],
    this.nameGroupOf = const {},
    this.patches = const [],
    this.captions = const [],
    this.captionFont,
    this.fonts = ScoreFonts.standard,
    this.embedFont = true,
    this.engraving = const EngravingOptions(),
    this.extensions = const {},
    this.textDynamics,
    this.rehearsalInRow,
    this.centeredLyrics,
    this.spacers = const [],
    this.gaps = const [],
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

  /// How the score moves (Project Settings ▸ Advanced, [CuratedScene.motion]); null: the app's
  /// default (Save as default).
  final ScoreMotion? motion;

  /// How the score's texts look (Project Settings ▸ Typography; the engraved ones in the
  /// engraving, the rest in [CuratedScene.typography]); null: the app's default (Save as default).
  final ScoreTypography? typography;

  /// The tempo track: where the score is pinned to the recording (warps among them), and the
  /// start before any anchor.
  final List<SyncAnchor> anchors;
  final double leadIn;

  /// The MIDI tempo map the sync follows instead of [anchors] (which are kept for when it
  /// goes), its start at [leadIn]; null: the anchors.
  final MidiTempoMap? midi;

  /// Every recording of the score, in the order the menu lists them; the sync above is the one
  /// [heard]'s (its own fields here left blank), each other's is its own. Adding, removing and
  /// switching recordings are no Undo steps: they change every state Undo keeps alike.
  final List<Take> takes;

  /// The [Take.id] of the recording heard; null when there is none.
  final String? heard;

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

  /// The playback line's colour (Project Settings ▸ Instruments); null: the score's own blue ([RenderStyle.pointer]).
  final Color? playheadColor;

  /// Whether the instruments are named in their family's colour (Project Settings ▸
  /// Instruments, [CuratedScene.nameColors]).
  final bool colorNames;

  /// The colours the user gave some families' groups; the others are [defaultNameColors]'.
  final Map<InstrumentFamily, Color> nameColors;

  /// Groups of the user's own, besides the families' (which can't be removed).
  final List<NameGroup> nameGroups;

  /// The group the user put some instruments in, by part id: a family's name or a
  /// [NameGroup.id]; null: none, named in the ink. Others are in their family's.
  final Map<String, String?> nameGroupOf;

  /// Images on the score (Attach Image), bottom to top.
  final List<ImagePatch> patches;

  /// Captions under the score (Captions), in the order they were added.
  final List<Caption> captions;

  /// Vertical spacers (Attach Image): staves of nothing, each an instrument of its own, in the
  /// order they were added.
  final List<VerticalSpacer> spacers;

  /// Horizontal spacers (Attach Image): blanks between beats, in the score's order.
  final List<HorizontalSpacer> gaps;

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

  /// The extensions this project turned on or off (Project Settings ▸ Extensions), by
  /// [CuratorExtension.id]; one left out follows the app's.
  final Map<String, bool> extensions;

  /// Whether dynamics written as text are engraved as dynamics (Project Settings ▸ Flags,
  /// [TextDynamics]); null: the app's (Save as default).
  final bool? textDynamics;

  /// Whether, while [barNumbers] are shown, the rehearsal marks show at their bars in that row,
  /// out of the music (Project Settings ▸ Flags, [CuratedScene.rehearsalInRow]); null: the app's.
  final bool? rehearsalInRow;

  /// Whether each syllable is centred under its notehead, but one an extender follows (Project
  /// Settings ▸ Flags, [EngraveRequest.centeredLyrics]); null: the app's.
  final bool? centeredLyrics;

  @override
  bool operator ==(Object other) =>
      other is EditState &&
      transition == other.transition &&
      scrollFollow == other.scrollFollow &&
      motion == other.motion &&
      typography == other.typography &&
      leadIn == other.leadIn &&
      midi == other.midi &&
      heard == other.heard &&
      listEquals(takes, other.takes) &&
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
      playheadColor == other.playheadColor &&
      colorNames == other.colorNames &&
      mapEquals(nameColors, other.nameColors) &&
      listEquals(nameGroups, other.nameGroups) &&
      mapEquals(nameGroupOf, other.nameGroupOf) &&
      listEquals(patches, other.patches) &&
      listEquals(captions, other.captions) &&
      captionFont == other.captionFont &&
      fonts == other.fonts &&
      embedFont == other.embedFont &&
      engraving == other.engraving &&
      mapEquals(extensions, other.extensions) &&
      textDynamics == other.textDynamics &&
      rehearsalInRow == other.rehearsalInRow &&
      centeredLyrics == other.centeredLyrics &&
      listEquals(spacers, other.spacers) &&
      listEquals(gaps, other.gaps);

  @override
  int get hashCode => Object.hash(transition, leadIn, lanes?.length, anchors.length, partNames.length, textEdits.length);

  /// This state with the fields given instead of its own. A field that may be null is
  /// cleared by passing null ([lanes], [transition], [scrollFollow], [motion], [typography], [midi], [captionFont], [playheadColor],
  /// [textDynamics], [rehearsalInRow], [centeredLyrics]); left
  /// out, it stays.
  EditState copyWith({
    Object? lanes = _kept,
    Object? transition = _kept,
    Object? scrollFollow = _kept,
    Object? motion = _kept,
    Object? typography = _kept,
    List<SyncAnchor>? anchors,
    double? leadIn,
    Object? midi = _kept,
    List<Take>? takes,
    Object? heard = _kept,
    Map<String, PartName>? partNames,
    Map<String, String>? textEdits,
    Set<String>? condensed,
    List<PlayerPair>? pairs,
    List<String>? partOrder,
    Map<String, String?>? sections,
    bool? groupSections,
    bool? barNumbers,
    Object? playheadColor = _kept,
    bool? colorNames,
    Map<InstrumentFamily, Color>? nameColors,
    List<NameGroup>? nameGroups,
    Map<String, String?>? nameGroupOf,
    List<ImagePatch>? patches,
    List<Caption>? captions,
    Object? captionFont = _kept,
    ScoreFonts? fonts,
    bool? embedFont,
    EngravingOptions? engraving,
    Map<String, bool>? extensions,
    Object? textDynamics = _kept,
    Object? rehearsalInRow = _kept,
    Object? centeredLyrics = _kept,
    List<VerticalSpacer>? spacers,
    List<HorizontalSpacer>? gaps,
  }) =>
      EditState(
        lanes: identical(lanes, _kept) ? this.lanes : lanes as Map<String, List<Region>>?,
        transition: identical(transition, _kept) ? this.transition : transition as double?,
        scrollFollow: identical(scrollFollow, _kept) ? this.scrollFollow : scrollFollow as double?,
        motion: identical(motion, _kept) ? this.motion : motion as ScoreMotion?,
        typography: identical(typography, _kept) ? this.typography : typography as ScoreTypography?,
        anchors: anchors ?? this.anchors,
        leadIn: leadIn ?? this.leadIn,
        midi: identical(midi, _kept) ? this.midi : midi as MidiTempoMap?,
        takes: takes ?? this.takes,
        heard: identical(heard, _kept) ? this.heard : heard as String?,
        partNames: partNames ?? this.partNames,
        textEdits: textEdits ?? this.textEdits,
        condensed: condensed ?? this.condensed,
        pairs: pairs ?? this.pairs,
        partOrder: partOrder ?? this.partOrder,
        sections: sections ?? this.sections,
        groupSections: groupSections ?? this.groupSections,
        barNumbers: barNumbers ?? this.barNumbers,
        playheadColor: identical(playheadColor, _kept) ? this.playheadColor : playheadColor as Color?,
        colorNames: colorNames ?? this.colorNames,
        nameColors: nameColors ?? this.nameColors,
        nameGroups: nameGroups ?? this.nameGroups,
        nameGroupOf: nameGroupOf ?? this.nameGroupOf,
        patches: patches ?? this.patches,
        captions: captions ?? this.captions,
        captionFont: identical(captionFont, _kept) ? this.captionFont : captionFont as String?,
        fonts: fonts ?? this.fonts,
        embedFont: embedFont ?? this.embedFont,
        engraving: engraving ?? this.engraving,
        extensions: extensions ?? this.extensions,
        textDynamics: identical(textDynamics, _kept) ? this.textDynamics : textDynamics as bool?,
        rehearsalInRow: identical(rehearsalInRow, _kept) ? this.rehearsalInRow : rehearsalInRow as bool?,
        centeredLyrics: identical(centeredLyrics, _kept) ? this.centeredLyrics : centeredLyrics as bool?,
        spacers: spacers ?? this.spacers,
        gaps: gaps ?? this.gaps,
      );

  /// The take [id]; null when there is none.
  Take? take(String id) => takes.where((t) => t.id == id).firstOrNull;

  /// This state with [id] heard: the sync of the take heard until now goes into its take, and
  /// [id]'s comes out of its own. As it is when [id] is heard already, or isn't a take.
  EditState hearing(String id) {
    final to = take(id);
    if (to == null || id == heard) return this;
    return copyWith(
      takes: [
        for (final t in takes)
          if (t.id == heard)
            t.copyWith(anchors: anchors, leadIn: leadIn, midi: midi)
          else if (t.id == id)
            Take(t.id, t.label)
          else
            t,
      ],
      heard: id,
      anchors: to.anchors,
      leadIn: to.leadIn,
      midi: to.midi,
    );
  }

  /// This state with [take] added (not heard, unless it is the first).
  EditState adding(Take take) =>
      copyWith(takes: [...takes, take], heard: heard ?? take.id);

  /// This state without the take [id]; one heard leaves its sync to the sync as it is.
  EditState removing(String id) => copyWith(
        takes: [for (final t in takes) if (t.id != id) t],
        heard: heard == id ? null : heard,
      );
}

/// One recording of the score ([EditState.takes]): its name in the menu and its sync, how the
/// score lines up with it (blank while it is the one heard: the state's own sync is its).
@immutable
class Take {
  const Take(this.id, this.label, {this.anchors = const [], this.leadIn = 0, this.midi});

  /// `take-1`, `take-2`…, the same as long as the project keeps it.
  final String id;

  /// What the menu calls it (the file's name at first: "Karajan 1963").
  final String label;
  final List<SyncAnchor> anchors;
  final double leadIn;
  final MidiTempoMap? midi;

  Take copyWith({String? label, List<SyncAnchor>? anchors, double? leadIn, Object? midi = _kept}) => Take(
        id,
        label ?? this.label,
        anchors: anchors ?? this.anchors,
        leadIn: leadIn ?? this.leadIn,
        midi: identical(midi, _kept) ? this.midi : midi as MidiTempoMap?,
      );

  @override
  bool operator ==(Object other) =>
      other is Take &&
      other.id == id &&
      other.label == label &&
      other.leadIn == leadIn &&
      other.midi == midi &&
      listEquals(other.anchors, anchors);

  @override
  int get hashCode => Object.hash(id, label, leadIn, anchors.length);
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

/// A group of instruments the user made (Project Settings ▸ Instruments): their names are
/// drawn in its colour.
@immutable
class NameGroup {
  const NameGroup(this.id, this.name, this.color);

  /// `group-1`, `group-2`…: never a family's name.
  final String id;
  final String name;
  final Color color;

  NameGroup copyWith({String? name, Color? color}) => NameGroup(id, name ?? this.name, color ?? this.color);

  @override
  bool operator ==(Object other) => other is NameGroup && other.id == id && other.name == name && other.color == color;

  @override
  int get hashCode => Object.hash(id, name, color);
}

/// A group as Project Settings ▸ Instruments shows it: a family's ([family] set; it can't be
/// removed) or the user's ([NameGroup]).
typedef NameGroupInfo = ({String id, String name, Color color, InstrumentFamily? family});

/// Everything a project stores besides the score and the recording: the edits, the image files
/// they show, and the view. Saved as modules ([ProjectModules]: `modules/<id>.json` in the
/// project), each checked field by field as it is read.
@immutable
class ProjectState {
  const ProjectState({this.edits = const EditState(), this.images = const {}, this.view = const ViewState(), this.foreign = const {}});

  final EditState edits;

  /// The image files [EditState.patches] show, by [PatchImage.id]. Not in the JSON: the
  /// project file keeps each as `images/<id>`.
  final Map<String, PatchImage> images;

  final ViewState view;

  /// Modules this build can't read that the project says may go unread (a newer version's),
  /// by id: kept as they came, so saving here doesn't lose them.
  final Map<String, ForeignModule> foreign;

  ProjectState copyWith({EditState? edits, Map<String, PatchImage>? images, ViewState? view, Map<String, ForeignModule>? foreign}) =>
      ProjectState(edits: edits ?? this.edits, images: images ?? this.images, view: view ?? this.view, foreign: foreign ?? this.foreign);
}

/// A module a newer version wrote that this one can't read, as it came: its JSON
/// (`modules/<id>.json`) and its files (under `<id>/`, by entry name).
@immutable
class ForeignModule {
  const ForeignModule({required this.version, required this.json, this.files = const {}});

  final int version;
  final Uint8List json;
  final Map<String, Uint8List> files;
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

  /// [value] as numbers: [count] of them, the last [optional] of which may be null or left out
  /// (`[start, end]`, `[start, end, in, out]`). Each is no bigger than [maxNumber] either way.
  static List<double?> numbers(Object? value, String where, int count, {int optional = 0}) {
    if (value is! List || value.length < count - optional || value.length > count) {
      throw FormatException('The project is damaged: $where is not ${count - optional == count ? count : '${count - optional} to $count'} numbers.');
    }
    return [
      for (var i = 0; i < count; i++)
        switch (i < value.length ? value[i] : null) {
          null when i >= count - optional => null,
          final num n when n.abs() <= maxNumber => n.toDouble(),
          _ => throw FormatException('The project is damaged: $where[$i] is not a number in range.'),
        },
    ];
  }
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
