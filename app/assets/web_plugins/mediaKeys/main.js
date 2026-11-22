// Built from app/assets/web_plugins/mediaKeys/src/main.ts by `make web-plugins`: change that, not this.
// app/assets/web_plugins/mediaKeys/src/main.ts
function main_default(curator) {
  const session = navigator.mediaSession;
  if (!session)
    return;
  const { playback, page, score } = curator;
  const describe = () => {
    session.metadata = new MediaMetadata({ title: page.title, artist: page.recordings[playback.recording]?.label ?? "", album: score.title });
  };
  const stops = () => {
    const chapters = score.chapters();
    if (chapters.length > 0)
      return chapters.map((c) => c.start);
    return score.spans(score.rehearsalMarks().map((m) => m.at)).map((s) => s.from);
  };
  const step = (by) => {
    const all = stops(), now = playback.time;
    const next = by > 0 ? all.find((t) => t > now + 0.5) : [...all].reverse().find((t) => t < now - 2);
    playback.seek(next ?? (by > 0 ? playback.duration : 0));
  };
  session.setActionHandler("play", () => playback.play());
  session.setActionHandler("pause", () => playback.pause());
  session.setActionHandler("seekbackward", (details) => playback.seek(playback.time - (details.seekOffset ?? 10)));
  session.setActionHandler("seekforward", (details) => playback.seek(playback.time + (details.seekOffset ?? 10)));
  session.setActionHandler("seekto", (details) => {
    if (details.seekTime != null)
      playback.seek(details.seekTime);
  });
  if (stops().length > 0) {
    session.setActionHandler("previoustrack", () => step(-1));
    session.setActionHandler("nexttrack", () => step(1));
  }
  const tell = () => {
    session.playbackState = playback.playing ? "playing" : "paused";
    const duration = playback.duration;
    if (duration > 0)
      session.setPositionState({ duration, playbackRate: playback.speed, position: Math.min(Math.max(playback.time, 0), duration) });
  };
  for (const event of ["play", "pause", "seek", "speed", "ended"])
    curator.on(event, tell);
  curator.on("recording", () => {
    describe();
    tell();
  });
  describe();
  tell();
}
export {
  main_default as default
};
