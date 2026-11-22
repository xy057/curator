// Bar Counter: the bar that sounds (and its beat) in a corner of the score; a switch in
// Options turns it off.
import type { Curator } from "../../curator-web";

export default function (curator: Curator) {
  const { playback, score, ui, storage, settings } = curator;

  const overlay = ui.overlay();
  const badge = document.createElement("div");
  const corner = String(settings.corner ?? "topRight");
  Object.assign(badge.style, {
    position: "absolute",
    [corner.startsWith("top") ? "top" : "bottom"]: "12px",
    [corner.endsWith("Left") ? "left" : "right"]: "12px",
    padding: "4px 10px",
    borderRadius: "8px",
    font: "600 15px/1.4 system-ui, sans-serif",
    fontVariantNumeric: "tabular-nums",
    // The page's own colours, the other way round: ink under paper.
    background: "var(--curator-ink)",
    color: "var(--curator-paper)",
    opacity: "0.85",
  });
  overlay.appendChild(badge);

  let shown = storage.get<boolean>("shown") ?? true;
  const draw = () => {
    badge.style.display = shown ? "" : "none";
    if (!shown) return;
    const place = score.quarter(playback.time);
    // The bar's number alone, or with the beat that sounds: "12.3".
    const text = settings.beats ? score.format(score.beatAt(place).start) : String(score.barAt(place).number);
    if (badge.textContent !== text) badge.textContent = text;
  };
  curator.on("time", draw);
  curator.on("recording", draw);
  draw();

  ui.option({
    type: "switch",
    label: "Bar counter",
    value: shown,
    change(on) {
      shown = on;
      storage.set("shown", on);
      draw();
    },
  });
}
