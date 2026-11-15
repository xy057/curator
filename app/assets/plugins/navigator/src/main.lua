-- Navigator: a Go menu for getting around a score while it is curated.
--
--   Go ▸ Next Mark, Previous Mark    through the rehearsal marks and bookmarks, in score order
--   Go ▸ Go to Place…                any of them, from a list
--   Go ▸ Copy Timestamps             "1:05 Coda" lines, for a video's description
--   Go ▸ Export Cue Sheet…           the same as a file: text, CSV or Markdown
--   Go ▸ Bookmarks ▸ …               places of your own, kept for each project
--   Go ▸ Loop ▸ …                    a passage played round and round
--   Go ▸ Rehearsal Marks ▸ …         an item for each mark of the score showing
--   Home ▸ Continue Last Project, and the playhead back where it was left
--
-- It is also Curator's showcase of how far a plugin reaches, and of where it ends. Where the
-- code meets an end, a comment starts with "Edge:". In short:
--   · A plugin adds commands and asks for dialogs; it draws nothing of its own.
--   · It keeps settings in the app, not data in a project.
--   · It hears events (opened, saved, shown, playing), not frames, and not edits.
--   · It reaches a file only through a dialog the user answers; it has no network.
--   · It changes the app's commands (wrap, hide, rename, rebind), not the app's windows.
--
-- The files: this one wires commands and events; places.lua says where things are, store.lua
-- keeps what is kept, loop.lua turns the loop, bookmarks.lua and cues.lua are their dialogs
-- and files. Each is a module: `require` gives the table it returns.

local places = require("places")
local store = require("store")
local loop = require("loop")
local bookmarks = require("bookmarks")
local cues = require("cues")
local tr = curator.tr

-- Asked each time a menu is drawn, so kept quick. Without a score (on Home) the commands
-- that need one are grey: asking the score for anything there would raise an error.
local function has_score() return score.open() end

local function all_places() return places.all(store.mine().bookmarks) end

-- MARK: Getting around

local function step(direction)
  local all, now, target = all_places(), places.playhead(), nil
  if direction > 0 then
    for _, p in ipairs(all) do
      if p.at > now + 0.01 then target = p break end
    end
  else
    -- While it plays, the mark just passed is the one sounding: Previous goes to the one before.
    local slack = project.playing() and 1 or 0.01
    for i = #all, 1, -1 do
      if all[i].at < now - slack then target = all[i] break end
    end
  end
  if not target then
    if direction > 0 then return ui.message(tr("No mark after the playhead")) end
    return ui.message(tr("No mark before the playhead"))
  end
  places.go(target.at)
  ui.message(places.label(target))
end

local function choose()
  local all = all_places()
  if #all == 0 then return ui.message(tr("No rehearsal marks or bookmarks yet")) end
  -- A choice's values are texts of the plugin's own: here "p1", "p2"…, each place's turn in the list.
  local options, by, nearest = {}, {}, "p1"
  local now = places.playhead()
  for i, p in ipairs(all) do
    local value = "p" .. i
    options[i], by[value] = {value = value, label = places.label(p)}, p
    if p.at <= now + 0.01 then nearest = value end
  end
  ui.form{
    title = "Go to Place",
    confirm = "Go",
    rows = { {id = "place", label = "Place", type = "choice", value = nearest, options = options} },
    done = function(values) places.go(by[values.place].at) end,
  }
end

-- A command is a table: where it shows (menu, key, toolbar, home, preview) and what it does.
-- "Go" is no menu of the app's, so it becomes a new one, before Window.
app.command{ id = "navigator.next", title = "Next Mark", menu = "Go", key = "cmd+]", enabled = has_score, run = function() step(1) end }
app.command{ id = "navigator.previous", title = "Previous Mark", menu = "Go", key = "cmd+[", enabled = has_score, run = function() step(-1) end }
app.command{ id = "navigator.choose", title = "Go to Place…", menu = "Go", key = "cmd+j", enabled = has_score, run = choose }
app.command{ id = "navigator.timestamps", title = "Copy Timestamps", menu = "Go", enabled = has_score, run = cues.copy }
app.command{ id = "navigator.cues", title = "Export Cue Sheet…", menu = "Go", enabled = has_score, run = cues.export }

-- MARK: Bookmarks

-- A slash puts a menu inside a menu.
app.command{
  id = "navigator.bookmark",
  title = "Add Bookmark…",
  menu = "Go/Bookmarks",
  key = "cmd+b",
  enabled = has_score,
  run = function() bookmarks.add(places.playhead()) end,
}
app.command{ id = "navigator.bookmarks", title = "Edit Bookmarks…", menu = "Go/Bookmarks", enabled = has_score, run = bookmarks.edit }
-- `preview` puts a command in the menu a right-click on the score opens; it is then given
-- the place that was clicked.
app.command{ id = "navigator.bookmark-here", title = "Add Bookmark Here…", preview = true, run = function(at) bookmarks.add(at) end }

-- MARK: The loop

app.command{
  id = "navigator.loop",
  title = "Loop Playback",
  menu = "Go/Loop",
  key = "cmd+l",
  toolbar = true, -- and a button on the editor's toolbar, lit while `checked` says so
  icon = "repeat",
  enabled = has_score,
  checked = loop.on,
  run = function()
    if loop.on() then return loop.turn(false) end
    -- With no loop set yet, it is the passage the playhead is in.
    if loop.range() then loop.turn(true) else loop.around(places.playhead(), all_places()) end
  end,
}
app.command{ id = "navigator.loop-from", title = "Loop From Playhead", menu = "Go/Loop", enabled = has_score,
  run = function() loop.from(places.beat(places.playhead()), all_places()) end }
app.command{ id = "navigator.loop-to", title = "Loop To Playhead", menu = "Go/Loop", enabled = has_score,
  run = function() loop.to(places.beat(places.playhead()), all_places()) end }
app.command{ id = "navigator.loop-around", title = "Loop Between Marks", menu = "Go/Loop", enabled = has_score,
  run = function() loop.around(places.playhead(), all_places()) end }
app.command{ id = "navigator.loop-clear", title = "Clear Loop", menu = "Go/Loop", enabled = function() return loop.range() ~= nil end, run = loop.clear }
app.command{ id = "navigator.loop-from-here", title = "Loop From Here", preview = true, run = function(at) loop.from(places.beat(at), all_places()) end }
app.command{ id = "navigator.loop-to-here", title = "Loop To Here", preview = true, run = function(at) loop.to(places.beat(at), all_places()) end }

-- MARK: Lists in the menu

-- Edge: a menu's items are commands and nothing else, so a list in a menu is made by adding
-- a command for each thing and taking the spare ones out as the list changes. A plugin adds
-- 500 commands at most: a long list belongs in a dialog (Go to Place…, Edit Bookmarks…), and
-- the menus show the first thirty.
local MOST = 30
local LISTS = {
  bookmark = {menu = "Go/Bookmarks", listed = 0},
  mark = {menu = "Go/Rehearsal Marks", listed = 0},
}

local function list(kind, items)
  local into, count = LISTS[kind], math.min(#items, MOST)
  for i = 1, count do
    local place = items[i]
    -- Adding a command with the id of one this plugin has replaces it, where it is.
    app.command{ id = "navigator." .. kind .. "." .. i, title = places.label(place), menu = into.menu, run = function() places.go(place.at) end }
  end
  for i = count + 1, into.listed do app.remove("navigator." .. kind .. "." .. i) end
  into.listed = count
end

-- Edge: nothing tells a plugin that the score was edited. The marks are read again when a
-- project opens, is shown or is saved, so one added in the score editor shows in the menu
-- after the next save.
local function refresh()
  local open = score.open()
  list("bookmark", open and store.mine().bookmarks or {})
  list("mark", open and places.marks() or {})
end

bookmarks.changed = refresh

-- MARK: What happens

-- Edge: an event's function runs when the thing has happened, and is given what the app
-- says of it (a project: its name and path). What it asks of `project` and `score` is the
-- project showing now, which is the one opened only if the user hasn't moved on.
app.on("project.opened", function(opened)
  refresh()
  if opened.path and opened.path == project.path() and store.options().resume then
    local left = store.mine().left
    if left and left > 0 and left < project.duration() then project.seek(left) end
  end
end)

app.on("project.shown", function()
  refresh()
  loop.turn(loop.on()) -- another project: its own loop, or none
end)

app.on("project.saved", function(saved)
  if saved.path == project.path() then store.saved() end
  refresh()
end)

app.on("project.closed", refresh)
app.on("playback.started", loop.watch)

-- Edge: nothing is told as the playhead is dragged, and "project.closed" comes once the tab
-- is gone, its playhead with it. So where the playhead was left is kept each time playback
-- stops: the nearest a plugin gets to "as the project closes".
app.on("playback.stopped", function()
  loop.watch()
  if project.open() and project.path() then
    store.mine().left = project.time()
    store.keep()
  end
end)

-- Staying compatible: something newer than the API level in plugin.json is asked for before
-- it is used. No Curator has this event yet; one that does would call refresh by itself.
if curator.has("event:score.edited") then app.on("score.edited", refresh) end

-- MARK: Home

-- `home` puts a button on Home. The files of File ▸ Open Recent are the app's to give.
app.command{
  id = "navigator.continue",
  title = "Continue Last Project",
  home = true,
  icon = "play",
  enabled = function() return app.recent()[1] ~= nil end,
  run = function() app.open(app.recent()[1]) end,
}

-- MARK: One of the app's own commands, changed

-- app.wrap puts a function around a command of the app's: it runs in the command's place
-- however the command is chosen (its key, the toolbar's button, app.run), and calls
-- original() to do what the app does. Here Go to start stops at the loop's start first.
-- Edge: a wrap sees that the command was chosen, not what it will do: it can run before it,
-- after it or instead of it, and can't change how the app does it.
local function wrap_home()
  if not store.options().home_to_loop then return app.wrap("goToStart", nil) end
  app.wrap("goToStart", function(original)
    local range = loop.on() and loop.range()
    if range and math.abs(project.time() - score.seconds(range.from)) > 0.05 then
      places.go(range.from)
    else
      original()
    end
  end)
end

-- MARK: Settings

-- Listening to "settings" puts Settings… in Navigator's menu in Settings ▸ Plugins.
-- Edge: the dialog is the app's, laid out from rows of fields (text, switch, choice). A
-- plugin can't put a control of its own in it, or a page of its own in Settings.
local LEAD_INS = {
  {value = "none", label = "None", seconds = 0},
  {value = "one", label = "1 second", seconds = 1},
  {value = "two", label = "2 seconds", seconds = 2},
}

app.on("settings", function()
  local options = store.options()
  local lead_in = "none"
  for _, choice in ipairs(LEAD_INS) do
    if choice.seconds == options.preroll then lead_in = choice.value end
  end
  ui.form{
    title = "Navigator",
    confirm = "Save",
    rows = {
      {id = "resume", label = "Return to where the playhead was left", type = "switch", value = options.resume},
      {id = "home_to_loop", label = "Go to start stops at the loop’s start", type = "switch", value = options.home_to_loop},
      {id = "bars", label = "Bar numbers in timestamps", type = "switch", value = options.bars},
      {id = "lead_in", label = "Lead-in before the loop", type = "choice", value = lead_in, options = LEAD_INS},
    },
    done = function(values)
      local seconds = 0
      for _, choice in ipairs(LEAD_INS) do
        if choice.value == values.lead_in then seconds = choice.seconds end
      end
      store.set_options({resume = values.resume, home_to_loop = values.home_to_loop, bars = values.bars, preroll = seconds})
      wrap_home()
    end,
  }
end)

-- MARK: Starting

-- This file runs once, as Curator starts or as Navigator's switch is turned on: with a
-- project showing in the second case, so what is listed is listed now.
wrap_home()
refresh()
