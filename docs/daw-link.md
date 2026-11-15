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

## Setting it up

1. Settings ▸ General ▸ DAW ▸ **Curator Link plug-in ▸ Install** puts `Curator Link.vst3` in
   `~/Library/Audio/Plug-Ins/VST3` and `Curator Link.component` in `…/Components`. After an
   update, **Update** appears there.
2. In the DAW, use it as an ARA plug-in on the track with the recording:
   - **Cubase / Nuendo**: select the audio event, then Audio ▸ Extensions ▸ Curator Link.
   - **Logic Pro**: insert Curator Link (Audio Units ▸ Curator) on the track. Logic hands ARA
     plug-ins the regions on the track.
   - **Studio One, REAPER, Cakewalk** and other ARA hosts: as they add ARA plug-ins
     (VST3).
3. In Curator, open the score, then the Audio tab ▸ ⋯ ▸ **Follow DAW…**. Choose the recording,
   the DAW bar where the score's bar 1 is (an upbeat comes before it), and whether to use the
   recording and follow the playhead.

While Curator follows a DAW, the Audio tab ▸ ⋯ ▸ **Capture Stems…** lists the DAW's tracks that
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

Only macOS is built so far. The protocol and Curator's side don't depend on the system.
