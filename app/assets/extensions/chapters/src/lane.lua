-- The Chapters lane: what it shows, what its tools do, the buttons on its name, and the
-- dialog that names a chapter.

local chapters = require("chapters")
local tr = curator.tr

local M = {}
local LANE = "lane" -- the lane's id in the connector

-- lane.items: every chapter, from where it starts.
function M.items()
  local items = {}
  for i, chapter in ipairs(chapters.list()) do
    items[i] = {at = chapter[1], label = chapter[2]}
  end
  return items
end

--- Adds a chapter and selects it.
function M.create(at, name)
  local index = chapters.add(at, name)
  if index then lanes.select(LANE, index) end
end

--- Removes chapter index; nothing is selected then.
function M.delete(index)
  if not chapters.list()[index] then return end
  lanes.select(LANE, nil)
  chapters.remove(index)
end

--- Changes chapter index, the selection following it; an empty name removes it.
function M.change(index, at, name)
  if text.trim(name) == "" then return M.delete(index) end
  local now = chapters.update(index, at, name)
  if now and lanes.selected(LANE) then lanes.select(LANE, now) end
end

-- A chapter's name and where it starts, as bar or bar.beat ("12" or "12.3"): chapter index,
-- or a new one when index is nil.
local function ask(index, at, name)
  local shown = score.format(at, true)
  -- The field as shown is the chapter's own start, not its rounding.
  local function place(values)
    if values.from == shown then return at end
    return score.parse(values.from)
  end
  ui.form {
    title = index and tr("Chapter") or tr("Add Chapter"),
    confirm = index and tr("Apply") or tr("Add"),
    width = 400,
    rows = {
      {
        {id = "name", label = tr("Name"), value = name, max = chapters.max_name, flex = 3, focus = true},
        {id = "from", label = tr("From"), value = shown},
      },
    },
    leading = index and {{id = "remove", title = tr("Remove")}} or nil,
    check = function(values)
      local q = place(values)
      if not q then return tr("Enter a bar or bar.beat, like 12 or 12.3") end
      if q >= score.quarters() then return tr("Set From before the end") end
      if chapters.starting_at(q, index) then return tr("Another chapter starts here") end
      if text.trim(values.name) == "" then return "" end
    end,
    done = function(values, button)
      if button == "remove" then return M.delete(index) end
      if index then M.change(index, place(values), values.name) else M.create(place(values), values.name) end
    end,
  }
end

-- lane.add: the Draw tool was clicked at a place.
function M.add(at)
  ask(nil, at, "")
end

-- lane.open: a chapter was double-clicked.
function M.open(index)
  local chapter = chapters.list()[index]
  if chapter then ask(index, chapter[1], chapter[2]) end
end

-- lane.move: a chapter is being dragged.
function M.move(index, at)
  local chapter = chapters.list()[index]
  if chapter then M.change(index, at, chapter[2]) end
end

-- lane.erase: the Erase tool was clicked on a chapter.
function M.erase(index)
  M.delete(index)
end

-- lane.remove: Delete was pressed with a chapter selected.
function M.remove(index)
  M.delete(index)
end

-- Add Chapter: a chapter from the beat the playhead is in.
function M.add_at_playhead()
  local seconds = editor.playhead()
  local q = math.min(math.max(score.quarter(seconds), 0.0), score.quarters() - 1e-6)
  local start = editor.beat(q, score.pass_at(seconds))
  ask(nil, start, "")
end

-- Add from Rehearsal Marks.
function M.add_marks()
  if #chapters.new_marks() == 0 then return end
  lanes.select(LANE, nil)
  chapters.add_marks()
end

function M.can_add_marks()
  return #chapters.new_marks() > 0
end

-- Remove Chapter: the selected one.
function M.remove_selected()
  local index = lanes.selected(LANE)
  if index then M.delete(index) end
end

function M.has_selection()
  return lanes.selected(LANE) ~= nil
end

return M
