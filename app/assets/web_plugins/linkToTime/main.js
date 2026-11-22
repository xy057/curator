// Built from app/assets/web_plugins/linkToTime/src/main.ts by `make web-plugins`: change that, not this.
// app/assets/web_plugins/linkToTime/src/main.ts
function main_default(curator) {
  const { playback, score, ui } = curator;
  function timeOf(hash) {
    const [key, value] = hash.replace(/^#/, "").split("=");
    if (key === "t" && value) {
      const parts = value.split(":").map(Number);
      if (parts.some((n) => !Number.isFinite(n)))
        return null;
      return parts.reduce((total, n) => total * 60 + n, 0);
    }
    if (key === "bar" && value) {
      const place = score.parse(value);
      return place === null ? null : score.seconds(place);
    }
    return null;
  }
  const go = () => {
    const time = timeOf(location.hash);
    if (time !== null)
      playback.seek(time);
  };
  go();
  addEventListener("hashchange", go);
  ui.button({
    title: "Copy Link to Here",
    icon: "link",
    run: async () => {
      const url = new URL(location.href);
      url.hash = curator.settings.bars ? `bar=${score.format(score.quarter(playback.time), true)}` : `t=${Math.floor(playback.time)}`;
      try {
        await navigator.clipboard.writeText(url.href);
        ui.message(curator.tr("Link copied"));
      } catch {
        ui.message(url.href);
      }
    }
  });
}
export {
  main_default as default
};
