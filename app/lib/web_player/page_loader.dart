import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:score_engine/score_engine.dart';

import '../image_patch.dart';
import '../project_archive.dart';
import '../project_file.dart' show ProjectFile;
import '../project_modules.dart';
import '../project_state.dart';
import '../web_page.dart';

/// A page as the player shows it: what [WebPage] describes, read and made ready to draw.
class LoadedPage {
  LoadedPage._(this.page, this.score, this.edits, this.arts);

  final WebPage page;
  final LoadedScore score;

  /// The exported project's edits: every setting its own.
  final EditState edits;

  /// Each image's drawing, by [PatchImage.id].
  final Map<String, PatchArt> arts;

  /// Reads the page in [WebPage.folder]: [fetch] gets a file by its path there. Throws a
  /// [FormatException] when something isn't what the export writes.
  static Future<LoadedPage> load(Future<Uint8List> Function(String path) fetch) async {
    final [pageBytes, projectBytes, engravingBytes] =
        await Future.wait([fetch(WebPage.pageFile), fetch(WebPage.projectFile), fetch(WebPage.engravingFile)]);
    final page = WebPage.fromJson(jsonDecode(utf8.decode(pageBytes)));

    const damaged = 'The page’s project is damaged.';
    final archive = ZipDecoder().decodeBytes(projectBytes);
    final manifest = ProjectArchive.manifestOf(archive, mimeType: ProjectFile.mimeType, notOurs: damaged, newer: damaged);
    final state = ProjectArchive.read(archive, manifest, ProjectModules.all, newer: damaged, keepForeign: false);
    final scoreFile = archive.findFile(WebPage.scoreEntry) ?? (throw const FormatException(damaged));
    final musicXML = utf8.decode(scoreFile.content);
    final edits = state.edits;

    // The fonts first: the score is measured and drawn in them.
    await edits.fonts.music.load();
    for (final f in page.fonts) {
      for (final file in f.files) {
        await ui.loadFontFromList(await fetch(file), fontFamily: f.family);
      }
    }
    final score = LoadedScore.engraved(musicXML, WebPage.requestOf(edits), EngravingFile.read(engravingBytes),
        textFontFound: page.fonts.any((f) => f.family == TextFonts.familyOf(edits.fonts.text)) || edits.fonts.text == TextFonts.academico);
    final arts = <String, PatchArt>{};
    for (final MapEntry(key: id, value: image) in state.images.entries) {
      try {
        arts[id] = await image.decode();
      } on FormatException {
        // Not drawn: the rest of the page still is.
      }
    }
    return LoadedPage._(page, score, edits, arts);
  }

  /// The scene's settings, with captions and bar numbers on or off as the viewer has them.
  SceneSettings settings({required bool captions, required bool barNumbers}) => SceneSettings(
        names: edits.partNames,
        condensed: edits.condensed,
        partOrder: edits.partOrder,
        scrollFollow: edits.scrollFollow ?? 1,
        motion: edits.motion ?? ScoreMotion.standard,
        typography: edits.typography ?? ScoreTypography.standard,
        patches: [
          for (final p in edits.patches)
            if (arts[p.image] case final art?) p.scene(art),
        ],
        captions: captions && (edits.extensions['captions'] ?? false) ? edits.captions : const [],
        captionStyle: page.captionStyle,
        sections: edits.groupSections,
        sectionOverrides: edits.sections,
        barNumbers: barNumbers && edits.barNumbers,
        rehearsalInRow: edits.rehearsalInRow ?? true,
        nameColors: page.nameColors,
        pointerColor: edits.playheadColor,
        spacers: edits.spacers,
      );

  /// The lanes as exported, each instrument in [shown] always or never shown instead.
  Curation curation(Map<String, PartShown> shown) {
    final end = score.timeline.measureStarts.last;
    final curation = Curation({for (final p in score.metadata.parts) p.id, for (final s in edits.spacers) s.id})
      ..load({...?edits.lanes}, transition: edits.transition);
    for (final MapEntry(key: id, value: how) in shown.entries) {
      if (how == PartShown.curated || !curation.partIds.contains(id)) continue;
      curation.setLane(id, how == PartShown.shown ? [Region(0, end)] : const []);
    }
    curation.join({
      for (final g in score.condensing.pairs(edits.pairs))
        if (edits.condensed.contains(g.id)) g.second: g.first,
    });
    return curation;
  }

  /// What [recording] plays to: the takes spliced by their lanes, or its take whole in its own
  /// time, as the editor plays them; cut to the page's bars.
  ScoreTimeline timeline(WebRecording recording) {
    SyncMap sync(List<SyncAnchor> anchors, double leadIn) =>
        SyncMap(measureStarts: score.timeline.measureStarts, defaultTempo: score.metadata.tempo ?? 100, beats: score.beats)
          ..load(anchors, leadIn: leadIn);
    final focus = sync(edits.anchors, edits.leadIn), takes = edits.takes;
    SyncMap of(Take t) => t.id == edits.focus ? focus : sync(t.anchors, t.leadIn);
    final ScoreTimeline whole = switch (recording.take) {
      final id? => of(takes.firstWhere((t) => t.id == id)),
      null when takes.length > 1 => TakeSplice(
          takes: [for (final t in takes) of(t)],
          lanes: [for (final t in takes) t.regions],
          crossfade: edits.crossfade ?? EditState.defaultCrossfade,
        ),
      null => focus,
    };
    final bars = whole.measureStarts.length - 1;
    if (page.firstBar == 1 && page.lastBar == bars) return whole;
    return ClippedTimeline.bars(whole, page.firstBar, page.lastBar)?.timeline ?? whole;
  }
}
