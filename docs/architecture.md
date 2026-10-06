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
| `midi_tempo.dart` | A Standard MIDI File's tempo map (Set Tempo events only), and the anchors that make a `SyncMap` follow it |
| `scroll_map.dart` | Playback time → the score x under the pointer: beat to beat, every onset on time, or a blend; `ClippedTimeline`, part of a performance as if it were all |
| `spacing_plan.dart`, `staff_stack.dart` | The vertical layout and the frozen zone's key column (as wide as the shown staves need), planned per segment |
| `display_list.dart`, `frozen_zone.dart`, `score_renderer.dart` | Drawable items per staff; the clef/key/time column and braces; tile-cached drawing |
| `curated_scene.dart` | `LoadedScore` (engraved, ready) and `CuratedScene`: one frame is `paint(time)` |
| `score_fonts.dart`, `font_files.dart`, `src/font_metrics.cpp` | The music and text fonts (`ScoreFonts`): bundled SMuFL fonts, added ones, installed text fonts; the fonts installed (read from the font folders, `FontFiles`); Verovio's metrics for them, measured with stb_truetype (`FontResources`) |
| `score_patch.dart` | Images on the score (`ScenePatch`, drawn by a `PatchArt` the app supplies) and `ScoreAxis`: score quarters ↔ engraving x |
| `search.dart` | `segmentAt`: the binary search the timelines, grids and plans share |

**`app/`** is the editor around it:

| File | Job |
|---|---|
| `editor_controller.dart` | The open document: score, curation, sync, names, texts; loading, Undo, project state |
| `editor/playback.dart`, `editor/lane_editing.dart`, `editor/sync_editing.dart`, `editor/image_editing.dart` | Parts of the controller: the clock and transport; the Instruments tab's tools and selection; the Audio tab's tapping and anchor selection; images on the score (Attach Image) |
| `image_patch.dart` | Attach Image's model: `ImagePatch` (where an image sits), `PatchImage` (its file), SVG / PNG / JPEG drawing, the clipboard |
| `assets_dialog.dart` | Attach Image's Manage assets… (toolbar): the images a project keeps, where each is used, Remove, Purge unused |
| `fonts_dialog.dart` | Score ▸ Fonts…: the music and text font a project is engraved in |
| `project_state.dart`, `edit_history.dart` | What a project stores (typed, validated, versioned); Undo's snapshots |
| `project_file.dart`, `project_document.dart` | The `.ccs` format; the document around it (path, dirty state, autosave) |
| `audio_track.dart`, `audio_format.dart`, `media_converter.dart` | Playback (SoLoud), the waveform and onsets, converting to FLAC; `MediaFormats` lists what is accepted |
| `video_export.dart`, `export_dialog.dart` | Video export: frames from `CuratedScene.renderFrame` piped to FFmpeg as raw RGBA, out as H.264/AAC MP4; the dialog (a still to scrub, bars, ratio, size, frame rate, paper, score size) |
| `scratch_space.dart` | Where temporary files go (see *Scratch files*) |
| `updater.dart` | Settings ▸ About: `appVersion`, `appBuild`, `appCommit`, the latest GitHub release, its download into Downloads |
| `app_menus.dart` | The menu bar (native on macOS): File, Edit, Score. Edit's items are greyed out with nothing to do, and while a text field or a dialog has the keyboard, since on macOS a key Flutter leaves unhandled goes on to the menu |
| `main.dart`, `*_panel.dart`, `score_view.dart`, `editor_toolbar.dart`, … | The UI |

## Rules

**A frame is a function of time.** `CuratedScene.paint(time)` draws everything from the
curation, the sync and the time alone; nothing accumulates between frames. That is what lets
the preview scrub freely, and what video export reuses: frame *i* is `renderFrame(i / fps)`,
the same painting offscreen. `VideoExport` works on its own scene and copies of the curation
and sync, so something the scene shows must be copied in `VideoExport.of` too (as `names` is);
the decoded images it shares are held (`ImageEditing.hold`) until it is disposed, since the
menu bar can close the project under the export dialog.
A video is the whole piece unless the dialog's From bar / To bar say otherwise
(`VideoExport.showBars`, never saved), and then it is made as if the score were only those
bars: the export's scene follows a `ClippedTimeline`, the performance with its passes cut from
where the first bar first sounds to where the last next ends after that (a repeat's first
time). Times stay the performance's; everything that reads the passes takes the cut for the
score's ends, so the scroll comes to rest after the last bar and the frame fades to paper
(`CuratedScene.endOf`), and a lane shown at the first bar is shown from the start, with no
transition under way there. The music either side is still engraved, so the frame shows it.
Bar 1 starts at time 0 and the last bar runs to the end, so all the bars are exactly the whole
video. Frames are `renderFrame(start + i / fps)`; the sound is read from the start (`-ss`,
fading in over 10 ms) and fades out over the settle after the last bar.
The end is a function of time too: after the final barline the score eases to rest over
`ScrollMap.settle` seconds (its last bars stay on screen), and the frame fades to paper over the
last `CuratedScene.fadeOut` seconds before `paint`'s `end` (the playback's duration: the piece's
`CuratedScene.endOf`, or the recording if longer), in the preview as in a video.
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
So does Go to: a click on the toolbar's time or bar.beat (or ⌘G) types where to go,
a bar (`12`, `12.2`: where it first sounds) or a time (`1:10.5`, `1:02:03`), read by
`Playback.goTo`. Closing it hands the keyboard back to what had it, or the window's
shortcuts would stop (focus falls to the route's scope, above them).

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

**A MIDI file can stand in for the anchors.** Dropping a `.mid` on the Audio tab (or its MIDI
button) reads its tempo map (`MidiTempoMap.read`: tempo changes only; the beats still come
from the score) and the sync follows it: the file's start is bar 1 (or its upbeat), sounding
at Starts at, and `MidiTempoMap.anchors` puts an anchor at each change of tempo and at the
score's end, so the tempo between them is constant, as a sequencer plays it. Everything that
reads the sync (scroll, timeline, video export) then works unchanged. While it does, the
anchors are derived: `SyncEditing` edits nothing (its `_sync` is null), tapping is off, and
the Audio tab draws the tempo map large instead of the anchors and the waveform. The anchors
set by hand are kept behind it (`EditorController._tapped`, saved as `sync.anchors`) and come
back when the MIDI goes. Using or dropping one is an edit (`midi` in `EditState`, and
`sync.midi` in the project from format 7, its tempos as `[quarter, quarters a minute]`).

**An image scrolls with the score** (the Attach Image extension). Right-click the preview ▸
Add Image… (an SVG, drawn as vectors, or a PNG / JPEG: the file's type says which), or Paste (⌘V: a PNG, SVG text, or a copied
file), puts one where it was clicked (⌘V: at the pointer); a file dropped on the score, where
it is dropped (`ScoreViewState.dropImage`). An `ImagePatch` pins its left edge
to a score quarter (so re-engraving keeps it at its bar) and gives its top below the frame's
top and its size in staff spaces (it grows with the score size); `crop` is the part of the
image shown, in fractions. The scene draws them over the music and under the names, the
frozen zone and the pointer (`ScoreRenderer.paint`'s `overlay`), the same in a video. A
click selects one, a drag moves it, a corner resizes it keeping its shape; double-click (or
right-click ▸ Crop) and the handles crop it instead, the whole image shown faintly behind.
Right-click ▸ Score Ink (`ImagePatch.ink`, format 10) draws it in the score's ink, its own
colours dropped, so line art follows the paper (light ink on dark paper in a dark theme or
video).
The toolbar's Manage assets… (shown while the switch is on) lists the image files the project
keeps (`ImageEditing.stored`: those a patch shows), each with its uses as bars: a bar
locates it (`ImageEditing.locate`: the playhead goes to where its left edge sounds, first
pass, and it is selected), and Remove takes every patch of that image off the score in one
Undo step (`ImageEditing.removeImage`).
Below them are the unused ones (`ImageEditing.unused`: removed while the project is open,
kept so Undo can bring them back; never saved). Purge unused lets go of them and rewrites
the Undo history without their patches (`EditHistory.rewrite`), so every other edit of
those steps can still be undone, and a step that only added or removed one is dropped.
Every change is an Undo step (`patches` in `EditState`); a project keeps them in
`state.patches` and each image file, byte for byte, as `images/<id>` (format 8); opening
reads only the files a patch shows. While the
switch is off the images stay in the project but are not drawn, exported or editable
(`ImageEditing.enabled`). Decoding is bounded (`PatchImage.decode`), so a small file can't
take gigabytes: a file over 64 MB, or a PNG / JPEG over 64 megapixels (one inside an SVG
too, read from its header before anything is decoded), is refused; one longer than 4096
pixels is kept at 4096. An SVG with no viewBox and no width and height (flutter_svg refuses
it; a browser draws it) is given the box around what it draws.

**A drop goes by where it lands** (`_HomePageState._areaAt`; the hint covers only that
area and says what it takes). With no score open, anything opens (as File ▸ Open). Above
the timeline, it is always an image (Attach Image; while that is off, it says so). On the
timeline, the Instruments tab opens a project or a score, and the Audio tab takes a MIDI
tempo map or a recording.

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
document's `EditState` (everything a project saves but the view: lanes, transition, sync,
MIDI, names, texts, condensing, order, images, fonts) with the last one recorded; a difference is one step. A gesture is one step: wrap it in `beginEdit` /
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
but every staff is drawn on its own (Verovio's brackets and system labels are left out; the
frozen zone draws a brace for an instrument on more than one staff, `StaffBrace`; its staves
move as one, as far apart as Verovio put them, where cross-staff notes were placed, and its
barlines run on between them, `ScoreRenderer.barlinesThrough`), so the
preview stacks them in `CuratedScene.partOrder`: the user's order (hold a lane's name in the
Instruments tab and drag it, or its ⋯ menu), then any part it lacks in score order. Changing
it only re-plans the layout, like condensing. It is an edit (`partOrder` in `EditState`, and
in the project from format 5, empty for the score's order); the lanes follow it
(`EditorController.laneParts`), and a condensed pair moves as one.

**Opening is all or nothing.** A project is read and validated (`ProjectState.fromJson`),
then engraved, and only then swapped in, in one synchronous step. If anything before the swap
fails, what was open stays open, with its path — so a later save can't write one project
over another. A recording that fails to load is reported, not fatal.

**What the engraving leaves out is said, not only logged.** The bridge keeps Verovio's
warnings ("Unsupported direction-type 'harp-pedals'") instead of printing them;
`EngravingData.warnings` / `LoadedScore.warnings` carry them, each once, and importing a
MusicXML score lists them in a dialog (`showImportWarnings`). Opening a project, or
re-engraving after an edit, doesn't show them again.

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
keep their written key), MusicXML direction ids (so texts can be edited), cancelling naturals
at a key change to C (a key change was applied twice, the second time cancelling itself), and a
log per thread (engravings run side by side on isolates, each reading its own). Mark changes in
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
the renderer draws. A project chooses its fonts (Score ▸ Fonts…, `ScoreFonts`: an edit,
`fonts` in `EditState`, saved from format 9; changing it re-engraves, as a text edit does).
Music: a bundled SMuFL font (Bravura, Leland, Petaluma, Leipzig, Gootville: each an OTF in
pubspec and Verovio's own metrics in `assets/verovio/<Name>.xml`; Leipzig's are there anyway
because Verovio always loads them), one installed with SMuFL metadata
(in a SMuFL folder, where the specification puts them on each platform: `FontFiles.smuflFolders`), or a file the user picks (`MusicFont.added`:
travels in the project as `fonts/<name>.font` and `.json`; registered for drawing by `load`).
Text: Academico (metrics written under Verovio's `Times*` names by
`Tools/make_text_metrics.swift`) or any installed family. The app finds installed fonts itself,
the same way on every platform: it reads the `name` and `OS/2` tables of every file in the
platform's font folders (`FontFiles.installed`, once a run), and draws an installed family
from those very files, registered under a family of its own (`TextFonts.load`, "Curator text
<name>"; a face of a .ttc copied out, as Flutter loads only first faces), so what is drawn is
what was measured. Verovio reads every font's metrics
from one resource folder, the text font's always as `text/Times*.xml`, so for anything but a
bundled music font with Academico, `FontResources.prepare` writes a folder of its own (in the
scratch space, once per pair of fonts), measuring the font files with stb_truetype
(`vb_measure_font`: tight ink boxes from the outlines, and advances; `src/stb_truetype.h`,
vendored, public domain / MIT). stb_truetype trusts its fonts, and a project brings its own
music font, so our copy is changed (its "CURATOR CHANGES" note): every read is checked against
the font file's bytes (`InFont` in `font_metrics.cpp`), and composite glyphs nest only so deep.
Keep those changes when updating it; a test measures a font made to break it. A font that
can't be read is never taken on (`EditorController.setFonts` prepares it first,
`LoadedScore.prepareFonts`), so a project never saves one it couldn't open with. A text font not installed here falls back to Academico, the
choice kept (`LoadedScore.textFontFound`). A glyph a music font lacks is laid out and drawn in
Bravura (`fontFallback`, `RenderStyle.musicFontFallback`). The frozen zone still spaces its
clef and time signature by Bravura's proportions.

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
Run workflow, or `gh workflow run release.yml`). It builds side by side with `make build` on
macOS and `flutter build windows` on Windows (Verovio fetched and patched by hand there: no
`make`), zips each as `Curator-<version>-<macos|windows>.zip` (the Windows zip carries the
Visual C++ runtime DLLs) and publishes release `v<version>` only when both have built and
`make check` has passed on macOS (the tests don't run on Windows), where the version is
`app/pubspec.yaml`'s. Its actions are pinned to commits, not tags; only the job that publishes
may write to the repository. To release again, bump that version and `appVersion` in
`updater.dart` together (`updater_test.dart` checks they match); a version already released
stops the run before it builds. The app finds its download by that name (the asset whose
name ends `-macos.zip` or `-windows.zip`; the launch notice stays quiet when there is none), so
keep that suffix if the workflow is changed. Neither build is notarized or signed (macOS ad hoc only), so
macOS Gatekeeper and Windows SmartScreen warn the first time; the release notes say how to open
it on each. The engine's CMake builds Verovio's sources itself, so Verovio's own platform
settings must be copied in by hand (on Windows: `include/win32` and `NOMINMAX`). The updater only downloads (into Downloads;
on Windows wherever the registry says that folder now is): it never replaces the running app.

## Adding things

- **A setting**: an `_Item` in `settings_dialog.dart`'s `_categories`, backed by a field in
  `AppSettings`. Settings of first-party components that are not part of the main work
  (import, curate, sync, export) and matter less go under **Extension**.
- **An extension**: a value of `AppExtension` (`app_extensions.dart`: its name, icon, version,
  one-line summary, search words, its own settings (`settings`, a dialog's content, or null)
  and its switch, a `bool` in `AppSettings`), which the Extension page lists: name and
  version, the summary under them, a settings button (greyed out without settings) and the
  switch. The switch
  is the app's, never a project's, and off by default. Say in `AppExtension.usedBy` when an open
  project uses it: opening a project that uses extensions that are off shows them in a dialog,
  each with its switch (and "All" when there are several). Everything the extension adds (menu items, toolbar buttons, drop targets, shortcuts,
  what it draws or exports) works only while its switch is on, and is hidden or inert otherwise.
  **Attach Image** (`AppSettings.attachImage`) is the first one.
- **Something a project saves**: a field in `ProjectState`, written in `toJson`, read in
  `fromJson`, filled in `EditorController.projectState` and taken on when a project opens;
  bump the version with a migration (even one that changes nothing). If Undo should cover it
  (every edit should), it is also a field of `EditState` (with its `==`), and the controller
  fills it in `_editState` and puts it back in `_restore`. If it changes what is drawn, copy
  it in `VideoExport.of` too.
- **A Verovio change**: edit `third_party/verovio`, then
  `git -C packages/score_engine/third_party/verovio diff > patches/verovio-curated-score.patch`,
  then `make setup` (it re-applies the patches from a clean tree, and records that it did).
