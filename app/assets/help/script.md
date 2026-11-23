# Curating by script

The Instruments tab's Script (the code button on its bar) shows a script in the lanes' place. A
script says when each lane is shown, a statement a line. Run (⌘R) does them all as one Undo
step, and what they do is what the tab's tools do: `show` is Draw, `hide` is Erase, `auto` is
Auto-Curate. What is wrong with a script is listed under it with its line, and then nothing
is changed.

```
# The strings open; the winds come in at B.
let winds = "Flute*", "Oboe*", "Clarinet in B♭"
clear
show "Violin I", "Violin II", "Viola" 1-16
show winds from mark B
hide "Viola" 9.3-12
show "Piano" 17-24 transition in 0.5 without staff 2
```

From Lanes writes the lanes as they are as a script that makes them again: somewhere to start
from, and a way to take one project's lanes to another. The script is kept with the project.

## Lanes

- A lane is called by its name in quotes, as the lane shows it: `"Flute 1"`. Capitals and
  spaces don't matter, and `*` stands for anything: `"Violin*"`.
- Several are separated by commas; `all` is every lane; `except` leaves some out:
  `all except "Piano", "Harp"`.
- Where lanes share a name, `"Violin"[2]` is the second from the top.
- `"Piano"/1` is the lane of a staff, once the instrument is split (`split "Piano"`).
- `let strings = "Violin*", "Viola"` names lanes; the name is written without quotes after it.

## Ranges

- `5` is bar 5 and `1-8` bars 1 through 8, as the ruler numbers them. `5.3` is a beat, and
  `3.2-8.4` runs from beat 2 of bar 3 through beat 4 of bar 8.
- `from 9` runs to the end, `until 17` from the start up to bar 17, `from 9.3 until 17` between.
- After `from` and `until` a place is a bar (`9`), a beat (`9.3`), part of the way through a
  beat (`9.3.50`: half), quarter notes from the start (`@32.5`), `start`, `end`, or a rehearsal
  mark (`mark B`).
- Several are separated by commas: `1-8, 17-24`. Without a range, it is the whole piece.

## Good to know

- `#` starts a comment. The language's words read in any case.
- A statement that names a lane or a bar there isn't stops the script before it changes
  anything.
- Statements run in order, each on what the one before left: `clear` first starts from nothing.

## Macros

A macro does a few statements without writing them. Edit ▸ Macros… puts one together from
choices: what to do, to which lanes, over which bars. It is kept for every project, and can
use what a script can't: the lanes selected, where the playhead is, bars asked for as it runs.
The Macros menu on the Instruments bar runs one, and ⌃1 to ⌃9 run the first nine. A run is one
Undo step, as a script's is.
