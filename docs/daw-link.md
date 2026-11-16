# Curator Link

Curator Link is an ARA 2 plug-in (VST3 and Audio Unit) that a DAW loads on an audio track. It
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
  silent;
- **keep the DAW's tracks as stems**. Each track is written out as the song plays it, over the
  length of the recording followed, and kept apart in the project. Each stem lines up sample for
  sample with the recording, ready for hearing one instrument alone or bringing it forward.

## Installing

Curator Link runs on macOS (Apple silicon and Intel). Curator carries it, so there is nothing to
download. On Windows and Linux, Settings ▸ General ▸ DAW says Curator Link is not available for
the system ("OS not supported"), Listen for Curator Link stays off, Curator opens no port, and
File ▸ Curator Link reads OS not supported, its Follow DAW… greyed out. A project's stems are kept
and can be edited there.

Everything Curator Link does in Curator is under **File ▸ Curator Link**: how it stands, Follow
DAW…, Capture Stems…, and Settings… (Listen for Curator Link, Install, Update, Uninstall).

1. **Quit your DAW.** A DAW reads its plug-ins when it starts.
2. In Curator, choose **File ▸ Curator Link ▸ Settings…** and click **Install** next to
   **Curator Link plug-in**. Curator puts two files in your own Library. It needs no password,
   and other accounts on the Mac don't get them:

   | File | Where | Used by |
   |---|---|---|
   | `Curator Link.vst3` | `~/Library/Audio/Plug-Ins/VST3` | Cubase, Nuendo, Studio One, REAPER and other VST3 hosts |
   | `Curator Link.component` | `~/Library/Audio/Plug-Ins/Components` | Logic Pro and other Audio Unit hosts |

   The row then shows the version installed, for example `0.9.0 (471)`.
3. Leave **Listen for Curator Link** on, in the same group. It is on unless you turned it off.
4. **Start your DAW.** Most DAWs find a new plug-in on their own. If Curator Link isn't listed:
   - **Logic Pro** checks every new Audio Unit when it starts. If the check failed, open
     Logic Pro ▸ Settings ▸ Plug-in Manager, select Curator Link, and click
     **Reset & Rescan Selection**.
   - **Cubase / Nuendo**: rescan in Studio ▸ VST Plug-in Manager.
   - **REAPER**: Settings ▸ Plug-ins ▸ VST ▸ **Re-scan**.
   - **Studio One** and other DAWs: rescan their plug-ins, or restart them once more.
5. **Check that it works.** Put Curator Link on a track ([Using it](#using-it)), then open its
   window in the DAW. It says **Connected to Curator** while Curator is open, and **Waiting for
   Curator** otherwise. In Curator, **File ▸ Curator Link** (and its Settings row) then says
   **Connected:** and the DAW's name; else **Not Connected**, or **Not Listening** while Listen for
   Curator Link is off.

### Updating

After Curator is updated, the row says **Update** instead of the version: click it, then
restart the DAW, which keeps the old plug-in loaded until it quits. Until then, a plug-in from
an older Curator still works. **Reinstall** puts the same version back, for a plug-in that was
damaged or partly removed.

### Installing by hand

`make daw-link` leaves both plug-ins in `app/assets/daw_link/CuratorLink.zip`. To install them
without Curator's button (on another Mac, for example), quit the DAW, unzip the file, and copy
`Curator Link.vst3` into `~/Library/Audio/Plug-Ins/VST3` and `Curator Link.component` into
`~/Library/Audio/Plug-Ins/Components`. The plug-ins have an ad-hoc signature, not Apple's.
macOS may then refuse a copy downloaded with a web browser, which marks it as from the
internet. If it does, clear that mark:

```bash
xattr -dr com.apple.quarantine ~/Library/Audio/Plug-Ins/VST3/"Curator Link.vst3" ~/Library/Audio/Plug-Ins/Components/"Curator Link.component"
```

## Uninstalling

1. **Quit your DAW.**
2. In Curator, open **Settings ▸ General ▸ DAW** and click **Uninstall** next to
   **Curator Link plug-in**. Both plug-ins are removed, and the button reads **Install** again.

   By hand, delete the two files instead:

   ```bash
   rm -rf ~/Library/Audio/Plug-Ins/VST3/"Curator Link.vst3" ~/Library/Audio/Plug-Ins/Components/"Curator Link.component"
   ```
3. **Start your DAW.** It drops Curator Link from its list when it next starts or rescans.
   A DAW project that used it says the plug-in is missing when it opens. Its audio and regions
   are untouched: Curator Link keeps nothing in the DAW's project.

What stays behind, and how to remove it:

- **Curator's projects keep what they took.** That includes a tempo map, a recording and
  stems. They are part of each project and don't need the plug-in.
- **Files written for Curator stay in its cache.** Recordings and stems the plug-in wrote are
  in `~/Library/Caches/Curator/DAW Link`. Curator has copied what it uses into its projects,
  so the folder can be deleted.
- **Curator still listens for the plug-in.** Turn off **Listen for Curator Link** to stop it.
  Curator then also removes `daw-link.json`, the file in
  `~/Library/Application Support/Curator` that tells the plug-in where to connect.

## Using it

1. In the DAW, use it as an ARA plug-in on the track with the recording:
   - **Cubase / Nuendo**: select the audio event, then Audio ▸ Extensions ▸ Curator Link.
   - **Logic Pro**: insert Curator Link (Audio Units ▸ Curator) on the track. Logic hands ARA
     plug-ins the regions on the track.
   - **Studio One, REAPER** and other ARA hosts: as they add ARA plug-ins
     (VST3).
2. In Curator, open the score, then **File ▸ Curator Link ▸ Follow DAW…**. Choose the recording,
   the DAW bar where the score's bar 1 is (an upbeat comes before it), and whether to use the
   recording and follow the playhead.

While Curator follows a DAW, **File ▸ Curator Link ▸ Capture Stems…** lists the DAW's tracks that
have recordings; every one but the recording's own is picked at first. Each one captured is
converted to FLAC and saved in the project (`media/stems/<id>/`), with the track's name and
colour, the take it lines up with, and the part of the score it plays: found by the track's name
when exactly one part's matches ("Violins 1" is "Violin I"). Capturing a track again replaces its
stem. Project Settings ▸ Project Info ▸ **Stems ▸ Edit…** sets each stem's part, or removes it.

**Listen for Curator Link** (Settings ▸ General ▸ DAW, on by default) is the switch for all of
this. The menu item is checked while Curator follows a DAW, and choosing it again stops. So does
choosing another tempo map, editing the one taken, or Convert to Anchors. The tempo map taken is
saved with the project like any other. Following lasts only while the project is open.

## What the plug-in does

On a track, an ARA plug-in plays that track's regions itself (it is their *playback renderer*):
the DAW no longer sends their audio through it. Curator Link reads each recording into memory
once the DAW allows it, and plays the regions from there. It plays them at their own speed and
does not time-stretch, and it tells the DAW so. Changing the DAW's tempo doesn't stretch the
audio. If the sample rates differ, it resamples linearly. A recording longer than three hours of
stereo at 48 kHz isn't held, and that region plays silence.

Its window shows only whether Curator is connected. The plug-in stores nothing in the DAW's
project, because everything it knows the DAW sends again.

## How Curator and the plug-in talk

- **Finding Curator.** Curator listens on the loopback address (127.0.0.1) at a port the system
  picks. It writes the port and a random token to `daw-link.json` in its data folder
  (`~/Library/Application Support/Curator`) and removes the file when it quits. The plug-in
  reads that file every second until it can connect. A plug-in that starts before Curator
  therefore connects as soon as Curator is up.
- **One line per message.** Each message is a JSON object on its own line, in both directions.
  The plug-in's first message is `hello`, carrying the token. Curator closes any connection
  whose first message doesn't carry it, so nothing else that reaches the port is heard.
- **One connection per DAW process.** All of that process's documents and plug-in instances
  share it.

| Message | From | Holds |
|---|---|---|
| `hello` | plug-in | `token`, `protocol` (1), `plugin` (its version), `build`, `host` (the DAW process's name), `pid` |
| `document` | plug-in | `id` (new each time the DAW opens the project), `name`; `contexts` (each with `tempo`: `[seconds, quarters]` pairs, `bars`: `[numerator, denominator, quarter]`, `keys`, `chords`), `tracks` (`name`, `color`, `order`, `context`), `sources` (`id`: the recording's persistent ID, `name`, `rate`, `frames`, `channels`, `access`), `regions` (`track`, `source`, `start` and `length` in the song, `from` and `span` in the recording) |
| `closed` | plug-in | `id`: the document has gone |
| `transport` | plug-in | `playing`, `seconds` and `quarters` from the song's start, `tempo`; at most 30 a second, and only when something changed |
| `export` | Curator | `document`, `source`: write this recording as a file |
| `stem` | Curator | `document`, `track`, `from` and `length` (seconds of the song): write the track as the song plays it there |
| `progress` | plug-in | `document`, `source` or `track`, `done` (0–1) |
| `exported` | plug-in | `document`, `source`, then `path` (a 32-bit float WAV in Curator's cache folder, under `DAW Link/`) or `error` |
| `stemmed` | plug-in | `document`, `track`, then `path` (a 32-bit float WAV under `DAW Link/Stems/`) or `error` (`empty`: nothing plays there) |

A stem has the most channels and the highest sample rate of the recordings on its track. Each
region plays in it as it plays in the song, unstretched; one of another layout is averaged into
every channel. The files are written one at a time, after the recordings they need are read.

The plug-in sends a document after every edit the DAW makes, but only when something differs.
It also sends every document again whenever it connects. Times are in seconds and positions in
quarter notes, both measured from the start of the song. Between two tempo entries the tempo is
constant; before the first entry and after the last, it is the tempo of the nearest stretch (as
ARA defines it). Bar 1 is the barline at quarter 0, or else the first barline after it.

Fields are only added over time. A message type or field that one side doesn't know is ignored.
`protocol` is raised only when one side could no longer read the other.

## Building and checking it

`make daw-link` does three things:

1. **Fetches the SDKs** into `daw_link/third_party/` (not in git), at the tags pinned in the
   Makefile:
   - Celemony's ARA SDK 2.3.0 (Apache 2.0)
   - Steinberg's VST3 SDK 3.8.0 (MIT)
   - Apple's AudioUnitSDK 1.4.0 (Apache 2.0)
2. **Builds the plug-in** as a universal binary, ad-hoc signed, with the version from
   `app/pubspec.yaml`. `daw_link/CMakeLists.txt` compiles the SDKs' sources directly and runs
   none of their build scripts.
3. **Runs `daw_link/test/link_host`**, a DAW in miniature, before zipping both bundles into
   `app/assets/daw_link/CuratorLink.zip`. That is the zip Settings installs from, and
   `make run` and `make build` make it whenever it is out of date. The test host:
   - stands in for Curator, behind a temporary `HOME`;
   - loads the VST3, makes a document with a tempo change, 4/4 then 3/4, a key, a track and a
     recording placed in the song;
   - checks what Curator is told;
   - asks for the recording, and checks the file sample by sample;
   - asks for the track as a stem from before its region, and checks the silence, then the
     region where the song plays it;
   - plays the region through the plug-in, and checks it sample by sample against the song;
   - opens the VST3's window in a view of its own and closes it;
   - then registers the Audio Unit in its own process only, makes its window and checks its
     playback the same way.

The SDKs' licences are in `app/assets/daw_link/LICENSES.txt`. That file is shown under Settings
▸ About ▸ Licenses and copied into each bundle.

Only macOS is built so far (`CuratorLinkPlugIns.supported`). The protocol and Curator's side don't depend on
the system.
