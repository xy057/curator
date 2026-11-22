// Link to a Time: the page starts where its address says ("#t=83", "#t=1:23", "#bar=12"), and a
// button copies a link to where it is.
import type { Curator } from "../../curator-web";

export default function (curator: Curator) {
  const { playback, score, ui } = curator;

  /** The time an address's fragment names; null when it names none. */
  function timeOf(hash: string): number | null {
    const [key, value] = hash.replace(/^#/, "").split("=");
    if (key === "t" && value) {
      // Seconds, or minutes and seconds: "83", "1:23".
      const parts = value.split(":").map(Number);
      if (parts.some((n) => !Number.isFinite(n))) return null;
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
    if (time !== null) playback.seek(time);
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
        // A browser that keeps a page from the clipboard: the link, to copy by hand.
        ui.message(url.href);
      }
    },
  });
}
