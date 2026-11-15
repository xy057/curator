# Writing a plugin

A plugin changes Curator itself, in every project: it adds commands to the menus, the keys,
the toolbar and Home, changes the app's own commands, and does things as projects open and
play. (What belongs to one project and is saved with it, a lane or captions, is an extension:
a `.cpe`.) A plugin is a `.cgp` file, which is a zip of plain files:

- `plugin.json`: its id, name, version, one-line summary, and the API level it needs.
- `src/main.lua`: its code, in Lua. This is the file Curator runs.
- `src/*.lua`: more code, for `main.lua` to `require` (optional).
- `locales/<language>.json`: its texts in other languages (optional).
- `assets/`: files its code reads with `curator.asset` (optional).
- `README.md`: what it does (optional).

Plugins are kept by the app, listed in Settings ▸ Plugins. Add one from its file there (Add
Plugin from File), or drop the file on the window. One from a file is off until its switch is
turned: it is someone's code.

## How it runs

Curator runs `main.lua` once: as the app starts, and when the plugin's switch is turned on.
Everything a plugin does starts there. It says what it adds and what it listens to, and
Curator calls it back:

```lua
app.command{
  title = "Hello",
  menu = "Plugins",
  run = function()
    ui.message("Hello from " .. curator.name)
  end,
}
```

Turning a plugin off takes out everything it added and puts back everything it changed.
Nothing has to be undone by hand. Run in the editor (⌘R) starts it again as it stands.

Another file is a module: write its functions on a table, return it, and get it with
`require("util")` (a file in a folder: `require("util.text")`). A file's own variables are its
own.

What goes wrong is listed under the code with its file and line, shown at the window's foot,
and never stops Curator. A function that runs too long is stopped.

## Commands

A command is something the user can do. `app.command` adds one, and says where it shows:

```lua
app.command{
  title = "Count Bars",
  menu = "View",                -- a menu of the app's, or any name for a new one
  after = "showTimeline",       -- beside a command of that menu; else at its end
  key = "cmd+shift+b",
  toolbar = true,               -- a button on the editor's toolbar
  icon = "score",
  enabled = function() return score.open() end,
  run = function()
    ui.message(curator.tr("Bars: {n}", {n = #score.bars()}))
  end,
}
```

- `menu`: `"File"`, `"Edit"`, `"View"`, `"Window"` or `"Help"`, or a name of your own, which
  makes a menu before Window. `"View/Zoom"` is a menu inside View. Without one the command
  is in no menu: it has its key, or its button.
- `key`: what is held, then the key, joined by `+`. `cmd` is ⌘ on a Mac and Ctrl elsewhere.
  A key one of the app's commands has stays the app's; the editor says so under the code.
- `toolbar`, `home`, `preview`: a button on the editor's toolbar, a button on Home, an item
  of the menu a right-click on the score opens (`run` is then given the place clicked, in
  quarter notes).
- `enabled` and `checked` are functions, asked whenever the menu is drawn: whether it can be
  chosen, whether it is ticked. Keep them quick. They are asked again after a command ran or
  an event was told; when what they hang on changes at another time (a timer, a dialog's
  answer), call `app.refresh()`.
- `id`: what the command is called by. Left out, it is made from the title ("count-bars").
  Give one when the title may change.

`app.remove(id)` takes one out again. `app.run(name)` does any command, the app's or a
plugin's, as its menu item would.

## Changing the app's own

Every command of the app has an id (listed in the Reference: `open`, `save`, `exportVideo`…);
its title in English works too (`"Export Video..."`).

```lua
app.hide("exportWeb")                    -- out of its menu and off its key
app.rename("importScore", "Import a Score…")
app.rebind("findPhrase", "cmd+shift+f")  -- the user's own choice in Settings ▸ Shortcuts wins
app.wrap("exportVideo", function(original)
  app.run("save")
  original()                             -- what the app does; leave it out to stop it
end)
```

`app.wrap` puts a function around a command: it is called in the command's place however the
command is chosen (menu, key, toolbar, `app.run`), and decides whether the app goes on.

`app.setting(name)` reads one of the app's settings and `app.setting(name, value)` sets it:
the theme, the accent colour, the language, and the rest of the Reference's list.

## Events

`app.on(event, fn)` calls `fn` when something happens: a project opened, saved, closed or
shown, playback started or stopped, the app started.

```lua
local off = app.on("project.saved", function(project)
  print("Saved " .. project.name)
end)
```

`off()` stops listening. `app.after(seconds, fn)` calls `fn` once, later.

## The project showing

`project` is the project in the tab that shows: its name and file, whether it plays, where
the playhead is. `score` reads its score: bars, parts, rehearsal marks, and where a place in
the score falls in the performance. Places are in quarter notes from the start of the score;
times in seconds. On Home there is no project: `project.open()` and `score.open()` say so, and
what needs one raises an error, so give a command that needs a score
`enabled = function() return score.open() end`.

## Settings

What a plugin remembers is one table, kept by the app for every project:

```lua
local settings = curator.settings()   -- a copy; {} the first time
settings.greeting = "Hello"
curator.save_settings(settings)
```

A plugin that listens to `"settings"` gets Settings… in its menu in Settings ▸ Plugins: show
a form there (`ui.form`), and keep what it gives.

## Text

Write every text shown to the user in English: a command's `title`, a menu's name and a
dialog's texts are translated as they are shown, and `curator.tr("…")` translates one in code.
To translate them, add `locales/<language>.json` (`zh-Hans.json`, `ja.json`) with the English
as the key:

```json
{ "Count Bars": "统计小节", "Bars: {n}": "小节：{n}" }
```

`curator.tr("Bars: {n}", {n = 3})` fills `{n}` in. A text that means two things gets a
context: `curator.tr_in("music", "Key")` looks for `"music|Key"` first.

## Dialogs

`ui.message` shows a line at the window's foot. `ui.ask` asks a question with buttons of
yours. `ui.form` opens a dialog laid out as Curator's own: rows of fields (a text, a
`"switch"`, or a `"choice"` among options), a `check` that says what is wrong as it is typed,
and `done`, called with the values. `ui.sheet` opens a table to edit, a row for each thing.
`ui.open_file` asks for a file and hands it over as text; `ui.save_file` asks where a file
goes, then writes what `write` returns. Lua never draws: it says what it wants, and Curator
shows it. None of them waits: each calls `done` when the user has answered.

## Staying compatible

The API only grows: what works now works in every later Curator. To use something newer than
the level in plugin.json, ask first:

```lua
if curator.has("app.after") then … end
if curator.has("command:exportWeb") then app.hide("exportWeb") end
```

`"event:…"` and `"setting:…"` ask about an event and a setting.

## Lua here

Lua 5.4 as it is written, with these differences: there is one kind of number; a string is
text, so `#s` counts characters as JavaScript does; there are no coroutines, no `io` and no
`os.execute`. A plugin reaches files only through `ui.open_file` and `ui.save_file`, which ask
the user. Beyond Lua's own `string`, `table`, `math` and `utf8` there are `text` (trim,
squeeze: any kind of space), `math.round` and `math.clamp`.

## A whole plugin

`plugin.json`

```json
{ "id": "com.example.greeting", "name": "Greeting", "version": "1.0.0",
  "summary": "Says hello as a project opens.", "api": 1 }
```

`src/main.lua`

```lua
local function greeting()
  return curator.settings().greeting or "Hello"
end

-- Says it as a project opens.
app.on("project.opened", function(project)
  ui.message(greeting() .. ", " .. project.name)
end)

-- And when asked: Help ▸ Greet, ⌥⌘G.
app.command{
  title = "Greet",
  menu = "Help",
  key = "cmd+alt+g",
  run = function() ui.message(greeting()) end,
}

-- Settings… in Settings ▸ Plugins: what it says.
app.on("settings", function()
  ui.form{
    title = "Greeting",
    confirm = "Save",
    rows = { { {id = "greeting", label = "Greeting", value = greeting(), focus = true} } },
    check = function(values) return values.greeting == "" and "" or nil end,
    done = function(values)
      curator.save_settings({greeting = values.greeting})
    end,
  }
end)
```

Curator's own plugins (Settings ▸ Plugins, View… in each one's menu) are working examples.
Three are a few lines each: Reopen Last Project (something done as the app starts), Appearance
Menu (ticked commands that change a setting), Save Before Export (two of the app's commands
wrapped). Navigator is the large one: a Go menu with rehearsal marks, bookmarks kept for each
project, a loop and timestamps, in six files. Where its code meets something a plugin can't
do, a comment that starts with `Edge:` says so, and what it does in its place.

## Where a plugin ends

- It adds commands and asks for the app's dialogs. It draws nothing: no panel, no control of
  its own, nothing on the score or the timeline.
- It keeps settings in the app (`curator.settings`), not data in a project. What belongs to
  a project and travels with it is an extension's.
- It is told events and can wait with `app.after`. It isn't called every frame, and isn't
  told that the score was edited or the playhead moved.
- It reads the score showing and moves the playhead. It can't edit the score or the lanes.
- It reaches a file only through `ui.open_file` and `ui.save_file`, and has no network.
