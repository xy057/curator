# Save Before Export

Saves the project before **Export Video…** and **Export to Web…**, when it has a file and
changes not yet saved.

It adds nothing: it changes two of the app's own commands with `app.wrap`. The function it
gives is called in the command's place and is handed `original`, which does what the app does;
a plugin that didn't call it would stop the command.
