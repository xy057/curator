<!-- Made by app/tool/plugin_docs.dart (make plugin-docs): edit app/assets/help/plugins.md and PluginApi instead. -->
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

# Reference

API level 1.

## Libraries

### `curator`

The plugin itself: its settings, its texts.

- `curator.settings() → table`: What the plugin keeps, for every project (a copy).
- `curator.save_settings(table)`: Keeps table as the plugin’s settings.
- `curator.tr(text, values) → text`: text in the interface’s language, from locales/<language>.json; each {name} in it is replaced by values.name.

  ```lua
  curator.tr("{n} bars", {n = 3})
  ```

- `curator.tr_in(context, text, values) → text`: curator.tr for a text that means two things: its translation in a context ("context|text" in locales/<language>.json), else as curator.tr gives it.
- `curator.has(name) → boolean`: Whether this Curator has a function ("app.after"), a library ("project"), an event ("event:project.saved"), a command ("command:exportWeb") or a setting ("setting:theme"): for using something newer than the level the plugin asks for.
- `curator.log(...)`: Writes a line to the plugin editor’s log. print does the same.
- `curator.list(table) → table`: Marks a table as a list, so that it is saved as [] while it is empty. A new table already is.
- `curator.map(table) → table`: Marks a table as a map, so that it is saved as {} while it is empty.
- `curator.asset(path) → text`: A file of the plugin’s assets folder as text; nil when there is none.
- `curator.api`: This Curator’s plugin API level (a number).
- `curator.id`: The plugin’s id.
- `curator.name`: The plugin’s name.
- `curator.version`: The plugin’s version, as plugin.json says it.
- `curator.language`: The interface’s language ("en", "zh-Hans").
- `curator.null`: JSON’s null where nil can’t stand: a value in a saved list.

### `app`

The app: its commands, menus, keys and toolbar, what happens in it, its settings and tabs.

- `app.command(spec) → id`: Adds a command: something the user can do. spec: title (its name, in English: translated from locales/), run (what it does), id (what it is called by; from its title when left out), menu (the menu it is in: "File", "Edit", "View", "Window", "Help", or any other name for a new menu; "View/Zoom" for a menu inside one), before or after (a command of that menu it sits beside; else at the menu’s end), key (its key: "cmd+shift+k"), toolbar (true: a button on the editor’s toolbar), home (true: a button on Home), preview (true: an item of the menu a right-click on the score opens; run is then given the place clicked, in quarters), icon (a button’s icon), enabled (a function: whether it can be chosen now) and checked (a function: whether it is ticked). Adding one with the id of one the plugin has replaces it.

  ```lua
  app.command{
    title = "Count Bars",
    menu = "View",
    key = "cmd+shift+b",
    enabled = function() return score.open() end,
    run = function()
      ui.message(curator.tr("{n} bars", {n = #score.bars()}))
    end,
  }
  ```

- `app.remove(id)`: Takes out a command the plugin added.
- `app.refresh()`: Has every command asked again whether it can be chosen and is ticked (enabled, checked): after something they hang on changed in a timer or a dialog’s answer. A command that ran and an event that was told do it by themselves.
- `app.run(name, ...) → boolean`: Does a command, the app’s own or a plugin’s, by its id ("exportVideo") or its title ("Export Video..."): as its menu item or its key would. false when it can’t be chosen now.

  ```lua
  app.run("save")
  ```

- `app.commands() → list`: Every command there is, the app’s then the plugins’: {id, title, menu, key, enabled, plugin (the id of the plugin that added it)}.
- `app.hide(name)`: Takes a command out of its menu and off its key, until app.show. app.run still does it.
- `app.show(name)`: Puts a hidden command back.
- `app.rename(name, title)`: Gives a command another name in its menu; nil: its own again.
- `app.rebind(name, key)`: Gives a command another key ("cmd+alt+s"); nil: none. A key the user chose in Settings ▸ Shortcuts stays theirs. Only for the commands the user can change there, and plugins’ own.
- `app.wrap(name, fn)`: Puts fn around one of the app’s commands: fn(original, ...) is called in its place, however it is chosen, and calls original() to do what the app does, or doesn’t. nil takes it off.

  ```lua
  app.wrap("exportVideo", function(original)
    app.run("save")
    original()
  end)
  ```

- `app.on(event, fn) → off`: Calls fn when something happens in the app (see Events). off() stops it.

  ```lua
  app.on("project.opened", function(project)
    print("Opened " .. project.name)
  end)
  ```

- `app.setting(name, value) → value`: One of the app’s settings (see Settings): with a value, sets it; gives it as it then is.

  ```lua
  app.setting("theme", "dark")
  ```

- `app.recent() → list`: The files of File ▸ Open Recent, as paths, the latest first.
- `app.open(path)`: Opens a project or a score in a tab, or shows the tab it is open in.
- `app.tabs() → list`: The projects open, in the tabs’ order: {name, path, edited, showing}.
- `app.show_tab(index)`: Shows a tab: 0 is Home, 1 the first project.
- `app.after(seconds, fn) → cancel`: Calls fn once, seconds from now. cancel() stops it first.
- `app.copy(text)`: Puts text on the clipboard.
- `app.version`: Curator’s version ("0.9.0").
- `app.build`: Its build (a number).
- `app.platform`: "macos", "windows" or "linux".

### `project`

The project showing: its file and its playback. The score library reads its score.

- `project.open() → boolean`: Whether a project shows (false on Home). The rest need one.
- `project.name() → text`: Its name, as its tab has it.
- `project.path() → text`: Its file; nil until it is saved.
- `project.edited() → boolean`: Whether it has changes not saved.
- `project.playing() → boolean`: Whether it is playing.
- `project.play()`: Plays from the playhead.
- `project.pause()`: Stops playing.
- `project.time() → seconds`: Where the playhead is.
- `project.seek(seconds)`: Moves the playhead.
- `project.duration() → seconds`: How long it plays.

### `score`

The score of the project showing, and the performance it is synced to. Places are in quarter notes from the start of the score; times in seconds.

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

### `ui`

Dialogs, laid out as the app’s own.

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

## Events

What `app.on` listens to:

- `"app.started"`, `function()`: Curator has started and its window is up. Told once, to the plugins on as it starts: one turned on later isn’t told.
- `"project.opened"`, `function(project)`: A project has opened in a tab. project: {name, path, edited} (no path until it is saved).
- `"project.saved"`, `function(project)`: The project was saved (Save, Save As…).
- `"project.closed"`, `function(project)`: A project’s tab was closed.
- `"project.shown"`, `function(project)`: Another tab shows: its project, or nil for Home.
- `"playback.started"`, `function()`: The project showing started playing.
- `"playback.stopped"`, `function()`: It stopped.
- `"settings"`, `function()`: Settings… was chosen in the plugin’s menu in Settings ▸ Plugins, which has it while the plugin listens: show them (ui.form) and keep them (curator.save_settings).

## Commands

The app’s own, by the id `app.run`, `app.hide`, `app.rename`, `app.rebind` and `app.wrap` take (its title does too). Those marked * keep their key.


Curator:

- `about` *: About Curator

Edit:

- `settings` *: Settings…

File:

- `newLilyPond`: New LilyPond Score…
- `open`: Open…
- `importScore`: Import…
- `close`: Close
- `save`: Save
- `saveAs`: Save As…
- `exportVideo`: Export Video…
- `exportWeb`: Export to Web…

Edit:

- `undo` *: Undo
- `redo` *: Redo
- `cut` *: Cut
- `copy` *: Copy
- `paste` *: Paste
- `delete` *: Delete
- `selectAll` *: Select All
- `findPhrase`: Find Phrase…
- `projectSettings`: Project Settings…

View:

- `showPreview`: Hide / Show Preview
- `showTimeline`: Hide / Show Timeline
- `maximizePreview`: Maximize Preview
- `maximizeTimeline`: Maximize Timeline
- `showPlayerMap`: Score / Player Map
- `showTabBar`: Hide / Show Tab Bar
- `showAllTabs`: Show All Tabs

MIDI:

- `midiVelocity`: Shade Notes by Velocity
- `midiSharedRange`: Shared Pitch Range
- `midiTallerRows`: Taller Rows
- `midiShorterRows`: Shorter Rows
- `midiWiderBeats`: Wider Beats
- `midiNarrowerBeats`: Narrower Beats
- `midiFileTempo`: Use File’s Tempo

Window:

- `previousTab`: Show Previous Tab
- `nextTab`: Show Next Tab

The editor’s keys, in no menu:

- `playPause` *: Play / Pause
- `goToStart`: Go to start
- `goToEnd`: Go to end
- `goTo`: Go to bar or time
- `metronome`: Metronome
- `tapAnchors`: Tap anchors
- `warp`: Warp
- `selectTool`: Select
- `drawTool`: Draw
- `eraseTool`: Erase
- `trimStart`: Start at the playhead
- `trimEnd`: End at the playhead
- `deselect` *: Deselect

## Settings

What `app.setting` reads and sets:

- `theme` ("light", "dark" or "system"): Light or dark.
- `accent` ("#rrggbb"): The accent colour.
- `style` ("refined" or "carbon"): The interface’s style.
- `text_size` ("small", "medium" or "large"): The interface’s text size.
- `density` ("compact", "standard" or "roomy"): How close the controls are set.
- `reduce_motion` (true or false): Whether the interface moves less.
- `language` (a locale ("en", "zh-Hans") or "system"): The interface’s language.
- `tab_bar` (true or false): Whether the tab bar shows.

## Keys

A key is what is held, then the key, joined by `+`: `"cmd+shift+k"`. Held: `cmd`, `ctrl`, `alt`, `shift` (`cmd` is ⌘ on a Mac and Ctrl elsewhere). A key is written as it is typed (`k`, `7`, `,`), or by name: `space`, `enter`, `tab`, `escape`, `backspace`, `delete`, `left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`, `f1`, `f2`, `f3`, `f4`, `f5`, `f6`, `f7`, `f8`, `f9`, `f10`, `f11`, `f12`.

Icons: `add`, `close`, `delete`, `reset`, `copy`, `check`, `search`, `more`, `open`, `project`, `score`, `export`, `assets`, `play`, `pause`, `music`, `draw`, `erase`, `tidy`, `audio`, `repeat`, `snap`, `frame`, `lanes`, `image`, `pin`, `link`, `captions`, `settings`, `fonts`, `extensions`, `done`, `failed`, `warning`, `previous`, `next`, `align`, `moveUp`, `moveDown`, `chapters`, `ai`, `show`, `hide`, `test`, `fetch`, `code`, `tonality`, `website`, `keyboard`.
