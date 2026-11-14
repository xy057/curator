-- Captions: text under the score, each shown while its music sounds.
--
-- The project keeps them as {captions = {{from, to, text}, ...}}, in the order they were
-- added: from and to in quarter notes from the start of the score. One shows at a time, so
-- they never overlap.
--
-- Here a caption is {from, to, text}.

local M = {}

M.default_bars = 4 -- how long a new caption lasts when nothing follows it
local LANE = "lane" -- the Captions lane's id in the connector

--- The captions in data (the project's own by default), in the order they were added.
function M.list(data)
  local list = {}
  for i, saved in ipairs((data or curator.data()).captions or {}) do
    list[i] = {from = saved[1], to = saved[2], text = saved[3]}
  end
  return list
end

--- A list of captions as data to save. (+ 0.0: a place is saved as a fraction, 4.0.)
function M.data(list)
  local rows = {}
  for i, c in ipairs(list) do rows[i] = {c.from + 0.0, c.to + 0.0, c.text} end
  return {captions = rows}
end

--- list with none overlapping, in its order: a caption running into the next by start (the
--- later of two starting together) ends where that one starts, and one left with no length goes.
function M.separate(list)
  local order = {}
  for i = 1, #list do order[i] = i end
  table.sort(order, function(a, b)
    if list[a].from ~= list[b].from then return list[a].from < list[b].from end
    return a < b
  end)
  local ends = {}
  for i, c in ipairs(list) do ends[i] = c.to end
  for k = 1, #order - 1 do
    local i = order[k]
    ends[i] = math.min(ends[i], list[order[k + 1]].from)
  end
  local apart = {}
  for i, c in ipairs(list) do
    if ends[i] - c.from > 1e-9 then
      apart[#apart + 1] = ends[i] == c.to and c or {from = c.from, to = ends[i], text = c.text}
    end
  end
  return apart
end

--- The free stretch around a place among list (leaving out caption except): from the end of
--- the one before (or 0) to the start of the one after (or total). Nothing when the place is
--- inside one (its start included).
function M.room(list, at, total, except)
  local from, to = 0.0, total
  for i, c in ipairs(list) do
    if i ~= except then
      if at >= c.from - 1e-9 and at < c.to - 1e-9 then return nil end
      if c.to <= at + 1e-9 then from = math.max(from, c.to) else to = math.min(to, c.from) end
    end
  end
  return from, to
end

--- The caption of list (other than except) that from–to runs into; nil when it runs into none.
function M.overlapping(list, from, to, except)
  for i, c in ipairs(list) do
    if i ~= except and c.from < to - 1e-9 and c.to > from + 1e-9 then return i end
  end
  return nil
end

--- A new caption from the beat a place is in (or the end of the caption there), among
--- among (the project's captions by default): default_bars bars long, or up to the next
--- caption. nil when there is no room.
function M.draft(quarter, among)
  among = among or M.list()
  local total = score.quarters()
  local start = score.beat_at(math.clamp(quarter, 0.0, total))
  local sorted = {}
  for i, c in ipairs(among) do sorted[i] = c end
  table.sort(sorted, function(a, b) return a.from < b.from end)
  for _, c in ipairs(sorted) do
    if start >= c.from - 1e-9 and start < c.to - 1e-9 then start = c.to end
  end
  local from, to = M.room(among, start, total)
  if not from then return nil end
  local after = score.bars()[score.bar_at(start) + M.default_bars]
  local stop = math.min(after and after.start or total, to)
  if stop - start < 1e-3 then return nil end
  return {from = start, to = stop, text = ""}
end

local function same(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i].from ~= b[i].from or a[i].to ~= b[i].to or a[i].text ~= b[i].text then return false end
  end
  return true
end

local function tidy(c)
  return {from = c.from, to = c.to, text = text.trim(c.text)}
end

-- Keeps list as the project's captions, kept apart: one Undo step.
local function set(list)
  local apart = M.separate(list)
  if #apart ~= #list then lanes.select(LANE, nil) end
  if same(apart, M.list()) then return end
  curator.data().captions = M.data(apart).captions
  curator.save("Captions")
end

--- Adds a caption; one without a text is none.
function M.add(caption)
  if text.trim(caption.text) == "" then return end
  local list = M.list()
  list[#list + 1] = tidy(caption)
  set(list)
end

--- Changes caption index; an empty text removes it.
function M.update(index, caption)
  local list = M.list()
  if not list[index] then return end
  if text.trim(caption.text) == "" then return M.remove(index) end
  local next = tidy(caption)
  local was = list[index]
  if was.from == next.from and was.to == next.to and was.text == next.text then return end
  list[index] = next
  set(list)
end

--- Replaces every caption at once: one Undo step. Those with an empty text are left out.
function M.replace_all(captions)
  local next = {}
  for _, c in ipairs(captions) do
    if text.trim(c.text) ~= "" then next[#next + 1] = tidy(c) end
  end
  if same(next, M.list()) then return end
  lanes.select(LANE, nil)
  set(next)
end

--- Removes caption index (the selected one by default).
function M.remove(index)
  index = index or lanes.selected(LANE)
  local list = M.list()
  if not index or not list[index] then return end
  lanes.select(LANE, nil)
  table.remove(list, index)
  set(list)
end

-- project.load: a project is being opened. Checks what it saved, and keeps them apart (those
-- saved before captions couldn't overlap show as they did).
function M.load(data)
  local list = {}
  for i, saved in ipairs(data.captions or {}) do
    local where = "captions[" .. (i - 1) .. "]"
    local from, to, words
    if type(saved) == "table" and #saved == 3 then from, to, words = saved[1], saved[2], saved[3] end
    local read = type(from) == "number" and type(to) == "number" and type(words) == "string" and math.abs(from) <= 1e9 and math.abs(to) <= 1e9
    if not read then error(where .. " is not a start, an end and a text.", 0) end
    if from < 0 then error(where .. " starts before the score.", 0) end
    if to <= from then error(where .. " ends before it starts.", 0) end
    list[i] = {from = from, to = to, text = words}
  end
  return M.data(M.separate(list))
end

-- project.used: whether the project has captions.
function M.used()
  return #(curator.data().captions or {}) > 0
end

-- project.replaced: the score is being replaced. Each caption goes where its places are in
-- the new score, cut at its end; one with nothing left of it is lost.
function M.replaced(data, carry, length)
  local list, kept = M.list(data), {}
  for _, c in ipairs(list) do
    local from, to = carry(c.from), carry(c.to) or length
    if from and to > from then kept[#kept + 1] = {from = from, to = to, text = c.text} end
  end
  local lost = #list - #kept
  local said
  if lost == 1 then said = curator.tr("1 caption") elseif lost > 1 then said = curator.tr("{n} captions", {n = lost}) end
  return M.data(M.separate(kept)), said
end

return M
