// The capture engine. Everything here exists because a naive
// `goto` + `waitForTimeout` + `screenshot` produces screenshots that look
// plausible and are wrong — see the comments on each step.

const GOTO_TIMEOUT_MS = 45_000;
const ACTION_TIMEOUT_MS = 60_000;
const LOAD_EVENT_BUDGET_MS = 12_000;
const SCROLL_BUDGET_MS = 15_000;
const SCROLL_STEP_PAUSE_MS = 110;
const SCROLL_TOP_BUDGET_MS = 3_000;
const IMAGE_BUDGET_MS = 15_000;
const FONT_BUDGET_MS = 3_000;
const PAINT_SETTLE_MS = 400;
const SCREENSHOT_TIMEOUT_MS = 120_000;

// `animation: none` is a trap: reveal-on-scroll elements commonly have
// `opacity: 0` as their BASE style with a keyframe animating to 1, so killing
// the animation snaps them back to invisible and silently blanks whole
// sections. Playwright's `animations: "disabled"` fast-forwards keyframes to
// their END state instead, which is what a baseline shot wants. So only
// transitions and smooth scrolling are neutralised here.
const STABILIZE_CSS = `
  *, *::before, *::after {
    transition-duration: 0s !important;
    transition-delay: 0s !important;
  }
  html, body { scroll-behavior: auto !important; }
`;

// Marketing overlays that cover the page. Suppressed by exact selector rather
// than a generic "hide anything fixed" sweep, which would also hide real UI.
const VENDOR_OVERLAY_SELECTOR = [
  '[class*="kl-private-reset-css-"]', // Klaviyo popup
  '[class*="klaviyo-form"]',
  "#gfp_popup_container", // goaffpro
  "#onetrust-consent-sdk",
  "#CybotCookiebotDialog",
  ".osano-cm-window",
  "#usercentrics-root",
].join(", ");

let browserPromise = null;

export async function getBrowser() {
  if (!browserPromise) {
    browserPromise = import("playwright")
      .then(({ chromium }) => chromium.launch({ headless: true }))
      .catch((error) => {
        browserPromise = null;
        throw new Error(
          `Could not launch Chromium: ${error.message}\n` +
            `  Install it with:  npx playwright install chromium`,
        );
      });
  }
  return browserPromise;
}

export async function closeBrowser() {
  if (!browserPromise) return;
  const browser = await browserPromise.catch(() => null);
  browserPromise = null;
  if (browser) await browser.close();
}

async function settlePage(page) {
  await page.waitForLoadState("load", { timeout: LOAD_EVENT_BUDGET_MS }).catch(() => {});
  await page.addStyleTag({ content: STABILIZE_CSS }).catch(() => {});

  // Below-the-fold lazy images never enter the viewport during a full-page
  // capture, so without this they render as blank boxes.
  await page.evaluate(() => {
    for (const img of Array.from(document.querySelectorAll('img[loading="lazy"]'))) img.loading = "eager";
    for (const frame of Array.from(document.querySelectorAll('iframe[loading="lazy"]'))) frame.loading = "eager";
  });

  await page.evaluate(
    async ({ budgetMs, pauseMs, topBudgetMs }) => {
      const step = Math.max(320, Math.round(window.innerHeight * 0.85));
      const deadline = Date.now() + budgetMs;
      let y = 0;
      while (Date.now() < deadline && y < document.documentElement.scrollHeight) {
        window.scrollTo(0, y);
        y += step;
        await new Promise((resolve) => setTimeout(resolve, pauseMs));
      }
      window.scrollTo(0, document.documentElement.scrollHeight);
      await new Promise((resolve) => setTimeout(resolve, 400));

      // `scroll-behavior: smooth` makes a single scrollTo(0, 0) land part-way
      // up the page. Leaving the page mid-scroll smears sticky headers down
      // the full-page image, so poll until it is genuinely at the top.
      const topDeadline = Date.now() + topBudgetMs;
      while (window.scrollY !== 0 && Date.now() < topDeadline) {
        window.scrollTo(0, 0);
        await new Promise((resolve) => setTimeout(resolve, 80));
      }
    },
    { budgetMs: SCROLL_BUDGET_MS, pauseMs: SCROLL_STEP_PAUSE_MS, topBudgetMs: SCROLL_TOP_BUDGET_MS },
  );

  // `networkidle` is deliberately not used: on sites with analytics polling or
  // a chat widget it never fires, so it only ever costs the full timeout.
  // Polling the images themselves is the deterministic equivalent.
  await page.evaluate(
    async ({ imageBudgetMs, fontBudgetMs }) => {
      const laidOut = () => Array.from(document.images).filter((img) => img.getBoundingClientRect().width > 0);
      const deadline = Date.now() + imageBudgetMs;
      while (Date.now() < deadline && !laidOut().every((img) => img.complete)) {
        await new Promise((resolve) => setTimeout(resolve, 250));
      }
      await Promise.race([document.fonts.ready, new Promise((resolve) => setTimeout(resolve, fontBudgetMs))]);
    },
    { imageBudgetMs: IMAGE_BUDGET_MS, fontBudgetMs: FONT_BUDGET_MS },
  );

  await page.waitForTimeout(PAINT_SETTLE_MS);

  // Runs last, because these popups are delay-triggered: a longer settle makes
  // them MORE likely to appear, not less. The `position: fixed` test is what
  // protects legitimate inline embeds that share the same class prefix.
  await page.evaluate((selector) => {
    for (const el of Array.from(document.querySelectorAll(selector))) {
      if (window.getComputedStyle(el).position === "fixed") {
        el.style.setProperty("display", "none", "important");
      }
    }
  }, VENDOR_OVERLAY_SELECTOR);
}

/** Anything still covering a quarter of the viewport after the sweep, so a contaminated shot is noticed during the run. */
async function findBlockingOverlays(page) {
  return page.evaluate(() => {
    const viewportArea = window.innerWidth * window.innerHeight;
    const found = [];
    for (const el of Array.from(document.body.querySelectorAll("*"))) {
      const style = window.getComputedStyle(el);
      if (style.position !== "fixed") continue;
      if (style.display === "none" || style.visibility === "hidden") continue;
      if (Number(style.opacity) === 0) continue;
      const rect = el.getBoundingClientRect();
      if (rect.width * rect.height < viewportArea * 0.25) continue;
      const id = el.id ? `#${el.id}` : "";
      const cls = (el.getAttribute("class") || "").trim().split(/\s+/).filter(Boolean).slice(0, 3);
      found.push(`${el.tagName.toLowerCase()}${id}${cls.length ? "." + cls.join(".") : ""} z=${style.zIndex}`);
    }
    return found;
  });
}

/**
 * Capture one page. Returns the PNG buffer plus what was learned on the way:
 * the real HTTP status, same-origin links (for crawl mode), and third-party
 * request domains.
 */
export async function capturePage({ url, viewport, fullPage = true, collectLinks = false, onWarn }) {
  const browser = await getBrowser();
  const context = await browser.newContext({
    viewport: { width: viewport.width, height: viewport.height },
    deviceScaleFactor: viewport.deviceScaleFactor ?? 1,
    // Themes commonly gate reveal-on-scroll animations behind this, which makes
    // the revealed content visible without depending on scroll timing.
    reducedMotion: "reduce",
  });
  context.setDefaultTimeout(ACTION_TIMEOUT_MS);
  const page = await context.newPage();

  const rootHostname = new URL(url).hostname;
  const externalDomains = new Map();
  page.on("request", (request) => {
    try {
      const requestUrl = new URL(request.url());
      if (!["http:", "https:"].includes(requestUrl.protocol)) return;
      if (requestUrl.hostname === rootHostname) return;
      externalDomains.set(requestUrl.hostname, (externalDomains.get(requestUrl.hostname) ?? 0) + 1);
    } catch {
      // Ignore malformed URLs.
    }
  });

  try {
    const response = await page.goto(url, { waitUntil: "domcontentloaded", timeout: GOTO_TIMEOUT_MS });
    await settlePage(page);

    const overlays = await findBlockingOverlays(page);
    if (overlays.length > 0 && onWarn) {
      onWarn(`overlay still visible on ${url} - ${overlays.join(" | ")}`);
    }

    // Links are read from the page we already have open, rather than by
    // visiting it a second time.
    const links = collectLinks
      ? await page.$$eval("a[href]", (els) => els.map((el) => el.getAttribute("href") || "").filter(Boolean))
      : [];

    const buffer = await page.screenshot({
      type: "png",
      fullPage,
      animations: "disabled",
      caret: "hide",
      timeout: SCREENSHOT_TIMEOUT_MS,
    });

    return {
      buffer,
      title: await page.title(),
      httpStatus: response?.status() ?? null,
      links,
      externalDomains: [...externalDomains.entries()]
        .map(([domain, count]) => ({ domain, count }))
        .sort((a, b) => b.count - a.count || a.domain.localeCompare(b.domain)),
    };
  } finally {
    await context.close();
  }
}
