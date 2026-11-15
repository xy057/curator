-- Reopen Last Project: as Curator starts, opens the file at the top of File ▸ Open Recent,
-- unless something is open already (a file Curator was started with).

app.on("app.started", function()
  local last = app.recent()[1]
  if last and #app.tabs() == 0 then
    app.open(last)
  end
end)
