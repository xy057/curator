-- Score Facts: what the score showing is made of. One command, in the View menu, with a key
-- and a button on the editor's toolbar; it shows a dialog whose button copies what it says.

local function clock(seconds)
  local whole = math.floor(seconds + 0.5)
  return string.format("%d:%02d", math.floor(whole / 60), whole % 60)
end

-- The facts, a line each, under the project's name.
local function facts()
  local parts, staves = score.parts(), 0
  for _, part in ipairs(parts) do
    staves = staves + part.staves
  end
  return table.concat({
    project.name(),
    "",
    curator.tr("Bars: {n}", {n = #score.bars()}),
    curator.tr("Parts: {n}", {n = #parts}),
    curator.tr("Staves: {n}", {n = staves}),
    curator.tr("Rehearsal marks: {n}", {n = #score.rehearsal_marks()}),
    curator.tr("Length: {time}", {time = clock(project.duration())}),
  }, "\n")
end

app.command{
  id = "scoreFacts",
  title = "Score Facts…",
  menu = "View",
  key = "cmd+shift+i",
  toolbar = true,
  icon = "score",
  -- Only while a score shows: on Home the menu item is grey.
  enabled = function() return score.open() end,
  run = function()
    local text = facts()
    ui.ask{
      title = "Score Facts",
      text = text,
      buttons = { {id = "copy", title = "Copy"} },
      done = function() app.copy(text) end,
    }
  end,
}
