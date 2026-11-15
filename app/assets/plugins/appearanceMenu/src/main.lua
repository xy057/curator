-- Appearance Menu: View ▸ Appearance, with Light, Dark and System, the one in use ticked.
-- A menu inside a menu is written with a slash; a command is ticked while `checked` says so.

local themes = { {"light", "Light"}, {"dark", "Dark"}, {"system", "System"} }

for _, theme in ipairs(themes) do
  local value, title = theme[1], theme[2]
  app.command{
    id = "appearance." .. value,
    title = title,
    menu = "View/Appearance",
    checked = function() return app.setting("theme") == value end,
    run = function() app.setting("theme", value) end,
  }
end
