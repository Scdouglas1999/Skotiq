// Web-dashboard honesty contract.
//
// app.js is one closed IIFE with no exports, so — following the convention in
// app_initialization_contract_test.js — each render path under test is lifted
// out of the source and EXECUTED against a DOM shim with its collaborators
// injected. The assertions are about what lands in the document, not about how
// the source is spelled.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const { makeDocument } = require('./dom_shim');

const ROOT = path.join(__dirname, '..');
const APP = fs.readFileSync(path.join(ROOT, 'js', 'app.js'), 'utf8');
const API = fs.readFileSync(path.join(ROOT, 'js', 'api.js'), 'utf8');
const HTML = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');

/** Lift `function <name>(...) { … }` out of the IIFE by its 2-space indent. */
function fn(name) {
  const re = new RegExp(
    '(?:  |  async )function ' + name + '\\([^)]*\\) \\{[\\s\\S]*?\\n  \\}',
  );
  const m = APP.match(re);
  assert.ok(m, name + ' must exist in app.js');
  return m[0];
}

/**
 * Lift a top-level `const NAME = …;` declaration out of the IIFE. The value
 * may wrap over several lines — a derived threshold is spelled as the
 * arithmetic that produces it, and the test must read that arithmetic, not a
 * number retyped here.
 */
function konst(name) {
  const re = new RegExp('  const ' + name + ' =[\\s\\S]*?;');
  const m = APP.match(re);
  assert.ok(m, name + ' must exist in app.js');
  return m[0];
}

/** Lift a top-level `let NAME = …;` declaration out of the IIFE. */
function letDecl(name) {
  const re = new RegExp('  let ' + name + ' =[^;]*;');
  const m = APP.match(re);
  assert.ok(m, name + ' must exist in app.js');
  return m[0];
}

/** The REAL galleryCountLine, over the real galleryRejection. */
function countLine() {
  return build(
    [],
    [fn('galleryRejection'), fn('galleryCountLine')],
    'galleryCountLine',
  )();
}

/**
 * The REAL reportRefreshFailure, wired to recorders. Built from the source so
 * every caller's test exercises the actual cadence-vs-failure branch rather
 * than a stub that always records.
 */
function refreshFailureReporter({ marks = [], log = [], debug = [] } = {}) {
  const report = build(
    ['markPanelUnconfirmed', 'addLogEntry', 'describeApiError', 'console'],
    [fn('isCadenceRefusal'), fn('reportRefreshFailure')],
    'reportRefreshFailure',
  )(
    (k) => marks.push('unconfirmed:' + k),
    (kind, text) => log.push(kind + ': ' + text),
    build(['x'], [fn('describeApiError')], 'describeApiError')(null),
    { debug: (m) => debug.push(m) },
  );
  return { report, marks, log, debug };
}

function build(params, sources, exportName) {
  // eslint-disable-next-line no-new-func
  return new Function(
    ...params,
    sources.join('\n') + '\n;return ' + exportName + ';',
  );
}

// ---------------------------------------------------------------------------
// D4-05 — guider RMS
// ---------------------------------------------------------------------------

function guidingPanel(guidingStatus) {
  const doc = makeDocument([
    'guide-status', 'guide-ra-rms', 'guide-dec-rms', 'guide-total-rms',
  ]);
  const badges = [];
  const render = build(
    ['document', 'state', 'renderBadge', 'updateGuidingButtons'],
    [fn('renderGuidingPanel')],
    'renderGuidingPanel',
  )(
    doc,
    { guidingStatus },
    (el, label, cls) => { badges.push({ label, cls }); el.textContent = label; },
    () => {},
  );
  render();
  return { doc, badges };
}

// GET /api/phd2/status answers `rmsRa`/`rmsDec`/`rmsTotal`, all 0.0 while
// disconnected. The panel read `rmsRA` — a key no response carries — so the RA
// row was permanently "--", while Dec and Total rendered the disconnected
// zeros as a flawless 0.00" guide.
test('a disconnected guider shows no RMS in any row', () => {
  const { doc } = guidingPanel({
    state: 'Disconnected', connected: false,
    rmsRa: 0.0, rmsDec: 0.0, rmsTotal: 0.0, snr: 0.0,
  });
  assert.equal(doc.getElementById('guide-ra-rms').textContent, '--');
  assert.equal(doc.getElementById('guide-dec-rms').textContent, '--');
  assert.equal(doc.getElementById('guide-total-rms').textContent, '--');
});

test('a connected guider shows all three RMS rows from the real keys', () => {
  const { doc } = guidingPanel({
    state: 'Guiding', connected: true,
    rmsRa: 0.41, rmsDec: 0.38, rmsTotal: 0.56, snr: 22.5,
  });
  assert.equal(doc.getElementById('guide-ra-rms').textContent, '0.41"');
  assert.equal(doc.getElementById('guide-dec-rms').textContent, '0.38"');
  assert.equal(doc.getElementById('guide-total-rms').textContent, '0.56"');
});

test('the RA row reads the key the server sends', () => {
  const source = fn('renderGuidingPanel');
  assert.match(source, /g\.rmsRa\b/);
  assert.doesNotMatch(source, /g\.rmsRA\b/,
    'rmsRA matches nothing in /api/phd2/status');
});

// ---------------------------------------------------------------------------
// D4-10 — safety verdict with no sensor
// ---------------------------------------------------------------------------

function weatherPanel(weather, safety, { stale = false } = {}) {
  const doc = makeDocument([
    'ops-weather-safe', 'ops-weather-alert-level', 'ops-weather-message',
    'ops-weather-temp', 'ops-weather-humidity', 'ops-weather-clouds',
    'ops-weather-wind', 'ops-weather-dew', 'ops-safety-badge',
    'ops-safety-monitor-count', 'ops-safety-monitor-list',
  ]);
  const render = build(
    ['document', 'state', 'clearElement', 'weatherDataIsStale'],
    [fn('wireNumber'), fn('paintOpsWeatherUnknown'), fn('renderOpsWeatherPanel'),
      fn('setOpsTelemetry')],
    'renderOpsWeatherPanel',
  )(doc, { ops: { weather, safety } }, (el) => { el.children = []; },
    () => stale);
  render();
  return doc;
}

// A headless appliance with no weather hardware answers
// /api/weather/current with safeToImage:true, alertLevel:"clear",
// dataSource:"unavailable" and /api/safety/status with isSafe:true,
// monitorsConnected:0, failModeWarning:"No weather data sources available".
// Rendering the first two verbatim produced a green "yes / clear / safe" for a
// rig nothing was watching.
test('no weather source yields no affirmative safety verdict', () => {
  const doc = weatherPanel(
    {
      safeToImage: true, alertLevel: 'clear', dataSource: 'unavailable',
      message: 'Weather safety is off — conditions are not being checked',
    },
    {
      isSafe: true, monitorsConnected: 0, monitors: [],
      dataSource: 'unavailable',
      failModeWarning: 'No weather data sources available',
    },
  );
  const safe = doc.getElementById('ops-weather-safe');
  assert.equal(safe.textContent, 'no sensor');
  assert.ok(!safe.className.includes('good'));
  assert.equal(doc.getElementById('ops-weather-alert-level').textContent,
    'not measured');
  const badge = doc.getElementById('ops-safety-badge');
  assert.equal(badge.textContent, 'no source');
  assert.ok(!badge.className.includes('badge-running'),
    'an unmonitored sky must not read green');
});

test('a real sensor still renders its verdict', () => {
  const doc = weatherPanel(
    {
      safeToImage: true, alertLevel: 'clear', dataSource: 'hardware',
      message: 'Clear and dry', temperature: 4.5, humidity: 61,
    },
    { isSafe: true, monitorsConnected: 1, monitors: [], dataSource: 'hardware' },
  );
  assert.equal(doc.getElementById('ops-weather-safe').textContent, 'yes');
  assert.ok(doc.getElementById('ops-weather-safe').className.includes('good'));
  assert.equal(doc.getElementById('ops-weather-alert-level').textContent, 'clear');
  assert.equal(doc.getElementById('ops-safety-badge').textContent, 'safe');
  assert.equal(doc.getElementById('ops-weather-temp').textContent, '4.5 °C');
});

test('a real sensor reporting unsafe still reads unsafe', () => {
  const doc = weatherPanel(
    { safeToImage: false, alertLevel: 'unsafe', dataSource: 'hardware', message: 'Rain' },
    { isSafe: false, monitorsConnected: 1, monitors: [], dataSource: 'hardware' },
  );
  assert.equal(doc.getElementById('ops-weather-safe').textContent, 'no');
  assert.equal(doc.getElementById('ops-safety-badge').textContent, 'unsafe');
});

// D4W-1. Arm weather safety on a box with no weather hardware and no reachable
// forecast and the provider falls to fail_closed: /api/safety/status answers
// isSafe:false with dataSource 'unavailable', monitorsConnected 0 and
// failModeWarning "No weather data sources available". Answering the sensor
// question first turned that decision into "no sensor / no source" — a neutral
// absence where the rig had refused to image.
test('a fail-closed refusal outranks the no-sensor reading', () => {
  const doc = weatherPanel(
    {
      safeToImage: false, alertLevel: 'clear', dataSource: 'unavailable',
      message: 'No weather data sources available',
    },
    {
      isSafe: false, monitorsConnected: 0, monitors: [],
      dataSource: 'unavailable',
      failModeWarning: 'No weather data sources available',
    },
  );
  const safe = doc.getElementById('ops-weather-safe');
  assert.equal(safe.textContent, 'no');
  assert.ok(safe.className.includes('error'),
    'a refusal is not a warning about missing hardware');
  const badge = doc.getElementById('ops-safety-badge');
  assert.equal(badge.textContent, 'unsafe');
  assert.ok(badge.className.includes('badge-error'));
  assert.equal(doc.getElementById('ops-weather-message').textContent,
    'No weather data sources available');
});

// ---------------------------------------------------------------------------
// D4-04 — settings panel reads only keys the API emits
// ---------------------------------------------------------------------------

// Verified against a live headless host: GET /api/settings emits 146 keys, of
// which `observatoryName`, `defaultSavePath` and `plateSolveSolver` are none;
// GET /api/settings/location answers {latitude, longitude, elevation} with no
// `elevationMeters`. All four rows therefore read "--" on a configured host.
test('the settings panel reads the keys the API actually emits', async () => {
  const doc = makeDocument([
    'settings-observer-name', 'settings-save-path', 'settings-plate-solver',
    'settings-latitude', 'settings-longitude', 'settings-elevation',
  ]);
  const refresh = build(
    ['document', 'api', 'addLogEntry', 'settingsPanelHint'],
    [konst('SETTINGS_VALUE_IDS'), fn('clearSettingsWithheld'),
      fn('wireNumber'), fn('refreshSettingsPanel')],
    'refreshSettingsPanel',
  )(
    doc,
    {
      isConnected: true,
      getSettings: async () => ({
        settings: {
          observerName: 'S. Douglas',
          imageOutputPath: '/srv/lights',
          plateSolver: 'ASTAP',
        },
      }),
      getLocation: async () => ({
        location: { latitude: 40.1, longitude: -105.2, elevation: 1650.0 },
      }),
    },
    () => { throw new Error('the happy path must not log an error'); },
    null,
  );
  await refresh();

  assert.equal(doc.getElementById('settings-observer-name').textContent, 'S. Douglas');
  assert.equal(doc.getElementById('settings-save-path').textContent, '/srv/lights');
  assert.equal(doc.getElementById('settings-plate-solver').textContent, 'ASTAP');
  assert.equal(doc.getElementById('settings-latitude').textContent, '40.1000°');
  assert.equal(doc.getElementById('settings-elevation').textContent, '1650 m');
});

test('the settings panel names no key the server does not send', () => {
  // Comments name the dead keys on purpose; only executable lines are checked.
  const code = fn('refreshSettingsPanel')
    .split('\n')
    .filter((line) => !line.trim().startsWith('//'))
    .join('\n');
  for (const dead of ['observatoryName', 'defaultSavePath', 'plateSolveSolver',
    'elevationMeters']) {
    assert.doesNotMatch(code, new RegExp('\\b' + dead + '\\b'),
      dead + ' appears in no server response');
  }
  assert.match(HTML, /id="settings-observer-name"/);
  assert.doesNotMatch(HTML, /id="settings-observatory-name"/);
});

// ---------------------------------------------------------------------------
// D4-01 — a dead backend must flip the header, not stay green
// ---------------------------------------------------------------------------

/**
 * Stand the page's whole data clock up — the tick, the header subscriber, the
 * Run-panel subscriber and the per-panel stale lines — and hand back one
 * `render()` that drives all of them from one sample, exactly as the running
 * page does. Testing the header alone is what let the Run panel keep a second,
 * disagreeing clock.
 */
function linkState({ unreachable, lastContactAt, lastWsMessageAt,
  rateLimitRemainingSecs = 0, lastProbeAt = Date.now(), isConnected = true,
  panelLastUpdate = {}, panelLastFailure = {} }) {
  const doc = makeDocument([
    'link-banner', 'status-text', 'status-dot', 'seq-status', 'seq-node',
    'seq-message',
    'ops-seq-progress-text', 'seq-progress-text', 'seq-progress-bar',
    'seq-progress-bar-container', 'ops-seq-progress-bar',
    'ops-seq-progress-bar-container', 'ops-seq-eta', 'ops-seq-current-node',
    'ops-seq-current-target',
    'stale-devices', 'stale-mount', 'stale-camera', 'stale-sequencer',
    'stale-guiding', 'stale-focuser', 'stale-filter-wheel', 'stale-rotator',
    'stale-sequences', 'stale-analytics', 'stale-weather', 'stale-dome',
    'ops-weather-safe', 'ops-weather-alert-level', 'ops-weather-message',
    'ops-weather-temp', 'ops-weather-humidity', 'ops-weather-clouds',
    'ops-weather-wind', 'ops-weather-dew', 'ops-safety-badge',
    'ops-safety-monitor-count', 'ops-safety-monitor-list',
    'ops-dome-shutter', 'ops-dome-az', 'ops-dome-slewing', 'ops-dome-sync',
    'ops-dome-state-badge',
  ]);
  doc.getElementById('status-text').textContent = 'Connected';
  doc.getElementById('status-dot').className = 'status-dot connected';
  const calls = [];
  const repaints = [];
  // The ops panels keep their own list: the Run panel's recovery edge is
  // asserted exactly, and a sibling joining the clock must not read as a
  // second sequencer repaint.
  const opsRepaints = [];
  const zeroed = {
    devices: 0, mount: 0, camera: 0, sequencer: 0, guiding: 0,
    focuser: 0, 'filter-wheel': 0, rotator: 0, sequences: 0, analytics: 0,
    weather: 0, dome: 0,
  };
  // Mutable, so a test can move the clock and repaint through the SAME
  // closure — the flag the recovery edge turns off lives in there.
  const api = { lastContactAt, isConnected, rateLimitRemainingSecs };
  const state = {
    serverUnreachable: unreachable,
    lastWsMessageAt,
    panelLastUpdate: Object.assign({}, zeroed, panelLastUpdate),
    panelLastFailure: Object.assign({}, zeroed, panelLastFailure),
  };
  const render = build(
    ['document', 'api', 'state', 'lastReachabilityProbeAt',
      'setConnectionStatus', 'renderBadge', 'renderSequencerPanel',
      'renderOpsWeatherPanel', 'renderOpsDomePanel', 'clearElement'],
    [
      konst('REACHABILITY_PROBE_MS'),
      konst('SERVER_HEARTBEAT_MS'),
      konst('MISSED_HEARTBEATS_BEFORE_STALE'),
      konst('SERVER_CONTACT_STALE_MS'),
      konst('PANEL_KEYS'),
      letDecl('runUnknownAsserted'),
      letDecl('weatherUnknownAsserted'),
      letDecl('domeUnknownAsserted'),
      fn('lastServerContactAt'),
      fn('isServerContactStale'),
      fn('isPanelDataStale'),
      fn('formatAgeSeconds'),
      // The real helper, not a stub: what the stale branch does to the
      // progress readouts is the thing under test.
      fn('markProgressUnknown'),
      fn('renderLinkState'),
      fn('runDataIsStale'),
      fn('paintRunUnknown'),
      fn('renderRunDataState'),
      fn('weatherDataIsStale'),
      fn('paintOpsWeatherUnknown'),
      fn('renderOpsWeatherDataState'),
      fn('domeDataIsStale'),
      fn('paintOpsDomeUnknown'),
      fn('renderOpsDomeDataState'),
      fn('renderStaleIndicator'),
      // The tick itself, and the wiring init() performs — both real, so a
      // subscriber the page forgets to register fails here too.
      'const dataClockSubscribers = [];',
      fn('subscribeToDataClock'),
      fn('repaintDataState'),
      `subscribeToDataClock(renderLinkState);
       subscribeToDataClock(renderRunDataState);
       subscribeToDataClock(renderOpsWeatherDataState);
       subscribeToDataClock(renderOpsDomeDataState);
       for (const panelKey of PANEL_KEYS) {
         subscribeToDataClock((view) => renderStaleIndicator(panelKey, view));
       }`,
    ],
    'repaintDataState',
  )(
    doc,
    api,
    state,
    lastProbeAt,
    (s) => {
      calls.push(s);
      if (s === 'connected') {
        doc.getElementById('status-text').textContent = 'Connected';
      }
    },
    (el, label, cls) => { el.textContent = label; el.className = cls; },
    () => { repaints.push('sequencer'); },
    () => { opsRepaints.push('weather'); },
    () => { opsRepaints.push('dome'); },
    (el) => { el.children = []; },
  );
  render();
  return { doc, calls, repaints, opsRepaints, render, api, state };
}

// Measured before the fix: 65 s after SIGKILL the header still read a green
// "Connected", the sequencer badge still read "running", and the weather panel
// still read "safe". `api.isConnected` is set once at connect and never
// cleared, so nothing in the page ever contradicted it.
test('an unreachable server flips the header and raises a banner', () => {
  const now = Date.now();
  const { doc } = linkState({
    unreachable: true,
    lastContactAt: now - 30000,
    lastWsMessageAt: now - 30000,
    lastProbeAt: now - 1000,
  });
  assert.equal(doc.getElementById('status-text').textContent, 'No contact');
  assert.ok(doc.getElementById('status-dot').className.includes('error'));
  const banner = doc.getElementById('link-banner');
  assert.ok(!banner.classList.contains('hidden'));
  assert.match(banner.textContent, /Cannot reach the Skotiq server/);
  assert.match(banner.textContent, /may be wrong/);
  assert.equal(doc.getElementById('seq-status').textContent, 'unknown',
    'the sequencer badge must stop claiming a state');
});

// D4W-02. The badge was fixed and the figure was not. Measured against the
// running bundle: SIGKILL at wire progress 0.250 left the badge "unknown" and
// the banner up while "25%" stayed on screen, the bar stayed 94.75px wide and
// the container kept announcing aria-valuenow="25" — for the whole 47 s the
// probe watched. The sibling ops readout was correctly "--" the entire time,
// so the page contradicted itself as well as the world.
test('a lost link stops asserting a progress figure', () => {
  const now = Date.now();
  const seed = (doc) => {
    doc.getElementById('seq-progress-text').textContent = '25%';
    doc.getElementById('seq-progress-bar').style.width = '25%';
    doc.getElementById('seq-progress-bar-container')
      .setAttribute('aria-valuenow', '25');
    doc.getElementById('ops-seq-progress-text').textContent = '25%';
    doc.getElementById('ops-seq-progress-bar').style.width = '25%';
    doc.getElementById('ops-seq-progress-bar-container')
      .setAttribute('aria-valuenow', '25');
    doc.getElementById('ops-seq-eta').textContent = '12m';
  };
  // Render once healthy so the seeded values are what a live run left behind,
  // then lose the server through the same closure.
  const h = linkState({
    unreachable: false,
    lastContactAt: now - 500,
    lastWsMessageAt: now - 500,
  });
  seed(h.doc);
  h.state.serverUnreachable = true;
  h.api.lastContactAt = now - 47000;
  h.state.lastWsMessageAt = now - 47000;
  h.render();

  const doc = h.doc;
  assert.equal(doc.getElementById('seq-status').textContent, 'unknown');
  for (const id of ['seq-progress-text', 'ops-seq-progress-text']) {
    assert.equal(doc.getElementById(id).textContent, '--',
      id + ' must stop naming a percentage');
  }
  for (const id of ['seq-progress-bar', 'ops-seq-progress-bar']) {
    assert.equal(doc.getElementById(id).style.width, '0%');
    assert.ok(doc.getElementById(id).classList.contains('unknown'),
      id + ' must not draw as a run that has done nothing');
  }
  for (const id of ['seq-progress-bar-container',
    'ops-seq-progress-bar-container']) {
    assert.equal(doc.getElementById(id).getAttribute('aria-valuenow'), null,
      id + ' must stop announcing a figure');
    assert.ok(doc.getElementById(id).classList.contains('unknown'));
  }
  // The ETA is extrapolated from that percentage; it cannot outlive it.
  assert.equal(doc.getElementById('ops-seq-eta').textContent, '--');
});

test('an unknown bar is visually distinct from a genuine zero', () => {
  // The two states share `width: 0%`, so the distinction has to be carried by
  // something else, and something else has to actually paint it.
  const css = fs.readFileSync(
    path.join(ROOT, 'css', 'dashboard.css'), 'utf8');
  assert.match(css, /\.progress-bar-container\.unknown\s*\{[\s\S]*?background-image/,
    'the unknown track must have its own rendering');
});

test('silence past the contact window is stale even without a failed probe', () => {
  const now = Date.now();
  // Two whole heartbeats missed and then some: nothing has answered for well
  // over a minute on a link the socket still believes is up.
  const { doc } = linkState({
    unreachable: false,
    lastContactAt: now - 70000,
    lastWsMessageAt: now - 70000,
  });
  assert.equal(doc.getElementById('status-text').textContent, 'No contact');
  assert.match(doc.getElementById('link-banner').textContent,
    /No answer from the Skotiq server/);
});

// D4W-1. An idle server pushes no events, so the 30 s ping/pong is the only
// thing that stamps contact and the gap between beats routinely reaches a full
// interval. Measured against the 12 s window this code used to carry: over a
// 200 s soak of a healthy, idle server the header spent 26 of 40 samples on
// "No contact" while every request in flight was being answered.
test('a healthy idle server between heartbeats is never declared lost', () => {
  const now = Date.now();
  for (const gap of [12001, 20000, 29500, 35000]) {
    const { doc } = linkState({
      unreachable: false,
      lastContactAt: now - gap,
      lastWsMessageAt: now - gap,
    });
    assert.equal(doc.getElementById('status-text').textContent, 'Connected',
      gap + ' ms since the last beat is quiet, not lost');
    assert.ok(doc.getElementById('link-banner').classList.contains('hidden'),
      'no banner at ' + gap + ' ms');
    assert.equal(doc.getElementById('seq-status').textContent, '',
      'the badge is left to the sequencer renderer at ' + gap + ' ms');
  }
});

// D4W-2. Staleness is a state of the link, not a mark burned into the badge:
// the badge that went "unknown" on a missed exchange stayed "unknown" for the
// rest of the session — through every later healthy poll — because only the
// header was ever restored.
test('contact returning hands the badge back to the real renderer', () => {
  const now = Date.now();
  const { doc, calls, repaints, render, api, state } = linkState({
    unreachable: true,
    lastContactAt: now - 70000,
    lastWsMessageAt: now - 70000,
    lastProbeAt: now - 1000,
  });
  assert.equal(doc.getElementById('seq-status').textContent, 'unknown');
  assert.deepEqual(repaints, [], 'nothing to restore while still stale');

  // The server answers again.
  api.lastContactAt = Date.now();
  state.lastWsMessageAt = Date.now();
  state.serverUnreachable = false;
  render();

  assert.deepEqual(repaints, ['sequencer'],
    'the sequencer panel repaints from the data, not from the overlay');
  assert.ok(calls.includes('connected'));
  assert.ok(doc.getElementById('link-banner').classList.contains('hidden'));

  // A second healthy tick must not keep repainting: the edge fired once.
  render();
  assert.deepEqual(repaints, ['sequencer']);
});

test('a healthy link leaves the header alone and hides the banner', () => {
  const now = Date.now();
  const { doc } = linkState({
    unreachable: false,
    lastContactAt: now - 500,
    lastWsMessageAt: now - 500,
  });
  assert.equal(doc.getElementById('status-text').textContent, 'Connected');
  assert.ok(doc.getElementById('link-banner').classList.contains('hidden'));
});

test('a rate-limited but live server says so without going stale', () => {
  const now = Date.now();
  const { doc } = linkState({
    unreachable: false,
    lastContactAt: now - 500,
    lastWsMessageAt: now - 500,
    rateLimitRemainingSecs: 3,
  });
  assert.equal(doc.getElementById('status-text').textContent, 'Connected');
  const banner = doc.getElementById('link-banner');
  assert.ok(!banner.classList.contains('hidden'));
  assert.match(banner.textContent, /rate-limiting this session/);
  assert.match(banner.textContent, /3s/);
});

// ---------------------------------------------------------------------------
// D4-03 — 429 handling
// ---------------------------------------------------------------------------

function loadApi(fetchStub) {
  const context = vm.createContext({
    fetch: fetchStub,
    Headers: globalThis.Headers,
    AbortController: globalThis.AbortController,
    setTimeout: globalThis.setTimeout,
    clearTimeout: globalThis.clearTimeout,
    Date: globalThis.Date,
    isFinite: globalThis.isFinite,
    Number: globalThis.Number,
    JSON: globalThis.JSON,
    console,
  });
  vm.runInContext(API + '\n;globalThis.__api = new SkotiqApi();', context);
  return context.__api;
}

const RATE_LIMIT_BODY = JSON.stringify({
  code: 'rate_limited', error: 'Rate limit exceeded',
  message: 'Token token-6e609b0e exceeded read bucket',
  bucket: 'read', maxRequests: 60, retryAfterSecs: 3, retryAfterSeconds: 3,
  requestId: 'dash-abc',
});

// Reproduced against a live host: a burst put the limiter's JSON body straight
// into the operator's log panel — "Settings fetch failed: GET /api/settings
// failed (429): {"code":"rate_limited",…}" — and nothing honoured
// retryAfterSecs, so the next tick fired into the same empty bucket.
test('a 429 becomes a typed retry window, never a rendered body', async () => {
  let calls = 0;
  const api = loadApi(async () => {
    calls += 1;
    return {
      ok: false, status: 429,
      headers: new Headers({ 'retry-after': '3' }),
      text: async () => RATE_LIMIT_BODY,
    };
  });

  await assert.rejects(
    () => api.getSettings(),
    (e) => e.kind === 'rate_limited' && e.retryAfterSecs === 3 &&
      !/rate_limited|maxRequests|requestId/.test(e.message),
  );
  assert.equal(calls, 1);
  assert.equal(api.rateLimitRemainingSecs, 3);

  // Inside the window no request leaves the page.
  await assert.rejects(() => api.getSettings(), (e) => e.kind === 'rate_limited');
  assert.equal(calls, 1, 'the client must not re-fire inside the retry window');
});

test('a transport failure is typed unreachable and stamps no contact', async () => {
  const api = loadApi(async () => { throw new TypeError('Failed to fetch'); });
  await assert.rejects(() => api.getInfo(), (e) => e.kind === 'unreachable');
  assert.equal(api.lastContactAt, 0,
    'a fetch that never completed is not proof the server exists');
});

test('any answered request counts as contact, even a 500', async () => {
  const api = loadApi(async () => ({
    ok: false, status: 500, headers: new Headers(), text: async () => 'boom',
  }));
  await assert.rejects(() => api.getInfo(), (e) => e.kind === 'http_error');
  assert.ok(api.lastContactAt > 0);
});

test('describeApiError never leaks a rate-limit body into the log', () => {
  const describe = build(['x'], [fn('describeApiError')], 'describeApiError')(null);
  const limited = describe(
    { kind: 'rate_limited', retryAfterSecs: 3, message: RATE_LIMIT_BODY },
    'Settings fetch',
  );
  assert.match(limited, /rate-limiting this session/);
  assert.doesNotMatch(limited, /rate_limited|maxRequests|requestId/);
  assert.match(
    describe({ kind: 'unreachable', message: 'x' }, 'Devices fetch'),
    /no answer from the server/,
  );
  assert.match(
    describe({ kind: 'http_error', message: 'GET /api/x failed (404): gone' }, 'X'),
    /404/,
    'a real HTTP error keeps its detail',
  );
});

// ---------------------------------------------------------------------------
// D4-08 — aria-valuenow
// ---------------------------------------------------------------------------

test('no progress bar declares aria-valuenow before it has a value', () => {
  const bars = HTML.match(/<div class="progress-bar-container"[^>]*>/g) || [];
  assert.ok(bars.length >= 2, 'both sequencer progress bars must exist');
  for (const bar of bars) {
    assert.doesNotMatch(bar, /aria-valuenow/,
      'markup must not announce a percentage nothing has reported');
  }
  // Both panels reach the clearing through the one helper now, so the helper is
  // where the rule lives — and the callers must be the ones using it.
  assert.match(fn('markProgressUnknown'), /removeAttribute\('aria-valuenow'\)/,
    'the unknown render must clear the announced value');
  for (const name of ['renderSequencerPanel', 'renderOpsSequencerLoadPanel',
    'paintRunUnknown']) {
    const source = fn(name);
    assert.match(source, /markProgressUnknown\(/,
      name + ' must clear the value when the figure is unknown');
    assert.doesNotMatch(source, /setAttribute\('aria-valuenow', '0'\)/);
  }
});

// ---------------------------------------------------------------------------
// D4W-5 — before the first answer, the page is connecting, not reporting
// ---------------------------------------------------------------------------

test('the sequencer badge asserts nothing before the first status', () => {
  const doc = makeDocument([
    'seq-status', 'seq-node', 'seq-message', 'seq-progress-bar',
    'seq-progress-bar-container', 'seq-progress-text',
  ]);
  const render = build(
    ['document', 'state', 'renderBadge', 'updateSequencerButtons',
      'getSequencerBadgeClass', 'sequencerProgressPercent',
      'renderOpsSequencerLoadPanel', 'runDataIsStale', 'paintRunUnknown'],
    [fn('markProgressUnknown'), fn('markProgressKnown'),
      fn('renderSequencerPanel')],
    'renderSequencerPanel',
  )(
    doc,
    { sequencerStatus: null },
    (el, label, cls) => { el.textContent = label; el.className = cls; },
    () => {},
    () => 'badge-idle',
    () => 0,
    () => {},
    // A healthy link with a fresh sequencer route: this test is about the
    // page before its FIRST answer, not about a stale one.
    () => false,
    () => { throw new Error('the unknown overlay must not fire on a fresh link'); },
  );
  render();
  assert.equal(doc.getElementById('seq-status').textContent, 'connecting',
    'a rig this page has never heard from is not "idle"');
  assert.equal(doc.getElementById('seq-progress-text').textContent, '');
  assert.equal(
    doc.getElementById('seq-progress-bar-container')
      .getAttribute('aria-valuenow'),
    null,
  );
  assert.ok(doc.getElementById('seq-progress-bar').classList
    .contains('unknown'),
  'a bar that has heard nothing must not draw as a real zero');

  // The shipped markup is what the operator sees for the first few hundred ms,
  // before any JS has run — it must make the same claim, which is none.
  const badge = HTML.match(/<span id="seq-status">[\s\S]*?<\/span>\s*<\/span>/);
  assert.ok(badge, 'the sequencer status badge must exist in the markup');
  assert.match(badge[0], />connecting</);
});

// ---------------------------------------------------------------------------
// D4W-01 — the server log tail
// ---------------------------------------------------------------------------

/// An EventSource good enough to prove which listener kind a client used.
class FakeEventSource {
  constructor(url) {
    this.url = url;
    this.listeners = new Map();
    this.onmessage = null;
    this.onerror = null;
    this.onopen = null;
    FakeEventSource.last = this;
  }
  addEventListener(name, fn) {
    if (!this.listeners.has(name)) this.listeners.set(name, []);
    this.listeners.get(name).push(fn);
  }
  close() { this.closed = true; }

  /// Deliver a frame the way the server writes it: `event: <name>` + data.
  /// A named frame does NOT reach `onmessage` — that is the whole defect.
  emit(name, data) {
    const event = { data: JSON.stringify(data) };
    for (const fn of this.listeners.get(name) || []) fn(event);
    if (name === 'message' && this.onmessage) this.onmessage(event);
  }
}

function apiWithEventSource() {
  const context = vm.createContext({
    fetch: async () => { throw new Error('no fetch in this test'); },
    Headers: globalThis.Headers,
    AbortController: globalThis.AbortController,
    setTimeout: globalThis.setTimeout,
    clearTimeout: globalThis.clearTimeout,
    Date: globalThis.Date,
    isFinite: globalThis.isFinite,
    Number: globalThis.Number,
    JSON: globalThis.JSON,
    EventSource: FakeEventSource,
    encodeURIComponent: globalThis.encodeURIComponent,
    console,
  });
  vm.runInContext(API + '\n;globalThis.__api = new SkotiqApi();', context);
  const api = context.__api;
  // The bearer rides in the query string: EventSource has no header API.
  api._authToken = 'tok-1';
  return api;
}

// Measured against the running bundle: the panel sat on "Waiting for log
// entries…" behind a badge reading "live" while a second EventSource attached
// to the IDENTICAL url counted 174 frames on `addEventListener('log', …)` and
// 0 on `onmessage`, over the same 12 s. `log_handlers.dart` names every frame
// (`event: log`), and EventSource.onmessage fires only for unnamed ones.
test('the log tail listens for the frames the server actually names', () => {
  const api = apiWithEventSource();
  const seen = [];
  let replayDone = 0;
  api.subscribeLogTail('info', (e) => seen.push(e), null, () => { replayDone++; });
  const source = FakeEventSource.last;

  source.emit('log', {
    timestamp: '2026-08-17T13:36:11.111819Z',
    severity: 'warning',
    source: 'HeadlessMain',
    message: 'SECURITY: TLS IS OFF',
  });
  source.emit('replay-done', {});

  assert.equal(seen.length, 1, 'a named "log" frame is an entry');
  assert.equal(seen[0].source, 'HeadlessMain');
  assert.equal(replayDone, 1, 'the end of the replay is the server\'s own event');
  assert.equal(source.onmessage, null,
    'nothing may hang off onmessage: this endpoint sends no unnamed frames');
});

// The tail reads `severity` — an allow-LIST of exact level names. `minSeverity`
// is /api/logs/recent's parameter and is ignored here, so the panel's selector
// filtered nothing at all: a debug firehose arrived on a stream asked for
// "info". Verified on the wire — `minSeverity=info` returned 2 debug entries in
// the same window where `severity=info,warning,error,critical` returned none.
test('the log tail asks for the severities with the parameter that filters', () => {
  const api = apiWithEventSource();
  api.subscribeLogTail('warning', () => {}, null);
  const url = FakeEventSource.last.url;
  assert.match(url, /severity=warning%2Cerror%2Ccritical/);
  assert.doesNotMatch(url, /minSeverity/,
    'minSeverity is silently ignored by /api/logs/tail');

  // The names are the server's own LogLevel values; "trace" and "warn" parse
  // as nothing on the other side.
  // Spread back into this realm: the vm sandbox's Array is a different class.
  const ctor = api.constructor;
  assert.deepEqual([...ctor.logLevels],
    ['debug', 'info', 'warning', 'error', 'critical']);
  assert.deepEqual([...ctor.logSeveritiesAtOrAbove('trace')], [],
    'an unknown name filters nothing rather than narrowing silently');
});

test('the severity selector offers only levels the server knows', () => {
  const select = HTML.match(
    /<select id="logs-min-severity"[\s\S]*?<\/select>/);
  assert.ok(select, 'the severity selector must exist');
  const values = [...select[0].matchAll(/value="([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(values, ['debug', 'info', 'warning', 'error', 'critical']);
});

test('a log row reads the keys a log frame carries', () => {
  const doc = makeDocument(['logs-container']);
  const append = build(
    ['document', 'logTail'],
    [fn('appendLogRow')],
    'appendLogRow',
  )(doc, { maxEntries: 500 });
  append({
    timestamp: '2026-08-17T13:36:11.111819Z',
    severity: 'warning',
    source: 'DeliveryRetrySweeper',
    message: 'Started the Darkroom delivery retry sweep (every 900s).',
  });
  const row = doc.getElementById('logs-container').children[0];
  const text = row.children.map((c) => c.textContent);
  assert.ok(text.includes('WARNING'), 'the severity comes from `severity`');
  assert.ok(text.includes('DeliveryRetrySweeper'),
    'the source column comes from `source` — `target` is a key no frame has');
  assert.ok(row.className.includes('log-warning'));

  // The keys that were being read and are not in `LogEntry.toJson`.
  const code = fn('appendLogRow')
    .split('\n')
    .filter((line) => !line.trim().startsWith('//'))
    .join('\n');
  for (const dead of ['payload.level', 'payload.target', 'payload.module',
    'payload.category', 'payload.msg', 'payload.timestampMs']) {
    assert.ok(!code.includes(dead), dead + ' appears in no log frame');
  }
});

// ---------------------------------------------------------------------------
// D4-01 (wave 6) — one failing route must not leave the Run panel painting a
// frozen run as live
//
// Measured against the running bundle with /api/sequencer/status substituted
// for a plain HTTP 500 and EVERY other request reaching the real daemon: 66
// refused refreshes over 45 s, every 5 s sample identical —
//   hdr='Connected' seq='running' node='Exposure L' pct='3%'
//   msg='Exposure: Frame 2/20 (5.0s) (10%)' staleBadge=hidden
// while the wire read state=running progress=0.1375 'Frame 11/20'. The page
// asserted 3% for a rig at 13.75%, under a green header, with the per-panel
// stale badge suppressed by its `wsHealthy` gate because the event socket was
// perfectly healthy the whole time.
// ---------------------------------------------------------------------------

/** The page mid-run: everything fresh, the sequencer route just refused. */
function runPanelWithFailingRoute(agoMs) {
  const now = Date.now();
  const fresh = now - 1000;
  const h = linkState({
    unreachable: false,
    lastContactAt: now - 200,
    lastWsMessageAt: now - 200,
    panelLastUpdate: {
      devices: fresh, mount: fresh, camera: fresh, sequencer: now - agoMs,
      guiding: fresh, focuser: fresh, 'filter-wheel': fresh, rotator: fresh,
    },
  });
  // A live run is on screen when the route starts failing.
  h.doc.getElementById('seq-status').textContent = 'running';
  h.doc.getElementById('seq-node').textContent = 'Exposure L';
  h.doc.getElementById('seq-message').textContent =
    'Exposure: Frame 2/20 (5.0s) (10%)';
  h.doc.getElementById('seq-progress-text').textContent = '3%';
  h.doc.getElementById('seq-progress-bar').style.width = '3%';
  h.doc.getElementById('seq-progress-bar-container')
    .setAttribute('aria-valuenow', '3');
  h.doc.getElementById('ops-seq-eta').textContent = '31m';
  return h;
}

test('a failing sequencer route stops the Run panel asserting a live run', () => {
  const h = runPanelWithFailingRoute(45000);
  // The link is fine: the server is answering everything else, and the header
  // must go on saying so.
  assert.equal(h.doc.getElementById('status-text').textContent, 'Connected');
  assert.ok(h.doc.getElementById('link-banner').classList.contains('hidden'));
  assert.equal(h.doc.getElementById('seq-status').textContent, 'running',
    'a healthy route is not stale merely because 45 s have passed');

  // Now the route refuses. Nothing else about the page changes.
  h.state.panelLastFailure.sequencer = Date.now();
  h.render();

  assert.equal(h.doc.getElementById('seq-status').textContent, 'unknown',
    'the badge must stop claiming a state its own source refused to confirm');
  assert.equal(h.doc.getElementById('seq-progress-text').textContent, '--');
  assert.equal(
    h.doc.getElementById('seq-progress-bar-container')
      .getAttribute('aria-valuenow'), null);
  assert.equal(h.doc.getElementById('seq-node').textContent, '--');
  assert.equal(h.doc.getElementById('seq-message').textContent, '');
  assert.equal(h.doc.getElementById('ops-seq-eta').textContent, '--');
});

test('a failing route says on the panel how old its data is', () => {
  const h = runPanelWithFailingRoute(45000);
  h.state.panelLastFailure.sequencer = Date.now();
  h.render();

  const badge = h.doc.getElementById('stale-sequencer');
  assert.ok(badge.classList.contains('visible'),
    'a healthy event socket must not suppress the panel that is failing');
  assert.match(badge.textContent, /Stale: 45s since last update/);
  // Only the panel that failed. The rest of the rig is being reported fine.
  for (const key of ['devices', 'mount', 'camera', 'guiding', 'focuser',
    'filter-wheel', 'rotator']) {
    assert.equal(h.doc.getElementById('stale-' + key).textContent, '',
      key + ' is answering and must not be marked stale');
  }
});

test('a quiet but healthy night marks nothing stale', () => {
  // The whole reason the suppressing gate existed: an idle server pushes no
  // events, so a panel's last refresh can be minutes old with nothing wrong.
  const now = Date.now();
  const h = linkState({
    unreachable: false,
    lastContactAt: now - 2000,
    lastWsMessageAt: now - 2000,
    panelLastUpdate: {
      devices: now - 600000, mount: now - 600000, camera: now - 600000,
      sequencer: now - 600000, guiding: now - 600000, focuser: now - 600000,
      'filter-wheel': now - 600000, rotator: now - 600000,
    },
  });
  for (const key of ['devices', 'mount', 'camera', 'sequencer', 'guiding',
    'focuser', 'filter-wheel', 'rotator']) {
    assert.equal(h.doc.getElementById('stale-' + key).textContent, '',
      key + ' has nothing new to report, which is not the same as stale');
  }
  assert.equal(h.doc.getElementById('seq-status').textContent, '',
    'the Run panel is left to its own renderer on a healthy night');
});

test('a route that answers again hands the Run panel back to its renderer', () => {
  const h = runPanelWithFailingRoute(45000);
  h.state.panelLastFailure.sequencer = Date.now();
  h.render();
  assert.equal(h.doc.getElementById('seq-status').textContent, 'unknown');
  assert.deepEqual(h.repaints, [], 'nothing to restore while still stale');

  // The next refresh succeeds.
  h.state.panelLastUpdate.sequencer = Date.now();
  h.render();
  assert.deepEqual(h.repaints, ['sequencer'],
    'the panel repaints from the data, not from the overlay');
  assert.equal(h.doc.getElementById('stale-sequencer').textContent, '');

  // A second healthy tick must not keep repainting: the edge fired once.
  h.render();
  assert.deepEqual(h.repaints, ['sequencer']);
});

test('the header and the panels age their data on one clock', () => {
  // The header's verdict is a page-wide fact: when contact is gone, every
  // panel is stale too, without each one needing its own failure recorded.
  const now = Date.now();
  const h = linkState({
    unreachable: true,
    lastContactAt: now - 70000,
    lastWsMessageAt: now - 70000,
    lastProbeAt: now - 1000,
    panelLastUpdate: {
      devices: now - 70000, mount: now - 70000, camera: now - 70000,
      sequencer: now - 70000, guiding: now - 70000, focuser: now - 70000,
      'filter-wheel': now - 70000, rotator: now - 70000,
      sequences: now - 70000, analytics: now - 70000,
    },
  });
  assert.equal(h.doc.getElementById('status-text').textContent, 'No contact');
  for (const key of ['devices', 'mount', 'camera', 'sequencer', 'guiding',
    'focuser', 'filter-wheel', 'rotator', 'sequences', 'analytics']) {
    assert.match(h.doc.getElementById('stale-' + key).textContent,
      /Stale: 1m 10s since last update/,
      key + ' must age from the same verdict the header reached');
  }
});

// D4-4. Measured across a SIGTERM with the dashboard open on a live run: at
// +8 s / +18 s / +38 s / +68 s the banner read "Every value below is from then
// and may be wrong", the Run panel had gone to unknown/--/--, and seven
// sibling panels carried a "Stale: …" line — while the Sequences panel went on
// naming "M long night" as the Current target and the Analytics panel went on
// reporting 15 frames, neither of them marked at all. They were simply not on
// the clock: PANEL_KEYS never named them and the markup had no line for them
// to write into.
test('the Sequences and Analytics panels age like their siblings', () => {
  const now = Date.now();
  const h = linkState({
    unreachable: true,
    lastContactAt: now - 68000,
    lastWsMessageAt: now - 68000,
    lastProbeAt: now - 1000,
    panelLastUpdate: { sequences: now - 68000, analytics: now - 68000 },
  });
  for (const key of ['sequences', 'analytics']) {
    assert.match(h.doc.getElementById('stale-' + key).textContent,
      /Stale: 1m 8s since last update/,
      key + ' must say its data is as old as the header says it is');
  }
  // And the line has somewhere to land in the shipped markup.
  for (const id of ['stale-sequences', 'stale-analytics']) {
    assert.match(HTML, new RegExp('id="' + id + '"'),
      id + ' must exist in index.html or the wiring writes into nothing');
  }
});

// D4-4, second half. paintRunUnknown clears every other claim the two panels
// make about a run whose source has stopped answering — the badge, both
// progress bars, the ETA, the node, the message — and left the target alone,
// so "Current target: M long night" outlived all of them by 68 s.
test('a retired run leaves no target named either', () => {
  const now = Date.now();
  const h = linkState({
    unreachable: true,
    lastContactAt: now - 68000,
    lastWsMessageAt: now - 68000,
    lastProbeAt: now - 1000,
  });
  const target = h.doc.getElementById('ops-seq-current-target');
  target.textContent = 'M long night';
  h.render();
  assert.equal(target.textContent, '--',
    'the target is a claim about the run, and it dies with the run');
});

// Observed on screen during the fix's own re-reproduction: the Run panel had
// gone honest (UNKNOWN / -- / --) while the Sequences panel two columns away
// still read "Current node: Autofocus (HFR Degradation) / Progress 5%". Both
// quote the same cached status, and the ops panel is repainted by sibling
// fetches — the analytics summary, a slew, the first paint — that go on
// succeeding while the sequencer route refuses.
test('the ops mirror cannot repaint a run the clock has already retired', () => {
  const doc = makeDocument([
    'seq-status', 'seq-node', 'seq-message', 'seq-progress-text',
    'seq-progress-bar', 'seq-progress-bar-container',
    'ops-seq-current-target', 'ops-seq-current-node', 'ops-seq-progress-text',
    'ops-seq-progress-bar', 'ops-seq-progress-bar-container', 'ops-seq-eta',
  ]);
  const now = Date.now();
  const state = {
    // A live run, cached from the last answer that landed.
    sequencerStatus: {
      state: 'running',
      currentNodeName: 'Autofocus (HFR Degradation)',
      progress: 0.05,
      message: 'Autofocus: step 0/9 (37%)',
    },
    serverUnreachable: false,
    lastWsMessageAt: now - 200,
    // ...and a sequencer route that refused after it.
    panelLastUpdate: { sequencer: now - 45000 },
    panelLastFailure: { sequencer: now - 1000 },
    ops: { sessionSummary: null, sequenceStartedAt: now - 60000 },
  };
  const render = build(
    ['document', 'api', 'state', 'lastReachabilityProbeAt', 'renderBadge',
      'sequencerProgressPercent', 'formatDurationSeconds'],
    [
      konst('REACHABILITY_PROBE_MS'),
      konst('SERVER_HEARTBEAT_MS'),
      konst('MISSED_HEARTBEATS_BEFORE_STALE'),
      konst('SERVER_CONTACT_STALE_MS'),
      fn('lastServerContactAt'),
      fn('isServerContactStale'),
      fn('isPanelDataStale'),
      fn('runDataIsStale'),
      fn('markProgressUnknown'),
      fn('markProgressKnown'),
      fn('paintRunUnknown'),
      fn('renderOpsSequencerLoadPanel'),
    ],
    'renderOpsSequencerLoadPanel',
  )(
    doc,
    { lastContactAt: now - 200, isConnected: true, rateLimitRemainingSecs: 0 },
    state,
    now - 1000,
    (el, label, cls) => { el.textContent = label; el.className = cls; },
    build(['x'], [fn('sequencerProgressPercent')], 'sequencerProgressPercent')(null),
    () => '3m',
  );
  render();

  assert.equal(doc.getElementById('ops-seq-current-node').textContent, '--',
    'the ops mirror must not name a node its source refused to confirm');
  assert.equal(doc.getElementById('ops-seq-progress-text').textContent, '--');
  assert.equal(doc.getElementById('ops-seq-eta').textContent, '--');
  assert.equal(
    doc.getElementById('ops-seq-progress-bar-container')
      .getAttribute('aria-valuenow'), null);
  // And it silences the Run panel with it, so the two can never disagree.
  assert.equal(doc.getElementById('seq-status').textContent, 'unknown');
  assert.equal(doc.getElementById('seq-node').textContent, '--');
});

// ---------------------------------------------------------------------------
// D4-3 — "Current target" names the target
// ---------------------------------------------------------------------------

/** Drive renderOpsSequencerLoadPanel with a healthy clock and one status. */
function opsLoadPanel(sequencerStatus, opsExtra) {
  const doc = makeDocument([
    'seq-status', 'seq-node', 'seq-message', 'seq-progress-text',
    'seq-progress-bar', 'seq-progress-bar-container',
    'ops-seq-current-target', 'ops-seq-current-node', 'ops-seq-progress-text',
    'ops-seq-progress-bar', 'ops-seq-progress-bar-container', 'ops-seq-eta',
  ]);
  const now = Date.now();
  const state = {
    sequencerStatus,
    serverUnreachable: false,
    lastWsMessageAt: now - 200,
    panelLastUpdate: { sequencer: now - 200 },
    panelLastFailure: {},
    ops: Object.assign({ sessionSummary: null, sequenceStartedAt: now - 60000 },
      opsExtra || {}),
  };
  const render = build(
    ['document', 'api', 'state', 'lastReachabilityProbeAt', 'renderBadge',
      'sequencerProgressPercent', 'formatDurationSeconds'],
    [
      konst('REACHABILITY_PROBE_MS'),
      konst('SERVER_HEARTBEAT_MS'),
      konst('MISSED_HEARTBEATS_BEFORE_STALE'),
      konst('SERVER_CONTACT_STALE_MS'),
      fn('lastServerContactAt'),
      fn('isServerContactStale'),
      fn('isPanelDataStale'),
      fn('runDataIsStale'),
      fn('markProgressUnknown'),
      fn('markProgressKnown'),
      fn('paintRunUnknown'),
      fn('renderOpsSequencerLoadPanel'),
    ],
    'renderOpsSequencerLoadPanel',
  )(
    doc,
    { lastContactAt: now - 200, isConnected: true, rateLimitRemainingSecs: 0 },
    state,
    now - 1000,
    (el, label, cls) => { el.textContent = label; el.className = cls; },
    build(['x'], [fn('sequencerProgressPercent')], 'sequencerProgressPercent')(null),
    () => '3m',
  );
  render();
  return doc;
}

// Measured live against the release bundle: on a headless run whose
// TargetHeader names "D4 Web Target" inside a sequence called "D4 web live",
// the panel read "D4 web live" for every sample of the run — the imaging
// SESSION's name, which a headless start takes from the sequence. Once the run
// ended and /api/sessions/active answered {"session":null} the fallback named
// the Loop ROOT node and the field read "D4 root"; during an interval
// autofocus it read "Autofocus (HFR Degradation)".
test('Current target names the target, never the sequence or the node', () => {
  const doc = opsLoadPanel({
    state: 'running',
    currentNodeName: 'Exposure L',
    currentTarget: 'D4 Web Target',
    progress: 0.13,
    message: 'Exposure: Frame 5/40',
  }, { sessionSummary: { session: { id: 7, name: 'D4 web live' } } });
  assert.equal(doc.getElementById('ops-seq-current-target').textContent,
    'D4 Web Target');
  assert.equal(doc.getElementById('ops-seq-current-node').textContent,
    'Exposure L', 'the node keeps its own row');
});

test('a run that has named no target says so rather than guessing', () => {
  const doc = opsLoadPanel({
    state: 'running',
    currentNodeName: 'D4 root',
    currentTarget: null,
    progress: 0.13,
    message: null,
  }, { sessionSummary: { session: { id: 7, name: 'D4 web live' } } });
  assert.equal(doc.getElementById('ops-seq-current-target').textContent, '--',
    'an unknown target is "--", not the nearest string on the page');
});

// ---------------------------------------------------------------------------
// W11-E / D4-01 + D4-02 — a positive empty state requires an answer that SAYS
// empty
//
// Measured against the release bundle on a rig with four connected simulator
// devices and twelve registered frames: a content-free 200 on
// /api/devices/connected rendered "No devices connected" (0 rows, mount alt
// "--", no stale line, no toast, no log entry, header "Connected"), and the
// same body — plus a body of `null` — on /api/images rendered "No captured
// images yet." with the status line reading "No images captured yet.". The
// control arms prove the class: a 500 kept the last good tiles and named the
// failure.
// ---------------------------------------------------------------------------

class TestApiError extends Error {
  constructor(kind, message, detail) {
    super(message);
    this.kind = kind;
    this.detail = detail || {};
  }
}

function wireList() {
  return build(
    ['SkotiqApiError'], [fn('requireWireList')], 'requireWireList',
  )(TestApiError);
}

test('a list the answer names is delivered, empty or not', () => {
  const require_ = wireList();
  assert.deepEqual(require_({ devices: [] }, 'devices', 'Connected devices'), []);
  assert.deepEqual(
    require_({ devices: [{ id: 'sim_camera_1' }] }, 'devices', 'Connected devices'),
    [{ id: 'sim_camera_1' }]);
});

test('an answer that names no list is a failed exchange, not an empty one', () => {
  const require_ = wireList();
  for (const payload of [{}, { devices: null }, { devices: 'none' }, 'ok', 42]) {
    assert.throws(
      () => require_(payload, 'devices', 'Connected devices'),
      (e) => e.kind === 'unusable_answer' && /no "devices" list/.test(e.message),
      JSON.stringify(payload) + ' says nothing about the inventory',
    );
  }
});

/** fetchDevices with its collaborators recorded rather than performed. */
function devicesFetch(answer) {
  const doc = makeDocument(['devices-list']);
  const log = [];
  const marks = [];
  const state = {
    connectedDevices: [{ id: 'sim_camera_1', deviceType: 'camera' }],
    filterWheelDeviceId: null, cameraDeviceId: null, mountDeviceId: null,
    focuserDeviceId: null, rotatorDeviceId: null,
    filterWheelPositions: null, filterWheelPositionsDeviceId: null,
    ops: {},
  };
  let rendered = 0;
  const debug = [];
  const reporter = refreshFailureReporter({ marks, log, debug });
  const run = build(
    ['api', 'state', 'requireWireList', 'SkotiqApiError',
      'reportRefreshFailure', 'renderDevicesPanel', 'markPanelFresh',
      'refreshPanelEnablement',
      'maybeLoadCameraReadoutModes', 'maybeLoadFilterWheelPositions'],
    [fn('fetchDevices')],
    'fetchDevices',
  )(
    { getConnectedDevices: async () => {
      if (answer instanceof Error) throw answer;
      return answer;
    } },
    state,
    wireList(),
    TestApiError,
    reporter.report,
    () => { rendered += 1; },
    (k) => marks.push('fresh:' + k),
    () => {}, () => {}, () => {},
  );
  return { run, state, log, marks, debug, rendered: () => rendered };
}

test('a content-free devices answer never asserts an empty rig', async () => {
  const h = devicesFetch(new TestApiError(
    'unusable_answer',
    'GET /api/devices/connected answered 200 with an empty body',
    { status: 200 },
  ));
  await h.run();
  assert.deepEqual(h.state.connectedDevices, [{ id: 'sim_camera_1', deviceType: 'camera' }],
    'the last confirmed inventory stands until something replaces it');
  assert.deepEqual(h.marks, ['unconfirmed:devices'],
    'the panel must be marked unconfirmed so its stale line appears');
  assert.equal(h.rendered(), 0,
    '"No devices connected" may not be painted from a failed read');
  assert.match(h.log.join('\n'), /Devices fetch failed/);
});

test('an answer with no devices list is refused like an empty body', async () => {
  const h = devicesFetch({ discoveryErrors: {} });
  await h.run();
  assert.deepEqual(h.marks, ['unconfirmed:devices']);
  assert.match(h.log.join('\n'), /no "devices" list/);
});

test('a devices answer that lists zero devices IS rendered as empty', async () => {
  const h = devicesFetch({ devices: [] });
  await h.run();
  assert.deepEqual(h.state.connectedDevices, []);
  assert.deepEqual(h.marks, ['fresh:devices']);
  assert.equal(h.rendered(), 1,
    'a server that lists zero devices has said the rig is empty');
});

/** refreshGalleryFromServer with a scripted /api/images answer. */
function galleryFetch(answer) {
  const doc = makeDocument(['gallery-grid', 'gallery-status', 'gallery-fresh-badge']);
  const gallery = { loading: false, items: [{ id: 1 }, { id: 2 }], freshSinceLastView: 3 };
  const log = [];
  let rendered = 0;
  const run = build(
    ['document', 'api', 'gallery', 'requireWireList', 'SkotiqApiError',
      'renderGallery', 'addLogEntry', 'describeApiError', 'galleryCountLine'],
    [fn('refreshGalleryFromServer')],
    'refreshGalleryFromServer',
  )(
    doc,
    { imagesGetAll: async () => {
      if (answer instanceof Error) throw answer;
      return answer;
    } },
    gallery,
    wireList(),
    TestApiError,
    () => { rendered += 1; },
    (kind, text) => log.push(kind + ': ' + text),
    build(['x'], [fn('describeApiError')], 'describeApiError')(null),
    countLine(),
  );
  return { run, doc, gallery, log, rendered: () => rendered };
}

test('a content-free images answer never claims the night captured nothing', async () => {
  const h = galleryFetch(new TestApiError(
    'unusable_answer', 'GET /api/images answered 200 and the body is null',
    { status: 200 },
  ));
  await h.run();
  const status = h.doc.getElementById('gallery-status').textContent;
  assert.doesNotMatch(status, /No images captured yet/,
    'that sentence is reserved for an answer that listed zero frames');
  assert.match(status, /Gallery fetch failed/);
  assert.deepEqual(h.gallery.items, [{ id: 1 }, { id: 2 }],
    'the tiles from the last good read stay, and the line above says they may be stale');
  assert.equal(h.rendered(), 0);
});

test('an images answer naming no list is refused', async () => {
  const h = galleryFetch({ total: 12 });
  await h.run();
  assert.match(h.doc.getElementById('gallery-status').textContent, /no "images" list/);
});

test('an images answer that lists zero frames IS the empty state', async () => {
  const h = galleryFetch({ images: [] });
  await h.run();
  assert.equal(h.doc.getElementById('gallery-status').textContent,
    'No images captured yet.');
  assert.deepEqual(h.gallery.items, []);
  assert.equal(h.rendered(), 1);
});

test('the older `items` spelling is still read when it is the one present', async () => {
  const h = galleryFetch({ items: [{ id: 7 }] });
  await h.run();
  assert.deepEqual(h.gallery.items, [{ id: 7 }]);
  assert.match(h.doc.getElementById('gallery-status').textContent, /1 image shown/);
});

// ---------------------------------------------------------------------------
// W11-E / D4-03 — a rejected bearer must not strand the operator
//
// Measured against the release bundle: typing a wrong token and pressing Sign
// in hid the overlay at t+3s, and at t+40s `#login-status` still read
// "Signing in...", the header read "Disconnected", the only notice had been a
// toast that expired at ~3s carrying the raw refusal body, and both fallback
// controls (#btn-apply-token, #btn-pair) measured zero-size inside a collapsed
// <details>.
// ---------------------------------------------------------------------------

test('a refused credential is described by what to do, not by its JSON', () => {
  const describe = build(
    ['x'],
    [fn('describeScopeRefusal'), fn('describeConnectFailure')],
    'describeConnectFailure',
  )(null);
  const rejected = describe({
    kind: 'http_error', status: 403,
    message: 'GET /api/status failed (403): {"error":"Access denied",' +
      '"message":"Invalid authentication token"}',
  });
  assert.equal(rejected.kind, 'rejected');
  assert.match(rejected.message, /rejected this token/);
  assert.match(rejected.message, /Remote Access/);
  assert.doesNotMatch(rejected.message, /Access denied|\{/,
    'the server\'s refusal body is a diagnostic, not an instruction');

  assert.equal(describe({ kind: 'unreachable' }).kind, 'unreachable');
  assert.match(describe({ kind: 'unreachable' }).message, /No answer/);
  assert.equal(describe({ kind: 'rate_limited', retryAfterSecs: 4 }).kind, 'rate_limited');
});

/** handleLoginSubmit driven against a scripted handleConnect outcome. */
function loginSubmit(outcome) {
  const doc = makeDocument([
    'login-server-url', 'login-token', 'login-remember', 'login-status',
    'server-url', 'auth-token', 'remember-token', 'login-overlay',
  ]);
  doc.getElementById('login-server-url').value = 'http://127.0.0.1:8214';
  doc.getElementById('login-token').value = 'WRONG-TOKEN-abc123';
  doc.getElementById('login-remember').checked = true;
  doc.getElementById('remember-token').checked = true;
  doc.getElementById('login-overlay').classList.add('hidden');
  doc.getElementById('login-overlay').setAttribute('hidden', '');
  const stored = [];
  const run = build(
    ['document', 'normalizeServerUrl', 'isSameOriginServerUrl',
      'crossOriginServerMessage', 'writeStoredToken', 'handleConnect',
      'applyHashRoute', 'hideLoginOverlay', 'reportLoginFailure'],
    [fn('handleLoginSubmit')],
    'handleLoginSubmit',
  )(
    doc,
    (u) => u,
    () => true,
    () => 'cross-origin',
    (token, remember) => stored.push({ token, remember }),
    async () => outcome,
    () => {},
    () => {
      doc.getElementById('login-overlay').classList.add('hidden');
      doc.getElementById('login-overlay').setAttribute('hidden', '');
    },
    build(
      ['document', 'writeStoredToken', 'showLoginOverlay'],
      [fn('reportLoginFailure')],
      'reportLoginFailure',
    )(
      doc,
      (token, remember) => stored.push({ token, remember }),
      () => {
        doc.getElementById('login-overlay').classList.remove('hidden');
        doc.getElementById('login-overlay').removeAttribute('hidden');
      },
    ),
  );
  return { run, doc, stored };
}

test('a rejected bearer brings the sign-in form back and says why', async () => {
  const h = loginSubmit({
    ok: false, kind: 'rejected',
    message: 'The desktop rejected this token. Check it against the ' +
      'desktop’s Remote Access screen, or pair this browser instead.',
  });
  await h.run();

  const overlay = h.doc.getElementById('login-overlay');
  assert.ok(!overlay.classList.contains('hidden'),
    'the only surface that can fix a credential must be on screen');
  assert.equal(overlay.hasAttribute('hidden'), false);
  const status = h.doc.getElementById('login-status');
  assert.match(status.textContent, /rejected this token/);
  assert.doesNotMatch(status.textContent, /Signing in/,
    '"Signing in..." over a finished attempt is a state that ended');
  assert.ok(status.className.includes('error'));
  assert.deepEqual(h.stored[h.stored.length - 1], { token: '', remember: true },
    'a credential the desktop refused must not survive a reload');
});

test('a server that never answered says so, and keeps the token typed', async () => {
  const h = loginSubmit({
    ok: false, kind: 'unreachable',
    message: 'No answer from the Skotiq server. Check that it is running ' +
      'and that this address is right.',
  });
  await h.run();
  assert.ok(!h.doc.getElementById('login-overlay').classList.contains('hidden'));
  assert.match(h.doc.getElementById('login-status').textContent, /No answer/);
  assert.deepEqual(h.stored, [{ token: 'WRONG-TOKEN-abc123', remember: true }],
    'an unreachable server is no evidence against the token');
});

test('a connection that succeeds is the only thing that dismisses the overlay', async () => {
  const h = loginSubmit({ ok: true });
  await h.run();
  assert.ok(h.doc.getElementById('login-overlay').classList.contains('hidden'));
  assert.equal(h.doc.getElementById('login-status').textContent, 'Signing in...');
});

test('an automatic connect only raises the form for a credential problem', () => {
  const isCredential = build(
    ['x'], [fn('isCredentialFailure')], 'isCredentialFailure')(null);
  assert.equal(isCredential({ ok: false, kind: 'rejected' }), true);
  assert.equal(isCredential({ ok: false, kind: 'needs_credential' }), true);
  for (const kind of ['unreachable', 'rate_limited', 'unusable_answer',
    'cross_origin', 'failed']) {
    assert.equal(isCredential({ ok: false, kind }), false,
      'a ' + kind + ' failure is not the token\'s fault, and asking for a ' +
      'token would send the operator hunting for the wrong thing');
  }
  assert.equal(isCredential(undefined), false);
});

// ---------------------------------------------------------------------------
// D4W-2 — Weather & Safety is not exempt from the staleness clock
//
// Measured against the release bundle on :8213 with a hardware-connected safe
// reading on the wire: 74 s after kill -TERM, with the header already reading
// "No contact" and five sibling panels carrying "Stale: 1m 14s since last
// update", the Weather & Safety panel still read "SAFE / Safe to image yes /
// Alert level clear / Conditions are within limits / Temperature 8.5 °C /
// Humidity 41 % / Cloud cover 3 %" with no freshness marker of any kind. It
// was simply not on the clock: PANEL_KEYS never named it and the markup had
// no line for it to write into. The Dome panel had the same shape.
// ---------------------------------------------------------------------------

test('the Weather & Safety and Dome panels age like their siblings', () => {
  const now = Date.now();
  const h = linkState({
    unreachable: true,
    lastContactAt: now - 74000,
    lastWsMessageAt: now - 74000,
    lastProbeAt: now - 1000,
    panelLastUpdate: { weather: now - 74000, dome: now - 74000 },
  });
  assert.equal(h.doc.getElementById('status-text').textContent, 'No contact');
  for (const key of ['weather', 'dome']) {
    assert.match(h.doc.getElementById('stale-' + key).textContent,
      /Stale: 1m 14s since last update/,
      key + ' must say its data is as old as the header says it is');
  }
  // And the line has somewhere to land in the shipped markup.
  for (const id of ['stale-weather', 'stale-dome']) {
    assert.match(HTML, new RegExp('id="' + id + '"'),
      id + ' must exist in index.html or the wiring writes into nothing');
  }
});

test('a rig nobody can reach is not reported safe to image', () => {
  const now = Date.now();
  const h = linkState({
    unreachable: false,
    lastContactAt: now - 200,
    lastWsMessageAt: now - 200,
    panelLastUpdate: { weather: now - 1000 },
  });
  // A hardware-connected safe reading is on screen when the route starts
  // refusing — the dangerous case, not the sensorless one.
  const safe = h.doc.getElementById('ops-weather-safe');
  safe.textContent = 'yes';
  safe.className = 'status-value good';
  h.doc.getElementById('ops-weather-alert-level').textContent = 'clear';
  h.doc.getElementById('ops-weather-message').textContent =
    'Conditions are within limits';
  h.doc.getElementById('ops-weather-temp').textContent = '8.5 °C';
  h.doc.getElementById('ops-weather-humidity').textContent = '41 %';
  h.doc.getElementById('ops-weather-clouds').textContent = '3 %';
  h.doc.getElementById('ops-safety-monitor-count').textContent = '1';
  h.doc.getElementById('ops-safety-monitor-list').children = [{}];
  const badge = h.doc.getElementById('ops-safety-badge');
  badge.textContent = 'safe';
  badge.className = 'badge badge-running';

  h.state.panelLastFailure.weather = Date.now();
  h.render();

  assert.equal(safe.textContent, '--',
    'a verdict whose source refused is not "yes"');
  assert.ok(!safe.className.includes('good'));
  assert.equal(badge.textContent, 'unknown');
  assert.ok(!badge.className.includes('badge-running'),
    'an unreachable sky must not read green');
  for (const id of ['ops-weather-alert-level', 'ops-weather-message',
    'ops-weather-temp', 'ops-weather-humidity', 'ops-weather-clouds',
    'ops-safety-monitor-count']) {
    assert.equal(h.doc.getElementById(id).textContent, '--',
      id + ' outlived the answer it came from');
  }
  assert.deepEqual(h.doc.getElementById('ops-safety-monitor-list').children, [],
    'a per-monitor "safe" row is the same verdict in another shape');
  assert.match(h.doc.getElementById('stale-weather').textContent,
    /since last update/);
});

test('a dome whose source stopped answering stops naming its shutter', () => {
  const now = Date.now();
  const h = linkState({
    unreachable: false,
    lastContactAt: now - 200,
    lastWsMessageAt: now - 200,
    panelLastUpdate: { dome: now - 1000 },
  });
  h.doc.getElementById('ops-dome-shutter').textContent = 'open';
  h.doc.getElementById('ops-dome-az').textContent = '182.4 °';
  h.doc.getElementById('ops-dome-slewing').textContent = 'no';
  h.doc.getElementById('ops-dome-sync').textContent = 'enabled';
  const badge = h.doc.getElementById('ops-dome-state-badge');
  badge.textContent = 'open';
  badge.className = 'badge badge-running';

  h.state.panelLastFailure.dome = Date.now();
  h.render();

  for (const id of ['ops-dome-shutter', 'ops-dome-az', 'ops-dome-slewing',
    'ops-dome-sync']) {
    assert.equal(h.doc.getElementById(id).textContent, '--');
  }
  assert.equal(badge.textContent, 'unknown');
  assert.ok(!badge.className.includes('badge-running'));
});

test('a route that answers again hands both ops panels back', () => {
  const now = Date.now();
  const h = linkState({
    unreachable: false,
    lastContactAt: now - 200,
    lastWsMessageAt: now - 200,
    panelLastUpdate: { weather: now - 1000, dome: now - 1000 },
  });
  assert.deepEqual(h.opsRepaints, [], 'nothing to restore on a healthy link');
  h.state.panelLastFailure.weather = Date.now();
  h.state.panelLastFailure.dome = Date.now();
  h.render();
  assert.equal(h.doc.getElementById('ops-safety-badge').textContent, 'unknown');
  assert.deepEqual(h.opsRepaints, [], 'nothing to restore while still stale');

  h.state.panelLastUpdate.weather = Date.now();
  h.state.panelLastUpdate.dome = Date.now();
  h.render();
  assert.deepEqual(h.opsRepaints, ['weather', 'dome'],
    'the panels repaint from the data, not from the overlay');
  h.render();
  assert.deepEqual(h.opsRepaints, ['weather', 'dome'],
    'the recovery edge fires once, not on every healthy tick');
});

/** Drive the real weather/safety fetch with a stubbed API. */
function weatherFetch({ rejects }) {
  const state = { ops: {} };
  const marks = [];
  const logs = [];
  const renders = [];
  const api = {
    weatherGetCurrent: () => rejects
      ? Promise.reject(Object.assign(new Error('refused'), { kind: 'unreachable' }))
      : Promise.resolve({ dataSource: 'hardware', safeToImage: true }),
    safetyGetStatus: () => rejects
      ? Promise.reject(Object.assign(new Error('refused'), { kind: 'unreachable' }))
      : Promise.resolve({ isSafe: true, monitorsConnected: 1 }),
  };
  const debug = [];
  const reporter = refreshFailureReporter({ marks, log: logs, debug });
  const run = build(
    ['api', 'state', 'markPanelFresh', 'reportRefreshFailure',
      'renderOpsWeatherPanel'],
    [fn('fetchOpsWeatherAndSafety')],
    'fetchOpsWeatherAndSafety',
  )(
    api, state,
    (key) => marks.push('fresh:' + key),
    reporter.report,
    () => renders.push(1),
  );
  return { run, marks, logs, renders, debug, state };
}

test('a refused weather answer reaches the clock, not only the log', () => {
  const h = weatherFetch({ rejects: true });
  return h.run().then(() => {
    assert.deepEqual(h.marks, ['unconfirmed:weather'],
      'the refusal used to reach nothing but a log line');
    assert.match(h.logs.join('\n'), /Weather\/safety fetch failed/);
    assert.equal(h.renders.length, 1,
      'the panel must repaint so the verdict comes off the screen');
  });
});

test('an answered weather fetch marks the panel fresh', () => {
  const h = weatherFetch({ rejects: false });
  return h.run().then(() => {
    assert.deepEqual(h.marks, ['fresh:weather']);
    assert.deepEqual(h.logs, []);
  });
});

// ---------------------------------------------------------------------------
// D4W-3 — a sequencer status that names no state
//
// Measured against the release bundle with {"state":null,...,"progress":null}
// on /api/sequencer/status: the Run panel read Status IDLE / Progress 0% /
// aria-valuenow="0" with no stale line, so a screen reader announced "0
// percent" for a figure the server had explicitly refused to supply. The same
// wire fed to /run-watch renders "Status unavailable / UNKNOWN / PROGRESS --".
// ---------------------------------------------------------------------------

function sequencerPanel(sequencerStatus, { stale = false } = {}) {
  const doc = makeDocument([
    'seq-status', 'seq-node', 'seq-message', 'seq-progress-bar',
    'seq-progress-bar-container', 'seq-progress-text',
    'ops-seq-progress-bar', 'ops-seq-progress-bar-container',
    'ops-seq-progress-text', 'ops-seq-eta', 'ops-seq-current-node',
    'ops-seq-current-target',
  ]);
  const buttons = [];
  const render = build(
    ['document', 'state', 'renderBadge', 'updateSequencerButtons',
      'renderOpsSequencerLoadPanel', 'runDataIsStale'],
    [fn('sequencerStateOf'), fn('getSequencerBadgeClass'),
      fn('sequencerProgressPercent'), fn('markProgressUnknown'),
      fn('markProgressKnown'), fn('paintRunUnknown'),
      fn('renderSequencerPanel')],
    'renderSequencerPanel',
  )(
    doc,
    { sequencerStatus },
    (el, label, cls) => { el.textContent = label; el.className = cls; },
    (s) => { buttons.push(s); },
    () => {},
    () => stale,
  );
  render();
  return { doc, buttons };
}

test('a status that names no state renders unknown, never idle', () => {
  const { doc, buttons } = sequencerPanel({
    state: null, currentNodeId: null, currentNodeName: null,
    currentTarget: null, progress: null, message: null,
  });
  const badge = doc.getElementById('seq-status');
  assert.equal(badge.textContent, 'unknown',
    'a null state is not a parked telescope');
  assert.ok(badge.className.includes('badge-error'));
  assert.equal(doc.getElementById('seq-progress-text').textContent, '--',
    '0% is a figure the server refused to supply');
  assert.equal(
    doc.getElementById('seq-progress-bar-container')
      .getAttribute('aria-valuenow'), null,
    'aria-valuenow="0" announces "0 percent" for nothing anyone sent');
  assert.ok(doc.getElementById('seq-progress-bar-container').classList
    .contains('unknown'));
  assert.equal(doc.getElementById('seq-node').textContent, '--');
  assert.equal(doc.getElementById('seq-message').textContent, '');
  assert.equal(doc.getElementById('ops-seq-current-target').textContent, '--');
  assert.deepEqual(buttons, [null]);
});

test('a status that names a state still renders it', () => {
  const { doc, buttons } = sequencerPanel({
    state: 'running', currentNodeName: 'SENTINEL NODE', progress: 0.42,
    message: 'SENTINEL MESSAGE',
  });
  assert.equal(doc.getElementById('seq-status').textContent, 'running');
  assert.equal(doc.getElementById('seq-node').textContent, 'SENTINEL NODE');
  assert.equal(doc.getElementById('seq-progress-text').textContent, '42%');
  assert.equal(
    doc.getElementById('seq-progress-bar-container')
      .getAttribute('aria-valuenow'), '42');
  assert.equal(doc.getElementById('seq-message').textContent,
    'SENTINEL MESSAGE');
  assert.deepEqual(buttons, ['running']);
});

test('only a named state counts as a state', () => {
  const named = build(['x'], [fn('sequencerStateOf')], 'sequencerStateOf')(null);
  for (const carried of [null, undefined, '', '   ', 42, { weird: true }, []]) {
    assert.equal(named({ state: carried }), null,
      JSON.stringify(carried) + ' names no run state');
  }
  assert.equal(named(null), null);
  assert.equal(named({ state: 'running' }), 'running');
  assert.equal(named({ state: '  paused  ' }), 'paused');
});

/** Drive the real sequencer fetch with a stubbed API. */
function sequencerFetch(answer) {
  const state = {};
  const marks = [];
  const run = build(
    ['api', 'state', 'sequencerStateOf', 'markPanelFresh',
      'markPanelUnconfirmed', 'renderSequencerPanel', 'addLogEntry',
      'describeApiError'],
    [fn('fetchSequencerStatus')],
    'fetchSequencerStatus',
  )(
    { sequencerGetStatus: () => Promise.resolve(answer) },
    state,
    build(['x'], [fn('sequencerStateOf')], 'sequencerStateOf')(null),
    (key) => marks.push('fresh:' + key),
    (key) => marks.push('unconfirmed:' + key),
    () => {},
    () => {},
    () => '',
  );
  return { run, marks };
}

test('a 200 that names no state is not a refreshed panel', () => {
  const h = sequencerFetch({ state: null, progress: null });
  return h.run().then(() => {
    assert.deepEqual(h.marks, ['unconfirmed:sequencer'],
      'the panel must carry a stale line, as it does for a malformed reply');
  });
});

test('a 200 that names a state is a refreshed panel', () => {
  const h = sequencerFetch({ state: 'running', progress: 0.42 });
  return h.run().then(() => {
    assert.deepEqual(h.marks, ['fresh:sequencer']);
  });
});

// ---------------------------------------------------------------------------
// D4W-5 — a socket that never opened
//
// Measured against the release bundle through a page whose WebSocket never
// completes its upgrade (a WS-hostile proxy or captive portal): the Event Log
// printed the literal line "WebSocket silent for Infinitys — falling back to
// REST polling". `Infinity` was the sentinel for "never connected" and it was
// interpolated straight into operator-visible copy.
// ---------------------------------------------------------------------------

function staleness({ lastWsMessageAt, lastContactAt = Date.now() - 200 }) {
  const logs = [];
  const state = {
    lastWsMessageAt,
    wsFallbackPollInterval: null,
    panelLastUpdate: {}, panelLastFailure: {},
  };
  const run = build(
    ['api', 'state', 'lastServerContactAt', 'lastReachabilityProbeAt',
      'probeServerReachable', 'repaintDataState', 'isServerContactStale',
      'isPanelDataStale', 'lastPanelRefreshRetryAt', 'fetchAllStatus',
      'fetchOpsSequences', 'addLogEntry', 'setInterval', 'clearInterval'],
    [
      konst('SERVER_HEARTBEAT_MS'),
      konst('REACHABILITY_PROBE_MS'),
      konst('HEARTBEAT_GRACE_MS'),
      konst('PANEL_REFRESH_RETRY_MS'),
      konst('WS_FALLBACK_THRESHOLD_MS'),
      konst('PANEL_KEYS'),
      fn('checkStaleness'),
    ],
    'checkStaleness',
  )(
    { isConnected: true, isWsConnected: false },
    state,
    () => lastContactAt,
    Date.now(),
    () => {},
    () => {},
    () => false,
    () => false,
    Date.now(),
    () => {},
    () => {},
    (cat, msg) => logs.push(msg),
    () => 'timer-handle',
    () => {},
  );
  run();
  return { logs, state };
}

test('a socket that never opened says so in words', () => {
  const { logs, state } = staleness({ lastWsMessageAt: 0 });
  assert.deepEqual(logs,
    ['WebSocket never connected — falling back to REST polling']);
  assert.equal(state.wsFallbackPollInterval, 'timer-handle',
    'the fallback must still arm — the socket is no less absent');
  for (const line of logs) {
    assert.doesNotMatch(line, /Infinity|NaN|undefined|null/,
      'no sentinel may reach operator-visible copy');
  }
});

test('a socket that opened and went quiet reports how long', () => {
  const now = Date.now();
  const { logs } = staleness({ lastWsMessageAt: now - 60000 });
  assert.equal(logs.length, 1);
  assert.match(logs[0],
    /^WebSocket silent for (59|60|61)s — falling back to REST polling$/);
});

test('a live socket arms no fallback and logs nothing', () => {
  const { logs, state } = staleness({ lastWsMessageAt: Date.now() - 2000 });
  assert.deepEqual(logs, []);
  assert.equal(state.wsFallbackPollInterval, null);
});

// ---------------------------------------------------------------------------
// W13-C / D4-W1 — the dashboard must not 429-storm itself during a live run
//
// Measured against the release bundle on a D1 sim night (port 8212): with the
// Event Log cleared and no other operator traffic, one 75 s run put 746 lines
// in the panel of which 274 carried the red `error` category, and every single
// one of those 274 was this page's own request coming back rate-limited
// ("Sequencer fetch skipped: server is rate-limiting this session (retry in
// 1s)" and its Checkpoint / Analytics / Camera siblings). Server-side over the
// same shape, /api/logs/tail?minSeverity=debug recorded 147 real 429s in 45 s
// across /api/sessions/active, /api/sequencer/checkpoint/has,
// /api/sequencer/status, /api/sequencer/checkpoint/info and
// /api/equipment/camera/status. The rig was healthy throughout.
// ---------------------------------------------------------------------------

/** The coalescing scheduler over a fake clock, so a burst can be replayed. */
function refreshScheduler() {
  let now = 1000;
  let nextId = 0;
  const pending = [];
  const refreshes = [];
  const gets = [];
  const fakeSetTimeout = (fn, ms) => {
    const id = ++nextId;
    pending.push({ id, at: now + (ms || 0), fn });
    return id;
  };
  const fakeClearTimeout = (id) => {
    const i = pending.findIndex((t) => t.id === id);
    if (i >= 0) pending.splice(i, 1);
  };
  const scheduler = build(
    ['Date', 'setTimeout', 'clearTimeout', 'fetchSequencerStatus',
      'fetchOpsCheckpoints', 'fetchOpsAnalyticsSummary'],
    [
      konst('SEQUENCER_REFRESH_MIN_INTERVAL_MS'),
      letDecl('sequencerRefreshTimer'),
      letDecl('sequencerRefreshLastAt'),
      fn('scheduleSequencerRefresh'),
      fn('runSequencerRefresh'),
      fn('cancelSequencerRefresh'),
    ],
    '({ schedule: scheduleSequencerRefresh, cancel: cancelSequencerRefresh, '
      + 'interval: SEQUENCER_REFRESH_MIN_INTERVAL_MS })',
  )(
    { now: () => now },
    fakeSetTimeout,
    fakeClearTimeout,
    () => { refreshes.push(now); gets.push('GET /api/sequencer/status'); },
    () => gets.push('GET /api/sequencer/checkpoint/has'),
    () => gets.push('GET /api/analytics/session-summary'),
  );

  function advance(ms) {
    const end = now + ms;
    for (;;) {
      let due = null;
      for (const t of pending) {
        if (t.at <= end && (due === null || t.at < due.at)) due = t;
      }
      if (!due) break;
      pending.splice(pending.indexOf(due), 1);
      now = due.at;
      due.fn();
    }
    now = end;
  }

  return { scheduler, advance, refreshes, gets, at: () => now };
}

test('an event burst collapses into one refresh', () => {
  const h = refreshScheduler();
  // Twenty Progress events inside one tick, the shape the executor emits.
  for (let i = 0; i < 20; i++) h.scheduler.schedule();
  h.advance(1);
  assert.equal(h.refreshes.length, 1,
    'twenty events in one tick are one thing happening, not twenty');
  assert.deepEqual(h.gets, [
    'GET /api/sequencer/status',
    'GET /api/sequencer/checkpoint/has',
    'GET /api/analytics/session-summary',
  ], 'the trio still goes out — coalesced, not dropped');
});

test('the trailing refresh runs, so a burst ends on its LAST event', () => {
  const h = refreshScheduler();
  h.scheduler.schedule();
  h.advance(1);
  assert.equal(h.refreshes.length, 1, 'the first event of a quiet period is prompt');
  // Something moves again immediately: too soon to send, never dropped.
  h.scheduler.schedule();
  h.advance(1);
  assert.equal(h.refreshes.length, 1, 'still inside the minimum interval');
  h.advance(h.scheduler.interval);
  assert.equal(h.refreshes.length, 2,
    'the deferred refresh fires once the interval has passed');
});

test('a 75s run at 10 events a second never outruns the server budget', () => {
  const h = refreshScheduler();
  // The measured shape: Progress/InstructionProgress several times a second
  // for the length of the run.
  for (let tick = 0; tick < 750; tick++) {
    h.scheduler.schedule();
    h.advance(100);
  }
  assert.equal(h.gets.length, h.refreshes.length * 3);
  // 7500 events used to mean 22 500 GETs. The budget the server sizes for a
  // dashboard is 60 reads a second (route_metadata/rate_limiting.dart), and
  // three panels' worth of state is one refresh.
  assert.ok(h.refreshes.length <= 76,
    'at most one refresh per second over 75s, got ' + h.refreshes.length);
  assert.ok(h.refreshes.length >= 74,
    'the panels must still keep up with the run, got ' + h.refreshes.length);
  for (let i = 1; i < h.refreshes.length; i++) {
    assert.ok(h.refreshes[i] - h.refreshes[i - 1] >= h.scheduler.interval,
      'two refreshes ' + (h.refreshes[i] - h.refreshes[i - 1]) + 'ms apart');
  }
});

test('a scheduled refresh is dropped when polling stops', () => {
  const h = refreshScheduler();
  h.scheduler.schedule();
  h.scheduler.cancel();
  h.advance(5000);
  assert.deepEqual(h.refreshes, [], 'a torn-down page asks for nothing');
});

test('a sequencer event schedules the refresh, never a per-event fan-out', () => {
  const body = fn('handleServerEvent');
  const branch = /category === 'sequencer'\) \{([\s\S]*?)\} else if/.exec(body);
  assert.ok(branch, "handleServerEvent must have a 'sequencer' branch");
  assert.match(branch[1], /scheduleSequencerRefresh\(\)/);
  for (const direct of ['fetchSequencerStatus', 'fetchOpsCheckpoints',
    'fetchOpsAnalyticsSummary']) {
    assert.doesNotMatch(branch[1], new RegExp(direct + '\\('),
      direct + ' must go through the coalescer, not fire once per event');
  }
});

test('a rate-limited refresh is a cadence fact, not an operator error', () => {
  const h = refreshFailureReporter();
  h.report('sequencer', { kind: 'rate_limited', retryAfterSecs: 1 },
    'Sequencer fetch');
  assert.deepEqual(h.log, [],
    'a self-skipped fetch is not one of the night\'s errors');
  assert.deepEqual(h.marks, [],
    'the panel is exactly as fresh as its last successful read');
  assert.equal(h.debug.length, 1, 'the fact is still recorded, for developers');
  assert.match(h.debug[0], /rate-limiting this session/);
});

test('a refusal that IS the data source still reaches the log and the clock', () => {
  for (const kind of ['unreachable', 'timeout', 'http_error', 'unusable_answer']) {
    const h = refreshFailureReporter();
    h.report('camera', { kind, message: 'SENTINEL' }, 'Camera status fetch');
    assert.deepEqual(h.marks, ['unconfirmed:camera'], kind + ' is panel staleness');
    assert.equal(h.log.length, 1, kind + ' is an operator-facing error');
    assert.match(h.log[0], /^error: Camera status fetch/);
    assert.deepEqual(h.debug, []);
  }
});

test('a panel-less background refresh still logs a real failure', () => {
  const h = refreshFailureReporter();
  h.report(null, { kind: 'unreachable', message: 'gone' }, 'Checkpoint fetch');
  assert.deepEqual(h.marks, []);
  assert.match(h.log.join('\n'), /Checkpoint fetch failed/);
});

// ---------------------------------------------------------------------------
// W13-C / D4-W2 — a rig that has never run reports no percentage
//
// Measured against the release bundle on an EMPTY database dir:
// GET /api/sequencer/status answered
// {"state":"idle","currentNodeId":null,"currentNodeName":null,
//  "currentTarget":null,"progress":0.0,"message":null} — every field null
// except the one figure, which was zero — and the two panels read
// "Status IDLE / Current Node -- / Progress 0%" and "Current target -- /
// Current node -- / Progress 0% / ETA --", both with aria-valuenow="0". The
// same process answered /api/run-watch/snapshot with progressPercent null and
// the phone surface rendered "PROGRESS --".
// ---------------------------------------------------------------------------

test('a rig that has never run shows no progress figure', () => {
  const { doc, buttons } = sequencerPanel({
    state: 'idle', currentNodeId: null, currentNodeName: null,
    currentTarget: null, progress: null, message: null,
  });
  assert.equal(doc.getElementById('seq-status').textContent, 'idle',
    'the STATE is known — no run is going — and only the figure is withheld');
  assert.deepEqual(buttons, ['idle']);
  assert.equal(doc.getElementById('seq-progress-text').textContent, '--',
    '0% is a measurement of a run that never happened');
  assert.equal(
    doc.getElementById('seq-progress-bar-container')
      .getAttribute('aria-valuenow'), null,
    'aria-valuenow="0" announces "0 percent" for a figure nobody sent');
  assert.ok(doc.getElementById('seq-progress-bar-container').classList
    .contains('unknown'));
});

test('the ops mirror renders the same absence, and no ETA from it', () => {
  const doc = opsLoadPanel({
    state: 'idle', currentNodeId: null, currentNodeName: null,
    currentTarget: null, progress: null, message: null,
  });
  assert.equal(doc.getElementById('ops-seq-progress-text').textContent, '--');
  assert.equal(doc.getElementById('ops-seq-eta').textContent, '--');
  assert.equal(
    doc.getElementById('ops-seq-progress-bar-container')
      .getAttribute('aria-valuenow'), null);
  assert.ok(doc.getElementById('ops-seq-progress-bar-container').classList
    .contains('unknown'));
});

test('a rig that HAS run keeps its real figure, zero included', () => {
  const { doc } = sequencerPanel({
    state: 'running', currentNodeName: 'Exposure L', progress: 0,
    message: 'Frame 1/12',
  });
  assert.equal(doc.getElementById('seq-progress-text').textContent, '0%',
    'a started run at zero percent HAS a measurement, and it is zero');
  assert.equal(
    doc.getElementById('seq-progress-bar-container')
      .getAttribute('aria-valuenow'), '0');
  assert.ok(!doc.getElementById('seq-progress-bar-container').classList
    .contains('unknown'));
});

// ---------------------------------------------------------------------------
// W13-C / D4-W3 — the gallery states the grader's verdict
//
// Measured against the release bundle after a D1 harness night whose star
// floor was raised past anything the simulator produces: 26 of the 38 rows
// GET /api/images returned carried "isAccepted": false plus a reason string,
// and every tile rendered as
// <button class="gallery-card" aria-label="B · 8/18/2026, 8:58:10 AM">
//   <img …><div class="gallery-caption">B · 8/18/2026, 8:58:10 AM</div>
// </button>
// — indistinguishable from a keeper. The count line read "38 images shown."
// and the preview modal read "Image preview / B · … / Download original /
// Close".
// ---------------------------------------------------------------------------

/** renderGallery over a scripted listing. */
function galleryGrid(items) {
  const doc = makeDocument(['gallery-grid']);
  const render = build(
    ['document', 'gallery', 'revokeGalleryThumbnailUrls',
      'loadGalleryThumbnail', 'markGalleryThumbUnavailable',
      'openGalleryModal'],
    [fn('wireNumber'), fn('formatGalleryMeta'), fn('galleryRejection'),
      fn('renderGallery')],
    'renderGallery',
  )(
    doc,
    { items },
    () => {},
    () => {},
    () => {},
    () => {},
  );
  render();
  const cards = doc.getElementById('gallery-grid').children;
  return {
    doc,
    cards,
    textOf: (i) => cards[i].children
      .map((c) => c.children.length
        ? c.children.map((g) => g.textContent).join('')
        : c.textContent)
      .join(' | '),
  };
}

const REJECT_REASON =
  'star count 43 below minimum 100000 (likely cloud / off-target)';

test('a grader-rejected sub carries a visible verdict and its reason', () => {
  const h = galleryGrid([
    { id: 14, filter: 'L', createdAt: 1787057569000, isAccepted: false,
      rejectionReason: REJECT_REASON },
  ]);
  const card = h.cards[0];
  assert.ok(card.classList.contains('gallery-card-rejected'));
  assert.match(card.getAttribute('aria-label'), /rejected by the grader$/,
    'a screen reader must get the verdict with the frame');
  const rendered = h.textOf(0);
  assert.match(rendered, /Rejected/, 'a badge an operator can see at a glance');
  assert.match(rendered, new RegExp(REJECT_REASON.replace(/[()/]/g, '\\$&')),
    "the grader's own words, not a shrug");
});

test('an accepted sub is untouched', () => {
  const h = galleryGrid([
    { id: 26, filter: 'B', createdAt: 1787057569000, isAccepted: true,
      rejectionReason: null },
  ]);
  const card = h.cards[0];
  assert.ok(!card.classList.contains('gallery-card-rejected'));
  assert.doesNotMatch(card.getAttribute('aria-label'), /rejected/i);
  assert.doesNotMatch(h.textOf(0), /Rejected/);
  assert.equal(card.children.filter((c) => c.className === 'gallery-caption')
    .length, 1, 'an accepted card gains no second caption line');
});

test('a listing that says nothing about the verdict invents none', () => {
  const h = galleryGrid([{ id: 3, filter: 'R', createdAt: 1787057569000 }]);
  assert.ok(!h.cards[0].classList.contains('gallery-card-rejected'));
  assert.doesNotMatch(h.textOf(0), /Rejected/);
});

test('a rejection with no stated reason still shows the verdict', () => {
  const h = galleryGrid([
    { id: 9, filter: 'G', createdAt: 1787057569000, isAccepted: false,
      rejectionReason: null },
  ]);
  assert.ok(h.cards[0].classList.contains('gallery-card-rejected'));
  assert.match(h.textOf(0), /Rejected/);
});

test('the count line states the tally the grader produced', () => {
  const line = countLine();
  const night = [];
  for (let i = 0; i < 24; i++) night.push({ id: i, isAccepted: true });
  night.push({ id: 24, isAccepted: false, rejectionReason: REJECT_REASON });
  night.push({ id: 25, isAccepted: false, rejectionReason: REJECT_REASON });
  assert.equal(line(night), '26 images — 2 rejected.');
  assert.equal(line([{ id: 1, isAccepted: true }]), '1 image shown.');
  assert.equal(line([{ id: 1 }, { id: 2 }]), '2 images shown.',
    'a listing that names no verdict reports no rejections');
  assert.equal(line([]), 'No images captured yet.');
  assert.equal(
    line([{ id: 1, isAccepted: false, rejectionReason: REJECT_REASON }]),
    '1 image — 1 rejected.');
});

test('the preview modal states the verdict on the frame it is showing', () => {
  const meta = build(
    [],
    [fn('wireNumber'), fn('formatGalleryMeta'), fn('galleryRejection'),
      fn('galleryModalMeta')],
    'galleryModalMeta',
  )();
  const rejected = meta({ id: 13, filter: 'L', createdAt: 1787057569000,
    isAccepted: false, rejectionReason: REJECT_REASON });
  assert.match(rejected, /REJECTED/);
  assert.ok(rejected.includes(REJECT_REASON));
  const accepted = meta({ id: 26, filter: 'B', createdAt: 1787057569000,
    isAccepted: true, rejectionReason: null });
  assert.doesNotMatch(accepted, /REJECT/i);
  assert.match(accepted, /^B · /);
});

// ---------------------------------------------------------------------------
// w14-B — the active-session card
// ---------------------------------------------------------------------------

/** The REAL renderOpsAnalyticsPanel over the real wireNumber/formatDurationSeconds. */
function analyticsPanel(session, transparency = []) {
  const doc = makeDocument([
    'ops-analytics-session-name', 'ops-analytics-frames',
    'ops-analytics-graded', 'ops-analytics-integration',
    'ops-analytics-hfr', 'ops-analytics-rms',
    'ops-analytics-transparency-summary',
  ]);
  const render = build(
    ['document', 'state', 'drawOpsTransparencySparkline'],
    [fn('wireNumber'), fn('pad2'), fn('formatDurationSeconds'),
      fn('renderOpsAnalyticsPanel')],
    'renderOpsAnalyticsPanel',
  )(doc, { ops: { sessionSummary: { session, transparency } } }, () => {});
  render();
  const read = (id) => doc.getElementById(id).textContent;
  return { doc, read };
}

// GET /api/sessions/active serves the imaging_sessions row, whose exposure
// counters used to be written only every fifth frame, beside an
// accepted/rejected pair the same endpoint counts live off captured_images.
// Four frames into a healthy night the card read "Frames returned 0" next to
// "4 accepted". The counters now advance per frame (SessionService), so the
// two halves of the card come from the same night at the same moment — and
// this is the shape that must never render again.
test('a card that has graded frames cannot report none returned', () => {
  const { read } = analyticsPanel({
    id: 1, name: 'D4 live watch',
    totalExposures: 4, successfulExposures: 4, failedExposures: 0,
    acceptedLights: 4, rejectedLights: 0,
    totalIntegrationSecs: 48.0, avgHfr: 2.67, avgGuidingRms: null,
  });
  assert.equal(read('ops-analytics-frames'), '4');
  assert.equal(read('ops-analytics-graded'), '4 accepted · 0 rejected');
  assert.equal(read('ops-analytics-integration'), '48s');
  assert.equal(read('ops-analytics-hfr'), '2.67');
});

test('a night that has returned nothing yet says so on both rows', () => {
  const { read } = analyticsPanel({
    id: 1, name: 'D4 live watch',
    totalExposures: 0, successfulExposures: 0, failedExposures: 0,
    acceptedLights: 0, rejectedLights: 0,
    totalIntegrationSecs: 0.0, avgHfr: null, avgGuidingRms: null,
  });
  assert.equal(read('ops-analytics-frames'), '0');
  assert.equal(read('ops-analytics-graded'), 'nothing graded yet');
  assert.equal(read('ops-analytics-hfr'), '--');
});

// The `!= null` guard was a presence check, not a type check: it admitted
// "banana" into String(...) and "NaN" into Number(...).toFixed(2), and the
// panel printed both at the operator as if they were measurements.
test('a wrong-typed session payload reads as absent, never as a number', () => {
  const { read } = analyticsPanel({
    id: 9, name: null,
    totalExposures: 'banana', successfulExposures: null,
    acceptedLights: null, rejectedLights: null,
    totalIntegrationSecs: 'NaN', avgHfr: 'x', avgGuidingRms: {},
  });
  assert.equal(read('ops-analytics-session-name'), 'Session #9');
  assert.equal(read('ops-analytics-frames'), '--');
  assert.equal(read('ops-analytics-graded'), '--');
  assert.equal(read('ops-analytics-integration'), '--');
  assert.equal(read('ops-analytics-hfr'), '--');
  assert.equal(read('ops-analytics-rms'), '--');
});

test('a NaN or an Infinity is an absence, not a reading', () => {
  const { read } = analyticsPanel({
    id: 3, name: 'Malformed',
    successfulExposures: NaN, totalExposures: NaN,
    acceptedLights: 2, rejectedLights: NaN,
    totalIntegrationSecs: Infinity, avgHfr: NaN, avgGuidingRms: -Infinity,
  });
  assert.equal(read('ops-analytics-frames'), '--');
  assert.equal(read('ops-analytics-graded'), '--');
  assert.equal(read('ops-analytics-integration'), '--');
  assert.equal(read('ops-analytics-hfr'), '--');
  assert.equal(read('ops-analytics-rms'), '--');
});

test('a numeric string is not a number the panel will print', () => {
  // The Dart handler serialises these as JSON numbers. A string arriving here
  // means the wire changed shape, and guessing at it is how "banana" got on
  // screen in the first place.
  const { read } = analyticsPanel({
    id: 4, name: 'Stringly typed',
    successfulExposures: '7', totalExposures: '7',
    acceptedLights: '7', rejectedLights: '0',
    totalIntegrationSecs: '84', avgHfr: '2.5', avgGuidingRms: '0.4',
  });
  assert.equal(read('ops-analytics-frames'), '--');
  assert.equal(read('ops-analytics-graded'), '--');
  assert.equal(read('ops-analytics-integration'), '--');
  assert.equal(read('ops-analytics-hfr'), '--');
  assert.equal(read('ops-analytics-rms'), '--');
});

test('no active session paints every row absent', () => {
  const { read } = analyticsPanel(null);
  assert.equal(read('ops-analytics-session-name'), 'no active session');
  assert.equal(read('ops-analytics-frames'), '--');
  assert.equal(read('ops-analytics-graded'), '--');
  assert.equal(read('ops-analytics-integration'), '--');
});

// The gate itself, exercised directly: every numeric sink in the sweep routes
// through this one function, so its contract is what the panels inherit.
test('wireNumber admits finite numbers and nothing else', () => {
  const wire = build([], [fn('wireNumber')], 'wireNumber')();
  assert.equal(wire(0), 0);
  assert.equal(wire(-2.5), -2.5);
  assert.equal(wire(48), 48);
  for (const bad of ['banana', 'NaN', '12', '', null, undefined, NaN,
    Infinity, -Infinity, true, false, {}, [], [5]]) {
    assert.equal(wire(bad), null, JSON.stringify(bad) + ' is not a reading');
  }
});

// ---------------------------------------------------------------------------
// w14-B — the rest of the sweep
//
// The analytics card above was the finding's example, not its extent. These
// are the other panels that took a wire value straight into a numeric render,
// and they failed in two directions the card did not: a wrong-typed value
// either printed as a reading ("Temp NaN C", "0.0 °C" from an empty field) or
// threw on `.toFixed` and took the REST of its panel down with it — the rows
// below the bad one never got appended, so a cooling camera rendered as a
// camera with no cooler.
// ---------------------------------------------------------------------------

/** The REAL renderFocuserPanel over the real wireNumber. */
function focuserPanel(focuserStatus, lastAutofocusResult = null) {
  const doc = makeDocument(['focuser-position', 'focuser-temp',
    'focuser-moving', 'focuser-last-af']);
  build(
    ['document', 'state', 'updateFocuserButtons'],
    [fn('wireNumber'), fn('renderFocuserPanel')],
    'renderFocuserPanel',
  )(doc, { focuserStatus, lastAutofocusResult }, () => {})();
  return (id) => doc.getElementById(id).textContent;
}

test('an unreadable focuser temperature does not take the position with it',
  () => {
    const read = focuserPanel({ position: 42, temperature: 'banana' });
    assert.equal(read('focuser-position'), '42');
    assert.equal(read('focuser-temp'), '--');
  });

test('a focuser that reports a real temperature still shows it', () => {
  const read = focuserPanel({ position: 18342, temperature: -4.25 });
  assert.equal(read('focuser-position'), '18342');
  assert.equal(read('focuser-temp'), '-4.3 °C');
});

/** The REAL renderRotatorPanel over the real wireNumber. */
function rotatorPanel(rotatorStatus, lastImagePositionAngle = null) {
  const doc = makeDocument(['rotator-sky-pa', 'rotator-mech-pa',
    'rotator-moving', 'btn-rotator-sync-image']);
  build(
    ['document', 'state', 'updateRotatorButtons'],
    [fn('wireNumber'), fn('renderRotatorPanel')],
    'renderRotatorPanel',
  )(doc, { rotatorStatus, lastImagePositionAngle }, () => {})();
  return (id) => doc.getElementById(id).textContent;
}

test('a rotator angle that is not a number reads as no angle', () => {
  const read = rotatorPanel({ position: 'banana', mechanicalPosition: NaN });
  assert.equal(read('rotator-sky-pa'), '--°');
  assert.equal(read('rotator-mech-pa'), '--°');
});

test('a rotator angle that is a number is painted', () => {
  const read = rotatorPanel({ position: 118.5, mechanicalPosition: 0 });
  assert.equal(read('rotator-sky-pa'), '118.50°');
  assert.equal(read('rotator-mech-pa'), '0.00°');
});

/** The REAL renderCameraStatusInfo; returns the rows it appended, in order. */
function cameraStatusRows(cameraStatus) {
  const doc = makeDocument(['camera-status-info']);
  const rows = [];
  build(
    ['document', 'state', 'clearElement', 'createStatusRow',
      'updateCameraButtons'],
    [fn('wireNumber'), fn('renderCameraStatusInfo')],
    'renderCameraStatusInfo',
  )(
    doc,
    { cameraStatus },
    () => { rows.length = 0; },
    (label, value) => {
      rows.push(label + '=' + value);
      return doc.createElement('div');
    },
    () => {},
  )();
  return rows;
}

test('a camera with no temperature reading still shows its cooler', () => {
  // `null.toFixed` threw here, and the throw escaped the whole render: State
  // was already on the panel, Cooler and Exposure never arrived, and the
  // operator read a camera that was cooling as one with no cooler at all.
  assert.deepEqual(
    cameraStatusRows({ cameraState: 'idle', ccdTemperature: null,
      coolerPower: 55, percentCompleted: 40 }),
    ['State=idle', 'Cooler=55%', 'Exposure=40%']);
});

test('a camera temperature of NaN is omitted, never printed', () => {
  assert.deepEqual(
    cameraStatusRows({ cameraState: 'exposing', ccdTemperature: NaN,
      coolerPower: 55, percentCompleted: 40 }),
    ['State=exposing', 'Cooler=55%', 'Exposure=40%']);
});

test('a wrong-typed cooler figure drops only its own row', () => {
  assert.deepEqual(
    cameraStatusRows({ cameraState: 'idle', ccdTemperature: -12.5,
      coolerPower: '55', percentCompleted: 40 }),
    ['State=idle', 'Temp=-12.5 C', 'Exposure=40%']);
});

test('a fully reporting camera renders every row', () => {
  assert.deepEqual(
    cameraStatusRows({ cameraState: 'exposing', ccdTemperature: -10.0,
      coolerPower: 62.4, percentCompleted: 33.3 }),
    ['State=exposing', 'Temp=-10.0 C', 'Cooler=62%', 'Exposure=33%']);
});

test('the weather rows refuse every value Number() would invent', () => {
  const setOpsTelemetry = build(
    ['document'], [fn('wireNumber'), fn('setOpsTelemetry')], 'setOpsTelemetry',
  )(makeDocument([]));
  const doc = makeDocument(['t']);
  const el = doc.getElementById('t');
  const format = (v) => v.toFixed(1) + ' °C';
  // Each of these used to coerce to a number and paint one: '' and [] became
  // 0.0 °C — a freeze warning from a sensor that reported nothing.
  for (const bad of ['', [], true, '12', 'banana', null, undefined, NaN]) {
    setOpsTelemetry(el, bad, format);
    assert.equal(el.textContent, '--', JSON.stringify(bad) + ' is not a reading');
  }
  setOpsTelemetry(el, -3.5, format);
  assert.equal(el.textContent, '-3.5 °C');
  setOpsTelemetry(el, 0, format);
  assert.equal(el.textContent, '0.0 °C');
});

test('a coordinate formatter answers only to numbers', () => {
  const formatRA = build(
    [], [fn('wireNumber'), fn('pad2'), fn('formatRA')], 'formatRA')();
  const formatDec = build(
    [], [fn('wireNumber'), fn('pad2'), fn('formatDec')], 'formatDec')();
  // `isNaN([])` is false, so an empty array used to print the pole: an
  // observatory pointed at 00h 00m from a payload that named no coordinate.
  for (const bad of [[], true, '5.588', 'banana', null, undefined, NaN, {}]) {
    assert.equal(formatRA(bad), '--h --m --s',
      JSON.stringify(bad) + ' is not an RA');
    assert.equal(formatDec(bad), '--° --\' --"',
      JSON.stringify(bad) + ' is not a Dec');
  }
  assert.equal(formatRA(5.588), '05h 35m 16.8s');
  assert.equal(formatDec(-5.39), '-05° 23\' 24"');
});

test('a target row with an unreadable coordinate offers no coordinate', () => {
  const doc = makeDocument(['ops-target-results']);
  const list = doc.getElementById('ops-target-results');
  build(
    ['document', 'state', 'clearElement', 'createEmptyState',
      'handleOpsTargetSelect'],
    [fn('wireNumber'), fn('pad2'), fn('formatRA'), fn('formatDec'),
      fn('renderOpsTargetResults')],
    'renderOpsTargetResults',
  )(
    doc,
    { ops: { catalogResults: [{ id: 1, name: 'M42', ra: 'banana', dec: {} }] } },
    () => { list.children.length = 0; },
    () => doc.createElement('div'),
    () => {},
  )();
  const coords = list.children[0].children.map((c) => c.textContent);
  assert.equal(coords[coords.length - 1], '--');
});

test('a target with an unreadable coordinate is not slewed to', () => {
  // The worst of the family: `Number('banana')` handed NaN to the mount and
  // logged "RA NaNh" beside it, so the operator watched a slew commanded to a
  // place that does not exist.
  const slews = [];
  const said = [];
  const doc = makeDocument(['mount-goto-name', 'mount-goto-ra',
    'mount-goto-dec']);
  const select = build(
    ['document', 'state', 'api', 'showToast', 'addLogEntry',
      'describeApiError', 'renderOpsSequencerLoadPanel'],
    [fn('wireNumber'), fn('pad2'), fn('formatRA'), fn('formatDec'),
      fn('handleOpsTargetSelect')],
    'handleOpsTargetSelect',
  )(
    doc,
    { mountDeviceId: 'mount-1', ops: {} },
    { mountSlewToRaDec: (id, ra, dec) => { slews.push([ra, dec]); return Promise.resolve(); } },
    (msg) => said.push(msg),
    (category, msg) => said.push(msg),
    (e) => String(e),
    () => {},
  );
  return select({ id: 1, name: 'M42', ra: 'banana', dec: 1.2 }).then(() => {
    assert.deepEqual(slews, []);
    assert.ok(said.some((m) => m.includes('has no coordinates')), said.join(' / '));
  });
});

test('a readable target is still slewed to, and logged as sent', () => {
  const slews = [];
  const said = [];
  const doc = makeDocument(['mount-goto-name', 'mount-goto-ra',
    'mount-goto-dec']);
  const select = build(
    ['document', 'state', 'api', 'showToast', 'addLogEntry',
      'describeApiError', 'renderOpsSequencerLoadPanel'],
    [fn('wireNumber'), fn('pad2'), fn('formatRA'), fn('formatDec'),
      fn('handleOpsTargetSelect')],
    'handleOpsTargetSelect',
  )(
    doc,
    { mountDeviceId: 'mount-1', ops: {} },
    { mountSlewToRaDec: (id, ra, dec) => { slews.push([ra, dec]); return Promise.resolve(); } },
    (msg) => said.push(msg),
    (category, msg) => said.push(msg),
    (e) => String(e),
    () => {},
  );
  return select({ id: 1, name: 'M42', ra: 5.588, dec: -5.39 }).then(() => {
    assert.deepEqual(slews, [[5.588, -5.39]]);
    assert.ok(said.some((m) => m.includes('RA 5.588h')), said.join(' / '));
    assert.equal(doc.getElementById('mount-goto-ra').value, '05h 35m 16.8s');
  });
});

/** The REAL renderPolarAlignmentPanel over the real wireNumber. */
function polarPanel(polarAlignment) {
  const doc = makeDocument(['pa-phase', 'pa-total-error', 'pa-modal-phase',
    'pa-modal-error', 'pa-modal-status']);
  build(['document', 'state'],
    [fn('wireNumber'), fn('renderPolarAlignmentPanel')],
    'renderPolarAlignmentPanel')(doc, { polarAlignment })();
  return (id) => doc.getElementById(id).textContent;
}

test('an unreadable polar error leaves the phase readable', () => {
  // `isFinite('3.5')` is true, so the old guard admitted the string and threw
  // on `.toFixed` — and the throw was raised before the phase row was written
  // in the modal, so the operator lost the whole alignment readout.
  const read = polarPanel({ phase: 'measuring', totalErrorArcmin: '3.5',
    statusMessage: 'adjusting' });
  assert.equal(read('pa-phase'), 'measuring');
  assert.equal(read('pa-total-error'), '--');
  assert.equal(read('pa-modal-error'), '--');
  assert.equal(read('pa-modal-status'), 'adjusting');
});

test('a measured polar error is painted and graded', () => {
  const read = polarPanel({ phase: 'done', totalErrorArcmin: 0.42,
    statusMessage: 'good' });
  assert.equal(read('pa-total-error'), "0.42'");
  assert.equal(read('pa-modal-error'), "0.42'");
});

test('a gallery row states an exposure only when one was sent', () => {
  const meta = build([], [fn('wireNumber'), fn('formatGalleryMeta')],
    'formatGalleryMeta')();
  // `Number([])` is 0, so an empty exposure field used to label the frame
  // "0s" — a sub that was never exposed.
  assert.doesNotMatch(meta({ id: 1, filter: 'L', exposureTime: [] }), /s$/);
  assert.doesNotMatch(meta({ id: 2, filter: 'L', exposureTime: true }), /1s/);
  assert.doesNotMatch(meta({ id: 3, filter: 'L', exposureTime: '120' }), /120s/);
  assert.match(meta({ id: 4, filter: 'L', exposureTime: 120 }), /120s/);
});

// ---------------------------------------------------------------------------
// D4-03 — the camera panel's empty live preview
// ---------------------------------------------------------------------------

/** Every string a rendered subtree carries, joined. */
function textOf(el) {
  const parts = el.textContent ? [el.textContent] : [];
  for (const child of el.children) parts.push(textOf(child));
  return parts.join(' ').trim();
}

/** The REAL renderEmptyLivePreview over a given fallback state. */
function emptyPreview(fallback) {
  const doc = makeDocument(['image-preview']);
  const thumbs = [];
  const reads = [];
  const render = build(
    ['document', 'previewFallback', 'formatGalleryMeta', 'galleryRejection',
      'loadGalleryThumbnail', 'loadPreviewFallback'],
    [fn('createImagePlaceholder'), fn('replaceWithPreviewPlaceholder'),
      fn('renderEmptyLivePreview')],
    'renderEmptyLivePreview',
  )(
    doc,
    fallback,
    build([], [fn('wireNumber'), fn('formatGalleryMeta')],
      'formatGalleryMeta')(),
    build([], [fn('galleryRejection')], 'galleryRejection')(),
    (img, id, opts) => { thumbs.push({ id, opts }); },
    () => { reads.push('library'); },
  );
  const container = doc.getElementById('image-preview');
  container.setAttribute('aria-label', 'Most recent exposure preview');
  render(container);
  return {
    container,
    text: textOf(container),
    label: container.getAttribute('aria-label'),
    thumbs,
    reads,
  };
}

// `/api/camera/last-image/jpeg` serves an in-memory buffer that a relaunched
// server has none of. Printing "No image captured yet" over its 404 put an
// absolute on the same screen whose gallery said "14 images — 2 rejected",
// measured against a rig restarted on its own database.
test('an empty buffer over a stocked library shows the library frame', () => {
  const { text, thumbs } = emptyPreview({
    status: 'read',
    item: { id: 14, filter: 'L', exposureTime: 120, isAccepted: true,
      createdAt: '2026-08-31T13:59:12Z' },
    error: '',
  });
  assert.deepEqual(thumbs.map((t) => t.id), ['14']);
  assert.match(text, /Last capture in the library/);
  assert.match(text, /no exposure since it started/);
  assert.doesNotMatch(text, /No image captured yet/);
});

test('a rejected last capture is labelled as one', () => {
  const { text } = emptyPreview({
    status: 'read',
    item: { id: 9, filter: 'L', isAccepted: false,
      rejectionReason: 'star count 43 below minimum 100000' },
    error: '',
  });
  assert.match(text, /rejected by the grader/);
});

test('"nothing captured" is said only when the library is empty too', () => {
  const { text, thumbs } = emptyPreview(
    { status: 'read', item: null, error: '' });
  assert.deepEqual(thumbs, []);
  assert.match(text, /No image captured yet/);
  assert.match(text, /the image library is empty too/);
});

test('an unreadable library is not reported as an empty one', () => {
  const { text } = emptyPreview(
    { status: 'unreadable', item: null, error: 'Image library: 503' });
  assert.match(text, /could not be read/);
  assert.match(text, /Image library: 503/);
  assert.doesNotMatch(text, /No image captured yet/);
  assert.doesNotMatch(text, /library is empty/);
});

test('an unread fallback asks the library exactly once per render', () => {
  const { text, reads } = emptyPreview(
    { status: 'unread', item: null, error: '' });
  assert.deepEqual(reads, ['library']);
  assert.match(text, /Looking for the last capture/);
  assert.doesNotMatch(text, /No image captured yet/);
});

// The pre-connection markup made the same absolute claim before any fetch had
// run, so it is not there to be read either.
// The container is `role="img"`, so its aria-label REPLACES the caption for a
// screen reader. Every branch's sentence has to be there too, or the panel is
// honest only to people who can see it.
test('the panel says the same thing to assistive tech', () => {
  const shown = emptyPreview({
    status: 'read',
    item: { id: 14, filter: 'L', isAccepted: true },
    error: '',
  });
  assert.equal(shown.label, shown.text);

  const empty = emptyPreview({ status: 'read', item: null, error: '' });
  assert.equal(empty.label, empty.text);
  assert.notEqual(empty.label, 'Most recent exposure preview');

  const broken = emptyPreview(
    { status: 'unreadable', item: null, error: 'Image library: 503' });
  assert.match(broken.label, /could not be read/);
});

test('the static camera placeholder claims nothing about the night', () => {
  assert.doesNotMatch(HTML, /No image captured yet/);
  assert.match(HTML, /Preview not loaded yet/);
});

// ---------------------------------------------------------------------------
// W19-A / D4-02, D4-03, D4-06 — a refusal the operator can read
//
// Measured against the release bundle with a read-only token on a live run:
// pressing Pause posted /api/sequencer/pause, took a 403 naming
// sequencer:control, and left the button enabled with no title, no Event Log
// line, and a toast that pasted the wire body verbatim and then faded. Signing
// in with a fine-grained view token that the rig accepts and honours produced
// "The desktop rejected this token. Check it against the desktop's Remote
// Access screen" — advice that cannot fix a scope problem, for a token that
// was not rejected. And the Settings panel, refused a control-scope read,
// rendered Observer / Save path / Latitude / Longitude / Elevation as "--",
// which reads as an unconfigured host rather than a withheld one.
// ---------------------------------------------------------------------------

/** The 403 body the rig sends when it names the capability it refused on. */
function scopeDeniedBody(resource, requiredLevel, tokenLevel) {
  return JSON.stringify({
    error: 'Access denied',
    message: 'Token scope is not permitted for this endpoint: this credential '
      + 'holds ' + tokenLevel + ' on ' + resource + ', and ' + requiredLevel
      + ' is required.',
    requiredResource: resource,
    requiredLevel,
    tokenLevel,
  });
}

test('the client tells a scope refusal from a credential the rig will not take', () => {
  const context = vm.createContext({ JSON: globalThis.JSON, console });
  vm.runInContext(API + '\n;globalThis.__cls = SkotiqApi._scopeRefusalFrom;', context);
  const classify = context.__cls;

  // Field by field: the classifier's object comes out of the vm realm, so a
  // structural compare against a literal built here is never reference-equal.
  const named = classify(403, scopeDeniedBody('sequencer', 'control', 'view'));
  assert.equal(named.resource, 'sequencer');
  assert.equal(named.requiredLevel, 'control');
  assert.equal(named.tokenLevel, 'view');

  // The rig answers an unknown bearer with 403 as well. That one names no
  // capability, and treating it as a scope refusal would leave a revoked
  // device carrying a dead token.
  assert.equal(classify(403, JSON.stringify({
    error: 'Access denied', message: 'Invalid authentication token',
  })), null);
  assert.equal(classify(401, JSON.stringify({ error: 'Authentication required' })), null);
  assert.equal(classify(403, 'not json'), null);
});

test('a 403 naming a capability arrives as a typed scope refusal', async () => {
  const api = loadApi(async () => new Response(
    scopeDeniedBody('sequencer', 'control', 'view'),
    { status: 403, headers: { 'content-type': 'application/json' } },
  ));
  api.configure('http://127.0.0.1:8210', 'a-read-only-token', 'dev');
  await assert.rejects(
    () => api.sequencerPause(),
    (e) => e.kind === 'scope_denied'
      && e.status === 403
      && e.detail.resource === 'sequencer'
      && e.detail.requiredLevel === 'control'
      && e.detail.tokenLevel === 'view',
  );
});

test('sign-in copy states the server\'s own reason, not one word for two failures', () => {
  const describe = build(
    ['x'],
    [fn('describeScopeRefusal'), fn('describeConnectFailure')],
    'describeConnectFailure',
  )(null);

  const scoped = describe({
    kind: 'scope_denied', status: 403,
    detail: { resource: 'info', requiredLevel: 'view', tokenLevel: 'none' },
  });
  assert.equal(scoped.kind, 'insufficient_scope');
  assert.match(scoped.message, /view access to info/);
  assert.match(scoped.message, /no access to info/);
  assert.match(scoped.message, /info:view/,
    'name the spec to ask for — re-pairing with the same one reproduces this');
  assert.doesNotMatch(scoped.message, /rejected this token/,
    'the token was not rejected; it was accepted and is short of scope');

  // A credential the rig will not take is still the other sentence.
  const rejected = describe({ kind: 'http_error', status: 401, message: 'x' });
  assert.equal(rejected.kind, 'rejected');
  assert.match(rejected.message, /did not accept this credential/);
});

/** The real reportSeqFailure over recorders. */
function seqFailureReporter(doc) {
  const toasts = [];
  const log = [];
  const report = build(
    ['document', 'showToast', 'addLogEntry', 'describeApiError', 'refusedControls'],
    [fn('describeScopeRefusal'), fn('noteControlRefused'), fn('reportSeqFailure')],
    'reportSeqFailure',
  )(
    doc,
    (m, kind) => toasts.push({ message: m, kind }),
    (kind, text) => log.push(kind + ': ' + text),
    (e, what) => what + ' failed: ' + (e && e.message),
    new Map(),
  );
  return { report, toasts, log };
}

test('a refused control names its refusal on the control, in a toast and in the log', () => {
  const doc = makeDocument(['btn-seq-pause']);
  const { report, toasts, log } = seqFailureReporter(doc);

  report('btn-seq-pause', {
    kind: 'scope_denied', status: 403,
    detail: { resource: 'sequencer', requiredLevel: 'control', tokenLevel: 'view' },
  }, 'Pause');

  const btn = doc.getElementById('btn-seq-pause');
  assert.equal(btn.disabled, true,
    'a control this credential cannot use may not stay live and do nothing');
  assert.match(btn.title, /control access to sequencer/);
  assert.equal(btn.getAttribute('aria-disabled'), 'true');

  assert.equal(toasts.length, 1);
  assert.match(toasts[0].message, /control access to sequencer/);
  assert.doesNotMatch(toasts[0].message, /\{|Access denied/,
    'the wire body is a diagnostic, not a sentence for the operator');
  assert.equal(toasts[0].kind, 'error');

  assert.equal(log.length, 1,
    'a toast fades; "I pressed Pause and nothing happened" needs a record');
  assert.match(log[0], /Pause refused/);
});

/** The real runSeqNoop, over recorders, with the real seqErrorBody under it. */
function seqNoopRunner() {
  const toasts = [];
  const log = [];
  const failures = [];
  const run = build(
    ['showToast', 'addLogEntry', 'reportSeqFailure'],
    [fn('seqErrorBody'), fn('runSeqNoop')],
    'runSeqNoop',
  )(
    (m, kind) => toasts.push({ message: m, kind }),
    (kind, text) => log.push(kind + ': ' + text),
    (buttonId, e, what) => failures.push({ buttonId, what, e }),
  );
  return { run, toasts, log, failures };
}

/** The refusal the host answers pause/resume with when nothing is in flight. */
function notRunningRefusal(verb) {
  const body = JSON.stringify({
    error: 'sequencer_not_running',
    message: 'No sequence is running; nothing to ' + verb + '.',
    wasRunning: false,
    state: 'idle',
  });
  const e = new Error('POST /api/sequencer/' + verb + ' failed (409): ' + body);
  e.kind = 'http_error';
  e.status = 409;
  e.detail = { status: 409, body };
  return e;
}

// Stop already read `wasRunning: false` off its 200 and said so plainly. Pause
// and resume answer the same verdict as a 409, and routing that through
// reportSeqFailure printed the whole JSON body as a red "Pause failed: POST
// /api/sequencer/pause failed (409): {…}" — a product fault for a press that
// simply had nothing to act on.
test('a pause with nothing running reads as information, not a failure', async () => {
  const { run, toasts, log, failures } = seqNoopRunner();
  await run(
    () => Promise.reject(notRunningRefusal('pause')),
    'btn-seq-pause', 'Pause', 'Sequence paused',
  );

  assert.equal(failures.length, 0,
    'nothing was running: that is the answer to the press, not a failure');
  assert.equal(toasts.length, 1);
  assert.equal(toasts[0].kind, undefined,
    'an informational toast, never the red error kind');
  assert.match(toasts[0].message, /nothing to pause/);
  assert.doesNotMatch(toasts[0].message, /[{}]|sequencer_not_running|409/,
    'the raw refusal body is a diagnostic, not a sentence for the operator');
  assert.match(log[0], /Pause ignored: no sequence was running/);
});

test('a resume with nothing running says so too', async () => {
  const { run, toasts, failures } = seqNoopRunner();
  await run(
    () => Promise.reject(notRunningRefusal('resume')),
    'btn-seq-resume', 'Resume', 'Sequence resumed',
  );
  assert.equal(failures.length, 0);
  assert.match(toasts[0].message, /nothing to resume/);
});

test('every other pause failure keeps the error toast it always had', async () => {
  const { run, toasts, failures } = seqNoopRunner();
  await run(
    () => Promise.reject({ kind: 'scope_denied', status: 403, detail: {} }),
    'btn-seq-pause', 'Pause', 'Sequence paused',
  );
  assert.equal(toasts.length, 0, 'the reporter owns the toast for a real failure');
  assert.equal(failures.length, 1);
  assert.equal(failures[0].buttonId, 'btn-seq-pause');
  assert.equal(failures[0].what, 'Pause');
});

test('a 409 that is not the not-running refusal is still a failure', async () => {
  const { run, failures } = seqNoopRunner();
  const body = JSON.stringify({ error: 'sequencer_busy', message: 'busy' });
  const e = new Error('POST /api/sequencer/pause failed (409): ' + body);
  e.kind = 'http_error';
  e.status = 409;
  e.detail = { status: 409, body };
  await run(() => Promise.reject(e), 'btn-seq-pause', 'Pause', 'Sequence paused');
  assert.equal(failures.length, 1, 'only the not-running verdict is informational');
});

test('a pause that did pause logs the act and raises no toast', async () => {
  const { run, toasts, log, failures } = seqNoopRunner();
  await run(async () => ({}), 'btn-seq-pause', 'Pause', 'Sequence paused');
  assert.equal(failures.length, 0);
  assert.equal(toasts.length, 0);
  assert.equal(log[0], 'sequencer: Sequence paused');
});

test('a 200 reporting wasRunning false is not read as a pause', async () => {
  // The stop contract, honoured on this path too: a host that answers the
  // no-op with 200 rather than 409 must not be logged as "Sequence paused".
  const { run, toasts, log } = seqNoopRunner();
  await run(
    async () => ({ wasRunning: false }),
    'btn-seq-pause', 'Pause', 'Sequence paused',
  );
  assert.match(log[0], /Pause ignored: no sequence was running/);
  assert.match(toasts[0].message, /No sequence was running/);
});

/**
 * The REAL handleSeqPause / handleSeqResume / handleSeqStop, over the real
 * runSeqNoop and seqErrorBody, with only `api` and the reporters stubbed.
 *
 * The helper being correct proves nothing on its own: the defect was the
 * HANDLER routing its 409 straight to reportSeqFailure, so the wiring is what
 * has to be executed.
 */
function seqControl(name, apiMethod, answer) {
  const toasts = [];
  const log = [];
  const failures = [];
  const handler = build(
    ['api', 'showToast', 'addLogEntry', 'reportSeqFailure'],
    [fn('seqErrorBody'), fn('runSeqNoop'), fn(name)],
    name,
  )(
    { [apiMethod]: answer },
    (m, kind) => toasts.push({ message: m, kind }),
    (kind, text) => log.push(kind + ': ' + text),
    (buttonId, e, what) => failures.push({ buttonId, what, e }),
  );
  return { handler, toasts, log, failures };
}

test('the Pause button itself answers a not-running 409 as information', async () => {
  const { handler, toasts, log, failures } = seqControl(
    'handleSeqPause', 'sequencerPause',
    () => Promise.reject(notRunningRefusal('pause')),
  );
  await handler();
  assert.equal(failures.length, 0,
    'the handler, not just the helper, must route the refusal');
  assert.equal(toasts[0].kind, undefined);
  assert.doesNotMatch(toasts[0].message, /[{}]|sequencer_not_running|409/);
  assert.match(log[0], /Pause ignored: no sequence was running/);
});

test('the Resume button itself answers a not-running 409 as information', async () => {
  const { handler, toasts, failures } = seqControl(
    'handleSeqResume', 'sequencerResume',
    () => Promise.reject(notRunningRefusal('resume')),
  );
  await handler();
  assert.equal(failures.length, 0);
  assert.match(toasts[0].message, /nothing to resume/);
});

test('the Pause button still reports a real failure as one', async () => {
  const { handler, failures } = seqControl(
    'handleSeqPause', 'sequencerPause',
    () => Promise.reject({ kind: 'scope_denied', status: 403, detail: {} }),
  );
  await handler();
  assert.equal(failures.length, 1);
  assert.equal(failures[0].buttonId, 'btn-seq-pause');
});

test('Stop keeps the wasRunning reading it already had', async () => {
  const stopped = seqControl(
    'handleSeqStop', 'sequencerStop', async () => ({ wasRunning: true }),
  );
  await stopped.handler();
  assert.deepEqual(stopped.log, ['sequencer: Sequence stopped']);
  assert.equal(stopped.toasts.length, 0);

  const nothing = seqControl(
    'handleSeqStop', 'sequencerStop', async () => ({ wasRunning: false }),
  );
  await nothing.handler();
  assert.match(nothing.log[0], /Stop ignored: no sequence was running/);
  assert.match(nothing.toasts[0].message, /No sequence was running/);
});

test('the next status poll does not hand a refused control back', () => {
  const doc = makeDocument([
    'btn-seq-start', 'btn-seq-pause', 'btn-seq-resume', 'btn-seq-stop',
  ]);
  const refused = new Map([['btn-seq-pause', 'Pause needs control access to sequencer.']]);
  const update = build(
    ['document', 'refusedControls'],
    [fn('updateSequencerButtons')],
    'updateSequencerButtons',
  )(doc, refused);

  update('running');
  assert.equal(doc.getElementById('btn-seq-pause').disabled, true);
  assert.match(doc.getElementById('btn-seq-pause').title, /control access to sequencer/);
  assert.equal(doc.getElementById('btn-seq-stop').disabled, false,
    'only the refused control is held down');
});

test('a settings read the credential cannot make is named, not painted as unknown', async () => {
  const ids = [
    'settings-observer-name', 'settings-save-path', 'settings-plate-solver',
    'settings-latitude', 'settings-longitude', 'settings-elevation',
  ];
  const doc = makeDocument(ids);
  for (const id of ids) doc.getElementById(id).textContent = '--';
  const log = [];
  const refusal = {
    kind: 'scope_denied', status: 403,
    detail: { resource: 'system', requiredLevel: 'control', tokenLevel: 'view' },
  };
  const refresh = build(
    ['document', 'api', 'addLogEntry', 'describeApiError', 'settingsPanelHint'],
    [konst('SETTINGS_VALUE_IDS'), fn('describeScopeRefusal'),
      fn('saySettingsWithheld'), fn('clearSettingsWithheld'), fn('wireNumber'),
      fn('refreshSettingsPanel')],
    'refreshSettingsPanel',
  )(
    doc,
    {
      isConnected: true,
      getSettings: async () => { throw refusal; },
      getLocation: async () => { throw refusal; },
    },
    (kind, text) => log.push(kind + ': ' + text),
    (e, what) => what + ' refused',
    null,
  );

  await refresh();

  for (const id of ids) {
    assert.equal(doc.getElementById(id).textContent, 'not permitted',
      id + ' read "--", which describes an unconfigured host, not a withheld one');
    assert.match(doc.getElementById(id).title, /control access to system/);
  }
  assert.equal(log.length, 1);
});
