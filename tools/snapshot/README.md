# snapshot

Capture a visual baseline of a site across viewports.

Produces a dated folder of PNGs named from the URL and viewport, a manifest, and
a contact sheet laying every page against every viewport. Names are stable, so a
later run over the same URLs lines up file-for-file with an earlier one — which
is what makes before/after comparison possible at all.

Self-contained: Node plus Playwright, no server and no other service.

## Setup

```sh
cd tools/snapshot
npm install
npx playwright install chromium
```

## Use

```sh
# a known list of pages, all three viewports
node snapshot.mjs --url https://example.com --pages urls.txt

# discover pages by following same-origin links
node snapshot.mjs --url https://example.com --crawl --max 25

# one viewport, one page — the loop to use while checking a fix
node snapshot.mjs --url https://example.com --pages urls.txt --viewport desktop --only /pricing

# rebuild the contact sheet without re-capturing
node snapshot.mjs --url https://example.com --render-only
```

`urls.txt` is newline-delimited paths or full URLs; `#` starts a comment.

```
# key pages
/
/pricing
/products/widget
```

## Output

```
captures/2026-08-25-example.com/
  pages/       example.com__pricing__desktop-1440.png, …
  raw/         per-viewport JSON: HTTP status, third-party domains
  manifest.json
  index.html   contact sheet — page x viewport
```

Filenames are `<host>__<path-slug>__<viewport>-<width>.png`. The slug comes from
the URL, not the page title: titles get edited between runs and would break the
correspondence. The query string is kept so `?q=` variants stay distinct.

`index.html` references the PNGs by relative path, so it opens straight off disk
— but it has to stay next to the folders it references.

## Why the capture is not just goto-and-screenshot

Each of these was a wrong screenshot before it was a line of code.

- **Lazy images.** Below-the-fold `loading="lazy"` images never enter the
  viewport during a full-page capture, so they render blank. The tool forces
  them eager and scrolls the page before shooting.
- **`scroll-behavior: smooth`.** A single `scrollTo(0, 0)` lands part-way up the
  page, and shooting from there smears sticky headers down the whole image. The
  scroll-to-top is polled until it actually reaches zero.
- **`animation: none` is a trap.** Reveal-on-scroll elements often have
  `opacity: 0` as their base style with a keyframe animating to 1, so disabling
  animations blanks them. Playwright's `animations: "disabled"` fast-forwards to
  the end state instead, which is what a baseline wants.
- **`networkidle` never fires** on sites with analytics polling or a chat
  widget, so it only ever costs the full timeout. Polling the images themselves
  is the deterministic equivalent.
- **Marketing popups are delay-triggered**, so a longer settle makes them *more*
  likely to appear. They are suppressed last, immediately before the shot, and
  only when `position: fixed` — which spares legitimate inline embeds sharing
  the same class prefix. Anything still covering a quarter of the viewport is
  logged as a warning, so a contaminated shot is noticed during the run rather
  than at review.

## Notes

- Very tall pages are fine at `deviceScaleFactor: 1` — a 23,512px mobile page
  captures complete. At 2x the same page is 47,024px, which is unwieldy
  everywhere downstream. Use a separate `--viewport-only` pass at 2x if you need
  legible small type for a specific callout.
- Tablet at 768 sits above the usual 750px "not a phone" breakpoint but below
  the ~990px "show the full nav" one, so many themes render an intermediate
  state there: hamburger menu with a wide layout. That is genuinely what a
  tablet shows.
- Pages are captured one at a time. The bottleneck is the deliberate settle
  waits, not concurrency — roughly 3–5s per page.
- The tool captures pages. It cannot step through an interactive flow such as a
  quiz or a checkout; for those, drive the browser directly.
