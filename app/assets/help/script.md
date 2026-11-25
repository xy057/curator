# Curating by script

The Instruments tab's Script shows a script in the lanes' place (its button is added to the
tab's bar with View ▸ Customize Toolbar…). A script, in CuraScript, Curator's own language, says when each lane is shown, a statement a line. Run (⌘R) does them all as one Undo
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
- Where lanes share a name, `"Violin"[2]` is the second from the top, as the lanes are when the
  script starts: one moved by it is still the lane it names.
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
- A script can set the Audio tab's anchors too: `align` is its Align. It listens to the recording
  first, which takes a while (the Audio tab's Align shows how far it has got), and then runs.
- A project is kept in CuraScript too: a .ccs is a zip, and its `project.cura` says all of the
  project, a field a line, what is in a field indented under it.

## Macros

A macro does a few statements without writing them. Edit ▸ Macros… puts one together from
choices: what to do, to which lanes, over which bars. It is kept for every project, and can
use what a script can't: the lanes selected, where the playhead is, bars asked for as it runs.
⌃1 to ⌃9 run the first nine (Settings ▸ Shortcuts gives them other keys), and each of those
can have a button of its own on a toolbar, under an icon you give it: the pin beside its name
puts it on the Instruments bar, and View ▸ Customize Toolbar… puts it anywhere, with a menu of
all the macros. A run is one Undo step, as a script's is. A macro runs where what it changes is
showing: steps for lanes in the Instruments tab, steps for the anchors in the Audio tab.

The steps are nodes on a canvas, and a wire from one to the next says what is done after what.
Drag from the circle on a node's right onto another node to wire them, click the dot on a wire
to take it away, and drag a node by its top to put it elsewhere; scroll, or drag the ground, to
move about. Steps with no wire between them don't wait for each other: while a step hears the
recording, which takes a while, the steps not wired after it are done at once, and those wired
after it when it is through (two Undo steps then: what was done at once, and the rest). Set
Anchors As Heard goes by what it is wired after, so it needs a Hear the Recording before it.

The first example is Auto-Curate itself, a step for each thing it does: Show Where Playing
(`follow`: each lane where its part plays, short rests bridged), Hide Least Important (`thin`:
where the staves run off the video's frame, the one that matters least in each phrase hidden,
until they fit), Show Again Where It Fits (`refill`: what was hidden tried back, what matters
most first) and Remove Lone Bars (`remove lone`: a staff left for a single bar goes too). As
they come they do what the button does; show only the strings first, bridge longer rests, thin
in phrases of eight bars or leave a step out, and it is yours. Fit to Frame (`fit`) is the last
three as one step.

The second is the Audio tab's Align: Hear the Recording (`hear`: the notes in it), Set Anchors
As Heard (`match`: the score found in them, the anchors set from it) and Snap Anchors to Notes
(`snap anchors`: each onto a note starting within 0.05 seconds, done while the Audio tab's Snap
to Notes is on, as Align's own is). Align (`align`) is the three as one step.
