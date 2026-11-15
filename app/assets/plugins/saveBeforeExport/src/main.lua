-- Save Before Export: Export Video… and Export to Web… save the project first, when it has a
-- file and changes not saved. It changes two of the app's own commands by wrapping them: the
-- function is called in the command's place, however it is chosen (its menu, its key, the
-- toolbar), and calls original() to go on with what the app does.

local function saving(original)
  if project.path() and project.edited() then
    app.run("save")
  end
  original()
end

app.wrap("exportVideo", saving)
app.wrap("exportWeb", saving)
