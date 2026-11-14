# Architecture

How Curator is put together, and the rules that keep it working. Read this before
changing how a score is engraved, what a project stores, or how edits are made.

## The two packages

**`packages/score_engine`** knows music and drawing, nothing about the app's UI:

| File | Job |
|---|---|
| `src/verovio_bridge.cpp` | A Verovio device context that records drawing calls (paths, glyphs, text) per staff, plus measures, onsets and clef/key/time signatures, behind a C API |
| `engraving_options.dart` | The Verovio options the user may change (Project Settings ▸ Engraving: the common ones by plain name on its Engraving tab, the Advanced tab every other; a project's over the app's, `EngravingOptions.over`) and the house style's values for them |
| `lib/src/native/bindings.dart`, `engraving.dart` | FFI bindings; `Engraver.engrave` runs Verovio on an isolate and copies everything into plain Dart data (`EngravingData`) |
| `lib/src/native/verovio.dart`, `verovio_web.dart`, `constants.dart` | Every `dart:ffi` call (engraving, font measuring), chosen by conditional import: on the web a stub that can't engrave, so the engine compiles there; the command constants without ffi |
| `engraving_file.dart` | `EngravingFile`: an engraving saved and read again (a web page's score); `LoadedScore.engraved` makes a score from one with no engraver |
| `score_metadata.dart`, `score_text.dart` | What the MusicXML says: parts, staves, meters, where each part plays; the editable texts, with text edits applied before engraving |
| `text_dynamics.dart` | Dynamics another program wrote as text (`TextDynamics`), made dynamics before engraving |
| `beat_grid.dart` | Where the beats fall in every bar (see *Beats*), and `bar.beat` positions |
| `curation.dart`, `auto_curate.dart` | When each instrument is shown: one lane of regions per part |
| `condensing.dart` | Pairs of players (Flute 1 + 2) that can share a staff, and the shared part written for each |
| `sync_map.dart` | The tempo track: anchors pinning score positions to recording times, and warps (anchors that jump); `TapPass`, one pass of tapping along |
| `score_form.dart` | The score's form (repeats, endings, D.C., D.S., To Coda, Fine): the order its bars are played in, and the MIDI warps for it |
| `midi_tempo.dart` | A Standard MIDI File's tempo map (Set Tempo events only), and the anchors that make a `SyncMap` follow it; `MidiInScore`, where its quarters fall in the score |
| `scroll_map.dart` | Playback time → the score x under the pointer: beat to beat, every onset on time, or a blend; `ClippedTimeline`, part of a performance as if it were all |
| `take_splice.dart` | `TakeSplice`: a performance spliced from several recordings' syncs by their lanes, and its sound as crossfaded `SoundChunk`s |
| `spacing_plan.dart`, `staff_stack.dart` | The vertical layout and the frozen zone's key column (as wide as the shown staves need), planned per segment |
| `display_list.dart`, `frozen_zone.dart`, `score_renderer.dart` | Drawable items per staff; the clef/key/time column and braces; tile-cached drawing |
| `score_editing.dart`, `score_edit_view.dart` | The score editor's model: MusicXML held as elements and edited by position (`EditableScore`: note input, pitches, rhythms, ties, slurs, marks, lyrics, dynamics, hairpins, tempo, text (and moving them), clefs, keys, time signatures, bars and barlines, copy and paste, Undo; and as text, an element a line: `toMusicXMLText`), and its view: a few bars engraved at a time with the bars around them (`EditChunk`, drawing what starts in its own) laid end to end as one system (`EditGalley`: drawing, hit testing, x ↔ bar and beat) |
| `pdf_detect.dart`, `pdf_pages.dart`, `pdf_text.dart`, `lib/src/native/pdfium.dart`, `pdfium_web.dart` | A PDF score read (see *A PDF score is the PDF*): PDFium through `dart:ffi` on one worker isolate (`PdfPages`; the hook bundles bblanchon's build, checked by SHA-256; on the web a stub), its pages' staves, systems, braces, music start, barlines and played bars found (`PdfDetect`), instruments matched system to system by name or by look (`PdfDetect.match`); names and tempo marks read from the pages' words (`PdfText`) |
| `pdf_ai.dart` | A PDF score's pages read by an AI model (see *Read with AI*): what it is asked (`PdfAi.prompt`, about a picture of the page with each staff found numbered, `PdfAi.labels`, `PdfAiView`), its answer (`PdfAiPage.parse`: each staff's region, staves it says were missed), put on the page's ink (`PdfAi.refine`, through `PdfPages.refine`) and into the layout (`PdfAi.apply`) |
| `pdf_ai_exam.dart` | The exam a model takes before Read with AI asks it (see *A model is examined*): two pages' key and the marking (`PdfAiExam.score`, `PdfAiExamResult`) |
| `pdf_layout.dart`, `pdf_score.dart` | What an import decided (`PdfScoreLayout`: instruments with their divisi, systems with their staves, each staff's region, the system's barlines, and masks), the skeleton MusicXML written from it, and the main view's PDF: each system as PDFium draws it (`PdfScoreArt`, `PdfPartSource`), each staff's bar a rectangle of it (`PdfEngraving`) |
| `lilypond_svg.dart`, `lilypond_score.dart` | A score LilyPond engraved (see *A LilyPond score is LilyPond's engraving*): its SVG read into shapes (`LilyPath`, `LilyText`) grouped by what made them (`LilyGroup`, by the tags Curator's settings put on them), and with the data file beside it made Curator's engraving of one endless system (`LilyPondScore.read`: its `engraving`, a `musicXML` of what the score is, and point-and-click `links` from the drawing to the source, `linkAt`); drawn as it is in the LilyPond editor's preview (`LilyPondDrawing`) |
| `curated_scene.dart` | `LoadedScore` (engraved, ready; what it was engraved with is an `EngraveRequest`) and `CuratedScene`: one frame is `paint(time)`; what it shows besides the score, time, curation and sync is a `SceneSettings` |
| `score_fonts.dart`, `font_files.dart`, `src/font_metrics.cpp` | The music and text fonts (`ScoreFonts`): bundled SMuFL fonts, added ones, installed text fonts; the fonts installed (read from the font folders, `FontFiles`); Verovio's metrics for them, measured with stb_truetype (`FontResources`) |
| `score_patch.dart` | Images on the score (`ScenePatch`, drawn by a `PatchArt` the app supplies) and `ScoreAxis`: score quarters ↔ engraving x |
| `spacers.dart` | Spacers (Attach Image): `VerticalSpacer`, an empty part of its own (`Spacers.write`), and `HorizontalSpacer`, a stretch of the score made wider (`Spacers.verovioOption`) |
| `score_caption.dart` | Captions (`Caption`), their markup (`captionRuns`), when each shows (`captionSpans`) and the bar they show in (`CaptionBar`) |
| `score_chapter.dart` | A video's or page's chapters (`ChapterCue`, which an extension gives) as the times a description takes (`chapterTimestamps`) and as FFmpeg reads them (`chapterMetadata`) |
| `lua.dart`, `lua/` | Lua, run in Dart (`Lua`): the language extensions are written in. Lua 5.4 as written, read into a tree and turned into Dart closures; no io, os.execute or debug; a script is stopped past a number of steps (`LuaLimit`). One kind of number, strings as text, no coroutines |
| `extension/package.dart` | `ExtensionPackage`: a `.cpe` (a zip: extension.json, connect.json, src/*.lua, locales/, assets/), read as it is and written back as it was, and its connector (`ConnectorGraph`: Curator's sockets as nodes, wired to functions of its files) |
| `extension/runtime.dart` | `ExtensionRuntime`: one extension running over an `ExtensionHost` (the project and app it stands on): its files as modules, its wires called (`fire`, `ask`, `invoke`), what goes wrong listed, and the `curator`, `score` and `text` libraries its Lua gets |
| `extension/api.dart` | `ExtensionApi`: every socket and function of the extension API with what it does and the level it came with; it only grows. `curator.has`, the extension editor's reference and docs are made from it |
| `extension/check.dart` | `checkExtension`: what is wrong with a package as written, found without running it (a file that doesn't read, a wire to nothing; what a later Curator may know is a warning) |
| `extension/lua_json.dart`, `extension/markers.dart` | Lua values to JSON and back (`LuaJson`); markers in time (`markerSpans`: what a markers lane draws, `score.spans`) |
| `score_tonality.dart` | Tonality: a key (`MusicKey`: its tonic on the line of fifths, major or minor; its name and its colour), key areas (`KeyArea`: a stretch of the score in a key; `tidyKeyAreas`, one over others cutting them back), a score's key signatures at concert pitch (`concertKeySignatures`) and Find Keys (`findKeys`) |
| `subtitles.dart` | Captions as subtitles: SRT and WebVTT read (`parseSubtitles`) and written (`writeSubtitles`), placed in the score (`captionsFromCues`) and timed from it (`captionCues`) |
| `score_motion.dart` | How the score moves (`ScoreMotion`): every curve (`MotionCurve`, an equation in t) and length of time the scene animates with |
| `score_typography.dart` | How each kind of text and music symbol in the score looks (`ScoreTypography`: a `TextLook` per `TextKind`), the engraved kinds written into the MusicXML for Verovio, the symbols' sizes as Verovio options |
| `sounding_notes.dart` | `soundingNotes`: every pitched note of the MusicXML as it sounds (concert pitch, in score quarters), which Find Phrase and Align read |
| `audio_alignment.dart`, `basic_pitch.dart` | Align: a recording heard by Spotify's Basic Pitch (`BasicPitch`, its network run in Dart) as which keys sound and start, a chunk at a time (`AudioNotes`, resampled to its rate), matched to the score's notes by multiscale DTW, the path thinned into anchors (`AudioAlignment.anchors`) |
| `phrase_search.dart` | Find Phrase: a melody entered (`Phrase`, `PhraseNote`) and its MusicXML for Verovio, drawn as `PhrasePicture`; every voice of the score as it sounds (`ScoreLine`); where a phrase is played (`PhraseSearch`) |
| `search.dart` | `segmentAt`: the binary search the timelines, grids and plans share |
| `zip_entries.dart` | `ZipEntries`: an entry of someone else's zip (a project, an .mxl), its bytes counted as they unpack and refused past a limit |

**`app/`** is the editor around it:

| File | Job |
|---|---|
| `editor_controller.dart` | The open document: score, curation, sync, names, texts; loading, Undo, project state |
| `editor/playback.dart`, `editor/lane_editing.dart`, `editor/sync_editing.dart`, `editor/image_editing.dart`, `editor/spacer_editing.dart`, `editor/caption_editing.dart`, `editor/tonality_editing.dart`, `editor/extension_editing.dart`, `editor/commands.dart` | Parts of the controller: the clock and transport; the Instruments tab's tools and selection; the Audio tab's tapping and anchor selection; images on the score and spacers (Attach Image); captions (Captions); key areas (Tonality); extensions that are packages (`ExtensionEditing`: their runtimes, data, lanes and selection); what the Edit menu and the keys do in the tab showing (`EditCommands`) |
| `controller_settings.dart` | `EditorController.takeSettings`: everything the app's settings set in the editor, in one place |
| `score_view/attach_image.dart` | Attach Image in the score view (a part of `score_view.dart`): selecting, moving, resizing and cropping an image by its handles; adding one from a file, the clipboard or a drop |
| `image_patch.dart` | Attach Image's model: `ImagePatch` (where an image sits), `PatchImage` (its file), SVG and raster drawing (animated too), the clipboard |
| `span_lane.dart` | `SpanLane`: a lane pinned under the ruler whose stretches (`SpanLaneModel`) are drawn, moved, trimmed and erased the way regions are; the Captions, Spacers, Tonality and recordings' lanes (`take_lanes.dart`) are four. One whose model `paints` (key areas) has its stretches go over each other as regions do, each in its own `color` |
| `spacer_dialogs.dart`, `spacer_lane.dart`, `score_view/spacer_handles.dart` | Attach Image's spacers: their dialogs; the Spacers lane (a `SpanLane` of the horizontal ones, with add and remove buttons); selecting, moving and resizing them in the score view |
| `assets_dialog.dart` | Attach Image's Manage assets… (toolbar): the images a project keeps, where each is used, Remove, Remove Unused |
| `caption_settings.dart` | Project Settings ▸ Extensions ▸ Captions' own settings (the app's): font, countdown, size, alignment, backing, with a preview |
| `extensions/extension.dart` | `CuratorExtension`, what the app knows of an extension (by id), and `Extensions`, every one there is |
| `extensions/built_in.dart` | Attach Image, Captions and Tonality as `CuratorExtension`s (those still written in the app) |
| `extensions/bundled.dart` | `BundledExtensions`: Curator's own extensions that are packages, folders under `assets/extensions/<id>/` read as the app starts |
| `extensions/extension_reader.dart` | Extensions run to read: `ReadingHost`, `ExtensionReaders` (what a video and a page get: chapters), a project's data checked as it opens (`checkedExtensionData`) and carried to a replacing score (`carriedExtensionData`) |
| `extensions/extension_lane.dart`, `extensions/extension_form.dart` | What the app draws for an extension: its lane (`ExtensionLane`, markers each running to the next, with its commands as buttons) and the dialog `ui.form` asks for |
| `extensions/extension_editor.dart`, `extensions/connector_view.dart`, `lua_language.dart` | The extension editor (`showExtensionEditor`: Project Settings ▸ Extensions ▸ New Extension, or an extension's menu ▸ Edit…; Curator's own open to read): a package's files beside its connector as a picture (`ConnectorView`: sockets as nodes, files with their functions, a port dragged onto a function wires it, onto a file writes the function), its Lua in a `CodeView` (coloured a line at a time, `luaCode`, `luaTokens`; the API offered as it is typed, `LuaPrompts`), About and README, the reference beside it (`ExtensionReference`, from `ExtensionApi`; a click writes it in) and the guide (`assets/help/extensions.md`), what is wrong listed under it (`checkExtension`, then what running it said), Run (⌘R) |
| `extensions/extension_actions.dart` | What Project Settings ▸ Extensions does with a package (`ExtensionActions`: new, from a `.cpe`, edit, duplicate, export; `ExtensionMenu`) |
| `extensions/extensions_dialog.dart` | On opening a project that uses extensions that are off: a switch for each |
| `caption_lane.dart`, `captions_dialog.dart` | Captions: the lane pinned under the bar ruler, and the sheet that edits every caption (double-click the lane) |
| `tonality_lane.dart` | Tonality: the lane pinned under the bar ruler, a `SpanLane` of the key areas, each in its key's colour, with add, Find Keys and remove buttons |
| `settings_dialog.dart` | Settings… (⌘,, the app's) and Edit ▸ Project Settings… (⇧⌘,, the open project's: each change an edit), one window laid out the same: categories, pages of items, a search |
| `key_bindings.dart`, `shortcut_settings.dart` | Settings ▸ Shortcuts (see *Every key is a KeyCommand*): every command a key gives (`KeyCommand`), its keys (`KeyChord`), those the user gave the menus' and the editor's commands (`KeyMap`, `AppSettings.keys`, over the window as `KeyMapScope`), tooltips naming a command's key as set (`keyed`); the page's control: a field taking the keys typed next (`ShortcutKeys`), or keycaps (`KeyCaps`) |
| `licenses_dialog.dart` | Settings ▸ About ▸ Licenses (`showLicensesDialog`): every package's licences from the `LicenseRegistry` (`packageLicenses`, read once), Curator's first, the chosen one's text selectable |
| `font_settings.dart` | Project Settings ▸ Engraving: the music and text font a project is engraved in, and its caption font |
| `sections_editor.dart` | Project Settings ▸ Sections: the instruments as staves, their brackets dragged, drawn or set on a selection |
| `motion_settings.dart` | Project Settings ▸ Animation: the motion's rows (`MotionSetting.all`), a slider or a curve each, and the Custom Curve dialog; `SettingSlider`, a setting's slider set when let go, its number typed over in a `SliderValueField` (also Scroll follow's and Export's Score size) |
| `typography_settings.dart` | Project Settings ▸ Engraving ▸ Typography: a row per property of each kind of text (`TypographySetting.all`), a slider or a style each |
| `ai_providers.dart`, `ai_settings.dart` | Settings ▸ Remote AI Provider: AI services reached over the internet and their credentials (`AiProvider`, kept as JSON in `AppSettings.aiProviders`; five built in: OpenAI, Anthropic, OpenRouter, Gemini, DeepSeek), `AiClient` (model lists and a one-word Test in the OpenAI, Anthropic and Gemini formats; redirects not followed, so a key stays with its server; what goes wrong is an `AiError` that never repeats the key; a server is reached within half a minute and its answer ended past 32 MB), and the page: providers at the left (by name, each On or Off), the chosen one's key, base URL, path and models at the right. What is known of a model (`AiModelInfo`: whether it reads images, whether it reasons, its context size, each null while nothing says) is kept with it (`AiProvider.details`, only for models it has) and shown by its ID (icons, 128K); Fetch fills it in from what the provider's list says (`AiClient.infoIn`: Anthropic's capabilities and max_input_tokens, Gemini's inputTokenLimit and thinking, OpenRouter's architecture, reasoning and context_length, and the context fields of other servers of OpenAI's format; OpenAI's and DeepSeek's lists say nothing but IDs, Gemini's nothing of images), and Edit Model (the model's gear, or a click on it) sets it by hand (`byHand`, which a later Fetch leaves) or fetches it for that model alone. Nothing yet asks what a model can do: it is kept for what comes. Advanced (under the path, and in Edit Model) holds custom headers ("Name: value" lines, `AiClient.headersIn`) and a custom body (a JSON object, `AiClient.bodyIn`), kept as typed and each saying under it what of it isn't right: a provider's go with every request to it (the model list and Test too: a gateway's own key), a model's with the requests asking it, after the provider's; a header named again replaces the one before (a custom Authorization, the key's), and a body is merged into the one the app makes (an object in both merged, a null taking its name out, anything else in place of what was there), so `max_tokens`, `temperature` or a provider's routing can be set. A model of one turned on is asked about pictures (`AiClient.ask`, ended by `close`) by the PDF import's Read with AI, the one picked in Settings ▸ General ▸ AI for PDF import (`AppSettings.pdfAiModel`, `AiModels`). Settings ▸ General ▸ Hide AI features (`AppSettings.hideAi`) is read once, at launch (`aiHidden`): hidden, the import is opened with no model and no way to choose one (no Read with AI), General drops AI for PDF import, and this page lies dimmed and out of reach under a cover holding the same switch; a change says Restart to apply (`aiRestartPending`). It hides remote AI only: AI run on this computer (local AI: Align's Basic Pitch, bundled, and what Settings ▸ Download Hub downloads, local AI having no page of its own) is never hidden |
| `condensing_editor.dart` | Project Settings ▸ Condensing ▸ Add a pair (the page itself, a switch per pair, is in `settings_dialog.dart`) |
| `score_replacement.dart` | Project Settings ▸ Project Info ▸ Score ▸ Replace… (another score file or PDF), or Edit… done (the score editor's, a PDF's import again): a project carried over to the new score file (`ScoreSwap`), and what differs between them |
| `score_editor.dart` | Project Settings ▸ Project Info ▸ Score ▸ Edit…: the score editor (`showScoreEditor`), laid out and keyed as Dorico's Write mode in galley view, and its MusicXML view (the toolbar's MusicXML toggle: the score as text in a `CodeView`) |
| `musicxml_language.dart`, `musicxml_schema.dart` | MusicXML as the MusicXML view reads it: each line coloured as it is drawn (`musicXmlCode`, `musicXmlTokens`), its elements folded (`MusicXmlFolds`), what is offered as it is typed (`MusicXmlPrompts`, from the MusicXML 4.0 schema's names, which Tools/make_musicxml_schema.py writes into musicxml_schema.dart), where a part's bar is in the text (`MusicXmlLines`) |
| `pdf_import.dart`, `pdf_ocr.dart` | Opening a PDF, Project Settings ▸ Project Info ▸ Score ▸ Edit… for one and Replace… with one: the import (`showPdfImport`) in five steps, each one's actions on the toolbar (see *The import goes in steps*), a page at a time with what was found drawn over it, each staff's region (a box edited as an image on a canvas: clicked, it is selected; its corners and sides dragged, it is resized; dragged inside, it is moved; Draw Region drags out a new one), every system's music start and end and barlines (the start's and the barlines' by handles above the system, the end's below it; a double click adds a barline), masks and staves' instruments dragged, drawn or picked, the instruments listed (each dragged by its handle to its place, a double click renaming it; blank lanes among them) and edited (renamed or made from a staff's chip, a double click renaming); a bar's changes inserted (right click, or the panel's Insert), each a tag on the page; `pdf_import_changes.dart` holds their dialogs; `pdf_import_ai.dart` reads the pages with AI (`PdfAiReader`) and gives a model the exam (`PdfAiExamRun`); `pdf_ai_model_dialog.dart` chooses the model, by its exam |
| `lilypond.dart`, `lilypond_dialog.dart` | LilyPond (see *A LilyPond score is LilyPond's engraving*): this computer's official build (`LilyPond.package`), downloaded from Settings ▸ Download Hub (`LilyPondInstaller`), a score's files (`LilySource`: its main file and those it includes, `LilySource.read`), engraving it with Curator's settings in the score's text font (`LilyPond.engrave`, giving a `LilyPondRun`: the SVG, the data file and LilyPond's problems where they are, `LilyProblem`); the dialog that engraves, asking for LilyPond from the Download Hub where it isn't here (`engraveWithLilyPond`; `ensureLilyPond` asks only), and LilyPond's errors (`showLilyPondErrors`) |
| `code_view.dart` | What the code editors share (the LilyPond editor's, the score editor's MusicXML): the code in re_editor (`CodeView`), each line coloured by its controller as it is drawn (`lilyPondCode`, `musicXmlCode`; not re_highlight, see *The MusicXML view*), folded as its language says, what can be typed offered as it is (`CodePromptList`), Find and Replace (`CodeFindBar`), and what is wrong with it listed under it (`CodeProblemList`) |
| `lilypond_editor.dart`, `lilypond_language.dart` | The LilyPond editor (`showLilyPondEditor`: Project Info ▸ Score ▸ Edit… of a LilyPond project, File ▸ New LilyPond Score…, Edit… where LilyPond's errors stop an import): the code in a `CodeView` with the score's files beside it, Find and Replace, Engrave (⌘R) and what LilyPond made drawn under the code (a click on a note goes to where it is written; the caret's line marks its notes), LilyPond's problems listed under it; LilyPond coloured a line at a time as it is drawn, its Scheme too, each line from where the one above left off (`lilyPondCode`, `lilyPondTokens`, kept for each line by `LilyPondStates`; `lilyPondTheme`) and what is offered as it is typed (`LilyPondPrompts`) |
| `project_state.dart`, `edit_history.dart` | What a project stores: its edits (`EditState`, also Undo's snapshots), image files, view and modules it can't read (`ForeignModule`); Undo and Redo |
| `project_modules.dart`, `project_archive.dart`, `legacy_project.dart` | How it is saved: one module per part of it (`ProjectModules`, each typed, validated and versioned), the zip layout projects and settings files share (`ProjectArchive`), and reading files saved before modules (formats 1–26) |
| `project_file.dart`, `project_document.dart` | The `.ccs` format; the document around it (path, dirty state, autosave) |
| `settings_file.dart` | The `.ccf` format: a project's score-wide settings, for other projects (Project Settings ▸ Export… / Import…) |
| `audio_track.dart`, `audio_format.dart`, `media_converter.dart` | Playback (SoLoud; every take's recording held, a voice per `PlayChunk`), the waveform and onsets, the recording heard for Align on several isolates (`AudioTrack.notes`), converting to FLAC; `MediaFormats` lists what is accepted |
| `video_export.dart`, `export_dialog.dart` | Video export: frames from `CuratedScene.renderFrame` piped to FFmpeg as raw RGBA, out as a `VideoCodec` (MP4 H.264 / HEVC, MOV ProRes, WebM VP9, a PNG sequence); the dialog: a large still over a trimmer of the piece (bars dragged by their handles or typed, the still scrubbed; `VideoExport.barStarts`, `musicEnd`), a sidebar of Video (format, size, frame rate: 30–120 or typed, `VideoFormat.parseRate`) and Picture (ratio, paper, transparent, score size); while it writes, the still shows each frame as drawn (`write`'s `onFrame`), never drawing the scene again at its own size: the renderer keeps tiles for one pixel ratio, and switching drops them all |
| `video_frame.dart` | `VideoRatio`, and `VideoFrame`: where a video's frame sits in a view (the preview's, the web player's) |
| `web_page.dart`, `web_export.dart`, `web_export_dialog.dart`, `web_guide.dart` | File ▸ Export to Web…: what a page is (`WebPage`, its `page.json`; `WebChoice`, a viewer's choice and whether it is theirs), writing one (`WebExport`), trying it here (`WebPreview`, the folder served on the loopback address to requests naming `localhost` only, so a site rebinding its name here gets nothing; byte ranges, 416 past the end), the dialog and its guide to publishing |
| `web_player/*.dart`, `web/`, `tool/pack_web_player.dart` | The web player, the app package built for the web from `web_player/main.dart` (`make web-player`): the page read (`LoadedPage`), drawn and played (`PagePlayer`, `PageAudio`: an `<audio>`, `HtmlAudio`, or a clock alone) |
| `phrase_search_window.dart` | Edit ▸ Find Phrase… (⌘F): the window that enters a phrase and lists where it is played |
| `project_tabs.dart` | The tabs along the window's top while a project is open (`ProjectTabs`): Home, then each project by name, a dot for unsaved changes; past the window's width they scroll, a mouse wheel's turn too |
| `scratch_space.dart` | Where temporary files go (see *Scratch files*) |
| `app_folders.dart`, `downloader.dart` | Where files the app keeps go (see *Kept files and downloads*); fetching one over https, from an address or a Git Xet repository on Hugging Face (`Downloader`, `XetSource`) |
| `file_names.dart`, `latest.dart` | A path's file name and stem (`fileNameOf`, `stemOf`); overlapping work where the latest call wins (`Latest`, `Turn`) |
| `updater.dart` | Settings ▸ About: `appVersion`, `appBuild`, `appCommit`, the newest GitHub release on the update channel (`UpdateChannel`: the releases, or pre-releases too), what its description says is new, its download into Downloads |
| `update_dialog.dart` | The update window (`showUpdateDialog`; About's Update… and the launch notice's): a release's version, its notes, Download, then how far that has got; `updateHelp`, where the updates stand in a line |
| `markdown_text.dart` | Markdown as a release's description has it, in the app's text (`MarkdownText`; `parseMarkdown`, `parseInline`): headings, lists, quotes, code, links (http and https only) |
| `app_menus.dart` | The menu bar (native on macOS): File (New LilyPond Score…; Export Video…, Export to Web…, also the toolbar's Export menu); Edit (Project Settings… then Settings… at its foot, on macOS too); View (Hide / Show Preview and Timeline, one of them always shown; Maximize Preview / Timeline, the other at its smallest); Window on macOS, Help elsewhere. Edit's items are greyed out with nothing to do, and while a text field or a dialog has the keyboard, since on macOS a key Flutter leaves unhandled goes on to the menu; under a dialog Open, Open Recent, Close and Show Next / Previous Tab are too (the dialog belongs to the tab showing: ⌘W would otherwise close the project under it) |
| `l10n/l10n.dart`, `l10n/po.dart` | The interface's language (`AppLanguage`, Settings ▸ General ▸ Language) and its translations, gettext files in `assets/l10n` keyed by the English and read as the app starts (see *Interface text*, docs/translating.md) |
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

**A web page is a frame of time too** (File ▸ Export to Web…, `WebExport`). A browser has no
engraver, so the page shows the score as the app engraved it: a folder, put on any web server as
it is, holds the web player (`index.html` and its files: the app package built for the web from
`lib/web_player/main.dart`, which `make web-player` builds and `tool/pack_web_player.dart` zips
into `assets/web_player/player.zip`, an asset the app bundles; not in git) and `score/`: `page.json`
(`WebPage`), `engraving.bin` (`EngravingFile`), `project.ccs` (the project's modules, stored, not
deflated: `ZipEntries` inflates with dart:io, which a page hasn't got) and `audio/<n>.m4a`. The
project there is `EditorController.pageState`: every setting the app supplies made the project's
(`exportedSettings`), the syncs as anchors (a MIDI tempo map's made into them, `syncsAsAnchors`), and
what the score is engraved with exactly as it was (`WebPage.requestOf` must give `score.request`, or
the export stops), so `LoadedScore.engraved` rebuilds the same score and the player's scene draws the
editor's frames pixel for pixel. Each way to hear it (`WebRecording`: the performance, and with two
recordings or more each one whole, `EditorController.performedCopy(take:)`) is a `VideoExport` whose
sound alone is written (`writeSound`, mixed and faded as a video's), cut to the page's bars as a video
is (`ClippedTimeline.bars`). The engine compiles for the web because every `dart:ffi` call is in
`native/verovio.dart`, which the web swaps for a stub by conditional import; `dart:io` compiles there,
so code reaching it (a file read) must just never run on a page. SVGs are sized before they go (a page
can't measure one on an isolate). For each thing a viewer could choose (the recording, speed with the
pitch kept, captions, bar numbers, each instrument as curated, always or never), the export sets what
they see first and whether they may change it (`WebChoice.open`); with none open the page is a player
only. The page loads its files beside it (no `<base>`), so it plays from any folder of a server, not
from a file opened directly. Written as `<name>.part`, then moved in: a folder there already takes
it only if it holds an earlier page (`score/page.json`), and then only the entries the export writes
are replaced, so what a user keeps beside them (a GitHub Pages repository's `.git`, a `CNAME`) stays.
Whatever goes wrong is a `VideoExportException` saying why (`WebExport.write` does all its work on
the disk inside one `try`: a folder that can't be read, leftovers that can't be cleared), and the
dialog shows any failure, so it is never left on Writing…, which can't be closed. The guide's
terminal command names the folder in single quotes (`shellQuoted`): a `$` or a quote in its name is
the shell's in double ones.
A page is the GPL'd player passed on, so it carries Curator's licence (`LICENSE.txt`, packed into the
player) and where the source of the build that wrote it is (`SOURCE.txt`, `WebExport.source`: the
commit, or the version's tag), beside Flutter's `assets/NOTICES` and the fonts' licences; installed
fonts it carries (`WebExport.installedFonts`) are named in the dialog, theirs to allow publishing.
The app's own licence window (Settings ▸ About ▸ Licenses) also has what pub can't list: Curator's
own, the GPL every copy must carry (`app/assets/LICENSE.txt`, the repository's LICENSE, which
about_page_test keeps the same), the bundled fonts' licences and those of the libraries shipped
compiled, Verovio and PDFium, each with the libraries built into it (`bundledLicenses` in
main.dart; `packages/score_engine/assets/licenses/`, written by Tools/make_licenses.py, to run
again when either is updated), and Basic Pitch's, Align's model
(`app/assets/basic_pitch/LICENSE.txt`, its NOTICE and licence as the release has them). A page has
none of them, so the player is packed without them.

**Beats come from `BeatGrid`, never "a quarter note".** Compound meters beat in dotted notes
(6/8 has two beats), additive ones in their groups (2+2+3/8 has three), upbeats count back
from the barline. Snapping, tapping, the tempo lane and every
`12.2` position (`BeatGrid.format` / `parse`) go through it.
So does Go to: a click on the toolbar's time or bar.beat (or ⌘G) types where to go,
a bar (`12`, `12.2`: where it first sounds) or a time (`1:10.5`, `1:02:03`), read by
`Playback.goTo`. Closing it hands the keyboard back to what had it, or the window's
shortcuts would stop (focus falls to the route's scope, above them).

**Align sets the anchors by ear** (the Audio tab's Align, first of the sync's tools: a filled button
with its name while the sync has no anchors, then an icon among the others; `SyncEditing.align`, one Undo step replacing the anchors there; at once when a recording is added to
a score with no anchors yet, unless Settings ▸ General ▸ Align added recordings is off). The recording is heard by
Spotify's Basic Pitch (the ICASSP 2022 model, Apache 2.0; `app/assets/basic_pitch`, its weights written
from the release's ONNX export by Tools/make_basic_pitch_weights.py): about 86 times a second, how likely
each of the piano's 88 keys is to be sounding, and to be starting, whatever plays it. `BasicPitch` runs its
network in Dart, four floats at a time (`Float32x4`; each convolution sums eight output planes in
registers), its frames the release's to about 1e-5, a window allocating nothing. A recording is heard in
chunks of about 16.5 s (`AudioNotes`), each from only the samples about it: resampled to 22,050 Hz
(windowed sinc) and run as 2-second windows a whole number of frames apart, each keeping the frames away
from its edges (the release's windows drift half a percent, 12 s over 40 minutes), four frames made one
(about 21.5 a second: the notes' mean, the onsets' most) with the samples' mean square beside them. So the
chunks are heard at once, on isolates as many as half the cores, each taking the next two as it is free
(some cores are slower) and reading their samples itself through flutter_soloud's binding into a buffer of
our own (its `readSamplesFromFile` never frees the one it reads into): 36 minutes in about 20 s on an M5
Pro. The score is laid out as played, its passes the warps set by hand, else the score's form's
(`ScoreForm.passes`), and made into the same frames: how many notes hold each key (none beyond the
piano's, which Basic Pitch doesn't hear), and how many start on it (a tie's carrying on not one). Silence
either side of the recording (40 dB under its loud frames) is left out. Dynamic time warping (steps
weighted 1.5, 1.5, 2, as synctoolbox's) matches them, solved at a quarter, a sixteenth… of the frame rate
first and then only in a band around the coarser path (under a second for 36 minutes); onsets count at
every rate (the strongest of each key at a coarse one), since what sounds alone can't tell apart bars of
one harmony held, and a bar it misplaces coarse is further off than a band reaches. A bar gets an anchor
only where a straight line through its neighbours' would put it more than 30 ms off; a pass's end is a
warp to the next; the final barline is where the music stops. With Snap to notes each anchor moves onto a
note heard within 50 ms. Measured against the chroma Align heard with before (each bar's error: mean,
90th percentile, worst but the final barline): the demo's recording, 109 / 124 / 1943 ms then, 50 / 71 /
129 ms now (its pizzicato chord held over bars 41–43, 2 s off then); the demo through General MIDI
soundfonts, with rubato, a held pause and a hall's reverb, 123 / 172 / 1357 → 44 / 56 / 85 ms, and
steady with a ritardando, 93 / 141 / 359 → 46 / 49 / 87 ms; tones of three harmonics, sustained or
dying away, worst 250 → 66 and 46 ms; a 36-minute run of 25 repeats, median 20 → 10 ms, worst 470 →
87 ms. A final barline is placed as it was, where the sound dies away (0.5–0.65 s from the barline set
by hand or played, above: where a held last chord ends is a matter of ear).

**The scroll follows the beats, the notes, or a blend.** `ScrollMap.follow` (Project
Settings ▸ Display ▸ Scrolling, `EditState.scrollFollow`, an Undo step saved with the project; a project
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

**How the score moves is the project's** (Project Settings ▸ Animation, `EditState.motion`, an Undo
step saved as `state.motion` from format 20; a project without its own takes `AppSettings.motion`,
the house style until Save as default; `CuratedScene.motion`, in `SceneSettings`). A `ScoreMotion`
holds every curve and length the scene animates with, and where the staves stand: the paper above the
first staff and below the last (`margin`, the bar numbers' row inside it) and the least and most between
staves (`minGap`, `maxGap`: `StaffStack.layout` shares the free height out between them; the least
holds even if the staves then run past the frame, and a most below it is the least; the staves are
centred, so the margin tells only while the share is between the two), points in the frame, as the plan's
key; an instrument's own room above and below (a lane's ⋯ ▸ Spacing…, `EditState.spacing`, staff
spaces, negative takes some away, saved in `instruments` from its version 2; `CuratedScene.instrumentSpacing`)
is added to its ink's reach, so the shared gaps make way for it; the staves' glide (`SpacingPlan` and
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
region's property (Display), and the interface's own motion stays the app's (Reduce motion).

**How the score's texts look is the project's** (Project Settings ▸ Engraving ▸ Typography, `EditState.typography`,
an Undo step saved as `state.typography` from format 21; a project without its own takes
`AppSettings.typography`, the house style until Save as default). A `ScoreTypography` holds a `TextLook`
per `TextKind`: a size (a share of the house size), a face (`TextFace`: Regular, Italic, Bold, Bold
Italic, or for engraved kinds As written, the file's own), letter spacing in ems and, for drawn kinds,
an opacity. The fonts themselves stay on the Engraving page. Two sorts of text, kept apart:
- **Drawn** by the scene (names, bar numbers, the tempo at the left, captions): `CuratedScene.typography`,
  in `SceneSettings`; a change only redraws (the renderer's names, the bar numbers' and tempo's
  paragraphs, the caption bar made again; a caption's size changes the room the staves leave).
- **Engraved** by Verovio (tempo marks, expressions, rehearsal marks (drawn in the bar numbers' row while it is on), lyrics): `EngraveRequest.typography`,
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
the playback's. An engine that couldn't start (no output device) is not kept as failed: the next
recording starts it again (`AudioEngine._ensureInitialized`), and the clicks are made again once
it has.

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

**A score can have several recordings** (takes: `EditState.takes`), a lane each at the top of the
Audio tab (`TakeLanes`, `SpanLane`s edited with the lanes' tools, as the instruments' are). A take's
regions say where it is heard, one at a time: a region drawn or moved in one lane is taken out of the
others (`EditState.withTakeRegions`); where no lane has one, nothing is heard and the time goes on
at the tempo of the take heard last. Each take has its own sync: the focus's is the state's own
(`anchors`, `leadIn`, `midi`, so everything that reads the sync, tapping, Align and a MIDI tempo map
included, works on it unchanged; its `Take` holds blanks), each other's is in its `Take`. What plays
is `TakeSplice` (score_engine): the form's passes cut at the regions' edges, each piece timed by
the take heard in it (the same time over as the performance plays it, or its last pass to play it),
(a pass of no length, a warp at the very start, has no piece: it is over as the next begins),
and the sound as `SoundChunk`s, a run one take plays straight on, ramped in and out over the edge's
crossfade (its region's transition, else `EditState.crossfade`, 0.3 s) centred on it (`gainAt`).
`EditorController.timeline` is that splice with two takes or more; the Audio tab edits a sync only
with one, or with a take picked (a click on its lane’s name, `EditorController.editSyncOf`): it
becomes the focus (`EditState.focusing`) and is heard whole in its own time, the playhead carried
to the same place in the score (`ScoreTimelinePasses.carriedTo`). `AudioEngine.setChunks` plays a
voice per chunk, faded with SoLoud's `fadeVolume`/`scheduleStop`, started again only when the
chunks changed (so tapping along doesn't restart it); the clock follows a voice not fading. Video
export mixes the same chunks with FFmpeg (`atrim`, `afade`, `adelay`, `amix`), or seeks the one
file covering it all. Adding, removing, picking and the focus are no Undo steps, yet Undo keeps
each take's edits: they are made to every state Undo keeps alike (`_everywhere`,
`EditHistory.rewrite`), so a state never holds one take's anchors as another's; lane edits, the
crossfade and renaming are steps. `AudioEngine` holds every take's recording at once, decoded in
memory while together they stay within 2 GB (`AudioEngine.memoryBudget`), read from disk as they play past it. Add Recording…
adds a take (the first heard throughout; another with an empty lane, picked, no anchors: Align
it); Replace Recording… (a lane's menu) and a recording dropped replace the focus's, keeping its
sync and lane. Saved as the `takes` module (optional: an older Curator keeps the focus's, with
its sync, and keeps the module unread with every recording it lists, `ProjectDocument._unreadTakes`). A recording that can't be read when the project opens (FFmpeg missing, a damaged
file) is kept as it came (`AudioEngine.keepUnread`), silent: its take, its sync and its file stay,
and the next save embeds it again (`EditorController.recordingOf`); the focus moves to one heard.

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
set by hand are kept behind it (`EditState.anchors`, `EditorController._ownAnchors`, saved as `sync.anchors`) and come
back when the MIDI goes. Using or dropping one is an edit (`midi` in `EditState`, and
`sync.midi` in the project from format 7, its tempos as `[quarter, quarters a minute]`).
The ⋯ Sync menu converts either way, one Undo step each, no format change: Convert to Tempo
Map follows `MidiTempoMap.ofSync` (named "Tempo Map"), a change at each hand-set anchor where
the file reaches it (repeats kept, points to drag), its warps from `warpsOf`, so followed from
Starts at it puts every anchor back; the anchors stay behind it as behind a file. Convert to
Anchors makes the anchors it follows the hand-set ones (those behind it go). Keys on the
selected change: ←/→ a beat of the score (⇧ a sixteenth), ↑/↓ a beat a minute (⇧ a tenth),
onto that step (`SyncEditing.moveTempo` / `retune`). ←/→ on selected anchors nudge by Settings
▸ General ▸ Anchor nudge (1–50 ms, default 10; ⇧ 1 ms); with nothing selected they skip 5 s (⇧ 1 s),
and ⌥←/→ always move the playhead by Settings ▸ General ▸ Fine seek (0.05–1 s, default 0.1;
`EditCommands.arrow`). Space taps while tapping is armed, else plays or pauses, as P always does.

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
Add Image… (an SVG, drawn as vectors, or a raster image: PNG, APNG, JPEG, GIF, WebP, BMP or ICO, kept as it came, or a TIFF, HEIC or AVIF, kept as a PNG of its first frame since only some systems read them: `PatchImage.portable`; the file's type says which), or Paste (⌘V: a PNG, SVG text, or a copied
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
An animated GIF, APNG or WebP (`RasterArt.animated`: every frame decoded) plays with the
playback, its frame picked by the playback time (`PatchArt.paint`'s `time`), over and over from
the recording's start whatever loop count the file asks for, so the preview and a video show the
same frame at the same moment; paused, it holds still. A frame of 10 ms or less shows for 100,
as browsers do. Images other than SVG and PNG / JPEG came in format 26.
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
(`ImageEditing.enabled`). A file is read through `PatchImage.readFile` (Add Image…, a drop, a copied file pasted), which
refuses one over 64 MB before reading any of it; a score file over 256 MB (`ScoreFile.maxBytes`)
and a MIDI file over 64 MB are refused the same way (`EditorController.openFile`, `loadMidiTempo`).
One render of a PDF makes 64 megapixels at most (`PdfPages.fittedScale`: a poster-size page is
drawn whole at a coarser grain, the raster saying its scale).
Decoding is bounded (`PatchImage.decode`), so a small file can't
take gigabytes: a file over 64 MB, or a raster image over 64 megapixels (one inside an SVG
too, read from its header before anything is decoded), is refused; one longer than 4096
pixels is kept at 4096. An animation's frames together are scaled down to 64 megapixels, and
one of more than 2000 frames is refused. An SVG with no viewBox and no width and height (flutter_svg refuses
it; a browser draws it) is given the box around what it draws.

**Spacers make room** (Attach Image too), for an image or what isn't written yet. The bottom
panel's Spacers lane (`SpacerLane`, pinned under the ruler while the switch is on) has the
buttons: Add Vertical Spacer puts a staff of nothing below the lowest lane selected, else at the
bottom (`SpacerEditing.addVertical`; below both players of a condensed pair): an instrument like any
other, with a lane (shown throughout), a name ("Spacer 1", renamed like any part) and a place in
the order. It is engraved as a part of its own after the score's, before the metadata is read
(`Spacers.write`, as condensing adds its parts): the bars of the first part with a key, each an
unprinted whole-bar rest (so the spacing doesn't change), with their time signatures, barlines
and keys as heard, written in its `SpacerKey` (Transposition: concert pitch, B♭, A, F, E♭, D, G).
What else it shows is only drawn (`SceneSettings.spacers`): its height in staff spaces, its five
staff lines or none (`StaffLayer.reach` makes room for a taller one; without lines it is an empty
layer of that height), and Name and clef (`frozen`: the frozen zone's name, clef, key and time;
off, `ScoreRenderer`'s `bare` staves show none and the key column leaves them out). A horizontal
spacer is a stretch of the score (any beats, across barlines) made `HorizontalSpacer.width` staff
spaces wider whatever its spacing: what sounds in it spreads apart evenly by time, what starts
at its start stays and what follows moves the whole width (the patched `curatedSpacers`
option: `Spacers.verovioOption` splits it at barlines, sharing the width out by time, and
Verovio's alignments in each piece move as far as their time is across it), so the rest of the
engraving is as it was. Horizontal ones never overlap. In the Spacers lane they are stretches
edited as the Captions lane's are (one `SpanLane`, the Instruments tab's tools): Draw drags one
out (a click: one beat), Select moves one by its middle or trims an edge, Erase cuts them back;
unlike captions they change once a drag ends (`SpanLaneModel.live` off), each change engraving
again. A gesture's erased pieces name the stretches as `SpanLaneModel.begin` found them (a live
model's change as it goes; one that isn't live reads them as they are when the drag ends, so a
model made anew by a rebuild meanwhile, as the recordings' is, loses nothing). They are fitted to the score's bars where a project opens and after
Replace Score (`Spacers.fitted`: in a bar it has, at a beat there, none past the end or into
the next), engraving again if that changed them; `Spacers.barLengths` takes each bar's longest
part, as Verovio engraves it. Its name's buttons add a vertical spacer, add a horizontal one over the beat the playhead
is in, and Remove Spacer takes out the one selected, or the spacers' lanes selected. In the
preview (`_SpacerHandles`) the one under the pointer is outlined (only there: a video shows
nothing); click selects one (one selection with the images and captions,
`SpacerEditing.selectedVertical` / `selectedHorizontal`, a horizontal one kept by its place;
Delete removes it), drag moves it (a vertical one dropped between two staves, `moveVertical`; a
horizontal one to the nearest beat, ⌘ anywhere, `moveHorizontal`), and a handle resizes it as an
image's does: a vertical one's top and bottom set its height, drawn as it goes, a horizontal
one's right-hand side how much wider it makes its stretch, engraved when let go.
Double-click (or right-click ▸ Edit Spacer…) edits either.
Every change is an Undo
step (`spacers` and `gaps` in `EditState`, format 24); a vertical one's key and any horizontal
one re-engrave (`EngraveRequest`), the rest only redraws. While Attach Image is off they stay
in the project, unengraved; Replace Score keeps vertical ones and the horizontal ones whose first bar
is still there.

**A caption shows under the score** (the Captions extension). A `Caption` is a text and
the score quarters it runs between, so it stays with its bars when the sync changes and shows
once for every pass that plays them (`captionSpans`). Captions never overlap, so one shows at
a time: every edit keeps them apart (`separateCaptions` in `CaptionEditing._set`, and on
reading a project, an earlier one ending where the next starts), and the editors stop at the
free stretch around a caption (`captionRoom`; the dialogs flag one running into another,
`captionOverlapping`). The scene draws it in `CaptionBar` under the staves, which leave
`CaptionBar.reserve` for it while there are any: the text (centred by default) in the score's text font,
and under it a hairline as wide as the text that draws in to its middle (or, set left or right, to
that side) as the caption's time runs out; it rises `ScoreMotion.captionRise` points into place as it fades in over `ScoreMotion.captionFade`, and fades out
as its time ends. It is part of `paint`, so the preview and a video show the same.
How it looks is a `CaptionStyle` (`CuratedScene.captionStyle`, copied into video export): its
font, countdown (`CaptionCountdown`: the hairline, a ring left of the text that
empties clockwise, or none), size (`CaptionSize`; the room grows with it), alignment
(`CaptionAlign`) and backing (`plate`: a rounded plate in the paper's colour, a touch of ink in it,
always solid, so it reads over staves, images and see-through paper). All but the font are the app's (the extension's settings button; `AppSettings.caption*`,
not edits). A caption's text may mark `*italic*` and `**bold**` (`captionRuns`, Markdown's
rule: a marker opens before a letter and closes after one, `\*` is a star, one never closed is
typed text); emphasis in an italic face is upright. The bar, the lane and subtitle files draw it;
the dialogs keep it as typed. The font is the project's when it has one (Project Settings ▸ Engraving ▸ Caption, shown while
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
Undo step (`CaptionEditing.replaceAll`). The sheet's Import… reads an SRT or WebVTT file
(`decodeSubtitles`: UTF-8, UTF-16 by its mark, else Latin-1; 8 MB at most) into rows, in place of
them or around them (a subtitle running into a row is left out): each cue goes where the sync
has its music (`captionsFromCues`, `quarterAtSeconds`), so a cue heard again on a repeat makes one
caption, and cues past the music go. `<i>` / `<b>` become markup; other tags go. Export… writes
the rows (SRT or WebVTT by the name chosen) timed as the recording plays them, once per pass
(`captionCues`). Export's Subtitles switch (shown while Captions is on with captions; not for a
PNG sequence; `AppSettings.videoSubtitles`) writes an .srt beside the movie, replacing one of that
name, timed from the video's start and cut to its bars (`VideoExport.subtitles`, the clipped timeline). A cell's widgets never change while typing (a
row's problem shows by the buttons, not around the row), or the cell would lose the keyboard. Every change is an Undo step
(`captions` in `EditState`); a project keeps them in `state.captions` (format 11). While the
switch is off they stay in the project but are not drawn, exported or editable.

**A chapter names a stretch of the piece** (the Chapters extension, a package:
`assets/extensions/chapters`). A chapter is a place in the score (quarters) and a name; it runs
to the next one. Nothing of it is drawn on the score. At any moment the chapter is the last one
starting at or before the place that sounds (`markerSpans`), so a repeat back into an earlier
chapter is that chapter again and a repeat inside one doesn't split it; music before the first
is no chapter's. They are kept in the score's order, one to a place (`chapters.lua`'s `tidy`),
as the extension's data (`EditState.extensionData['chapters']`, `{"chapters": [[at, name]]}`: an
edit, so opening, Undo and closing take them) and saved in the `chapters` module as they always
were (`ProjectModules.ownData`), which is optional: an older build opens the project and keeps
them. Its `project.load` checks them as a project opens. While the switch is on, the Chapters
lane (an `ExtensionLane` of markers, `lane.lua`) is pinned under the Captions lane in both tabs,
each chapter drawn where it sounds, with the Instruments tab's tool (the Audio tab selects):
Select clicks one (Delete removes it), drags where it starts (never past its neighbours, one
Undo step) and double-clicks it for its dialog (name and From, a `ui.form`; an empty name
removes it); Draw clicks for a new one from the beat there; Erase clicks one away. The lane's
name has three buttons (the connector's `command` nodes): a chapter at the playhead's beat, one
at every rehearsal mark where none starts (the marks as the bar numbers' row shows them), and
remove. Export Video's Chapters switch (shown while an extension gives any; not for a PNG
sequence; `AppSettings.videoChapters`, on by default) puts them in the movie
(`VideoExport.write`'s `chapters`: an FFmpeg metadata file read as the last input,
`-map_chapters`; MP4, MOV and WebM all carry them) and writes their times beside it as
`<name> chapters.txt` (`writeChaptersBeside`: "0:00 Opening" a line, what a video's description
takes). A video's chapters cover it whole (`export.lua`'s `chapters`, the `export.chapters`
port): the one under way at its first bar starts with it, and music before the first chapter is
one named Start. A page carries them in its project (Export to Web's Chapters switch leaves out
the extensions that give any, and their data): the player, which runs the same Lua, lists them
at the top of its side panel, in the times of the recording heard, the one sounding marked, a
tap jumping there. Replace Score carries each to its place (`project.replaced`), saying those
past the end as lost. `test/chapters_extension_test.dart` holds the package to what the
chapters written in the app did, edit for edit.

**A key area colours the top of the score** (the Tonality extension). A `KeyArea` is a stretch of
the score (`start`–`end`, quarters), a key (`MusicKey`: its tonic as fifths from C, so F♯ and G♭
are two keys, major or minor; the thirty with a key signature of seven sharps or flats at most) and
the user's own marking, if any (`label`, 40 characters; "(F major)", "Development"). The scene
draws them in a band along the frame's top (`CuratedScene.keyAreas`, through `SceneSettings`),
which the staves leave room for while there are any (`_bandReserve`, under the top margin's `_top`;
the bar numbers' row moves down with them): each area in its key's colour from its start to its
end (at a bar's start or the score's end, that barline: `_xOfPlace`), a sliver of paper between
two that meet so two of one key are two, nothing where none is, named at its start by its marking
or the key's name, in white, as `TextKind.tonality` looks (Typography, shown while the switch is on;
bold at 1.25 staff spaces by default). Over the names and the frozen zone the band shows the area
the music at their right is in (none in a gap), named at the frame's left, as the zone shows that
music's key signature; one gives way to the next over the tempo at the left's fade. The playhead
runs on through it. A key's colour is its tonic's place on the circle of fifths as an OKLCH hue (C
yellow-green, the sharp keys cooling through green and blue, the flat ones warming through orange
and red, F olive), every major as light as the others and every minor darker, so two spellings of
one key are one colour. The scene is given each area named (`_sceneAreas`): the marking, else the
key's name in the interface's language (`TonalityEditing.nameOf`, `.tr` of "F major": the thirty
names are in curator.pot by hand), named again when the language changes (`followLanguage`, from
`takeSettings`); the web player names them in the viewer's. They are kept in the score's order,
never overlapping (`tidyKeyAreas`: each, in turn, over those before it, which it cuts back or in
two), as `keyAreas` in `EditState` (the controller's `_doc`) and saved in the `tonality` module
(`[start, end, tonic, mode]` and the marking after them), which is optional. While the switch is
on, the Tonality lane (`TonalityLane`) is pinned under the bar ruler in both tabs, above the other
pinned lanes: a `SpanLane` whose model `paints`, each area drawn where it sounds in its key's
colour (outlined when selected), edited as an instrument's regions are, with the Instruments tab's
tool. Select: click to select (Delete removes), drag to move, drag an edge to trim, double-click
for its dialog (`showKeyDialog`, laid out as the region dialog: From and Until, the key from a list
of the thirty, the marking, empty for the key's name, Remove); a click on empty space moves the
playhead. Draw: drag across bars (a click, one beat) and the dialog asks for the key, the one in
force there first (`keyAt`). Erase: cuts areas back or in two. ←/→ move the selected area a bar
(⇧ a beat) and [ / ] trim it to the playhead's beat, in either tab (`nudge`, `trimToPlayhead`,
before the lanes' in `EditCommands`), as they do regions. An area drawn, moved, trimmed or changed
in its dialog goes over the others, as a region goes over its lane's: what it covers is cut back
(`reshape`), from the areas as the drag found them (`SpanLaneModel.begin`, `from`), so what a drag
covered it gives back as it goes on, and the gesture is one Undo step; what an area leaves is left
without a key. The lane's name has three buttons: a key from the playhead's beat to where the next
starts (`nextStart`), Find Keys, and remove.
**Find Keys** (`findKeys`, on an isolate) reads the score's notes
(`soundingNotes`, concert pitch): each bar is how long each pitch class sounds in it and the bars
either side (weights ¼ ½ 1 ½ ¼), the lowest note at each onset counted twice, correlated with
Krumhansl and Kessler's major and minor profiles on all twelve tonics; the likeliest keys through
the piece are a Viterbi path over the bars, each weighing as long as it lasts, a change of key
costing 6 (a few bars' worth), the key signature in force (`concertKeySignatures`: each part's
written key moved by its transposition, most parts winning, a part at concert pitch counting
twice, unpitched percussion none) leaning 0.08 a quarter toward its own major and minor and 0.14
toward the one its `<mode>` names. A change heard within two bars of a change of key signature
moves to it, and each key is spelled as near the key signature in force as it can be (G♭ major
among flats, F♯ among sharps). A score with no notes (a PDF's skeleton) gets its key signatures'
keys, major unless they say minor. What it finds replaces the areas there are, an area from each
change to the next, one Undo step, an area found where one was (the same start, end and key)
keeping its marking. Replace Score carries each area's start and end to their places, counting
those past the end as lost.

**A drop goes by where it lands** (`_ProjectPageState._areaAt`; the hint covers only that
area and says what it takes). On Home, or before a project's score has opened, anything opens (as File ▸ Open, in a tab of its own). Above
the timeline, it is always an image (Attach Image; while that is off, it says so). On the
timeline (the whole window while View ▸ Hide Preview has hidden the preview), the Instruments tab opens a project or a score (in a new tab), and the Audio tab takes a MIDI
tempo map or a recording. Only the tab showing takes drops (`DropTarget.enable`): a page out of sight is still laid out, so it would.

**Find Phrase looks for a melody by ear, not by notation** (Edit ▸ Find Phrase…, ⌘F, or the
toolbar's button by the time, lit while it is open; `PhraseSearchWindow`, a window over the editor
like the Engraving pop-out, moved by its title, not modal). A match double-clicked, or its title's
Collapse, folds it down to a bar at the same top right corner: the match gone to and its place among
them, the one before and after (← →, Enter, ⇧Enter), Expand (or a double-click on the bar, ⌘F, the
toolbar's button) and Close; folded down, the phrase's keys do nothing. The phrase is typed (A–G at the octave nearest the note before, as notation programs place
them; 3–8 the values 32nd to whole, `.` a dot, `-` `=` `0` flat, sharp, natural, R a rest, ↑ ↓ a
step, ⇧↑ ⇧↓ an octave, ← → the selection, Backspace), clicked on its staff (a pitch where clicked,
or a note to select it) or played on its three-octave keyboard, in the clef chosen by the tools
(`PhraseClef`: Auto, treble or bass by where the notes lie, or treble, treble 8vb, alto, tenor,
bass; only how it is written and where a click lands, as the search goes by sounding pitch; the
staff moves up or down so the notes fit). The clef is a select (`AppDropdown`), not a popup menu: a
popup's route goes in under the window's overlay entry, while a `MenuAnchor` draws above it. Verovio engraves it after every
change (`PhrasePicture.engrave`: one bar, its time signature hidden and as long as the notes, eighths
and shorter beamed within each quarter, no barline; the latest engraving wins, `Latest`). What was
entered stays while the app runs. The score is read for it once per score, on an isolate
(`ScoreLine.read`, from `LoadedScore.musicXML`: the file as opened, so condensed and spacer parts are
not in it): each voice of each part, a chord its top note, tied notes one, grace and cue notes left
out, pitches as they sound (`<transpose>`), positions in score quarters; a rest longer than a 4/4 bar
ends a line. `PhraseSearch.find` compares pitches, or in Any key (on by default) the steps between
them, and with Rhythm the time from each note to the next (the last note's length is free, and a
rest counts in the time before the next note). Exact finds only those; Similar is Sellers' edit
distance (the whole phrase against any stretch of a line): a note a step or two off costs half, a
time off up to half, a missing or extra note one, and a match is kept down to
`PhraseSearch.minSimilarity` (65 %); of overlapping ones the best. Matches are listed by place
(bar as Go to counts them, instrument, the transposition from what was typed, the similarity); a
click, Enter or ⇧Enter puts the playhead where it first sounds (`Playback.goToQuarter`), so the
score shows it under the pointer. Nothing is marked on the score, which stays paper; nothing is an
edit or saved.

**Lanes are painted, not cut.** Drawing adds a region and merges it with what it touches;
erasing trims. Touching regions are merged on purpose: a seam between two regions would dip
the staff's fade. During a drag regions may overlap (`Curation.updateLanes`); `normalize`
merges them when the drag ends. Every lane snaps through `snapInLanes`, takes a click's beat (or
bar, zoomed out) through `beatInLanes`, and tells a double-click through `DoubleClicks`
(lanes_common.dart). The cursor over a lane says what a press there would do, and follows the
tool as a key changes it with the mouse at rest (⌥, or V, D, E): every lane's state is a
`LaneCursor` (`cursorAt`). A click on the bar ruler moves the playhead and leaves the selection,
so regions are trimmed to a playhead put there (`[`, `]`) and copied ones pasted into the lane selected.
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

**A trackpad's swipe scrolls; it never drags.** A two-finger swipe comes as pan-zoom events, which
a drag recognizer takes as a drag unless told not to: every drag in the app is given
`kDragDevices` (all but the trackpad; a trackpad's click-and-drag comes as a mouse's), so a swipe
over an image, the Sections editor or a slider scrolls what is under it instead. The time axis and
the score are moved by hand (`SideSwipe`, lanes_common.dart), as a scroll view would move them: the
swipe keeps to the axis it starts on (`SwipeAxisPhysics` holds the lanes' vertical scroll still
while it runs sideways; a Listener sees each event before any recognizer does, so the axis is
known before the scroll view moves, and it is kept after the swipe for the scroll view's fling),
and glides on after a flick. In the lanes it pans the time; on the score it scrubs
(`Playback.scrub`), at the score's own speed there (`ScoreViewState._speedAt`), so the notes stay
under the fingers. A mouse's wheel is not a swipe (it comes as scroll events): over the score it
scrubs turned either way, down moving on in time (`ScoreViewState._wheel`); a trackpad's
up-and-down swipe there still does nothing.

**Auto-Curate fits the frame.** A new score's lanes (unless Settings ▸ General ▸ Auto-curate
imported scores is off: then each lane is whole), Auto-Curate and a lane's Auto-Curate Lane start from where each part plays (`autoCurateMeasures`: rests of one bar bridged), then ask that
same check (`CuratedScene.curatedToFit`, on a copy of the curation, for `videoLayout`) and cut
back until nothing runs off (`fittedCuratedLanes`): in each 4 bars that overflow, the staff that
matters least there is hidden, and the frame asked again. What matters is `LoadedScore.salience`
(`BarSalience`, per part and bar): half how melodic (the top line's steps and range, how many notes
start), a quarter how exposed (how few others sound as its notes start), a quarter the dynamic in
force; unpitched percussion has no line. A part that plays every note of another (the same moments,
two or more, in its pitch classes: unison or octaves) counts a quarter while that one is shown, and
the one left counts as much as what it stands for. Only crowded bars lose anyone: with room, every
part that plays is shown. Once it fits, each cut is tried back (most salient first, its 4 bars then
bar by bar), since it may have been made while the segment around was fuller; a staff left alone
for one bar between cuts goes. Each try plans the piece (a millisecond or two for the demo).
Condensed pairs are their first player's lane, louder of the two. Lanes not asked for stay.

**A region carries its properties.** Besides its bounds a region has properties of its own:
its transitions (how long its staff glides in at its start, `Region.transitionIn`, and out at
its end, `transitionOut`; null is the project's, `Curation.transition`) and the staves of its
instrument it leaves out (`Region.hiddenStaves`, numbers in the part, never all of them: a
piano's left hand where the score leaves it out). Every edit that
reshapes a region keeps them (`withBounds`: moving, trimming, a split by erasing, copying a
lane); a merge keeps each edge's from the region it came from, else the other's
(`joinedWith`; its staves, the earlier one's). Regions that leave out different staves are
never merged (`Curation._normalize`): where they overlap the later one gives way, so they meet,
and the meeting is an edge of its own (`Curation._meetings`, in `edgesInSeconds`) where the staff
coming or going fades (`staffVisibilityAt`) and the instrument's staves glide together while the
instrument stays shown (its spans are joined there). They are part of the region's equality, so Undo, saving (`transitionIn` /
`transitionOut` on a region in the project, from format 6; its staves a fifth item, from
`curation`'s version 2) and video export follow without
more code. The layout glides over each edge's own transition (the longest where edges fall
together; key changes and warps use the project's). A region's properties are set in its
dialog (double-click it), or at every selected edge at once in the Instruments tab's
toolbar (`LaneEditing.setTransition`; the staves by its ≡ menu, `setStaffShown`, shown while
a selected region's instrument is on more than one staff). A region leaving out staves shows
its instrument's staves stacked in its middle, those it shows filled. A selection is of edges: a click in a region's middle
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

**A lane can be split, a lane a staff.** An instrument on several staves can have a lane for
each (a lane's ⋯ or right-click ▸ Split Lane; Join Lanes on a staff's puts it back): each staff
then shown, edited and spaced on its own. The instrument's lane stays what is shown and saved,
each region leaving out the staves not shown then; the staves' lanes are another way of
setting it (`Curation.setSplit`, the instruments split with their staves' count). A staff's lane
has the id `partId/n` (`Curation.staffLaneId`, `staffOfLane`; a part id has no `/`), and every
edit by id takes one (`lane`, `setLane`, `setLanes`, `updateLanes`, so painting, dragging and
pasting too): an edit of a staff's lane makes the instrument's again from its staves'
(`Curation._combined`, a region for each stretch some are shown), and one of the instrument's
(loading, joining, a pair's) makes its staves' from it (`_projected`). The lanes follow
`EditorController.laneRows` (an instrument's id, or its staves' in its place) where they used
`laneParts`, which stays the instruments' order: moving a staff's lane moves its instrument
(`instrumentOfLane`). A staff's room (its Spacing…) is `EditState.spacing` under its lane's id,
added between it and its neighbours and, at an outer staff shown, to the instrument's
(`SpacingPlan`'s `staffRoom`); joining drops it. Which instruments are split is
`EditState.split`, saved in `curation` (`split`, the part ids, from its version 2).

**Editing the score's texts is deprecated and unreachable.** No menu, toolbar button,
dialog or double-click changes a text any more; add nothing to it. The engine and the
controller keep it (`EditorController.editTexts`, `textEdits` in `EditState` and the project),
so projects with text edits still open and engrave as saved, Undo steps through them, and
Replace Score carries them over. A double-click on a text does nothing.

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
`cond-` prefix (`Condenser.idPrefix`) on the original's id, copied after the text edits, so an
edit of the original is in the copy too. A slur or hairpin in a shared part keeps both of its ends or neither. Any two
single-staff instruments with the same clefs, transposition and meters throughout, and as many
bars (the shared part is written bar by bar from both), can pair
(`Condenser._writtenAs`: every change of those, where it takes effect, read for what it
means): the shared part takes the first player's attributes, and where the second is
written in another key its bars are spelled again against the first's (`Condenser._respell`). A
condensed pair is one lane: `Curation.join` keeps the second player's lane equal to the
first's (an edit of either is an edit of both; joining unites them), and the Instruments tab
shows only the first (`EditorController.laneParts`), named for both.

**The instruments' order is a layout, not an engraving.** Verovio engraves in score order,
but every staff is drawn on its own (Verovio's brackets and system labels are left out; the
frozen zone draws a brace for an instrument on more than one staff, `StaffBrace`; its staves
move as one, as far apart as Verovio put them, where cross-staff notes were placed, a staff a
region leaves out taking no room, and its barlines run on between the staves shown, a
`StaffJoin` without the starting line; `ScoreRenderer.barlinesThrough`), so the
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
(`StaffJoin`). The room between staves changes as they come and go, so these are drawn each
frame, as an instrument's own are (a tile's barlines cross only its staff's lines): each barline's strokes
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

**The playback line can take a colour of its own** (Project Settings ▸ Instruments ▸ Playback line
color, above Color names; `EditState.playheadColor`, an edit saved from format 25, null for
`RenderStyle.pointer`'s blue; `CuratedScene.pointerColor`, in `SceneSettings`). It is the score's fixed
pointer, so the preview and the video draw it alike. The lanes' playhead keeps the accent.

**Bar numbers are drawn, not engraved** (Project Settings ▸ Display ▸ Bar numbers,
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
While it is on, rehearsal marks leave the music too (their ids in `apart` with the tempo marks') and
stand in the row at their bar's left (`ScoreText.measure`, as edited), boxed, in full ink, bold
unless Typography ▸ Rehearsal marks gives a face, 1.8 staff spaces at its size; the bar's number
follows the box. Off, Verovio engraves them over the top staff as before.
That is a flag (Project Settings ▸ Flags ▸ Rehearsal marks in bar numbers:
`EditState.rehearsalInRow`, saved under `flags` from format 22, null taking `AppSettings`'s, on
until Save as default; `CuratedScene.rehearsalInRow`, in `SceneSettings`): off, they stay in the
music with the row on. Changing it only redraws (the display list made again); Flags ▸ Reset to
Default sets every flag in one Undo step (`EditorController.setFlags`).
Flags ▸ Centered lyrics (`EditState.centeredLyrics`, under `flags` from format 23 as `centredLyrics`, the flag's first spelling, null taking
`AppSettings`'s, off until Save as default; `EngraveRequest.centeredLyrics`, an Undo step that
re-engraves) centres each syllable, or an elision's syllables together, under its notehead, as
Verovio otherwise sets them from just left of it; one an extender follows stays there, so a
melisma's line runs on. The patched `curatedLyricCentre` option moves it in Verovio's syllable
spacing, before syllables are kept apart, so the music still makes room.
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

**A large score opens without stopping the app.** Everything slow about opening runs on other
isolates, so the window keeps drawing: reading the MusicXML and preparing it (`_prepare`, some
half a second for a big orchestral file), Verovio, a PDF score's whole layout (`_fromPdfApart`:
its skeleton written, read and laid out as printed), the replacement read of Replace… and Edit…
(`_readApart`), and, for a new score that will be auto-curated (`measure`), what each bar plays
(`BarSalience`). That last one runs after the engraving, not beside it: isolates from
`Isolate.run` share one heap, and a second parse alongside Verovio's copying out made
collections that stopped the main isolate for a quarter of a second. Each step is said as it
starts (`LoadStage`, `EditorController.loadStage`), and the page's busy overlay shows it as a
bar creeping on to where that step ends. A PDF score's pages are read a screenful ahead of
what the preview shows (`CuratedScene.buffer`, each paint), and while a system drawn isn't
ready (`PdfScoreArt.isWaiting`) the preview says "Loading pages…". Still on the main isolate:
fitting a new score's lanes to the frame (`curatedToFit`, a few hundred milliseconds).

**Closing asks before anything goes.** Close (⌘W, or a tab's ×), Quit and the window's close button offer
to save unsaved changes first (`_ProjectPageState._confirmDiscard`), showing the project they are in; quitting
(`AppLifecycleListener`'s `_AppWindowState._exitRequested`) asks of each project in turn, and Cancel
keeps them all. On macOS the close button quits as Quit does
(`MainFlutterWindow.windowShouldClose` → `NSApp.terminate`), so the question is asked while the
window is still there.

**Each project is a tab, and Home is one too.** `AppWindow` holds Home and every project open
(`_OpenProject`, a `ProjectPage` each: its own controller, document, keys, drops and messages,
its own `ScaffoldMessenger`); `ProjectTabs` shows once one is. Open…, Open Recent, Open Sample, a
drop and the Finder open in a new tab, or show the tab where that file (or the sample) is open
already. A page whose tab doesn't show is kept as it was left, out of sight (`Offstage`), its
tickers stopped and its focus let go (`_AppWindowState._tab`); leaving it pauses its playback and
closes Find Phrase and the Engraving window (one at a time, over whichever tab shows). There is
one menu bar (on macOS one `PlatformMenuBar` may be built): the window builds it for the tab
showing, from that page's state, and a page says when what it offers changes (`onMenusChanged`).
Show Next / Previous Tab (⌃Tab, ⌃⇧Tab: Window on macOS, View elsewhere) go round the tabs, Home
among them; past the window's width the strip scrolls, and to the tab showing when another does (`_ProjectTabsState._reveal`). A project's tab dragged along the strip changes places with those it passes (`ProjectTabs.onMove`, `_AppWindowState._moveTab`: the order of `_projects`), following the pointer over the others, which slide aside. View ▸ Show / Hide Tab Bar (⇧⌘T, `AppSettings.tabBar`) hides the strip, the editor's toolbar
taking a button that shows it again meanwhile (`AppIcon.tabBar`); Show All Tabs (⇧⌘\) shows it again. The strip folds up under the menu as it goes, still painted
(clipped, kept in the tree), and the window has a background under everything: a place left
unpainted, even for a frame, shows the window's black backing. AppKit's own window tabs are off
(`MainFlutterWindow.awakeFromNib`: `allowsAutomaticWindowTabbing`), or it would add items of those
names to View for tabs of windows the app doesn't have. Closing takes the tab away at once and the page drops its editor
(`ProjectPage.closing`); the page itself goes once `ProjectDocument.close` has run (after a save
under way), the tab after it showing (or before it, or Home). A project that doesn't open says
why and its tab goes. A score opened again while its project isn't saved yet shows that project's
tab (`_OpenProject.file`); a file the system asks to open while a dialog is up waits until it has
gone (`_openFromSystem`); Save As onto a project open in another tab is refused. Two projects open on one recording file (a linked one) share SoLoud's one
sound of it, which the last to let go disposes (`audio_track.dart`'s `_holders`).

**Replacing the score keeps the project.** Another score file picked by Project Settings ▸
Project Info ▸ Score ▸ Replace… (read over the settings window, refused past `ScoreFile.maxBytes`
as on opening: `EditorController.prepareReplacement`), another PDF picked there (set out in its
own import first, which takes the window, nothing carried into it from the open score), or what
Edit… hands back (the score editor's MusicXML, or a PDF's import set again) is engraved with the
project's edits carried over to it (`EditorController.prepareReplacementWith`, `ScoreSwap`), and
only then swaps it in, like opening, keeping the recording, the path and the view
(`replaceScore`). A score file makes the project a score's, a PDF a PDF's (`ProjectState.kind`,
`pdf`). A PDF's replacement holds the pages it is drawn from (`ScoreReplacement.pages`): the open
PDF's when its import was set again, kept open; another's, which take their place once it is put
in, and are closed with it when it is declined or another score was opened meanwhile
(`discardReplacement`); if it can't be made, the caller still holds them. Instruments are matched by id and name, then by name (an
instrument added above renumbers the rest), then by id (renamed); lanes, names, pairs,
condensing, order, sections, name groups, a lane's split and each one's room (a staff's too,
by its lane's id) follow them, and an instrument only in the new file is curated as on
import. `ScoreSwap.carry` copies the state it is given, so what has no part id or position (the
project's kind, a PDF's layout, the view, modules kept unread) stays as it is. Positions (regions, anchors and warps, images, captions) keep their bar and their
distance into it, no further than its end; a barline stays that barline. A MIDI tempo map's warp
jumps at the same moment of the file (as an anchor keeps its time) and goes on from the same bar;
one with nowhere to go, and those after it, are left out and counted. A text edit follows
its text: the same instrument, words and kind, by id, else in the same bar (ids the app gives
in document order shift). What has no place (past the new last bar, a removed instrument's
text) is dropped. When the files differ (instruments, bars, time signatures, bar lengths,
tempo, edits lost) a dialog lists it before anything changes. Undo starts again from the
replacement: its steps were of the old file.

**The score is edited as MusicXML, then replaced.** Project Settings ▸ Project Info ▸ Score ▸
Edit… opens the score's MusicXML (`LoadedScore.musicXML`) in an editor over the window
(`score_editor.dart`); Done hands back the file as edited, which replaces the score (above)
(`ProjectDocument.prepareReplacementWith`, the same carrying over, dialog and fresh Undo); nothing
edited, or Cancel, changes nothing. `EditableScore` (`score_editing.dart`) keeps the document's
elements and edits them in place, never a model of its own written back out, so what it doesn't
know (sounds, layout hints, other notations) is kept as it was. It gives every note, rest, bar,
direction and slur an id `cxeN` (an id it had is kept aside and restored on export); Verovio
keeps those ids and the bridge records them (`EditorId`), so a click finds the element drawn
there (`ScoreDisplayList.sourced`). A bar is never changed in place but copied, so Undo is a list
of each part's bars (`edit` makes one step of whatever it wraps). After every change it tidies the
bars it touched: rests merged and written by the beat, a voice filled or dropped, beams by the
time signature's groups, tuplet brackets, accidentals spelled for the key and the bar.
The view is a galley, one endless system, engraved a few bars at a time so a key typed engraves
only its own bars again: a chunk is `EditChunk.barsFor` bars (24 staves' worth: two of an
orchestra, six of a piano; Verovio's time is as the notes are many), engraved with the bars it
takes to engrave them as they are in the whole score (`EditableScore.chunk`): the bar before (so
the first carries on from a barline, not a system's start) and the bar after (a tie into it, a
clef change before the barline), and as many more as a slur, hairpin, octave line, pedal or
ending begun in the chunk runs on for (up to `EditableScore.reach`; one with a single end in
those bars is left out of them: Verovio would take a slur's end with no start for the next
slur's). A chunk draws what starts in its own bars, whole, and nothing that starts in the others
(`EditChunk.owns`, by an item's left edge, from the barline before its first bar; what is drawn in
pieces, an ending, by its first piece, whole: its closing hook lies on its last barline as that
barline does, so the bridge records an ending as a source, `ScoreDisplayList.wholes`), so chunks side
by side draw each thing once, as one engraving of the score would (the test counts them). What
the chunks can't agree on is where things are pushed up or down out of each other's way: a text
wider than its bars may be drawn over a slur the next chunk has. A bar written again engraves
its chunk, the one after its last bar and the ones before whose slurs reach it, nearest the
view first, up to six at a time, and they are laid end to end with staves aligned to the widest
gap any chunk needs. A bar's text is written once (`_xml`: a bar is never changed), what is in
force at each bar is kept up to the bar that changed (`_contextBefore`), and an Undo step is the
bars that differ, by their place. Scrolling and zooming (a pinch, ⌘ and the wheel, about the
pointer) draw the score again and build nothing: the painter listens to them. A strip along the
top numbers the bars (a click on a number selects the bar); a rectangle dragged out from where
nothing is selects what it touches, ⌘A everything; ⌘G goes to a bar. In note input a faint note
follows the pointer and a click puts it in (`_placeAt`: the staff's middle line is the clef's
`middle`, half a space a step; the time is the note value's grid step nearest, between the
notes either side as the engraving spaces them, `EditGalley.timeNearX`); over a note a click
selects it, as outside note input, where a second click in the same place starts note input.
A marking (a dynamic, a text, a tempo, a hairpin: a `<direction>`, `EditableScore.markingsOf`) is
moved in music, not in points (Verovio places a direction by its time, staff and side, and reads
no offset): dragged, it follows the pointer faint and a line shows where it would go
(`_dropAt`: as far on or back as it was dragged, at the nearest note or rest of the staff or
step of the note value's grid, `placeNear`; up or down by more than a staff space and a half,
on the nearest staff, over or under it by the side of its middle), and let go, it and the other
markings selected go as far (`moveMarkings`); ⌥←→ steps them on and back the same way
(`stepMarkings`), ⌥↑↓ a place up or down, from under a staff to over it to under the one above
(`liftMarkings`, when no note is selected: those it transposes), ⇧⌥←→ makes a hairpin end later
or sooner (`stepEnds`). A hairpin's end (any line a direction starts: the first end of its kind
and number after it) goes as far as its start; one that would end past the last bar stays. The
direction is the same element in its new bar, so it keeps its id and stays selected.
The caret may be past the last bar (the last is full): that place answers as an empty bar the
last one's key and time are in force in, and a note typed there adds its bar. A caret placed
by a click is at the note there exactly (`EditableScore.onsetAt`: the engraving's place is in
3840ths of a quarter, which a septuplet's notes are not). While a popover's field has the
keyboard the editor takes no key (it is asked before the field, and a key it took would never
reach it). A time signature that says no length is read as none, and a score whose instruments
have different numbers of bars is refused, saying so. The keys are
Dorico's: ⇧N or Enter note input, 1–9 note values (6 a quarter), `.` dot, `-` `=` `0` flat,
sharp, natural, A–G a note at the nearest octave (⇧⌥ adds to the chord; Q chord mode), `,` rest,
Space on, T tie, S slur, V the next voice, R repeat, `/` and ⇧/ grace notes (crossed through or
not), ⌥↑↓ a step, ⌘⌥↑↓ an octave, ⌥= ⌥- the same
sound spelled as the note above or below, ⌥←→ ⌥↑↓ a marking moved (⇧⌥←→ a hairpin's end), `[` `]` `{` `}`
`'` articulations, and the popovers: ⇧D dynamics and hairpins, ⇧T tempo, ⇧M time, ⇧K key,
⇧C clef, ⇧X text, ⇧B bars (`+2`, `-1`) and barlines, ⇧R repeats (`1.`, `1, 2` an ending over the
bars selected; `segno`, `coda`, `D.C.`, `D.S.`, either `al Fine` or `al Coda`, `Fine`, `To Coda`),
⇧A a rehearsal mark (the next after the last before it offered), ⇧H holds, ⇧O ornaments, ⇧L
lyrics (Space or `-` to the next note), `;` a tuplet (`:` ends it). A time signature change fills
or cuts bars rather than rebarring the music after it. An ending is written in every part
(Verovio pairs a start with the next ending of its number), in place of those it overlaps, the
same one over the same bars again taking it out, and closed where its last bar ends in a repeat; a
barline changed keeps the ending it holds. A segno, coda, D.C., D.S., To Coda or Fine goes over the
first part's top staff with the `<sound>` `ScoreForm` plays it by, so warps from the score follow
it. A segno or coda sign is tagged itself (Verovio draws it by its own id, not its direction's) and
a rehearsal mark is its direction's (drawn as that id and "-reh"), so either is clicked, moved and
deleted as a marking. A grace note is the next note's or rest's (`_Event.graces`): `locate`
doesn't find it (`isGrace` does), it stays before what is typed over its rest, and a bar of
rests one is before stays rests.

**The MusicXML view edits the score as text.** The toolbar's MusicXML toggle shows the score as
its MusicXML in a `CodeView` (the LilyPond editor's code view) in place of the panels and the galley:
`EditableScore.toMusicXMLText`, an element a line, an element's text as it was written, the file's
own ids and not the editor's, the caret on the line of what is selected (else the caret's bar). Its
keys are the text's: the editor takes none while it is shown, or a letter typed would be a note.
Toggled off (or Done), the text, if changed, is read as a score of its own (`EditableScore.parse`)
that takes the place of the one before: everything is engraved again and nothing stays selected.
The one before is kept (`_earlier`), so Undo goes back to it once the new one has nothing left to
undo, and Redo on again (`_later`, which a change that makes a step leaves behind:
`EditableScore.undoStep`); its own Redo is forgotten (`forgetRedo`), the score having gone on
another way. A text that can't be read stays, what is wrong listed under it with its line and
column (a click goes there; an XML error's place is the text's own offset, `FormatException.offset`
of that text only). The bar the caret was moved to is gone to and its first note selected
(`MusicXmlLines`: a part is a `<part>` line, a bar a `<measure>` line). The text is kept while the
score is as it was made from (its own Undo, its caret), else made again. Neither it nor LilyPond
is coloured by re_highlight (re_editor's): that colours the whole text on every change and copies
what is left of it at each word it colours, so its time grows as the square of the text (an
orchestral score's 55,000 lines: 35 seconds; a 500 KB `.ly`: 3 seconds), while a line coloured
alone as it is drawn (`musicXmlTokens`, the controller's span builder) costs nothing that grows
with the score; MusicXML written an element a line has nothing that runs over lines but a comment.
LilyPond has more (a block comment, a string, Scheme's parentheses), so each of its lines is read
from where the line above left off (`lilyPondTokens`): `LilyPondStates` keeps that for every line
read, through what is folded too, and reads again only from the first line that changed (every
line of a 500 KB `.ly` coloured: 5 ms). Elements whose tags are on lines of their own
fold (`MusicXmlFolds`). What is offered (`MusicXmlPrompts`) is the MusicXML 4.0 schema's, by name:
after `<` what the element the caret is in holds, in the schema's order (put in with its end tag,
the caret between, or as `<chord/>`), after `</` its end tag, in a start tag its attributes (put in
as `type=""`), in quotes or an element's text the values the schema lists (and `<mode>`'s, which
only its documentation does), after `&` an entity. The element the caret is in is read back from the
caret, at most `MusicXmlPrompts.reach` lines; an element seen whole on the way that has only one
place to be (a `<measure>` in a `<part>`, a `<note>` in a `<measure>`) answers at once.

**A PDF score is the PDF, cut by rectangles.** A `.pdf` is imported (`pdf_import.dart`; File ▸ Import… ⌘I and Home's Import…, their own beside Open…, whose picker lists no PDF; one dropped or opened from the Finder or Open Recent is imported too):
`PdfPages.read` finds every page's systems (`PdfDetect`, on PDFium's ink at 2.5 pixels a point:
staves by row projection (five lines evenly apart, a space under a fortieth of the page's width;
of fives that overlap, the one whose weakest line fills most of its row, so a tie's crest a space
off a staff is no line of it; a line a leaning scan breaks in two taken whole, its ends looked
for a fifth of a space either way), systems by a line joining them, braces, where the music starts past
the clef, key and time signature, barlines, the row between two staves least ink crosses) and
the instruments: the system with the most staves names them, and every other system's staves
are matched to them by the PDF's text (names, abbreviations) or, with none, by how alike their
ink is (`PdfDetect.match`, a monotone alignment: a staff left out is a hidden instrument, a lone
staff of a piano one of its two, a staff again a divisi). The user fixes what is wrong; that is the
only place anything is worked out of the pixels. What it decided is a `PdfScoreLayout`, the
project's `pdf` module (the PDF itself is the source score file, byte for byte), and a skeleton
MusicXML written from it (`musicXML`: a part per player, a whole note where a bar is played, the
meters, keys, upbeat and tempo the user gave) is the score the rest of Curator reads, so
curation, sync, captions, export and the web page work as for any score. The project is a PDF's
(`ProjectKind.pdf`, `EditorController.isPdf`): no Find Phrase, Align or condensing, and no
auto-curation (Auto-curate and Auto-Curate Lane gone, lanes on import and a re-import's new
instruments empty, drawn by hand) unless Settings ▸ General ▸ Auto-curate PDF scores
(`autoCuratePdf`, off) is on (`canAutoCurate`); turned on or off, the open project follows at once. Replace… with a
score file makes it a score's project, and a score's project replaced by a PDF is a PDF's. The main view draws no
engraving: each system is drawn by PDFium as printed (RGBA, on nothing; `PdfPagesSource`, a few
systems ahead of the view, `CuratedScene.ready`, and an LRU of decoded images: the systems a
scene asks for together, `PdfScoreArt.load`'s holder, are never let go for one another, and each
video frame got ready holds its own until it is drawn), and each staff's
bar is the rectangle of it its region spans (`PdfSystem.regionOf`), the masks clipped out (a mask is every
lane's, or one lane's, `PdfMask.part`: Mask Lane (M) gives it the selected staff's, or the one drawn from; Mask All
Lanes (⇧M) none;
`masksOf` gives a system's, and the ink measured leaves a lane's out of its staves only); never tinted,
recoloured or processed. Each staff's region is its own: the barlines (and where the music starts
and ends) are the system's, every staff's, but a region's four sides are its staff's alone
(`PdfStaff.regionTop`, `regionBottom`, `regionLeft`, `regionRight`; a left or right left null is
where the system's music starts or ends, and goes with it). A region holds its staff's lines and
is a space wide at least (`PdfSystem.withRegion`). Two regions may overlap: what lies in both is in
both pictures, and in the ink measured a mark that lies whole in two regions is both staves'
(`PdfDetect.assign`, `PdfParts`; one partly in a region goes to the staff whose region holds most of
it, and a mark through two staves' lines, a barline, is cut pixel by pixel, each the staff's whose
region it is in, where they overlap the one whose lines are nearest: `PdfSystem.staffAt`). Room in
no region is no one's: what is printed there (a line of text between two staves, a staff's bars
past a region cut short) goes with no one, in the picture and in the ink measured. The `pdf`
module's version 1 kept a system's top, bottom, cuts between staves and gaps below them; version 2
keeps each staff's region (`PdfScoreLayout.upgradeJson` reads the first as the second: the regions
meeting at the cuts, apart across a gap, their sides the system's). What the import inserts at a bar is the score's: tempo marks
(`PdfScoreLayout.tempos`, words and a speed; the first part writes them, `tempoId`, and the
display list sets each apart where its bar starts, so the frame's left names the speed as for
any score; a speed past the first bar is written, not played), keys (concert; read off a
transposing staff in the dialog, `SpacerKey.concertOf`, each instrument showing its own,
`keyOf`) and meters; or one instrument's (`PdfInstrument.clefs` per staff, `meters`): its own
time signatures change only what its staves' frozen zone shows (`meterOf`), never the bars or
beats, which the first part's `<time>` sets. An instrument's transposition follows its name
(`keyForName`, `renamed`). A divided instrument (`PdfInstrument.divisi`) is a part a division
(`P6`, `P6d2`…, `players`): a one-staff instrument's further staves in a system (`PdfStaff.staff`
2…) are its divisions', so a system printing it on one staff leaves the others silent and
curation hides them. A blank lane (`PdfInstrument.blank`, the import's Add Blank Lane) is a part
no staff of the PDF is: a staff's room in the main view, drawn empty and unnamed, no signature in
its frozen zone (`_bareStaves`, `_unnamed`); auto-curation leaves it shown (`isBlankLane`), and its
lane and Spacing… say when and how much room there is. Export to Web writes each system's picture as `score/pdf/N.png`: those the page's bars are in, and a frame's width of the music either side of them, which a page of some bars shows too.

**What is found on a page, and how a scan's is.** `PdfDetect.page` looks at the page with its staff
lines level (`PdfDetect.flat`: a scan of a page that lay curved has a staff's lines rise or fall
some rows on their way, so no row holds a line; the page is taken in strips of 48 columns, each
moved up or down, in 16 bands down the page, to where its lines meet those of the strips between
it and the page's middle one, three lines or more meeting, three rows from its neighbour at most;
only up and down, so what is found across the page is where it was; a page within two rows of
level is left as it is, a row's move putting a step in what crosses a strip's edge, and
`PdfRaster.level` says it was looked at). Staves are one system where a line joins them
(`_joined`): near their left ends, or anywhere along them when it runs on through one of them (a
barline; a faint scan's system line is broken), followed as it leans with a few rows missing
(`_down`). Where the music starts (`musicStart`) is looked for staff by staff, each from where its
own lines start, and the furthest is the system's, placed where its middle staff starts (staves in
different keys have their accidentals where another's are not, and a tie held over fills the way
from a clef to its first note: all their ink together is one long mark): the clef, then what
follows closely and is no wider than an accidental (the first up to two spaces off when as tall as
one, `_accidentalLike`; a filled notehead never, `_headIn`), a time signature a little apart when
alike in most staves (`_signatureLike`; two digits filling the staff are the last of it), the
staff's lines left out by their thickness. A barline (`barlines`) is a line through all of a
staff's lines (`_down`), thin most of its way (`_thin`: a time signature's digits one over the
other run through a staff too), found in most staves where it would be by how far most lean from
one staff to the next, and a barline in most: joined to the next staff's, or with no notehead on it
as far as it goes (`_headless`; a lone staff's ends at the staff, `_alone`); it is placed where its
staves' middle one has it. Still wrong, on the scores this was worked out on: a key whose
accidentals touch is cut through, a staff of faint broken lines is not found, and a time signature
a strip's move put a step in is read as no time signature.

**A PDF's page stays loaded while it is asked of.** PDFium keeps what it worked out of a page
(a scan's picture decoded, some 105 of the 135 ms a render of a 600 dpi page takes; its text)
only while the page is loaded, and a page is asked of many times in a row: each staff's name as
it is read, each system's ink (`PdfPages.measure`) and picture, the import's page shown closer.
So `PdfiumDocument` keeps the page asked of last, and its text, loaded until another is asked for
(`_load`, `release`), and the worker lets every document's go 20 s after its last job (`_Worker._kept`:
a decoded scan is some 13 MB). A scan's first render of each page is PDFium's to decode: that is
what reading one costs (some 140 ms a page; one with text some 25), and measuring it once more
(Done). A system's ink is measured in passes over its pixels, none for each staff or bar
(`PdfDetect.assign`: marks labelled, summed up and given to staves; `PdfDetect.ink`: the ink
summed and each staff's first and last row in each bar in one pass): some 30 ms a system of a
dozen staves. Nothing here changes what is found.

**The import goes in steps, and reads the words on the pages.** `PdfImport` is five steps
(`_Step`, a bar across the top, Back and Next below): Pages (only here can the systems found be
dragged, drawn or removed, and staves and barlines added, by Draw Region and Add Barline, or
removed). Each staff's region is edited as an image on a canvas: the region under the pointer is
outlined, a click selects it (`_RegionSelection`; in an overlap the selected one, else the one whose
lines are nearest) or a barline, never a bar, and the region selected has a round handle at each
corner and a bar at the middle of each side (`_Handle`; a side is grabbed anywhere along it). Its
handles resize it, a drag inside it moves it once the pointer has gone 3 pixels (a click alone
selects), over a neighbour's region if need be, never off its own lines or the page
(`_RegionDrag`, `_dragRegion`); its edges snap, within 5 pixels, to where the system's music starts
and ends and to the other regions' edges, each snap drawn as a guide (`_guides`), and a side snapped
to the music's start or end follows it. Draw Region (R) drags out a region: the staff whose lines
it holds, found across the page's width (`PdfPages.staffIn`), gets it, one already found its region
replaced, else a staff added to the system it lies in (`PdfSystem.withStaff`, `fit: false`) or a
system of its own; a click with it adds a staff there (`withStaff` giving it the room between its
neighbours' regions). Delete removes the region (its staff) or barline selected, Remove System its
system, `withoutStaff` leaving a staff removed's region no one's; elsewhere the page shows the
regions, not their boxes: `_PagePainter.editing`), Instruments (the list, dragged by its handles, a ⋯ menu each; Add
Instrument and Add Blank Lane are tiles in the accent under it; each staff's chip, and the staves
no one's), Edit (the masks: Mask Lane leaves what it draws out of the lane picked, `_maskLane`,
a staff's click or the toolbar's picker; Mask All Lanes out of every one), Changes (a bar's,
inserted; the tempo marks read off the pages, each added or dismissed, or all) and Review (the
score's fields and what will be imported, then Import). No step's action is only in a menu: the
toolbar holds each step's own (`_stepTools`: Pages' tools, Remove, Remove System and Detect Page Again; the instrument's
Rename, Move Up and Down, Remove, Add, Read Names, the next staff no one's; Edit's tools; a change
inserted at the bar selected). Each page's words are read
once the layout is there, in the background (`_readText`, the page with the most staves and the
next first): the PDF's own text where it has some (`PdfPages.textRuns`, PDFium's text runs and
their boxes), else, on a Mac, read off a picture of the page at 3 pixels a point by Vision on the
device (`PdfOcr`, the `curated_score/ocr` channel, `PageText` in `MainFlutterWindow.swift`, drawn
on white). What they say is geometry only (`PdfText`, so the PDF's text and a scan's read alike):
an instrument's name is the words left of its staves in the first system naming it, a later
different one its abbreviation (`names`; a new import's "Staff 1"… are named so by themselves,
names in capitals written as names); a tempo mark is the words above a system's first staff that
name a tempo or a change (`isTempo`) or stand before a metronome mark on its line, at the bar they
start over (`tempos`, `tempoOf`; the speed is taken as quarters). A field being typed in keeps
its keys (the import's are asked first: only ⌘Z and Page Up / Down stay its own); where a system's music ends (`PdfSystem.right`) is dragged as where it starts (`_EndDrag`: a barline at
the end goes with it, and it stops at the barline before); a drag's Undo
step is made at its first move, so a click on a barline only selects it; opened again
(Edit…) and left as it came, Done hands nothing back, and nothing is replaced.

**Read with AI asks a model, then checks it against the page.** The import's toolbar button (by
Undo and Redo, on every step) reads every page with systems with the model picked in Settings ▸
General ▸ AI for PDF import (`AppSettings.pdfAi`, asked at each reading through `PdfImport.ai`:
Settings opens over the import, and a key put right there is the one sent; none: it asks for one
first), only when clicked:
`PdfAiReader` shows the model each page as two PNGs drawn on white (the page, and its systems'
starts enlarged: names, clefs, keys, time signatures), each staff found numbered in red in a column
at their right (`PdfAi.labels`, in the bundled IBM Plex Sans), and asks (`PdfAi.prompt`) for JSON:
each staff's instrument (by id, from the list it is given), name, printed name, clef and key, where
its middle is and its region (its own top and bottom: two staves' may meet, lie apart or overlap);
each system's staves, barlines, time signatures and tempo marks. The page the instruments are named from goes first,
alone (its answer names them for the other questions), then the rest three at a time; Stop ends the
requests under way, one whose connection is still being made too, and asks nothing more
(`AiClient.close`). A model's places are rough and sometimes made up, so they
are checked (`PdfAi.refine`, on the worker with the page's ink): where it says the staves are,
against where they are, gives a line that sets its other places right (`PdfAi.fit`), and unless most
staves lie on it within ¾ of a space none of its places is taken. Taken, each region's edge goes on
the quiet row nearest where it says (`PdfDetect.quietRow`), a system's top and bottom never into ink
its outer staves reach (`PdfDetect.inkEnd`). Between two staves the regions meet on one row, or end
and begin with room between that is no one's, as it says; where it says they overlap, they do only
if no row between the two edges is clear of ink (`PdfDetect.clearRow`, the barlines' columns left
out): each then ends within a space of where it says, and with a row clear they meet on it, a cut
there losing nothing. Its barlines are lined up in order with those found (`_barlines`), a
found one kept where it is, one it adds put on a line through the staves there
(`PdfDetect.lineNear`), and a found one it leaves out removed only from a lone staff; too few
paired and its barlines are passed over. Staves found apart join into one system only where their
bars line up. A staff it says was missed (one it gives no number, only where it is) is added only
where the page has it (`PdfAi._missed`): five lines found within three spaces of where it says,
looked for in the strip between the staves either side (`PdfDetect.staves` on those rows), across
the system's music and spaced as its staves are; it joins the system its answer's system's staves
are in, and is then a staff like the others (its region, instrument and clef as said). No lines
there, or places that are no good, and nothing is added. What it names is taken as said (`PdfAi.apply`): staves given to the instruments it
says (a one-staff instrument's further staff a division), instruments renamed (a name spelled
otherwise, "B♭" or "Bb", kept) and abbreviated, the concert key the most staves say (each read
through its transposition, concert-pitch staves counting twice), and clefs, time signatures and
tempo marks put in at their bars where they differ from those in force; nothing is taken away (a
staff found is never removed). It
is all one Undo step, made when the reading ends (stopped: the pages read until then); meanwhile
nothing is edited (`_busy`) but the pages are turned. A page that fails is passed over and said in
the status line; the first failing ends it all.

**A model is examined before it reads.** Settings ▸ General ▸ AI for PDF import (and Read with AI
with none chosen) opens a dialog (`showPdfAiModelDialog`) where a model chosen takes the exam
(`PdfAiExam`, run by `PdfAiExamRun`): the first two pages of a scanned orchestral score
(`assets/exam/pdf-ai-exam.pdf`), asked exactly as Read with AI asks (the same pictures and
prompt, the staves numbered from the key's, not from what the detector finds), both at once. The
answers are marked against a key measured on a 300 dpi render (`PdfAiExam.score`), in six parts
counting the same: horizontal borders (one system, no staff made up as missed; each staff's region, its top between the staff
above's lines and its own and its bottom between its own and the staff below's, the system's first
and last between the ink around it, all through `PdfAi.fit` and none counted where Read with AI
would take none), barlines (paired in order within two spaces, all moved as far as most are off;
F1, a plain one only), instrument names (whose, and the names printed), clefs and keys (a change
made up is wrong), and tempo and time (nothing where nothing is printed). An answer that isn't
JSON is wrong throughout; an error asking ends the other page's request (or it asks nothing) and is
shown whole once that has ended: nothing the exam asked outlasts it. The result, by whole
percent (`PdfAiVerdict`): over 95 used; over 85 used with a warning; over 75 once Use anyway is
ticked; over 65 once a warning is confirmed; over 50 both, Use in red; no more, not used. Results
are kept by model (`AppSettings.pdfAiExam`, with `PdfAiExam.version`: a new key or prompt bumps
it, and every model is examined again).

**A LilyPond score is LilyPond's engraving, read as Curator's own.** A `.ly` (or `.ily`) is
imported as a PDF is (File ▸ Import… ⌘I, a drop, the Finder, Open Recent; Project Info ▸ Score ▸
Replace… takes one too): read with the files it includes (`LilySource.read`: each `\include "…"`
found from the folder of the file that includes it, as LilyPond finds it, up to three folders
above the main file's, 64 MB in 256 files at most; LilyPond's own and paths elsewhere on the
computer left to LilyPond), then engraved by LilyPond 2.26.0, its official build for this computer
(macOS arm64 and x86-64, Linux x86-64, Windows x86-64, which Windows on Arm runs; Linux on Arm has
none). Settings ▸ Download Hub downloads it (`LilyPondInstaller`: checked by SHA-256, unpacked
whole into the app's data folder). Everything that takes LilyPond is offered without it (opening
a LilyPond score, File ▸ New LilyPond Score…, the editor's Engrave, a LilyPond score's text font)
and asks for it then, its Open Download Hub going there (`engraveWithLilyPond`, `ensureLilyPond`;
from Project Settings once that window has closed, one settings window being shown at a time): the
one place LilyPond is downloaded, a download under way there waited for and what was asked done
once it is in. LilyPond runs
in a scratch folder holding the score's files (`LilyPond.engrave`) with Curator's settings
(`assets/lilypond/curator.ly`, through `-dinclude-settings`): the piece on one endless line, no
titles, headers or footers, every graphical object tagged in the SVG with what made it (`data-c`
its number, `data-g` its kind, `data-l` the staff or lyrics it belongs to), and what the score is
(contexts, bars, notes, clefs, keys, times, tempo and rehearsal marks) written one JSON object a
line to the file `CURATOR_LILYPOND_DATA` names; nothing in the settings may stop a score engraving
(a failure is written as an error line). Its text is set in the project's text font, the font
Curator draws it in, so that it is spaced as it is drawn (`LilyPond.textFontFor`: Academico, or
a family installed here; one that isn't, Academico, as Verovio's engraving has it): the font's
files, one a line in `CURATOR_LILYPOND_FONTS` (an installed family's own; Academico's, the
engine's, written into the scratch folder), each added to LilyPond's fontconfig (a folder added
would leave a font cache behind for each engraving), and its family in `CURATOR_LILYPOND_SERIF`,
made LilyPond's serif. With the SVG backend LilyPond's own text font is the system's serif (Times
on a Mac, narrower: tempo marks ran into their "(", syllables into the next). A run spaced in
another font (a score setting its own) is drawn no wider than LilyPond spaced it, as far as what
follows it in its grob (`Cmd.fitWidth`), set closer by up to a tenth of an em a character.
`LilyPondScore.read` makes the two Curator's engraving:
LilyPond's own shapes are what the views draw (not Verovio's engraving), and a MusicXML of what was
written is what curation, sync, Align and Find Phrase read. Its point-and-click links
(`textedit://file:line:column:column`) name each file by its path in the score's folder
(`LilyPond.relativeLinks`; LilyPond writes the folder it ran in as it is, or with every byte but
letters, digits and `-._/` escaped `%xx` in lowercase), so no path of this computer is kept.

A LilyPond project is a kind of its own (`ProjectKind.lilypond`). Its main file is the project's
score; its `lilypond` module keeps the files it includes (`lilypond/files/<path>`, each checked
to be a path inside the score's folder, `LilyPondProject.isPath`), the engraving as LilyPond made
it (`lilypond/score.svg`, `lilypond/score.jsonl`), and the versions of LilyPond and of the settings
it was made with (`LilyPond.settingsVersion`), so it opens again without LilyPond. Its staves are
LilyPond's, so none are condensed. Project Info ▸ Score ▸ Edit… opens the LilyPond editor
(`showLilyPondEditor`); its Done engraves what changed since, and the score is replaced with the
project's edits carried over, as the score editor's is. Project Settings ▸ Engraving ▸ Text font
engraves it again in the font chosen before the change is taken on (`EditorController.setFonts`;
failing, nothing changes and the field says why), as Import… does a settings file's (without
LilyPond, the text is drawn in it as LilyPond spaced it before). Each engraving is kept by its font
(`EditorController._lilyPondIn`) while the score is open, so Undo and Redo go back to one without
LilyPond, and the project saves the one shown. File ▸ New LilyPond Score… opens the
editor on a few bars (`LilySource.blank`), its Done making them a new project, unsaved. A LilyPond
file is a program: its Scheme can do whatever the user can, and LilyPond has no safe mode any
more, so engraving a score runs it, as running a script would.

**What the engraving leaves out is said, not only logged.** The bridge keeps Verovio's
warnings ("Unsupported direction-type 'harp-pedals'") instead of printing them;
`EngravingData.warnings` / `LoadedScore.warnings` carry them, each once, and importing a
MusicXML score lists them in a dialog (`showImportWarnings`). Opening a project, or
re-engraving after an edit, doesn't show them again.

**A project is saved in modules** (`ProjectArchive`, since build 131). The zip holds `mimetype`
(stored, first), a stub `project.json` (`{"format": "application/x-curated-score", "version": 27}`:
Curator 0.1–0.6.1 read only that file and refuse a version past theirs, 26 at most, asking for an
update, so every release knows the file and none opens it), `manifest.json` (format, `layout` 2,
`writer` (`ProjectArchive.writer`: "Curator <version> (<build>)"), the project's `kind` (`ProjectKind`: `score`, `pdf` or `lilypond`;
absent or unknown, what its score is), the score's and recording's names and entries, and each module's
`version` and whether it is `optional`), `modules/<id>.json` (compact JSON), each module's files
under `<id>/` (`images/<id>`, `fonts/<name>.font`), `score/<name>`, then `media/<name>` (the
recording heard) and `media/takes/<id>/<name>` (each other, listed in the manifest's `takes`) last.
Everything deflates at zlib's default level, but the recordings and packed images, stored.

Each module (`ProjectModule`, all in `ProjectModules.all`) owns a part of `ProjectState`: `fonts`,
`engraving` (options, typography, the flags), `display` (transitions, scroll, motion, bar numbers,
sections, the playback line, family colours), `extensions`, `instruments` (order, names, sections,
name groups, pairs), `texts`, `curation`, `sync`, `takes` (optional: every recording's lane, and
each but the focus's sync), `images`, `captions`, `chapters`, `spacers`, `view`, and a PDF
project's `pdf` and a LilyPond project's `lilypond`. It writes
its JSON and files, and reads them back checking every field, naming the damaged one
(`sync.anchors[3]`). Long lists are tuples (an anchor `[quarter, seconds, jumpTo?]`, a region
`[start, end, in?, out?]`, a caption `[start, end, text]`); every value is written, defaults too,
only "the app's" (null) left out. A module missing from a file reads as empty (its defaults).

**The format changes a module at a time.** Every save writes each module in the newest version
this build has (`ProjectModule.version`). To change what one saves: bump its version and add a step
from the old one to its `migrations`; a field an older build would lose or misread needs the bump.
Something new with no place in a module is a new module (an older project has none: its defaults).
`ProjectArchive.layout` changes only with the archive's own shape. Opening checks the layout, then
each module: one this build doesn't know, or of a newer version, refuses the project ("needs a
newer version") unless the manifest says it is optional (nothing shown or played depends on it,
as `view`): then it opens without it, and keeps it as it came, JSON and files
(`ProjectState.foreign`, carried by the controller and Replace Score), for the next save to write
back. Projects saved before modules (formats 1–26: one `state` in `project.json`) are read by
`LegacyProject`: its frozen migrations to 26, then each field dealt out to its module in that
module's shape, for the module to check. The bundled demo is one, so every test reads it so.
Such a project opens as any other, and says so (`OpenedProject.olderFormat`,
`ProjectDocument.isOlderFormat` until it is saved): a snack bar that stays until closed warns
that saving (an autosave too) updates it, and older versions won't open it then. Nothing is ever
written in an older format; the sample, never saved, says nothing.

**Project Settings travel as a settings file** (`.ccf`, `SettingsFile`; Import… and Export… at the
foot of Project Settings' sidebar). It is a project's layout (`ProjectArchive`, `mimetype`
`application/x-curator-settings`, its stub `settings.json`) with only the score-wide modules
(`ProjectModules.settings`: fonts with an embedded added font's files, engraving, display,
extensions), so it is checked and migrated as a project is; a module it can't read is refused,
optional or not, and one saved before modules (`settings.json`'s `state`) goes through `LegacyProject`:
it is applied, then a dialog says it is in an older format and to export again to update it
(`SettingsFile.read`'s `olderFormat`; Export writes only the new one).
Only what a page sets for the whole score: what it sets per instrument (brackets, groups' members,
pairs and condensing, names) stays, as another score's instruments differ, and so do the user's own
name groups. Export writes the settings as the score shows them (`EditorController.exportedSettings`:
the app's defaults filled in where the project has none, the engraving options over the app's,
every extension on or off), so another project takes them as they look here. Import
(`EditorController.importSettings`) gets the fonts ready first (a font only named is looked for
here, Bravura standing in; one that can't be read changes nothing), then puts the file's in place
of the project's as one Undo step, engraving again if they change the engraving.

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
own, so Verovio still sets it beside the dynamic.
A direction-type that repeats one before it in its direction, but for its offsets, goes (exporters
write "pizz.pizz.", "mf mf" and two hairpins so), and a rehearsal mark's text is trimmed, as
spaces after it widen its box on one side; both in `PreparedScore.prepare`, before the texts list. The texts list is read before, so it and saved
edits' ids don't change. Project Settings ▸ Flags ▸ Dynamics typed as text (`EditState.textDynamics`,
an Undo step that re-engraves; a project without its own takes `AppSettings.textDynamics`, on
until Save as default) turns it off.
A lyric's `number` may be any token ("part1verse2", "chorus"), but Verovio reads a whole number,
so any other is verse 1: in a part with such a token, `PreparedScore.prepare` numbers the verses
1, 2, … by the last number in each token, then as they first come (after typography).

**Verovio is pinned and patched.** `make setup` clones the tagged release and applies
`patches/*.patch` from a clean tree whenever a patch changes; the build hook refuses to build
while a patch is newer than the tree. Patches: per-part key changes (transposing instruments
keep their written key), MusicXML direction ids (so texts can be edited), syllables centred
under their noteheads (`curatedLyricCentre`), stretches made wider (`curatedSpacers`), the app's typography
(`curated-score-size` / `curated-score-tracking` on words, rehearsal marks and lyrics, a rehearsal
mark's `font-style`, the `curated…Scale` options sizing music symbols, accidentals clear of
articulations and caesuras between their neighbours), engraving fixes (a rehearsal mark set a fifth
larger than other text, in a box as roomy at the sides as above and below and at least square,
a space clear of the music and of notes beside it; text boxes as thick as the font says, not
half; a space between a tempo's words and its metronome mark, which keeps its own weight; a tuplet whose notes are on two staves bracketed above the upper one, clear of the notes on both, not along a beam between them), cancelling naturals
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
Project Settings ▸ Engraving is one sidebar entry with three tabs (`_Category.tabbed`, a switch
under its title): Engraving, Typography and Advanced. The Engraving tab offers the options most
scores want changed (`EngravingSetting.all`, in `engraving_settings.dart`: a plain name, a heading,
a slider step) and Advanced every other one (`EngravingSetting.advanced`; together they hold each option in `EngraveOption.all`
once), all as `EngravingControl`s: sliders, switches and a menu
with the other pages' `SettingSlider` and `ResetSlot`, found by plain or code name in the search.
All three are `_Category(preview: true)`: a half-size preview of the open score above the rows
(with none, `EngravingPreviewHost` engraves the bundled demo in a controller of its own, with the
app's options, for as long as the preview is shown; a PDF score's systems are drawn as they are
read, its painter listening to `score.pdf` as the score view's does), hidden on all three at once by the button by
the page's title (`AppSettings.engravingPreview`, app-wide, not an edit). Open in Window, also by
the title, closes Project Settings and shows the tab as `_EngravingWindow`: an `OverlayEntry`
over the editor, not modal (the score re-engraves behind it, playback goes on), moved by its
title, one at a time, built from the same `_pageBody` and `_pageButtons` as the page. A slider sets
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
that reads it. A project's page, likewise, rebuilds only for the settings it shows (`_ProjectPageState._shown`).

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
Refined's palette (`AppColors._refinedOf`) takes every grey from a scale defined up front
(`RefinedGreys`: a cool 50–900 and the dark theme's own steps, OLED-dark from a black window; a new grey is a shade of it,
never a literal), with no accent mixed in, and a
`chrome` tone behind toolbars, the lane-name column and the ruler. Depth comes from Material's
elevations, set in the theme: the default button at
1 (2 on hover, flat when pressed), dialogs and the Settings window at the
top. A region is set apart by a tone or a line, not both: Settings' and Export's sidebars are the
`well` grey with no dividing line (hairlines stay only where content scrolls under a header or
over a footer). Resting icons and unchosen sidebar rows are a step softer than text, full
strength on hover. Controls are 28 px with 5 px
corners on a 13 px type scale. Segmented controls are a clear track whose chosen segment, a light
tint of the accent, slides to the one clicked, each label taking the accent as the tint passes
under it, and the hover and press shades (drawn by the segment, so they fade rather than switch)
gone while it slides.
Carbon follows IBM's Carbon Design System (v11) as specified: the White theme or Gray 100 a step darker (a black background, every layer one Gray grade down: OLED-dark), its
named tokens in a `CarbonColors` extension (only in a Carbon theme: `CarbonColors.maybeOf`), IBM
Plex Sans on the productive type set (12 / 14 / 16 / 20 px, Carbon's tracking), square corners,
sm (32 px) buttons at the condensed density (label at the left, 7 / 39 px), primary / tertiary
(outlined) / ghost (text) buttons in their state colours, an icon at the right (a filled or outlined
button's at its right end, 8 px in, with `withIconStyle`, so it is as wide as without one; a ghost
one's after its label), fields filled with `$field` and a line
under them (`CarbonFieldBorder`), a 2 px `$focus` ring (`CarbonFocusBorder` on a button; a symbol chip's edge),
checkboxes in `$icon-primary`, monochrome 2 px sliders (the thumb grows from 14 to 20 px, ringed in
`$interactive`, under the pointer, dragged or focused), the small toggle in `$support-success`
with its check, the content switcher (edged in `$border-inverse`, the chosen segment inverse),
24 px menus on `$layer-01`, the side nav (a 3 px bar of the accent) in Settings, the project tabs
as contained tabs (the one showing topped with 2 px of `$border-interactive`), and the modal
(`$layer-01` on `$overlay`, heading-03, footer buttons edge to edge at the right, slimmed to 40 px from the spec's 64; the
Settings windows on `$overlay` too, drawn in their transition from the theme as it is now, since
Settings ▸ Appearance changes it under them).
A button lays its `side` over the shape it is given (`shape.copyWith(side:)`), so a style sets a
button's edge as its `side` (an outlined button's own is the theme's outline, which would win over
the shape's), and `CarbonFocusBorder.copyWith` returns itself, or the ring would be a plain square.
Carbon's layering: what is on a layer takes the one above it. `CarbonColors` are the first layer's
(a toolbar, a dialog, a menu: fields `$field-02`); Settings' groups are `$layer-02`, and
`CarbonLayer` puts their content on `CarbonColors.raised` (`$field-03`, that layer's hover,
selection and `$border-subtle`), so a field stands out from its group. An accent is an IBM hue
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
same tile while `AppSettings.mascotIcon` is on, which a click on About's icon toggles (saved);
Tools/make_mascot_icon.swift draws that tile, both sizes, from the official art (Tools/mascot.png). The
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
edge. A dialog is an `AppDialog`, never an `AlertDialog`; a labelled field an `AppTextField`,
a select an `AppDropdown(label: …)` (a long one opens scrolled to its chosen item), and one that filters as it is
typed in (a long font list) a `DropdownMenu` built through `dialogMenuField`. `Export` is a
`Dialog` of its own, in the same measures.
A dialog's keys are `DialogKeys` (ui_kit.dart), which `AppDialog` wraps itself in: Return presses
the default button (the filled one last among the actions, or the only one), unless a field has
the keyboard (it submits) or a button was reached with Tab (it is pressed); not where that
throws work away (`confirmsOnReturn: false`: Discard Your Changes?). A dialog with no field has
the keyboard in its route's focus scope, above everything it shows, so the handler is that
scope's own (`FocusScope.of(context).onKeyEvent`), never a `Focus` or `CallbackShortcuts` among
the dialog's widgets, which would not hear the key. A dialog a click outside must not close
(`barrierDismissible: false`: Export Video, Export to Web, the Captions sheet) doesn't close on
Esc by itself either: it gives `onEscape` (Cancel's own action; the Captions sheet's asks first
once something was changed, and nothing while an export writes).

**Every key is a `KeyCommand`** (key_bindings.dart), listed in Settings ▸ Shortcuts under its
menu, its window or the editor's tab: its name as the menu or tooltip says it, where it works
(`KeyPlace`), its keys as the app comes (`KeyChord`s, written once for every system: `command` is
⌘ on macOS and Ctrl elsewhere, `control` ⌃ there and Ctrl elsewhere too). The menus' commands and
the editor's that are one action on one key are `editable`: the user gives them another key, or
none (`KeyMap`, saved as `AppSettings.keys` by command name, only those changed). The window takes
them from `KeyMapScope` (over everything, in `CuratedScoreApp`'s builder): the menus
(`AppMenus.keys`), the editor's bindings after its fixed ones (`_bindings`), and every tooltip that
names such a key, through `keyed`, which says the command's name alone while it has none (so each
has a "Name ({key})" text and a "Name" one). A key can't be given where another command has it
(`KeyMap.takenBy`: the menus and the editor share their keys, and the editor's ⌃ on macOS beside
⌘ is in `also`), and a menu's key holds ⌘ or ⌃ (Ctrl), or is a function key, so a letter typed
in a field still types, and is one a menu shows (a letter, digit, sign or Tab:
`KeyCommand.refuses`). The rest are listed only: the editor's contextual keys (Space, the arrows,
Esc), Edit's, the system's on macOS, and those of the score editor, the PDF import, Find Phrase
and the code editors, whose handlers are their own. So a key added to any handler is added there
too, where the page shows it and no command is given it. The names, help lines and headings are
enum data, put into curator.pot by hand (a test checks they are there).

**Overlays keep their parent in the accessibility tree.** Tooltips and sliders draw their
overlay (the tip, the slider's value) through an `OverlayPortal`, and for accessibility that
overlay hangs from the widget that shows it. Flutter loses the link when two such widgets
share a semantics node (flutter/flutter#182444), and when the widget is faded to opacity 0,
which drops its semantics but not its overlay (a `Slider`'s is always there,
flutter/flutter#190357). The overlay is then sent with no parent, the desktop engine rejects
the update ("Failed to update ui::AXTree" in `make run`), and its tree stays broken. So:
`Tip`, never `Tooltip` (and `ToolbarButton` for icon buttons); a `Slider` inside
`OverlaySemantics`; `showAppDialog`, never `showDialog`; a fade over any of them keeps its
semantics (`alwaysIncludeSemantics: true`); and a list with a slider in it keeps every row in
the tree (a settings page: `ScrollCacheExtent.pixels(double.maxFinite)`), as a row scrolled past the cache
is dropped from it but its slider's overlay is not. `test/accessibility_tree_test.dart`
replays the updates as the engine takes them (`accessibility_mirror.dart`).

**Fonts: engraving and drawing agree.** Verovio lays out with the metrics of the same fonts
the renderer draws. A project chooses its fonts (Project Settings ▸ Engraving, `ScoreFonts`: an edit,
`fonts` in `EditState`, saved from format 9; changing it re-engraves, as a text edit does).
Music: a bundled SMuFL font (Bravura, Leland, Petaluma, Leipzig, Gootville: each a font file in
the engine's pubspec, Leipzig's a TTF, the rest OTFs, and Verovio's own metrics in `assets/verovio/<Name>.xml`; Leipzig's are there anyway
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
`EditorController.newProjectFonts`); a music font not installed where a score is imported is
kept by name, as a project naming one is (Bravura standing in, the snack bar), a text font
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
Keep those changes when updating it. A font that
can't be read is never taken on (`EditorController.setFonts` prepares it first,
`LoadedScore.prepareFonts`), so a project never saves one it couldn't open with; its picker says
why under the field. A text font not installed here falls back to Academico, the
choice kept (`LoadedScore.textFontFound`). A LilyPond score's is LilyPond's to set: engraved in it
again first (see *A LilyPond score is LilyPond's engraving*). A glyph a music font lacks is laid out and drawn in
Bravura (`fontFallback`, `RenderStyle.musicFontFallback`). The frozen zone still spaces its
clef and time signature by Bravura's proportions.

**Scratch files.** Everything temporary goes under `ScratchSpace`: one folder per running
app, locked while it runs. Jobs release their folders when done (a replaced recording's
converted audio, a closed project's unpacked media), the app deletes its folder when it quits,
and at start-up it sweeps folders whose lock is free (their app crashed).

**Kept files and downloads.** What the app keeps between runs that is neither a project nor
a setting goes under `AppFolders`: `data` (`~/Library/Application Support/Curator`,
`%LocalAppData%\Curator`, `~/.local/share/curator`) or `cache` (fetched or made again at will:
`~/Library/Caches/Curator`, `%LocalAppData%\Curator\Cache`, `~/.cache/curator`), one plain-named
folder per kind (`AppFolders.folder`), made only when asked for. `Downloader.fetch` brings a file
in: https only, redirects followed by hand (never to plain http; a token goes to the source's own
host only), written as `<file>.part` under a lock, checked (size, SHA-256) and only then renamed,
so a file of that name is whole. A stopped download keeps its part and resumes with a byte range
when the hash is known. A `XetSource` is a file of a Hugging Face repository
(`/<repo>/resolve/<revision>/<path>`): the Hub redirects to the Xet bridge and names the file's
SHA-256, size and commit (`X-Linked-Etag`, `X-Linked-Size`, `X-Repo-Commit`), so its downloads
check and resume themselves; pin a revision by the commit `Downloaded.revision` gives. Nothing
uses either yet. Settings and Open Recent stay in `SharedPreferences`; the updater keeps its own
download (GitHub only, into Downloads).

**Tests run on the demo.** Every test uses `app/assets/demo/WI275 - 01 Intro.ccs` (a 44-bar
6/8 orchestral intro with its recording and curation), so a fresh clone runs them all.
The suite is kept small: a test or two per feature, on its main path (engine parts and the
engraving, scroll map, phrase search, auto-curate, video frame, tapping, takes and tempo maps,
Align, curation, save and open, safe save, older formats, Undo, the updater's URLs, the app's folders and downloads, web export,
the app's screens, the accessibility tree, the translations); add one only for a core path none of them covers. `Samples/` is for trying things by hand only. A test's tap that something
else would catch fails (`flutter_test_config.dart`). `make smoke` runs the app as built
(opening a window): what only a bundle has, its native library and resources, is checked there.

## Releasing

`.github/workflows/release.yml` runs only when started by hand (GitHub ▸ Actions ▸ Release ▸
Run workflow, or `gh workflow run release.yml`). It builds side by side with `make build` on
macOS and `flutter build windows` on Windows (Verovio fetched and patched by hand there, and the web
player built as `make web-player` would: no `make`), zips each as `Curator-<version>-<macos|windows>.zip` (the Windows zip carries the
Visual C++ runtime DLLs) and publishes release `v<version>` only when both have built and Windows
has run the smoke test (`app/integration_test/app_smoke_test.dart`, `make smoke` on macOS: the app
as built opens the sample, engraves, draws, and where FFmpeg is installed exports a second of video,
which the Windows runner hasn't; macOS runs no test there, nor `make check` either), where the version is
`app/pubspec.yaml`'s. The run's form asks three things. **What's new** is the release's description,
the changelog as Markdown, given to the script as an environment variable and never written into
it; left empty, the description is GitHub's own list of what changed (`releases/generate-notes`).
The form's field keeps one line, so a changelog of several goes in with
`gh workflow run release.yml -f notes="$(pbpaste)"`, or onto a draft's page before it is published.
Under it the workflow writes `<!-- install -->` and how to install: the app shows a description
up to that line (`Release.installMarker`), so keep it when editing one by hand. **Pre-release**
marks the release a pre-release on GitHub and nothing else: it is versioned as any other (0.9.1),
and unticking "Set as a pre-release" on its page later makes it the release without building again.
**Draft** keeps it to the repository's owner until published. Its actions are pinned to commits, not tags; only the job that publishes
may write to the repository. To release again, bump that version and `appVersion` / `appBuild`
in `updater.dart` together (`make versions` checks they match, from `make check` and as the
workflow's first step: one left behind would offer the app its own release); a version already
released stops the run before it builds. The app asks on the channel chosen in Settings ▸ About ▸
Update channel (`AppSettings.updateChannel`, `Updater.channel`): Release asks GitHub's
`releases/latest`, which is never a pre-release or a draft; Pre-release asks the list of releases
and takes the highest version that is no draft, a pre-release or not (`Release.newest`). Changing
the channel forgets what the last check found and drops the answer of one still on its way. A
newer version opens as the update window (update_dialog.dart): its description as Markdown, then
Download. The app finds its download by that name (the asset whose
name ends `-macos.zip` or `-windows.zip`; the launch notice stays quiet when there is none), so
keep that suffix if the workflow is changed. Neither build is notarized or signed (macOS ad hoc only), so
macOS Gatekeeper and Windows SmartScreen warn the first time; the release notes say how to open
it on each. The engine's CMake builds Verovio's sources itself, so Verovio's own platform
settings must be copied in by hand (on Windows: `include/win32` and `NOMINMAX`). The updater only downloads (into Downloads;
on Windows wherever the registry says that folder now is): it never replaces the running app.

## Adding things

- **A setting**: an `_Item` in `settings_dialog.dart`'s `_categories` (its texts in both Chinese
  tables, see *Interface text*), backed by a field in
  `AppSettings` (the editor takes what concerns it in `takeSettings`, controller_settings.dart); a project's own, in `_projectCategories`, backed by an edit (see *Something a
  project saves*), so Settings holds only what is the same for every project. A project page whose settings
  can become the app's defaults gives its `_Category` a `saveDefault`: a slim Save as Default
  button beside the page's title (a check and "Default" once they match), never a row; while they
  differ, Reset to Default before it puts the app's back on the page (`reset`, one Undo step). Once
  the saved defaults are other than the system's (the app's own as it comes, the house style:
  `savedIsSystem`), Reset to Default is a menu: Saved Default, and System Default
  (`resetToSystem`, the house style written into the project so it stays over the saved, the
  app's left as they are, one Undo step), each greyed out while the page is so (`isDefault`,
  `isSystem`). Settings of first-party components that are not part of the main work
  (import, curate, sync, export) and matter less go under **Extensions**.
- **Something downloaded** (a tool such as LilyPond, or a model run on this computer: local AI):
  an `_Item` on Settings ▸ Download Hub, the one place it is downloaded; what takes it is offered
  without it and asks for it there (as `ensureLilyPond` does). Local AI is never hidden by Hide AI
  features, which hides remote AI only.
- **A flag**: a fix for how other programs write their files, on by default (Centered lyrics, a
  house style, is off), as an `_Item` on
  Project Settings ▸ Flags with a switch to turn it off: the project's (`EditState`, an edit),
  else the app's default (`AppSettings`), which that page's Save as default sets.
- **An extension**: a `CuratorExtension` (`extensions/extension.dart`). Each gives a stable
  `id`, its name, icon, one-line summary, search words, its own settings (`settings`,
  a dialog's content, or null; the app's), `isUsedBy` (whether an open project uses it) and
  `apply` (turns its part of the editor on or off). Project Settings ▸ Extensions lists each:
  name (and a version, which only an extension from elsewhere has: Curator's own change
  with the app), the summary under it, a settings button (greyed out without settings)
  and the switch. The switch is the project's only (`EditState.extensions` by id, an Undo step,
  `EditorController.extensionOn`); there is no app-wide default, and one the project never chose
  is off. The app's old switches (`AppSettings.legacyExtensions`: a switch each until build 69,
  then Save as default) are deprecated, read but never written: a project saved before it kept
  its own takes one it uses that was on there, as it opens. Opening a project that uses
  extensions it never chose shows them in a dialog (`extensions_dialog.dart`), each with its
  switch (and "All" when there are several); what the dialog ends with is the project's
  (`EditorController.keepExtensions`: one left off is stored off, no Undo step but saved), so
  it asks once. Everything the extension adds works only while its switch is on, and is hidden
  or inert otherwise. Project files keep switches for ids this version doesn't know, so a newer
  version's choices survive.

  **An extension is a package** (`ExtensionPackage`, a `.cpe`): Lua files, and a connector that
  wires Curator's sockets (`ExtensionApi.sockets`: `project`, `lane`, `command`, `export`) to
  their functions. Curator's own are folders under `app/assets/extensions/<id>/`
  (`BundledExtensions`, one-word ids, never saved in a project); one from elsewhere has a
  reverse-domain id and is carried by the project that uses it (`ProjectState.packages`, the
  `packages` module: `packages/<id>.cpe` as it is shared). A package adds nothing by hand:
  while its switch is on, `EditorController.extensions` (`ExtensionEditing`) runs it (an
  `ExtensionRuntime`), and the app draws what its connector declares (a lane, the buttons on
  its name, a dialog it asks for) and calls its Lua for the rest. What it keeps is JSON in
  `EditState.extensionData` by id (an edit: `curator.data()` then `curator.save()` is one Undo
  step), saved in the `extensiondata` module with the version of the data it writes, or, for one
  of Curator's own that had a module before it was a package, in that module as it always was
  (`ProjectModules.ownData`), so files stay the same byte for byte. Where nothing is edited (a
  project opening, a video's export, a web page) an extension runs over a `ReadingHost`. Rules:
  - The API only grows (`ExtensionApi.level`): nothing listed is taken away or changes meaning.
    What is added says its level; a package says the level it needs and may ask
    `curator.has`. What a build doesn't know in a package (a later key, a later socket) is kept.
  - The app draws its own chrome and the extension describes it; Lua never builds widgets.
    Text an extension shows goes through `curator.tr` (Curator's own: the app's translations,
    which `tool/l10n.dart` reads from their Lua and connectors).
  - Lua's `at + 0.0` keeps a place a fraction (saved `4.0`); `text.squeeze`, `text.trim` and
    `math.round` are Dart's own, so a port from Dart stays exact.
  - A port (an extension once written in the app) is held to the old code by a test before
    the old code goes: every edit compared, then kept as a digest.
  - The API is written once, in `ExtensionApi`: the editor's reference and prompts, `curator.has`
    and `docs/extension-api.md` (the editor's guide, `assets/help/extensions.md`, then the
    reference; `make extension-docs`, which a test holds it to) all come from it. A new socket
    or function is added there with its summary, and to the guide when it changes how one is
    written.
  - A package made in the app has a `user.<name>` id (`ExtensionActions.idFor`); editing one
    replaces it in the project (`ProjectState.packages`) and starts it again, its data kept.
  **Chapters** is the first package; **Attach Image**, **Captions** and **Tonality** are still
  written in the app (`extensions/built_in.dart`), behind `images.enabled` /
  `captions.enabled` / `tonality.enabled`.
- **Interface text** follows Apple's HIG *Writing*, in US English: Title Case for menu items,
  buttons and dialog titles that are fragments ("Copy Lane To…", "Couldn’t Export Video"),
  sentence case for tooltips, labels, help lines and messages; an ellipsis only where more
  input follows. A failure says "Couldn’t …" and, where there is one, the fix ("Use an image
  under 64 MB"), never blame or "we". Warnings, notices and confirmations are friendly but calm:
  plain words, an exclamation mark or a ☆ now and then ("This project is from a newer Curator.
  Update to open it!"), no jokes or kaomoji, still short and still with the fix; labels,
  buttons and titles stay plain. Contractions; seconds and minutes spelled out in
  sentences; no "e.g.". One word per thing: the playhead (never the pointer), the sample,
  open (a score), add (a recording, a MIDI tempo map), transition, Extensions.
  It is written in English in the code and translated where it is shown (Settings ▸ General ▸
  Language: System, English, Simplified or Traditional Chinese, switched live; `AppLanguage`):
  `'Open Sample'.tr`, `'Couldn’t align. {error}'.fill({'error': …})` with values (the translation
  places them), and
  `trIn` where one English word means two things (a `msgctxt`). A name the score or the user gave
  (an instrument, a recording, a group of the user's) is shown as written, never translated: one
  that reads as a word of the interface ("Alto", "Bass": clefs; "Score") is not that word. A widget
  that translates its label takes `named: true` for one (`AppCheckRow`, `ExportSelect`, Settings'
  rows), and `showColorDialog`'s title is shown as given. The English is the template,
  `assets/l10n/curator.pot`, and each language a gettext file beside it named by its locale
  (`zh-Hans.po`, `AppLanguage.file`), which Crowdin keeps (`crowdin.yml`, docs/translating.md);
  `Strings.load` reads them all before the first frame (a test's `flutter_test_config.dart` too),
  so switching stays instant. One without an entry shows the English (a debug run prints it).
  A new `.tr` / `.fill` text goes into every file with `make l10n` (`tool/l10n.dart`; text
  translated other than as a literal, an enum's label, is added to curator.pot by hand), and needs
  its Simplified and Traditional Chinese, with the same placeholders (`test/l10n_test.dart`
  checks); a language Crowdin adds may be partly translated. A new language is an `AppLanguage`
  with its locale, and its file. Material's own strings come from `GlobalMaterialLocalizations` (material_ui's).
- **Something a project saves**: a field of `EditState` (with its `==` and `copyWith`),
  written and read by the module it belongs to (`project_modules.dart`), bumping that module's
  version with a migration when an older build would lose it; or a new module. If the controller keeps it itself it lives in `_doc`, and
  opening, Undo and closing take it with no more code; if a model holds it, `_editState` (also
  what a project saves, `EditorController.projectState`) reads it from the model, and `_install`
  and `_restore` load the model. If it changes the engraving it goes in `EngraveRequest` too. Replace Score carries it as it is unless
  `ScoreSwap.carry` maps it (a part id or a position). Only the view (`ViewState`) is saved
  without being an edit. If it changes what is drawn, it goes in `SceneSettings` (and the
  controller's `sceneSettings`), which `VideoExport.of` takes.
- **A Verovio change**: edit `third_party/verovio`, then
  `git -C packages/score_engine/third_party/verovio diff > patches/verovio-curated-score.patch`,
  then `make setup` (it re-applies the patches from a clean tree, and records that it did).
- **A MusicXML release**: run Tools/make_musicxml_schema.py on its schema (`musicxml.xsd`), which
  writes what the MusicXML view offers (musicxml_schema.dart), and say its version in the docs above.
- **A Verovio release**: `VEROVIO_TAG` in the Makefile, then move the clone by hand (the Makefile
  clones only into an empty folder): `git -C packages/score_engine/third_party/verovio checkout -- .`,
  `fetch --depth 1 origin tag <tag>`, `checkout <tag>`, remove its `.curated-score-patched` and
  `make setup`; write the patch again from the patched tree (above) so its lines are the release's,
  and run Tools/make_licenses.py. `verovioVersion`'s doc comments name the version.
- **A widget**: Material is the `material_ui` package (`package:material_ui/material_ui.dart`);
  the framework's `package:flutter/material.dart`, deprecated since Flutter 3.50, has a `Theme`, a
  `Scaffold`, a `MaterialLocalizations` of its own, which ours never find. A package still built on
  it (re_editor, the LilyPond editor's code view) gets the app's theme and Material texts through
  `MaterialUiCompatibilityBridge` in `CuratedScoreApp`'s builder; once none is, the bridge goes.
