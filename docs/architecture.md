# Architecture

How Curator is put together, and the rules that keep it working. Read this before
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
| `sync_map.dart` | The tempo track: anchors pinning score positions to recording times, and warps (anchors that jump) |
| `scroll_map.dart` | Playback time → the score x under the pointer: beat to beat, every onset on time, or a blend |
| `spacing_plan.dart`, `staff_stack.dart` | The vertical layout and the frozen zone's key column (as wide as the shown staves need), planned per segment |
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
| `updater.dart` | Settings ▸ Update: `appVersion`, the latest GitHub release, its download into Downloads |
| `main.dart`, `*_panel.dart`, `score_view.dart`, `editor_toolbar.dart`, … | The UI |

## Rules

**A frame is a function of time.** `CuratedScene.paint(time)` draws everything from the
curation, the sync and the time alone; nothing accumulates between frames. That is what lets
the preview scrub freely, and what video export reuses: frame *i* is `renderFrame(i / fps)`,
the same painting offscreen. `VideoExport` works on its own scene and copies of the curation
and sync, so something the scene shows must be copied in `VideoExport.of` too (as `names` is).
A video has any ratio (`VideoRatio`: a preset or one typed, 1:4 to 4:1, chosen in the
toolbar beside the frame toggle, which choosing one turns on); its size
(`VideoResolution`, "1080p") is its short side in pixels. It is laid out like a preview
`VideoFormat.layoutShortSide` (540) points on its short side (`VideoFormat.layoutOf`) at
`shortSide / 540` pixels a point, so every size frames the score the same way, and a tall
video draws it as big as a wide one, with room for more staves. The editor's preview fills
the window by default; the toolbar's frame toggle (`AppSettings.previewVideoFrame`) makes it
that frame too: `ScoreView` letterboxes `AppSettings.videoFormat`'s aspect ratio, laid out
the same way and scaled to fit (`VideoFrame.fit`; filling is `VideoFrame.fill`), so the
window's size never changes what the score shows. Hit tests go through `VideoFrame.toLayout`.

**Beats come from `BeatGrid`, never "a quarter note".** Compound meters beat in dotted notes
(6/8 has two beats), additive ones in their groups (2+2+3/8 has three), upbeats count back
from the barline. Snapping, tapping, the tempo lane and every
`12.2` position (`BeatGrid.format` / `parse`) go through it.

**The scroll follows the beats, the notes, or a blend.** `ScrollMap.follow` (Settings ▸
Animation ▸ Scrolling, `AppSettings.scrollFollow`, app-wide, 0.4 by default, copied into video export) runs
from 0, beats, to 1, notes. At 0 (as before 0.2) every beat of the time signature is under the
pointer as it sounds and a monotone cubic (Fritsch–Carlson) glides between them. At 1 every
onset the engraving records (a note or rest starting in any staff) is; engraved spacing grows
far more slowly than duration, so the speed changes even at one tempo: slow through long
notes, quicker through runs, and quick across room no note owns (a barline, a key change).
Between onsets only the speed is free, and it is the curve with the least acceleration
relative to its speed (a natural spline weighted by 1 / speed², `_Curve._tangentsOf`), held
above a quarter of each stretch's mean speed so the score never stalls or runs back. In
between, x is the weighted mean of the two curves: both put every beat on time and never run
back, so the blend does too. The anchors are read when the map is built; changing `follow`
(`withFollow`) reuses them, and each curve is solved once, when first used.

**A place in the score can sound more than once.** A warp is an anchor that jumps: the
score arrives at `quarter` and, at that same moment, goes on from `jumpTo` (back for a
repeat, on to a coda). The performance is then a list of `ScoreTimeline.passes`, stretches
played straight through. A time is always at one place (`quarterAtSeconds`), but a place
sounds once per pass that plays it, so asking when something sounds takes a pass:
`secondsAtQuarter(q, pass: k)`, or `spans` / `timesOf` for every time. The scroll map has a
curve per pass, a lane's fades are per pass (joined across a warp while still shown), and the
timeline draws bars and regions per pass. Inside, `SyncMap` works on the performed position,
which a warp doesn't interrupt, so the tempo runs on through a jump. Changing a jump moves
the anchors after it (up to the next warp) with it, keeping their times (`SyncMap.setJump`).
Anchors are kept in time order, each arriving further on than the one before went on from.

**Lanes are painted, not cut.** Drawing adds a region and merges it with what it touches;
erasing trims. Touching regions are merged on purpose: a seam between two regions would dip
the staff's fade. During a drag regions may overlap (`Curation.updateLanes`); `normalize`
merges them when the drag ends.

**A region carries its properties.** Besides its bounds a region has properties of its own
(so far its transitions: how long its staff glides in at its start, `Region.transitionIn`, and
out at its end, `transitionOut`; null is the project's, `Curation.transition`). Every edit that
reshapes a region keeps them (`withBounds`: moving, trimming, a split by erasing, copying a
lane); a merge keeps each edge's from the region it came from, else the other's
(`joinedWith`). They are part of the region's equality, so Undo, saving (`transitionIn` /
`transitionOut` on a region in the project, from format 6) and video export follow without
more code. The layout glides over each edge's own transition (the longest where edges fall
together; key changes and warps use the project's). A region's properties are set in its
dialog (double-click it), or at every selected edge at once in the Instruments tab's
toolbar (`LaneEditing.setTransition`). A selection is of edges: a click in a region's middle
selects the region (`RegionEdges.both`), a click on an edge only that edge
(`LaneEditing.selection`); moving and deleting take the regions, trimming (a drag, `[`/`]`)
and transitions only the edges selected. An edge with its own transition shows it beside it.

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

**The instruments' order is a layout, not an engraving.** Verovio engraves in score order,
but every staff is drawn on its own (brackets and system labels are left out), so the
preview stacks them in `CuratedScene.partOrder`: the user's order (hold a lane's name in the
Instruments tab and drag it, or its ⋯ menu), then any part it lacks in score order. Changing
it only re-plans the layout, like condensing. It is an edit (`partOrder` in `EditState`, and
in the project from format 5, empty for the score's order); the lanes follow it
(`EditorController.laneParts`), and a condensed pair moves as one.

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

## Releasing

`.github/workflows/release.yml` runs only when started by hand (GitHub ▸ Actions ▸ Release ▸
Run workflow, or `gh workflow run release.yml`). It builds with `make build` on macOS, zips the
app as `Curator-<version>-macos.zip` and publishes release `v<version>`, where the
version is `app/pubspec.yaml`'s. To release again, bump that version and `appVersion` in
`updater.dart` together (`updater_test.dart` checks they match); a version already released
stops the run before it builds. The app finds its download by that name
(`-macos.` in the asset's name). Releases are macOS only. The app is signed ad hoc, not notarized; the
release notes say how to open it the first time. The updater only downloads: it never
replaces the running app.

## Adding things

- **A setting**: an `_Item` in `settings_dialog.dart`'s `_categories`, backed by a field in
  `AppSettings`. Settings of first-party components that are not part of the main work
  (import, curate, sync, export) and matter less go under **Extension**.
- **Something a project saves**: a field in `ProjectState` (and `EditState` if Undo should
  cover it), written in `toJson`, read in `fromJson`; bump the version with a migration if
  older files need converting.
- **A Verovio change**: edit `third_party/verovio`, then
  `git -C packages/score_engine/third_party/verovio diff > patches/verovio-curated-score.patch`,
  then `make setup` (it re-applies the patches from a clean tree, and records that it did).
