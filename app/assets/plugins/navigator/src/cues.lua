-- Timestamps and cue sheets: every mark and bookmark with the time it is heard.

local places = require("places")
local store = require("store")
local tr = curator.tr

local M = {}

-- Every place with its time, the start of the piece first.
local function cues()
  local list = {}
  for _, p in ipairs(places.all(store.mine().bookmarks)) do
    list[#list + 1] = {seconds = score.seconds(p.at), name = p.name, bar = places.bar(p.at)}
  end
  -- A video's chapters must begin at 0:00.
  if #list == 0 or list[1].seconds > 0.5 then
    table.insert(list, 1, {seconds = 0, name = tr("Start"), bar = 1})
  end
  return list
end

local function name_of(cue)
  if store.options().bars then return tr("{name} (bar {n})", {name = cue.name, n = cue.bar}) end
  return cue.name
end

--- The cues as lines a video's description takes as chapters: "1:05 Coda".
function M.timestamps()
  local lines = {}
  for i, cue in ipairs(cues()) do lines[i] = places.clock(cue.seconds) .. " " .. name_of(cue) end
  return lines
end

function M.copy()
  local lines = M.timestamps()
  app.copy(table.concat(lines, "\n"))
  ui.message(tr("{n} timestamps copied", {n = #lines}))
end

local function quoted(field)
  return '"' .. field:gsub('"', '""') .. '"'
end

-- The cue sheet in each form it is saved in, by the extension of the name chosen.
local WRITERS = {
  csv = function(list)
    local lines = {"Time,Bar,Name"}
    for _, cue in ipairs(list) do
      lines[#lines + 1] = table.concat({places.clock(cue.seconds), string.format("%d", cue.bar), quoted(cue.name)}, ",")
    end
    return table.concat(lines, "\n") .. "\n"
  end,
  md = function(list)
    local lines = {"| Time | Bar | Name |", "| ---: | ---: | :--- |"}
    for _, cue in ipairs(list) do
      lines[#lines + 1] = string.format("| %s | %d | %s |", places.clock(cue.seconds), cue.bar, (cue.name:gsub("|", "\\|")))
    end
    return table.concat(lines, "\n") .. "\n"
  end,
  txt = function() return table.concat(M.timestamps(), "\n") .. "\n" end,
}

--- The cue sheet as a file of a kind holds it: "csv", "md", or lines of text.
function M.sheet(extension)
  return (WRITERS[extension] or WRITERS.txt)(cues())
end

--- Saves the cue sheet where the user says: text, CSV or Markdown.
-- Edge: the file dialog is the only way out to the disk. A plugin can't write beside the
-- project by itself, or to a folder it remembers.
function M.export()
  ui.save_file{
    name = (project.name() or tr("Cue Sheet")) .. ".txt",
    types = {
      {label = "Text", extensions = {"txt"}},
      {label = "CSV", extensions = {"csv"}},
      {label = "Markdown", extensions = {"md"}},
    },
    write = function(file) return M.sheet(file.extension) end,
    done = function(file)
      if file.error then return ui.message(file.error) end
      ui.message(tr("Exported “{name}”", {name = file.name}))
    end,
  }
end

return M
