-- The band along the top of the score: each key area in its key's colour, named by the user's
-- marking or else the key's name.

local areas = require("areas")
local keys = require("keys")

local M = {}

--- What an area is called: the user's marking, else its key's name in the interface's language.
function M.label(area)
  return area.label or keys.label(area.tonic, area.minor)
end

-- band.areas: the band's stretches.
function M.areas()
  local band = {}
  for i, a in ipairs(areas.list()) do
    band[i] = {from = a.from, to = a.to, color = keys.color(a.tonic, a.minor), label = M.label(a)}
  end
  return band
end

return M
