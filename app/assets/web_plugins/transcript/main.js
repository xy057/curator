// Built from app/assets/web_plugins/transcript/src/main.ts by `make web-plugins`: change that, not this.
// app/assets/web_plugins/transcript/src/main.ts
var width = 300;
function main_default(curator) {
  const { playback, score, ui, storage } = curator;
  let captions = score.captions();
  if (captions.length === 0)
    return;
  const side = curator.settings.side === "left" ? "left" : "right";
  let dock = null;
  let rows = [];
  let marked = -1;
  const plain = (caption) => caption.text.replace(/\\\*/g, "\x00").replace(/\*+/g, "").replace(/\u0000/g, "*");
  const clock = (seconds) => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, "0")}`;
  function open() {
    dock = ui.dock(side, Math.min(width, innerWidth / 2));
    const panel = dock.element;
    Object.assign(panel.style, {
      font: "14px/1.45 system-ui, sans-serif",
      padding: "12px 0",
      [side === "left" ? "borderRight" : "borderLeft"]: "1px solid color-mix(in srgb, var(--curator-ink) 18%, transparent)"
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
  function close() {
    dock?.remove();
    dock = null;
    rows = [];
  }
  function mark() {
    if (!dock)
      return;
    const now = playback.time;
    const index = captions.findIndex((c) => now >= c.start && now < c.end);
    if (index === marked)
      return;
    if (marked >= 0)
      rows[marked].style.background = "";
    marked = index;
    if (index < 0)
      return;
    rows[index].style.background = "color-mix(in srgb, var(--curator-ink) 12%, transparent)";
    rows[index].scrollIntoView({ block: "nearest", behavior: "smooth" });
  }
  const button = ui.button({ title: "Transcript", icon: "list", checked: false, run: toggle });
  function toggle() {
    if (dock)
      close();
    else
      open();
    button.checked = dock !== null;
    storage.set("open", dock !== null);
  }
  ui.key("t", toggle);
  curator.on("time", mark);
  curator.on("recording", () => {
    captions = score.captions();
    if (dock) {
      close();
      open();
    }
  });
  if (storage.get("open", true))
    toggle();
}
export {
  main_default as default
};
