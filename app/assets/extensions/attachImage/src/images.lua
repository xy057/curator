-- Attach Image: pictures on the score that scroll with it.
--
-- The project keeps them as {patches = {{image, quarter, top, width, height, crop, ink}, ...}},
-- bottom to top: image is the file's name, quarter where its left edge is (in quarter notes
-- from the start of the score), top, width and height in staff spaces, crop the part of the
-- image shown as {left, top, right, bottom} (each 0-1; left out: all of it), ink whether it is
-- drawn in the score's ink (left out: its own colours).
--
-- The app has the files, draws them and gives each picture its handles; what it hands over
-- and asks for is a picture: {image, at, top, width, height, crop = {left, top, right, bottom}, ink}.

local M = {}

M.default_height = 12 -- a new picture's height, in staff spaces
M.max_width = 40 -- and the widest it comes in

--- A patch as it is saved: its keys in this order. (+ 0.0: a place is saved as a fraction, 4.0.)
local function patch(image, quarter, top, width, height, crop, ink)
  local p = {image = image, quarter = quarter + 0.0, top = top + 0.0, width = width + 0.0, height = height + 0.0}
  if crop and not (crop[1] == 0 and crop[2] == 0 and crop[3] == 1 and crop[4] == 1) then
    p.crop = {crop[1] + 0.0, crop[2] + 0.0, crop[3] + 0.0, crop[4] + 0.0}
  end
  if ink then p.ink = true end
  return p
end

--- The patches of data (the project's own by default).
local function patches(data)
  return (data or curator.data()).patches or {}
end

--- Patches as data to save.
local function data(list)
  return {patches = curator.list(list)}
end

local function save(list)
  curator.data().patches = curator.list(list)
  curator.save("Images")
end

local function copy(list)
  local out = {}
  for i, p in ipairs(list) do out[i] = p end
  return out
end

--- images.list: the pictures, bottom to top.
function M.list()
  local list = {}
  for i, p in ipairs(patches()) do
    local c = p.crop
    list[i] = {
      image = p.image, at = p.quarter, top = p.top, width = p.width, height = p.height,
      crop = c and {left = c[1], top = c[2], right = c[3], bottom = c[4]}, ink = p.ink == true,
    }
  end
  return list
end

--- images.add: a new image, its top-left corner at a quarter and so many staff spaces down.
--- It comes in default_height high, or lower when that would make it wider than max_width.
function M.add(image, at, top, aspect)
  local height = math.min(M.default_height, M.max_width / aspect)
  local list = copy(patches())
  list[#list + 1] = patch(image, at, top, height * aspect, height)
  save(list)
  return #list
end

--- images.change: a picture as it is after a move, a resize, a crop or its ink switched.
function M.change(index, picture)
  local list = copy(patches())
  local was = list[index]
  if not was then return end
  local c = picture.crop
  list[index] = patch(was.image, picture.at, picture.top, picture.width, picture.height, c and {c.left, c.top, c.right, c.bottom}, picture.ink)
  save(list)
end

--- images.remove: these pictures go.
function M.remove(indexes)
  local gone, kept = {}, {}
  for _, i in ipairs(indexes) do gone[i] = true end
  for i, p in ipairs(patches()) do
    if not gone[i] then kept[#kept + 1] = p end
  end
  save(kept)
end

--- images.without: data without the pictures showing these image files.
function M.without(saved, images)
  local gone, kept = {}, {}
  for _, image in ipairs(images) do gone[image] = true end
  for _, p in ipairs(patches(saved)) do
    if not gone[p.image] then kept[#kept + 1] = p end
  end
  if #kept == #patches(saved) then return saved end
  return data(kept)
end

local function number(saved, key, where)
  local v = saved[key]
  if type(v) ~= "number" then error(where .. "." .. key .. " is not a number.", 0) end
  if not (math.abs(v) <= 1e9) then error(where .. "." .. key .. " is out of range.", 0) end
  return v
end

local function size(saved, key, where)
  local v = number(saved, key, where)
  if not (v > 0) then error(where .. "." .. key .. " is not a size.", 0) end
  return v
end

--- project.load: the saved patches, checked. (The app has checked each one's image file.)
function M.load(saved)
  local list = {}
  for i, p in ipairs(saved.patches or {}) do
    local where = "patches[" .. (i - 1) .. "]"
    local crop = p.crop
    if crop ~= nil and #crop > 0 then
      local l, t, r, b = crop[1], crop[2], crop[3], crop[4]
      local part = #crop == 4 and type(l) == "number" and type(t) == "number" and type(r) == "number" and type(b) == "number"
        and 0 <= l and l < r and r <= 1 and 0 <= t and t < b and b <= 1
      if not part then error(where .. ".crop is not a part of the image.", 0) end
    else
      crop = nil
    end
    local quarter, top = number(p, "quarter", where), number(p, "top", where)
    local width, height = size(p, "width", where), size(p, "height", where)
    if p.ink ~= nil and type(p.ink) ~= "boolean" then error(where .. ".ink is not true or false.", 0) end
    list[i] = patch(p.image, quarter, top, width, height, crop, p.ink)
  end
  return data(list)
end

--- project.used: whether the project has pictures.
function M.used()
  return #patches() > 0
end

--- project.replaced: the score is being replaced. Each picture goes where its place is in the
--- new score; one whose place is gone is lost.
function M.replaced(saved, carry)
  local all, kept = patches(saved), {}
  for _, p in ipairs(all) do
    local at = carry(p.quarter)
    if at then kept[#kept + 1] = patch(p.image, at, p.top, p.width, p.height, p.crop, p.ink) end
  end
  local lost = #all - #kept
  local said
  if lost == 1 then said = curator.tr("1 image") elseif lost > 1 then said = curator.tr("{n} images", {n = lost}) end
  return data(kept), said
end

return M
