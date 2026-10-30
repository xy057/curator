import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:score_engine/score_engine.dart';

import 'project_state.dart';

/// A score as a web page (File ▸ Export to Web…): what the export writes in [folder] beside the
/// web player (`lib/web_player/`), and the player reads. The page shows the project as it was
/// exported: [projectFile], a project of its own (the modules a `.ccs` has, stored, with every
/// setting the app supplies made the project's and the syncs as anchors); [engravingFile], the
/// score engraved ([EngravingFile]), since a browser has no engraver; and [pageFile], this.
@immutable
class WebPage {
  const WebPage({
    required this.title,
    required this.staffSpace,
    required this.ratio,
    required this.firstBar,
    required this.lastBar,
    required this.recordings,
    required this.captionStyle,
    this.nameColors = const {},
    this.fonts = const [],
    this.instruments = const WebChoice({}),
    this.recording = const WebChoice(0),
    this.captions = const WebChoice(true),
    this.barNumbers = const WebChoice(true),
    this.speed = const WebChoice(1.0),
  });

  static const format = 'application/x-curator-web', version = 1;
  static const folder = 'score', pageFile = 'page.json', projectFile = 'project.ccs', engravingFile = 'engraving.bin';

  /// Where [projectFile] keeps the MusicXML.
  static const scoreEntry = 'score/score.musicxml';

  final String title;

  /// The score size, as in the editor's toolbar.
  final double staffSpace;

  /// The frame's width : height ([VideoFrame.fit]); null: the page's whole window.
  final double? ratio;

  /// The bars it shows, from 1 (all of them: 1 and the last); fewer are played as a video of
  /// them is ([ClippedTimeline.bars]).
  final int firstBar, lastBar;

  /// The ways to hear it, the first the performance as the lanes splice the recordings (one,
  /// silent, without a recording).
  final List<WebRecording> recordings;

  /// The Captions extension's look (the app's setting), its font among [fonts].
  final CaptionStyle captionStyle;

  /// Each instrument's name colour, by part id, as the editor resolves them.
  final Map<String, Color> nameColors;

  /// Text fonts the page registers before it draws (an installed text or caption font): each a
  /// family, as the scene names it, and its files, beside this.
  final List<({String family, List<String> files})> fonts;

  /// What the viewer sees at first, and whether they may change it:
  /// each instrument as the lanes show it, always or never (by part id; one left out: as curated);
  final WebChoice<Map<String, PartShown>> instruments;

  /// which of [recordings] plays;
  final WebChoice<int> recording;

  /// captions and bar numbers on or off (only where the project has them);
  final WebChoice<bool> captions, barNumbers;

  /// and how fast it plays (pitch kept).
  final WebChoice<double> speed;

  /// The speeds a viewer may pick.
  static const speeds = [0.5, 0.75, 1.0, 1.25, 1.5];

  Map<String, Object?> toJson() => {
        'format': format,
        'version': version,
        'title': title,
        'staffSpace': staffSpace,
        'ratio': ratio,
        'bars': [firstBar, lastBar],
        'recordings': [for (final r in recordings) r.toJson()],
        'captionStyle': {
          'fontFamily': captionStyle.fontFamily,
          'countdown': captionStyle.countdown.name,
          'size': captionStyle.size.name,
          'align': captionStyle.align.name,
          'plate': captionStyle.plate,
        },
        'nameColors': {for (final MapEntry(:key, :value) in nameColors.entries) key: value.toARGB32()},
        'fonts': [for (final f in fonts) {'family': f.family, 'files': f.files}],
        'viewer': {
          'instruments': instruments.toJson({for (final MapEntry(:key, :value) in instruments.value.entries) key: value.name}),
          'recording': recording.toJson(recording.value),
          'captions': captions.toJson(captions.value),
          'barNumbers': barNumbers.toJson(barNumbers.value),
          'speed': speed.toJson(speed.value),
        },
      };

  /// Reads what [toJson] wrote. Throws a [FormatException] when it isn't that.
  static WebPage fromJson(Object? json) {
    try {
      final j = json as Map<String, Object?>;
      if (j['format'] != format) throw const FormatException('This isn’t a Curator page.');
      if ((j['version'] as num) > version) throw const FormatException('This page is from a newer Curator.');
      final style = j['captionStyle'] as Map<String, Object?>, viewer = j['viewer'] as Map<String, Object?>;
      T named<T extends Enum>(List<T> values, Object? name) => values.byName(name as String);
      final [first, last] = [for (final n in j['bars'] as List<Object?>) (n as num).toInt()];
      return WebPage(
        title: j['title'] as String,
        staffSpace: (j['staffSpace'] as num).toDouble(),
        ratio: (j['ratio'] as num?)?.toDouble(),
        firstBar: first,
        lastBar: last,
        recordings: [for (final r in j['recordings'] as List<Object?>) WebRecording.fromJson(r as Map<String, Object?>)],
        captionStyle: CaptionStyle(
          fontFamily: style['fontFamily'] as String?,
          countdown: named(CaptionCountdown.values, style['countdown']),
          size: named(CaptionSize.values, style['size']),
          align: named(CaptionAlign.values, style['align']),
          plate: style['plate'] as bool,
        ),
        nameColors: {
          for (final MapEntry(:key, :value) in (j['nameColors'] as Map<String, Object?>).entries) key: Color(value as int),
        },
        fonts: [
          for (final f in (j['fonts'] as List<Object?>).cast<Map<String, Object?>>())
            (family: f['family'] as String, files: (f['files'] as List<Object?>).cast<String>()),
        ],
        instruments: WebChoice.fromJson(viewer['instruments'], (v) => {
              for (final MapEntry(:key, :value) in (v as Map<String, Object?>).entries) key: named(PartShown.values, value),
            }),
        recording: WebChoice.fromJson(viewer['recording'], (v) => (v as num).toInt()),
        captions: WebChoice.fromJson(viewer['captions'], (v) => v as bool),
        barNumbers: WebChoice.fromJson(viewer['barNumbers'], (v) => v as bool),
        speed: WebChoice.fromJson(viewer['speed'], (v) => (v as num).toDouble()),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      // A wrong type, a missing field, an unknown name: TypeError, ArgumentError, StateError.
      throw const FormatException('The page is damaged.');
    }
  }

  /// What a score with [edits] (an exported project's: every setting its own) is engraved with.
  static EngraveRequest requestOf(EditState edits) => EngraveRequest(
        textEdits: edits.textEdits,
        pairs: edits.pairs,
        fonts: edits.fonts,
        options: edits.engraving,
        textDynamics: edits.textDynamics ?? true,
        typography: edits.typography ?? ScoreTypography.standard,
        centeredLyrics: edits.centeredLyrics ?? false,
        spacers: edits.spacers,
        gaps: edits.gaps,
      );
}

/// What the export sets for the viewer: its [value], and whether they may change it.
@immutable
class WebChoice<T> {
  const WebChoice(this.value, {this.open = false});
  final T value;
  final bool open;

  WebChoice<T> copyWith({T? value, bool? open}) => WebChoice(value ?? this.value, open: open ?? this.open);

  Map<String, Object?> toJson(Object? json) => {'value': json, 'open': open};

  static WebChoice<T> fromJson<T>(Object? json, T Function(Object? value) read) {
    final j = json as Map<String, Object?>;
    return WebChoice(read(j['value']), open: j['open'] as bool);
  }
}

/// How an instrument shows on a page: as its lane says, always, or never.
enum PartShown { curated, shown, hidden }

/// A way to hear a page: [take] heard whole in its own time, or (null) the performance as the
/// lanes splice the recordings. Its sound is [audio] (beside the page; none: silent), seconds
/// [start]…[end] of the performance; its music ends at [musicEnd], then the score comes to rest
/// and fades.
@immutable
class WebRecording {
  const WebRecording({required this.label, required this.take, required this.audio, required this.start, required this.end, required this.musicEnd});
  final String label;
  final String? take;
  final String? audio;
  final double start, end, musicEnd;

  Map<String, Object?> toJson() => {'label': label, 'take': take, 'audio': audio, 'start': start, 'end': end, 'musicEnd': musicEnd};

  static WebRecording fromJson(Map<String, Object?> j) => WebRecording(
        label: j['label'] as String,
        take: j['take'] as String?,
        audio: j['audio'] as String?,
        start: (j['start'] as num).toDouble(),
        end: (j['end'] as num).toDouble(),
        musicEnd: (j['musicEnd'] as num).toDouble(),
      );
}
