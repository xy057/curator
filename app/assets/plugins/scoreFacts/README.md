# Score Facts

Adds **View ▸ Score Facts…** (⇧⌘I, and a button on the editor's toolbar): the number of bars,
parts, staves and rehearsal marks in the score showing, and how long it plays. Copy puts them
on the clipboard.

It is the smallest whole plugin: one `app.command` with a `menu`, a `key`, `toolbar`, an
`enabled` function and a `run` that reads the score (`score`, `project`) and shows a dialog
(`ui.ask`). Its texts are translated with `curator.tr`.
