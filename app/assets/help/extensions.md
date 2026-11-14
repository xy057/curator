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
