import { dependency } from './runtime.mjs';
process.env.PLAYWRIGHT_BROWSERS_PATH ??= '0';
const [{ chromium }, { default: postcss }, { default: valueParser }, fontkit, { default: sharp }] = await Promise.all(['playwright', 'postcss', 'postcss-value-parser', 'fontkit', 'sharp'].map(dependency));
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const MAX_BYTES = 12 * 1024 * 1024;
const VIEWPORT = { width: 1440, height: 900 };
const generic = new Set(['serif', 'sans-serif', 'monospace', 'cursive', 'fantasy', 'system-ui', 'ui-serif', 'ui-sans-serif', 'ui-monospace', 'ui-rounded', 'emoji', 'math', 'fangsong']);
const families = s => postcss.list.comma(s).map(unquote);
const unquote = s => s.trim().replace(/^(['"])(.*)\1$/, '$2');
const httpURL = (url, base) => {
  const u = new URL(url, base);
  if (!['http:', 'https:'].includes(u.protocol)) throw new Error(`unsupported asset protocol: ${u.protocol}`);
  return u.href;
};

export function colorHex(value) {
  if (/^#[0-9a-f]{6}$/i.test(value)) return value.toUpperCase();
  if (/^#[0-9a-f]{3}$/i.test(value)) return '#' + [...value.slice(1)].map(c => c + c).join('').toUpperCase();
  const rgb = value.match(/^rgba?\(\s*([\d.]+)[, ]+([\d.]+)[, ]+([\d.]+)(?:\s*[,/]\s*([\d.]+))?\s*\)$/i);
  if (!rgb || (rgb[4] !== undefined && Number(rgb[4]) !== 1)) return null;
  return '#' + rgb.slice(1, 4).map(c => Math.round(Number(c)).toString(16).padStart(2, '0')).join('').toUpperCase();
}

export function originImage(url, base) {
  const u = new URL(url, base);
  return u.pathname === '/_next/image' && u.searchParams.has('url')
    ? httpURL(u.searchParams.get('url'), u) : httpURL(u.href);
}

// Node fetch follows redirects independently of browser CSSOM/CORS access.
async function asset(url, kind) {
  const response = await fetch(httpURL(url), { redirect: 'follow', signal: AbortSignal.timeout(15000) });
  if (!response.ok) throw new Error(`${kind}: HTTP ${response.status}`);
  const chunks = [];
  let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length;
    if (size > MAX_BYTES) { await response.body.cancel().catch(() => {}); throw new Error(`${kind}: exceeds 12 MiB`); }
    chunks.push(chunk);
  }
  const bytes = Buffer.concat(chunks);
  if (!bytes.length) throw new Error(`${kind}: empty body`);
  return { bytes, final: response.url, type: (response.headers.get('content-type') || '').split(';')[0].toLowerCase() };
}

export function parseCSS(text, url) {
  if (/^\s*(?:<!doctype\s+html|<html|<head|<body)/i.test(text)) throw new Error('HTML returned as CSS');
  const root = postcss.parse(text, { from: url });
  if (root.nodes.some(n => n.type === 'rule' && n.selector.trim().startsWith('<'))) throw new Error('markup returned as CSS');
  return root;
}

export function fontMetadata(bytes) {
  if (!['wOFF', 'wOF2', 'OTTO', 'true', 'ttcf'].includes(bytes.subarray(0, 4).toString()) && bytes.readUInt32BE(0) !== 0x00010000) throw new Error('not a font signature');
  const font = fontkit.create(bytes);
  if (!font.familyName || !font.numGlyphs) throw new Error('not a single usable font');
  const axes = font.variationAxes || {};
  const familyRaw = font.familyName;
  const family = axes.wght ? familyRaw.replace(/\s+(?:(?:Extra|Ultra|Semi|Demi)?\s*(?:Thin|Light|Bold)|Regular|Medium|Black|Heavy|Italic)(?:\s+Italic)?$/i, '') : familyRaw;
  return { family, familyRaw, variable: Object.keys(axes).length > 0,
    weightAxis: axes.wght ? [axes.wght.min, axes.wght.max] : null,
    glyphCount: font.numGlyphs, characterCount: font.characterSet.length,
    subsetted: font.numGlyphs < 1000 ? true : null,
    subsetAssessment: 'fewer than 1000 glyphs flags a limited font; larger files have unknown subset status',
    copyright: font.copyright || null };
}

export async function imageMetadata(bytes, type = '') {
  const image = sharp(bytes);
  const meta = await image.metadata();
  await image.stats(); // Decode the content, not just its header or extension.
  if (!meta.width || !meta.height) throw new Error('image has no dimensions');
  const sniffedType = meta.mediaType || ({ jpeg: 'image/jpeg', png: 'image/png', webp: 'image/webp', gif: 'image/gif', svg: 'image/svg+xml', heif: 'image/avif' })[meta.format];
  if (!sniffedType) throw new Error(`unsupported image format: ${meta.format}`);
  if (type && type !== 'application/octet-stream' && type !== sniffedType) throw new Error(`content-type ${type} disagrees with parsed ${sniffedType}`);
  return { sniffedType, intrinsic: [meta.width, meta.height] };
}

async function settle(page, warnings) {
  await page.waitForLoadState('load', { timeout: 10000 }).catch(() => warnings.push('load event timed out'));
  await page.addStyleTag({ content: '*,*::before,*::after{transition-duration:0s!important;scroll-behavior:auto!important}html{scroll-behavior:auto!important}' });
  await page.evaluate(async () => {
    document.querySelectorAll('img[loading="lazy"]').forEach(img => { img.loading = 'eager'; });
    const height = Math.min(document.documentElement.scrollHeight, 20000);
    for (let y = 0; y < height; y += innerHeight) { scrollTo(0, y); await new Promise(r => setTimeout(r, 30)); }
    scrollTo(0, 0);
  });
  await page.waitForFunction(() => scrollY === 0, null, { timeout: 3000 });
  await page.waitForFunction(() => [...document.images].every(i => !i.getClientRects().length || i.complete), null, { timeout: 5000 }).catch(() => warnings.push('laid-out images did not all complete'));
  const fontsReady = await page.evaluate(() => Promise.race([document.fonts.ready.then(() => true), new Promise(r => setTimeout(() => r(false), 5000))]));
  if (!fontsReady) warnings.push('document.fonts.ready timed out; computed typography may use fallbacks');
  await page.waitForTimeout(150);
  const overlays = await page.evaluate(() => [...document.querySelectorAll('body *')].filter(el => {
    const s = getComputedStyle(el), r = el.getBoundingClientRect();
    return s.position === 'fixed' && s.visibility !== 'hidden' && Number(s.opacity) > 0 && r.width * r.height > innerWidth * innerHeight / 4;
  }).map(el => el.tagName.toLowerCase() + (el.id ? '#' + el.id : '')));
  if (overlays.length) warnings.push(`large fixed overlays present; inspect screenshot: ${overlays.join(', ')}`);
}

async function pixels(png) {
  const { data, info } = await sharp(png).removeAlpha().raw().toBuffer({ resolveWithObject: true });
  const counts = new Map();
  for (let i = 0; i < data.length; i += info.channels) {
    const key = '#' + data.subarray(i, i + 3).toString('hex').toUpperCase();
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  return [...counts].sort((a, b) => b[1] - a[1]).slice(0, 32).map(([value, paintedArea]) => ({ value, paintedArea }));
}

async function inspectDOM(page) {
  return page.evaluate(() => {
    const visible = el => { const s = getComputedStyle(el), r = el.getBoundingClientRect(); return s.display !== 'none' && s.visibility === 'visible' && Number(s.opacity) > 0 && r.width > 0 && r.height > 0; };
    const styles = [...document.querySelectorAll('style')].map(s => s.textContent);
    const sheets = [...document.querySelectorAll('link[rel~="stylesheet"]')].map(s => s.href);
    let cssBytesInBrowser = 0, corsBlockedSheets = 0;
    for (const sheet of document.styleSheets) { try { cssBytesInBrowser += new TextEncoder().encode([...sheet.cssRules].map(r => r.cssText).join('\n')).length; } catch { corsBlockedSheets++; } }
    const samples = [...document.querySelectorAll('html, body, body *')].filter(visible).map(el => {
      const s = getComputedStyle(el), r = el.getBoundingClientRect();
      const text = [...el.childNodes].filter(n => n.nodeType === Node.TEXT_NODE).map(n => n.textContent).join('').trim();
      const w = Math.max(0, Math.min(innerWidth, r.right) - Math.max(0, r.left));
      const h = Math.max(0, Math.min(innerHeight, r.bottom) - Math.max(0, r.top));
      return { tag: el.tagName.toLowerCase(), background: s.backgroundColor, backgroundImage: s.backgroundImage,
        color: s.color, boxArea: w * h, textChars: text.length, sampleText: text.slice(0, 100), family: s.fontFamily, weight: Number(s.fontWeight), fontSize: s.fontSize, lineHeight: s.lineHeight, letterSpacing: s.letterSpacing };
    });
    const icons = [...document.querySelectorAll('link[rel]')].filter(l => /icon/i.test(l.rel)).map(l => l.href);
    const manifests = [...document.querySelectorAll('link[rel="manifest"]')].map(l => l.href);
    const candidates = [];
    for (const anchor of document.querySelectorAll('header a[href], [role="banner"] a[href]')) {
      let u; try { u = new URL(anchor.href); } catch { continue; }
      if (u.origin !== location.origin || u.pathname !== '/') continue;
      for (const el of anchor.querySelectorAll('img, svg')) {
        const r = el.getBoundingClientRect(), s = getComputedStyle(el);
        if (s.display === 'none' || s.visibility === 'hidden' || Number(s.opacity) === 0) continue;
        candidates.push({ kind: el.tagName.toLowerCase() === 'svg' ? 'inline-svg' : 'raster', inlineSvg: el.tagName.toLowerCase() === 'svg' ? el.outerHTML : null,
          urlAsRendered: el.currentSrc || el.src || null, renderedAt: [r.width, r.height], alt: el.getAttribute('alt') || el.getAttribute('aria-label') || null,
          markupLength: el.outerHTML.length, foundVia: 'largest-node-in-header-home-link' });
      }
    }
    return { styles, sheets, samples, icons, manifests, candidates, cssBytesInBrowser, corsBlockedSheets, declaredColorScheme: getComputedStyle(document.documentElement).colorScheme };
  });
}

export async function extract(url, { out, browser: suppliedBrowser } = {}) {
  httpURL(url);
  const browser = suppliedBrowser || await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: VIEWPORT, deviceScaleFactor: 1, reducedMotion: 'reduce' });
  const warnings = [], measurements = {}, screenshots = {}, computedMeasurements = {}, allCSS = [], seenCSS = new Set();
  let dom, final;
  try {
    for (const [name, scheme, force] of [['schemeLight', 'light', null], ['schemeDark', 'dark', null], ['forcedLight', 'light', 'light'], ['forcedDark', 'dark', 'dark']]) {
      const page = await context.newPage();
      await page.emulateMedia({ colorScheme: scheme });
      const response = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
      if (!response || !response.ok()) throw new Error(`page: HTTP ${response?.status() ?? 'no response'}`);
      final = page.url();
      if (force) await page.evaluate(theme => {
        document.documentElement.dataset.theme = theme;
        document.documentElement.classList.remove('dark', 'light');
        document.documentElement.classList.add(theme);
        document.documentElement.style.colorScheme = theme;
      }, force);
      await settle(page, warnings);
      const renderedDOM = await inspectDOM(page);
      if (!dom) dom = renderedDOM;
      const areas = new Map();
      for (const sample of renderedDOM.samples) {
        const hex = colorHex(sample.background);
        if (hex) areas.set(hex, (areas.get(hex) || 0) + sample.boxArea);
      }
      computedMeasurements[name] = [...areas].sort((a, b) => b[1] - a[1])[0]?.[0] || null;
      const png = await page.screenshot({ animations: 'disabled', caret: 'hide' });
      measurements[name] = await pixels(png);
      screenshots[name] = png;
      await page.close();
    }
    const getCSS = async (url, inline) => {
      if (seenCSS.has(url)) return;
      seenCSS.add(url);
      try {
        const data = inline === undefined ? await asset(url, 'CSS') : { bytes: Buffer.from(inline), final: url, type: 'text/css' };
        if (data.type && !['text/css', 'application/octet-stream'].includes(data.type)) throw new Error(`CSS content-type ${data.type}`);
        const root = parseCSS(data.bytes.toString(), data.final);
        allCSS.push({ url: data.final, root, bytes: data.bytes.length });
        const imports = [];
        root.walkAtRules('import', rule => {
          const first = valueParser(rule.params).nodes.find(n => n.type !== 'space' && n.type !== 'comment');
          const path = first?.type === 'string' ? first.value : first?.type === 'function' && first.value.toLowerCase() === 'url' ? unquote(valueParser.stringify(first.nodes)) : null;
          if (path) imports.push(httpURL(path, data.final));
        });
        for (const imported of imports) await getCSS(imported);
      } catch (e) { warnings.push(`CSS ${url}: ${e.message}`); }
    };
    for (const sheet of dom.sheets) await getCSS(sheet);
    for (const [i, text] of dom.styles.entries()) await getCSS(`${final}#inline-style-${i}`, text);
    if (dom.corsBlockedSheets) warnings.push(`${dom.corsBlockedSheets} browser CSSOM sheets blocked; static reads recorded separately`);

    const declared = [], faces = [], declaredColors = [];
    const declarations = [];
    for (const css of allCSS) css.root.walkDecls(d => declarations.push({ property: d.prop, value: d.value, source: css.url }));
    const validColors = await context.newPage();
    const checked = await validColors.evaluate(values => values.map(v => {
      if (/\b(?:var|env)\(/i.test(v) || !CSS.supports('color', v) || ['inherit', 'initial', 'unset', 'revert', 'currentcolor'].includes(v.toLowerCase())) return null;
      const canvas = document.createElement('canvas').getContext('2d');
      canvas.fillStyle = '#010203'; canvas.fillStyle = v; const first = canvas.fillStyle;
      canvas.fillStyle = '#040506'; canvas.fillStyle = v;
      if (first !== canvas.fillStyle) return null; // CSS support does not imply canvas support.
      return { value: v, normalized: canvas.fillStyle };
    }), declarations.map(d => d.value));
    await validColors.close();
    checked.forEach((c, i) => { if (c) declaredColors.push({ ...declarations[i], ...c, hex: colorHex(c.normalized), provenance: ['declared-css'] }); });
    for (const css of allCSS) {
      css.root.walkDecls(decl => {
        if (decl.prop.startsWith('--')) declared.push({ siteTokenName: decl.prop, value: decl.value, selector: decl.parent.selector || decl.parent.name || '', source: css.url, provenance: ['declared-css'] });
      });
      css.root.walkAtRules('font-face', face => {
        const d = Object.fromEntries(face.nodes.filter(n => n.type === 'decl').map(n => [n.prop.toLowerCase(), n.value]));
        const urls = [];
        valueParser(d.src || '').walk(node => { if (node.type === 'function' && node.value.toLowerCase() === 'url') {
          try { urls.push(httpURL(unquote(valueParser.stringify(node.nodes)), css.url)); }
          catch (e) { warnings.push(`font source: ${e.message}`); }
        } });
        if (urls.length) faces.push({ cssFamily: unquote(d['font-family'] || ''), declaredWeightInCss: d['font-weight'] || null, unicodeRange: d['unicode-range'] || null, urls });
      });
    }
    const colors = new Map();
    const entry = value => {
      const key = colorHex(value) || value;
      if (!colors.has(key)) colors.set(key, { value, hex: colorHex(value), role: null, roleConfidence: 'unassigned', evidence: { paintedArea: 0, boxArea: 0, textChars: 0 }, provenance: [] });
      return colors.get(key);
    };
    for (const p of measurements.schemeLight) {
      const c = entry(p.value); c.evidence.paintedArea = p.paintedArea; c.provenance.push('screenshot-pixels');
    }
    for (const s of dom.samples) {
      if (!/^(?:rgba\([^)]*,\s*0\)|[^()]+\([^)]*\/\s*0\)|transparent)$/.test(s.background)) {
        const c = entry(s.background); c.evidence.boxArea += s.boxArea; c.provenance.push('computed-background');
      }
      if (s.textChars) { const c = entry(s.color); c.evidence.textChars += s.textChars; c.provenance.push('computed-text'); }
    }
    const sorted = [...colors.values()].sort((a, b) => b.evidence.paintedArea - a.evidence.paintedArea);
    const background = [...sorted].filter(c => c.evidence.boxArea && c.hex).sort((a, b) => b.evidence.boxArea - a.evidence.boxArea)[0];
    if (background) { background.role = 'background'; background.roleConfidence = 'measured'; }
    for (const c of sorted) {
      c.provenance = [...new Set(c.provenance)];
      if (!c.role && c.evidence.textChars) { c.role = 'foreground'; c.roleConfidence = 'measured'; }
      else if (!c.role && c.evidence.boxArea) { c.role = 'surface'; c.roleConfidence = 'measured'; }
    }
    for (const d of declaredColors) { const c = entry(d.normalized); c.evidence.cssOccurrences = (c.evidence.cssOccurrences || 0) + 1; c.provenance.push('declared-css'); }
    for (const c of colors.values()) c.provenance = [...new Set(c.provenance)];
    const fontCache = new Map(), fontGroups = new Map();
    for (const face of faces) {
      const samples = dom.samples.filter(s => families(s.family).includes(face.cssFamily) && s.textChars);
      if (!samples.length) continue;
      const files = [];
      for (const u of face.urls) {
        try {
          if (!fontCache.has(u)) { const data = await asset(u, 'font'); fontCache.set(u, { url: u, final: data.final, bytes: data.bytes.length, ...fontMetadata(data.bytes) }); }
          files.push(fontCache.get(u));
          break;
        } catch (e) { warnings.push(`font ${u}: ${e.message}`); }
      }
      const font = files[0], specimen = samples.sort((a, b) => b.textChars - a.textChars)[0];
      let stack = [font?.family || face.cssFamily];
      const computedStack = families(specimen.family);
      const firstGeneric = computedStack.find(s => generic.has(s.toLowerCase()));
      if (firstGeneric) stack.push(firstGeneric);
      else stack.push('sans-serif');
      stack = [...new Set(stack)];
      if (files.some(f => f.subsetted)) warnings.push(`font ${face.cssFamily} has limited glyph coverage; check intended copy before reuse`);
      const record = { cssFamily: face.cssFamily, declaredWeightInCss: face.declaredWeightInCss, unicodeRange: face.unicodeRange,
        family: font?.family || null, familyRaw: font?.familyRaw || null, variable: font?.variable ?? null, weightAxis: font?.weightAxis || null,
        usedWeights: [...new Set(samples.map(s => s.weight))], stack, files,
        specimen: { fontSize: specimen.fontSize, lineHeight: specimen.lineHeight, letterSpacing: specimen.letterSpacing, weight: specimen.weight, sampleText: specimen.sampleText },
        provenance: ['computed-styles', 'declared-font-face', ...(font ? ['font-binary'] : [])] };
      if (!fontGroups.has(face.cssFamily)) fontGroups.set(face.cssFamily, record);
      else {
        const group = fontGroups.get(face.cssFamily);
        for (const file of files) if (!group.files.some(f => f.url === file.url)) group.files.push(file);
      }
    }
    const typography = [...fontGroups.values()];
    for (const group of typography) {
      group.familyCandidates = [...new Set(group.files.map(f => f.family))];
      if (group.familyCandidates.length > 1) group.family = null;
      group.usageLimit = 'weights describe computed CSS family usage; font matching and selected subset per glyph are not proven';
    }
    if (!typography.length) warnings.push('no used downloadable font faces resolved; system fonts or unreadable CSS may be in use');
    const excluded = new Set(dom.icons.map(u => originImage(u, final)));
    for (const u of dom.manifests) {
      try {
        const data = await asset(u, 'manifest'), manifest = JSON.parse(data.bytes.toString());
        if (!Array.isArray(manifest.icons)) throw new Error('manifest.icons is not an array');
        for (const i of manifest.icons) excluded.add(httpURL(i.src, data.final));
      } catch (e) { warnings.push(`manifest ${u}: ${e.message}`); }
    }
    const candidates = dom.candidates.map(c => ({ ...c, url: c.urlAsRendered ? originImage(c.urlAsRendered, final) : null }));
    const logos = candidates.filter(c => !c.url || !excluded.has(c.url)).sort((a, b) => b.renderedAt[0] * b.renderedAt[1] - a.renderedAt[0] * a.renderedAt[1] || b.markupLength - a.markupLength);
    const logo = logos[0] || { kind: 'none', url: null, inlineSvg: null };
    if (logo.kind !== 'none') {
      try {
        const data = logo.inlineSvg ? { bytes: Buffer.from(logo.inlineSvg), type: 'image/svg+xml' } : await asset(logo.url, 'logo');
        const metadata = await imageMetadata(data.bytes, data.type);
        if (metadata.sniffedType === 'image/svg+xml' && !logo.inlineSvg) logo.kind = 'external-svg';
        Object.assign(logo, metadata, { verified: true, bytes: data.bytes.length, final: data.final || null, originRecovered: logo.url !== logo.urlAsRendered });
      } catch (e) { logo.verified = false; warnings.push(`logo: ${e.message}`); }
    } else warnings.push('no non-icon logo found inside a header home link');
    const report = {
      schemaVersion: 1,
      source: { requested: url, final, capturedAt: new Date().toISOString(), viewport: [VIEWPORT.width, VIEWPORT.height], coverage: {
        cssBytesStatic: allCSS.reduce((n, c) => n + c.bytes, 0), cssBytesInBrowser: dom.cssBytesInBrowser, corsBlockedSheets: dom.corsBlockedSheets,
        inlineStyleBlocks: dom.styles.length, cssSources: allCSS.map(c => c.url), cssReadsAttempted: seenCSS.size, fontFilesParsed: fontCache.size,
        scope: 'top-level document; viewport pixels; readable static CSS including imports; no shadow DOM, frames or authenticated browser state' } },
      colors: [...colors.values()].sort((a, b) => b.evidence.paintedArea - a.evidence.paintedArea), declaredTokens: declared, declaredColors,
      background: { computed: background || null, renderedDominant: measurements.schemeLight[0], limitation: 'computed box areas can overlap; rendered pixels can include gradients and images' },
      accent: { value: null, status: 'unassigned', candidates: [...colors.values()].map(c => ({ value: c.value, evidence: c.evidence })),
        rankings: Object.fromEntries(['paintedArea', 'cssOccurrences', 'textChars'].map(key => [key, [...colors.values()].filter(c => c.evidence[key]).sort((a, b) => b.evidence[key] - a.evidence[key]).slice(0, 12).map(c => c.value)])) },
      computedTypography: dom.samples.filter(s => s.textChars).map(s => ({ cssFamily: s.family, weight: s.weight, fontSize: s.fontSize, textChars: s.textChars })),
      typography, logo: { ...logo, excludedIconUrls: [...excluded], candidates: logos },
      themes: { variantDetected: Object.values(computedMeasurements).every(Boolean) ? new Set(Object.values(computedMeasurements)).size > 1 : null,
        method: 'four-render-background-comparison', measurements: Object.fromEntries(Object.entries(measurements).map(([k, v]) => [k, v[0]])),
        computedMeasurements, declaredColorScheme: dom.declaredColorScheme, switchMechanism: 'prefers-color-scheme; forced html .light/.dark and data-theme',
        limitation: 'compares opaque sRGB computed background areas; rendered dominant pixels are retained separately; other theme mechanisms and smaller changes can be missed' },
      warnings: [...new Set(warnings)]
    };
    if (out) {
      await mkdir(out); // Refuse an existing directory; keep earlier evidence intact.
      for (const [name, png] of Object.entries(screenshots)) await writeFile(resolve(out, `${name}.png`), png);
      await writeFile(resolve(out, 'brand-tokens.json'), JSON.stringify(report, null, 2) + '\n');
    }
    return report;
  } finally { await context.close(); if (!suppliedBrowser) await browser.close(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [, , url, flag, out] = process.argv;
  if (!url || flag !== '--out' || !out || process.argv.length !== 5) {
    console.error('usage: node brand-tokens.mjs <http(s)-url> --out <new-directory>'); process.exitCode = 2;
  } else {
    extract(url, { out: resolve(out) }).then(r => console.log(`${resolve(out)}/brand-tokens.json (${r.warnings.length} warning(s); accent unassigned)`)).catch(e => { console.error(e.message); process.exitCode = 1; });
  }
}
