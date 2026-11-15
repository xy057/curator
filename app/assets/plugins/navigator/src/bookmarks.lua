-- Bookmarks: places of your own in a project, each with a name.

local places = require("places")
local store = require("store")
local tr = curator.tr

local M = {}

-- Called when the bookmarks changed: main.lua puts them in the menu again.
M.changed = function() end

local function sorted(list)
  table.sort(list, function(a, b) return a.at < b.at end)
  return list
end

local function replace(list)
  store.mine().bookmarks = sorted(list)
  store.keep()
  M.changed()
end

--- Asks for a bookmark's name at a place, and adds it.
function M.add(at)
  at = places.beat(at)
  ui.form{
    title = "Add Bookmark",
    confirm = "Add",
    rows = {
      {
        {id = "name", label = "Name", value = tr("Bar {n}", {n = places.bar(at)}), focus = true, max = 60, flex = 3},
        {id = "at", label = "At", value = score.format(at), flex = 1},
      },
    },
    -- Said under the fields as they are typed: "" keeps Add off without saying anything.
    check = function(values)
      if text.trim(values.name) == "" then return "" end
      if not score.parse(values.at) then return tr("Enter a bar or bar.beat, like 12 or 12.3") end
      return nil
    end,
    done = function(values)
      local list = store.mine().bookmarks
      list[#list + 1] = {at = score.parse(values.at), name = text.trim(values.name)}
      replace(list)
      ui.message(tr("Bookmark added"))
    end,
  }
end

-- A row of the sheet: its cells as typed, and the place it was made from (kept exactly while
-- its cell still shows it as written).
local function row(bookmark)
  return {at = score.format(bookmark.at), name = bookmark.name, place = bookmark.at}
end

local function place_of(r)
  if r.place and r.at == score.format(r.place) then return r.place end
  return score.parse(r.at)
end

local function from_rows(rows)
  local list = {}
  for _, r in ipairs(rows) do
    local at, name = place_of(r), text.trim(r.name)
    if at and name ~= "" then list[#list + 1] = {at = at, name = name} end
  end
  return sorted(list)
end

-- The file bookmarks travel in: a line each, "bar.beat<tab>name". Plain enough to write by
-- hand, or to make in a spreadsheet. A place is written as score.format says it, so it comes
-- back as exactly as a bar and a beat can say: bookmarks are made on a beat (places.beat),
-- which comes back as it was.
local TYPES = {{label = "Text", extensions = {"txt", "tsv"}}}

--- Bookmarks as the text of such a file.
function M.write(list)
  local lines = {}
  for i, b in ipairs(list) do lines[i] = score.format(b.at) .. "\t" .. b.name end
  return table.concat(lines, "\n") .. "\n"
end

--- The bookmarks in such a file's text; a line that isn't one is passed over.
function M.read(contents)
  local list = {}
  for _, line in ipairs(text.lines(contents)) do
    local at, name = line:match("^%s*([%d%.]+)%s+(.-)%s*$")
    local place = at and score.parse(at)
    if place and name ~= "" then list[#list + 1] = {at = place, name = name} end
  end
  return list
end

--- Opens the bookmarks as a table to edit: Done keeps them, a row left without a name goes.
function M.edit()
  local rows = {}
  for i, b in ipairs(store.mine().bookmarks) do rows[i] = row(b) end
  ui.sheet{
    title = "Bookmarks",
    width = 520,
    columns = {
      {id = "at", label = "At", width = 96},
      {id = "name", label = "Name", max = 60, hint = tr("Leave empty to remove")},
    },
    rows = rows,
    empty = tr("No bookmarks"),
    buttons = {
      {id = "add", title = "Add", icon = "add"},
      {id = "import", title = "Import…"},
      {id = "export", title = "Export…", enabled = function(sheet) return sheet.valid() and #sheet.rows() > 0 end},
    },
    more = "add",
    press = function(id, sheet)
      if id == "add" then
        local at = places.beat(places.playhead())
        sheet.add(row({at = at, name = ""}), "name")
      elseif id == "import" then
        -- Edge: a plugin reads a file only when the user picks it, and gets its text: it
        -- can't list a folder, open a path of its own choosing, or read a file's bytes.
        ui.open_file{
          types = TYPES,
          max = 200000,
          done = function(file)
            if file.too_big then return sheet.notice(tr("This file is too big for bookmarks")) end
            if file.error then return sheet.notice(file.error) end
            local list = M.read(file.text)
            if #list == 0 then return sheet.notice(tr("No bookmarks in this file")) end
            local all = sheet.rows()
            for _, b in ipairs(list) do all[#all + 1] = row(b) end
            sheet.set(all)
            sheet.notice(tr("{n} imported", {n = #list}))
          end,
        }
      else
        ui.save_file{
          name = (project.name() or tr("Bookmarks")) .. ".txt",
          types = TYPES,
          write = function() return M.write(from_rows(sheet.rows())) end,
          done = function(file)
            if file.error then return sheet.notice(file.error) end
            sheet.notice(tr("Exported “{name}”", {name = file.name}))
          end,
        }
      end
    end,
    -- What is wrong with each row: a list as long as the rows, nil where one is fine.
    check = function(rows)
      local said = {}
      for i, r in ipairs(rows) do
        if not place_of(r) then said[i] = {tr("Enter a bar or bar.beat, like 12 or 12.3"), "at"} end
      end
      return said
    end,
    done = function(rows) replace(from_rows(rows)) end,
  }
end

return M
