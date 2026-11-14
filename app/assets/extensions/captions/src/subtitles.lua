-- Subtitle files, SubRip (.srt) and WebVTT (.vtt), read and written; captions as the
-- subtitles of a performance, and subtitles as captions.
--
-- A cue is {from, to, text}: seconds, and a text in captions' markup (*italic*, **bold**).
-- A cue's lines are joined by spaces, as a caption wraps on its own.

local captions = require("captions")
local tr = curator.tr

local M = {}

M.max_bytes = 8 * 1024 * 1024 -- the largest file read: an hour of dense subtitles is some 100 KB

-- A time, with its hours ("01:02:03,456") or without ("02:03.456", as WebVTT may).
local LONG, SHORT = "%d+:%d%d?:%d%d[.,]%d%d?%d?", "%d%d?:%d%d[.,]%d%d?%d?"
local TIMINGS = {}
for _, first in ipairs({LONG, SHORT}) do
  for _, second in ipairs({LONG, SHORT}) do
    TIMINGS[#TIMINGS + 1] = "^ ?(" .. first .. ") ?%-%-> ?(" .. second .. ")"
  end
end

-- The two times of a timing line ("00:01,000 --> 00:02,500"); nothing for another line.
local function timing(line)
  local flat = text.flatten(line) -- every run of spaces one space
  for _, pattern in ipairs(TIMINGS) do
    local first, second = flat:match(pattern)
    if first then return first, second end
  end
end

-- "01:02:03,456", "02:03.456": seconds.
local function seconds(time)
  local total = 0.0
  for part in (time:gsub(",", ".")):gmatch("[^:]+") do
    total = total * 60 + tonumber(part)
  end
  return total
end

local NAMED = {amp = "&", lt = "<", gt = ">", nbsp = utf8.char(0xA0), quot = '"', apos = "'"}

-- The character a number names; the replacement character for none (past U+10FFFF).
local function character(code)
  if code and code <= 0x10FFFF then return utf8.char(code) end
  return utf8.char(0xFFFD)
end

-- HTML entities read: &amp; &#233; &#xE9;
local function entities(s)
  return (s:gsub("&(#?[0-9a-zA-Z]+);", function(name)
    if NAMED[name] then return NAMED[name] end
    local decimal = name:match("^#([0-9]+)$")
    if decimal then return character(#decimal <= 15 and tonumber(decimal) or nil) end
    local hex = name:match("^#x([0-9a-fA-F]+)$")
    if hex then return character(#hex <= 12 and tonumber(hex, 16) or nil) end
    return nil
  end))
end

local function is_marker(s)
  return s == "*" or s == "**"
end

-- A cue's text with its tags turned into markup: <i> and <b> become stars (a star typed in it
-- stays a star), other tags (voices, classes, colours, karaoke times, {\an8}) go. Spaces just
-- inside a tag move outside its marker (markup opens before a letter and closes after one),
-- and a tag around nothing goes.
local function from_tags(s)
  local parts = {} -- plain text, "*" or "**"
  local open = {["*"] = false, ["**"] = false}

  local function mark(marker, opening)
    if open[marker] == opening then return end -- nested or stray: already so
    open[marker] = opening
    if not opening then
      if parts[#parts] == marker then
        parts[#parts] = nil -- around nothing
        return
      end
      -- Its spaces after it.
      local last = parts[#parts] or ""
      local trimmed = text.trim_end(last)
      if not is_marker(last) and #trimmed < #last then
        parts[#parts] = trimmed
        parts[#parts + 1] = marker
        parts[#parts + 1] = last:sub(#trimmed + 1)
        return
      end
    end
    parts[#parts + 1] = marker
  end

  local function plain(raw)
    local words = (entities(raw):gsub("%*", "\\*"))
    -- Spaces after an opener go before it.
    local last = parts[#parts]
    if is_marker(last) and open[last] then
      local trimmed = text.trim_start(words)
      if #trimmed < #words then
        table.insert(parts, #parts, words:sub(1, #words - #trimmed))
        words = trimmed
      end
    end
    if words ~= "" then parts[#parts + 1] = words end
  end

  local i, n = 1, #s
  while i <= n do
    local ch = s:sub(i, i)
    if ch == "<" then
      local close = s:find(">", i + 1, true)
      if close then
        local slash, tag = s:match("^<(/?)([a-zA-Z]+)", i)
        if tag then
          tag = tag:lower()
          if tag == "i" or tag == "em" then mark("*", slash == "") end
          if tag == "b" or tag == "strong" then mark("**", slash == "") end
        end
        i = close + 1
      else
        plain("<")
        i = i + 1
      end
    elseif ch == "{" then
      local close = s:sub(i + 1, i + 1) == "\\" and s:find("}", i + 2, true)
      if close then
        i = close + 1
      else
        plain("{")
        i = i + 1
      end
    else
      local stop = s:find("[<{]", i) or n + 1
      plain(s:sub(i, stop - 1))
      i = stop
    end
  end
  return text.flatten(table.concat(parts))
end

--- The cues of an SRT or WebVTT file, in order, either way it is written. Blocks without a
--- timing (WebVTT's header, NOTE, STYLE, REGION; an SRT's stray lines) are passed over. An
--- error when no cue is left.
function M.parse(source)
  local mark = utf8.char(0xFEFF)
  local at = source:find(mark, 1, true)
  if at then source = source:sub(1, at - 1) .. source:sub(at + #mark) end
  local lines = text.lines(source)
  local cues = {}
  local i = 1
  while i <= #lines do
    local first, second = timing(lines[i])
    if first then
      local from, to = seconds(first), seconds(second)
      local said = {}
      while i + 1 <= #lines and text.trim(lines[i + 1]) ~= "" do
        i = i + 1
        said[#said + 1] = text.trim(lines[i])
      end
      local words = text.trim(from_tags(table.concat(said, " ")))
      if to > from and words ~= "" then cues[#cues + 1] = {from = from, to = to, text = words} end
    end
    i = i + 1
  end
  if #cues == 0 then error(tr("No subtitles found in this file."), 0) end
  return cues
end

-- A text's markup as tags; escape: &, < and > as entities (WebVTT needs them; SRT players
-- mostly show them as typed).
local function to_tags(s, escape)
  local out = {}
  local italic, bold = false, false
  for _, run in ipairs(text.runs(s)) do
    -- Closed and opened again around each run, so tags never cross.
    if bold and not run.bold then out[#out + 1] = "</b>" end
    if italic and not run.italic then out[#out + 1] = "</i>" end
    if run.italic and not italic then out[#out + 1] = "<i>" end
    if run.bold and not bold then out[#out + 1] = "<b>" end
    italic, bold = run.italic, run.bold
    local words = run.text
    if escape then words = words:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;") end
    out[#out + 1] = words
  end
  if bold then out[#out + 1] = "</b>" end
  if italic then out[#out + 1] = "</i>" end
  return table.concat(out)
end

--- cues as a file in a format ("srt" or "vtt"): numbered (SRT) or under its header (WebVTT),
--- markup as <i> and <b>.
function M.write(cues, format)
  local srt = format ~= "vtt"
  local function time(at)
    local ms = math.round(math.max(0.0, at) * 1000)
    return string.format("%02d:%02d:%02d%s%03d", ms // 3600000, ms // 60000 % 60, ms // 1000 % 60, srt and "," or ".", ms % 1000)
  end
  local out = {srt and "" or "WEBVTT\n\n"}
  for i, cue in ipairs(cues) do
    if srt then out[#out + 1] = i .. "\n" end
    out[#out + 1] = time(cue.from) .. " --> " .. time(cue.to) .. "\n" .. to_tags(cue.text, not srt) .. "\n\n"
  end
  return table.concat(out)
end

-- The captions in time: each as often as its music sounds, in order, {caption, from, to} in
-- seconds. Should two meet, the earlier ends where the later starts.
local function spans(list)
  local passes = score.passes()
  local found = {}
  for i, c in ipairs(list) do
    if text.trim(c.text) ~= "" then
      for k, pass in ipairs(passes) do
        local low, high = math.max(c.from, pass.from), math.min(c.to, pass.to)
        if high - low > 1e-9 then
          found[#found + 1] = {caption = i, from = score.seconds(low, k), to = score.seconds(high, k)}
        end
      end
    end
  end
  table.sort(found, function(a, b)
    if a.from ~= b.from then return a.from < b.from end
    return a.caption < b.caption
  end)
  local apart = {}
  for i, s in ipairs(found) do
    local after = found[i + 1]
    if after and after.from < s.to then
      apart[i] = {caption = s.caption, from = s.from, to = math.max(s.from, after.from)}
    else
      apart[i] = s
    end
  end
  return apart
end

--- The captions of list as subtitles of the performance: each time its music sounds, those
--- between from and to seconds (clipped to them), timed from from.
function M.cues(list, from, to)
  from = from or 0.0
  local cues = {}
  for _, s in ipairs(spans(list)) do
    if s.to > from + 1e-6 and (not to or s.from < to - 1e-6) then
      cues[#cues + 1] = {
        from = math.max(s.from, from) - from,
        to = (to and math.min(s.to, to) or s.to) - from,
        text = list[s.caption].text,
      }
    end
  end
  return cues
end

--- cues as captions, each placed in the score where its music is: a cue heard again on a
--- repeat gives the same caption, made once. Cues outside the music go, and those left are
--- kept apart.
function M.to_captions(cues)
  local total = score.quarters()
  -- Rounded so a repeat's copy matches its first time to the millionth of a quarter.
  local function rounded(q) return math.round(q * 1e6) / 1e6 end
  local seen, list = {}, {}
  for _, cue in ipairs(cues) do
    local a = math.clamp(score.quarter(cue.from), 0.0, total)
    local b = math.clamp(score.quarter(cue.to), 0.0, total)
    if b - a > 1e-3 then
      local from, to = rounded(a), rounded(b)
      seen[from] = seen[from] or {}
      seen[from][to] = seen[from][to] or {}
      if not seen[from][to][cue.text] then
        seen[from][to][cue.text] = true
        list[#list + 1] = {from = from, to = to, text = cue.text}
      end
    end
  end
  return captions.separate(list)
end

-- export.subtitles: the subtitles of a video showing from–to seconds, as a SubRip file.
function M.export(from, to)
  local list = captions.list()
  if #list == 0 then return nil end
  return M.write(M.cues(list, from, to), "srt")
end

return M
