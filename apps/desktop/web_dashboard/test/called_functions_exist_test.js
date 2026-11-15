// Every bare function call in the static pages' scripts names something that
// exists: a function or binding the page declares, or a browser global. A call
// to a deleted helper is not a syntax error, so nothing else catches it until
// the line runs in a browser, and an event listener swallows the ReferenceError.
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const desktop = path.join(__dirname, '..', '..');

// The scripts each page loads, in order; they share one global scope.
const PAGES = {
  dashboard: [
    'web_dashboard/js/api.js',
    'web_dashboard/js/wire-events.js',
    'web_dashboard/js/app.js',
  ],
  'run watch': [
    'web_run_watch/js/wire-events.js',
    'web_run_watch/js/run-watch.js',
  ],
  'run watch service worker': ['web_run_watch/sw.js'],
};

// Browser globals the pages call that Node does not define.
const BROWSER_GLOBALS = new Set([
  'alert',
  'cancelAnimationFrame',
  'clients',
  'confirm',
  'createImageBitmap',
  'EventSource',
  'getComputedStyle',
  'importScripts',
  'matchMedia',
  'Notification',
  'prompt',
  'requestAnimationFrame',
  'requestIdleCallback',
  'skipWaiting',
]);

const KEYWORDS = new Set([
  'if', 'for', 'while', 'switch', 'catch', 'function', 'return', 'typeof',
  'new', 'await', 'async', 'yield', 'delete', 'void', 'in', 'of', 'do',
  'else', 'case', 'throw', 'instanceof', 'super', 'import', 'with',
]);

/** [source] with comments, strings, template text and regex literals blanked. */
function codeOnly(source) {
  let out = '';
  let i = 0;
  // What the last significant token was, to tell a regex from a division.
  let prev = '';
  const templateDepth = [];
  while (i < source.length) {
    const c = source[i];
    const next = source[i + 1];
    if (c === '/' && next === '/') {
      while (i < source.length && source[i] !== '\n') i += 1;
      continue;
    }
    if (c === '/' && next === '*') {
      const end = source.indexOf('*/', i + 2);
      const stop = end < 0 ? source.length : end + 2;
      out += source.slice(i, stop).replace(/[^\n]/g, ' ');
      i = stop;
      continue;
    }
    if (c === '"' || c === "'") {
      i += 1;
      while (i < source.length && source[i] !== c) {
        if (source[i] === '\\') i += 1;
        i += 1;
      }
      i += 1;
      out += '""';
      prev = '"';
      continue;
    }
    if (c === '`' || (c === '}' && templateDepth.length &&
        templateDepth[templateDepth.length - 1] === 0)) {
      if (c === '}') templateDepth.pop();
      i += 1;
      // Template text up to its end or the next `${`.
      while (i < source.length && source[i] !== '`') {
        if (source[i] === '\\') {
          i += 2;
          continue;
        }
        if (source[i] === '$' && source[i + 1] === '{') break;
        i += 1;
      }
      if (source[i] === '$') {
        templateDepth.push(0);
        i += 2;
        out += '"" + (';
      } else {
        i += 1;
        out += '""';
      }
      prev = '"';
      continue;
    }
    if (templateDepth.length) {
      if (c === '{') templateDepth[templateDepth.length - 1] += 1;
      if (c === '}') templateDepth[templateDepth.length - 1] -= 1;
    }
    if (c === '/' && (prev === '' || /[(,=:[!&|?{};+\-*%<>~^]/.test(prev) ||
        /\b(return|typeof|case)$/.test(out.trimEnd()))) {
      i += 1;
      let inClass = false;
      while (i < source.length && (source[i] !== '/' || inClass)) {
        if (source[i] === '\\') i += 1;
        else if (source[i] === '[') inClass = true;
        else if (source[i] === ']') inClass = false;
        i += 1;
      }
      i += 1;
      while (/[a-z]/i.test(source[i] || '')) i += 1;
      out += '/r/';
      prev = '/';
      continue;
    }
    out += c;
    if (!/\s/.test(c)) prev = c;
    i += 1;
  }
  return out;
}

/** Every name [code] binds: declarations, parameters, destructured names. */
function declaredNames(code) {
  const names = new Set();
  const add = (list) => {
    for (const raw of list.split(',')) {
      const name = raw.replace(/=.*$/s, '').replace(/[{}[\].:\s]/g, ' ')
        .trim().split(/\s+/).pop();
      if (name && /^[A-Za-z_$][\w$]*$/.test(name)) names.add(name);
    }
  };
  for (const m of code.matchAll(/\b(?:function|class)\s*\*?\s*([A-Za-z_$][\w$]*)/g)) {
    names.add(m[1]);
  }
  for (const m of code.matchAll(/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)/g)) {
    names.add(m[1]);
  }
  for (const m of code.matchAll(/\b(?:const|let|var)\s+([{[][^=]*?[}\]])\s*=/g)) {
    for (const n of m[1].matchAll(/[A-Za-z_$][\w$]*/g)) names.add(n[0]);
  }
  for (const m of code.matchAll(/\bfunction\s*\*?\s*[\w$]*\s*\(([^)]*)\)/g)) {
    add(m[1]);
  }
  for (const m of code.matchAll(/\(([^()]*)\)\s*=>/g)) add(m[1]);
  for (const m of code.matchAll(/([A-Za-z_$][\w$]*)\s*=>/g)) names.add(m[1]);
  for (const m of code.matchAll(/\bcatch\s*\(\s*([A-Za-z_$][\w$]*)/g)) {
    names.add(m[1]);
  }
  // Method shorthand in object literals and classes: `name(args) {`.
  for (const m of code.matchAll(/^\s*(?:async\s+)?([A-Za-z_$][\w$]*)\s*\(([^)]*)\)\s*\{/gm)) {
    if (!KEYWORDS.has(m[1])) add(m[2]);
  }
  return names;
}

/** Each bare call in [code]: `name(` not reached through a property. */
function bareCalls(code) {
  const calls = [];
  const lines = code.split('\n');
  lines.forEach((line, index) => {
    for (const m of line.matchAll(/(^|[^\w$.])([A-Za-z_$][\w$]*)\s*\(/g)) {
      const name = m[2];
      if (KEYWORDS.has(name)) continue;
      // `function name(` and method shorthand declare, they do not call.
      const before = line.slice(0, m.index + m[1].length);
      if (/\b(function\s*\*?|class)\s*$/.test(before)) continue;
      const after = line.slice(m.index + m[0].length);
      if (/^\s*((async|get|set|static)\s+)*$/.test(before) &&
          /^[^)]*\)\s*\{/.test(after)) {
        continue;
      }
      calls.push({ name, line: index + 1 });
    }
  });
  return calls;
}

for (const [page, files] of Object.entries(PAGES)) {
  test(`every function the ${page} calls exists`, () => {
    const sources = files.map((file) => ({
      file,
      code: codeOnly(fs.readFileSync(path.join(desktop, file), 'utf8')),
    }));
    const declared = new Set();
    for (const { code } of sources) {
      for (const name of declaredNames(code)) declared.add(name);
    }
    const missing = [];
    for (const { file, code } of sources) {
      for (const { name, line } of bareCalls(code)) {
        if (declared.has(name)) continue;
        if (name in globalThis || BROWSER_GLOBALS.has(name)) continue;
        missing.push(`${file}:${line} ${name}()`);
      }
    }
    assert.deepEqual(missing, [], 'calls to names nothing declares');
  });
}

test('a call to a deleted helper is caught', () => {
  const code = codeOnly([
    'function kept(a) { return a; }',
    "api.on('event', (data) => { if (!gone(data.type)) return; kept(1); });",
    "const s = `${kept(2)} text gone( still text`; // gone() in a comment",
  ].join('\n'));
  const declared = declaredNames(code);
  const missing = bareCalls(code).filter((c) => !declared.has(c.name) &&
    !(c.name in globalThis));
  assert.deepEqual(missing.map((c) => c.name), ['gone']);
});
