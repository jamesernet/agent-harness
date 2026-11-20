import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dependency } from '../skills/site-visual-baseline/scripts/runtime.mjs';
const { chromium } = await dependency('playwright');
const { default: sharp } = await dependency('sharp');
import { colorHex, originImage, parseCSS, fontMetadata, imageMetadata, extract } from '../skills/site-visual-baseline/scripts/brand-tokens.mjs';

const fixture = fileURLToPath(new URL('./fixtures/brand-tokens/', import.meta.url));
let server, browser, base, font, logo, icon;
before(async () => {
  font = await readFile(join(fixture, 'variable-subset.ttf'));
  logo = await sharp({ create: { width: 320, height: 40, channels: 4, background: '#ffffff' } }).png().toBuffer();
  icon = await sharp({ create: { width: 512, height: 512, channels: 4, background: '#ff0000' } }).png().toBuffer();
  server = createServer((req, res) => {
    const send = (type, value, status = 200) => { res.writeHead(status, { 'content-type': type }); res.end(value); };
    const u = new URL(req.url, base);
    if (u.pathname === '/font.ttf') return send('font/ttf', font);
    if (u.pathname === '/logo.png') return send('image/png', logo);
    if (u.pathname === '/icon.png') return send('image/png', icon);
    if (u.pathname === '/logo-redirect') { res.writeHead(302, { location: '/logo.png' }); return res.end(); }
    if (u.pathname === '/_next/image') return send('image/png', logo);
    if (u.pathname === '/manifest.json') return send('application/manifest+json', JSON.stringify({ icons: [{ src: '/icon.png' }] }));
    if (u.pathname === '/soft404.css' || u.pathname === '/fake.ttf' || u.pathname === '/fake.png') return send('text/html', '<html><body>not an asset</body></html>');
    if (u.pathname === '/missing.css') return send('text/html', '<html>not found</html>', 404);
    if (u.pathname === '/style.css') return send('text/css', '@import url("/more.css"); @font-face{font-family:"__Fixture_hash";font-weight:400;src:local("Missing Local Font"),url("/font.ttf") format("truetype")} @font-face{font-family:"Ignore Fallback";src:local("Arial")} :root{--brand:#123456;--derived:var(--brand)} @media(prefers-color-scheme:dark){:root{--brand:#654321}}');
    if (u.pathname === '/more.css') return send('text/css', ':root{--imported:#abcdef}');
    const dataIcon = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="red"/></svg>');
    const regressionPages = {
      '/data-images': `<link rel="icon" href="${dataIcon}"><header><a href="/"><img width="160" height="20" src="data:image/png;base64,${logo.toString('base64')}"></a></header><p>Visible brand</p>`,
      '/hidden-parent': '<style>@font-face{font-family:HiddenBrand;src:url(/font.ttf)}body{background:white;color:black}.hide{opacity:0}.hide p{color:#ff00ff;font-family:HiddenBrand}</style><p>Visible copy</p><div class="hide"><p>Hidden copy must not become a measured foreground or font family</p></div>',
      '/opaque-theme-parents': '<style>html,body{margin:0;background:white;color:black;min-height:100vh}main{min-height:100vh;background:white}:root.dark main{background:black;color:white}</style><main>Theme fills the viewport</main>',
      '/style-attributes': '<body style="background:#123456;color:#fedcba;--brand:#987654"><p style="color:#112233">Inline declarations</p></body>',
    };
    if (regressionPages[u.pathname]) return send('text/html', '<!doctype html><html>' + regressionPages[u.pathname] + '</html>');
    const themed = u.pathname === '/themed';
    const bad = u.pathname === '/bad';
    const blue = u.pathname === '/blue';
    const color = blue ? '#0B2241' : '#050A07';
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="20" viewBox="0 0 80 20"><rect width="80" height="20" fill="white"/></svg>';
    send('text/html', `<!doctype html><html><head><link rel="icon" href="/icon.png"><link rel="manifest" href="/manifest.json"><link rel="stylesheet" href="http://localhost:${server.address().port}/style.css">${bad ? '<link rel="stylesheet" href="/soft404.css"><link rel="stylesheet" href="/missing.css">' : ''}<style>
html,body{margin:0;background:transparent;color-scheme:dark}main{box-sizing:border-box;background:${color};color:white;min-height:1800px;padding:60px}header{position:absolute}h1,p{font-family:"__Fixture_hash",Arial,sans-serif,serif}h1{font-size:60px;font-weight:800}p{font-size:18px} .alpha{background:rgba(0,0,0,0.5);width:80px;height:40px}
${themed ? '@media(prefers-color-scheme:light){main{background:#fff;color:#000}} :root[data-theme="light"] main{background:#fff;color:#000} :root[data-theme="dark"] main{background:#050A07;color:#fff}' : ''}
${bad ? '@font-face{font-family:Bad;src:url("/fake.ttf")} p{font-family:Bad}' : ''}</style></head><body><header><a href="/"><img src="/icon.png" width="200" height="200">${blue ? svg : `<img src="${bad ? '/fake.png' : '/_next/image?url=%2Flogo-redirect&w=256&q=75'}" width="160" height="20">`}</a></header><main><h1>Evidence before inference</h1><p>Business definitions carry sources and known limits.</p><div class="alpha"></div></main></body></html>`);
  });
  await new Promise(resolve => server.listen(0, '::', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true });
});
after(async () => { await browser?.close(); await new Promise(r => server?.close(r)); });

test('alpha is preserved and non-sRGB values retain a nullable hex', () => {
  assert.equal(colorHex('rgba(0, 0, 0, 0)'), null);
  assert.equal(colorHex('rgba(0, 0, 0, 0.5)'), null);
  assert.equal(colorHex('rgb(5, 10, 7)'), '#050A07');
  assert.equal(colorHex('oklab(0.2 0 0 / 0.5)'), null);
});
test('Next image recovers the origin URL and rejects unsupported schemes', () => {
  assert.equal(originImage('/_next/image?url=%2Flogo.png&w=256', base), `${base}/logo.png`);
  assert.throws(() => originImage('/_next/image?url=data%3Aimage%2Fpng', base), /protocol/);
});
test('a status-200 HTML body is not CSS, font or image content', async () => {
  const html = '<html><body>not found</body></html>';
  assert.throws(() => parseCSS(html, 'fake.css'), /HTML/);
  assert.throws(() => fontMetadata(Buffer.from(html)), /font/);
  await assert.rejects(imageMetadata(Buffer.from(html)), /unsupported|corrupt/i);
});
test('valid CSS child selectors and quoted attribute values remain parseable', () => {
  assert.equal(parseCSS('header > a {color:white} [data-label="<"] {color:black}', 'valid.css').nodes.length, 2);
});
test('variable font identity comes from the binary with default style stripped', () => {
  const m = fontMetadata(font);
  assert.equal(m.familyRaw, 'Harness Fixture Thin');
  assert.equal(m.family, 'Harness Fixture');
  assert.deepEqual(m.weightAxis, [100, 900]);
  assert.equal(m.variable, true);
  assert.ok(m.glyphCount < 1000);
  assert.equal(m.subsetted, true);
});
test('image bytes are decoded and compared to the HTTP content type', async () => {
  assert.deepEqual((await imageMetadata(logo, 'image/png')).intrinsic, [320, 40]);
  await assert.rejects(imageMetadata(logo, 'image/avif'), /disagrees/);
  await assert.rejects(imageMetadata(logo.subarray(0, 36), 'image/png'));
});
test('known dark background survives transparency; CORS CSS, fonts and redirect logo resolve', async () => {
  const r = await extract(base, { browser });
  assert.equal(r.themes.measurements.schemeLight.value, '#050A07');
  assert.equal(r.themes.variantDetected, false, 'color-scheme alone is not a theme variant');
  assert.equal(r.colors.find(c => c.role === 'background').hex, '#050A07');
  assert.equal(r.accent.value, null);
  assert.equal(r.accent.status, 'unassigned');
  assert.ok(!r.colors.some(c => c.role === 'accent'));
  assert.ok(r.source.coverage.corsBlockedSheets >= 1);
  assert.ok(r.declaredTokens.some(t => t.siteTokenName === '--imported'));
  assert.equal(r.declaredTokens.filter(t => t.siteTokenName === '--brand').length, 2);
  assert.ok(!r.declaredColors.some(c => c.value.startsWith('var(')), 'unresolved variables must not turn into invented black');
  assert.ok(r.declaredColors.some(c => c.value === '#123456'));
  assert.equal(r.typography[0].family, 'Harness Fixture');
  assert.ok(r.typography[0].usedWeights.includes(800));
  assert.deepEqual(r.typography[0].stack, ['Harness Fixture', 'sans-serif']);
  assert.ok(!r.typography.some(t => t.cssFamily === 'Ignore Fallback'));
  assert.equal(r.logo.url, `${base}/logo-redirect`);
  assert.equal(r.logo.final, `${base}/logo.png`);
  assert.equal(r.logo.verified, true);
  assert.deepEqual(r.logo.intrinsic, [320, 40]);
  assert.equal(r.logo.originRecovered, true);
  assert.ok(r.logo.excludedIconUrls.includes(`${base}/icon.png`));
});
test('second known-answer palette and inline SVG logo retain their provenance', async () => {
  const r = await extract(`${base}/blue`, { browser });
  assert.equal(r.themes.measurements.schemeLight.value, '#0B2241');
  assert.equal(r.logo.kind, 'inline-svg');
  assert.match(r.logo.inlineSvg, /<svg/);
  assert.equal(r.logo.verified, true);
  assert.equal(r.logo.sniffedType, 'image/svg+xml');
});
test('four renders observe an actual theme change', async () => {
  const r = await extract(`${base}/themed`, { browser });
  assert.equal(r.themes.variantDetected, true);
  assert.equal(r.themes.measurements.forcedDark.value, '#050A07');
  assert.equal(r.themes.measurements.forcedLight.value, '#FFFFFF');
});
test('incomplete assets produce explicit warnings and no verified identity', async () => {
  const r = await extract(`${base}/bad`, { browser });
  assert.ok(r.warnings.some(w => w.includes('soft404.css')));
  assert.ok(r.warnings.some(w => w.includes('HTTP 404')));
  assert.ok(r.warnings.some(w => w.includes('fake.ttf')));
  assert.equal(r.logo.verified, false);
});
test('evidence directories are new and existing artifacts survive a repeat', async () => {
  const tmp = await mkdtemp(join(tmpdir(), 'brand-token-test-'));
  try {
    const out = join(tmp, 'capture');
    await extract(base, { browser, out });
    const original = await readFile(join(out, 'brand-tokens.json'));
    await assert.rejects(extract(base, { browser, out }), /EEXIST/);
    assert.deepEqual(await readFile(join(out, 'brand-tokens.json')), original);
    assert.ok((await readFile(join(out, 'schemeLight.png'))).length > 100);
  } finally { await rm(tmp, { recursive: true, force: true }); }
});

test('data-URL favicons and logos retain a complete validated report', async () => {
  const r = await extract(`${base}/data-images`, { browser });
  assert.ok(r.logo.url.startsWith('data:image/png;base64,'));
  assert.equal(r.logo.verified, true);
  assert.deepEqual(r.logo.intrinsic, [320, 40]);
  assert.ok(r.logo.excludedIconUrls.some(url => url.startsWith('data:image/svg+xml,')));
});
test('ancestor opacity excludes hidden foreground and font attribution', async () => {
  const r = await extract(`${base}/hidden-parent`, { browser });
  assert.ok(!r.colors.some(c => c.hex === '#FF00FF' && c.roleConfidence === 'measured'));
  assert.ok(!r.typography.some(t => t.cssFamily === 'HiddenBrand'));
  assert.ok(!r.computedTypography.some(t => t.cssFamily.includes('HiddenBrand')));
});
test('opaque parents do not outweigh a full-viewport child theme', async () => {
  const r = await extract(`${base}/opaque-theme-parents`, { browser });
  assert.equal(r.themes.variantDetected, true);
  assert.equal(r.themes.computedMeasurements.forcedLight, '#FFFFFF');
  assert.equal(r.themes.computedMeasurements.forcedDark, '#000000');
  assert.equal(r.themes.measurements.forcedDark.value, '#000000');
});
test('style attributes contribute declared colors, tokens and coverage', async () => {
  const r = await extract(`${base}/style-attributes`, { browser });
  assert.ok(r.source.coverage.inlineStyleAttributes >= 2);
  assert.ok(r.declaredTokens.some(t => t.siteTokenName === '--brand' && t.value === '#987654'));
  assert.ok(r.declaredColors.some(c => c.hex === '#123456' && c.source.includes('inline-style-attribute-')));
});
