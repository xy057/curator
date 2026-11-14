-- What a video and a web page get of the chapters.

local chapters = require("chapters")

local M = {}

-- export.chapters: the chapters of a video or page showing from–to seconds of the
-- performance, timed from its start. They cover it whole, as players expect: the one under
-- way at from starts with the video, and music before the first chapter is one named Start.
-- None when no chapter sounds in it.
function M.chapters(from, to)
  local list, places = chapters.list(), {}
  for i, chapter in ipairs(list) do places[i] = chapter[1] end
  local spans, any = {}, false
  for _, span in ipairs(score.spans(places, to)) do
    if span.to > from + 1e-6 and span.from < to - 1e-6 then
      spans[#spans + 1] = span
      any = any or span.index > 0
    end
  end
  if not any then return {} end
  local cues = {}
  for i, span in ipairs(spans) do
    cues[i] = {
      from = math.max(span.from, from) - from,
      to = math.min(span.to, to) - from,
      name = span.index > 0 and list[span.index][2] or curator.tr("Start"),
    }
  end
  return cues
end

return M
