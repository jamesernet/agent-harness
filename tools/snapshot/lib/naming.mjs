import { viewportLabel } from "./viewports.mjs";

// Filenames come from the URL and the viewport, never from the page title or
// the position in the run. That is what lets a later "after" capture line up
// file-for-file with an earlier baseline: titles get edited and list positions
// shift, but a URL is stable.
//
//   alchemypet.com__collections-products__desktop-1440.png
//   alchemypet.com__home__mobile-390.png

export function makeShotName({ url, viewport }) {
  const parsed = new URL(url);
  const host = parsed.hostname.replace(/^www\./, "");
  return `${host}__${pathSlug(parsed)}__${viewportLabel(viewport)}.png`;
}

/** Root path becomes "home"; the query string is kept so `?q=` variants stay distinct. */
export function pathSlug(url) {
  const raw = `${url.pathname}${url.search}`.replace(/^\/+|\/+$/g, "");
  return (
    raw
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 150) || "home"
  );
}

export function runFolderName(rootUrl, date) {
  const host = new URL(rootUrl).hostname.replace(/^www\./, "");
  return `${date}-${host}`;
}
