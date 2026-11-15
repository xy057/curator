# Reopen Last Project

As Curator starts, opens the project or score that was opened last (the first of File ▸ Open
Recent), unless Curator was started with a file.

It adds no command: it listens (`app.on`) to `"app.started"`, which is told once, to the
plugins that are on as Curator starts. Turning it on later does nothing until the next start.
