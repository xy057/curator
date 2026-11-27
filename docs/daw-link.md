# Attacca

(Attacca was called Curator Link until build 484. Install and Uninstall remove bundles by that
name too. Since build 485 it is a plug-in of its own to a DAW, with IDs of its own: a DAW project
that used Curator Link says it is missing, so put Attacca on that track instead.)

Attacca is an ARA 2 plug-in (VST3, and on macOS an Audio Unit too) that a DAW loads on an audio track. It
reads the DAW's song through ARA, which hands a plug-in the host's model instead of only its
audio, and passes it to Curator: the tempo map, bar and key signatures, the tracks, the
recordings and where each is placed in the song, and the transport while the DAW plays. Curator
can then:

- **follow the DAW's tempo**. The sync takes the tempo map of the song where the recording sits,
  in the same way it follows a MIDI file's. It takes it again whenever the tempo track changes in
  the DAW, so a tempo map made there (Logic's Smart Tempo, Cubase's tempo detection, or one drawn
  by hand) lines the barlines up with the recording;
- **take the recording itself**, written out of the DAW as a file and loaded as the project's;
- **follow the DAW's playhead**. While the DAW plays, the score moves with it and Curator stays
  silent. Where the DAW lets Attacca drive its transport (an ARA playback controller: Cubase,
  Nuendo, Studio One, REAPER), Curator's own drives the DAW's too: play and pause (Space), going
  to a place (a click, the wheel, a drag once let go, Home, Go To) start, stop and move the DAW,
  which plays while Curator stays silent;
- **keep the DAW's tracks as stems**. Each track is written out as the song plays it, over the
  length of the recording followed, and kept apart in the project. Each stem lines up sample for
  sample with the recording, ready for hearing one instrument alone or bringing it forward.

## Installing

Attacca runs on macOS (Apple silicon and Intel) and on Windows 10 and later (x86_64; see
[On Windows](#on-windows) for what differs there). Curator carries it, so there is nothing to
download. On Linux, Settings ▸ General ▸ DAW says Attacca is not available for
the system ("OS not supported"), Listen for Attacca stays off, Curator opens no port, and
File ▸ Attacca reads OS not supported, its Connect Attacca… greyed out. A project's stems are kept
and can be edited there.

Everything Attacca does in Curator is under **File ▸ Attacca**: how it stands, Follow
DAW…, Capture Stems…, and Settings… (Listen for Attacca, Install, Update, Uninstall).

1. **Quit your DAW.** A DAW reads its plug-ins when it starts. (On Windows it must be quit:
   Windows lets nothing replace a plug-in a DAW has loaded, and Curator says **Quit your DAW
   first.**)
2. In Curator, choose **File ▸ Attacca ▸ Settings…** and click **Install** next to
   **Attacca plug-in**. On macOS, Curator puts three files in your own Library. It needs no
   password, and other accounts on the Mac don't get them:

   | File | Where | Used by |
   |---|---|---|
   | `Attacca.vst3` | `~/Library/Audio/Plug-Ins/VST3` | Cubase, Nuendo, Studio One, REAPER and other VST3 hosts |
   | `Attacca Capturer.vst3` | `~/Library/Audio/Plug-Ins/VST3` | the same, for [Attacca Capturer](#attacca-capturer) |
   | `Attacca.component` | `~/Library/Audio/Plug-Ins/Components` | Logic Pro and other Audio Unit hosts (Attacca and Attacca Capturer) |

   On Windows it puts two folders in your own VST3 folder, which needs no administrator, and
   other accounts on the PC don't get them (there is no Audio Unit on Windows):

   | Folder | Where | Used by |
   |---|---|---|
   | `Attacca.vst3` | `%LOCALAPPDATA%\Programs\Common\VST3` | Cubase, Nuendo, Studio One, REAPER and other VST3 hosts |
   | `Attacca Capturer.vst3` | `%LOCALAPPDATA%\Programs\Common\VST3` | the same, for [Attacca Capturer](#attacca-capturer) |

   The row then shows the version installed, for example `630`: Attacca's own
   ([Updating](#updating)), not Curator's.
3. Leave **Listen for Attacca** on, in the same group. It is on unless you turned it off.
4. **Start your DAW.** Most DAWs find a new plug-in on their own. If Attacca isn't listed:
   - **Logic Pro** checks every new Audio Unit when it starts. If the check failed, open
     Logic Pro ▸ Settings ▸ Plug-in Manager, select Attacca, and click
     **Reset & Rescan Selection**.
   - **Cubase / Nuendo**: rescan in Studio ▸ VST Plug-in Manager.
   - **REAPER**: Settings ▸ Plug-ins ▸ VST ▸ **Re-scan**.
   - **Studio One** and other DAWs: rescan their plug-ins, or restart them once more.
   - **On Windows**, a DAW that doesn't look in your own VST3 folder (the VST3 standard's
     place for one user's plug-ins) needs to be told of it: add
     `%LOCALAPPDATA%\Programs\Common\VST3` to its VST3 folders (Studio One: Options ▸
     Locations ▸ VST Plug-ins; REAPER: Settings ▸ Plug-ins ▸ VST), or copy the two folders into
     `C:\Program Files\Common Files\VST3`, which every VST3 host reads (as an administrator).
5. **Check that it works.** Put Attacca on a track ([Using it](#using-it)), then open its
   window in the DAW. It says **Connected to Curator** while Curator is open, and **Waiting for
   Curator** otherwise. In Curator, **File ▸ Attacca** (and its Settings row) then says
   **Connected:** and the DAW's name; else **Not Connected**, or **Not Listening** while Listen for
   Attacca is off.

### Updating

Attacca has a version of its own, a whole number that goes up only when the plug-in itself
changes. An update of Curator that doesn't change Attacca leaves the one installed as it is:
nothing to do, and nothing says it is outdated. When an update does bring a newer Attacca, the
row's button says **Update** instead of **Reinstall**: click it, then restart the DAW, which
keeps the old plug-in loaded until it quits. Until then, the older plug-in still works, and
says it is outdated ([Using it](#using-it)). **Reinstall** puts the same version back, for a
plug-in that was damaged or partly removed.

(An Attacca from before it had its own version, 630, shows Curator's of the time, for example
`0.10.625 (625)`: every one of them is older.)

### Installing by hand

On Windows, `make daw-link-windows` (run on a Mac) leaves them in
`daw_link/build-windows/Attacca.zip`: quit the DAW, unzip it, and copy the folders
`Attacca.vst3` and `Attacca Capturer.vst3` into `%LOCALAPPDATA%\Programs\Common\VST3` (or
`C:\Program Files\Common Files\VST3`). They are not signed.

On macOS, `make daw-link` leaves the plug-ins in `app/assets/daw_link/Attacca.zip`. To install them
without Curator's button (on another Mac, for example), quit the DAW, unzip the file, and copy
`Attacca.vst3` and `Attacca Capturer.vst3` into `~/Library/Audio/Plug-Ins/VST3` and `Attacca.component` into
`~/Library/Audio/Plug-Ins/Components`. The plug-ins have an ad-hoc signature, not Apple's.
macOS may then refuse a copy downloaded with a web browser, which marks it as from the
internet. If it does, clear that mark:

```bash
xattr -dr com.apple.quarantine ~/Library/Audio/Plug-Ins/VST3/"Attacca.vst3" ~/Library/Audio/Plug-Ins/VST3/"Attacca Capturer.vst3" ~/Library/Audio/Plug-Ins/Components/"Attacca.component"
```

## Uninstalling

1. **Quit your DAW.**
2. In Curator, open **Settings ▸ General ▸ DAW** and click **Uninstall** next to
   **Attacca plug-in**. All its plug-ins are removed, and the button reads **Install** again.

   By hand on Windows, delete the two folders `Attacca.vst3` and `Attacca Capturer.vst3` from
   `%LOCALAPPDATA%\Programs\Common\VST3`. On macOS, delete the three files instead (and any named Curator Link):

   ```bash
   rm -rf ~/Library/Audio/Plug-Ins/VST3/"Attacca.vst3" ~/Library/Audio/Plug-Ins/VST3/"Attacca Capturer.vst3" ~/Library/Audio/Plug-Ins/Components/"Attacca.component" \
     ~/Library/Audio/Plug-Ins/VST3/"Curator Link.vst3" ~/Library/Audio/Plug-Ins/Components/"Curator Link.component"
   ```
3. **Start your DAW.** It drops Attacca from its list when it next starts or rescans.
   A DAW project that used it says the plug-in is missing when it opens. Its audio and regions
   are untouched: Attacca keeps nothing in the DAW's project.

What stays behind, and how to remove it:

- **Curator's projects keep what they took.** That includes a tempo map, a recording and
  stems. They are part of each project and don't need the plug-in.
- **Files written for Curator stay in its cache.** Recordings and stems the plug-in wrote are
  in `~/Library/Caches/Curator/DAW Link` (Windows: `%LOCALAPPDATA%\Curator\Cache\DAW Link`). A project saved holds its own copy of what it uses.
  **Settings ▸ General ▸ DAW ▸ Attacca cache** shows how much is there, and **Clear** removes it
  (all but the files a project open now still plays, which go the next time).
- **Curator still listens for the plug-in.** Turn off **Listen for Attacca** to stop it.
  Curator then also removes `daw-link.json`, the file in
  `~/Library/Application Support/Curator` (Windows: `%LOCALAPPDATA%\Curator`) that tells the plug-in where to connect.

## Using it

Attacca supports a DAW by what the DAW gives it through ARA, never by the DAW's name. ARA has a
host hand a plug-in several interfaces. Two of them every ARA host gives (a recording's samples,
and the project's archive); the others it may leave out. Attacca needs two of those:

- **the song** (ARA's content access: the tempo map, bar and key signatures), which the sync
  follows;
- **the transport** (ARA's playback controller), by which Curator's transport drives the DAW's
  and Record from DAW… starts it.

Attacca tells Curator which interfaces the DAW gave it (`interfaces` in `document`), and a DAW
that gives both is supported: **Cubase, Nuendo, Studio One (Studio Pro) and REAPER** do. A DAW
that leaves one out is not: when Attacca is put on a recording there, Curator says the DAW isn't
supported and what it doesn't give, and Connect Attacca… doesn't offer its recordings. Holding
**⌥ (Option; Alt on Windows)** in that notice shows **Connect Anyway**, which offers them all the
same (for this time only): what the DAW does give still works. A DAW without ARA at all (Ableton
Live, Bitwig Studio) can only have Attacca on an insert, with no recording: Connect Attacca…
says Attacca isn't on a recording there. An Attacca from before build 622 doesn't say what the
DAW gives, and its DAW is taken to give everything (Curator says that Attacca is outdated).

1. In the DAW, use it as an ARA plug-in on the track with the recording:
   - **Cubase / Nuendo**: select the audio event, then Audio ▸ Extensions ▸ Attacca.
   - **Studio One, REAPER**: as they add ARA plug-ins (VST3).

   Attacca's VST3 is ARA only (its category says `OnlyARA`), so a DAW that heeds it doesn't
   offer it as an insert. Attacca put in an insert slot all the same (or its Audio Unit, which has
   no such mark) is connected but given no recording: its window says **Insert only** (the instance tells it whether the DAW bound it to ARA: the VST3's
   audio side by a message to its editing side, the Audio Unit by a property of its own), and
   Connect Attacca… says Attacca isn't on a recording in that DAW, and to add it as an ARA extension.
2. In Curator, open the score, then **File ▸ Attacca ▸ Connect Attacca…**. Choose the recording,
   the DAW bar where the score's bar 1 is (an upbeat comes before it), and whether to use the
   recording and follow the playhead.

**Outdated.** A DAW keeps the Attacca it loaded until it opens again, so one updated while
the DAW is open is still the old one there. Attacca's window then says it is outdated and to
reopen the DAW (a newer Attacca is in its bundle on disk), or to update it in Curator's
Settings (the Attacca Curator bundles, by the version in `daw-link.json`, is newer). Curator
says so too, from the version in `hello`: once as the DAW connects, in Connect Attacca…, and as
"(outdated)" beside the DAW in File ▸ Attacca. Both compare Attacca's own version, never
Curator's: a newer Curator with the same Attacca says nothing.

A recording taken from the DAW (**Load ARA Clip**) is the project's Attacca recording: its
take is marked with a link sign, beside its name in its lane, under Recording in the Audio tab
and in Project Info. A project has one for now. Once it has one, Connect Attacca… offers only that
recording, and taking it again puts it back into the same take, whichever take is picked. A
file's recording loaded into that take takes the mark off; removing the take frees the project
for another. Stems captured line up with the Attacca take. While a project has one, Export
Video… and Export to Web… are greyed out: an ARA clip is the recording as it lies, not what the
DAW plays of it. Record from DAW… puts the DAW's mix in its place, and they are back.

**File ▸ Attacca ▸ Capture Stems…** is greyed out for now; what follows is how it works once it
is back. While Curator follows a DAW, it lists the DAW's tracks that
have recordings; every one but the recording's own is picked at first. Each one captured is
converted to FLAC and saved in the project (`media/stems/<id>/`), with the track's name and
colour, the take it lines up with, and the part of the score it plays: found by the track's name
when exactly one part's matches ("Violins 1" is "Violin I"). Capturing a track again replaces its
stem. Project Settings ▸ Project Info ▸ **Stems ▸ Edit…** sets each stem's part, or removes it.

### Attacca Capturer

Attacca reads a recording as the DAW hands it over: the track's own audio, before its inserts,
sends and the mix. To take the recording as you hear it instead, put **Attacca Capturer** (Curator
▸ Attacca Capturer; installed with Attacca: a VST3 of its own, so no DAW offers it as an ARA
extension, and a second Audio Unit in Attacca's component) as an insert, usually in the
last slot of the DAW's output (Stereo Out, the main bus). It passes everything through untouched.

It works together with Attacca on a track, which still tells Curator the song. It is linked to
it in **Attacca's** window: its **Capturer** menu lists the Capturers in the DAW (by the DAW's
channel each is on, "Stereo Out", where the DAW says) and None. The one chosen is linked; the
Capturer stays an ordinary insert, never an ARA instance. The link is kept in the DAW's project
(Attacca's instances keep the Capturer's ID in their state, the Capturer keeps its ID in its
own), so it holds when the project opens again. The Capturer's window says **Linked to Attacca**,
or **Not linked: choose it in Attacca's window**.

Its VST3 has a connection of its own to Curator, so Curator does the linking: it matches the two
by the DAW's process ID (`pid` in `hello`), lists the Capturers to Attacca (`inserts`), hears the
one chosen (`link`), tells the Capturer it is linked (`linked`), and asks the document's Attacca
to have the DAW play and stop.

Connect Attacca… always takes the recording through ARA (**Load ARA Clip**), Capturer or not.
**File ▸ Attacca ▸ Record from DAW…**, while the project follows a DAW, captures the mix over the
span the recording followed plays in the song (its region: the file is as long as the recording,
lined up with it, silent outside the region, and done once the region was heard), and loads it
in place of the project's Attacca take as an ordinary recording: the mix, no longer the DAW's
recording, so no longer marked Attacca (the project still follows the DAW). Curator asks the
DAW to stop first, and the Capturer keeps nothing until the DAW has been stopped and quiet for a
quarter of a second (what still rings from before, a reverb's tail when the DAW last stopped or
what it played before it jumped, would land on the region's first moments, a sound the DAW
itself never plays there from a stop); then it says it is ready (or after a second without being
run, or eight seconds that never fall quiet), and Curator asks the DAW to play from a second
before the region and to stop once every moment of it was heard; a DAW that doesn't let a
plug-in start it (or one that stops early) is played by hand, and the span may be played in pieces or out of order. The progress bar
is how much of it was heard; Cancel stops. So does Curator going (the Capturer lets the capture
go when the connection ends) or the DAW's document closing (Curator cancels it). It captures with the Capturer linked: without one in
the DAW it says to put one on the output, and with none linked to choose it in Attacca's window.

**Listen for Attacca** (Settings ▸ General ▸ DAW, on by default) is the switch for all of
this. The menu item is checked while Curator follows a DAW, and choosing it again stops. So does
choosing another tempo map, editing the one taken, or Convert to Anchors. The tempo map taken is
saved with the project like any other. Following lasts only while the project is open and the
DAW has the recording: closing the DAW's project, quitting the DAW, removing the recording's
track (or Attacca from it), or turning Listen for Attacca off ends it.

## On Windows

Attacca on Windows is the same plug-in, built from the same sources, and Curator does with it
all it does on macOS. What differs:

- **VST3 only.** Windows has no Audio Units: `Attacca.vst3` and `Attacca Capturer.vst3`, each a
  folder holding its program (`Contents\x86_64-win\<name>.vst3`), the licences and Attacca's
  version (`Contents\Resources`). The DAWs Attacca supports all load VST3.
- **x86_64 only.** A DAW built for ARM (Windows on ARM, run natively) doesn't load it. One
  built for x86_64 does, on either processor.
- **Your own VST3 folder.** `%LOCALAPPDATA%\Programs\Common\VST3` is the VST3 standard's
  place for one user's plug-ins, and Curator writes there without an administrator. Not every
  DAW looks there by itself ([Installing](#installing), step 4).
- **Quit the DAW to install, update or uninstall.** Windows keeps a plug-in a DAW has loaded:
  it can't be replaced or removed until the DAW quits, and Curator says **Quit your DAW first.**
  and changes nothing. So a newer Attacca is never on disk under a DAW still running the old
  one, and its window only ever says it is outdated because Curator is newer.
- **A file Curator is playing isn't replaced.** Curator plays a recording from the file the
  plug-in wrote, and Windows lets nothing take an open file's place. A recording asked for again
  (Load ARA Clip, Record from DAW…) is then written by the same name in a folder beside the
  first (`<folder> 2`), and Curator is told that one. Attacca cache ▸ Clear removes the old ones.
- **Its window** is drawn by the plug-in itself (no Cocoa there): the same lines and the
  Capturer menu, in Windows' own font and colours, as many pixels a point as the DAW says its
  screen has.
- **Where things are.** Curator's `daw-link.json` is in `%LOCALAPPDATA%\Curator`, and the files
  the plug-in writes in `%LOCALAPPDATA%\Curator\Cache\DAW Link`, which the plug-in finds as
  Curator does (`%LOCALAPPDATA%`, else `%USERPROFILE%\AppData\Local`). A DAW is named by its
  program without `.exe` ("Cubase15", "reaper").

It has been run only by the DAW in miniature (below), on Wine and, in the Release workflow, on
Windows: never yet in a DAW on Windows.

## What the plug-in does

On a track, an ARA plug-in plays that track's regions itself (it is their *playback renderer*):
the DAW no longer sends their audio through it. Attacca reads each recording into memory
once the DAW allows it, and plays the regions from there. It plays them at their own speed and
does not time-stretch, and it tells the DAW so. Changing the DAW's tempo doesn't stretch the
audio. If the sample rates differ, it resamples linearly. A recording longer than three hours of
stereo at 48 kHz isn't held, and that region plays silence.

Its window shows whether Curator is connected, and if not, why: Curator isn't open, isn't
listening (Listen for Attacca is off), or is still connecting. While connected, it names
the Curator projects following this DAW. The plug-in stores nothing in the DAW's
project, because everything it knows the DAW sends again.

## How Curator and the plug-in talk

- **Finding Curator.** Curator listens on the loopback address (127.0.0.1) at a port the system
  picks. It writes the port, a random token and the version of the Attacca it bundles (`build`) to `daw-link.json` in its data
  folder (`~/Library/Application Support/Curator`; Windows: `%LOCALAPPDATA%\Curator`) and removes the file when it quits. The plug-in
  reads that file every second until it can connect. A plug-in that starts before Curator
  therefore connects as soon as Curator is up. The file also names Curator's process (`pid`): one
  left behind by a Curator that is gone (it crashed) is not followed, since its port may be
  another program's by then.
- **One line per message.** Each message is a JSON object on its own line, in both directions.
  The plug-in's first message is `hello`, carrying the token. Curator closes any connection
  whose first message doesn't carry it, so nothing else that reaches the port is heard.
- **One connection per bundle in a DAW process.** All of that bundle's documents and instances
  share it: Attacca's (its VST3, or the component with both Audio Units), and Attacca Capturer's
  VST3 apart. Curator matches a DAW's connections by `pid`.

| Message | From | Holds |
|---|---|---|
| `hello` | plug-in | `token`, `protocol` (1), `build` (Attacca's version), `host` (the DAW process's name), `pid` |
| `document` | plug-in | `id` (new each time the DAW opens the project), `name`; `contexts` (each with `tempo`: `[seconds, quarters]` pairs, `bars`: `[numerator, denominator, quarter]`, `keys`, `chords`), `tracks` (`name`, `color`, `order`, `context`), `sources` (`id`: the recording's persistent ID, `name`, `rate`, `frames`, `channels`, `access`), `regions` (`track`, `source`, `start` and `length` in the song, `from` and `span` in the recording); `playback`: whether the DAW lets Attacca drive its transport; `interfaces`: the ARA host interfaces the DAW gave Attacca, of `audio`, `archiving` (every host gives both), `content` (the song), `updates`, `playback` (the transport): Curator supports a DAW that gives `content` and `playback` (`DawDocument.needed`) |
| `closed` | plug-in | `id`: the document has gone, said as the DAW closes it (`destroyDocumentController`), even while an instance keeps Attacca's side of it a while; nothing more is asked of the DAW for it |
| `transport` | plug-in | `playing`, `seconds` and `quarters` from the song's start, `tempo`; at most 30 a second, and only when something changed |
| `followers` | Curator | `names`: the projects following one of this DAW's documents, one a line (empty: none); sent when they change, and on connecting |
| `export` | Curator | `document`, `source`: write this recording as a file |
| `stem` | Curator | `document`, `track`, `from` and `length` (seconds of the song): write the track as the song plays it there |
| `progress` | plug-in | `document`, `source` or `track`, `done` (0–1) |
| `exported` | plug-in | `document`, `source`, then `path` (a 32-bit float WAV in Curator's cache folder, under `DAW Link/`) or `error` |
| `stemmed` | plug-in | `document`, `track`, then `path` (a 32-bit float WAV under `DAW Link/Stems/`) or `error` (`empty`: nothing plays there) |
| `capturers` | plug-in | `list`: each Attacca Capturer in the bundle (`id`, kept in its state; `name`, the DAW's channel it is on, if said; `channels`, `rate`); sent when one comes, goes or is set up, and on connecting |
| `link` | plug-in | `capturer`: the Capturer linked to this DAW's Attacca (chosen in its window, kept in its instances' state; empty: none); sent when chosen or restored, and on connecting |
| `inserts` | Curator | `ids`, `names` (one a line): the Capturers in the same DAW process, for Attacca's Capturer menu |
| `capture` | Curator | `document`, `capturer`, `from` and `length` (seconds of the song), `name`: keep what the Capturer hears there (sent on the Capturer's connection); `start` and `end` (optional): the song time the DAW plays of it, the only part to be heard, the rest of the file silence (Record from DAW…: the whole recording's length, lined up with it, and its region) |
| `play` | Curator | `document`, `at` (song seconds, optional): the document's Attacca asks the DAW to play (from `at`, no earlier than 0) the next time the DAW asks it for updates (`notifyModelUpdates`, on the DAW's model thread, where it closes documents too: a DAW that waits there for what it is asked can't be waited on by a document closing), as it asks for `stop` and `seek`, in the order they came: Curator's play while following, or a capture starting (a second before its span) |
| `stop` | Curator | `document`: the DAW asked to stop (Curator's pause; a capture starting, before it is `ready`; a capture done, failed or cancelled) |
| `seek` | Curator | `document`, `at`: the DAW asked to go there (Curator's playhead moved while following; at most one every 60 ms, the last where it ended) |
| `linked` | Curator | `ids` (one a line): to a connection with Capturers, those linked to an Attacca with a document in the same DAW process |
| `cancel` | Curator | `document`, `capturer`: the capture under way ends (`captured` with `error`: `cancelled`) |
| `ready` | plug-in | `document`, `capturer`: a capture asked for listens now, the DAW stopped and fallen quiet (what it heard before is dropped); Curator asks the DAW to play then |
| `captured` | plug-in | `document`, `capturer`, then `path` (a 32-bit float WAV under `DAW Link/Captures/`, `name`.wav) once every frame was heard, or `error` (`empty`, `too long`, `unwritable`, `cancelled`); `progress` with `capturer` before it says how much was heard |

A stem has the most channels and the highest sample rate of the recordings on its track. Each
region plays in it as it plays in the song, unstretched; one of another layout is averaged into
every channel. The files are written one at a time, after the recordings they need are read.

The plug-in sends a document after every edit the DAW makes, but only when something differs.
A recording's samples let be read (`access`) outside an edit are told when the DAW next asks the
plug-in for its updates.
It also sends every document again whenever it connects. Times are in seconds and positions in
quarter notes, both measured from the start of the song. Between two tempo entries the tempo is
constant; before the first entry and after the last, it is the tempo of the nearest stretch (as
ARA defines it). Bar 1 is the barline at quarter 0, or else the first barline after it.

Fields are only added over time. A message type or field that one side doesn't know is ignored.
`protocol` is raised only when one side could no longer read the other.

`build`, in `hello` and in `daw-link.json`, is Attacca's version, named for what it was: until
630 Attacca had Curator's build for its version. Its own began there, so every plug-in and
every Curator from before compares as older without either side knowing of the change.

## Building and checking it

`make daw-link` does three things:

1. **Fetches the SDKs** into `daw_link/third_party/` (not in git), at the tags pinned in the
   Makefile:
   - Celemony's ARA SDK 2.3.0 (Apache 2.0)
   - Steinberg's VST3 SDK 3.8.0 (MIT)
   - Apple's AudioUnitSDK 1.4.0 (Apache 2.0)
2. **Builds the plug-in** as a universal binary, ad-hoc signed, with its own version
   ([Its version](#its-version)). `daw_link/CMakeLists.txt` compiles the SDKs' sources directly and runs
   none of their build scripts.
3. **Runs `daw_link/test/link_host`**, a DAW in miniature, before zipping the bundles into
   `app/assets/daw_link/Attacca.zip`. That is the zip Settings installs from, and
   `make run` and `make build` make it whenever it is out of date. The test host:
   - stands in for Curator, behind a temporary `HOME` (Windows: `LOCALAPPDATA`);
   - loads the VST3, makes a document with a tempo change, 4/4 then 3/4, a key, a track and a
     recording placed in the song; and one as a DAW giving only what ARA requires of every host,
     which must say so;
   - checks what Curator is told;
   - asks for the recording, and checks the file sample by sample; asks again while it holds
     the first open, and checks the second is whole (on Windows, beside the first);
   - asks for the track as a stem from before its region, and checks the silence, then the
     region where the song plays it;
   - plays the region through the plug-in, and checks it sample by sample against the song;
   - opens the VST3's window in a view of its own and closes it;
   - then registers the Audio Unit in its own process only, makes its window and checks its
     playback the same way.

The SDKs' licences are in `app/assets/daw_link/LICENSES.txt`, with the notices of what the
Windows build links in with them (`-static`): the LLVM Project's C++ library and runtime and the
MinGW-w64 runtime, as llvm-mingw comes with them (`LICENSE.TXT`; the runtime's
`x86_64-w64-mingw32/share/mingw32/COPYING.MinGW-w64-runtime.txt`, which asks for it): read them
again when llvm-mingw is updated. That file is shown under Settings ▸ About ▸ Licenses and
copied into each bundle.

**For Windows**, `make daw-link-windows` builds the same sources on a Mac, for x86_64:

1. It fetches the ARA and VST3 SDKs as above, and **llvm-mingw** (Clang, LLD and mingw-w64:
   a compiler that makes Windows programs on a Mac) into `daw_link/third_party/`, the release
   pinned in the Makefile, its download checked against the SHA-256 pinned beside it.
2. It builds the two VST3 bundles and `link_host.exe` in `daw_link/build-windows/`. The C++
   library is linked into each DLL, so they need nothing but Windows' own libraries (no Visual
   C++ runtime) where a DAW loads them.
3. It zips the bundles into `daw_link/build-windows/Attacca.zip`. `link_host.exe` runs on
   Windows (`link_host.exe <path>\Attacca.vst3 "<path>\Attacca Capturer.vst3"`), or on a Mac
   under Wine: the same checks as on macOS, without the Audio Unit's, with the window put in a
   window never shown and made half as big again as a DAW on a denser screen does.

The Release workflow does this in a job of its own (`attacca-windows`, on a Mac), and its
Windows job runs `link_host.exe` on Windows, then puts the zip in the app as
`assets/daw_link/Attacca.zip` before building it. Each system's app carries its own Attacca.

### Its version

Attacca's version is `attaccaVersion` in `app/lib/attacca_version.dart`: a whole number apart
from Curator's version and build. The Makefile reads it from there for the plug-in (its
bundles' version, the VST3 classes', ARA's, `build` in `hello`; an Audio Unit's version is 1,
then the number over its last two bytes), and Curator compares it with what a DAW's Attacca
says and with the one installed.

**Raise it by one with every change to the plug-in** (`daw_link/CMakeLists.txt`,
`daw_link/src`, `daw_link/mac`), then run `make attacca-seal`, which writes down what those
sources are (`daw_link/sources.sha256`, one SHA-256 of them all). `make versions` (from
`make check`, and the Release workflow's first step) fails while they are anything else, so a
changed Attacca can't go out under the version DAWs already have, where nothing would tell
them it is outdated. A change that touches none of those files (Curator's own, the test host)
leaves the version alone, and every Attacca installed stays current.

macOS and Windows are built (`AttaccaPlugIns.supported`); the plug-in's sources say what
differs between them in `link_system.cpp` (Curator's folders, the process), `link_socket.h`
(sockets) and the window (`mac/link_view.mm`, `win/link_view.cpp`). Linux isn't: the protocol
and Curator's side don't depend on the system.
