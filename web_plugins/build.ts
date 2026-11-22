// Builds the web player's plugin host and Curator's own web plugins from their TypeScript
// (`make web-plugins`; run with bun from the repository's root):
//
//   web_plugins/host.ts                           → app/web/plugin_host.js
//   app/assets/web_plugins/<id>/src/main.ts       → app/assets/web_plugins/<id>/main.js
//
// What it writes is in git, so that building the web player needs no TypeScript; then it
// writes down what it was built from and what it built (web_plugins/sources.sha256), which the
// tests check (app/test/in_step_test.dart): a source changed and not built again fails there.
import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const plugins = "app/assets/web_plugins";
const ids = readdirSync(plugins).filter((name) => statSync(join(plugins, name)).isDirectory()).sort();
const builds = [{ from: "web_plugins/host.ts", to: "app/web/plugin_host.js" }, ...ids.map((id) => ({ from: `${plugins}/${id}/src/main.ts`, to: `${plugins}/${id}/main.js` }))];

for (const { from, to } of builds) {
  const built = await Bun.build({ entrypoints: [from], target: "browser", format: "esm" });
  if (!built.success) {
    for (const log of built.logs) console.error(log);
    process.exit(1);
  }
  const head = `// Built from ${from} by \`make web-plugins\`: change that, not this.\n`;
  writeFileSync(to, head + (await built.outputs[0].text()));
  console.log(to);
}

/** Every file under [folder] with a name [keep] takes, by path, in order. */
function files(folder: string, keep: (path: string) => boolean): string[] {
  const out: string[] = [];
  for (const name of readdirSync(folder).sort()) {
    const path = join(folder, name);
    if (statSync(path).isDirectory()) out.push(...files(path, keep));
    else if (keep(path)) out.push(path);
  }
  return out;
}

/** The files at [paths] as one number: each one's path, then its own. */
function seal(paths: string[]): string {
  const all = createHash("sha256");
  for (const path of paths) all.update(`${path}\n${createHash("sha256").update(readFileSync(path)).digest("hex")}\n`);
  return all.digest("hex");
}

const sources = ["web_plugins/host.ts", ...files(plugins, (path) => path.endsWith(".ts"))].sort();
const built = builds.map((b) => b.to).sort();
writeFileSync("web_plugins/sources.sha256", `sources ${seal(sources)}\nbuilt ${seal(built)}\n`);
