-- How captions look in every project: their font, countdown, size, alignment and backing.
-- A project may choose a font of its own (Project Settings ▸ Engraving).

local tr = curator.tr

local M = {}

local CHOICES = {
  countdown = {line = true, ring = true, none = true},
  size = {small = true, medium = true, large = true},
  align = {left = true, center = true, right = true},
}

--- The settings as they are kept, what is missing or unknown as it is at first.
function M.get()
  local saved = curator.settings()
  local function one_of(key, default)
    local value = saved[key]
    return CHOICES[key][value] and value or default
  end
  return {
    font = type(saved.font) == "string" and saved.font or "", -- "": the score's text font
    countdown = one_of("countdown", "line"),
    size = one_of("size", "medium"),
    align = one_of("align", "center"),
    plate = saved.plate == true,
  }
end

local function style_of(settings)
  return {
    font = settings.font ~= "" and settings.font or nil,
    countdown = settings.countdown,
    size = settings.size,
    align = settings.align,
    plate = settings.plate,
  }
end

-- captions.style: as the scene draws them.
function M.style()
  return style_of(M.get())
end

-- settings.form: the settings, with a caption drawn as they make it.
function M.form()
  local now = M.get()
  return {
    rows = {
      {id = "font", label = tr("Font"), type = "font", value = now.font, none = tr("Score text")},
      {
        id = "countdown", label = tr("Countdown"), type = "segments", value = now.countdown,
        options = {{value = "line", label = tr("Line")}, {value = "ring", label = tr("Ring")}, {value = "none", label = tr("None")}},
      },
      {
        id = "size", label = tr("Size"), type = "segments", value = now.size,
        options = {{value = "small", label = "S"}, {value = "medium", label = "M"}, {value = "large", label = "L"}}, -- sizes, as on a label: not words
      },
      {
        id = "align", label = tr("Align"), type = "segments", value = now.align,
        options = {{value = "left", label = tr("Left")}, {value = "center", label = tr("Center")}, {value = "right", label = tr("Right")}},
      },
      {id = "plate", label = tr("Backing"), type = "switch", value = now.plate},
    },
    preview = function(values)
      return {caption = tr("The *horns* answer, softly"), style = style_of(values)}
    end,
    changed = function(values)
      curator.save_settings(values)
    end,
  }
end

return M
