-- The Captions lane: what it shows and what its tools do, the dialog that asks for a
-- caption's text and bars, and the items of the preview's menu.
--
-- A caption is dragged between its neighbours (it never goes over one). Drawing one asks for
-- its text; double-click one for its text and bars, or the lane's name for the sheet.

local captions = require("captions")
local tr = curator.tr

local M = {}

-- lane.items (and captions.list): every caption, its text as its label.
function M.items()
  local items = {}
  for i, c in ipairs(captions.list()) do
    items[i] = {from = c.from, to = c.to, label = c.text}
  end
  return items
end

-- A caption's text and bars: caption index, or a new one when index is nil.
local function ask(index, caption)
  local from_shown, to_shown = score.format(caption.from), score.format(caption.to)
  -- A field as shown is the caption's own edge, not its rounding.
  local function place(typed, shown, edge)
    if typed == shown then return edge end
    return score.parse(typed)
  end
  ui.form {
    title = index and tr("Caption") or tr("Add Caption"),
    confirm = index and tr("Apply") or tr("Add"),
    width = 400,
    spacing = 16,
    rows = {
      {id = "text", label = tr("Text"), value = caption.text, hint = "*italic*  **bold**", focus = true, max = 160},
      {
        {id = "from", label = tr("From"), value = from_shown},
        {id = "to", label = tr("Until"), value = to_shown},
      },
    },
    leading = index and {{id = "remove", title = tr("Remove")}} or nil,
    check = function(values)
      local from, to = place(values.from, from_shown, caption.from), place(values.to, to_shown, caption.to)
      if not from or not to then return tr("Enter a bar or bar.beat, like 12 or 12.3") end
      if to <= from then return tr("Set Until after From") end
      if captions.overlapping(captions.list(), from, to, index) then return tr("Overlaps another caption") end
      if not index and text.trim(values.text) == "" then return "" end
    end,
    done = function(values, button)
      if button == "remove" then return captions.remove(index) end
      local result = {
        from = place(values.from, from_shown, caption.from),
        to = place(values.to, to_shown, caption.to),
        text = values.text,
      }
      if index then captions.update(index, result) else captions.add(result) end
    end,
  }
end

-- lane.draw: the Draw tool was dragged across bars. Asks for the text.
function M.draw(from, to)
  ask(nil, {from = from, to = to, text = ""})
end

-- lane.open, captions.open, Edit Caption…: a caption was double-clicked, in the lane or
-- where it shows.
function M.open(index)
  local caption = captions.list()[index]
  if caption then ask(index, caption) end
end

-- The captions as a drag found them: an erase's pieces are of these.
local before = {}

-- lane.begin: a drag begins.
function M.begin()
  before = captions.list()
end

-- lane.change: a caption is being moved or trimmed.
function M.change(index, from, to)
  local caption = captions.list()[index]
  if caption then captions.update(index, {from = from, to = to, text = caption.text}) end
end

-- lane.cut: the Erase tool went over captions. Every caption as it is left, each a piece of
-- one of those the drag found.
function M.cut(pieces)
  local list = {}
  for _, piece in ipairs(pieces) do
    local of = before[piece.of]
    if of then list[#list + 1] = {from = piece.from, to = piece.to, text = of.text} end
  end
  captions.replace_all(list)
end

-- lane.remove, Remove Caption: Delete with a caption selected, or the menu of the one showing.
function M.remove(index)
  captions.remove(index)
end

-- Add Caption…: a caption from the place clicked in the preview.
function M.add_at(quarter)
  local draft = captions.draft(quarter)
  if draft then ask(nil, draft) end
end

-- No room: the captions there run on to the end.
function M.can_add_at(quarter)
  return captions.draft(quarter) ~= nil
end

return M
