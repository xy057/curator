# Chapters

Named places in the score, each running to the next. A video carries them for its player,
with a list of their times beside it; a web page lists them to jump to.

- `src/chapters.lua` keeps the chapters: adding, changing and removing them, the score's
  rehearsal marks as chapters, and what happens to them when a project is opened or its
  score replaced.
- `src/lane.lua` is the Chapters lane: its items, its tools, the buttons on its name and the
  dialog that names a chapter.
- `src/export.lua` gives a video and a web page their chapters.

The project keeps `{"chapters": [[at, name], …]}`: `at` in quarter notes from the start of
the score.
