-- The loop: a passage played round and round while it is on.
--
-- Edge: a plugin hears events, never frames, and has no part in the audio. The loop is
-- turned by a timer (app.after), the finest clock a plugin has: twenty times a second it
-- looks where the playhead is and sends it back. So the loop turns up to a twentieth of a
-- second late, and with a click as the recording starts again. A seamless loop would be the
-- app's own work, not a plugin's.
--
-- Edge: a plugin draws nothing. The loop shows as a tick on its menu item and its toolbar
-- button, and is said at the window's foot; it can't be drawn as a stretch on the timeline.
-- (An extension's lane can do that, in the one project that carries it.)

local places = require("places")
local store = require("store")
local tr = curator.tr

local M = {}

local TICK = 0.05
local on = false
local waiting -- cancels the tick that is waiting, if one is

--- The loop's two ends in seconds, or nil without one. It ends a moment before the piece
--- does: playback stops there, and a stopped piece isn't sent back.
local function ends()
  local range = store.mine().loop
  if not range then return nil end
  local from = math.max(0, score.seconds(range.from) - store.options().preroll)
  local to = math.min(score.seconds(range.to), project.duration() - 0.1)
  if to <= from then return nil end
  return from, to
end

local function tick()
  waiting = nil
  if not on or not project.open() or not project.playing() then return end
  local from, to = ends()
  if from then
    local now = project.time()
    if now >= to or now < from - 0.5 then project.seek(from) end
  end
  waiting = app.after(TICK, tick)
end

--- Starts or stops watching the playhead, as things now are: called when the loop is turned,
--- playback starts or stops, or another project shows.
function M.watch()
  if waiting then
    waiting()
    waiting = nil
  end
  if on and project.open() and project.playing() then
    local from, to = ends()
    -- Started outside the loop, it starts at the loop's beginning.
    if from and (project.time() < from - 0.5 or project.time() >= to) then project.seek(from) end
    waiting = app.after(TICK, tick)
  end
end

function M.on() return on end

function M.range() return project.open() and store.mine().loop or nil end

function M.turn(to)
  on = to and M.range() ~= nil
  M.watch()
end

local function say()
  local range = store.mine().loop
  ui.message(tr("Loop: {from} to {to}", {from = score.format(range.from, true), to = score.format(range.to, true)}))
end

--- Sets the loop to a passage and turns it on.
function M.set(from, to)
  if to <= from then return ui.message(tr("The loop ends before it starts")) end
  store.mine().loop = {from = from, to = to}
  store.keep()
  M.turn(true)
  say()
end

--- The loop from a place: to its old end when that comes later, else to the next mark.
function M.from(at, all)
  local range = store.mine().loop
  local to = range and range.to > at and range.to or nil
  if not to then
    to = score.quarters()
    for _, p in ipairs(all) do
      if p.at > at + 0.01 then to = p.at break end
    end
  end
  M.set(at, to)
end

--- The loop to a place: from its old start when that comes earlier, else from the mark before.
function M.to(at, all)
  local range = store.mine().loop
  local from = range and range.from < at and range.from or nil
  if not from then
    from = 0
    for _, p in ipairs(all) do
      if p.at < at - 0.01 then from = p.at end
    end
  end
  M.set(from, at)
end

--- The loop around a place: from the mark before it to the mark after.
function M.around(at, all)
  local from, to = 0, score.quarters()
  for _, p in ipairs(all) do
    if p.at <= at + 0.01 then from = p.at end
  end
  for _, p in ipairs(all) do
    if p.at > at + 0.01 then to = p.at break end
  end
  M.set(from, to)
end

function M.clear()
  store.mine().loop = nil
  store.keep()
  M.turn(false)
  ui.message(tr("Loop cleared"))
end

return M
