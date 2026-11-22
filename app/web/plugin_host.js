// Built from web_plugins/host.ts by `make web-plugins`: change that, not this.
// web_plugins/host.ts
var members = [
  "api",
  "plugin",
  "player",
  "language",
  "settings",
  "storage",
  "page",
  "playback",
  "view",
  "score",
  "ui",
  "on",
  "once",
  "has",
  "tr",
  "trIn",
  "asset",
  "log",
  "storage.get",
  "storage.set",
  "storage.remove",
  "page.title",
  "page.firstBar",
  "page.lastBar",
  "page.ratio",
  "page.recordings",
  "playback.playing",
  "playback.time",
  "playback.duration",
  "playback.musicEnd",
  "playback.play",
  "playback.pause",
  "playback.toggle",
  "playback.seek",
  "playback.speed",
  "playback.recording",
  "playback.volume",
  "playback.muted",
  "playback.audio",
  "view.shows",
  "view.available",
  "view.captions",
  "view.barNumbers",
  "view.instruments",
  "view.show",
  "view.can",
  "view.frame",
  "view.theme",
  "view.quarterAt",
  "view.xOf",
  "score.title",
  "score.quarters",
  "score.bars",
  "score.barAt",
  "score.beatAt",
  "score.format",
  "score.parse",
  "score.seconds",
  "score.quarter",
  "score.passAt",
  "score.passes",
  "score.spans",
  "score.rehearsalMarks",
  "score.parts",
  "score.notes",
  "score.chapters",
  "score.captions",
  "ui.button",
  "ui.option",
  "ui.key",
  "ui.message",
  "ui.overlay",
  "ui.dock",
  "ui.controls",
  "ui.showOptions"
];
var events = [
  "play",
  "pause",
  "ended",
  "seek",
  "time",
  "bar",
  "chapter",
  "recording",
  "speed",
  "view",
  "captions",
  "barNumbers",
  "instruments",
  "resize",
  "theme",
  "controls",
  "options",
  "click"
];
var icons = [
  "play",
  "pause",
  "stop",
  "previous",
  "next",
  "rewind",
  "forward",
  "replay",
  "loop",
  "shuffle",
  "volume",
  "mute",
  "fullscreen",
  "exitFullscreen",
  "link",
  "share",
  "copy",
  "download",
  "info",
  "help",
  "settings",
  "bookmark",
  "star",
  "heart",
  "search",
  "list",
  "text",
  "captions",
  "music",
  "piano",
  "clock",
  "show",
  "hide",
  "zoomIn",
  "zoomOut",
  "close",
  "check",
  "add",
  "remove",
  "more",
  "language"
];
var features = new Set([...members, ...events.map((e) => `event:${e}`), ...icons.map((i) => `icon:${i}`)]);
function start(bridge, page) {
  const call = (method, ...args) => {
    const answer = bridge.call(method, args);
    if (answer.error !== undefined)
      throw new Error(answer.error);
    return answer.ok;
  };
  const info = call("page");
  const listeners = new Map;
  const presses = new Map;
  const changes = new Map;
  const failed = (plugin, doing, error) => console.error(`Curator: the plugin ${plugin.spec.name} failed in ${doing}.`, error);
  function tell(event, data) {
    for (const { plugin, fn } of [...listeners.get(event) ?? []]) {
      try {
        fn(data);
      } catch (error) {
        failed(plugin, `"${event}"`, error);
      }
    }
  }
  function emit(event, data) {
    switch (event) {
      case "ui.press":
      case "ui.key":
        presses.get(data.id)?.();
        return false;
      case "ui.change":
        changes.get(data.id)?.(data.value);
        return false;
      case "click": {
        let prevented = false;
        const click = { x: data.x, y: data.y, quarter: data.quarter ?? null, preventDefault: () => void (prevented = true) };
        tell(event, click);
        return prevented;
      }
      case "resize":
        place();
        break;
      case "options":
        for (const { element, over } of overlays)
          if (over === "frame")
            element.style.visibility = data.open ? "hidden" : "";
        break;
    }
    tell(event, data);
    return false;
  }
  const root = document.createElement("div");
  root.id = "curator-plugins";
  root.style.cssText = "position:fixed;inset:0;z-index:1;pointer-events:none;";
  document.body.appendChild(root);
  const overlays = [];
  const docks = [];
  function colours() {
    const theme = call("view.theme");
    root.style.setProperty("--curator-paper", theme.paper);
    root.style.setProperty("--curator-ink", theme.ink);
    root.style.colorScheme = theme.dark ? "dark" : "light";
    return theme;
  }
  colours();
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => tell("theme", colours()));
  function place() {
    const frame = call("view.frame");
    for (let i = overlays.length - 1;i >= 0; i--) {
      const { element, over } = overlays[i];
      if (!element.isConnected) {
        overlays.splice(i, 1);
      } else if (over === "frame") {
        Object.assign(element.style, { left: `${frame.x}px`, top: `${frame.y}px`, width: `${frame.width}px`, height: `${frame.height}px` });
      }
    }
  }
  function layout() {
    const room = { left: 0, top: 0, right: 0, bottom: 0 };
    for (const dock of docks)
      room[dock.edge] += dock.size;
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
  let serial = 0;
  function curatorOf(plugin) {
    const { spec } = plugin, name = spec.name;
    const base = new URL(`${spec.folder}/`, document.baseURI);
    const id = () => `${spec.id}#${++serial}`;
    const fill = (text, values) => values ? text.replace(/\{(\w+)\}/g, (whole, name) => (name in values) ? String(values[name]) : whole) : text;
    const tr = (text, values) => fill(plugin.texts[text] ?? text, values);
    const trIn = (context, text, values) => fill(plugin.texts[`${context}|${text}`] ?? plugin.texts[text] ?? text, values);
    const guarded = (doing, fn) => (...args) => {
      try {
        fn(...args);
      } catch (error) {
        failed(plugin, doing, error);
      }
    };
    const undoable = (undo) => {
      const off = () => {
        if (plugin.undo.delete(off))
          undo();
      };
      plugin.undo.add(off);
      return off;
    };
    function on(event, fn) {
      if (typeof fn !== "function")
        throw new TypeError(`curator.on("${event}"): the listener isn’t a function`);
      let set = listeners.get(event);
      if (!set)
        listeners.set(event, set = new Set);
      const listener = { plugin, fn };
      set.add(listener);
      return undoable(() => set.delete(listener));
    }
    const prefix = `curator:${location.pathname}:${spec.id}:`;
    const memory = new Map;
    const kept = {
      read(key) {
        try {
          return localStorage.getItem(prefix + key);
        } catch {
          return memory.get(key) ?? null;
        }
      },
      write(key, value) {
        try {
          if (value === null)
            localStorage.removeItem(prefix + key);
          else
            localStorage.setItem(prefix + key, value);
        } catch {
          if (value === null)
            memory.delete(key);
          else
            memory.set(key, value);
        }
      }
    };
    const curator = {
      api: page.api,
      plugin: Object.freeze({ id: spec.id, name: spec.name, version: spec.version }),
      player: Object.freeze({ ...info.player }),
      language: plugin.language,
      settings: Object.freeze({ ...spec.settings }),
      storage: {
        get(key, fallback) {
          const text = kept.read(key);
          if (text === null)
            return fallback;
          try {
            return JSON.parse(text);
          } catch {
            return fallback;
          }
        },
        set: (key, value) => kept.write(key, JSON.stringify(value)),
        remove: (key) => kept.write(key, null)
      },
      page: Object.freeze({
        title: info.title,
        firstBar: info.firstBar,
        lastBar: info.lastBar,
        ratio: info.ratio,
        recordings: Object.freeze(info.recordings.map((r) => Object.freeze({ ...r })))
      }),
      playback: {
        get playing() {
          return call("playback.playing");
        },
        get time() {
          return call("playback.time");
        },
        get duration() {
          return call("playback.duration");
        },
        get musicEnd() {
          return call("playback.musicEnd");
        },
        play: () => call("playback.play"),
        pause: () => call("playback.pause"),
        toggle() {
          call(this.playing ? "playback.pause" : "playback.play");
        },
        seek: (seconds) => call("playback.seek", seconds),
        get speed() {
          return call("playback.speed");
        },
        set speed(value) {
          call("playback.setSpeed", value);
        },
        get recording() {
          return call("playback.recording");
        },
        set recording(index) {
          call("playback.setRecording", index);
        },
        get volume() {
          return call("playback.volume");
        },
        set volume(value) {
          call("playback.setVolume", value);
        },
        get muted() {
          return call("playback.muted");
        },
        set muted(value) {
          call("playback.setMuted", value);
        },
        get audio() {
          return bridge.audio() ?? null;
        }
      },
      view: {
        get shows() {
          return call("view.shows");
        },
        set shows(value) {
          call("view.setShows", value);
        },
        available: Object.freeze([...info.available]),
        get captions() {
          return call("view.captions");
        },
        set captions(on) {
          call("view.setCaptions", on);
        },
        get barNumbers() {
          return call("view.barNumbers");
        },
        set barNumbers(on) {
          call("view.setBarNumbers", on);
        },
        instruments: () => call("view.instruments"),
        show: (part, how) => call("view.show", part, how),
        can: (choice) => info.open[choice] === true,
        get frame() {
          return call("view.frame");
        },
        get theme() {
          return call("view.theme");
        },
        quarterAt: (x) => call("view.quarterAt", x) ?? null,
        xOf: (quarter) => call("view.xOf", quarter) ?? null
      },
      score: {
        get title() {
          return call("score.title");
        },
        get quarters() {
          return call("score.quarters");
        },
        bars: () => call("score.bars"),
        barAt: (quarter) => call("score.barAt", quarter),
        beatAt: (quarter) => call("score.beatAt", quarter),
        format: (quarter, compact) => call("score.format", quarter, compact ?? false),
        parse: (text) => call("score.parse", text) ?? null,
        seconds: (quarter, pass) => call("score.seconds", quarter, pass ?? 0),
        quarter: (seconds) => call("score.quarter", seconds),
        passAt: (seconds) => call("score.passAt", seconds),
        passes: () => call("score.passes"),
        spans: (places, end) => call("score.spans", places, end ?? null),
        rehearsalMarks: () => call("score.rehearsalMarks"),
        parts: () => call("score.parts"),
        notes: (part) => call("score.notes", part ?? null),
        chapters: () => call("score.chapters"),
        captions: () => call("score.captions")
      },
      ui: {
        button(spec) {
          const key = id(), state = { title: spec.title, icon: spec.icon, text: spec.text, checked: spec.checked ?? false, enabled: spec.enabled ?? true };
          const show = () => call("ui.button", { id: key, ...state, title: tr(state.title), icon: state.icon ?? null, text: state.text ?? null });
          show();
          presses.set(key, guarded(`the button ${spec.title}`, () => spec.run()));
          const remove = undoable(() => {
            presses.delete(key);
            call("ui.removeButton", key);
          });
          return {
            get title() {
              return state.title;
            },
            set title(value) {
              state.title = value;
              show();
            },
            get icon() {
              return state.icon;
            },
            set icon(value) {
              state.icon = value;
              show();
            },
            get text() {
              return state.text;
            },
            set text(value) {
              state.text = value;
              show();
            },
            get checked() {
              return state.checked;
            },
            set checked(value) {
              state.checked = value;
              show();
            },
            get enabled() {
              return state.enabled;
            },
            set enabled(value) {
              state.enabled = value;
              show();
            },
            remove
          };
        },
        option(spec) {
          const key = id();
          const state = { label: spec.label, value: spec.type === "action" ? undefined : spec.value, enabled: true };
          const show = () => call("ui.option", {
            id: key,
            group: name,
            type: spec.type,
            label: tr(state.label),
            value: state.value ?? null,
            options: spec.type === "choice" ? spec.options.map((o) => ({ value: o.value, label: tr(o.label) })) : [],
            enabled: state.enabled
          });
          show();
          if (spec.type === "action") {
            presses.set(key, guarded(`the option ${spec.label}`, () => spec.run()));
          } else {
            changes.set(key, guarded(`the option ${spec.label}`, (value) => {
              state.value = value;
              spec.change(value);
            }));
          }
          const remove = undoable(() => {
            presses.delete(key);
            changes.delete(key);
            call("ui.removeOption", key);
          });
          return {
            get label() {
              return state.label;
            },
            set label(value) {
              state.label = value;
              show();
            },
            get value() {
              return state.value;
            },
            set value(value) {
              if (spec.type !== "action") {
                state.value = value;
                show();
              }
            },
            get enabled() {
              return state.enabled;
            },
            set enabled(value) {
              state.enabled = value;
              show();
            },
            remove
          };
        },
        key(chord, run) {
          const key = id();
          call("ui.key", key, chord);
          presses.set(key, guarded(`the key ${chord}`, run));
          return undoable(() => {
            presses.delete(key);
            call("ui.removeKey", key);
          });
        },
        message: (text) => call("ui.message", String(text)),
        overlay(overlay) {
          const element = document.createElement("div"), over = overlay?.over ?? "frame";
          element.dataset.plugin = spec.id;
          element.style.cssText = `position:fixed;pointer-events:none;overflow:hidden;color:var(--curator-ink);${over === "page" ? "inset:0;" : ""}`;
          root.appendChild(element);
          overlays.push({ element, over });
          undoable(() => element.remove());
          place();
          return element;
        },
        dock(edge, size) {
          if (!["left", "right", "top", "bottom"].includes(edge))
            throw new TypeError(`curator.ui.dock: ${edge} isn’t an edge`);
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
            get size() {
              return dock.size;
            },
            set size(value) {
              dock.size = Math.max(0, Number(value) || 0);
              layout();
            },
            remove
          };
        },
        controls: {
          get visible() {
            return call("ui.controlsVisible");
          },
          get hidden() {
            return call("ui.controlsHidden");
          },
          set hidden(value) {
            call("ui.hideControls", value);
          }
        },
        showOptions: () => call("ui.showOptions")
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
      log: (...values) => console.log(`[${name}]`, ...values)
    };
    return curator;
  }
  function languageOf(locales) {
    const wanted = navigator.languages?.length ? navigator.languages : [navigator.language || "en"];
    const lower = new Map(locales.map((l) => [l.toLowerCase(), l]));
    for (const tag of wanted) {
      const t = tag.toLowerCase(), primary = t.split("-")[0];
      if (primary === "en")
        break;
      const chinese = primary === "zh" ? /hant|-(tw|hk|mo)\b/.test(t) ? "zh-hant" : "zh-hans" : null;
      const found = lower.get(t) ?? (chinese && lower.get(chinese)) ?? lower.get(primary) ?? locales.find((l) => l.toLowerCase().split("-")[0] === primary && !chinese);
      if (found)
        return { locale: found, language: found };
    }
    return { locale: null, language: wanted[0] };
  }
  async function boot(spec) {
    if (spec.api > page.api) {
      console.warn(`Curator: the plugin ${spec.name} needs a newer Curator (API level ${spec.api}; this player has ${page.api}).`);
      return;
    }
    const { locale, language } = languageOf(spec.locales ?? []);
    const plugin = { spec, texts: {}, language, undo: new Set };
    try {
      const base = new URL(`${spec.folder}/`, document.baseURI);
      if (locale) {
        try {
          const response = await fetch(new URL(`locales/${locale}.json`, base));
          if (response.ok)
            plugin.texts = await response.json();
        } catch (error) {
          console.warn(`Curator: the plugin ${spec.name} has no texts for ${locale}.`, error);
        }
      }
      const module = await import(new URL("main.js", base).href);
      if (typeof module.default !== "function")
        throw new Error("main.js has no default export to call");
      const curator = curatorOf(plugin);
      const started = module.default(curator);
      if (started instanceof Promise)
        started.catch((error) => failed(plugin, "starting", error));
    } catch (error) {
      console.error(`Curator: the plugin ${spec.name} couldn’t start.`, error);
      for (const undo of [...plugin.undo]) {
        try {
          undo();
        } catch {}
      }
    }
  }
  (async () => {
    for (const spec of page.plugins)
      await boot(spec);
  })();
  return { emit };
}
export {
  start
};
