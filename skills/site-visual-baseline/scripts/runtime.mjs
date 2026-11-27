import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { mkdir, copyFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const hash = createHash('sha256').update(readFileSync(join(here, 'package-lock.json'))).digest('hex');
export const runtimeDir = process.env.BRAND_TOKENS_RUNTIME || join(process.env.XDG_CACHE_HOME || join(homedir(), '.cache'), 'agent-harness', 'brand-tokens', hash);
const require = createRequire(join(runtimeDir, 'package.json'));
export async function dependency(name) {
  let entry;
  try {
    const installed = createHash('sha256').update(readFileSync(join(runtimeDir, 'package-lock.json'))).digest('hex');
    if (installed !== hash) throw new Error('runtime lock mismatch');
    entry = require.resolve(name);
    if (!entry.startsWith(join(runtimeDir, 'node_modules') + '/')) throw new Error('dependency resolved outside runtime');
  }
  catch { throw new Error('Brand-token runtime missing. Run: node ' + join(here, 'runtime.mjs') + ' --install'); }
  const module = await import(pathToFileURL(entry).href);
  return Object.assign({}, module.default, module);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === '--path') console.log(runtimeDir);
  else if (args.length === 1 && args[0] === '--check') {
    try { await Promise.all(['playwright', 'postcss', 'postcss-value-parser', 'fontkit', 'sharp'].map(dependency)); }
    catch (error) { console.error(error.message); process.exitCode = 1; }
  }
  else if (args[0] === '--install' && args.length <= 2 && (!args[1] || args[1] === '--with-deps')) {
    await mkdir(runtimeDir, { recursive: true });
    for (const file of ['package.json', 'package-lock.json']) await copyFile(join(here, file), join(runtimeDir, file));
    const npm = spawnSync('npm', ['ci', '--prefix', runtimeDir], { stdio: 'inherit' });
    if (npm.status !== 0) process.exit(npm.status || 1);
    const browser = spawnSync(process.execPath, [join(runtimeDir, 'node_modules/playwright/cli.js'), 'install', ...(args[1] ? ['--with-deps'] : []), 'chromium'], { stdio: 'inherit', env: { ...process.env, PLAYWRIGHT_BROWSERS_PATH: '0' } });
    process.exitCode = browser.status || (browser.error ? 1 : 0);
  } else { console.error('usage: node runtime.mjs --path | --check | --install [--with-deps]'); process.exitCode = 2; }
}
