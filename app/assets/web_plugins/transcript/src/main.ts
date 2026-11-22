// Transcript: the page's captions as a list beside the score. The one that shows is marked; a
// click on one goes to it.
import type { Caption, Curator, Dock } from "../../curator-web";

const width = 300;

export default function (curator: Curator) {
  const { playback, score, ui, storage } = curator;
  let captions = score.captions();
  if (captions.length === 0) return; // a page without captions: nothing to list

  const side = curator.settings.side === "left" ? "left" : "right";
  let dock: Dock | null = null;
  let rows: HTMLElement[] = [];
  let marked = -1;

  /** A caption as plain text: its *italic* and **bold** markers taken out. */
  const plain = (caption: Caption) => caption.text.replace(/\\\*/g, "\u0000").replace(/\*+/g, "").replace(/\u0000/g, "*");
  const clock = (seconds: number) => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, "0")}`;

  function open(): void {
    dock = ui.dock(side, Math.min(width, innerWidth / 2));
    const panel = dock.element;
    Object.assign(panel.style, {
      font: "14px/1.45 system-ui, sans-serif",
      padding: "12px 0",
      [side === "left" ? "borderRight" : "borderLeft"]: "1px solid color-mix(in srgb, var(--curator-ink) 18%, transparent)",
    });
    rows = captions.map((caption) => {
      const row = document.createElement("div");
      row.style.cssText = "display:flex;gap:10px;padding:6px 14px;cursor:pointer;";
      const time = document.createElement("span");
      time.textContent = clock(caption.start);
      time.style.cssText = "flex:none;opacity:0.55;font-variant-numeric:tabular-nums;";
      const text = document.createElement("span");
      text.textContent = plain(caption);
      row.append(time, text);
      row.addEventListener("click", () => playback.seek(caption.start));
      panel.appendChild(row);
      return row;
    });
    marked = -1;
    mark();
  }

  function close(): void {
    dock?.remove();
    dock = null;
    rows = [];
  }

  /** Marks the caption that shows, and keeps it in sight. */
  function mark(): void {
    if (!dock) return;
    const now = playback.time;
    const index = captions.findIndex((c) => now >= c.start && now < c.end);
    if (index === marked) return;
    if (marked >= 0) rows[marked].style.background = "";
    marked = index;
    if (index < 0) return;
    rows[index].style.background = "color-mix(in srgb, var(--curator-ink) 12%, transparent)";
    rows[index].scrollIntoView({ block: "nearest", behavior: "smooth" });
  }

  const button = ui.button({ title: "Transcript", icon: "list", checked: false, run: toggle });
  function toggle(): void {
    if (dock) close();
    else open();
    button.checked = dock !== null;
    storage.set("open", dock !== null);
  }
  ui.key("t", toggle);

  curator.on("time", mark);
  // Another recording plays the captions at other times.
  curator.on("recording", () => {
    captions = score.captions();
    if (dock) {
      close();
      open();
    }
  });

  if (storage.get("open", true)) toggle();
}
