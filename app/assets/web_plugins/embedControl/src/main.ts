// Embed Control: a page in an <iframe> of another site is played from that site by
// postMessage, and tells it what happens.
import type { Curator, Shows } from "../../curator-web";

export default function (curator: Curator) {
  if (parent === window) return; // not in a frame: no one to hear from
  const { playback, view, score } = curator;
  // The one site that may play the page; "*": any.
  const site = String(curator.settings.origin || "*").replace(/\/+$/, "");
  const allowed = (origin: string) => site === "*" || origin === site;

  const state = () => ({
    curator: "state",
    playing: playback.playing,
    time: playback.time,
    duration: playback.duration,
    speed: playback.speed,
    recording: playback.recording,
    shows: view.shows,
    bar: score.barAt(score.quarter(playback.time)).number,
  });
  const say = (message: object) => parent.postMessage(message, site);
  const tell = () => say(state());

  addEventListener("message", (event) => {
    const data = event.data as { curator?: string; value?: unknown } | null;
    if (!allowed(event.origin) || typeof data?.curator !== "string") return;
    const value = data.value;
    try {
      switch (data.curator) {
        case "play": playback.play(); break;
        case "pause": playback.pause(); break;
        case "toggle": playback.toggle(); break;
        case "seek": playback.seek(Number(value)); break;
        case "bar": {
          const place = score.parse(String(value));
          if (place !== null) playback.seek(score.seconds(place));
          break;
        }
        case "speed": playback.speed = Number(value); break;
        case "recording": playback.recording = Number(value); break;
        case "shows": view.shows = value as Shows; break;
        case "state": tell(); break;
      }
    } catch (error) {
      // Something the page hasn't (a recording, a view): said, not done.
      say({ curator: "error", message: String(error instanceof Error ? error.message : error) });
    }
  });

  for (const event of ["play", "pause", "seek", "speed", "recording", "view", "bar"] as const) curator.on(event, tell);
  curator.on("ended", () => say({ curator: "ended" }));
  // The time as it plays, four times a second.
  let told = 0;
  curator.on("time", () => {
    const now = performance.now();
    if (now - told < 250) return;
    told = now;
    tell();
  });
  tell();
}
