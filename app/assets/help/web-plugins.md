# Writing a web plugin

A web plugin changes the pages File ▸ Export to Web… writes: it adds buttons to the transport,
rows to Options, keys, and elements of its own over or beside the score, and it follows and
moves what plays. (What changes the app itself is a plugin, a `.cgp` in Lua; what belongs to
one project is an extension, a `.cpe`.) A web plugin runs in a browser, so it is written in
TypeScript and built into JavaScript. It is a `.cwp` file, which is a zip of plain files:

- `plugin.json`: its id, name, version, one-line summary, the API level it needs, its settings.
- `main.js`: its code as a page runs it: one ES module, built from `src/`.
- `src/main.ts`: its TypeScript, for those who read it (optional, and never run).
- `locales/<language>.json`: its texts in other languages (optional).
- `assets/`: files a page fetches with `curator.asset` (optional).
- `README.md`: what it does (optional).

Web plugins are kept by the app and listed in Export to Web, under Plugins. The ticked ones go
into the page. Add one from its file in the menu beside the heading; Download Docs for AI…
there saves this guide, the API's types and Curator's own web plugins as a folder.

## How it runs

`main.js` exports one function as its default. The player calls it once, as the page starts,
with the page's `Curator`. Everything a plugin does starts there:

```ts
import type { Curator } from "./curator-web";

export default function (curator: Curator) {
  curator.ui.button({
    title: "Restart",
    icon: "previous",
    run: () => curator.playback.seek(0),
  });
}
```

`curator-web.d.ts` declares the whole API (it is the Reference below). Copy it beside your
code: the import is of types only, and nothing of it is left in `main.js`.

A page starts its plugins in the order Export to Web lists them. What goes wrong in one is
written to the browser's console with its name, and never stops the page: a plugin that fails
to start adds nothing, and a function of one that throws is passed over.

## Building it

Any tool that turns TypeScript into one ES module does:

```bash
bun build src/main.ts --outfile main.js --format esm
```

```bash
npx esbuild src/main.ts --bundle --format=esm --outfile=main.js
```

Then zip the folder's files (not the folder itself) as `<name>.cwp`:

```bash
zip -r ../hello.cwp plugin.json main.js src README.md
```

To try a change without the app: export a page with the plugin once, then build into the
page's own copy, `score/plugins/<id>/main.js`, and reload. Open in Browser, in Export to Web,
serves the folder.

## Times and places

Times are seconds from the start of what is heard, 0 to `playback.duration`, as the
transport's clock counts them. Places in the score are quarter notes from its start.
`score.seconds(quarter)` and `score.quarter(seconds)` go between them. Lists start at 0.

## Playback

`curator.playback` is what is heard: `playing`, `time`, `duration`; `play()`, `pause()`,
`toggle()`, `seek(seconds)`; `speed`, `recording` (which of `page.recordings`), `volume` and
`muted`, each read and set. A browser lets sound start only after the viewer has clicked or
pressed a key, so a `play()` before that does nothing.

## Events

`curator.on(event, fn)` calls `fn` when something happens, and gives a function that stops it:

```ts
const off = curator.on("bar", (bar) => curator.log(`Bar ${bar.number}`));
```

`"play"`, `"pause"`, `"ended"`, `"seek"`; `"time"` (every frame while it plays), `"bar"` and
`"chapter"` as another one sounds; `"recording"`, `"speed"`, `"view"`, `"captions"`,
`"barNumbers"`, `"instruments"` as the viewer or a plugin changes them; `"resize"`, `"theme"`,
`"controls"` and `"options"` as the page does; `"click"` on the score, which
`event.preventDefault()` keeps from playing or pausing.

## The score and the view

`curator.score` reads the score and its performance: `bars()`, `barAt`, `format` and `parse`
("12.3"), `passes()` (a repeat is a pass more), `rehearsalMarks()`, `parts()`, `notes()`,
`chapters()` and `captions()`.

`curator.view` is what shows: `shows` (the views of the project's Video tab, the score, its
notes in rows, the player map: those in `available`), `captions`, `barNumbers`, each
instrument (`instruments()`, `show`). `frame` says where the score's frame is in the window;
`quarterAt(x)` and `xOf(quarter)` go between a place in the score and where it is drawn now.
The export may leave a choice to the viewer or not (`view.can("speed")`); a plugin is the
page's own, and changes any of them.

## What it adds

The player draws its interface itself, in one canvas. So a button, an option and a key are
described, and the player draws them as its own:

```ts
const loop = curator.ui.button({ title: "Loop", icon: "loop", checked: false, run: toggle });
loop.checked = true;                                   // any of them, changed later

curator.ui.option({ type: "switch", label: "Bar counter", value: true, change: (on) => show(on) });
curator.ui.key("shift+l", toggle);                     // wins over the player's own keys
curator.ui.message("Link copied");                     // a line at the page's foot
```

Elements of a plugin's own go in one of two places. `curator.ui.overlay()` is an element over
the score's frame, kept there as the window changes. It lies over all the player draws (so
it is hidden while Options is open); clicks go through it to the score, so give what should
take them `pointer-events: auto`. `curator.ui.dock("right", 300)` makes room
beside the player for a panel. Both carry the page's colours as `--curator-paper` and
`--curator-ink`. `curator.ui.controls.hidden = true` keeps the transport away, for a plugin
with controls of its own.

## Settings

Two kinds. What the one who exports the page sets is listed in plugin.json, shown in Export to
Web (the gear on the plugin's row) and read as `curator.settings`:

```json
"settings": [
  { "id": "corner", "label": "Corner", "type": "choice", "value": "topRight",
    "options": [{ "value": "topLeft", "label": "Top left" }, { "value": "topRight", "label": "Top right" }] },
  { "id": "beats", "label": "Beats", "type": "switch", "value": true },
  { "id": "prefix", "label": "Prefix", "type": "text", "value": "" }
]
```

What a viewer chooses is kept in their browser, for that page and that plugin:

```ts
const shown = curator.storage.get<boolean>("shown") ?? true;
curator.storage.set("shown", false);
```

## Text

Write every text shown to the viewer in English: a button's `title` and an option's `label`
are translated as they are shown, and `curator.tr("…")` translates one in code. To translate
them, add `locales/<language>.json` (`zh-Hans.json`, `ja.json`) with the English as the key:

```json
{ "Copy Link to Here": "复制此处的链接", "Bar {n}": "第 {n} 小节" }
```

`curator.tr("Bar {n}", { n: 3 })` fills `{n}` in. A text that means two things gets a context:
`curator.trIn("music", "Key")` looks for `"music|Key"` first. The language is the viewer's
browser's; `curator.language` says which.

## Staying compatible

The API only grows: what works now works in every later Curator. A page carries the player
that wrote it, so a plugin there never meets a player older than its page. To use something
newer than the level in plugin.json, ask first:

```ts
if (curator.has("ui.dock")) { … }
if (curator.has("event:chapter")) { … }
```

`"icon:…"` asks about an icon.

## A whole plugin

`plugin.json`

```json
{ "id": "com.example.restart", "name": "Restart", "version": "1.0.0",
  "summary": "A button and a key that go back to the start.", "api": 1 }
```

`src/main.ts`

```ts
import type { Curator } from "./curator-web";

export default function (curator: Curator) {
  const { playback, ui } = curator;
  const restart = () => {
    playback.seek(0);
    ui.message(curator.tr("Back at the start"));
  };
  const button = ui.button({ title: "Restart", icon: "previous", enabled: false, run: restart });
  ui.key("home", restart);
  // Nothing to go back from at the start.
  curator.on("time", ({ time }) => (button.enabled = time > 1));
  curator.on("seek", ({ time }) => (button.enabled = time > 1));
}
```

Curator's own web plugins (Export to Web ▸ Plugins; their code is in the docs folder) are
working examples: Media Keys (the browser's own APIs fed from events), Link to a Time (a
button, a setting, places and times), Embed Control (the page played from the site around it),
Bar Counter (an element over the score, an option, storage) and Transcript (a panel beside the
player, a ticked button, a key).

## Where a web plugin ends

- It is code on a web page, with the browser's own freedoms and limits: it may fetch, and use
  any API the browser has. Tick only plugins whose makers you trust: a page's visitors run them.
- It adds to the player and follows it. It doesn't draw on the score itself, and can't change
  how the score is engraved or curated: that is the project's, in the app.
- A button, an option and a key are the player's to draw: a plugin gives them a name, an icon
  of the list's, a state. What it draws itself is in an overlay or a dock.
- It keeps a viewer's choices in their browser, not in the page: another browser starts anew.
- Curator never runs it: the app only puts it into pages.
