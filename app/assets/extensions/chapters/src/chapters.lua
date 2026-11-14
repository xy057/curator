-- Chapters: named places in the score, each running to the next.
--
-- The project keeps them as {chapters = {{at, name}, ...}}: at is where one starts, in
-- quarter notes from the start of the score. They are kept in the score's order, one to a
-- place, each with a name.

local M = {}

M.max_name = 80 -- the longest name a chapter keeps
M.apart = 0.25 -- the least two chapters are apart, in quarters

--- The chapters, in the score's order: each {at, name}.
function M.list()
  return curator.data().chapters or {}
end

--- list as it is kept: in the score's order, names tidied (one without a name goes), one
--- to a place (of two at one place, the later in the list stays).
function M.tidy(list)
  local by_place, places = {}, {}
  for _, chapter in ipairs(list) do
    local at, name = chapter[1], text.squeeze(chapter[2])
    if name ~= "" and at >= 0 and at < math.huge then
      -- To the millionth of a quarter.
      local place = math.round(at * 1e6)
      if not by_place[place] then places[#places + 1] = place end
      -- (+ 0.0: a place is saved as a fraction, 4.0.)
      by_place[place] = {at + 0.0, #name > M.max_name and name:sub(1, M.max_name) or name}
    end
  end
  table.sort(places)
  local tidied = {}
  for i, place in ipairs(places) do tidied[i] = by_place[place] end
  return tidied
end

local function same(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i][1] ~= b[i][1] or a[i][2] ~= b[i][2] then return false end
  end
  return true
end

-- Keeps list (tidied) as the chapters: one Undo step, or nothing when they are those already.
local function set(list)
  local tidied = M.tidy(list)
  if same(tidied, M.list()) then return end
  curator.data().chapters = tidied
  curator.save("Chapters")
end

local function copy(list)
  local out = {}
  for i, chapter in ipairs(list) do out[i] = chapter end
  return out
end

-- at inside the score: never at its very end.
local function within(at)
  return math.min(math.max(at, 0.0), math.max(0.0, score.quarters() - M.apart))
end

--- The chapter starting at a place (its index), but for the one at index except.
function M.starting_at(at, except)
  for i, chapter in ipairs(M.list()) do
    if i ~= except and math.abs(chapter[1] - at) < 1e-6 then return i end
  end
end

--- Adds a chapter (in place of one starting where it does). Returns its index.
function M.add(at, name)
  if text.trim(name) == "" then return end
  at = within(at)
  local list = copy(M.list())
  list[#list + 1] = {at, name}
  set(list)
  return M.starting_at(at)
end

--- Changes chapter index. Returns where it is now, or nil when nothing changed.
function M.update(index, at, name)
  local list = copy(M.list())
  local old = list[index]
  if not old then return end
  at = within(at)
  if old[1] == at and old[2] == name then return end
  -- Last, so it is the one that stays where another starts.
  table.remove(list, index)
  list[#list + 1] = {at, name}
  set(list)
  return M.starting_at(at)
end

--- Removes chapter index.
function M.remove(index)
  local list = copy(M.list())
  if not list[index] then return end
  table.remove(list, index)
  set(list)
end

--- The score's rehearsal marks as chapters, each from its bar.
function M.marks()
  local marks, list = score.rehearsal_marks(), {}
  -- Backwards: the first of two in one bar stays, as the bar numbers' row shows it.
  for i = #marks, 1, -1 do list[#list + 1] = {marks[i].at, marks[i].text} end
  return M.tidy(list)
end

--- The rehearsal marks no chapter starts at yet.
function M.new_marks()
  local new = {}
  for _, mark in ipairs(M.marks()) do
    if not M.starting_at(mark[1]) then new[#new + 1] = mark end
  end
  return new
end

--- Adds a chapter at every rehearsal mark where none starts.
function M.add_marks()
  local new = M.new_marks()
  if #new == 0 then return end
  local list = copy(M.list())
  for _, mark in ipairs(new) do list[#list + 1] = mark end
  set(list)
end

-- project.load: a project is being opened. Checks what it saved, and tidies it.
function M.load(data)
  local list = {}
  for i, chapter in ipairs(data.chapters or {}) do
    local at, name
    if type(chapter) == "table" and #chapter == 2 then at, name = chapter[1], chapter[2] end
    if type(at) ~= "number" or type(name) ~= "string" or not (math.abs(at) <= 1e9) then
      error("chapters[" .. (i - 1) .. "] is not a place and a name.", 0)
    end
    if at < 0 then error("chapters[" .. (i - 1) .. "] starts before the score.", 0) end
    list[i] = {at, name}
  end
  return {chapters = M.tidy(list)}
end

-- project.used: whether the project has chapters.
function M.used()
  return #M.list() > 0
end

-- project.replaced: the score is being replaced. Each chapter goes where its place is in the
-- new score; one past its end is lost.
function M.replaced(data, carry)
  local list, kept = data.chapters or {}, {}
  for _, chapter in ipairs(list) do
    local at = carry(chapter[1])
    if at then kept[#kept + 1] = {at, chapter[2]} end
  end
  local lost = #list - #kept
  local said
  if lost == 1 then said = curator.tr("1 chapter") elseif lost > 1 then said = curator.tr("{n} chapters", {n = lost}) end
  return {chapters = M.tidy(kept)}, said
end

return M
