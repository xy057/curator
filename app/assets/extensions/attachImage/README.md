# Attach Image

Images that scroll with the score, and spacers that make room for them.

- `images.lua`: where each picture is, and the rules they are kept by.

The app keeps each image's file in the project, draws it, and gives it its handles and menu
(the `images` socket). Spacers are the app's own; the `spacers` socket turns them on.
