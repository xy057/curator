<!-- Made by app/tool/script_docs.dart (make script-docs): edit app/assets/help/script.md and LaneScriptApi instead. -->
# Curating by script

The Instruments tab's Script shows a script in the lanes' place (its button is added to the
tab's bar with View ▸ Customize Toolbar…). A script says when each lane is shown, a statement a line. Run (⌘R) does them all as one Undo
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

## Macros

A macro does a few statements without writing them. Edit ▸ Macros… puts one together from
choices: what to do, to which lanes, over which bars. It is kept for every project, and can
use what a script can't: the lanes selected, where the playhead is, bars asked for as it runs.
⌃1 to ⌃9 run the first nine, and each of those can have a button of its own on a toolbar,
under an icon you give it: the pin beside its name puts it on the Instruments bar, and View ▸
Customize Toolbar… puts it anywhere, with a menu of all the macros. A run is one Undo step, as
a script's is. A macro runs where what it changes is showing: steps for lanes in the Instruments
tab, steps for the anchors in the Audio tab.

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

## Statements

- `show <lanes> [<ranges>] [transition …] [without staff <n>]`: Shows the lanes over the ranges, as Draw does: joined with what it touches. Without a range, throughout. `transition 0.5` gives the stretch its own transition at both ends, `transition in 0.5 out 1` at each; `without staff 2` leaves a staff of the instrument out there.

```
show "Flute 1", "Oboe 1" 1-8, 17-24
```

- `hide <lanes> [<ranges>]`: Hides the lanes over the ranges, as Erase does: regions there are trimmed, split or removed.

```
hide "Violin II" from 33
```

- `only <lanes> [<ranges>]`: Shows the lanes over the ranges and hides every other lane there.

```
only "Piano" 9-16
```

- `clear [<lanes>]`: Empties the lanes; without any, every lane.

```
clear
```

- `auto [<lanes>]`: Auto-Curate: fills the lanes (every lane without any) from where each instrument plays, cut back to fit the frame (`follow`, then `fit`).

```
auto "Violin*"
```

- `follow [<lanes>] [<ranges>] [bridge <bars>]`: Auto-Curate’s first half: each lane (every lane without any) is shown where its instrument plays and hidden where it rests, over the ranges (without one, throughout). `bridge 1` keeps it through a rest of up to that many bars between two runs. A lane that plays nothing stays as it is.

```
follow "Violin*" bridge 1
```

- `fit [<lanes>] [phrase <bars>]`: Auto-Curate’s second half: hides of the lanes (every lane without any) what the frame has no room for; the other lanes stay as they are. It is `thin`, `refill` and `remove lone`, one after another. `follow all bridge 1` and then `fit` is what `auto` does.

```
fit
```

- `thin [<lanes>] [phrase <bars>]`: The first step of `fit`: where the staves would run off the frame, hides the lane that matters least there, a phrase (4 bars, or as given) at a time, until they fit. What it hides is remembered until the script ends, for `refill` and `remove lone`.

```
thin phrase 8
```

- `refill [<lanes>]`: The second step of `fit`: shows again what `thin` hid wherever the frame holds it now, what matters most first, a phrase and else a bar at a time. Nothing where the staves still run off.

```
refill
```

- `remove lone [in <lanes>]`: The third step of `fit`: a lane left showing for a single bar, next to bars `thin` hid of it, is hidden there too.

```
remove lone
```

- `align`: The Audio tab’s Align: sets the anchors from the recording, heard against the score, in place of those there. It is `hear`, `match` and, where the Audio tab’s Snap to Notes is on, `snap anchors`.

```
align
```

- `hear`: The first step of `align`: listens to the recording for the notes in it. It takes a while and changes nothing; what is heard is kept until the script ends, for `match`.

```
hear
```

- `match`: The second step of `align`: finds the score in what `hear` heard (through its repeats: the warps set by hand, or with none the score’s own) and sets the anchors from it, in place of those there.

```
match
```

- `snap anchors [within <seconds>]`: The third step of `align`: moves each anchor onto the nearest note heard starting, within 0.05 seconds of it or as given.

```
snap anchors within 0.08
```

- `bridge rests <bars> [in <lanes>]`: Tidy’s Bridge Rests: joins regions with at most that many bars between them.

```
bridge rests 2
```

- `remove short <bars> [in <lanes>]`: Tidy’s Remove Regions Shorter Than: takes out regions shorter than that many bars.

```
remove short 1 in "Timpani"
```

- `copy <lane> to <lanes>`: Copy Lane To: the lanes get that lane’s regions in place of their own.

```
copy "Violin I" to "Violin II", "Viola"
```

- `split <lanes>`: Split Lane: an instrument on several staves gets a lane a staff, named "Piano"/1, "Piano"/2.

```
split "Piano"
```

- `join <lanes>`: Join Lanes: a split instrument has one lane again.

```
join "Piano"
```

- `move <lanes> to top | to bottom | before <lane> | after <lane>`: Moves the lanes, and their staves in the score, together.

```
move "Harp" before "Violin I"
```

- `restore order`: Restore Score Order: the lanes as the score has them.

```
restore order
```

- `transition <seconds>`: The project’s transition: how long a staff takes to come and go.

```
transition 0.3
```

- `transition <lanes> [<ranges>] [in <seconds>] [out <seconds>]`: The regions’ own transitions, at every start (`in`) and end (`out`) inside the ranges; `default` for seconds gives the project’s back.

```
transition "Flute 1" 9-16 in 1 out default
```

- `let <name> = <lanes>`: Names lanes, for the statements after it.

```
let strings = "Violin*", "Viola", "Cello"
```
