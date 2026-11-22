/**
 * Curator's web player plugin API, level 1.
 *
 * A web plugin changes a page File ▸ Export to Web… writes: it adds buttons to the transport,
 * rows to Options, keys, elements of its own over or beside the score, and follows and moves
 * what plays. Its code is an ES module, `main.js`, built from TypeScript; its default export is
 * called once, as the page starts, with the page's `Curator`:
 *
 *     import type { Curator } from "./curator-web";
 *
 *     export default function (curator: Curator) {
 *       curator.ui.button({ title: "Restart", icon: "previous", run: () => curator.playback.seek(0) });
 *     }
 *
 * Times are seconds from the start of what is heard (0 … `playback.duration`), as the
 * transport's clock counts them. Places in the score are quarter notes from its start. Lists
 * start at 0.
 *
 * The API only grows: what is here works in every later Curator. What a later level adds says
 * so (`@since`); `curator.has("ui.dock")` asks whether this player has it.
 */

/** What `main.js` exports as its default: called once, as the page starts. */
export type Plugin = (curator: Curator) => void | Promise<void>;

/** Stops what the call that gave it started (a listener, a key). */
export type Off = () => void;

/** The values a text's `{name}` placeholders are filled with. */
export type Values = Record<string, string | number>;

/** The page a plugin runs in: everything it can read, follow and change. */
export interface Curator {
  /** This player's plugin API level. */
  readonly api: number;
  /** The plugin itself, as its plugin.json says. */
  readonly plugin: PluginInfo;
  /** The web player: the Curator that wrote the page. */
  readonly player: PlayerInfo;
  /** The viewer's language, as the plugin's `locales/` name them where it has it ("zh-Hans"), else the browser's ("fr-CA"). */
  readonly language: string;
  /** The plugin's settings as the page was exported with them, by id: plugin.json's `settings`, each as set in Export to Web. */
  readonly settings: Readonly<Record<string, string | boolean>>;
  /** What the plugin keeps in the viewer's browser, for this page. */
  readonly storage: PluginStorage;
  /** What the page is. */
  readonly page: Page;
  /** What is heard: playing, the time, the speed, the recording. */
  readonly playback: Playback;
  /** What shows in the frame. */
  readonly view: View;
  /** The score, and the performance it is synced to. */
  readonly score: Score;
  /** What the plugin adds to the page. */
  readonly ui: UI;

  /** Calls `fn` whenever `event` happens; the function it gives stops that. */
  on<E extends keyof Events>(event: E, fn: (event: Events[E]) => void): Off;
  /** As `on`, for the next time only. */
  once<E extends keyof Events>(event: E, fn: (event: Events[E]) => void): Off;
  /**
   * Whether this player has something: a member ("ui.dock", "score.notes"), an event
   * ("event:chapter") or an icon ("icon:loop"). For using what is newer than the level in
   * plugin.json.
   */
  has(name: string): boolean;
  /**
   * `text` in the viewer's language, from the plugin's `locales/<language>.json` (the English
   * is the key); each `{name}` in it is replaced by `values.name`. The texts a plugin hands
   * the player (a button's title, an option's label) are translated so as they are shown.
   */
  tr(text: string, values?: Values): string;
  /** `tr` for a text that means two things: `"context|text"` in the locale file first. */
  trIn(context: string, text: string, values?: Values): string;
  /** The address of a file in the plugin's `assets/` folder, for `fetch`, an `<img>` or `import()`. */
  asset(path: string): string;
  /** Writes to the browser's console, under the plugin's name. */
  log(...values: unknown[]): void;
}

export interface PluginInfo {
  readonly id: string;
  readonly name: string;
  readonly version: string;
}

export interface PlayerInfo {
  /** The release that wrote the page ("0.10.0"). */
  readonly release: string;
  /** Its build (a number). */
  readonly build: number;
}

/**
 * What a plugin keeps in the viewer's browser (its local storage), apart for each page and each
 * plugin. A browser that keeps nothing (a private window) keeps it until the page closes.
 */
export interface PluginStorage {
  /** What was kept under `key`; `fallback` (else undefined) when nothing was. */
  get<T = unknown>(key: string, fallback?: T): T | undefined;
  /** Keeps `value` (anything JSON holds) under `key`. */
  set(key: string, value: unknown): void;
  remove(key: string): void;
}

// MARK: The page

export interface Page {
  readonly title: string;
  /** The bars the page shows, counted from 1. */
  readonly firstBar: number;
  readonly lastBar: number;
  /** The frame's width : height; null: the whole window. */
  readonly ratio: number | null;
  /** The ways to hear it, the first the performance. */
  readonly recordings: readonly Recording[];
}

export interface Recording {
  readonly label: string;
  /** How long it plays, seconds. */
  readonly duration: number;
  /** When its music ends: the score then comes to rest and fades. */
  readonly musicEnd: number;
  /** Whether it has sound (a page without a recording is silent). */
  readonly sound: boolean;
}

// MARK: Playback

export interface Playback {
  readonly playing: boolean;
  /** Where it is, seconds. */
  readonly time: number;
  /** How long what is heard plays. */
  readonly duration: number;
  /** When the music ends. */
  readonly musicEnd: number;
  /**
   * Plays from where it is (from the start, at the end). A browser lets sound start only after
   * the viewer has clicked or pressed a key: `"play"` tells that it did.
   */
  play(): void;
  pause(): void;
  toggle(): void;
  seek(seconds: number): void;
  /** How fast it plays, the pitch kept: 0.25 … 4. */
  speed: number;
  /** Which of `page.recordings` is heard. Another one plays on from the same place in the score. */
  recording: number;
  /** 0 … 1. */
  volume: number;
  muted: boolean;
  /**
   * The `<audio>` element what is heard plays through, for what the API has no word for (an
   * analyser, a sink); null on a silent page. Another recording is another element: ask again
   * on `"recording"`. Move the time with `seek`, not through it.
   */
  readonly audio: HTMLAudioElement | null;
}

// MARK: The view

/**
 * What shows in the frame: the views as the project's Video tab has them, the score, the
 * score's notes in rows, or the player map.
 */
export type Shows = "views" | "score" | "midi" | "map";

/** How an instrument shows: as its lane says, always, or never. */
export type Shown = "curated" | "shown" | "hidden";

/** What the export may leave the viewer to change in Options. */
export type Choice = "recording" | "speed" | "captions" | "barNumbers" | "view" | "instruments";

export interface View {
  /** What shows. One the page hasn't (`available`) is refused. */
  shows: Shows;
  /** What the page can show. */
  readonly available: readonly Shows[];
  captions: boolean;
  barNumbers: boolean;
  instruments(): Instrument[];
  /** Shows an instrument as curated, always or never. */
  show(part: string, how: Shown): void;
  /** Whether the export left `choice` to the viewer. A plugin is the page's own: it changes any of them. */
  can(choice: Choice): boolean;
  /** Where the frame is in the window, CSS pixels. */
  readonly frame: Rect;
  readonly theme: Theme;
  /** The place in the score under `x` (pixels from the frame's left) now; null while the map shows. */
  quarterAt(x: number): number | null;
  /** Where a place in the score is now, pixels from the frame's left (it may be outside it); null while the map shows. */
  xOf(quarter: number): number | null;
}

export interface Instrument {
  readonly id: string;
  readonly name: string;
  readonly shown: Shown;
}

export interface Rect {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/** The page's colours: the browser's light or dark, the paper and the ink as "#rrggbb". */
export interface Theme {
  readonly dark: boolean;
  readonly paper: string;
  readonly ink: string;
}

// MARK: The score

export interface Score {
  /** "" when it has none. */
  readonly title: string;
  /** Its length, quarter notes. */
  readonly quarters: number;
  bars(): Bar[];
  /** The bar a place is in. */
  barAt(quarter: number): Bar;
  /** The beat a place is in. */
  beatAt(quarter: number): { start: number; end: number };
  /** A place as bar.beat ("12.3"); `compact` drops a first beat ("12"). */
  format(quarter: number, compact?: boolean): string;
  /** The place "12" or "12.3" names; null when it names none. */
  parse(text: string): number | null;
  /** When a place sounds, in the `pass`-th time through it (0, the first, by default). */
  seconds(quarter: number, pass?: number): number;
  /** The place sounding at a time. */
  quarter(seconds: number): number;
  /** Which pass through the score sounds at a time: a repeat is a pass more. */
  passAt(seconds: number): number;
  passes(): Pass[];
  /**
   * Markers (places, each running to the next) as they sound, in order. A repeat back into an
   * earlier one is that one again. They cover what is heard from 0 to `end` seconds (the end of
   * the music by default).
   */
  spans(places: number[], end?: number): Span[];
  /** In the order written. */
  rehearsalMarks(): Mark[];
  parts(): Part[];
  /** The notes as they sound (ties joined on, transposing parts at concert pitch), part by part; of one part with its id. Read from the score each time: keep what it gives. */
  notes(part?: string): Note[];
  /** The page's chapters, in order; none unless the project has them. */
  chapters(): Chapter[];
  /** The captions as they show, in order, each as often as its music sounds. */
  captions(): Caption[];
}

export interface Bar {
  /** Its place in `bars()`. */
  readonly index: number;
  /** Its number, counted from the project's first bar number. */
  readonly number: number;
  /** Where it starts, quarters. */
  readonly start: number;
  readonly length: number;
}

/** A pass through the score: quarters `from` … `to`, sounding `starts` … `ends` seconds. */
export interface Pass {
  readonly from: number;
  readonly to: number;
  readonly starts: number;
  readonly ends: number;
}

export interface Span {
  /** The marker's place in the list given; -1 for the music before the first. */
  readonly index: number;
  /** Seconds. */
  readonly from: number;
  readonly to: number;
}

export interface Mark {
  /** Where it is, quarters. */
  readonly at: number;
  /** The bar it is in, as `bars()` lists it. */
  readonly bar: number;
  readonly text: string;
}

export interface Part {
  readonly id: string;
  readonly name: string;
  readonly staves: number;
}

export interface Note {
  readonly part: string;
  /** 1 is the part's first staff. */
  readonly staff: number;
  /** Quarters. */
  readonly start: number;
  readonly end: number;
  /** As MIDI: 60 is middle C. */
  readonly pitch: number;
}

export interface Chapter {
  readonly name: string;
  /** Seconds. */
  readonly start: number;
  readonly end: number;
}

export interface Caption {
  /** As written: `*italic*` and `**bold**` as in Markdown. */
  readonly text: string;
  /** Seconds. */
  readonly start: number;
  readonly end: number;
}

// MARK: Events

/** What `curator.on` listens to, and what each tells. */
export interface Events {
  /** It started playing. */
  play: {};
  /** It stopped, by anyone's doing. */
  pause: {};
  /** It played to the end. */
  ended: {};
  /** The time was moved other than by playing. */
  seek: { time: number };
  /** The time is other than it was: every frame while it plays. */
  time: { time: number };
  /** Another bar sounds. */
  bar: Bar;
  /** Another chapter plays: its place in `score.chapters()`, -1 for none. */
  chapter: { index: number };
  /** Another recording is heard. */
  recording: { index: number };
  speed: { speed: number };
  /** What shows is other than it was. */
  view: { shows: Shows };
  captions: { on: boolean };
  barNumbers: { on: boolean };
  /** An instrument shows otherwise. */
  instruments: {};
  /** The frame is elsewhere or another size. */
  resize: { frame: Rect };
  /** The browser went light or dark. */
  theme: Theme;
  /** The transport came or went (it rests while the page plays and the pointer is still). */
  controls: { visible: boolean };
  /** Options opened or closed. While it is open the overlays over the frame are hidden: they would lie over it. */
  options: { open: boolean };
  /** The score was clicked. The player then plays or pauses, unless a listener says not to. */
  click: Click;
}

export interface Click {
  /** Where, pixels from the frame's left and top. */
  readonly x: number;
  readonly y: number;
  /** The place in the score there; null on the map. */
  readonly quarter: number | null;
  /** Keeps the player from playing or pausing. */
  preventDefault(): void;
}

// MARK: The interface

/** The icons a button may name. */
export type Icon =
  | "play" | "pause" | "stop" | "previous" | "next" | "rewind" | "forward" | "replay" | "loop" | "shuffle"
  | "volume" | "mute" | "fullscreen" | "exitFullscreen" | "link" | "share" | "copy" | "download" | "info" | "help"
  | "settings" | "bookmark" | "star" | "heart" | "search" | "list" | "text" | "captions" | "music" | "piano"
  | "clock" | "show" | "hide" | "zoomIn" | "zoomOut" | "close" | "check" | "add" | "remove" | "more" | "language";

export type Edge = "left" | "right" | "top" | "bottom";

export interface UI {
  /** Adds a button to the transport, before Options. */
  button(spec: ButtonSpec): Button;
  /** Adds a row to Options, under the plugin's name. */
  option(spec: SwitchSpec | ChoiceSpec | ActionSpec): Option;
  /**
   * Calls `run` when a key is pressed: what is held, then the key, joined by `+`
   * ("shift+l", "cmd+k": `cmd` is ⌘ on a Mac and Ctrl elsewhere). A key is written as it is
   * typed, or by name: space, enter, tab, escape, backspace, delete, left, right, up, down,
   * home, end, pageup, pagedown, f1 … f12. A plugin's key wins over the player's own (space,
   * left, right). Throws for a key that isn't one.
   */
  key(key: string, run: () => void): Off;
  /** Shows a line at the page's foot for a moment. */
  message(text: string): void;
  /**
   * An element of the plugin's over the frame (or the whole page), kept where it is as the
   * window changes: fill it as any element. It lies over all the player draws, its transport
   * too. Clicks go through it to the score; give what should take them `pointer-events: auto`.
   * `element.remove()` takes it away.
   */
  overlay(spec?: OverlaySpec): HTMLElement;
  /** Room beside the player for an element of the plugin's: a panel `size` pixels wide (left, right) or tall (top, bottom). */
  dock(edge: Edge, size: number): Dock;
  /** The transport at the page's foot. */
  readonly controls: Controls;
  /** Opens Options. */
  showOptions(): void;
}

export interface ButtonSpec {
  /** Its name, in English: its tip, and its face without an icon or a text. */
  title: string;
  icon?: Icon;
  /** A few characters as its face, in place of an icon ("1×", "A–B"). */
  text?: string;
  /** Whether it shows as on. */
  checked?: boolean;
  enabled?: boolean;
  run(): void;
}

export interface Button {
  title: string;
  icon: Icon | undefined;
  text: string | undefined;
  checked: boolean;
  enabled: boolean;
  remove(): void;
}

export interface SwitchSpec {
  type: "switch";
  /** In English. */
  label: string;
  value: boolean;
  /** The viewer turned it. */
  change(value: boolean): void;
}

export interface ChoiceSpec {
  type: "choice";
  label: string;
  /** One of the options' values. */
  value: string;
  options: { value: string; label: string }[];
  /** The viewer chose another. */
  change(value: string): void;
}

export interface ActionSpec {
  type: "action";
  label: string;
  run(): void;
}

export interface Option {
  label: string;
  /** A switch's or a choice's; setting it calls nothing. */
  value: boolean | string | undefined;
  enabled: boolean;
  remove(): void;
}

export interface OverlaySpec {
  /** Over the score's frame (the default), or the whole page. */
  over?: "frame" | "page";
}

export interface Dock {
  readonly element: HTMLElement;
  readonly edge: Edge;
  /** How wide or tall it is; set it to change the room. */
  size: number;
  remove(): void;
}

export interface Controls {
  /** Whether the transport shows now. */
  readonly visible: boolean;
  /** Keeps the transport away for good: a plugin with controls of its own. */
  hidden: boolean;
}
