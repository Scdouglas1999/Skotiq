#!/usr/bin/env node
/**
 * Skotiq Web Dashboard — static smoke test (no build step, no browser).
 *
 * The dashboard is vanilla JS/CSS and is not Flutter-golden-able, so this is
 * the automated guard for it. It runs under plain `node` (no deps) and checks:
 *
 *   1. js/app.js and js/api.js parse with no syntax errors (node --check
 *      equivalent, via vm.compileFunction so it also runs in CI where the file
 *      is wrapped in an IIFE).
 *   2. The Phase F dashboard-polish hooks are present and consistent across the
 *      three source files — theme toggle, persisted panel collapse, and the
 *      WS-firehose-driven (not per-panel-polled) update model.
 *
 * Run:  node apps/desktop/web_dashboard/tools/smoke.mjs
 * Exit: 0 = all checks passed, 1 = a check failed (prints the failures).
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (rel) => readFileSync(join(root, rel), 'utf8');

const app = read('js/app.js');
const api = read('js/api.js');
const css = read('css/dashboard.css');
const html = read('index.html');

const failures = [];
const ok = [];

function check(name, cond) {
  if (cond) ok.push(name);
  else failures.push(name);
}

// --- 1. Syntax: both scripts must compile. -------------------------------
for (const [name, src] of [['js/app.js', app], ['js/api.js', api]]) {
  try {
    new vm.Script(src, { filename: name });
    ok.push('syntax: ' + name);
  } catch (e) {
    failures.push('syntax: ' + name + ' — ' + e.message);
  }
}

// --- 2a. Theme toggle wired end-to-end. ----------------------------------
check('html: theme toggle button present', /id="btn-theme-toggle"/.test(html));
check('css: light theme palette present', /\[data-theme="light"\]/.test(css));
check('js: setupTheme defined', /function setupTheme\(/.test(app));
check('js: setupTheme invoked in init', /\bsetupTheme\(\);/.test(app));
check('js: theme persisted to localStorage',
  /skotiq_theme/.test(app) && /localStorage\.setItem\(THEME_STORAGE_KEY/.test(app));
check('js: respects prefers-color-scheme on first load',
  /prefers-color-scheme/.test(app));
check('js: expanded auth controls retain a visible close toggle',
  /classList\.toggle\('hidden', !authRequired\)/.test(app) &&
  /'aria-expanded'/.test(app) && /Hide pairing and token controls/.test(app));
check('js: protected gallery route waits for authentication',
  /route === 'gallery' && api\.isConnected/.test(app));

// --- 2b. Persisted panel prefs (collapse). -------------------------------
check('js: setupPanelPrefs defined', /function setupPanelPrefs\(/.test(app));
check('js: setupPanelPrefs invoked in init', /\bsetupPanelPrefs\(\);/.test(app));
check('js: panel collapse persisted to localStorage',
  /skotiq_panel_collapsed/.test(app));
check('css: collapsed-panel style present', /\.panel\.is-collapsed/.test(css));

// --- 2c. WS firehose drives panels (no residual per-panel polling). ------
// The only setInterval calls allowed are: the 30s WS ping, the 2s staleness
// watchdog, and the 5s REST fallback that arms ONLY when the WS goes silent.
// Any other setInterval would be a per-panel poll regression.
const intervals = [...app.matchAll(/setInterval\(/g)].length;
check('js: panel updates are WS-event driven (<= 3 setInterval timers, all resilience)',
  intervals <= 3);
check('js: REST fallback gated on WS silence',
  /wsSilentMs > WS_FALLBACK_THRESHOLD_MS/.test(app));
check('js: events firehose fans out to panels',
  /api\.on\('event'/.test(app) && /function handleServerEvent\(/.test(app));

// --- Report -------------------------------------------------------------
for (const name of ok) console.log('  PASS  ' + name);
for (const name of failures) console.error('  FAIL  ' + name);
console.log('\n' + ok.length + ' passed, ' + failures.length + ' failed');
process.exit(failures.length ? 1 : 0);
