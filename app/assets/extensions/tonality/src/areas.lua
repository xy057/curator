-- Key areas: the key the music is in, stretch by stretch.
--
-- The project keeps them as {areas = {{from, to, tonic, mode, marking}, ...}}: from and to in
-- quarter notes from the start of the score, the tonic in fifths from C (see keys.lua), the
-- mode "major" or "minor", and the user's own marking when there is one (the band then shows
-- it instead of the key's name). They are kept in the score's order and never overlap.
--
-- Here an area is {from, to, tonic, minor, label}.

local keys = require("keys")

local M = {}

M.max_label = 40 -- the longest marking an area keeps

--- An area like another, from one place to another.
function M.with(area, from, to)
  return {from = from, to = to, tonic = area.tonic, minor = area.minor, label = area.label}
end

-- An area as it is saved. (+ 0.0: a place is saved as a fraction, 4.0.)
local function row(area)
  local saved = {area.from + 0.0, area.to + 0.0, area.tonic, area.minor and "minor" or "major"}
  if area.label then saved[5] = area.label end
  return saved
end

--- The areas in data (the project's own by default), in the score's order.
function M.list(data)
  local list = {}
  for i, saved in ipairs((data or curator.data()).areas or {}) do
    list[i] = {from = saved[1], to = saved[2], tonic = saved[3], minor = saved[4] == "minor", label = saved[5]}
  end
  return list
end

--- A list of areas as data to save.
function M.data(list)
  local rows = {}
  for i, area in ipairs(list) do rows[i] = row(area) end
  return {areas = rows}
end

--- list as it is kept: in the score's order, never overlapping. What a later one in the list
--- covers of an earlier one is taken out of it (cut back, or cut in two), as a key drawn over
--- others paints them. Only keys there are stay; markings are tidied (an empty one is none).
function M.tidy(list)
  local kept = {}
  for _, a in ipairs(list) do
    local finite = a.from > -math.huge and a.from < math.huge and a.to > -math.huge and a.to < math.huge
    if finite and a.from >= 0 and not (a.to - a.from < 1e-6) and keys.valid(a.tonic, a.minor) then
      local label = a.label and text.squeeze(a.label)
      if label and #label > M.max_label then label = label:sub(1, M.max_label) end
      if label == "" then label = nil end
      local around = {}
      for _, k in ipairs(kept) do
        if k.from < a.from - 1e-6 then around[#around + 1] = M.with(k, k.from, math.min(k.to, a.from)) end
        if k.to > a.to + 1e-6 then around[#around + 1] = M.with(k, math.max(k.from, a.to), k.to) end
      end
      around[#around + 1] = {from = a.from + 0.0, to = a.to + 0.0, tonic = a.tonic, minor = a.minor, label = label}
      kept = around
    end
  end
  table.sort(kept, function(x, y) return x.from < y.from end)
  return kept
end

--- Whether two lists of areas are the same.
function M.same(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if x.from ~= y.from or x.to ~= y.to or x.tonic ~= y.tonic or x.minor ~= y.minor or x.label ~= y.label then return false end
  end
  return true
end

--- Keeps a tidied list as the project's key areas: one Undo step, or nothing when they are
--- those already.
function M.keep(tidied)
  if M.same(tidied, M.list()) then return end
  curator.data().areas = M.data(tidied).areas
  curator.save("Tonality")
end

--- The key at a place: the area's there, else the last one's before it (the first's before
--- them all), else C major. What a new area starts as. Returns tonic, minor.
function M.key_at(at)
  local list, found = M.list(), nil
  for _, a in ipairs(list) do
    if a.from <= at + 1e-9 then found = a end
  end
  found = found or list[1]
  if found then return found.tonic, found.minor end
  return 0, false
end

--- Where the area after a place starts, else the end of the score: how far a key added at
--- that place goes.
function M.next_start(at)
  for _, a in ipairs(M.list()) do
    if a.from > at + 1e-6 then return a.from end
  end
  return score.quarters()
end

-- project.load: a project is being opened. Checks what it saved, and tidies it.
function M.load(data)
  local list = {}
  for i, saved in ipairs(data.areas or {}) do
    local where = "areas[" .. (i - 1) .. "]"
    local from, to, tonic, mode, label
    if type(saved) == "table" and (#saved == 4 or #saved == 5) then
      from, to, tonic, mode, label = saved[1], saved[2], saved[3], saved[4], saved[5]
    end
    local read = type(from) == "number" and type(to) == "number" and math.type(tonic) == "integer" and type(mode) == "string"
      and (label == nil or type(label) == "string") and math.abs(from) <= 1e9 and math.abs(to) <= 1e9
    if not read then error(where .. " is not a stretch and a key.", 0) end
    if from < 0 then error(where .. " starts before the score.", 0) end
    if to <= from then error(where .. " ends before it starts.", 0) end
    tonic = math.tointeger(tonic)
    local minor = mode == "minor"
    if (mode ~= "major" and mode ~= "minor") or not keys.valid(tonic, minor) then error(where .. " is not a key there is.", 0) end
    list[i] = {from = from, to = to, tonic = tonic, minor = minor, label = label}
  end
  return M.data(M.tidy(list))
end

-- project.used: whether the project has key areas.
function M.used()
  return #(curator.data().areas or {}) > 0
end

-- project.replaced: the score is being replaced. Each area goes where its places are in the
-- new score, cut at its end; one with nothing left of it is lost.
function M.replaced(data, carry, length)
  local list, kept = M.list(data), {}
  for _, a in ipairs(list) do
    local from, to = carry(a.from), carry(a.to) or length
    if from and to > from then kept[#kept + 1] = M.with(a, from, to) end
  end
  local lost = #list - #kept
  local said
  if lost == 1 then said = curator.tr("1 key") elseif lost > 1 then said = curator.tr("{n} keys", {n = lost}) end
  return M.data(M.tidy(kept)), said
end

return M
