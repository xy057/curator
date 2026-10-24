# Architecture

How Curator is put together, and the rules that keep it working. Read this before
changing how a score is engraved, what a project stores, or how edits are made.

## The two packages

**`packages/score_engine`** knows music and drawing, nothing about the app's UI:

| File | Job |
|---|---|
| `src/verovio_bridge.cpp` | A Verovio device context that records drawing calls (paths, glyphs, text) per staff, plus measures, onsets and clef/key/time signatures, behind a C API |
| `engraving_options.dart` | The Verovio options the user may change (Project Settings ▸ Engraving: the common ones by plain name, Advanced Engraving every other; a project's over the app's, `EngravingOptions.over`) and the house style's values for them |
| `lib/src/native/bindings.dart`, `engraving.dart` | FFI bindings; `Engraver.engrave` runs Verovio on an isolate and copies everything into plain Dart data (`EngravingData`) |
| `score_metadata.dart`, `score_text.dart` | What the MusicXML says: parts, staves, meters, where each part plays; the editable texts, with text edits applied before engraving |
| `text_dynamics.dart` | Dynamics another program wrote as text (`TextDynamics`), made dynamics before engraving |
| `beat_grid.dart` | Where the beats fall in every bar (see *Beats*), and `bar.beat` positions |
| `curation.dart`, `auto_curate.dart` | When each instrument is shown: one lane of regions per part |
| `condensing.dart` | Pairs of players (Flute 1 + 2) that can share a staff, and the shared part written for each |
| `sync_map.dart` | The tempo track: anchors pinning score positions to recording times, and warps (anchors that jump); `TapPass`, one pass of tapping along |
| `score_form.dart` | The score's form (repeats, endings, D.C., D.S., To Coda, Fine): the order its bars are played in, and the MIDI warps for it |
| `midi_tempo.dart` | A Standard MIDI File's tempo map (Set Tempo events only), and the anchors that make a `SyncMap` follow it; `MidiInScore`, where its quarters fall in the score |
| `scroll_map.dart` | Playback time → the score x under the pointer: beat to beat, every onset on time, or a blend; `ClippedTimeline`, part of a performance as if it were all |
| `spacing_plan.dart`, `staff_stack.dart` | The vertical layout and the frozen zone's key column (as wide as the shown staves need), planned per segment |
| `display_list.dart`, `frozen_zone.dart`, `score_renderer.dart` | Drawable items per staff; the clef/key/time column and braces; tile-cached drawing |
| `curated_scene.dart` | `LoadedScore` (engraved, ready; what it was engraved with is an `EngraveRequest`) and `CuratedScene`: one frame is `paint(time)`; what it shows besides the score, time, curation and sync is a `SceneSettings` |
| `score_fonts.dart`, `font_files.dart`, `src/font_metrics.cpp` | The music and text fonts (`ScoreFonts`): bundled SMuFL fonts, added ones, installed text fonts; the fonts installed (read from the font folders, `FontFiles`); Verovio's metrics for them, measured with stb_truetype (`FontResources`) |
| `score_patch.dart` | Images on the score (`ScenePatch`, drawn by a `PatchArt` the app supplies) and `ScoreAxis`: score quarters ↔ engraving x |
| `score_caption.dart` | Captions (`Caption`), when each shows (`captionSpans`) and the bar they show in (`CaptionBar`) |
| `score_motion.dart` | How the score moves (`ScoreMotion`): every curve (`MotionCurve`, an equation in t) and length of time the scene animates with |
| `score_typography.dart` | How each kind of text and music symbol in the score looks (`ScoreTypography`: a `TextLook` per `TextKind`), the engraved kinds written into the MusicXML for Verovio, the symbols' sizes as Verovio options |
| `search.dart` | `segmentAt`: the binary search the timelines, grids and plans share |
| `zip_entries.dart` | `ZipEntries`: an entry of someone else's zip (a project, an .mxl), its bytes counted as they unpack and refused past a limit |

**`app/`** is the editor around it:

| File | Job |
|---|---|
| `editor_controller.dart` | The open document: score, curation, sync, names, texts; loading, Undo, project state |
| `editor/playback.dart`, `editor/lane_editing.dart`, `editor/sync_editing.dart`, `editor/image_editing.dart`, `editor/caption_editing.dart`, `editor/commands.dart` | Parts of the controller: the clock and transport; the Instruments tab's tools and selection; the Audio tab's tapping and anchor selection; images on the score (Attach Image); captions (Captions); what the Edit menu and the keys do in the tab showing (`EditCommands`) |
| `controller_settings.dart` | `EditorController.takeSettings`: everything the app's settings set in the editor, in one place |
| `score_view/attach_image.dart` | Attach Image in the score view (a part of `score_view.dart`): selecting, moving, resizing and cropping an image by its handles; adding one from a file, the clipboard or a drop |
| `image_patch.dart` | Attach Image's model: `ImagePatch` (where an image sits), `PatchImage` (its file), SVG / PNG / JPEG drawing, the clipboard |
| `assets_dialog.dart` | Attach Image's Manage assets… (toolbar): the images a project keeps, where each is used, Remove, Remove Unused |
| `caption_settings.dart` | Project Settings ▸ Extensions ▸ Captions' own settings (the app's): font, position, countdown, size, with a preview |
| `extensions/extension.dart` | `CuratorExtension`, what the app knows of an extension (by id), and `Extensions`, every one there is |
| `extensions/built_in.dart` | Attach Image and Captions as `CuratorExtension`s |
| `extensions/extensions_dialog.dart` | On opening a project that uses extensions that are off: a switch for each |
| `caption_lane.dart`, `captions_dialog.dart` | Captions: the lane pinned under the bar ruler, and the sheet that edits every caption (double-click the lane) |
| `settings_dialog.dart` | Settings… (⌘,, the app's) and File ▸ Project Settings… (⇧⌘,, the open project's: each change an edit), one window laid out the same: categories, pages of items, a search |
| `font_settings.dart` | Project Settings ▸ Engraving: the music and text font a project is engraved in, and its caption font |
| `sections_editor.dart` | Project Settings ▸ Sections: the instruments as staves, their brackets dragged, drawn or set on a selection |
| `motion_settings.dart` | Project Settings ▸ Advanced: the motion's rows (`MotionSetting.all`), a slider or a curve each, and the Custom Curve dialog; `SettingSlider`, a setting's slider set when let go, its number typed over in a `SliderValueField` (also Scroll follow's and Export's Score size) |
| `typography_settings.dart` | Project Settings ▸ Typography: a row per property of each kind of text (`TypographySetting.all`), a slider or a style each |
| `condensing_editor.dart` | Project Settings ▸ Condensing ▸ Add a pair (the page itself, a switch per pair, is in `settings_dialog.dart`) |
| `score_replacement.dart` | Project Settings ▸ Project Info ▸ Score ▸ Replace…: a project carried over to another score file (`ScoreSwap`), and what differs between them |
| `project_state.dart`, `edit_history.dart` | What a project stores (typed, validated, versioned): its edits (`EditState`, also Undo's snapshots), image files and view; Undo and Redo |
| `project_file.dart`, `project_document.dart` | The `.ccs` format; the document around it (path, dirty state, autosave) |
| `audio_track.dart`, `audio_format.dart`, `media_converter.dart` | Playback (SoLoud), the waveform and onsets, converting to FLAC; `MediaFormats` lists what is accepted |
| `video_export.dart`, `export_dialog.dart` | Video export: frames from `CuratedScene.renderFrame` piped to FFmpeg as raw RGBA, out as a `VideoCodec` (MP4 H.264 / HEVC, MOV ProRes, WebM VP9, a PNG sequence); the dialog: a large still over a trimmer of the piece (bars dragged by their handles or typed, the still scrubbed; `VideoExport.barStarts`, `musicEnd`), a sidebar of Video (format, size, frame rate: 30–120 or typed, `VideoFormat.parseRate`) and Picture (ratio, paper, transparent, score size); while it writes, the still shows each frame as drawn (`write`'s `onFrame`), never drawing the scene again at its own size: the renderer keeps tiles for one pixel ratio, and switching drops them all |
| `scratch_space.dart` | Where temporary files go (see *Scratch files*) |
| `file_names.dart`, `latest.dart` | A path's file name and stem (`fileNameOf`, `stemOf`); overlapping work where the latest call wins (`Latest`, `Turn`) |
| `updater.dart` | Settings ▸ About: `appVersion`, `appBuild`, `appCommit`, the latest GitHub release, its download into Downloads |
| `app_menus.dart` | The menu bar (native on macOS): File (Project Settings… then Settings… at its foot, on macOS too), Edit. Edit's items are greyed out with nothing to do, and while a text field or a dialog has the keyboard, since on macOS a key Flutter leaves unhandled goes on to the menu |
| `timeline_panel.dart`, `instrument_lanes/*.dart`, `instruments_toolbar.dart` | The Instruments tab: the lanes, in parts (where things are, lanes moved by their names, the pointer among regions, a lane's name and ⋯ menu, the painter); the tab's toolbar |
| `main.dart`, `*_panel.dart`, `score_view.dart`, `editor_toolbar.dart`, … | The UI |

## Rules

**A frame is a function of time.** `CuratedScene.paint(time)` draws everything from the
curation, the sync and the time alone; nothing accumulates between frames. That is what lets
the preview scrub freely, and what video export reuses: frame *i* is `renderFrame(i / fps)`,
the same painting offscreen. `VideoExport` works on its own scene and copies of the curation
and sync; what else the scene shows is a `SceneSettings` (`EditorController.sceneSettings`), which
`VideoExport.of` takes whole, so something new the scene shows goes in it;
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
fading in over 10 ms) and fades out over the settle after the last bar (a settle of 0 cuts it,
over the same 10 ms).
The end is a function of time too: after the final barline the score eases to rest over
`ScoreMotion.settle` seconds (its last bars stay on screen), and the frame fades to paper over the
last `ScoreMotion.endFade` seconds before `paint`'s `end` (the playback's duration: the piece's
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
What a video is written as is a `VideoCodec` (Export's Format, `AppSettings.videoCodec`): its
FFmpeg encoders best first (the dialog asks FFmpeg which it has, `VideoEncoder.probeAll`, and greys
out the rest): FFmpeg's own and its libraries, alike everywhere; for H.264 and HEVC the platform's
own (VideoToolbox, Media Foundation) last, for builds without them, its container and sound. A PNG sequence is a folder of numbered frames without
sound, written as `<name>.part` and renamed; an existing folder is replaced only if it holds
nothing but frames of that name (`VideoEncoder.onlyFrames`; `.DS_Store`, `Thumbs.db` and the like aside), never anything else; one that gains other files while it is written keeps them, and the frames go beside it ("Take 2", `write` returns where). Sizes run 480p
to 1440p (no 4K or 8K): at 4:1 that is 5760 × 1440, which every format writes and every GPU draws,
so no size is ever too big.
A transparent video (`AppSettings.videoTransparent`, only where `VideoCodec.alpha`:
ProRes 4444, VP9 with alpha, RGBA PNG) is drawn on paper of alpha 0 (`VideoFormat.paperColor`),
the paper choosing the ink. The renderer can't hide the music under the names by painting paper
over it then, so on see-through paper the music goes on a layer of its own and that part is cut
out (`dstOut`); the ending fades the whole frame out on a layer instead of painting paper on it.
Its frames are read back as `rawStraightRgba` (Flutter's `rawRgba` is premultiplied, FFmpeg's
`rgba` straight); the dialog's still shows it on a checkerboard toned like the paper.

**Beats come from `BeatGrid`, never "a quarter note".** Compound meters beat in dotted notes
(6/8 has two beats), additive ones in their groups (2+2+3/8 has three), upbeats count back
from the barline. Snapping, tapping, the tempo lane and every
`12.2` position (`BeatGrid.format` / `parse`) go through it.
So does Go to: a click on the toolbar's time or bar.beat (or ⌘G) types where to go,
a bar (`12`, `12.2`: where it first sounds) or a time (`1:10.5`, `1:02:03`), read by
`Playback.goTo`. Closing it hands the keyboard back to what had it, or the window's
shortcuts would stop (focus falls to the route's scope, above them).

**The scroll follows the beats, the notes, or a blend.** `ScrollMap.follow` (Project
Settings ▸ Animation ▸ Scrolling, `EditState.scrollFollow`, an Undo step saved with the project; a project
without its own takes `AppSettings.scrollFollow`, 0.4 until Save as default; copied into video export) runs
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

**How the score moves is the project's** (Project Settings ▸ Advanced, `EditState.motion`, an Undo
step saved as `state.motion` from format 20; a project without its own takes `AppSettings.motion`,
the house style until Save as default; `CuratedScene.motion`, in `SceneSettings`). A `ScoreMotion`
holds every curve and length the scene animates with: the staves' glide (`SpacingPlan` and
`KeyColumnPlan`'s blend) and fade (`Curation.visibilityAt`'s ramp, then the ink after `inkDelay`,
`ScoreMotion.inkFor`); the scroll's settle and slowest speed (`ScrollMap.withMotion`: a new slowest
speed solves the notes' curves again, a new settle only re-ends them); the ending's fade
(`CuratedScene.endOf(timeline, motion)`, so playback's duration and a clipped video's end follow);
captions' fade and rise; the bar numbers' row lead and the tempo's cross-fade. Each curve is a
`MotionCurve`: an equation in `t` (presets by name, or the user's own), parsed once into a Dart
closure and cached, scaled so it always runs from 0 to 1; between them it may overshoot by up to 1 (a glide
goes past and back), while opacities are held inside. It is checked at 1024 points (undefined or
further out: refused, saying where); between them a value undefined is the straight line's, and one
further out is held at the limit, so no frame can be NaN. The settle leaves at the speed it arrived
when its curve starts at a slope of 1 or more (`startSlope`). The staff transition's length stays a
region's property (Animation), and the interface's own motion stays the app's (Reduce motion).

**How the score's texts look is the project's** (Project Settings ▸ Typography, `EditState.typography`,
an Undo step saved as `state.typography` from format 21; a project without its own takes
`AppSettings.typography`, the house style until Save as default). A `ScoreTypography` holds a `TextLook`
per `TextKind`: a size (a share of the house size), a face (`TextFace`: Regular, Italic, Bold, Bold
Italic, or for engraved kinds As written, the file's own), letter spacing in ems and, for drawn kinds,
an opacity. The fonts themselves stay on the Engraving page. Two sorts of text, kept apart:
- **Drawn** by the scene (names, bar numbers, the tempo at the left, captions): `CuratedScene.typography`,
  in `SceneSettings`; a change only redraws (the renderer's names, the bar numbers' and tempo's
  paragraphs, the caption bar made again; a caption's size changes the room the staves leave).
- **Engraved** by Verovio (tempo marks, expressions, rehearsal marks, lyrics): `EngraveRequest.typography`,
  compared by `engravesLike`, so only these engrave again. `ScoreTypography.applyTo` (in
  `PreparedScore.prepare`, after dynamics typed as text, before condensing copies them) writes a face as
  MusicXML's `font-style` / `font-weight`, and a size and letter spacing as the patched importer's own
  attributes, `curated-score-size` (percent) and `curated-score-tracking` (MEI virtual units: ems × the
  engraving's text size, `lyricSize`, × the size), which become a `rend`'s or `syl`'s typography. Verovio
  lays the text out with them, so the music makes room; tempo and expression are told apart as Verovio
  tells them (a metronome mark or `<sound tempo>`). A file's own `font-size` (points) is still ignored.
  The letter spacing reaches the drawing through `VBCommand.letterSpacing`.
- **Music symbols**, every glyph Verovio sets in the music font: clefs, key and time signatures,
  noteheads, flags, rests (and a multi-bar rest's number), accidentals, articulations, dynamics,
  ornaments (and a trill's wavy line), fermatas, breath marks and caesuras, tremolos (and their number),
  arpeggios, glissandos (wavy), tuplet numbers, pedal and octave marks, bar repeats (and their count),
  repeat dots, tablature (fret numbers, lute rhythm signs; the tab clef is a clef), segno and coda; with
  augmentation dots (drawn as circles). Every music-font draw in Verovio's views is one of these, but
  for notation MusicXML can't bring in (neumes, mensural, clusters, a serpent barline) and the
  braces and brackets, stretched to their staves.
  Stems, beams, ledger lines and staff lines are lines, set by the Engraving page's thicknesses. `TextKind.isSymbol`, the page's Music
  symbols group: a size alone, the font having one face and its glyphs set one by one.
  `ScoreTypography.verovioOptions` passes each changed size as the patched Verovio's own option
  (`curatedDynamScale`…, `TextKind.verovioScale`), which scales the staff size its draw functions use
  (`CuratedSize`; fingering's and chord symbols' point size), so the layout follows: Verovio lays out by
  the boxes drawing makes. Noteheads are sized in `Doc`'s glyph metrics too (`CuratedGlyphSize`), so
  stems, dots, ledger lines and accidentals keep to them; their lines and spaces stay the staff's, so
a notehead goes no bigger than its staff space (`TextKind.maxSize`, 100%): bigger, a chord's thirds
  run into each other and heads rise into what is set above the staff.
- **Fingering and chord symbols** are text Verovio builds itself (`TextKind.optioned`): size, face and
  letter spacing go as the patched Verovio's options (`curatedFingScale` / `…Face` / `…Tracking`, the
  same for `Harm`), applied to the text's font in `DrawFing` / `DrawHarm`; a chord's accidentals, in
  the music font, follow its size. Two placements the patch adds so big ones keep
  clear: an accidental moves left of its note's articulations, and a caesura sits midway between the
  notes or rests either side. The frozen zone draws its clef, key and time signature at the same sizes
  (`FrozenZone(typography:)`, its columns widening with them).

**The metronome clicks the beats as they sound** (C, or the toolbar's button by Play; an aid
for aligning the tempo, `Playback.metronome`: neither saved, an edit, nor in a video). Each frame
while playing, the beat sounding (`BeatGrid.beatAt`, per pass, so a repeat clicks again) clicks
once if it began since the last frame's time: a late frame still clicks, a seek into a beat
doesn't. The bar's first beat is higher. The clicks are WAVs made in memory
(`AudioEngine.clickWav`) and play through SoLoud beside the recording, at full speed whatever
the playback's; tests take them through `AudioEngine.debugClick`.

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
anchors are derived: `SyncEditing` edits no anchor (its `_sync` is null), tapping is off, and
the Audio tab draws the tempo map large instead of the anchors and the waveform. The map
itself is edited there, as a sequencer's tempo track: a change dragged (up and down its tempo,
sideways its place, snapped to beats, stopping a beat this side of a
neighbour), the step after it dragged for its tempo only, ⌥-click
on the line adding a change at the nearest beat (`inserted`: kept though it repeats the tempo,
a point to drag), ⌥-drag drawing a step a beat (`MidiTempoMap.drawn`: the last drawn holds to
the next change; only the stretch drawn loses repeats), Delete removing the selected change
(`anchors.selectedTempo`; `anchors.selected` is only ever anchors). Each makes a new map (`moved` / `inserted` /
`drawn` / `removed`) that `EditorController.editMidiTempo` follows from the same
start; the lane's scale is held while a gesture lasts, so it doesn't re-fit under the pointer, and
the pointer is read on the map the gesture began from, so a step drawn doesn't move the beats
under the pointer drawing on. The anchors
set by hand are kept behind it (`EditorController._tapped`, saved as `sync.anchors`) and come
back when the MIDI goes. Using or dropping one is an edit (`midi` in `EditState`, and
`sync.midi` in the project from format 7, its tempos as `[quarter, quarters a minute]`).

A file that plays the repeats out keeps the score's form in its warps (`MidiTempoMap.warps`,
W or the Warp button, saved as `sync.midi.warps` from format 15). The file counts quarters
as played, as `SyncMap`'s performed position does, so a warp is `(at, jumpTo)`: at the file's
quarter `at` the score goes on from `jumpTo`; where it arrives from follows (`arrivals`), and
`anchors` walks the passes, a change of tempo landing in whichever pass plays it. Editing one
(double-click its line; an empty jump removes it) moves the moment it jumps, never those after.
Warps that don't fit the score (a damaged project's) are left out from the first that doesn't, the
rest followed (`MidiTempoMap.arrivals`, as `SyncMap` would keep them); editing a warp lets them go.
Reading a file keeps the warps the sync had: the old file's, or those set by hand
(`MidiTempoMap.warpsOf`), so the form is set once; the window says where a file's warps came from
(`showMidiWarpsTaken`, with Remove). With none, a file nearer the score's length
played with its repeats than straight through (`MidiTempoMap.lengthOf`, to its last track's end)
takes the score's own (`EditorController.scoreWarps`); the Audio tab's Warps from score button puts
them in place of the map's at any time. They come from `ScoreForm` (`ScoreMetadata.form`): the
first part's repeats and endings and every part's `<sound>` jumps and markers (a segno or coda
symbol counts as a marker), unrolled by `playedOrder` as a player would: a repeat goes back to the
last forward repeat or where the stretch began, endings play on their times through, D.C. / D.S.
are taken once and after one repeats are left out (unless `after-jump`) and the last ending plays,
To Coda jumps on and Fine stops. A warp is wherever the next bar played isn't the next in the
score. A Fine ends the file but not the score: the bars after it follow the last tempo. The lane works in the file's quarters and
asks `MidiInScore` (the engine's) where they are in the score for beats and snapping, and when each
warp it follows jumps (`warpSeconds`, by its place among the map's warps).

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
kept so Undo can bring them back; never saved). Remove Unused lets go of them and rewrites
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

**A caption shows under the score** (the Captions extension). A `Caption` is a text and
the score quarters it runs between, so it stays with its bars when the sync changes and shows
once for every pass that plays them (`captionSpans`). Captions never overlap, so one shows at
a time: every edit keeps them apart (`separateCaptions` in `CaptionEditing._set`, and on
reading a project, an earlier one ending where the next starts), and the editors stop at the
free stretch around a caption (`captionRoom`; the dialogs flag one running into another,
`captionOverlapping`). The scene draws it in `CaptionBar` under the staves, which leave
`CaptionBar.reserve` for it while there are any: the text centred in the score's text font,
and under it a hairline as wide as the text that draws in to its middle as the caption's time
runs out; it rises `ScoreMotion.captionRise` points into place as it fades in over `ScoreMotion.captionFade`, and fades out
as its time ends. It is part of `paint`, so the preview and a video show the same.
How it looks is a `CaptionStyle` (`CuratedScene.captionStyle`, copied into video export): its
font, countdown (`CaptionCountdown`: the hairline, a ring left of the text that
empties clockwise, or none) and size (`CaptionSize`; the room grows with it). Countdown and size are the app's (the extension's settings button; `AppSettings.caption*`,
not edits). The font is the project's when it has one (Project Settings ▸ Engraving ▸ Caption, shown while
the switch is on: an edit, saved as `fonts.caption` from format 12), else the app's ('' is the
score's text font); an installed family is read and registered before it is drawn
(`CaptionEditing._applyStyle`, the latest call winning), and one not installed here falls back
to the score's text font, the choice kept. A style change repaints by marking playback dirty:
the preview repaints only when asked.
Right-click the preview ▸ Add Caption… starts one on the beat where it was clicked (or
where the caption there ends), four bars long or up to the next caption (`CaptionEditing.draft`;
greyed out without room); double-click the caption showing (or
right-click it) to change it; an empty text removes it.
While the switch is on, the Captions lane (`CaptionLane`) is pinned under the bar ruler in
both tabs: never scrolled with the instruments, moved or unpinned, so it has no ⋯ menu. Its
captions are regions, edited as the instruments' are with the Instruments tab's tool (the
Audio tab only selects): Draw drags out a stretch and asks for its text (nothing is added
until it has one), Select moves one, trims an edge, selects it for Delete
(`CaptionEditing.selected`, cleared by a click in any other lane) and double-clicked opens
its dialog, Erase cuts captions back or in two; edges snap as the lanes' do, and a drag is
one Undo step. A double-click on the lane's name opens the Captions sheet (`CaptionsDialog`): a row per caption, From / Until /
Text cells, Tab across and ↑ / ↓ / Enter down the column, Add, ×; Done applies it all as one
Undo step (`CaptionEditing.replaceAll`). A cell's widgets never change while typing (a
row's problem shows by the buttons, not around the row), or the cell would lose the keyboard. Every change is an Undo step
(`captions` in `EditState`); a project keeps them in `state.captions` (format 11). While the
switch is off they stay in the project but are not drawn, exported or editable.

**A drop goes by where it lands** (`_HomePageState._areaAt`; the hint covers only that
area and says what it takes). With no score open, anything opens (as File ▸ Open). Above
the timeline, it is always an image (Attach Image; while that is off, it says so). On the
timeline, the Instruments tab opens a project or a score, and the Audio tab takes a MIDI
tempo map or a recording.

**Lanes are painted, not cut.** Drawing adds a region and merges it with what it touches;
erasing trims. Touching regions are merged on purpose: a seam between two regions would dip
the staff's fade. During a drag regions may overlap (`Curation.updateLanes`); `normalize`
merges them when the drag ends. Every lane snaps through `snapInLanes`, takes a click's beat (or
bar, zoomed out) through `beatInLanes`, and tells a double-click through `DoubleClicks`
(lanes_common.dart).
A drag in the timeline measures from where it began in the score or the recording (kept at the
press), never from a point on the screen: the view pages on under it while playing
(`TimeViewport.follow`). One the system cancels (the pointer taken) keeps what it changed so far
as one Undo step and starts nothing new (a Draw click, a caption's dialog); a lane held by its
name goes back to its place.
The playhead is a layer of its own over every lane (`WithPlayhead`): playback moves it every frame
and repaints only it, so a lane's painter listens to edits and the viewport, never to the time. The
Instruments tab paints only the lanes scrolled into view.
The bar ruler is red while notation runs off the video's frame (`EditorController.overflowing`, a
`SpacingPlan` for `videoLayout`, its ratio's: for each keyframe, every item drawn (a note, a dynamic, a
slur) whose bounds, where the keyframe puts its staff, pass the frame's top or bottom edge, for as long
as it is in view between the names and the right edge, `ScrollMap.timesBetween`; a staff whose lines
are off it, the whole segment. The margins and the caption bar are on screen, so ink there is not off
it), and a warning by its name lists those bars.
Export says so too, for the bars it writes (`overflowBars(within:)`: a warning under the Picture
rows, Carbon's inline error notification there), and Export… waits until Export anyway is ticked;
ticked for those bars only, so bars that change (another ratio, score size or range) ask again.
`CuratedScene.overflowing` plans that size apart from the frames painted, so the preview at
another size never plans again for it. It plans every segment (about 20 ms for 350 bars), so
while a gesture lasts (a region or anchor dragged, the score size slid) the controller keeps the
answer from before and works it out once as the gesture ends; Export's dialog rebuilds then too.

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
Cut and Copy (Edit, ⌘X / ⌘C) take the selected regions whole, with their properties, into the
app's own clipboard (`LaneEditing.copied`, kept across projects; the system's holds Attach
Image's images): each lane's regions from the first one's start, and its row below the top lane
copied. Paste (⌘V, in the Instruments tab while regions are copied; elsewhere an image) puts
them in from the beat nearest the playhead, merged as drawing merges: the top row into the top
lane selected and the rest as far below it, or with nothing selected each into its own lane
(`LaneEditing.paste`); a row past the bottom lane is left out, and the piece's end cuts them.

**Editing the score's texts is deprecated and unreachable.** No menu, toolbar button,
dialog or double-click changes a text any more; add nothing to it. The engine and the
controller keep it (`EditorController.editTexts`, `textEdits` in `EditState` and the project),
so projects with text edits still open and engrave as saved, Undo steps through them, and
Replace Score carries them over. A double-click on a text does nothing
(`test/app_screenshot_test.dart` checks it).

**Widgets change the document only through `EditorController`** (and its parts). They may
read the models (`curation`, `sync`) to draw them. The Edit menu, the keys and the toolbar's Remove
act through `EditorController.commands` (`EditCommands`), and a menu item is enabled by the same
`can…` its command checks, so what the menu offers is what the key does.
The controller notifies at every move of a drag, so nothing large rebuilds on it wholesale: the
page, the toolbar, the score view, the bottom panel, the lanes and their names each rebuild through
a `Select` (ui_kit.dart) only when what they show changes; painters listen for themselves.
Resizing the window rebuilds nothing either: a layout builder returns children built outside it
(the same widgets, so only laid out again), and only what changes with the window's size reads
`MediaQuery.sizeOf`. The score's `SpacingPlan` and
`KeyColumnPlan` are made again at each new size, so they work a segment's keyframe out only when a
frame first needs it. The lanes repaint at every frame of playback and read the controller for
each lane, so what they read is kept until what it comes from is replaced: `laneParts` and
`condensable` (the score, order, pairs and condensed set are always replaced, never changed in
place), and each lane's runs of bars played (`_activity`, per score and pair).

**One Undo for the whole document.** The controller keeps its own edits (names, texts, pairs,
condensing, order, fonts, engraving options, the MIDI tempo map and the anchors behind it) as one
`EditState`, `_doc`, which opening takes, Undo puts back and closing empties whole; the models (the
curation, the sync, the images, the captions) keep theirs, and `_editState` reads them from there.
After every change the controller compares the
document's `EditState` (everything a project saves but the view: lanes, transition, sync,
MIDI, names, texts, condensing, order, images, fonts, engraving options) with the last one recorded; a difference is one step. A gesture is one step: wrap it in `beginEdit` /
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

**Sections are grouped as printed when asked** (Project Settings ▸ Sections ▸ Group sections,
`EditState.groupSections`, an edit saved from format 17, off for a new project; `CuratedScene.sections`,
in `SceneSettings`).
A section is a run, in the instruments' order, of two instruments or more of one
`ScorePart.section` (woodwinds, brass, percussion, voices, strings; keyboards, harp and guitar stand
alone), or of one the user put in a section of their own (a family's lone instrument is otherwise
left bare, as printed; the editor gives a bracket dragged down to one instrument a section of its own). Families first, as exports group them every which way, then the file: where its part-list
brackets anything, an instrument it leaves out of every bracket stands alone too
(`ScorePart.bracketed`: no bracket, no barlines joined to it). Last, the user, in Project Settings ▸
Sections (`SectionsEditor`, under the switch): the instruments as staves in
lane order, bracketed as the score has them; a bracket's end dragged takes in or lets go of
instruments, a drag down the bracket column draws one, and instruments selected as lanes are
(⌘-click a range, ⇧-click adds) are bracketed or unbracketed by its buttons. A section is then any
name (`EditState.sections`, by part id: a family's name joins that family, `bracket-2` only those
given it, null none; an edit saved as `sections` from format 16, any name from 17;
`CuratedScene.sectionOverrides`); one put back in its own family's is no longer the user's, and
Reset gives every instrument its own. While a bracket is dragged the score behind shows it
(`EditorController.previewSections`, not an edit); letting go is one Undo step. Each section gets a
bracket (`StaffBracket`, the font's hooks at its ends; set out past the braces when one of its
instruments has them, the names then stopping short of it), its barlines run on between its staves
(not the voices', which leave room for words), and the starting line runs through every staff
(`StaffJoin`). The room between staves changes as they come and go, so unlike an instrument's
barlines (baked into its tiles) these are drawn each frame: each barline's strokes
(`ScoreRenderer._barlineStrokes`) from where the staff above's end to where the one below's begin.
A section stays bracketed while any of its staves shows, one alone too; the bracket's ends follow
a staff fading in or out at either end, and it fades with the last.
Only drawn: nothing is planned or engraved again.

**Names can take their group's colour** (Project Settings ▸ Instruments ▸ Color names,
`EditState.colorNames`, an edit saved from format 19, off for a new project; `CuratedScene.nameColors`,
by part id, in `SceneSettings`). Each instrument's name in the name column is drawn in its group's
colour instead of the ink (a pair in its first player's). The groups (`EditorController.nameGroups`)
are the families' (woodwinds blue, brass yellow, percussion red, keyboards violet, voices green,
strings wood: `defaultNameColors`, each recoloured in `EditState.nameColors`), which can't be
removed, then the user's (`NameGroup`, `group-N`: added, renamed, recoloured, removed). An
instrument is in its `ScorePart.family`'s group (none for other families) unless the user chose
another or none (`EditState.nameGroupOf`, by part id; removing a group sends its instruments back
to their families'). This is not the Sections page's brackets. Only the name's layer is tinted
another colour (`StaffLabel.color`); the paragraphs cached in the ink serve every colour.

**Bar numbers are drawn, not engraved** (Project Settings ▸ Engraving ▸ Bar numbers,
`EditState.barNumbers`, an edit saved from format 18, on for a new project, off for one saved before; `CuratedScene.barNumbers`,
in `SceneSettings`). Every bar's number as the score prints it (`ScoreMetadata.barNumbers`: MusicXML's `text`, else `number`;
none on an upbeat, a split bar's second half or a bar numbered as the one before; the ruler and Go to
still count bars from 1) is set at its
top left, small, italic and in half the ink, in a row of its own just above the room the staves
have (`_rowBottom`: the top margin), so it stays put however the stack
grows or shrinks. Only staves squeezed into a full frame reach up into it: then the row rises, and
never comes down. `_liftFor` keeps, per plan (and score size), the most the row has had to rise up to each 0.1 s
(the top two shown staves' ink, checked against each staff's highest ink first, so most steps cost
one lookup), worked out only as far as a
frame asks, so an edit costs the steps up to the playhead, and kept as it was while a gesture lasts
(`holdBarRow`, set by the controller as for the off-frame check; a video never holds); `_rowShiftAt` averages that over the next 1.2 s with smoothstep's bell as the weight,
so each rise starts and ends at rest, is done before the staves get there, and is still a function
of time. Drawn in the renderer's
overlay, so the names and frozen zone cover them as they cover the music.
While it is on, the texts that speak of the speed (`ScoreText.tempoRole`: a tempo mark; a change for a
while, "rit.", "accel.", "allarg." and the like; or "a tempo"; a pair's copy with them) are set apart from
the music (`ScoreDisplayList.build`'s `apart`; the display list and renderer are made again, lazily, and
the plan with them), and what they say where the playhead is (`_tempoSpanList`) is written at the
frame's left in that row: the tempo mark last passed, or a change in its stead from where it is
written until its dashes or bracket end (`ScoreText.extended`; Verovio draws them with it, so its
right edge is where), "a tempo" or another mark comes ("a tempo" itself shows the tempo again).
The words are as edited (no metronome mark), on the numbers' baseline, in the text font's italic at
the names' size, cut short with an ellipsis past their width; one gives way to the next over two
staff spaces of scroll. The off-frame check doesn't count either.

**Opening is all or nothing.** A project is read and validated (`ProjectState.fromJson`),
then engraved, and only then swapped in, in one synchronous step. If anything before the swap
fails, what was open stays open, with its path — so a later save can't write one project
over another. A recording that fails to load is reported, not fatal. Listeners never see it
half done: `_install` sets every part before anything notifies (captions last, as working out
their style can notify at once), and a controller disposed while engraving takes nothing on,
its recording included.

**Replacing the score keeps the project.** Project Settings ▸ Project Info ▸ Score ▸ Replace… engraves another score
file with the project's edits carried over to it (`EditorController.prepareReplacement`,
`ScoreSwap`), and only then swaps it in, like opening, keeping the recording, the path and
the view (`replaceScore`). Instruments are matched by id and name, then by name (an
instrument added above renumbers the rest), then by id (renamed); lanes, names, pairs,
condensing and order follow them, and an instrument only in the new file is curated as on
import. Positions (regions, anchors and warps, images, captions) keep their bar and their
distance into it, no further than its end; a barline stays that barline. A MIDI tempo map's warp
jumps at the same moment of the file (as an anchor keeps its time) and goes on from the same bar;
one with nowhere to go, and those after it, are left out and counted. A text edit follows
its text: the same instrument, words and kind, by id, else in the same bar (ids the app gives
in document order shift). What has no place (past the new last bar, a removed instrument's
text) is dropped. When the files differ (instruments, bars, time signatures, bar lengths,
tempo, edits lost) a dialog lists it before anything changes. Undo starts again from the
replacement: its steps were of the old file.

**What the engraving leaves out is said, not only logged.** The bridge keeps Verovio's
warnings ("Unsupported direction-type 'harp-pedals'") instead of printing them;
`EngravingData.warnings` / `LoadedScore.warnings` carry them, each once, and importing a
MusicXML score lists them in a dialog (`showImportWarnings`). Opening a project, or
re-engraving after an edit, doesn't show them again.

**The project format changes with a version.** `project.json`'s `state` is written by
`ProjectState.toJson`, always in the newest format this build has (`ProjectState.version`),
whatever the project uses. To change it: bump `ProjectState.version`, and add a migration from the
old version in `ProjectState._migrations`, so older files still open. Migrations are additive: a
new format adds fields (an older file, lacking them, gets their defaults) and never renames,
removes or changes the meaning of one an older format wrote. Reading checks every
field and names the damaged one.

**The C and Dart structs must match.** `VBCommand` is read from Dart as 4-byte words (`Cmd`
in `engraving.dart`), and declared again for FFI in `native/bindings.dart`. The bridge `static_assert`s every field's word index, and
`Engraver` compares every struct's size with the library's (`vb_struct_size`) before reading.
Change both sides together.

**Dynamics typed as text are dynamics.** A notation program can write a dynamic as words: Sibelius
exports an "f" typed in a text style other than Expression as `<words font-family="Maestro">F</words>`,
and Verovio, reading what the file says, engraves the letter in the text font. `TextDynamics.apply`
(in `PreparedScore.prepare`, after the text edits and before condensing) rewrites as `<dynamics>`
every `<words>` that spells one of MusicXML's dynamics (`f`, `mp`, `sfz`…): in a font whose letters
draw dynamics (Maestro, Opus Text, Bravura Text…; any case, as exporters map glyphs through their
font's table), or in SMuFL's dynamics characters (U+E520–E53D) in any font. It keeps its place and
colour, not its font; text beside it in the same direction-type moves into direction-types of its
own, so Verovio still sets it beside the dynamic. The texts list is read before, so it and saved
edits' ids don't change. Project Settings ▸ Flags ▸ Dynamics typed as text (`EditState.textDynamics`,
an Undo step that re-engraves; a project without its own takes `AppSettings.textDynamics`, on
until Save as default) turns it off.

**Verovio is pinned and patched.** `make setup` clones the tagged release and applies
`patches/*.patch` from a clean tree whenever a patch changes; the build hook refuses to build
while a patch is newer than the tree. Patches: per-part key changes (transposing instruments
keep their written key), MusicXML direction ids (so texts can be edited), the app's typography
(`curated-score-size` / `curated-score-tracking` on words, rehearsal marks and lyrics, a rehearsal
mark's `font-style`, the `curated…Scale` options sizing music symbols, accidentals clear of
articulations and caesuras between their neighbours), cancelling naturals
at a key change to C (a key change was applied twice, the second time cancelling itself), and a
log per thread (engravings run side by side on isolates, each reading its own). Mark changes in
Verovio's code with `[curated-score patch]`.

**Engraving options: offered ones only, the layout ones fixed.** The bridge
(`vb_engraver_create`) fixes what the curated view relies on: one endless system (`breaks`
none), no header, footer or page margins, `scale` 100. Everything a score is engraved with besides its MusicXML (text edits, pairs, fonts,
options, flags) is one `EngraveRequest`; the score keeps the one it was engraved with
(`LoadedScore.request`), and an edit that changes the controller's (`_requestFor`) engraves again.
Dart then sends every option in
`EngraveOption.all`, with the house style's value unless the user changed it, so the house
style lives in that list alone. They are set twice over: the app's defaults (in `AppSettings`;
not part of a project, not an edit, set only by Project Settings ▸ Engraving ▸ Save as default,
which also saves the project's fonts for new projects), and the open project's over them
(Project Settings ▸ Engraving, `EditorController.projectEngraving`: an edit, saved as
`state.engraving` from format 13). A project's keep a value set back to the house style's
(`keepDefault`), so it still wins over the app's; a reset there goes back to the house style,
over a default too. Only its options are ever sent, so none of the fixed ones can be
overridden; none may change the bars or the staves (`expand`, `transpose`, `mdiv*` stay out).
Their types, ranges and choices are checked against Verovio's own list
(`Engraver.availableOptions`); an out-of-range value would be dropped by Verovio without a
word. Changing them re-engraves the open score, as a text edit does.
The Engraving page offers the options most scores want changed (`EngravingSetting.all`, in
`engraving_settings.dart`: a plain name, a heading, a slider step) and Advanced Engraving every
other one (`EngravingSetting.advanced`; together they hold each option in `EngraveOption.all`
once, which `engraving_pages_test` checks), all as `EngravingControl`s: sliders, switches and a menu
with the other pages' `SettingSlider` and `ResetSlot`, found by plain or code name in the search.
Both, and Typography, are `_Category(preview: true)`: a half-size preview of the open score above
the rows (with none, `EngravingPreviewHost` engraves the bundled demo in a controller of its own,
with the app's options, for as long as the preview is shown), hidden on all three at once by the
button by the page's title (`AppSettings.engravingPreview`, app-wide, not an edit). A slider sets
its option only when let go, so a drag is one engraving and, in a project, one Undo step. Every
row reads and writes through `EngravingTarget` (the project's, over the app's), which shows a line
thickness left unset as the open score's font's own.

**Colours are chosen when drawing.** The engraving is recorded as ink only; the renderer
tints tiles, names and the frozen zone with the ink colour as it composites them
(`paint(paper:, ink:)`), so a theme change never re-rasterises anything.
The app passes the theme's `scorePaper` / `scoreInk`.

**A change of appearance cross-fades over a still.** The theme (light, dark, accent) changes at
once, and a still of the window as it was (`_StillBoundary`, taken from its last painted layer)
fades out over it. A lerped theme would rebuild every widget that reads it on every frame of the
fade, too slow with many lanes. A Material animates a change of its shape on its own, behind the
still: one with an outline sets `animationDuration: Duration.zero`, or (a popup menu, which can't)
takes `_SteadyBorder`. A widget's own colour animation (a hover, a selection) takes `stateDuration`, which is none in
the frame the appearance changes, so it doesn't trail the cross-fade either.
The two themes are built once per accent, style, density and motion (`_CuratedScoreAppState._buildThemes`): a new
`ThemeData` never equals the last, so one built per change of settings would rebuild every widget
that reads it. The page, likewise, rebuilds only for the settings it shows (`_HomePageState._shown`).

**Two styles, one look on every platform: a style is a set of tokens and a theme builder.**
Settings ▸ Appearance ▸ Style (`AppSettings.uiStyle`): Refined, the default, or Carbon (which
replaced Classic, Material's theme as it was; a saved `classic` opens as Refined, `UiStyle.named`,
and `AppSettings` saves it so).
Each style is three things in app_colors.dart: a palette (`AppColors.of`), a theme builder laid
over one Material base (`AppColors._refined`, `AppColors._carbon`), and an `AppStyle`, the tokens
every widget reads instead of asking which style it is: `rounded` (`corner(r)` / `radius(r)`
give a Refined radius, 0 in Carbon), `control` (toolbar buttons, 28 / 32), `toolbar` and
`panelBar`, a dialog's `field` (36 / 40) and `fieldInset` (10 / 16), `row` (34 / 32), `menuRow`
(22 / 24) and `menuInset`, `menuOpen` / `menuClose` (190 / 110 ms), and the curves. `motion(context, ms)`
takes Material's milliseconds to the style's: about three quarters in Refined, snapped to Carbon's
duration steps (70, 110, 150, 240, 400, 700) in Carbon. `AppStyle.of` of a theme without one (a
bare `MaterialApp` in a test) is Refined; there are no Material fallbacks left.
Three more settings under Appearance shape every style: **Text size** (`TextSize`, 0.9 / 1 / 1.15)
is a `TextScaler` over the system's, set in `MaterialApp.builder`, so it reaches every `Text` but
not text painted on a canvas (bar numbers, region and anchor labels, which keep to their lanes) nor
the score. **Density** (`UiDensity`) is the `AppStyle` at a density (`AppStyle.at`): `control`,
`toolbar` and `panelBar` 4 px smaller or bigger, `row` and `menuRow` 2 (a whole Carbon step, xs
24 px, crowded the toolbars' icons); a dialog's `field` stays, and the theme builders take their
button and menu-row heights from it, so a size written as a number elsewhere doesn't follow.
**Reduce motion** is `AppStyle.still`: `duration` (so `motion`) gives none, menus open and close at
once, a fixed duration goes through `AppStyle.moving`, the appearance cross-fade is skipped and
`MediaQuery.disableAnimations` is set; what the score does (scrolling, staff transitions) is the
project's and unchanged. A change of text size or density cross-fades as a change of theme does.
Refined's palette (`AppColors._refinedOf`) has neutral greys, with no accent mixed in, and a
`chrome` tone behind toolbars, the lane-name column and the ruler. Controls are 28 px with 5 px
corners on a 13 px type scale. Segmented controls are a clear track whose chosen segment, a light
tint of the accent, slides to the one clicked, each label taking the accent as the tint passes
under it, and the hover and press shades (drawn by the segment, so they fade rather than switch)
gone while it slides.
Carbon follows IBM's Carbon Design System (v11) as specified: the White theme or Gray 100, its
named tokens in a `CarbonColors` extension (only in a Carbon theme: `CarbonColors.maybeOf`), IBM
Plex Sans on the productive type set (12 / 14 / 16 / 20 px, Carbon's tracking), square corners,
sm (32 px) buttons at the condensed density (label at the left, 7 / 39 px), primary / tertiary
(outlined) / ghost (text) buttons in their state colours, fields filled with `$field` and a line
under them (`CarbonFieldBorder`), a 2 px `$focus` ring (`CarbonFocusBorder` on a button),
checkboxes in `$icon-primary`, monochrome 2 px sliders, the small toggle in `$support-success`
with its check, the content switcher (edged in `$border-inverse`, the chosen segment inverse),
24 px menus on `$layer-01`, the side nav (a 3 px bar of the accent) in Settings, and the modal
(`$layer-01`, heading-03, footer buttons edge to edge at the right, slimmed to 40 px from the spec's 64). An accent is an IBM hue
(`CarbonHue`, a field of the `AccentColor`): Sky is Carbon's own Blue 60, the others Purple, Cyan,
Teal, Green, Magenta, Orange, Warm Gray (Sand) and Cool Gray at their 60 (light) or 50 / 40
(Gray 100) grades; `$button-primary` stays the 60 in both. An `AccentColor` is a swatch
(`AccentColor.values`, saved by name) or the user's own (`AccentColor.custom`, after the swatches,
chosen in `color_dialog.dart`; saved as "custom" plus `AppSettings.customAccent`), whose Refined
strong shade and Carbon grades are worked out from it in HSL (the fill at most 42 % light, so white
reads on it).
State shows as fills (`$background-hover`, `$background-active`), never ripples.
A click on a segment chooses at once; an appearance change it makes (Theme, Style) fades
from a still of the window, which would hold the tint where it started, so the tint is
`LeftOutOfStills` (its own layer, hidden while `_RenderStillBoundary` takes the still) while it
moves or a click is about to move it; at rest it stays in the still, so a change of accent
cross-fades it as the rest of the window; there are no ripples or 48 px touch targets. Custom
widgets read `AppStyle` and, for Carbon's own colours, `CarbonColors` (ToolbarButton, the play
button, the bottom panel's tab switch, the Settings sidebar, lane labels). The score's paper and
ink are the same in every style (`ScorePaper`), and video export draws on them. Neither style
follows the platform (no `.adaptive` or Cupertino widgets), so macOS and Windows match.
`AppSwitch` and `AppSegmented` (ui_kit.dart) draw their own controls: always use them, never
`Switch` or `SegmentedButton`.
Icons are named by meaning, `AppIcon` (app_icons.dart), and each style draws its own set: Refined
Material Symbols Rounded (outlined, weight 300, optical size 20; filled only for play, pause, go to
start, the pin and the done / failed marks), Carbon IBM's Carbon icons (the 16 px designs where
there are, the 32 px masters otherwise). Both are bundled as small fonts holding only these icons,
one code point per icon in both; `AppIcon.x.of(context)` picks the style's, never `Icons`. A table
that has no context holds the `AppIcon` and resolves it where it is drawn. Tools/make_icon_fonts.py
builds both fonts and app_icons.dart from its table, from the pinned releases: add an icon there.
The metronome, which neither set has, is painted in the style's stroke.
The app icon shows in the app as `AppLogo` (Home, Settings ▸ About): the icon, or the mascot on the
same tile while `AppSettings.mascotIcon` is on, which a click on About's icon toggles (saved). The
running app takes it too: `WindowChrome.showAppIcon` sends the tile's PNG (512 px on macOS,
256 elsewhere; null for the bundle's own) over the runners' `curated_score/window` channel as
`setAppIcon`: the Dock icon on macOS (`NSApp.applicationIconImage`), the window's icons on Windows
(`WM_SETICON`: title bar, taskbar, Alt-Tab) and Linux (`gtk_window_set_icon`). The bundle's icon
(Finder, Launchpad, a pinned taskbar item, the Start menu) stays the app's: changing it would
break the signature. Refined's `AppSegmented` works its label colour out from the tint
(the accent's strong shade taken toward black, or white, until it reads at 4.5:1), as some
accents' shades don't. Text styles set in a style's theme are merged with the typography's
geometry as `Theme.of` gives them, since a button lerps its label between the two styles and two
text styles lerp only when both inherit or neither.
Flutter fixes a popup menu's and a dropdown's timing and row height in the widget, not the theme,
so `menu_kit.dart` has them: a menu is an `AppPopupMenuButton` filled with `menuItem` /
`checkedMenuItem` / `menuDivider`, a select an `AppDropdown` (a `MenuAnchor` whose bare panel
holds a card of the theme's menu style, so the card and its rows fade in together), never
`PopupMenuButton` or `DropdownButton`; and a duration written as Material's goes through `motion`.

Dialogs are laid out by `dialog_kit.dart`: `AppDialog` (title, a body that scrolls
in a short window, a footer with `leading` buttons, a `status` and the `actions`), `AppTextField`
(its label over it, its borders from `fieldBorders`), `AppCheckRow` and `AppChip`.
A dialog has measures of its own, roomier than the toolbars' since it is read and filled in: in
Refined an 18 px title, 14 px text, 36 px fields, 34 px rows and buttons, 24 px padding, a 14 px
corner; in Carbon a 20 px heading, 14 px body, 40 px fields, 32 px rows, 16 px padding, 48 px
over the footer, square, and the footer's buttons sharing its width (half each for one or two,
a quarter with leading buttons or a status, which take the rest; the label at the top left,
Cancel a secondary button). A body is a fifth wider than its content's base (`dialogWidth`).
In Refined everything in a dialog starts and ends on that 24 px edge: the title, the content, a
check row's box (no inset), and the footer's buttons, whose secondary ones (Cancel, an extra
action) are outlined by `DialogButtons` so their edge, not their label, is on it (in Carbon
`DialogButtons` makes them secondary buttons); groups of fields are `dialogGap` apart. Export's
footer uses `DialogButtons` too. Inside a field, typed and chosen text both start
`AppStyle.fieldInset` in from the border, so an `AppTextField`'s outline has no label gap and an
`AppDropdown` draws its border over itself; a menu's heading is a `menuHeader`, on its items'
edge. A dialog is an `AppDialog`, never an `AlertDialog`; a labelled field an `AppTextField`
(tests find it with `appField(label)`), a select an `AppDropdown(label: …)`, and one that filters as it is
typed in (a long font list) a `DropdownMenu` built through `dialogMenuField`. `Export` is a
`Dialog` of its own, in the same measures.

**Overlays keep their parent in the accessibility tree.** Tooltips and sliders draw their
overlay (the tip, the slider's value) through an `OverlayPortal`, and for accessibility that
overlay hangs from the widget that shows it. Flutter loses the link when two such widgets
share a semantics node (flutter/flutter#182444), and when the widget is faded to opacity 0,
which drops its semantics but not its overlay (a `Slider`'s is always there,
flutter/flutter#190357). The overlay is then sent with no parent, the desktop engine rejects
the update ("Failed to update ui::AXTree" in `make run`), and its tree stays broken. So:
`Tip`, never `Tooltip` (and `ToolbarButton` for icon buttons); a `Slider` inside
`OverlaySemantics`; `showAppDialog`, never `showDialog`; and a fade over any of them keeps its
semantics (`alwaysIncludeSemantics: true`).

**Fonts: engraving and drawing agree.** Verovio lays out with the metrics of the same fonts
the renderer draws. A project chooses its fonts (Project Settings ▸ Engraving, `ScoreFonts`: an edit,
`fonts` in `EditState`, saved from format 9; changing it re-engraves, as a text edit does).
Music: a bundled SMuFL font (Bravura, Leland, Petaluma, Leipzig, Gootville: each an OTF in
pubspec and Verovio's own metrics in `assets/verovio/<Name>.xml`; Leipzig's are there anyway
because Verovio always loads them), one installed with SMuFL metadata
(in a SMuFL folder, where the specification puts them on each platform: `FontFiles.smuflFolders`), or a file the user picks (`MusicFont.added`:
travels in the project as `fonts/<name>.font` and `.json`; registered for drawing by `load`).
Its picker offers the bundled and installed SMuFL fonts, then Installed Font… (the system's
font picker: the runners' `curated_score/fonts` channel, macOS's Fonts panel answered when it
closes, Windows' Font dialog; a file where there is none) and Font File…. Embed font
(`EditState.embedFont`, saved as `fonts.embed: false` from format 14) shows only for a font
that isn't bundled; a font file turns it on in the same step (elsewhere it couldn't be found by
name). Off, only the name is saved; opening such a project looks it up
(`EditorController.findInstalledMusicFont` → `MusicFont.findInstalled`: a SMuFL folder, else a
family by its typographic name or a weight's legacy one, as Windows' Font dialog answers
"Foo Light"; compared through `MusicFont.nameFor`, the file-safe name a font goes by). Not
found, or found but unreadable, it is `MusicFont.missing` (`MusicFontKind`: bundled, added,
missing): engraved and drawn in Bravura, the choice kept and saved again, Embed font off and
disabled (nothing to embed), and the window says so once (a snack bar the user closes). The
pickers set the project's fonts (edits); a late answer from the system picker applies only to
the project it was chosen for. What new projects start with is the fonts of the one last saved
as the default (Project Settings ▸ Engraving ▸ Save as default:
`AppSettings.musicFont`/`textFont`/`embedFont`, by name, as the app keeps no font file;
`EditorController.newProjectFonts`); one not installed where a score is imported is Bravura or
Academico. Settings rows are keyed by item, so a control keeps its state when a `shown` row
above it comes or goes.
Text: Academico (metrics written under Verovio's `Times*` names by
`Tools/make_text_metrics.swift`) or any installed family. The app finds installed fonts itself,
the same way on every platform: it reads the `name` and `OS/2` tables of every file in the
platform's font folders (`FontFiles.installed`, once a run), and draws an installed family
from those very files, registered under a family of its own (`TextFonts.load`, "Curator text
<name>"; a face of a .ttc copied out, as Flutter loads only first faces), so what is drawn is
what was measured. Verovio reads every font's metrics
from one resource folder, the text font's always as `text/Times*.xml`, so for anything but a
bundled music font with Academico, `FontResources.prepare` writes a folder of its own (in the
scratch space, once per pair of fonts, and again when the system's temp cleanup has emptied it), measuring the font files with stb_truetype
(`vb_measure_font`: tight ink boxes from the outlines, and advances; `src/stb_truetype.h`,
vendored, public domain / MIT). stb_truetype trusts its fonts, and a project brings its own
music font, so our copy is changed (its "CURATOR CHANGES" note): every read is checked against
the font file's bytes (`InFont` in `font_metrics.cpp`), and composite glyphs nest only so deep.
Keep those changes when updating it; a test measures a font made to break it. A font that
can't be read is never taken on (`EditorController.setFonts` prepares it first,
`LoadedScore.prepareFonts`), so a project never saves one it couldn't open with; its picker says
why under the field. A text font not installed here falls back to Academico, the
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
additive meter). `Samples/` is for trying things by hand only. A test's tap that something
else would catch fails (`flutter_test_config.dart`). `make smoke` runs the app as built
(opening a window): what only a bundle has, its native library and resources, is checked there.

## Releasing

`.github/workflows/release.yml` runs only when started by hand (GitHub ▸ Actions ▸ Release ▸
Run workflow, or `gh workflow run release.yml`). It builds side by side with `make build` on
macOS and `flutter build windows` on Windows (Verovio fetched and patched by hand there: no
`make`), zips each as `Curator-<version>-<macos|windows>.zip` (the Windows zip carries the
Visual C++ runtime DLLs) and publishes release `v<version>` only when both have built and run
the smoke test (`app/integration_test/app_smoke_test.dart`, `make smoke`: the app as built opens
the sample, engraves, draws and exports), and `make check` has passed on macOS (the other tests
don't run on Windows), where the version is
`app/pubspec.yaml`'s. Its actions are pinned to commits, not tags; only the job that publishes
may write to the repository. To release again, bump that version and `appVersion` / `appBuild`
in `updater.dart` together (`make versions` checks they match, from `make check` and as the
workflow's first step: one left behind would offer the app its own release); a version already
released stops the run before it builds. The app finds its download by that name (the asset whose
name ends `-macos.zip` or `-windows.zip`; the launch notice stays quiet when there is none), so
keep that suffix if the workflow is changed. Neither build is notarized or signed (macOS ad hoc only), so
macOS Gatekeeper and Windows SmartScreen warn the first time; the release notes say how to open
it on each. The engine's CMake builds Verovio's sources itself, so Verovio's own platform
settings must be copied in by hand (on Windows: `include/win32` and `NOMINMAX`). The updater only downloads (into Downloads;
on Windows wherever the registry says that folder now is): it never replaces the running app.

## Adding things

- **A setting**: an `_Item` in `settings_dialog.dart`'s `_categories`, backed by a field in
  `AppSettings` (the editor takes what concerns it in `takeSettings`, controller_settings.dart); a project's own, in `_projectCategories`, backed by an edit (see *Something a
  project saves*), so Settings holds only what is the same for every project. A project page whose settings
  can become the app's defaults gives its `_Category` a `saveDefault`: a slim Save as Default
  button beside the page's title (a check and "Default" once they match), never a row; while they
  differ, Reset to Default before it puts the app's back on the page (`reset`, one Undo step). Settings of first-party components that are not part of the main work
  (import, curate, sync, export) and matter less go under **Extensions**.
- **A flag**: a fix for how other programs write their files, on by default, as an `_Item` on
  Project Settings ▸ Flags with a switch to turn it off: the project's (`EditState`, an edit),
  else the app's default (`AppSettings`), which that page's Save as default sets.
- **An extension**: a `CuratorExtension` (`extensions/extension.dart`), listed in
  `Extensions.all`; the built-in ones are in `extensions/built_in.dart`. Each gives a stable
  `id`, its name, icon, version, one-line summary, search words, its own settings (`settings`,
  a dialog's content, or null; the app's), `isUsedBy` (whether an open project uses it) and
  `apply` (turns its part of the editor on or off). Project Settings ▸ Extensions lists each:
  name and version, the summary under them, a settings button (greyed out without settings)
  and the switch. The switch is the project's only (`EditState.extensions` by id, an Undo step,
  `EditorController.extensionOn`); there is no app-wide default, and one the project never chose
  is off. The app's old switches (`AppSettings.legacyExtensions`: a switch each until build 69,
  then Save as default) are deprecated, read but never written: a project saved before it kept
  its own takes one it uses that was on there, as it opens. Opening a project that uses
  extensions it never chose shows them in a dialog (`extensions_dialog.dart`), each with its
  switch (and "All" when there are several); what the dialog ends with is the project's
  (`EditorController.keepExtensions`: one left off is stored off, no Undo step but saved), so
  it asks once. Everything the extension adds (menu
  items, toolbar buttons, drop targets, shortcuts, what it draws or exports) works only while
  its switch is on, and is hidden or inert otherwise. **Attach Image** is the first one,
  **Captions** the second.

  Nothing in the app names an extension but its own code: the switches, the project
  file and dialogs go by id, so one more needs only its class and a place in `Extensions.all`.
  This is ready for extensions from elsewhere (`ExtensionOrigin.thirdParty`, reverse-domain
  ids), but none can be added yet: there is no loading, no sandbox and no API for adding to
  the editor's menus, toolbars or drawing. A built-in extension still adds those by hand,
  behind `images.enabled` / `captions.enabled`. Project files keep switches for ids this
  version doesn't know, so a newer version's choices survive.
- **Interface text** follows Apple's HIG *Writing*, in US English: Title Case for menu items,
  buttons and dialog titles that are fragments ("Copy Lane To…", "Couldn’t Export Video"),
  sentence case for tooltips, labels, help lines and messages; an ellipsis only where more
  input follows. A failure says "Couldn’t …" and, where there is one, the fix ("Use an image
  under 64 MB"), never blame or "we". Contractions; seconds and minutes spelled out in
  sentences; no "e.g.". One word per thing: the playhead (never the pointer), the sample,
  open (a score), add (a recording, a MIDI tempo map), transition, Extensions.
- **Something a project saves**: a field of `EditState` (with its `==` and `copyWith`),
  written in `ProjectState.toJson` and read in `fromJson`; bump the version with a migration
  (even one that changes nothing). If the controller keeps it itself it lives in `_doc`, and
  opening, Undo and closing take it with no more code; if a model holds it, `_editState` (also
  what a project saves, `EditorController.projectState`) reads it from the model, and `_install`
  and `_restore` load the model. If it changes the engraving it goes in `EngraveRequest` too. Replace Score carries it as it is unless
  `ScoreSwap.carry` maps it (a part id or a position). Only the view (`ViewState`) is saved
  without being an edit. If it changes what is drawn, it goes in `SceneSettings` (and the
  controller's `sceneSettings`), which `VideoExport.of` takes; set it in
  `test/export_parity_test.dart`, which checks that a video frame is the preview's.
- **A Verovio change**: edit `third_party/verovio`, then
  `git -C packages/score_engine/third_party/verovio diff > patches/verovio-curated-score.patch`,
  then `make setup` (it re-applies the patches from a clean tree, and records that it did).
