-- Places in the score, and how they are said: a bar, a time on the clock, a name.
-- Places are in quarter notes from the start of the score, as everywhere in Curator's Lua.

local M = {}

--- Seconds as a clock: 1:05, or 1:02:05 past the hour.
function M.clock(seconds)
  local whole = math.floor(seconds + 0.5)
  local h, m, s = math.floor(whole / 3600), math.floor(whole % 3600 / 60), whole % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

--- The number of the bar a place is in.
function M.bar(at)
  local number = score.bar_at(at)
  return number
end

--- The start of the beat a place is in: where a click on the score, or a playhead between
--- beats, is taken to mean.
function M.beat(at)
  local start = score.beat_at(at)
  return start
end

--- Where the playhead is.
function M.playhead()
  return score.quarter(project.time())
end

--- Moves the playhead to a place, or `early` seconds before it.
-- Edge: where the music repeats, a place is played more than once. score.seconds gives its
-- first time through (a second argument asks for another pass); Navigator keeps to the first.
function M.go(at, early)
  project.seek(math.max(0, score.seconds(at) - (early or 0)))
end

--- The score's rehearsal marks as places: {at, name}.
function M.marks()
  local list = {}
  for _, mark in ipairs(score.rehearsal_marks()) do
    local name = text.trim(text.squeeze(mark.text))
    if name ~= "" then list[#list + 1] = {at = mark.at, name = name} end
  end
  return list
end

--- Every place there is to go to, in score order: the rehearsal marks and the bookmarks.
function M.all(bookmarks)
  local list = M.marks()
  for _, b in ipairs(bookmarks) do
    list[#list + 1] = {at = b.at, name = b.name, bookmark = true}
  end
  table.sort(list, function(a, b) return a.at < b.at end)
  return list
end

--- A place as a menu or a list names it: "Coda · bar 41".
-- (Put together here, so a bookmark someone named "Bars" is never taken for a text of the
-- interface and translated.)
function M.label(place)
  return curator.tr("{name} · bar {n}", {name = place.name, n = M.bar(place.at)})
end

return M
