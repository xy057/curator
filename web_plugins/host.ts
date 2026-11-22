// The web player's plugin host: what a page's plugins are given (curator-web.d.ts), made of
// what the player answers (PageApi.call, in Dart) and of the browser's own. The player loads
// this file (built into app/web/plugin_host.js by `make web-plugins`) when a page has plugins,
// and calls `start`.
//
// The player draws its own interface, so what a plugin adds there (a button, an option, a
// key) is described to it and drawn by it; what is the browser's (elements over and beside the
// score, the viewer's storage, the plugin's texts and files) is done here.

import type {
  Bar, Button, ButtonSpec, ActionSpec, Caption, Chapter, ChoiceSpec, Click, Curator, Dock, Edge, Events, Icon, Instrument,
  Mark, Note, Off, Option, OverlaySpec, Part, Pass, Plugin, Rect, Recording, Shown, Shows, Span, SwitchSpec, Theme, Values, Choice,
} from "../app/assets/web_plugins/curator-web";

/** What the player hands over: every question and order by name, and its `<audio>`. */
interface Bridge {
  call(method: string, args: unknown[]): { ok?: unknown; error?: string };
  audio(): HTMLAudioElement | null;
}

/** A plugin as the page lists it (page.json's `plugins`, with where its files are). */
interface PluginSpec {
  id: string;
  name: string;
  version: string;
  api: number;
  locales: string[];
  settings: Record<string, string | boolean>;
  folder: string;
}

interface PageSpec {
  api: number;
  plugins: PluginSpec[];
}

/** What the player tells the host through. */
export interface Host {
  /** Something happened; true when a plugin asks the player not to do what it otherwise would. */
  emit(event: string, data: Record<string, unknown>): boolean;
}

interface PageInfo {
  title: string;
  firstBar: number;
  lastBar: number;
  ratio: number | null;
  recordings: Recording[];
  player: { release: string; build: number };
  open: Record<Choice, boolean>;
  available: Shows[];
}

/** What `curator.has` knows: every member, event and icon of this level. */
const members = [
  "api", "plugin", "player", "language", "settings", "storage", "page", "playback", "view", "score", "ui",
  "on", "once", "has", "tr", "trIn", "asset", "log",
  "storage.get", "storage.set", "storage.remove",
  "page.title", "page.firstBar", "page.lastBar", "page.ratio", "page.recordings",
  "playback.playing", "playback.time", "playback.duration", "playback.musicEnd", "playback.play", "playback.pause", "playback.toggle",
  "playback.seek", "playback.speed", "playback.recording", "playback.volume", "playback.muted", "playback.audio",
  "view.shows", "view.available", "view.captions", "view.barNumbers", "view.instruments", "view.show", "view.can", "view.frame",
  "view.theme", "view.quarterAt", "view.xOf",
  "score.title", "score.quarters", "score.bars", "score.barAt", "score.beatAt", "score.format", "score.parse", "score.seconds",
  "score.quarter", "score.passAt", "score.passes", "score.spans", "score.rehearsalMarks", "score.parts", "score.notes",
  "score.chapters", "score.captions",
  "ui.button", "ui.option", "ui.key", "ui.message", "ui.overlay", "ui.dock", "ui.controls", "ui.showOptions",
];
const events: (keyof Events)[] = [
  "play", "pause", "ended", "seek", "time", "bar", "chapter", "recording", "speed", "view", "captions", "barNumbers", "instruments",
  "resize", "theme", "controls", "options", "click",
];
const icons: Icon[] = [
  "play", "pause", "stop", "previous", "next", "rewind", "forward", "replay", "loop", "shuffle", "volume", "mute", "fullscreen",
  "exitFullscreen", "link", "share", "copy", "download", "info", "help", "settings", "bookmark", "star", "heart", "search", "list",
  "text", "captions", "music", "piano", "clock", "show", "hide", "zoomIn", "zoomOut", "close", "check", "add", "remove", "more",
  "language",
];
const features = new Set<string>([...members, ...events.map((e) => `event:${e}`), ...icons.map((i) => `icon:${i}`)]);

/** A plugin running: what it listens to and what it added, to take away should it fail to start. */
interface Running {
  spec: PluginSpec;
  texts: Record<string, string>;
  language: string;
  undo: Set<() => void>;
}

type Listener = { plugin: Running; fn: (event: never) => void };

/** Starts the page's plugins, in the page's order, and gives what the player tells them through. */
export function start(bridge: Bridge, page: PageSpec): Host {
  const call = <T = unknown>(method: string, ...args: unknown[]): T => {
    const answer = bridge.call(method, args);
    if (answer.error !== undefined) throw new Error(answer.error);
    return answer.ok as T;
  };
  const info = call<PageInfo>("page");

  // MARK: What happens

  const listeners = new Map<string, Set<Listener>>();
  /** What the viewer's press of a button, change of an option or key calls, by the id the player has it under. */
  const presses = new Map<string, () => void>();
  const changes = new Map<string, (value: unknown) => void>();

  const failed = (plugin: Running, doing: string, error: unknown) => console.error(`Curator: the plugin ${plugin.spec.name} failed in ${doing}.`, error);

  function tell(event: string, data: unknown): void {
    for (const { plugin, fn } of [...(listeners.get(event) ?? [])]) {
      try {
        (fn as (event: unknown) => void)(data);
      } catch (error) {
        failed(plugin, `"${event}"`, error);
      }
    }
  }

  function emit(event: string, data: Record<string, unknown>): boolean {
    switch (event) {
      case "ui.press":
      case "ui.key":
        presses.get(data.id as string)?.();
        return false;
      case "ui.change":
        changes.get(data.id as string)?.(data.value);
        return false;
      case "click": {
        let prevented = false;
        const click: Click = { x: data.x as number, y: data.y as number, quarter: (data.quarter ?? null) as number | null, preventDefault: () => void (prevented = true) };
        tell(event, click);
        return prevented;
      }
      case "resize":
        place();
        break;
      case "options":
        // The player draws Options under the page's elements: those over the frame give way to it.
        for (const { element, over } of overlays) if (over === "frame") element.style.visibility = data.open ? "hidden" : "";
        break;
    }
    tell(event, data);
    return false;
  }

  // MARK: Elements over and beside the score

  // Over the player (which draws into the page's one canvas): clicks go through to it but
  // where a plugin's own element takes them.
  const root = document.createElement("div");
  root.id = "curator-plugins";
  root.style.cssText = "position:fixed;inset:0;z-index:1;pointer-events:none;";
  document.body.appendChild(root);

  const overlays: { element: HTMLElement; over: "frame" | "page" }[] = [];
  const docks: { element: HTMLElement; edge: Edge; size: number }[] = [];

  function colours(): Theme {
    const theme = call<Theme>("view.theme");
    root.style.setProperty("--curator-paper", theme.paper);
    root.style.setProperty("--curator-ink", theme.ink);
    root.style.colorScheme = theme.dark ? "dark" : "light";
    return theme;
  }
  colours();
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => tell("theme", colours()));

  /** Puts every overlay over what it covers. Those taken out of the page are forgotten. */
  function place(): void {
    const frame = call<Rect>("view.frame");
    for (let i = overlays.length - 1; i >= 0; i--) {
      const { element, over } = overlays[i];
      if (!element.isConnected) {
        overlays.splice(i, 1);
      } else if (over === "frame") {
        Object.assign(element.style, { left: `${frame.x}px`, top: `${frame.y}px`, width: `${frame.width}px`, height: `${frame.height}px` });
      }
    }
  }

  /**
   * Lays the docks out, top and bottom ones across the window and left and right ones between
   * them, each edge's from the window's edge inwards in the order they were made, and has the
   * player leave them the room.
   */
  function layout(): void {
    const room = { left: 0, top: 0, right: 0, bottom: 0 };
    for (const dock of docks) room[dock.edge] += dock.size;
    const at = { left: 0, top: 0, right: 0, bottom: 0 };
    for (const { element, edge, size } of docks) {
      const style = element.style;
      style.left = style.right = style.top = style.bottom = style.width = style.height = "";
      if (edge === "top" || edge === "bottom") {
        Object.assign(style, { left: "0", right: "0", [edge]: `${at[edge]}px`, height: `${size}px` });
      } else {
        Object.assign(style, { top: `${room.top}px`, bottom: `${room.bottom}px`, [edge]: `${at[edge]}px`, width: `${size}px` });
      }
      at[edge] += size;
    }
    call("ui.insets", room.left, room.top, room.right, room.bottom);
  }

  // MARK: A plugin's own Curator

  let serial = 0;

  function curatorOf(plugin: Running): Curator {
    const { spec } = plugin, name = spec.name;
    const base = new URL(`${spec.folder}/`, document.baseURI);
    const id = () => `${spec.id}#${++serial}`;

    const fill = (text: string, values?: Values) =>
      values ? text.replace(/\{(\w+)\}/g, (whole, name: string) => (name in values ? String(values[name]) : whole)) : text;
    const tr = (text: string, values?: Values) => fill(plugin.texts[text] ?? text, values);
    const trIn = (context: string, text: string, values?: Values) => fill(plugin.texts[`${context}|${text}`] ?? plugin.texts[text] ?? text, values);

    /** Calls a plugin's own function, whatever it does: one that throws never stops the player. */
    const guarded = <A extends unknown[]>(doing: string, fn: (...args: A) => void) => (...args: A) => {
      try {
        fn(...args);
      } catch (error) {
        failed(plugin, doing, error);
      }
    };

    /** Something to take away should the plugin fail to start; the function that does it now. */
    const undoable = (undo: () => void): Off => {
      const off = () => {
        if (plugin.undo.delete(off)) undo();
      };
      plugin.undo.add(off);
      return off;
    };

    function on<E extends keyof Events>(event: E, fn: (event: Events[E]) => void): Off {
      if (typeof fn !== "function") throw new TypeError(`curator.on("${event}"): the listener isn’t a function`);
      let set = listeners.get(event);
      if (!set) listeners.set(event, (set = new Set()));
      const listener: Listener = { plugin, fn: fn as (event: never) => void };
      set.add(listener);
      return undoable(() => set.delete(listener));
    }

    // What the viewer's browser keeps, apart for each page and plugin; a browser that keeps
    // nothing keeps it here until the page closes.
    const prefix = `curator:${location.pathname}:${spec.id}:`;
    const memory = new Map<string, string>();
    const kept = {
      read(key: string): string | null {
        try {
          return localStorage.getItem(prefix + key);
        } catch {
          return memory.get(key) ?? null;
        }
      },
      write(key: string, value: string | null): void {
        try {
          if (value === null) localStorage.removeItem(prefix + key);
          else localStorage.setItem(prefix + key, value);
        } catch {
          if (value === null) memory.delete(key);
          else memory.set(key, value);
        }
      },
    };

    const curator: Curator = {
      api: page.api,
      plugin: Object.freeze({ id: spec.id, name: spec.name, version: spec.version }),
      player: Object.freeze({ ...info.player }),
      language: plugin.language,
      settings: Object.freeze({ ...spec.settings }),
      storage: {
        get<T>(key: string, fallback?: T): T | undefined {
          const text = kept.read(key);
          if (text === null) return fallback;
          try {
            return JSON.parse(text) as T;
          } catch {
            return fallback;
          }
        },
        set: (key, value) => kept.write(key, JSON.stringify(value)),
        remove: (key) => kept.write(key, null),
      },
      page: Object.freeze({
        title: info.title,
        firstBar: info.firstBar,
        lastBar: info.lastBar,
        ratio: info.ratio,
        recordings: Object.freeze(info.recordings.map((r) => Object.freeze({ ...r }))),
      }),
      playback: {
        get playing() { return call<boolean>("playback.playing"); },
        get time() { return call<number>("playback.time"); },
        get duration() { return call<number>("playback.duration"); },
        get musicEnd() { return call<number>("playback.musicEnd"); },
        play: () => call("playback.play"),
        pause: () => call("playback.pause"),
        toggle() { call(this.playing ? "playback.pause" : "playback.play"); },
        seek: (seconds) => call("playback.seek", seconds),
        get speed() { return call<number>("playback.speed"); },
        set speed(value) { call("playback.setSpeed", value); },
        get recording() { return call<number>("playback.recording"); },
        set recording(index) { call("playback.setRecording", index); },
        get volume() { return call<number>("playback.volume"); },
        set volume(value) { call("playback.setVolume", value); },
        get muted() { return call<boolean>("playback.muted"); },
        set muted(value) { call("playback.setMuted", value); },
        get audio() { return bridge.audio() ?? null; },
      },
      view: {
        get shows() { return call<Shows>("view.shows"); },
        set shows(value) { call("view.setShows", value); },
        available: Object.freeze([...info.available]),
        get captions() { return call<boolean>("view.captions"); },
        set captions(on) { call("view.setCaptions", on); },
        get barNumbers() { return call<boolean>("view.barNumbers"); },
        set barNumbers(on) { call("view.setBarNumbers", on); },
        instruments: () => call<Instrument[]>("view.instruments"),
        show: (part: string, how: Shown) => call("view.show", part, how),
        can: (choice) => info.open[choice] === true,
        get frame() { return call<Rect>("view.frame"); },
        get theme() { return call<Theme>("view.theme"); },
        quarterAt: (x) => call<number | null>("view.quarterAt", x) ?? null,
        xOf: (quarter) => call<number | null>("view.xOf", quarter) ?? null,
      },
      score: {
        get title() { return call<string>("score.title"); },
        get quarters() { return call<number>("score.quarters"); },
        bars: () => call<Bar[]>("score.bars"),
        barAt: (quarter) => call<Bar>("score.barAt", quarter),
        beatAt: (quarter) => call<{ start: number; end: number }>("score.beatAt", quarter),
        format: (quarter, compact) => call<string>("score.format", quarter, compact ?? false),
        parse: (text) => call<number | null>("score.parse", text) ?? null,
        seconds: (quarter, pass) => call<number>("score.seconds", quarter, pass ?? 0),
        quarter: (seconds) => call<number>("score.quarter", seconds),
        passAt: (seconds) => call<number>("score.passAt", seconds),
        passes: () => call<Pass[]>("score.passes"),
        spans: (places, end) => call<Span[]>("score.spans", places, end ?? null),
        rehearsalMarks: () => call<Mark[]>("score.rehearsalMarks"),
        parts: () => call<Part[]>("score.parts"),
        notes: (part) => call<Note[]>("score.notes", part ?? null),
        chapters: () => call<Chapter[]>("score.chapters"),
        captions: () => call<Caption[]>("score.captions"),
      },
      ui: {
        button(spec: ButtonSpec): Button {
          const key = id(), state = { title: spec.title, icon: spec.icon, text: spec.text, checked: spec.checked ?? false, enabled: spec.enabled ?? true };
          const show = () => call("ui.button", { id: key, ...state, title: tr(state.title), icon: state.icon ?? null, text: state.text ?? null });
          show();
          presses.set(key, guarded(`the button ${spec.title}`, () => spec.run()));
          const remove = undoable(() => {
            presses.delete(key);
            call("ui.removeButton", key);
          });
          return {
            get title() { return state.title; },
            set title(value) { state.title = value; show(); },
            get icon() { return state.icon; },
            set icon(value) { state.icon = value; show(); },
            get text() { return state.text; },
            set text(value) { state.text = value; show(); },
            get checked() { return state.checked; },
            set checked(value) { state.checked = value; show(); },
            get enabled() { return state.enabled; },
            set enabled(value) { state.enabled = value; show(); },
            remove,
          };
        },
        option(spec: SwitchSpec | ChoiceSpec | ActionSpec): Option {
          const key = id();
          const state = { label: spec.label, value: spec.type === "action" ? undefined : spec.value, enabled: true };
          const show = () =>
            call("ui.option", {
              id: key,
              group: name,
              type: spec.type,
              label: tr(state.label),
              value: state.value ?? null,
              options: spec.type === "choice" ? spec.options.map((o) => ({ value: o.value, label: tr(o.label) })) : [],
              enabled: state.enabled,
            });
          show();
          if (spec.type === "action") {
            presses.set(key, guarded(`the option ${spec.label}`, () => spec.run()));
          } else {
            changes.set(key, guarded(`the option ${spec.label}`, (value: unknown) => {
              state.value = value as boolean | string;
              (spec.change as (value: unknown) => void)(value);
            }));
          }
          const remove = undoable(() => {
            presses.delete(key);
            changes.delete(key);
            call("ui.removeOption", key);
          });
          return {
            get label() { return state.label; },
            set label(value) { state.label = value; show(); },
            get value() { return state.value; },
            set value(value) { if (spec.type !== "action") { state.value = value; show(); } },
            get enabled() { return state.enabled; },
            set enabled(value) { state.enabled = value; show(); },
            remove,
          };
        },
        key(chord: string, run: () => void): Off {
          const key = id();
          call("ui.key", key, chord);
          presses.set(key, guarded(`the key ${chord}`, run));
          return undoable(() => {
            presses.delete(key);
            call("ui.removeKey", key);
          });
        },
        message: (text) => call("ui.message", String(text)),
        overlay(overlay?: OverlaySpec): HTMLElement {
          const element = document.createElement("div"), over = overlay?.over ?? "frame";
          element.dataset.plugin = spec.id;
          element.style.cssText = `position:fixed;pointer-events:none;overflow:hidden;color:var(--curator-ink);${over === "page" ? "inset:0;" : ""}`;
          root.appendChild(element);
          overlays.push({ element, over });
          undoable(() => element.remove());
          place();
          return element;
        },
        dock(edge: Edge, size: number): Dock {
          if (!["left", "right", "top", "bottom"].includes(edge)) throw new TypeError(`curator.ui.dock: ${edge} isn’t an edge`);
          const element = document.createElement("div");
          element.dataset.plugin = spec.id;
          element.style.cssText = "position:fixed;pointer-events:auto;overflow:auto;box-sizing:border-box;background:var(--curator-paper);color:var(--curator-ink);";
          const dock = { element, edge, size: Math.max(0, Number(size) || 0) };
          docks.push(dock);
          root.appendChild(element);
          layout();
          const remove = undoable(() => {
            docks.splice(docks.indexOf(dock), 1);
            element.remove();
            layout();
          });
          return {
            element,
            edge,
            get size() { return dock.size; },
            set size(value) { dock.size = Math.max(0, Number(value) || 0); layout(); },
            remove,
          };
        },
        controls: {
          get visible() { return call<boolean>("ui.controlsVisible"); },
          get hidden() { return call<boolean>("ui.controlsHidden"); },
          set hidden(value) { call("ui.hideControls", value); },
        },
        showOptions: () => call("ui.showOptions"),
      },
      on,
      once(event, fn) {
        const off = on(event, (data) => {
          off();
          fn(data);
        });
        return off;
      },
      has: (name) => features.has(name),
      tr,
      trIn,
      asset: (path) => new URL(`assets/${path}`, base).href,
      log: (...values) => console.log(`[${name}]`, ...values),
    };
    return curator;
  }

  // MARK: Starting them

  /** The locale of [locales] the viewer reads first, and the browser's own language. */
  function languageOf(locales: string[]): { locale: string | null; language: string } {
    const wanted = navigator.languages?.length ? navigator.languages : [navigator.language || "en"];
    const lower = new Map(locales.map((l) => [l.toLowerCase(), l]));
    for (const tag of wanted) {
      const t = tag.toLowerCase(), primary = t.split("-")[0];
      // A plugin's texts are written in English: one who reads it first reads them as they are.
      if (primary === "en") break;
      const chinese = primary === "zh" ? (/hant|-(tw|hk|mo)\b/.test(t) ? "zh-hant" : "zh-hans") : null;
      const found = lower.get(t) ?? (chinese && lower.get(chinese)) ?? lower.get(primary) ?? locales.find((l) => l.toLowerCase().split("-")[0] === primary && !chinese);
      if (found) return { locale: found, language: found };
    }
    return { locale: null, language: wanted[0] };
  }

  async function boot(spec: PluginSpec): Promise<void> {
    if (spec.api > page.api) {
      console.warn(`Curator: the plugin ${spec.name} needs a newer Curator (API level ${spec.api}; this player has ${page.api}).`);
      return;
    }
    const { locale, language } = languageOf(spec.locales ?? []);
    const plugin: Running = { spec, texts: {}, language, undo: new Set() };
    try {
      const base = new URL(`${spec.folder}/`, document.baseURI);
      if (locale) {
        // Without its texts a plugin still runs, in English.
        try {
          const response = await fetch(new URL(`locales/${locale}.json`, base));
          if (response.ok) plugin.texts = (await response.json()) as Record<string, string>;
        } catch (error) {
          console.warn(`Curator: the plugin ${spec.name} has no texts for ${locale}.`, error);
        }
      }
      const module = (await import(new URL("main.js", base).href)) as { default?: Plugin };
      if (typeof module.default !== "function") throw new Error("main.js has no default export to call");
      const curator = curatorOf(plugin);
      // What it adds before it fails is taken away again; what it awaits isn't waited for.
      const started = module.default(curator);
      if (started instanceof Promise) started.catch((error) => failed(plugin, "starting", error));
    } catch (error) {
      console.error(`Curator: the plugin ${spec.name} couldn’t start.`, error);
      for (const undo of [...plugin.undo]) {
        try {
          undo();
        } catch {
          // gone already
        }
      }
    }
  }

  // One after another, so what they add is in the page's order.
  void (async () => {
    for (const spec of page.plugins) await boot(spec);
  })();

  return { emit };
}
