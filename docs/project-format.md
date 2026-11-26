# Curator's files: projects and settings

What a Curator project (`.ccs`) and a settings file (`.ccf`) hold, every layout a Curator has
written them in, and the rules that keep them readable: by every later Curator (past-proof), and
by the Curators before it as far as they can (future-proof). The code is
`app/lib/project_archive.dart` (the archive, every layout), `app/lib/project_modules.dart` (the
modules), `app/lib/legacy_project.dart` (layout 1) and `packages/score_engine/lib/src/cura_data.dart`
(the notation). `app/test/formats` holds a project and a settings file in layout 2 and in every
layout 3 format since, and `app/test/project_file_test.dart` checks each opens as the newest does;
layout 1 is the bundled demo's (`app/assets/demo`: format 1, as Curator 0.1.0 saved it), which the
tests open, with formats 17 and 25 as the test writes them.

## The archive

A zip. Each entry, in the order Curator writes them:

| Entry | What it is |
| --- | --- |
| `mimetype` | The kind of file, stored first and uncompressed: `application/x-curated-score` (a project) or `application/x-curator-settings` (settings). For other programs; Curator goes by `format` (below). |
| `project.json` | (`settings.json`) A stub for Curator 0.6.1 and before: `{"format": "<kind>", "version": 27}`. They read nothing else, and ask for an update past their own format (25 at most). |
| `manifest.json` | A stub for Curator 0.7 to 0.11.0-beta1: `{"format": "<kind>", "layout": 3}`. They ask for an update past layout 2. |
| `project.cura` | (`settings.cura`) The file in CuraScript: what it is, then each module. |
| `<id>/…` | A module's own files, all under its id: `images/<image>`, `fonts/<name>.font`. |
| `score/<name>` | A project's score, byte for byte as it was imported. |
| `media/<name>` | The recording heard; `media/takes/<take>/<name>` each other; `media/stems/<stem>/<name>` each stem. Last, stored as they are. |

## Which layout a file is in

1. With no `manifest.json`: **layout 1** (formats 1 to 26: Curator 0.6.1 and before wrote up to 25,
   the builds just after it 26). `project.json`
   is all of it. Its `format` must be the kind; a `version` past 26 is a later layout's whose
   `manifest.json` is lost: refused as newer.
2. Else `manifest.json`'s `format` must be the kind, and its `layout` 3 at most (else refused as
   newer). Below 3: **layout 2** (Curator 0.7 to 0.11.0-beta1). 3: **layout 3**, in `project.cura`,
   whose own `format` and `layout` are checked the same.

A file in layout 1 or 2 opens and says it is older: saving writes it in layout 3, which the
Curator that wrote it can't open. Nothing is ever written in an older layout.

### Layout 3

`project.cura` holds, in CuraScript (below), the file's fields:

```
# Written by Curator, in CuraScript: what the file is, then each of its modules.
format "application/x-curated-score"
layout 3
writer "Curator 0.11.0-beta1 (697)"
kind "score"
score
  name "Symphony.musicxml"
  entry "score/Symphony.musicxml"
media
  name "Concert.wav"
  entry "media/Concert.wav"
```

- `format`: the kind of file. `layout`: 3. `writer`: the Curator that wrote it, its release and
  build, for a later one to tell.
- A project's: `kind` (`score`, `pdf`, `lilypond` or `midi`; absent or unknown, what its score
  is), `score` (`name`, `entry`), `media` (`name`, `entry`; or, a recording linked and not found,
  `name`, `path`, `relativePath`), `takes` and `stems` (each `id`, `name`, `entry`).

Then each module, under its heading: `module <id> version <n>`, and `optional` after it where a
Curator that can't read it may open the file without it. Its fields are its data.

### Layout 2

`manifest.json` holds the file's fields as layout 3's (but as JSON), and `modules`: each module's
id → `{"version": n}`, with `"optional": true` where it may go unread. Each module's data is
`modules/<id>.json`, its files as layout 3's. A module's data is the same in both: what JSON holds.

### Layout 1

`project.json` (`settings.json`) holds `format`, `version` (1 to 26), a project's `score` and
`media`, and `state`: every edit in one object. Reading it brings `state` up to format 26 by
`LegacyProject`'s frozen steps, then deals its fields out to the modules, each in its version 1
(`LegacyProject.moduleVersion`), from where it is upgraded as any module is.

## CuraScript's data

What JSON holds, written a field a line. A file:

```
file     = { field | module }                 (the file's fields at indent 0)
module   = "module" name "version" digits [ "optional" ]     (at indent 0)
           { field }                          (its fields, indented, all alike)
field    = name [ value ]                     (no value on the line: the block under it)
block    = { field } | { item } | { text }    (lines indented more than the line above, all alike)
item     = "-" [ value ]                      (no value on the line: the block under it)
text     = "|" [ " " ] rest of the line       (the lines joined with a line feed)
value    = quoted | number | "true" | "false" | "none" | "{}" | "[" [ value { "," value } ] "]"
name     = bare | quoted
bare     = [A-Za-z_][A-Za-z0-9_.-]*
number   = -?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?
quoted   = '"' { character | \" | \\ | \n | \r | \t | \u{hex} } '"'      (hex: 1 to 6 digits)
```

- Lines end in a line feed, a carriage return and line feed, or a carriage return. A byte order
  mark before the first is no part of the file.
- A line's indent is the spaces and tabs it starts with, each one column. A blank line, or one
  whose first character after its indent is `#`, is skipped wherever it is; `#` after a value or a
  heading starts a comment to the line's end.
- `none` is JSON's null; `{}` an object with nothing in it (any other object is a block);
  `true`, `false` and `none` read in any case.
- A number with no point and no exponent is a whole number (an int, as `jsonDecode` gives it, where
  it fits); any other a double. One past a double's range doesn't read.
- A name appears once among its fields; a module once in its file.
- Fields and lists may be 256 deep at most, a file's own fields or a module's the first. A
  module's version is a whole number of nine digits at most.

What doesn't read says its line ("The project is damaged: project.cura, line 12: …").

### As Curator writes it

One way to write each file, which `app/test/formats` holds Curator to:

- Line feeds; two spaces an indent; nothing after a line's last character, but what a `|`
  line's text ends in.
- The heading comment, the file's fields, then each module after a blank line.
- A value goes on its name's line (or its `-`'s) when it is a number, `true`, `false`, `none`,
  text of one line (or of several that need an escape), `{}`, `[]`, or a list of only these,
  none of them text written as `|` lines. Anything else goes under it: fields, `-` items, `|`
  lines.
- Text of several lines that needs no escape (but tabs) goes as `|` lines, an empty one `|` alone.
- A whole number in digits. A double as Dart's `double.toString` (JavaScript's `Number`'s
  `toString`) writes it: the fewest digits that read back as it, plain from 10⁻⁶ up to below
  10²¹, a whole one with `.0` after it (`2.0`, `0.000015`, `100000000000000000000.0`), and with an
  exponent outside that (`1e-7`, `1.5e-7`, `1e+21`).
- In quotes, `\"`, `\\`, `\n`, `\r`, `\t`; any other character below U+0020, U+007F, U+2028,
  U+2029 and lone surrogates as `\u{…}`, in lower-case hex; the rest as it is (U+0080 to U+009F
  too).
- A name is bare when it can be, else in quotes; a file's own field named `module`, always quoted.

## The modules

Each module is one part of the project, with a version of its own. A settings file holds only the
score-wide ones. (`app/test/in_step_test.dart` checks this table is `ProjectModules.all`.)

| Module | Version | Optional | Settings | Holds | Files |
| --- | --- | --- | --- | --- | --- |
| `pdf` | 2 | no | no | A PDF score's layout: its pages' systems, staves and barlines, masks, instruments, meter and key | |
| `lilypond` | 1 | no | no | A LilyPond score's: the files it includes, which LilyPond engraved it, the main file's folder | `lilypond/files/<path>`, `lilypond/score.svg`, `lilypond/score.jsonl` |
| `midi` | 1 | yes | no | How the MIDI view's rows are drawn | |
| `fonts` | 1 | no | yes | The music, text and captions' fonts; whether an added music font is embedded | `fonts/<name>.font`, `fonts/<name>.json` |
| `engraving` | 1 | no | yes | Engraving options over the app's, typography, the flags that change the engraving | |
| `display` | 1 | no | yes | Transitions, scrolling, motion, bar numbers, the first bar's number, sections, the playback line, the names' colours | |
| `extensions` | 1 | no | yes | The extensions turned on or off, by id | |
| `instruments` | 2 | no | no | Each instrument's order, name, section, name group, pair, spacing; condensing | |
| `texts` | 1 | no | no | The score's texts changed | |
| `curation` | 2 | no | no | Each instrument's lane: when it is shown; the lanes split a staff each | |
| `sync` | 1 | no | no | The tempo track: lead-in, anchors, the MIDI tempo map | |
| `takes` | 1 | yes | no | The recordings: each one's lane and (but the focus's) sync, the focus, the crossfade | |
| `stems` | 1 | yes | no | The stems: each one's name, colour, take, offset and part | |
| `images` | 1 | no | no | The images on the score (Attach Image's data) | `images/<image>` |
| `captions` | 1 | no | no | The captions (Captions' data) | |
| `chapters` | 1 | yes | no | The chapters (Chapters' data) | |
| `tonality` | 1 | yes | no | The key areas (Tonality's data) | |
| `spacers` | 1 | no | no | Spacers: staves of nothing, blanks between beats | |
| `packages` | 1 | yes | no | The extensions the project carries | `packages/<id>.cpe` |
| `extensiondata` | 1 | yes | no | What those extensions keep, each with its data's version | |
| `playermap` | 1 | yes | no | The player map | |
| `automation` | 1 | yes | no | The Video tab's lanes | |
| `view` | 1 | yes | no | How the editor was left: zoom, grid, snapping, the playhead | |
| `script` | 1 | yes | no | The Instruments tab's script | |

## Reading

A module's id is `[a-z][a-z0-9-]{0,63}`, never `score`, `media` or `modules`: every Curator names
its modules so, and a file with any other is damaged. For each module in the file, in its order:

- One this Curator knows, of its version or before: its data is brought up to this version, a
  step a version (`ProjectModule.upgrade`, `migrations`), and read, every field checked. A damaged
  one says which (`The project is damaged: sync.anchors[3] …`).
- One it doesn't know, or of a later version: if the file says it is `optional`, the project opens
  without it and keeps it as it came, its data and its files under `<id>/`, for the next save to
  write back (`ProjectState.foreign`; a settings file keeps none). If not, the file is refused:
  "from a newer Curator. Update to open it!" (A layout 2 module's data CuraScript couldn't write
  again isn't kept.)

A module the file doesn't have reads as having nothing (its defaults); a field a module doesn't
know is passed over. What a file unpacks is counted as it comes: a stub or layout 2 JSON 64 MiB at
most, `project.cura` 128 MiB, the modules kept unread with their files 256 MiB together.

## Changing the format

So that every file ever written still opens, and the Curators before still say what they can't:

- **A module's data.** What a version of a module means never changes. To change what it saves,
  raise its `version` and add a step from the old one to its `migrations`. Raise it whenever a
  Curator before would lose or misread the change (one that reads it and saves again writes only
  what it knows). A Curator that doesn't know the new version then asks for an update, unless the
  module is optional.
- **Optional** only when nothing the score shows or plays depends on it: a Curator before opens
  the project without it, and keeps it.
- **Something new** with no place in a module is a new module: a new id, version 1, in
  `ProjectModules.all` (and `.settings` if it is score-wide), in the table above. A file without it
  reads as having none.
- **A module is never taken away**, nor its id given to another: a file that has it must still
  open, its data read (or dealt to where it is kept now) as long as Curator reads files at all.
- **A module's files** go under `<id>/`, nowhere else (written or read elsewhere, a `StateError`):
  a Curator keeping the module unread keeps exactly those.
- **The layout** changes only with the archive's shape or CuraScript's notation (which a Curator
  before would read as damage). Then `manifest.json` says the new one, so every Curator from 0.7 on
  asks for an update, and every older layout is still read. The stubs are written always.
- **Freeze it.** Once the format changes, `app/test/project_file_test.dart` fails. Raise the
  build, then `make formats` keeps what this build writes as `app/test/formats/<build>.ccs` and
  `.ccf` (never over a folder there already). If a new module has nothing in the sample, give it
  something in the new folder's `project.cura` by hand: older folders don't have it, so they are
  compared without it; the test then checks this build writes it again as it is. Leave every
  module older folders have as `make formats` wrote it, or they can't open as it. The folders are
  never edited once committed.
