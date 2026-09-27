# Architecture

How Curated Score is put together, and the rules that keep it working. Read this before
changing how a score is engraved, what a project stores, or how edits are made.

## The two packages

**`packages/score_engine`** knows music and drawing, nothing about the app's UI:

| File | Job |
|---|---|
| `src/verovio_bridge.cpp` | A Verovio device context that records drawing calls (paths, glyphs, text) per staff, plus measures, onsets and clef/key/time signatures, behind a C API |
| `engraving_options.dart` | The Verovio options the user may change (Settings ▸ Advanced ▸ Engrave Option, by code name) and the house style's values for them |
| `lib/src/native/bindings.dart`, `engraving.dart` | FFI bindings; `Engraver.engrave` runs Verovio on an isolate and copies everything into plain Dart data (`EngravingData`) |
| `score_metadata.dart`, `score_text.dart` | What the MusicXML says: parts, staves, meters, where each part plays; the editable texts, with text edits applied before engraving |
| `beat_grid.dart` | Where the beats fall in every bar (see *Beats*), and `bar.beat` positions |
| `curation.dart`, `auto_curate.dart` | When each instrument is shown: one lane of regions per part |
| `condensing.dart` | Pairs of players (Flute 1 + 2) that can share a staff, and the shared part written for each |
| `sync_map.dart` | The tempo track: anchors pinning score positions to recording times |
| `scroll_map.dart` | Playback time → the score x under the pointer |
| `spacing_plan.dart`, `staff_stack.dart` | The vertical layout, planned per curation segment |
| `display_list.dart`, `frozen_zone.dart`, `score_renderer.dart` | Drawable items per staff; the clef/key/time column; tile-cached drawing |
| `curated_scene.dart` | `LoadedScore` (engraved, ready) and `CuratedScene`: one frame is `paint(time)` |

**`app/`** is the editor around it:

| File | Job |
|---|---|
| `editor_controller.dart` | The open document: score, curation, sync, names, texts; loading, Undo, project state |
| `editor/playback.dart`, `editor/lane_editing.dart`, `editor/sync_editing.dart` | Parts of the controller: the clock and transport; the Instruments tab's tools and selection; the Audio tab's tapping and anchor selection |
| `project_state.dart`, `edit_history.dart` | What a project stores (typed, validated, versioned); Undo's snapshots |
| `project_file.dart`, `project_document.dart` | The `.ccs` format; the document around it (path, dirty state, autosave) |
| `audio_track.dart`, `audio_format.dart`, `media_converter.dart` | Playback (SoLoud), the waveform and onsets, converting to FLAC; `MediaFormats` lists what is accepted |
| `video_export.dart`, `export_dialog.dart` | Video export: frames from `CuratedScene.renderFrame` piped to FFmpeg as raw RGBA, out as H.264/AAC MP4; the dialog |
| `scratch_space.dart` | Where temporary files go (see *Scratch files*) |
| `main.dart`, `*_panel.dart`, `score_view.dart`, `editor_toolbar.dart`, … | The UI |

## Rules

**A frame is a function of time.** `CuratedScene.paint(time)` draws everything from the
curation, the sync and the time alone; nothing accumulates between frames. That is what lets
the preview scrub freely, and what video export reuses: frame *i* is `renderFrame(i / fps)`,
the same painting offscreen. `VideoExport` works on its own scene and copies of the curation
and sync, so something the scene shows must be copied in `VideoExport.of` too (as `names` is).
A video is laid out like a preview `VideoFormat.layoutHeight` (540) points high at
`height / 540` pixels a point, so every size frames the score the same way.

**Beats come from `BeatGrid`, never "a quarter note".** Compound meters beat in dotted notes
(6/8 has two beats), additive ones in their groups (2+2+3/8 has three), upbeats count back
from the barline. Snapping, tapping, the scroll map's anchors, the tempo lane and every
`12.2` position (`BeatGrid.format` / `parse`) go through it.

**Lanes are painted, not cut.** Drawing adds a region and merges it with what it touches;
erasing trims. Touching regions are merged on purpose: a seam between two regions would dip
the staff's fade. During a drag regions may overlap (`Curation.updateLanes`); `normalize`
merges them when the drag ends.

**Widgets change the document only through `EditorController`** (and its parts). They may
read the models (`curation`, `sync`) to draw them.

**One Undo for the whole document.** After every change the controller compares the
document's `EditState` (lanes, transition, anchors, lead-in, names, text edits) with the last
one recorded; a difference is one step. A gesture is one step: wrap it in `beginEdit` /
`endEdit`. The models keep no history of their own. View settings (staff size, grid, playhead)
are not edits.

**Condensing adds staves; it never moves any.** Each pair of players that can share a staff
(the built-in ones, and the user's own: `CondensingOptions.pairs`, where the user's win)
gets a part of its own, written into the MusicXML before engraving (after the text edits,
so it copies them) and appended after every other part, so every staff number stays as it
was. Verovio engraves it in the same system as the rest, so it lines up with them. The
shared staves are always engraved; which pairs are condensed is an edit (`condensed` in
the project and in `EditState`), and switching it only re-plans the layout. The user's
pairs (`pairs`, format 3) are an edit too, but change the engraving: making or removing one
re-engraves, as a text edit does, while the lanes follow at once (the pairs are known
without engraving). The scene shows
a shared staff while both players are shown, and the player's own staff otherwise; a hidden
one waits on its twin (`SpacingPlan`'s `twins`), so they swap in place. Its texts carry the
`cond-` prefix, and `Condenser.sourceTextId` leads back to the original, so editing one edits
the other. A slur or hairpin in a shared part keeps both of its ends or neither. Any two
single-staff instruments with the same clefs, transposition and meters throughout can pair
(`Condenser._writtenAs`: every change of those, where it takes effect, read for what it
means): the shared part takes the first player's attributes, and where the second is
written in another key its bars are spelled again against the first's (`Condenser._respell`). A
condensed pair is one lane: `Curation.join` keeps the second player's lane equal to the
first's (an edit of either is an edit of both; joining unites them), and the Instruments tab
shows only the first (`EditorController.laneParts`), named for both.

**Opening is all or nothing.** A project is read and validated (`ProjectState.fromJson`),
then engraved, and only then swapped in, in one synchronous step. If anything before the swap
fails, what was open stays open, with its path — so a later save can't write one project
over another. A recording that fails to load is reported, not fatal.

**The project format changes with a version.** `project.json`'s `state` is written by
`ProjectState.toJson`. To change it: bump `ProjectState.version`, and add a migration from the
old version in `ProjectState._migrations`, so older files still open. Reading checks every
field and names the damaged one.

**The C and Dart structs must match.** `VBCommand` is read from Dart as 4-byte words (`Cmd`
in `engraving.dart`). The bridge `static_assert`s every field's word index, and
`Engraver` compares every struct's size with the library's (`vb_struct_size`) before reading.
Change both sides together.

**Verovio is pinned and patched.** `make setup` clones the tagged release and applies
`patches/*.patch` from a clean tree whenever a patch changes; the build hook refuses to build
while a patch is newer than the tree. Patches: per-part key changes (transposing instruments
keep their written key), and MusicXML direction ids (so texts can be edited). Mark changes in
Verovio's code with `[curated-score patch]`.

**Engraving options: offered ones only, the layout ones fixed.** The bridge
(`vb_engraver_create`) fixes what the curated view relies on: one endless system (`breaks`
none), no header, footer or page margins, `scale` 100. Dart then sends every option in
`EngraveOption.all`, with the house style's value unless the user changed it (Settings ▸
Advanced, app-wide, in `AppSettings`; not part of a project, not an edit), so the house style
lives in that list alone. Only its options are ever sent, so none of the fixed ones can be
overridden; none may change the bars or the staves (`expand`, `transpose`, `mdiv*` stay out).
Their types, ranges and choices are checked against Verovio's own list
(`Engraver.availableOptions`); an out-of-range value would be dropped by Verovio without a
word. Changing them re-engraves the open score, as a text edit does.

**Colours are chosen when drawing.** The engraving is recorded as ink only; the renderer
tints tiles, names and the frozen zone with the ink colour as it composites them
(`paint(paper:, ink:)`), so a theme change (or its cross-fade) never re-rasterises anything.
The app passes the theme's `scorePaper` / `scoreInk`.

**Overlays keep their parent in the accessibility tree.** Tooltips and sliders draw their
overlay (the tip, the slider's value) through an `OverlayPortal`, and for accessibility that
overlay hangs from the widget that shows it. Flutter loses the link when two such widgets
share a semantics node (flutter/flutter#182444), and when the widget is faded to opacity 0,
which drops its semantics but not its overlay (a `Slider`'s is always there,
flutter/flutter#190357). The overlay is then sent with no parent, the desktop engine rejects
the update ("Failed to update ui::AXTree" in `make run`), and its tree stays broken. So:
`Tip`, never `Tooltip` (and `ToolbarButton` for icon buttons); a `Slider` inside
`OverlaySemantics`; `showAppDialog`, never `showDialog`; and a fade over any of them keeps its
semantics (`alwaysIncludeSemantics: true`). `test/accessibility_tree_test.dart` replays every
update through a model of the engine's tree (`test/accessibility_mirror.dart`).

**Fonts: engraving and drawing agree.** Verovio lays out with the metrics of the same fonts
the renderer draws: Bravura for music (`assets/verovio/Bravura.xml`; Leipzig's metrics are
there because Verovio always loads them), Academico for text (metrics written under Verovio's
`Times*` names by `Tools/make_text_metrics.swift`).

**Scratch files.** Everything temporary goes under `ScratchSpace`: one folder per running
app, locked while it runs. Jobs release their folders when done (a replaced recording's
converted audio, a closed project's unpacked media), the app deletes its folder when it quits,
and at start-up it sweeps folders whose lock is free (their app crashed).

**Tests run on the demo.** Every test uses `app/assets/demo/WI275 - 01 Intro.ccs` (a 44-bar
6/8 orchestral intro with its recording and curation), so a fresh clone runs them all. The
engine tests build variants of it where they need something it lacks (a key change, an
additive meter). `Samples/` is for trying things by hand only.

## Adding things

- **A setting**: an `_Item` in `settings_dialog.dart`'s `_categories`, backed by a field in
  `AppSettings`.
- **Something a project saves**: a field in `ProjectState` (and `EditState` if Undo should
  cover it), written in `toJson`, read in `fromJson`; bump the version with a migration if
  older files need converting.
- **A Verovio change**: edit `third_party/verovio`, then
  `git -C packages/score_engine/third_party/verovio diff > patches/verovio-curated-score.patch`,
  then `make setup` (it re-applies the patches from a clean tree, and records that it did).
