# Navigator

A **Go** menu for getting around a score while it is curated.

- **Next Mark** (⌘]), **Previous Mark** (⌘[) and **Go to Place…** (⌘J) move through the
  rehearsal marks and your bookmarks.
- **Bookmarks**: Add Bookmark… (⌘B, or a right-click on the score), Edit Bookmarks… (a table,
  with Import… and Export…). They are kept for each project.
- **Loop**: Loop Playback (⌘L, and a button on the toolbar) plays a passage round and round:
  the one between the marks around the playhead, or from and to wherever you say.
- **Copy Timestamps** puts `1:05 Coda` lines on the clipboard, for a video's description;
  **Export Cue Sheet…** saves them as text, CSV or Markdown.
- **Rehearsal Marks** lists the score's own.
- **Continue Last Project** on Home, and the playhead goes back to where it was left.

Settings… in its menu in Settings ▸ Plugins has its options.

## As an example

Navigator is the largest of Curator's own plugins, and shows how far one reaches:

- `src/main.lua` adds every command (a new menu, menus inside it, keys, a toolbar button, a
  Home button, items of the score's menu, lists kept up as commands are added and removed),
  listens to what happens, wraps one of the app's own commands, and shows its settings.
- `src/places.lua`, `src/store.lua`, `src/loop.lua`, `src/bookmarks.lua` and `src/cues.lua` are
  modules it requires: reading the score, keeping settings, a timer, a form, a table to edit,
  files read and written, the clipboard.

It also shows where a plugin ends. Each place the code meets an end is a comment that starts
with `Edge:`. The loop is turned by a timer, a twentieth of a second at a time, and is not
drawn on the timeline; bookmarks are kept by the app under the project's path, not in the
project; the marks are read again when a project is saved, not as its score is edited.
