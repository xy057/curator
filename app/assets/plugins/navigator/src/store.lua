-- What Navigator keeps: its options, and for each project its bookmarks, its loop and where
-- the playhead was left.
--
-- Edge: a plugin has no place in a project's file. All it keeps is one table in the app's
-- settings (curator.settings, saved as JSON), so each project's part is filed under the
-- project's path: move or rename the file and its bookmarks stay behind, and they never
-- travel with the project to another computer. What should travel is an extension's to keep
-- (curator.data there: saved in the .ccs, and an Undo step).

local M = {}

local DEFAULTS = {resume = true, preroll = 0, home_to_loop = true, bars = false}

local options   -- the options as kept, read once
local cache = {} -- each project's part by its path, read once
-- Edge: a project not saved yet has no path. Its part is kept here, in memory, until the
-- project is saved (M.saved) or Curator closes.
local unsaved, last_unsaved = {}, nil

--- The options, each as kept or as it comes.
function M.options()
  if not options then
    local kept = curator.settings().options or {}
    options = {}
    for name, default in pairs(DEFAULTS) do
      if kept[name] == nil then options[name] = default else options[name] = kept[name] end
    end
  end
  return options
end

function M.set_options(changed)
  local all = curator.settings()
  all.options = changed
  curator.save_settings(all)
  options = nil
end

--- The part of the project showing: {bookmarks = {{at, name}…}, loop = {from, to}, left = seconds}.
-- Change it, then call M.keep().
function M.mine()
  local path = project.path()
  if not path then
    last_unsaved = project.name() or ""
    unsaved[last_unsaved] = unsaved[last_unsaved] or {bookmarks = {}}
    return unsaved[last_unsaved]
  end
  if not cache[path] then
    local kept = (curator.settings().projects or {})[path] or {}
    kept.bookmarks = kept.bookmarks or {}
    cache[path] = kept
  end
  return cache[path]
end

--- Keeps the showing project's part as it is now.
function M.keep()
  local path = project.path()
  local mine = path and cache[path]
  if not mine then return end
  local all = curator.settings()
  -- curator.map: an empty table is saved as {} rather than [], so it reads back as one.
  all.projects = all.projects or curator.map({})
  -- A project with nothing kept leaves nothing behind.
  local empty = #mine.bookmarks == 0 and not mine.loop and not mine.left
  all.projects[path] = (not empty) and mine or nil
  curator.save_settings(all)
end

--- The project showing was saved: what was kept for it while it had no path moves under it.
function M.saved()
  local path = project.path()
  local mine = last_unsaved and unsaved[last_unsaved]
  if not path or not mine then return end
  unsaved[last_unsaved] = nil
  last_unsaved = nil
  if not cache[path] then
    cache[path] = mine
    M.keep()
  end
end

return M
