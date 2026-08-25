#!/usr/bin/env node
// snapshot — capture a visual baseline of a site across viewports.
//
// Produces a dated folder of PNGs named from the URL and viewport, a manifest,
// and a contact sheet laying every page against every viewport. Names are
// stable, so a later run over the same URLs lines up file-for-file with an
// earlier one — which is what makes before/after comparison possible.
//
//   snapshot --url https://example.com --pages urls.txt
//   snapshot --url https://example.com --crawl --max 25
//   snapshot --url https://example.com --pages urls.txt --viewport desktop
//   snapshot --url https://example.com --pages urls.txt --only /products/
//   snapshot --url https://example.com --render-only
//
// Requires Chromium:  npx playwright install chromium

import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { capturePage, closeBrowser } from "./lib/capture.mjs";
import { renderContactSheet } from "./lib/contact-sheet.mjs";
import { mergeRows, pngSize } from "./lib/manifest.mjs";
import { makeShotName, runFolderName } from "./lib/naming.mjs";
import { VIEWPORT_ORDER, presetFor } from "./lib/viewports.mjs";

const args = process.argv.slice(2);
const flag = (name, fallback = null) => {
  const i = args.indexOf(`--${name}`);
  return i === -1 || !args[i + 1] ? fallback : args[i + 1];
};
const has = (name) => args.includes(`--${name}`);

function fail(message) {
  console.error(`\nFAIL: ${message}\n`);
  process.exit(1);
}

if (has("help") || args.length === 0) {
  console.log(
    [
      "snapshot — capture a visual baseline of a site across viewports",
      "",
      "  --url <rootUrl>        site to capture (required)",
      "  --pages <file>         newline-delimited paths or URLs; # comments allowed",
      "  --crawl                discover pages by following same-origin links instead",
      "  --max <n>              page cap for --crawl (default 25)",
      "  --depth <n>            link depth for --crawl (default 3)",
      "  --viewport <list>      all | desktop,tablet,mobile (default all)",
      "  --set <name>           subfolder + manifest grouping (default pages/crawl)",
      "  --only <substr>        capture just the matching URLs from --pages",
      "  --viewport-only        capture the fold instead of the whole page",
      "  --out <dir>            output root (default ./captures)",
      "  --render-only          rebuild the contact sheet from an existing manifest",
      "",
      "Requires Chromium:  npx playwright install chromium",
    ].join("\n"),
  );
  process.exit(0);
}

const rootUrl = flag("url");
if (!rootUrl) fail("--url is required, e.g. --url https://example.com");
try {
  new URL(rootUrl);
} catch {
  fail(`--url is not a valid URL: ${rootUrl}`);
}

const mode = has("crawl") ? "crawl" : "pages";
const set = flag("set", mode);
const outRoot = flag("out", path.join(process.cwd(), "captures"));
const runDir = path.join(outRoot, runFolderName(rootUrl, new Date().toISOString().slice(0, 10)));
const manifestPath = path.join(runDir, "manifest.json");

async function loadManifest() {
  try {
    return JSON.parse(await readFile(manifestPath, "utf8"));
  } catch {
    return { rootUrl, rows: [] };
  }
}

if (has("render-only")) {
  const manifest = await loadManifest();
  if (manifest.rows.length === 0) fail(`No manifest at ${manifestPath}`);
  await writeFile(path.join(runDir, "index.html"), renderContactSheet(manifest));
  console.log(`Rendered ${manifest.rows.filter((r) => r.file).length} shot(s) -> file://${path.join(runDir, "index.html")}`);
  process.exit(0);
}

// Same-origin, no fragments, no asset files. Trailing slash is dropped so "/a"
// and "/a/" do not both get captured.
function normalize(candidate) {
  try {
    const url = new URL(candidate, rootUrl);
    if (!["http:", "https:"].includes(url.protocol)) return null;
    if (url.origin !== new URL(rootUrl).origin) return null;
    if (/\.(jpe?g|png|gif|webp|svg|pdf|zip|mp4|webm|mov|mp3|xml|json|css|js)$/i.test(url.pathname)) return null;
    url.hash = "";
    if (url.pathname !== "/" && url.pathname.endsWith("/")) url.pathname = url.pathname.slice(0, -1);
    return url.toString();
  } catch {
    return null;
  }
}

let targets = [];
if (mode === "pages") {
  const pagesFile = flag("pages");
  if (!pagesFile) fail("--pages <file> is required unless --crawl is used");
  const raw = await readFile(pagesFile, "utf8").catch(() => fail(`Cannot read ${pagesFile}`));
  const requested = raw
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));

  const only = flag("only");
  const filtered = only ? requested.filter((line) => line.includes(only)) : requested;
  if (filtered.length === 0) fail(only ? `--only "${only}" matched nothing` : `No URLs in ${pagesFile}`);

  // A URL that normalizes away would otherwise vanish with no error, turning a
  // 13-page run into a 12-page one that still looks successful.
  const dropped = [];
  for (const line of filtered) {
    const normalized = normalize(line);
    if (!normalized) dropped.push(line);
    else if (!targets.includes(normalized)) targets.push(normalized);
  }
  if (dropped.length > 0) {
    for (const line of dropped) console.error(`  !!  ${line}  not same-origin as ${rootUrl}, or not a page`);
    fail(`${dropped.length} URL(s) cannot be captured.`);
  }
}

const viewportArg = flag("viewport", "all");
const viewportKeys = viewportArg === "all" ? VIEWPORT_ORDER : viewportArg.split(",").map((v) => v.trim());
for (const key of viewportKeys) {
  try {
    presetFor(key);
  } catch {
    fail(`Unknown --viewport "${key}". Use: all | ${VIEWPORT_ORDER.join(",")}`);
  }
}

const maxPages = Number(flag("max", 25));
const maxDepth = Number(flag("depth", 3));
const fullPage = !has("viewport-only");
const warn = (message) => console.error(`  warn: ${message}`);

await mkdir(path.join(runDir, set), { recursive: true });
await mkdir(path.join(runDir, "raw"), { recursive: true });

let manifest = await loadManifest();
let exitCode = 0;

for (const key of viewportKeys) {
  const preset = presetFor(key);
  const viewport = { width: preset.width, height: preset.height, deviceScaleFactor: 1 };
  console.log(`\n-> ${set} / ${preset.label}`);
  const startedAt = Date.now();

  // Crawl mode discovers as it goes; pages mode has its list up front. Both
  // walk a queue so the capture loop below is identical.
  const queue = mode === "crawl" ? [{ url: normalize(rootUrl), depth: 0 }] : targets.map((url) => ({ url, depth: 0 }));
  const seen = new Set(queue.map((job) => job.url));
  const rows = [];
  const rawPages = [];

  while (queue.length > 0 && rows.length < (mode === "crawl" ? maxPages : targets.length)) {
    const job = queue.shift();
    const shotName = makeShotName({ url: job.url, viewport });
    const requestPath = new URL(job.url).pathname + new URL(job.url).search;

    try {
      const shot = await capturePage({
        url: job.url,
        viewport,
        fullPage,
        collectLinks: mode === "crawl" && job.depth < maxDepth,
        onWarn: warn,
      });

      await writeFile(path.join(runDir, set, shotName), shot.buffer);
      const { width, height } = pngSize(shot.buffer);
      rows.push({
        set,
        viewport: key,
        viewportLabel: preset.label,
        path: requestPath,
        url: job.url,
        status: "visited",
        httpStatus: shot.httpStatus,
        title: shot.title || null,
        file: path.posix.join(set, shotName),
        bytes: shot.buffer.length,
        width,
        height,
      });
      rawPages.push({
        url: job.url,
        path: requestPath,
        title: shot.title,
        httpStatus: shot.httpStatus,
        depth: job.depth,
        screenshotPath: path.posix.join(set, shotName),
        externalDomains: shot.externalDomains,
      });

      const mark = shot.httpStatus === 200 ? " ok " : ` ${shot.httpStatus} `;
      console.log(`  ${mark} ${requestPath.padEnd(52)} ${width}x${height}`);

      for (const href of shot.links) {
        const next = normalize(href);
        if (next && !seen.has(next) && seen.size < maxPages * 4) {
          seen.add(next);
          queue.push({ url: next, depth: job.depth + 1 });
        }
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      rows.push({
        set,
        viewport: key,
        viewportLabel: preset.label,
        path: requestPath,
        url: job.url,
        status: "failed",
        httpStatus: null,
        title: null,
        error: message,
      });
      console.error(`  !!  ${requestPath.padEnd(52)} ${message.split("\n")[0]}`);
      exitCode = 1;
    }
  }

  console.log(`  ${((Date.now() - startedAt) / 1000).toFixed(0)}s`);

  await writeFile(
    path.join(runDir, "raw", `${set}-${preset.label}.json`),
    JSON.stringify({ rootUrl, set, mode, viewport, capturedAt: new Date().toISOString(), pages: rawPages }, null, 2),
  );

  manifest = mergeRows(manifest, rows);
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2));
  await writeFile(path.join(runDir, "index.html"), renderContactSheet(manifest));
}

await closeBrowser();

const total = manifest.rows.filter((row) => row.file).length;
console.log(`\n${total} shot(s) in ${runDir}`);
console.log(`Review sheet: file://${path.join(runDir, "index.html")}`);
process.exit(exitCode);
