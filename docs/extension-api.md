<!-- Made by app/tool/extension_docs.dart (make extension-docs): edit app/assets/help/extensions.md and ExtensionApi instead. -->
# Writing an extension

An extension adds something to a project: a lane, a button, chapters for a video. It is a
`.cpe` file, which is a zip of plain files:

- `extension.json`: its id, name, version, one-line summary, and the API level it needs.
- `connect.json`: the connector. Which of Curator's sockets it uses, and which function of
  which file Curator calls for each.
- `src/*.lua`: its code, in Lua.
- `locales/<language>.json`: its texts in other languages (optional).
- `assets/`: files its code reads with `curator.asset` (optional).
- `README.md`: what it does (optional).

A project carries the extensions it uses, so it opens the same on any computer.

## How it runs

Curator never calls a function by its name. It calls what the connector wires: the `items`
port of a lane to `lane.lua#items`, say. So the connector is the whole list of what the
extension does, and the Lua can be laid out as you like.

Each file is a module. Write its functions on a table and return it:

```lua
local M = {}

function M.items()
  return { {at = 0, label = "Start"} }
end

return M
```

Another file gets that table with `require("lane")` (a file in a folder: `require("util.text")`).
A file's own variables are its own: nothing leaks from one file to another.

An extension runs only while its switch is on in Project Settings ▸ Extensions. What goes
wrong is listed under the code with its file and line, and never stops Curator. A function
that runs too long is stopped.

## Sockets

- **Project**: the project opened (`opened`), its data changed (`changed`), checking the
  saved data as a project opens (`load`), moving it when the score is replaced (`replaced`).
- **Lane**: a lane pinned under the bar ruler. `items` says what is in it; the other ports
  are what the tools and keys do. Its `kind` is `markers` (places that each run to the next:
  `add`, `move`, `erase`) or `spans` (stretches with a start and an end, edited as an
  instrument's regions are: `draw`, `begin`, `change`, `cut`). A double-click on its name
  calls `details`.
- **Command**: a button on a lane's name, or an item of the menu a right-click on the preview
  opens (`where`: `lane`, `preview`, or `caption` for the caption showing). `run` does it;
  `enabled` says whether it can be chosen. In a menu both are told what was clicked: the place,
  or the caption's index.
- **Band**: a band of colours along the top of the score. `areas` says what is in it.
- **Captions**: text under the score, one caption at a time. `list` says what they are,
  `style` how they look; `open` is a double-click on the one showing.
- **Images**: pictures on the score that scroll with it. Curator keeps their files, draws
  them and gives each its handles and menu; the extension keeps where each one is. `list`
  says what they are; `add`, `change` and `remove` are what the user did; `without` takes the
  pictures of files that were let go out of a state Undo keeps.
- **Spacers**: turns on Curator's spacers (staves of nothing, stretches made wider). It has
  no ports.
- **Export**: what a video and a web page get: their chapters, a video's subtitles.
- **Settings**: the extension's own settings, for every project. `form` describes them, and
  Curator shows them from the extension's menu in Project Settings ▸ Extensions.

Every port's function is given in the Reference, as it would be written.

## Data

What an extension keeps in the project is one table, saved as JSON:

```lua
local data = curator.data()
data.notes = data.notes or {}
table.insert(data.notes, {at = 12.0, text = "Here"})
curator.save("Add Note")
```

`curator.save` is one Undo step. After Undo, `curator.data()` gives the table as it was, and
the `changed` port is called. Keep nothing else between calls: a local variable is lost when
the extension restarts.

When the shape of the data changes, raise `"data": {"version": 2}` in extension.json and
bring older data up to date in the `load` port, which is given the version it was saved with.

Places in the score are in quarter notes from its start (a fraction: `12.0`, `12.5`). Times
are in seconds. Lists start at 1, as in Lua.

## Text

Write every text shown to the user through `curator.tr("…")`, in English. To translate it,
add `locales/<language>.json` (`zh-Hans.json`, `ja.json`) with the English as the key:

```json
{ "Add Note": "添加笔记", "{n} notes": "{n} 条笔记" }
```

`curator.tr("{n} notes", {n = 3})` fills `{n}` in. Titles in the connector are translated
the same way. A text that means two things gets a context: `curator.tr_in("music", "Key")`
looks for `"music|Key"` first.

## Colours

A colour is `"#rrggbb"`, or a table of its red, green and blue from 0 to 1:
`{r = 1, g = 0.5, b = 0}`.

## Dialogs

`ui.form` opens a dialog laid out as Curator's own: rows of fields (a text, a `"switch"`, or
a `"choice"` among options), a `check` that says what is wrong as it is typed, and `done`,
called with the values. Lua never draws: it says what it wants, and Curator shows it.

`ui.sheet` opens a table to edit, a row for each thing: its columns, its rows, buttons at its
foot, a `check` that says what is wrong with each row, and `done`, called with the rows. A row
is your own table: a text for each column, and whatever else you keep in it. The functions
you give it get the `sheet`, to read its rows and change them.

`ui.ask` asks a question with buttons of yours. `ui.open_file` asks for a file and hands it
over as text; `ui.save_file` asks where a file goes, then writes what `write` returns. None
of them waits: each calls `done` when the user has answered.

## Staying compatible

The API only grows: what works now works in every later Curator. To use something newer than
the level in extension.json, ask first:

```lua
if curator.has("ui.form") then … end
```

What this Curator doesn't know in an extension (a socket or a setting from a later one) is
kept as it is.

## Lua here

Lua 5.4 as it is written, with these differences: there is one kind of number (write `x + 0.0`
to keep a whole number a fraction when it is saved); a string is text, so `#s` counts
characters as JavaScript does; there are no coroutines, no `io` and no `os.execute`. Beyond
Lua's own `string`, `table`, `math` and `utf8` there are `text` (trim, squeeze: any kind of
space), `math.round` and `math.clamp`.

## A whole extension

`extension.json`

```json
{ "id": "com.example.notes", "name": "Notes", "version": "1.0.0",
  "summary": "Notes on the score.", "api": 1 }
```

`connect.json`

```json
{ "nodes": [
    {"id": "project", "type": "project", "at": [40, 40]},
    {"id": "notes", "type": "lane", "at": [40, 200], "title": "Notes"} ],
  "wires": [
    ["notes.items", "main.lua#items"],
    ["notes.add", "main.lua#add"],
    ["notes.remove", "main.lua#remove"] ],
  "files": {"main.lua": [420, 40]} }
```

`src/main.lua`

```lua
local M = {}

local function notes()
  local data = curator.data()
  data.notes = data.notes or {}
  return data.notes
end

-- notes.items: what the lane shows.
function M.items()
  local items = {}
  for i, note in ipairs(notes()) do
    items[i] = {at = note.at, label = note.text}
  end
  return items
end

-- notes.add: the Draw tool was clicked at a place.
function M.add(at)
  table.insert(notes(), {at = at, text = score.format(at, true)})
  table.sort(notes(), function(a, b) return a.at < b.at end)
  curator.save("Add Note")
end

-- notes.remove: Delete was pressed with a note selected.
function M.remove(index)
  table.remove(notes(), index)
  curator.save("Remove Note")
end

return M
```

# Reference

API level 1.

## Sockets

### Project (`project`)

The project the extension is on in. Every extension has one. An extension has one.

Ports:

- `opened()`: A project with the extension on has opened, or it was just turned on.
- `changed()`: The extension’s saved data changed: an edit of its own, Undo or Redo.
- `used() → boolean`: Whether the project uses the extension, so opening it offers to turn it on. Unwired: whether it has saved anything.
- `load(data, version) → data`: A project is being opened: check its saved data (written by the extension’s version of the data, "data.version" in extension.json) and return it as this version wants it. An error here says the project is damaged.
- `replaced(data, carry) → data, lost`: The score is being replaced by another. carry(quarter) gives where a place of the old score is in the new one, or nil when it is gone; a third argument is the new score’s length in quarters. Return the saved data moved there, and what was lost as a text ("2 chapters"), or nil.

### Command (`command`)

Something the user can do: a button on a lane’s name, or an item of the menu a right-click on the preview opens.

Ports:

- `run(at)`: The user chose it. In the preview’s menu, at is the place clicked, in quarters; in the menu of the caption showing, that caption’s index.
- `enabled(at) → boolean`: Whether it can be chosen now (at as run gets it). Unwired: always.

Properties (set on the node in connect.json):

- `title` (text): Its name: a menu item’s text, a button’s hover text.
- `icon` (an icon’s name): Its icon, on a button.
- `where` (`"lane"` or `"preview"` or `"caption"`, default `lane`): Where it is offered: on a lane’s name, in the menu of the preview (a right-click on the score), or in the menu of the caption showing there (a right-click on it).
- `lane` (the id of a lane node): The lane whose name carries the button (where: lane).

### Export (`export`)

What the extension gives a video and a web page made of the project. An extension has one.

Ports:

- `chapters(from, to) → list`: The chapters of a video or page showing from–to seconds of the performance: {from, to, name}, in seconds from its start, in order and without gaps. A movie carries them for its player, with a list of their times beside it; a page lists them to jump to.
- `subtitles(from, to) → text`: The subtitles of a video showing from–to seconds of the performance, as the text of a SubRip (.srt) file timed from its start: written beside the movie when Export’s Subtitles switch is on. nil while there are none.

### Lane (`lane`)

A lane pinned under the bar ruler, drawn and edited as the app’s own are. Its kind says what it holds: markers (places, each running to the next) or spans (stretches that never overlap).

Ports:

- `items() → list`: What the lane shows, in score order. Markers: {at = quarter, label = text}. Spans: {from = quarter, to = quarter, label = text, color = colour}; without a colour a stretch is drawn as a region is. Asked again when the extension’s data changes.
- `open(index)`: Item index was double-clicked.
- `remove(index)`: Delete was pressed with item index selected.
- `nudge(index, direction, fine)`: ← (direction -1) or → (1) was pressed with item index selected; fine asks for the smaller step (a beat, not a bar). Unwired: the keys do what they do without it.
- `trim(index, edge)`: [ (edge "start") or ] ("end") was pressed with item index selected: the edge goes to the playhead.
- `add(at)`: Markers: the Draw tool was clicked at a place (snapped to the beat it is in).
- `move(index, at)`: Markers: item index is being dragged to start at a place. Called as it moves; the whole drag is one Undo step.
- `erase(index)`: Markers: the Erase tool was clicked on item index.
- `draw(from, to)`: Spans: the Draw tool was dragged across from–to (a click: the beat there).
- `begin()`: Spans: a drag that may change the stretches begins. Until the next, change and cut are of the stretches as they are now: keep them.
- `change(index, from, to)`: Spans: stretch index (as begin found them) was moved or trimmed to from–to. Called as the drag goes, the whole drag one Undo step; with live off, once as it ends.
- `cut(pieces)`: Spans: the Erase tool went over stretches. pieces is every stretch as it is left, {of, from, to}: a piece of stretch of (as begin found them). One erased whole has none.
- `details()`: The lane’s name was double-clicked: show everything in it (ui.sheet).

Properties (set on the node in connect.json):

- `title` (text): The lane’s name.
- `kind` (`"markers"` or `"spans"`, default `markers`): What it holds: markers are places that each run to the next, spans are stretches with a start and an end.
- `gap` (number, default `0.25`): Markers: the least two are apart, in quarters: a drag stops there.
- `paint` (toggle, default `false`): Spans: a stretch drawn, moved or trimmed goes over the others, as an instrument’s region does (cut them back in change and draw), instead of stopping at them.
- `live` (toggle, default `true`): Spans: a drag changes the stretch as it goes. Off: once, when it ends.
- `markup` (toggle, default `false`): Spans: a label’s *italic* and **bold** are drawn so, as a caption’s are.
- `order` (number, default `100`): Where it sits among the pinned lanes: a lower number is higher up.

### Band (`band`)

A band of colours along the top of the score, in the preview, a video and a web page: the staves leave it room while it has anything. An extension has one.

Ports:

- `areas() → list`: The band’s stretches, in score order: {from = quarter, to = quarter, color = colour, label = text}, each named at its start. Asked again when the extension’s data or the language changes.

### Captions (`captions`)

Text under the score, one caption at a time, in the preview, a video and a web page: each shows while its music sounds, its time running out. An extension has one.

Ports:

- `list() → list`: The captions: {from = quarter, to = quarter, text = text}, none overlapping. *italic* and **bold** in a text are drawn so. Asked again when the extension’s data changes.
- `style() → table`: How they look: font (a text font’s family; nil: the score’s text font), countdown ("line", "ring" or "none"), size ("small", "medium" or "large"), align ("left", "center" or "right"), plate (true: a soft backing behind the text). Unwired, or a key left out: a line, medium, centred, no plate. Asked again when the extension’s settings change.
- `open(index)`: The caption showing was double-clicked in the preview.

### Settings (`settings`)

The extension’s own settings, for every project: Settings… in its menu in Project Settings ▸ Extensions opens them. An extension has one.

Ports:

- `form() → spec`: The settings as a form. spec: rows (each {id, label, value, type}: a "switch", "segments" (one of options, each {value, label}), or a "font" (a text font’s family, "" for none, named none)), preview(values) → what is drawn under them ({caption = text, style = a captions style}), changed(values) called as one is changed: keep them with curator.save_settings.

### Images (`images`)

Pictures on the score that scroll with it, in the preview, a video and a web page. The app keeps each one’s file in the project, draws it, and gives it its handles and its menu (move, resize, Crop, Score Ink, Remove), with Add Image… and Paste in the preview’s menu, files dropped on the score and Manage Assets; the extension keeps where each picture is. An extension has one.

Ports:

- `list() → list`: The pictures, bottom to top: {image = a file’s name, at = quarter (its left edge), top, width, height (in staff spaces, top from the frame’s), crop = {left, top, right, bottom} (the part of the image shown, each 0–1; nil: all of it), ink = true (drawn in the score’s ink)}. The project keeps the files these name. Asked again when the extension’s data changes.
- `add(image, at, top, aspect) → index`: The user added an image (a file, the clipboard, a drop), kept as the file named image: its top-left corner goes to quarter at, top staff spaces down; aspect is its width over its height. Return the new picture’s index, which is then selected.
- `change(index, picture)`: Picture index was moved, resized, cropped or had its ink switched: picture is as list gives one, as it is now. Called at every move of a drag, which is one Undo step.
- `remove(indexes)`: The user removed these pictures: the selected one, or every one showing an image.
- `without(data, images) → data`: The files named images were let go (Manage Assets ▸ Remove Unused): return data, a state Undo keeps, without the pictures that show them.

### Spacers (`spacers`)

Room in the score: staves of nothing and stretches made wider, with the Spacers lane and their handles in the preview. It has no ports: an extension with one turns them on, and the app keeps them. An extension has one.

Icons: `add`, `close`, `delete`, `reset`, `copy`, `check`, `search`, `more`, `open`, `project`, `score`, `export`, `assets`, `play`, `pause`, `music`, `draw`, `erase`, `tidy`, `audio`, `repeat`, `snap`, `frame`, `lanes`, `image`, `pin`, `link`, `captions`, `settings`, `fonts`, `extensions`, `done`, `failed`, `warning`, `previous`, `next`, `align`, `moveUp`, `moveDown`, `chapters`, `ai`, `show`, `hide`, `test`, `fetch`, `code`, `tonality`, `website`, `keyboard`.

A colour is `"#rrggbb"`, or a table of its red, green and blue from 0 to 1: `{r = 1, g = 0.5, b = 0}`.

## Libraries

### `curator`

The extension itself: its saved data, its texts.

- `curator.data() → table`: The table the extension keeps in the project. It is the same table until the project changes under it (Undo, another project): change it, then call curator.save.

  ```lua
  local data = curator.data()
  data.notes = data.notes or {}
  table.insert(data.notes, {at = 4, text = "Here"})
  curator.save("Add Note")
  ```

- `curator.save(label)`: Keeps curator.data() as it is now: one Undo step, named label in the Edit menu. Saving what is already saved does nothing.
- `curator.settings() → table`: What the extension keeps for every project (a copy).
- `curator.save_settings(table)`: Keeps table as the extension’s settings for every project.
- `curator.tr(text, values) → text`: text in the interface’s language, from locales/<language>.json; each {name} in it is replaced by values.name.

  ```lua
  curator.tr("{n} chapters", {n = 3})
  ```

- `curator.tr_in(context, text, values) → text`: curator.tr for a text that means two things: its translation in a context ("context|text" in locales/<language>.json), else as curator.tr gives it.

  ```lua
  curator.tr_in("music", "Key")
  ```

- `curator.has(name) → boolean`: Whether this Curator has a function ("score.notes"), a library ("ui"), a socket ("socket:lane") or a port ("socket:lane.items"): for using something newer than the level the extension asks for.
- `curator.log(...)`: Writes a line to the extension editor’s log. print does the same.
- `curator.list(table) → table`: Marks a table as a list, so that it is saved as [] while it is empty. A new table already is.
- `curator.map(table) → table`: Marks a table as a map, so that it is saved as {} while it is empty.
- `curator.asset(path) → text`: A file of the extension’s assets folder as text; nil when there is none.
- `curator.api`: This Curator’s API level (a number).
- `curator.id`: The extension’s id.
- `curator.name`: The extension’s name.
- `curator.version`: The extension’s version, as extension.json says it.
- `curator.language`: The interface’s language ("en", "zh-Hans").
- `curator.null`: JSON’s null where nil can’t stand: a value in a saved list.

### `score`

The score and the performance it is synced to. Places are in quarter notes from the start of the score; times in seconds.

- `score.open() → boolean`: Whether a score is open. The rest raise an error without one.
- `score.quarters() → number`: The score’s length.
- `score.bars() → list`: Every bar: {number, start, length}.
- `score.bar_at(quarter) → number, start`: The bar a place is in (1 is the first) and where that bar starts.
- `score.beat_at(quarter) → start, end`: The beat a place is in.
- `score.format(quarter, compact) → text`: A place as bar.beat ("12.3"); compact drops a first beat ("12").
- `score.parse(text) → quarter`: The place "12" or "12.3" names; nil when it names none.
- `score.seconds(quarter, pass) → seconds`: When a place sounds, in the pass-th time through it (1 by default).
- `score.quarter(seconds) → quarter`: The place sounding at a time.
- `score.pass_at(seconds) → number`: Which pass through the score sounds at a time: a repeat is a pass more.
- `score.passes() → list`: Every pass through the score, a repeat being one more: {from, to} in quarters, {starts, ends} in seconds.
- `score.end_seconds() → seconds`: When the music ends.
- `score.spans(places, end) → list`: Markers (places in quarters, each running to the next) as they sound, in order: {index, from, to} in seconds, index 0 for the music before the first. A repeat back into an earlier one is that one again. They cover the performance from 0 to end seconds (the end of the music by default).

  ```lua
  for _, span in ipairs(score.spans({0, 16, 48})) do
    print(span.index, span.from, span.to)
  end
  ```

- `score.rehearsal_marks() → list`: The score’s rehearsal marks, in the order written: {at, bar, text}.
- `score.parts() → list`: The instruments: {id, name, staves}.
- `score.title() → text`: The score’s title; "" when it has none.
- `score.music(done)`: Reads the music off to the side, so a long score doesn’t stop the editor, then calls done(music): music.notes is every pitched note as it sounds, part by part ({from, to} in quarters, pitch as a MIDI number at concert pitch, tied when a tie carries it on from the note before, chord for a chord’s notes after its first, part, staff, voice); music.keys the key signatures at concert pitch ({bar, fifths, minor}, each from its bar on; minor only when the score says which); music.bars where each bar starts, then the score’s end. done(nil) when the score changed meanwhile. In the editor only.

  ```lua
  score.music(function(music)
    if not music then return end
    print(#music.notes, "notes")
  end)
  ```


### `text`

Text as people write it: every kind of space counts, in any script.

- `text.trim(text) → text`: text without the spaces at its ends.
- `text.trim_start(text) → text`: text without the spaces at its start.
- `text.trim_end(text) → text`: text without the spaces at its end.
- `text.flatten(text) → text`: text with every run of spaces and line breaks made one space; those at its ends stay, as one.
- `text.runs(text) → list`: A caption’s text as it is drawn: its stretches in one face, {text, italic, bold}, the markers of *italic* and **bold** taken out. A star that marks nothing stays, and so does one written \*.
- `text.squeeze(text) → text`: text with every run of spaces and line breaks made one space, and none at its ends: a name as it is kept.
- `text.lower(text) → text`: text in lower case, in any script.
- `text.upper(text) → text`: text in upper case, in any script.
- `text.lines(text) → list`: The lines of text.

### `math`

Lua’s math library, and:

- `math.round(x) → number`: x to the nearest whole number, a half away from zero.
- `math.clamp(x, low, high) → number`: x, no lower than low and no higher than high.

### `lanes`

What is selected in the extension’s lanes. In the editor only.

- `lanes.selected(lane) → index`: The item selected in a lane (the lane’s id in the connector); nil when none is.
- `lanes.select(lane, index)`: Selects item index of a lane; nil selects nothing.

### `editor`

The editor’s playhead and grid. In the editor only.

- `editor.playhead() → seconds`: Where the playhead is.
- `editor.seek(seconds)`: Moves the playhead.
- `editor.beat(quarter, pass) → start, end`: The beat of the lanes’ grid a place is in (bars when zoomed far out).
- `editor.snap(quarter, pass) → quarter`: The nearest line of the lanes’ grid, as a drag snaps to it.
- `editor.next(quarter, unit) → quarter`: The first barline after a place (unit "bar", the default) or the first beat ("beat"); the score’s end when there is none.
- `editor.previous(quarter, unit) → quarter`: The last barline (or beat) before a place; the score’s start when there is none.
- `editor.nearest(quarter, unit) → quarter`: The barline (or beat) nearest a place.

### `ui`

Dialogs, laid out as the app’s own. In the editor only.

- `ui.form(spec)`: Opens a dialog. spec: title, confirm (its button’s title), width, spacing (between rows), rows (each a list of fields: {id, label, value, type = "text", "switch" or "choice", max, flex, focus, hint (a text, or a function of the values), lines, options (a choice’s: {value, label, color})}), leading (buttons at the left: {id, title}), check(values) → nil when it can be confirmed, a text saying why not, or "" to say nothing, and done(values, button), called with the fields’ values by id and "confirm" or a leading button’s id. Cancel calls nothing.

  ```lua
  ui.form{
    title = "Add Note", confirm = "Add",
    rows = { { {id = "text", label = "Note", focus = true} } },
    check = function(values) return values.text == "" and "" or nil end,
    done = function(values) add(values.text) end,
  }
  ```

- `ui.message(text)`: Shows a line at the window’s foot for a moment.
- `ui.ask(spec)`: Asks a question. spec: title, text, buttons (each {id, title}; the last is the one Return presses), done(id) called with the button pressed. Cancel, which the app adds, calls nothing.

  ```lua
  ui.ask{
    title = "Replace the old notes?",
    buttons = { {id = "add", title = "Add"}, {id = "replace", title = "Replace"} },
    done = function(id) print(id) end,
  }
  ```

- `ui.sheet(spec) → sheet`: Opens a table to edit, a row for each thing. spec: title, width, columns (each {id, label, width, max, hint}; one without a width takes the room left), rows (each a table with a text for every column’s id; what else it holds stays with it), focus ({row, column id}), empty (what it says without rows), buttons (at its foot: {id, title, icon, enabled(sheet)}), press(id, sheet), more (the id of the button Return presses on the last row), check(rows) → a list with what is wrong with each row (nil, a text, or {text, column ids at fault}), done(rows) when Done is pressed. Done is off while a row has something wrong; Cancel asks first once something was changed. sheet: rows() (as they are now), set(rows), add(row, column id) (and types there), notice(text) (a line at its foot), valid() (no row has anything wrong).
- `ui.open_file(spec)`: Asks for a file to read. spec: types (each {label, extensions}), max (the most bytes read), done(file) called with what was chosen: {name, text} (the file as text: UTF-8, UTF-16 by its mark, else Latin-1), or {name, error} when it can’t be read ({name, too_big = true} past max). Nothing chosen calls nothing.
- `ui.save_file(spec)`: Asks where to save a file, then writes it. spec: name (as offered), types (each {label, extensions}), write(file) → the text to write, called once the place is chosen (file.name, and file.extension: the name’s, else the chosen type’s first), done(file) once it is written (file.error says why it couldn’t be).
