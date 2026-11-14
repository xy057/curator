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
- **Lane**: a lane pinned under the bar ruler. `items` says what is in it; `add`, `move`,
  `erase`, `open` and `remove` are what the tools and keys do.
- **Command**: a button on a lane's name. `run` does it; `enabled` says whether it can be
  chosen.
- **Export**: what a video and a web page get: their chapters.

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
the same way.

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
space) and `math.round`.

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
- `replaced(data, carry) → data, lost`: The score is being replaced by another. carry(quarter) gives where a place of the old score is in the new one, or nil when it is gone. Return the saved data moved there, and what was lost as a text ("2 chapters"), or nil.

### Command (`command`)

Something the user can do: a button on a lane’s name, or an item of the preview’s menu.

Ports:

- `run()`: The user chose it.
- `enabled() → boolean`: Whether it can be chosen now. Unwired: always.

Properties (set on the node in connect.json):

- `title` (text): Its name: a menu item’s text, a button’s hover text.
- `icon` (an icon’s name): Its icon, on a button.
- `where` (`"lane"` or `"preview"`, default `lane`): Where it is offered.
- `lane` (the id of a lane node): The lane whose name carries the button (where: lane).

### Export (`export`)

What the extension gives a video and a web page made of the project. An extension has one.

Ports:

- `chapters(from, to) → list`: The chapters of a video or page showing from–to seconds of the performance: {from, to, name}, in seconds from its start, in order and without gaps. A movie carries them for its player, with a list of their times beside it; a page lists them to jump to.

### Lane (`lane`)

A lane pinned under the bar ruler, drawn and edited as the app’s own are.

Ports:

- `items() → list`: What the lane shows, in score order: {at = quarter, label = text}, each running to the next. Asked again when the extension’s data changes.
- `add(at)`: The Draw tool was clicked at a place (snapped to the beat it is in).
- `move(index, at)`: Item index is being dragged to start at a place. Called as it moves; the whole drag is one Undo step.
- `erase(index)`: The Erase tool was clicked on item index.
- `open(index)`: Item index was double-clicked.
- `remove(index)`: Delete was pressed with item index selected.

Properties (set on the node in connect.json):

- `title` (text): The lane’s name.
- `kind` (`"markers"`, default `markers`): Markers are places that each run to the next.
- `gap` (number, default `0.25`): The least two markers are apart, in quarters: a drag stops there.
- `order` (number, default `100`): Where it sits among the pinned lanes: a lower number is higher up.

Icons: `add`, `close`, `delete`, `reset`, `copy`, `check`, `search`, `more`, `open`, `project`, `score`, `export`, `assets`, `play`, `pause`, `music`, `draw`, `erase`, `tidy`, `audio`, `repeat`, `snap`, `frame`, `lanes`, `image`, `pin`, `link`, `captions`, `settings`, `fonts`, `extensions`, `done`, `failed`, `warning`, `previous`, `next`, `align`, `moveUp`, `moveDown`, `chapters`, `ai`, `show`, `hide`, `test`, `fetch`, `code`, `tonality`, `website`, `keyboard`.

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

### `text`

Text as people write it: every kind of space counts, in any script.

- `text.trim(text) → text`: text without the spaces at its ends.
- `text.squeeze(text) → text`: text with every run of spaces and line breaks made one space, and none at its ends: a name as it is kept.
- `text.lower(text) → text`: text in lower case, in any script.
- `text.upper(text) → text`: text in upper case, in any script.
- `text.lines(text) → list`: The lines of text.

### `math`

Lua’s math library, and:

- `math.round(x) → number`: x to the nearest whole number, a half away from zero.

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

### `ui`

Dialogs, laid out as the app’s own. In the editor only.

- `ui.form(spec)`: Opens a dialog. spec: title, confirm (its button’s title), width, rows (each a list of fields: {id, label, value, type = "text" or "switch", max, flex, focus, hint, lines}), leading (buttons at the left: {id, title}), check(values) → nil when it can be confirmed, a text saying why not, or "" to say nothing, and done(values, button), called with the fields’ values by id and "confirm" or a leading button’s id. Cancel calls nothing.

  ```lua
  ui.form{
    title = "Add Note", confirm = "Add",
    rows = { { {id = "text", label = "Note", focus = true} } },
    check = function(values) return values.text == "" and "" or nil end,
    done = function(values) add(values.text) end,
  }
  ```

- `ui.message(text)`: Shows a line at the window’s foot for a moment.
