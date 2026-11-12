---
name: site-visual-baseline
description: Capture a reproducible visual record of a website across viewports — for before/after comparison, design-degradation evidence, QA rounds, client onboarding, or competitive teardowns. Use when asked to screenshot a site, capture pages at desktop/tablet/mobile, build a before-and-after set, document how a site looks today, or gather visual evidence of layout, contrast, or consistency problems. Covers the capture traps that silently produce wrong screenshots.
effort: medium
---

# Site Visual Baseline

Produce a screenshot set someone can act on: complete, faithful, and named so a
later run lines up against it. The failure mode is not a crash — it is a set of
screenshots that look fine and are quietly wrong, which then get used as
evidence.

## Operating principles

**A baseline is a pair, or it is nothing.** The value is in the comparison, so
filenames must be stable across runs. Derive them from the URL and viewport,
never from the page title (clients edit titles) or list position (lists change).
`<host>__<path-slug>__<viewport>-<width>.png`.

**Verify one shot before capturing eighty.** Capture a single page, open the
PNG, and look at it. Then run the set. A bad settle recipe produces eighty bad
shots just as fast as one.

**Distinguish a site defect from a capture artifact.** Washed-out text, missing
images, and half-rendered sections all have two possible causes. Before
reporting one as a finding, measure it: read `getComputedStyle` for the element
and check `opacity`, `color`, and `animationName`. If `opacity` is 1 and there
is no running animation, it is the site. If not, it is the capture, and the
screenshots are not yet trustworthy.

## Tooling

**Site Snapshot Explorer** (`snapshot.emergentlabs.xyz`) implements everything
below: same-origin crawl, three viewports, stable URL-derived filenames, a
manifest, and a contact sheet laying every page against every viewport. Stable
names are what make before/after comparison possible — a later run over the
same URLs lines up file-for-file with an earlier one.

Run it from its own checkout (`npm run dev`, then the UI or
`scripts/capture-run.mjs`), or use the deployed instance.

Where that is unavailable, drive Playwright directly and implement the same
settle sequence — the traps below are properties of the web, not of any one
tool, and a hand-rolled capture hits every one of them.

## The settle sequence

Naive `goto` then `screenshot` is wrong on most real sites. In order:

1. Wait for `load`, bounded and non-fatal.
2. Inject CSS zeroing `transition-duration` and forcing `scroll-behavior: auto`.
3. Flip every `img[loading="lazy"]` to `eager`.
4. Scroll to the bottom in viewport-sized steps.
5. **Poll `scrollY` back to 0** until it actually reaches zero.
6. Poll until every laid-out image reports `complete`; then `document.fonts.ready`, capped.
7. Short paint settle.
8. Suppress marketing overlays — last, immediately before the shot.
9. Screenshot with `animations: "disabled"` and `caret: "hide"`.

Set `reducedMotion: "reduce"` on the browser context: many themes gate
reveal-on-scroll animations behind that media query, which makes the content
visible without depending on scroll timing.

## Traps

**Lazy images render blank.** Below-the-fold `loading="lazy"` images never enter
the viewport during a full-page capture. Scrolling alone is not always enough;
force them eager *and* scroll, then wait on `img.complete`.

**`animation: none` blanks content.** Reveal-on-scroll elements commonly have
`opacity: 0` as their base style with a keyframe animating to 1. Disabling
animations snaps them back to invisible and silently removes whole sections.
Playwright's `animations: "disabled"` fast-forwards keyframes to their end state
— use that, never the CSS override.

**`scroll-behavior: smooth` smears sticky headers.** One `scrollTo(0, 0)` lands
part-way up the page. Capturing from there repeats or streaks the sticky header
down the full-page image. Poll until `scrollY === 0`.

**`networkidle` may never fire.** Analytics polling and chat widgets keep the
network busy indefinitely, so waiting on it costs the whole timeout and buys
nothing. Poll the images instead.

**Popups are delay-triggered.** A longer settle makes an email-capture overlay
*more* likely to appear, not less. Suppress last. Match by vendor selector and
require `position: fixed`, so inline embeds sharing a class prefix survive. They
are often intermittent — appearing on every load in one session and none in the
next — so also detect: log anything still covering >25% of the viewport, and
treat a silent run as the only clean run.

**Very tall pages.** Full-page mobile captures of long pages reach 20,000px+ and
are fine at `deviceScaleFactor: 1`. At 2x they double again and become unwieldy
in every downstream tool. Keep full-page at 1x; if legible small type is needed
for a specific callout, take a separate viewport-only pass at 2x. Check the
bottom rows of a tall PNG once — a truncated capture fails silently, as a black
or blank tail rather than an error.

**Interactive flows cannot be crawled.** A quiz, checkout, or wizard lives at
one URL, so a crawler only ever captures step 1. Drive those with browser
automation, stepping and shooting each screen. **Stop at any email or phone
capture and never submit** — submitting creates a real lead in the client's
marketing system.

## Choosing viewports

Desktop 1440x900, tablet 768x1024, mobile 390x844 covers the common
breakpoints. Note 768 sits above the usual 750px "not a phone" breakpoint but
below the ~990px "full nav" one, so many themes render an intermediate state
there — hamburger menu with a wide layout. That is what a tablet genuinely
shows; it is not a capture bug.

## Reporting findings

Quantify rather than describe. "Text is hard to read" is an opinion; "contrast
ratio 1.10:1 against WCAG AA's 4.5:1 minimum, cream `#F4F1E8` at 75% on white"
is a finding a client cannot argue with. Compute contrast from the actual
computed color and the sampled background pixel.

Pixel height is itself a signal — a 23,512px mobile homepage is a finding, not a
footnote. So is a page returning HTTP 200 with almost no content, or one missing
its `<header>` and `<footer>` entirely.

Record the third-party request domains per page while capturing. It costs
nothing and it is the evidence behind any claim about page weight.

## Verify before delivering

- Open at least one full-page PNG per viewport and actually look at it.
- Check the bottom of the tallest page for a truncated tail.
- Confirm the header appears once, not repeated down the image.
- Confirm no overlay tint, and that the run logged no overlay warnings.
- Confirm every requested URL produced a file. URL normalization silently drops
  cross-origin and asset URLs, so a 13-page request can quietly return 12.
  Diff requested against returned and fail loudly.
- Never `rm -rf` the output directory to tidy up between test runs. It is the
  deliverable.
