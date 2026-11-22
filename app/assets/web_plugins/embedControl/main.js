// Built from app/assets/web_plugins/embedControl/src/main.ts by `make web-plugins`: change that, not this.
// app/assets/web_plugins/embedControl/src/main.ts
function main_default(curator) {
  if (parent === window)
    return;
  const { playback, view, score } = curator;
  const site = String(curator.settings.origin || "*").replace(/\/+$/, "");
  const allowed = (origin) => site === "*" || origin === site;
  const state = () => ({
    curator: "state",
    playing: playback.playing,
    time: playback.time,
    duration: playback.duration,
    speed: playback.speed,
    recording: playback.recording,
    shows: view.shows,
    bar: score.barAt(score.quarter(playback.time)).number
  });
  const say = (message) => parent.postMessage(message, site);
  const tell = () => say(state());
  addEventListener("message", (event) => {
    const data = event.data;
    if (!allowed(event.origin) || typeof data?.curator !== "string")
      return;
    const value = data.value;
    try {
      switch (data.curator) {
        case "play":
          playback.play();
          break;
        case "pause":
          playback.pause();
          break;
        case "toggle":
          playback.toggle();
          break;
        case "seek":
          playback.seek(Number(value));
          break;
        case "bar": {
          const place = score.parse(String(value));
          if (place !== null)
            playback.seek(score.seconds(place));
          break;
        }
        case "speed":
          playback.speed = Number(value);
          break;
        case "recording":
          playback.recording = Number(value);
          break;
        case "shows":
          view.shows = value;
          break;
        case "state":
          tell();
          break;
      }
    } catch (error) {
      say({ curator: "error", message: String(error instanceof Error ? error.message : error) });
    }
  });
  for (const event of ["play", "pause", "seek", "speed", "recording", "view", "bar"])
    curator.on(event, tell);
  curator.on("ended", () => say({ curator: "ended" }));
  let told = 0;
  curator.on("time", () => {
    const now = performance.now();
    if (now - told < 250)
      return;
    told = now;
    tell();
  });
  tell();
}
export {
  main_default as default
};
