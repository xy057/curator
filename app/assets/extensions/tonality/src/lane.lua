-- The Tonality lane: what it shows, what its tools and keys do, the buttons on its name, and
-- the dialog that names a key area.
--
-- Key areas are edited as an instrument's regions are. One drawn, moved or trimmed over others
-- goes over them: what it covers of them is cut back, and given back as the drag goes on.

local areas = require("areas")
local band = require("band")
local find = require("find")
local keys = require("keys")
local tr = curator.tr

local M = {}
local LANE = "lane" -- the lane's id in the connector

-- lane.items: every key area, in its key's colour, named as the band names it.
function M.items()
  local items = {}
  for i, a in ipairs(areas.list()) do
    items[i] = {from = a.from, to = a.to, label = band.label(a), color = keys.color(a.tonic, a.minor)}
  end
  return items
end

local function copy(list)
  local out = {}
  for i, area in ipairs(list) do out[i] = area end
  return out
end

-- Keeps list as the key areas, inside the score and tidied. select (when given) is selected
-- where it went; else the selection stays on the area it was on.
local function set(list, select)
  local total = score.quarters()
  local selected = lanes.selected(LANE)
  local was = selected and areas.list()[selected]
  local inside = {}
  for i, a in ipairs(list) do
    inside[i] = areas.with(a, math.clamp(a.from, 0.0, total), math.clamp(a.to, 0.0, total))
  end
  local tidied = areas.tidy(inside)
  local function index_of(area)
    if not area then return nil end
    for i, t in ipairs(tidied) do
      if math.abs(t.from - area.from) < 1e-6 and t.tonic == area.tonic and t.minor == area.minor then return i end
    end
  end
  if select then
    lanes.select(LANE, index_of(areas.tidy({select})[1]))
  else
    lanes.select(LANE, index_of(was))
  end
  areas.keep(tidied)
end

--- Adds an area over what it covers of the others, and selects it.
function M.add(area)
  local list = areas.list()
  list[#list + 1] = area
  set(list, area)
end

--- Area index of base (the areas as a gesture found them; the current ones by default) as
--- area: moved, trimmed or changed over what it then covers of the others.
function M.reshape(index, area, base)
  local list = copy(base or areas.list())
  if not list[index] then return end
  table.remove(list, index)
  list[#list + 1] = area
  set(list, area)
end

--- Removes area index; nothing is selected then.
function M.delete(index)
  local list = areas.list()
  if not index or not list[index] then return end
  lanes.select(LANE, nil)
  table.remove(list, index)
  set(list)
end

-- An area's key, the marking the band shows instead of the key's name (empty: the name) and
-- its bars: area index, or a new one when index is nil.
local function ask(index, area)
  local from_shown, to_shown = score.format(area.from), score.format(area.to)
  -- A field as shown is the area's own edge, not its rounding.
  local function place(typed, shown, edge)
    if typed == shown then return edge end
    return score.parse(typed)
  end
  local options = {}
  for i, key in ipairs(keys.all) do
    options[i] = {value = i, label = keys.label(key.tonic, key.minor), color = keys.color(key.tonic, key.minor)}
  end
  ui.form {
    title = index and curator.tr_in("tonality", "Key") or tr("Add Key"),
    confirm = index and tr("Apply") or tr("Add"),
    width = 400,
    spacing = 16,
    rows = {
      {
        {id = "from", label = tr("From"), value = from_shown, focus = true},
        {id = "to", label = tr("Until"), value = to_shown},
      },
      {
        -- The music's key: the score editor's "Key" is a key signature.
        {id = "key", label = curator.tr_in("tonality", "Key"), type = "choice", value = keys.index(area.tonic, area.minor), options = options},
        {
          id = "marking", label = tr("Marking"), value = area.label or "", max = areas.max_label,
          hint = function(values)
            local key = keys.all[values.key]
            return keys.label(key.tonic, key.minor)
          end,
        },
      },
    },
    leading = index and {{id = "remove", title = tr("Remove")}} or nil,
    check = function(values)
      local from, to = place(values.from, from_shown, area.from), place(values.to, to_shown, area.to)
      if not from or not to then return tr("Enter a bar or bar.beat, like 12 or 12.3") end
      if to <= from then return tr("Set Until after From") end
    end,
    done = function(values, button)
      if button == "remove" then return M.delete(index) end
      local key = keys.all[values.key]
      local result = {
        from = place(values.from, from_shown, area.from),
        to = place(values.to, to_shown, area.to),
        tonic = key.tonic,
        minor = key.minor,
        label = values.marking,
      }
      if index then M.reshape(index, result) else M.add(result) end
    end,
  }
end

--- A new area from one place to another, in the key the music is in there.
function M.draft(from, to)
  local tonic, minor = areas.key_at(from)
  return {from = from, to = to, tonic = tonic, minor = minor}
end

-- lane.draw: the Draw tool was dragged across bars. Asks for the key.
function M.draw(from, to)
  ask(nil, M.draft(from, to))
end

-- lane.open: an area was double-clicked.
function M.open(index)
  local area = areas.list()[index]
  if area then ask(index, area) end
end

-- The areas as a drag found them: a move goes over these, an erase's pieces are of these.
local before = {}

-- lane.begin: a drag begins.
function M.begin()
  before = areas.list()
end

-- lane.change: an area is being moved or trimmed.
function M.change(index, from, to)
  if before[index] then M.reshape(index, areas.with(before[index], from, to), before) end
end

-- lane.cut: the Erase tool went over areas. Every area as it is left, each a piece of one of
-- those the drag found.
function M.cut(pieces)
  local list = {}
  for _, piece in ipairs(pieces) do
    if before[piece.of] then list[#list + 1] = areas.with(before[piece.of], piece.from, piece.to) end
  end
  lanes.select(LANE, nil)
  set(list)
end

-- lane.remove: Delete was pressed with an area selected.
function M.remove(index)
  M.delete(index)
end

-- lane.nudge: ← or → with an area selected. It moves to the next or previous barline (or
-- beat), over what it then covers, as a region does.
function M.nudge(index, direction, fine)
  local a = areas.list()[index]
  if not a then return end
  local unit = fine and "beat" or "bar"
  local to = direction > 0 and editor.next(a.from, unit) or editor.previous(a.from, unit)
  local delta = math.clamp(to - a.from, -a.from, score.quarters() - a.to)
  if math.abs(delta) < 1e-9 then return end
  M.reshape(index, areas.with(a, a.from + delta, a.to + delta))
end

-- lane.trim: [ or ] with an area selected. It now starts (or ends) at the beat nearest the
-- playhead, unless that would turn it inside out.
function M.trim(index, edge)
  local a = areas.list()[index]
  if not a then return end
  local at = editor.nearest(score.quarter(editor.playhead()), "beat")
  if edge == "start" then
    if at >= a.to - 1e-6 then return end
    M.reshape(index, areas.with(a, at, a.to))
  else
    if at <= a.from + 1e-6 then return end
    M.reshape(index, areas.with(a, a.from, at))
  end
end

-- Add Key: a key from the beat the playhead is in to where the next one starts, in the key
-- there.
function M.add_at_playhead()
  local seconds = editor.playhead()
  local at = math.clamp(score.quarter(seconds), 0.0, score.quarters() - 1e-6)
  local start = editor.beat(at, score.pass_at(seconds))
  ask(nil, M.draft(start, areas.next_start(start)))
end

-- Whether Find Keys is reading the score.
local finding = false

--- The keys found in the music, in place of the areas there are (one Undo step). An area
--- found where one was, in the same key, keeps its marking.
function M.found(music)
  local found = find.keys(music)
  if #found == 0 then return end
  local function place(at) return math.round(at * 1e6) end
  local function id(a) return place(a.from) .. " " .. place(a.to) .. " " .. a.tonic .. " " .. tostring(a.minor) end
  local markings = {}
  for _, a in ipairs(areas.list()) do
    if a.label then markings[id(a)] = a.label end
  end
  for _, a in ipairs(found) do a.label = markings[id(a)] end
  lanes.select(LANE, nil)
  set(found)
end

-- Find Keys: reads the music (off to the side: a long score takes a moment), then keeps the
-- keys heard in it. A score that has changed meanwhile takes nothing.
function M.find()
  if finding then return end
  score.music(function(music)
    finding = false
    if music then M.found(music) end
  end)
  finding = true
end

function M.can_find()
  return not finding
end

-- Remove Key: the selected one.
function M.remove_selected()
  M.delete(lanes.selected(LANE))
end

function M.has_selection()
  return lanes.selected(LANE) ~= nil
end

return M
