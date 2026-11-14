-- The Captions sheet (double-click the lane's name): every caption as a row of From, Until
-- and Text, in the order they show. Done applies everything as one Undo step, and a row left
-- without text goes. Import… brings in an SRT or WebVTT file's subtitles as rows (placed in
-- the score by the sync), Export… writes the rows as one, timed as the recording plays them.

local captions = require("captions")
local subtitles = require("subtitles")
local tr = curator.tr

local M = {}

local TYPES = {
  {label = "SubRip", extensions = {"srt"}},
  {label = "WebVTT", extensions = {"vtt"}},
}

-- A row: its cells as typed, the caption it shows (or was drafted as) and where that is
-- among the captions (nil: added here).
local function row(caption, index)
  return {from = score.format(caption.from), to = score.format(caption.to), text = caption.text, caption = caption, index = index}
end

-- A cell still showing its edge as written keeps that edge exactly.
local function place(typed, edge)
  if typed == score.format(edge) then return edge end
  return score.parse(typed)
end

local function start_of(r) return place(r.from, r.caption.from) end
local function end_of(r) return place(r.to, r.caption.to) end

-- What is wrong with each row's bars. Rows can't overlap (one caption shows at a time):
-- sorted by start, one running into the next is flagged.
local function problems(rows)
  local starts, ends, said = {}, {}, {}
  for i, r in ipairs(rows) do
    local a, b = start_of(r), end_of(r)
    starts[i], ends[i] = a, b
    if not a or not b then
      said[i] = tr("Enter a bar or bar.beat, like 12 or 12.3")
    elseif b <= a then
      said[i] = tr("Set Until after From")
    end
  end
  local order = {}
  for i = 1, #rows do
    if not said[i] then order[#order + 1] = i end
  end
  table.sort(order, function(x, y) return starts[x] < starts[y] end)
  for k = 1, #order - 1 do
    local i, j = order[k], order[k + 1]
    if ends[i] > starts[j] + 1e-9 then said[j] = tr("Overlaps the caption in row {n}", {n = i}) end
  end
  -- With each, the cells at fault: a bar that isn't one, an end too soon, or (an overlap) the start.
  local list = {}
  for i = 1, #rows do
    if said[i] then
      local a, b = starts[i], ends[i]
      local problem = {said[i]}
      if not a or (b and b > a) then problem[#problem + 1] = "from" end
      if not b or (a and b <= a) then problem[#problem + 1] = "to" end
      list[i] = problem
    end
  end
  return list
end

-- The rows as captions, those whose bars read.
local function valid(rows)
  local list = {}
  for _, r in ipairs(rows) do
    local a, b = start_of(r), end_of(r)
    if a and b and b > a then list[#list + 1] = {from = a, to = b, text = r.text} end
  end
  return list
end

-- Add: a new row after the last caption (or from the playhead when there is none), its text
-- to type. It fits among the rows as they are here (not the captions as they were).
local function add(sheet)
  local rows = sheet.rows()
  local among = valid(rows)
  for _, c in ipairs(among) do c.text = "" end
  local last = #rows > 0 and end_of(rows[#rows]) or nil
  local draft = last and last < score.quarters() - 1e-9 and captions.draft(last, among) or nil
  draft = draft or captions.draft(score.quarter(editor.playhead()), among)
  if not draft then return sheet.notice(tr("No room for another caption")) end
  sheet.add(row(draft), "text")
end

-- Import…: reads a subtitle file into rows, in place of these or (Add) around them, a
-- subtitle running into a row left out.
local function import(sheet)
  ui.open_file {
    types = TYPES,
    max = subtitles.max_bytes,
    done = function(file)
      if file.too_big then return sheet.notice(tr("This subtitle file is a bit too big.")) end
      if file.error then return sheet.notice(file.error) end
      local ok, read = pcall(function() return subtitles.to_captions(subtitles.parse(file.text)) end)
      if not ok then return sheet.notice(tostring(read)) end
      if #read == 0 then return sheet.notice(tr("None of these subtitles land inside the music.")) end
      local function take(adding)
        local rows = adding and sheet.rows() or {}
        local kept = valid(rows)
        local taken = 0
        for _, c in ipairs(read) do
          if not captions.overlapping(kept, c.from, c.to) then
            rows[#rows + 1] = row(c)
            taken = taken + 1
          end
        end
        table.sort(rows, function(a, b) return (start_of(a) or 0) < (start_of(b) or 0) end)
        sheet.set(rows)
        local left = #read - taken
        if left > 0 then
          sheet.notice(tr("{n} imported, {left} overlapping left out", {n = taken, left = left}))
        else
          sheet.notice(tr("{n} imported", {n = taken}))
        end
      end
      if #sheet.rows() == 0 then return take(false) end
      ui.ask {
        title = tr("Replace the old captions?"),
        buttons = {{id = "add", title = tr("Add")}, {id = "replace", title = tr("Replace")}},
        done = function(id) take(id == "add") end,
      }
    end,
  }
end

-- Export…: writes the rows as SRT or WebVTT (the name chosen says which).
local function export(sheet)
  local list = valid(sheet.rows())
  local title = text.trim((score.title():gsub("[/\\:]", "-")))
  ui.save_file {
    name = (title == "" and tr("Captions") or title) .. ".srt",
    types = TYPES,
    write = function(file)
      return subtitles.write(subtitles.cues(list), file.extension == "vtt" and "vtt" or "srt")
    end,
    done = function(file)
      if file.error then return sheet.notice(file.error) end
      sheet.notice(tr("Exported “{name}”", {name = file.name}))
    end,
  }
end

--- Opens the sheet; focus (an index into the captions) starts on that caption's text.
function M.open(focus)
  local list = captions.list()
  local order = {}
  for i = 1, #list do order[i] = i end
  table.sort(order, function(a, b) return list[a].from < list[b].from end)
  local rows, at = {}, nil
  for k, i in ipairs(order) do
    rows[k] = row(list[i], i)
    if i == focus then at = k end
  end
  ui.sheet {
    title = tr("Captions"),
    width = 640,
    columns = {
      {id = "from", label = tr("From"), width = 88},
      {id = "to", label = tr("Until"), width = 88},
      {id = "text", label = tr("Text"), max = 160, hint = tr("Leave empty to remove")},
    },
    rows = rows,
    focus = at and {at, "text"} or nil,
    empty = tr("No captions"),
    buttons = {
      {id = "add", title = tr("Add"), icon = "add"},
      {id = "import", title = tr("Import…")},
      {id = "export", title = tr("Export…"), enabled = function(sheet) return sheet.valid() and #sheet.rows() > 0 end},
    },
    more = "add",
    press = function(id, sheet)
      if id == "add" then add(sheet) elseif id == "import" then import(sheet) else export(sheet) end
    end,
    check = problems,
    done = function(done)
      -- In the captions' own order (new ones last), so a sheet left as it was changes nothing.
      local kept, added = {}, {}
      for _, r in ipairs(done) do
        if r.index then kept[#kept + 1] = r else added[#added + 1] = r end
      end
      table.sort(kept, function(a, b) return a.index < b.index end)
      local result = {}
      for _, r in ipairs(kept) do result[#result + 1] = {from = start_of(r), to = end_of(r), text = r.text} end
      for _, r in ipairs(added) do result[#result + 1] = {from = start_of(r), to = end_of(r), text = r.text} end
      captions.replace_all(result)
    end,
  }
end

return M
