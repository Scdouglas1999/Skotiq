// Run-Watch honesty contract.
//
// This surface is what an operator looks at from bed. Everything it shows is a
// cache of the last snapshot the server answered, so the questions that matter
// are: does it admit when that cache has gone stale, does it invent numbers the
// server never sent, and does it report the server's own refusals.
//
// The tests EXECUTE the page's render path against a DOM shim rather than
// grepping its source: what the operator sees is the contract.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const { makeDocument } = require('./dom_shim');

const RUN_WATCH = path.join(__dirname, '..', '..', 'web_run_watch');
const SOURCE = fs.readFileSync(path.join(RUN_WATCH, 'js', 'run-watch.js'), 'utf8');

const IDS = [
  'state-badge', 'seq-name', 'connection-dot', 'link-banner', 'recovery-banner',
  'target-state', 'target-name', 'target-coords', 'target-alt', 'target-az',
  'target-time-set', 'target-time-transit',
  'progress-pct', 'progress-bar', 'progress-bar-aria', 'progress-frames',
  'progress-integration', 'progress-node', 'progress-filter',
  'frame-meta', 'frame-img', 'frame-placeholder', 'frame-wrap',
  'frame-loading-badge',
  'equipment-list', 'guide-state', 'guide-ra', 'guide-dec', 'guide-total',
  'guide-snr', 'weather-badge', 'weather-message', 'event-feed', 'toast-region',
  'seq-message',
  'pair-screen', 'main-screen', 'pair-status', 'btn-request-code',
  'pair-code-source',
  'opt-wake-lock', 'opt-wake-lock-row', 'opt-wake-lock-note',
  'opt-push', 'opt-push-row', 'opt-push-note',
  'btn-pause', 'btn-resume', 'btn-skip', 'btn-stop', 'btn-reset',
];

/**
 * Load run-watch.js into a sandbox and hand back the internals under test.
 * The file is a plain script with no exports, so the accessors are appended
 * to its own scope.
 */
function loadRunWatch(overrides) {
  const doc = makeDocument(IDS);
  const timers = [];
  /// One-shot callbacks the page has deferred. Captured rather than dropped so
  /// a test can run the coalesced snapshot re-read a frame event schedules.
  const deferred = [];
  const sandbox = {
    // `window` and `navigator` carry the capability surface the settings sheet
    // feature-tests, so a test can hand the page the origin it is pretending
    // to be served from.
    window: Object.assign(
      { addEventListener() {}, crypto: undefined, isSecureContext: true },
      (overrides && overrides.window) || {},
    ),
    document: doc,
    localStorage: {
      _m: new Map(),
      getItem(k) { return this._m.has(k) ? this._m.get(k) : null; },
      setItem(k, v) { this._m.set(k, String(v)); },
      removeItem(k) { this._m.delete(k); },
    },
    // The dashboard's own per-tab store. run-watch reads the bearer the
    // dashboard leaves here rather than asking an already-signed-in operator to
    // pair again, so a test can hand it the state a real tab would be in.
    sessionStorage: {
      _m: new Map((overrides && overrides.sessionStorage) || []),
      getItem(k) { return this._m.has(k) ? this._m.get(k) : null; },
      setItem(k, v) { this._m.set(k, String(v)); },
      removeItem(k) { this._m.delete(k); },
    },
    navigator: Object.assign(
      { userAgent: 'node-test' }, (overrides && overrides.navigator) || {}),
    fetchImpl: (overrides && overrides.fetch) || (() => {
      throw new Error('no fetch stub installed');
    }),
    EventSource: (overrides && overrides.EventSource) ||
      function () { this.close = () => {}; this.addEventListener = () => {}; },
    setInterval: (fn, ms) => { timers.push({ fn, ms }); return timers.length; },
    clearInterval: () => {},
    setTimeout: (fn, ms) => { deferred.push({ fn, ms }); return deferred.length; },
    Headers: globalThis.Headers,
    console: { warn() {}, log() {} },
    // The frame card hands blobs to the <img> through object URLs. Counting
    // the create/revoke pairs is how a test proves the page dropped the stale
    // JPEG when the server stopped answering with one.
    URL: {
      _live: new Set(),
      _n: 0,
      createObjectURL(blob) {
        const u = 'blob:frame-' + (++this._n);
        this._live.add(u);
        return u;
      },
      revokeObjectURL(u) { this._live.delete(u); },
    },
  };

  const suffix = `
;return {
  applySnapshot,
  fetchSnapshot,
  renderLinkState,
  isLinkStale,
  noteLinkOk,
  noteLinkFailure,
  retryAfterSecsFrom,
  apiFetch,
  setToken,
  tokenWasEverAccepted,
  handleSseMessage,
  isProgressTickEvent,
  openSSE,
  FEED_EVENT_NAMES,
  showPairScreen,
  sequencerAction,
  scopeRefusalText,
  updateRunControls,
  peekRefusedControls: () => new Map(refusedControls),
  formatDurationSecs,
  resolveCredentialAndShow,
  adoptSessionCookie,
  credentialRefusalText,
  codeDeliveryText,
  requestPairingCode,
  startPairing,
  renderSnapshot,
  renderFrameCounter,
  noteFrameEvent,
  noteFeedEvent,
  feedEventKey,
  peekFeed: () => ({
    events: feedEvents.slice(),
    keys: new Set(feedSeenKeys),
    ticks: foldedProgressTicks,
  }),
  refreshFrame,
  peekCredential: () => ({
    adoptedBearer, sessionCsrfToken, credentialSource,
    effective: effectiveToken(),
  }),
  wakeLockSupport,
  notificationSupport,
  refreshCapabilityToggles,
  applyWakeLockOption,
  applyPushOption,
  readOpts: loadOpts,
  pokeOpts: saveOpts,
  peek: () => ({ lastSnapshotAt, linkFailure, rateLimitedUntil, lastKnownState }),
  poke: (o) => {
    if (o.lastSnapshotAt !== undefined) lastSnapshotAt = o.lastSnapshotAt;
    if (o.sessionStartedAt !== undefined) sessionStartedAt = o.sessionStartedAt;
    if (o.linkFailure !== undefined) linkFailure = o.linkFailure;
    if (o.rateLimitedUntil !== undefined) rateLimitedUntil = o.rateLimitedUntil;
  },
};`;

  // eslint-disable-next-line no-new-func
  const factory = new Function(
    'window', 'document', 'localStorage', 'sessionStorage', 'navigator',
    'fetch', 'EventSource', 'setInterval', 'clearInterval', 'setTimeout',
    'Headers', 'console', 'URL',
    SOURCE + suffix,
  );
  const api = factory(
    sandbox.window, sandbox.document, sandbox.localStorage,
    sandbox.sessionStorage, sandbox.navigator,
    sandbox.fetchImpl, sandbox.EventSource, sandbox.setInterval,
    sandbox.clearInterval, sandbox.setTimeout, sandbox.Headers, sandbox.console,
    sandbox.URL,
  );
  return { doc, api, timers, deferred, sandbox };
}

/** A snapshot shaped like a live headless run of the D1 sim sequence. */
function runningSnapshot(extra) {
  return Object.assign({
    serverTime: new Date().toISOString(),
    sequencer: {
      state: 'running',
      currentNodeName: 'Exposure L',
      progress: {
        state: 'running',
        currentTarget: 'D1 Simulated Field',
        currentNodeName: 'Exposure L',
        currentFilter: 'L',
        totalExposures: 12,
        completedExposures: 1,
        completedIntegrationSecs: 2.0,
        totalIntegrationSecs: null,
        progressPercent: 1 / 12,
      },
    },
    activeTarget: {
      coordinatesKnown: false,
      message: 'Coordinates unavailable: the native executor holds this run',
      id: null,
      name: 'D1 Simulated Field',
      raHours: null,
      decDegrees: null,
      altitudeDeg: null,
      azimuthDeg: null,
      timeToSetSecs: null,
      timeToTransitSecs: null,
    },
    guiding: {
      state: 'Disconnected',
      connected: false,
      rmsRa: 0.0,
      rmsDec: 0.0,
      rmsTotal: 0.0,
      snr: 0.0,
    },
    weather: {
      safeToImage: true,
      alertLevel: 'clear',
      message: 'Weather safety is off — conditions are not being checked',
      dataSource: 'unavailable',
      lastEvaluation: null,
    },
    devices: [],
    recentEvents: [],
    recovery: null,
  }, extra || {});
}

// D4-02. A killed backend used to leave a green `badge-running` on screen
// indefinitely — measured at 35 s after SIGKILL, two poll intervals, with the
// frame counter frozen at "1 / 12" and no banner anywhere on the page.
test('a lost server flips the state badge and raises a banner', () => {
  const { doc, api } = loadRunWatch();
  api.noteLinkOk();
  api.applySnapshot(runningSnapshot());
  assert.equal(doc.getElementById('state-badge').textContent, 'running');
  assert.ok(doc.getElementById('state-badge').classList.contains('badge-running'));
  api.renderLinkState();
  assert.ok(doc.getElementById('link-banner').classList.contains('hidden'),
    'a healthy link raises no banner');

  // The server goes away: the next poll's fetch rejects.
  api.noteLinkFailure('unreachable', 'connect ECONNREFUSED');
  api.renderLinkState();

  const badge = doc.getElementById('state-badge');
  assert.equal(badge.textContent, 'unknown',
    'the badge must stop asserting "running" for a server that is gone');
  assert.ok(badge.classList.contains('badge-error'));
  assert.ok(!badge.classList.contains('badge-running'));

  const banner = doc.getElementById('link-banner');
  assert.ok(!banner.classList.contains('hidden'), 'the banner must be visible');
  assert.match(banner.textContent, /Cannot reach the observatory server/);
  assert.match(banner.textContent, /may be wrong/);

  const dot = doc.getElementById('connection-dot');
  assert.ok(dot.classList.contains('conn-disconnected'));
  assert.ok(!dot.classList.contains('conn-reconnecting'),
    'the dot must not keep implying a recovery is under way');

  // The SSE retry loop fires onerror on every attempt; it must not talk the
  // dot back into "reconnecting" behind the banner's back.
  const onerror = SOURCE.match(/sse\.onerror = \(\) => \{[\s\S]*?\n  \};/);
  assert.ok(onerror, 'the SSE error handler must exist');
  assert.match(onerror[0], /isLinkStale\(\) \? 'disconnected' : 'reconnecting'/);
});

// The silent case: the socket stays open but no snapshot completes. One poll
// interval plus slack is the deadline.
test('a missed poll interval counts as stale even with no error', () => {
  const { doc, api } = loadRunWatch();
  api.noteLinkOk();
  api.applySnapshot(runningSnapshot());
  assert.equal(api.isLinkStale(), false);

  // 21 s ago — past SNAPSHOT_INTERVAL_MS (15 s) + 5 s slack.
  api.poke({ lastSnapshotAt: Date.now() - 21000 });
  assert.equal(api.isLinkStale(), true);
  api.renderLinkState();
  assert.equal(doc.getElementById('state-badge').textContent, 'unknown');
  assert.match(doc.getElementById('link-banner').textContent,
    /No answer from the observatory server/);
  assert.match(doc.getElementById('link-banner').textContent,
    /state was "running"/);
});

// D4-06. `totalIntegrationSecs` is null whenever the host does not know the
// run's planned integration, which on a headless appliance is always. The old
// render turned that into "0s" and printed "24s / 0s".
test('an unknown integration denominator renders as unknown, not zero', () => {
  const { doc, api } = loadRunWatch();
  api.noteLinkOk();
  api.applySnapshot(runningSnapshot());
  assert.equal(doc.getElementById('progress-integration').textContent, '2s / --');
  assert.equal(doc.getElementById('progress-frames').textContent, '1 / 12');

  const snap = runningSnapshot();
  snap.sequencer.progress.totalIntegrationSecs = 24.0;
  api.applySnapshot(snap);
  assert.equal(doc.getElementById('progress-integration').textContent, '2s / 24s');
});

// D4-07. The card used to read `--` in every row during a live run whose
// target the same snapshot named.
test('a target with no coordinates still shows its name', () => {
  const { doc, api } = loadRunWatch();
  api.noteLinkOk();
  api.applySnapshot(runningSnapshot());
  assert.equal(doc.getElementById('target-name').textContent, 'D1 Simulated Field');
  assert.equal(doc.getElementById('target-coords').textContent, '--');
  assert.equal(doc.getElementById('target-alt').textContent, '--');
  assert.match(doc.getElementById('target-state').textContent,
    /Coordinates unavailable/);
});

// D4-08. aria-valuenow="0" announces "0 percent" — a figure the server never
// sent. An absent attribute announces an indeterminate bar, which is the truth.
test('an unknown progress percentage carries no aria-valuenow', () => {
  const { doc, api } = loadRunWatch();
  const snap = runningSnapshot();
  snap.sequencer.progress.progressPercent = null;
  api.applySnapshot(snap);
  const bar = doc.getElementById('progress-bar-aria');
  assert.equal(bar.getAttribute('aria-valuenow'), null);
  assert.equal(doc.getElementById('progress-pct').textContent, '--');

  api.applySnapshot(runningSnapshot());
  assert.equal(bar.getAttribute('aria-valuenow'), '8');
});

test('the shipped markup declares no aria-valuenow before any snapshot', () => {
  const html = fs.readFileSync(path.join(RUN_WATCH, 'index.html'), 'utf8');
  const bar = html.match(/<div class="bar"[^>]*id="progress-bar-aria"[^>]*>/);
  assert.ok(bar, 'the progressbar element must exist');
  assert.match(bar[0], /role="progressbar"/);
  assert.doesNotMatch(bar[0], /aria-valuenow/,
    'a bar that has heard nothing must not announce a value');
});

// D4-05, phone side. PHD2 answers 0.0 for every RMS while disconnected.
test('a disconnected guider reports no RMS at all', () => {
  const { doc, api } = loadRunWatch();
  api.applySnapshot(runningSnapshot());
  assert.equal(doc.getElementById('guide-state').textContent, 'disconnected');
  assert.equal(doc.getElementById('guide-ra').textContent, '--');
  assert.equal(doc.getElementById('guide-dec').textContent, '--');
  assert.equal(doc.getElementById('guide-total').textContent, '--');
  assert.equal(doc.getElementById('guide-snr').textContent, '--');

  const snap = runningSnapshot();
  snap.guiding = {
    state: 'Guiding', connected: true,
    rmsRa: 0.41, rmsDec: 0.38, rmsTotal: 0.56, snr: 22.5,
  };
  api.applySnapshot(snap);
  assert.equal(doc.getElementById('guide-ra').textContent, '0.41″');
  assert.equal(doc.getElementById('guide-total').textContent, '0.56″');
  assert.equal(doc.getElementById('guide-snr').textContent, '22.5');
});

// D4-10. `dataSource: 'unavailable'` means nothing has looked at the sky. The
// server still fills in safeToImage/alertLevel, and the badge used to render
// them as a green "clear".
test('no weather source never renders an affirmative verdict', () => {
  const { doc, api } = loadRunWatch();
  api.applySnapshot(runningSnapshot());
  const badge = doc.getElementById('weather-badge');
  assert.equal(badge.textContent, 'no sensor');
  assert.ok(!badge.classList.contains('badge-running'),
    'an unmeasured sky must not read green');
  assert.match(doc.getElementById('weather-message').textContent,
    /not being checked|No weather source configured/);

  const snap = runningSnapshot();
  snap.weather = {
    safeToImage: true, alertLevel: 'clear', message: 'Clear and dry',
    dataSource: 'hardware', lastEvaluation: null,
  };
  api.applySnapshot(snap);
  assert.equal(badge.textContent, 'clear');
  assert.ok(badge.classList.contains('badge-running'),
    'a real sensor reporting clear may read green');
});

// D4W-1. A fail-closed safety policy refuses BECAUSE nothing could be read, so
// the refusal arrives with dataSource 'unavailable' — the same payload shape as
// "no sensor". The badge answered the sensor question first and printed a
// neutral grey "no sensor"; the word "unsafe" appeared nowhere on the page
// while the rig had decided not to image.
test('a fail-closed refusal reads as unsafe, not as an absence', () => {
  const { doc, api } = loadRunWatch();
  const snap = runningSnapshot();
  snap.weather = {
    safeToImage: false, alertLevel: 'clear', dataSource: 'unavailable',
    message: 'No weather data sources available', lastEvaluation: null,
  };
  api.applySnapshot(snap);

  const badge = doc.getElementById('weather-badge');
  assert.equal(badge.textContent, 'unsafe');
  assert.ok(badge.classList.contains('badge-error'),
    'a refusal must not wear the idle class');
  assert.ok(!badge.classList.contains('badge-idle'));
  assert.equal(doc.getElementById('weather-message').textContent,
    'No weather data sources available');
});

test('a refusal from a real sensor keeps the level it was given', () => {
  const { doc, api } = loadRunWatch();
  const badge = doc.getElementById('weather-badge');

  const measured = runningSnapshot();
  measured.weather = {
    safeToImage: false, alertLevel: 'unsafe', dataSource: 'hardware',
    message: 'Rain', lastEvaluation: null,
  };
  api.applySnapshot(measured);
  assert.equal(badge.textContent, 'unsafe');
  assert.ok(badge.classList.contains('badge-error'));

  const escalated = runningSnapshot();
  escalated.weather = {
    safeToImage: false, alertLevel: 'critical', dataSource: 'hardware',
    message: 'Hail', lastEvaluation: null,
  };
  api.applySnapshot(escalated);
  assert.equal(badge.textContent, 'unsafe · critical');
  assert.ok(badge.classList.contains('badge-error'));

  // A warning the rig is still imaging through is not a refusal.
  const warned = runningSnapshot();
  warned.weather = {
    safeToImage: true, alertLevel: 'warning', dataSource: 'hardware',
    message: 'Cloud approaching', lastEvaluation: null,
  };
  api.applySnapshot(warned);
  assert.equal(badge.textContent, 'warning');
  assert.ok(badge.classList.contains('badge-running'));
});

// D4-09. `POST /api/sequencer/stop` answers 200 with wasRunning:false and
// "No sequence was running; nothing to stop." when there is nothing to stop.
test('a control reports the server refusal instead of a success toast', async () => {
  const answers = {
    body: {
      commandId: 'x', status: 'stopped', preserveCheckpoint: true,
      wasRunning: false,
      message: 'No sequence was running; nothing to stop.',
    },
  };
  const { doc, api } = loadRunWatch({
    fetch: async () => ({
      ok: true, status: 200, statusText: 'OK',
      headers: new Headers(),
      json: async () => answers.body,
    }),
  });
  await api.sequencerAction('/api/sequencer/stop', 'Stop');
  const toasts = doc.getElementById('toast-region').children.map((c) => ({
    text: c.textContent, cls: c.className,
  }));
  assert.equal(toasts.length, 1);
  assert.equal(toasts[0].text, 'No sequence was running; nothing to stop.');
  assert.ok(toasts[0].cls.includes('toast-warning'),
    'a refusal must not be styled as a success');

  answers.body = { commandId: 'y', status: 'stopped', wasRunning: true };
  await api.sequencerAction('/api/sequencer/stop', 'Stop');
  const after = doc.getElementById('toast-region').children;
  assert.equal(after[after.length - 1].textContent, 'Stop accepted');
});

// D4-03. The limiter's JSON body must never be what the operator reads, and
// the page must honour the server's own retry window rather than re-firing.
test('a 429 is honoured as a retry window, not printed', async () => {
  const body = {
    code: 'rate_limited', error: 'Rate limit exceeded',
    message: 'Token token-6e609b0e exceeded read bucket',
    bucket: 'read', maxRequests: 60, retryAfterSecs: 3, retryAfterSeconds: 3,
    requestId: 'abc',
  };
  let calls = 0;
  const { doc, api } = loadRunWatch({
    fetch: async () => {
      calls += 1;
      return {
        ok: false, status: 429, statusText: 'Too Many Requests',
        headers: new Headers({ 'retry-after': '3' }),
        clone() { return this; },
        json: async () => body,
        text: async () => JSON.stringify(body),
      };
    },
  });

  await assert.rejects(
    () => api.apiFetch('/api/run-watch/snapshot'),
    (e) => e.kind === 'rate_limited' && e.detail.retryAfterSecs === 3,
  );
  assert.equal(calls, 1);

  // Inside the window the gate refuses locally: no second request is sent.
  await assert.rejects(
    () => api.apiFetch('/api/run-watch/snapshot'),
    (e) => e.kind === 'rate_limited',
  );
  assert.equal(calls, 1, 'the page must not re-fire inside the retry window');

  api.noteLinkOk();
  api.renderLinkState();
  const banner = doc.getElementById('link-banner');
  assert.ok(!banner.classList.contains('hidden'));
  assert.match(banner.textContent, /rate-limiting this device/);
  assert.doesNotMatch(banner.textContent, /rate_limited|maxRequests|requestId/,
    'the limiter body must never reach the screen');
});

// A page that has just opened is loading, not out of contact — but only for
// one poll interval, and only while nothing has actually failed.
test('a page still waiting for its first snapshot is not yet stale', () => {
  const { doc, api } = loadRunWatch();
  api.poke({ lastSnapshotAt: 0, sessionStartedAt: Date.now(), linkFailure: null });
  assert.equal(api.isLinkStale(), false);
  api.renderLinkState();
  assert.ok(doc.getElementById('link-banner').classList.contains('hidden'));

  api.poke({ sessionStartedAt: Date.now() - 21000 });
  assert.equal(api.isLinkStale(), true);
  api.renderLinkState();
  assert.match(doc.getElementById('link-banner').textContent,
    /No update has arrived since this page opened/);
});

test('a first fetch that fails outright is stale immediately', () => {
  const { api } = loadRunWatch();
  api.poke({ lastSnapshotAt: 0, sessionStartedAt: Date.now() });
  api.noteLinkFailure('unreachable', 'connect ECONNREFUSED');
  assert.equal(api.isLinkStale(), true,
    'a refused connection needs no grace period');
});

test('retryAfterSecsFrom prefers the body, then the header, then one second',
  async () => {
    const { api } = loadRunWatch();
    const res = (json, header) => ({
      clone() {
        return { json: async () => { if (json == null) throw new Error('no body'); return json; } };
      },
      headers: new Headers(header ? { 'retry-after': String(header) } : {}),
    });
    assert.equal(await api.retryAfterSecsFrom(res({ retryAfterSecs: 7 }, 2)), 7);
    assert.equal(await api.retryAfterSecsFrom(res({ retryAfterSeconds: 4 })), 4);
    assert.equal(await api.retryAfterSecsFrom(res(null, 9)), 9);
    assert.equal(await api.retryAfterSecsFrom(res(null)), 1);
    // A hostile window cannot park the page for hours.
    assert.equal(await api.retryAfterSecsFrom(res({ retryAfterSecs: 100000 })), 300);
  });

// ---------------------------------------------------------------------------
// D4W-3 — a cancelled night is not an idle rig
// ---------------------------------------------------------------------------

/**
 * What GET /api/run-watch/snapshot actually answers six seconds after
 * POST /api/sequencer/stop, measured against the release bundle: the sequencer
 * status says `cancelled` while the executor's own progress block has already
 * fallen back to `idle` — `SequenceExecutionState` has no cancelled member.
 */
function cancelledSnapshot(progressExtra) {
  return runningSnapshot({
    sequencer: {
      state: 'cancelled',
      currentNodeName: null,
      progress: Object.assign({
        state: 'idle',
        currentTarget: 'D1 Simulated Field',
        currentNodeName: null,
        totalExposures: 12,
        completedExposures: 1,
        progressPercent: 0.083,
      }, progressExtra || {}),
    },
  });
}

test('a cancelled run is not reported as an idle rig', () => {
  const { doc, api } = loadRunWatch();
  api.noteLinkOk();
  api.applySnapshot(cancelledSnapshot());
  assert.equal(doc.getElementById('state-badge').textContent, 'cancelled',
    'the badge must read the field the snapshot actually carries');
  assert.equal(doc.getElementById('seq-name').textContent, 'D1 Simulated Field');
});

test('a cancelled run with nothing left to name still says cancelled', () => {
  const { doc, api } = loadRunWatch();
  api.noteLinkOk();
  api.applySnapshot(cancelledSnapshot({ currentTarget: null }));
  assert.equal(doc.getElementById('state-badge').textContent, 'cancelled');
  assert.equal(doc.getElementById('seq-name').textContent, 'Cancelled',
    'an unnamed cancelled run must not read "Idle"');
});

test('a live run still reports the executor state, not the wire state', () => {
  const { doc, api } = loadRunWatch();
  api.noteLinkOk();
  // The executor is mid-run and the sequencer status lags a state behind: the
  // block describing the live run wins.
  api.applySnapshot(runningSnapshot({
    sequencer: {
      state: 'idle',
      currentNodeName: 'Exposure L',
      progress: { state: 'running', currentTarget: 'D1 Simulated Field' },
    },
  }));
  assert.equal(doc.getElementById('state-badge').textContent, 'running');
});

test('a genuinely idle rig still reads idle', () => {
  const { doc, api } = loadRunWatch();
  api.noteLinkOk();
  api.applySnapshot(runningSnapshot({
    sequencer: { state: 'idle', currentNodeName: null, progress: { state: 'idle' } },
  }));
  assert.equal(doc.getElementById('state-badge').textContent, 'idle');
  assert.equal(doc.getElementById('seq-name').textContent, 'Idle');
});

test('a snapshot that names no state at all is unknown, never idle', () => {
  const { doc, api } = loadRunWatch();
  api.noteLinkOk();
  api.applySnapshot(runningSnapshot({ sequencer: { progress: {} } }));
  assert.equal(doc.getElementById('state-badge').textContent, 'unknown');
  assert.ok(doc.getElementById('state-badge').className.includes('badge-error'));
});

// D4-1. Measured live: `POST /api/sequencer/pause` at a cancelled run answered
// 200 {"status":"paused"} and the next snapshot carried
// `sequencer.state: cancelled` beside `progress.state: paused`; a resume made
// it `progress.state: running`. The executor block outranked the wire state
// unconditionally, so this page showed a green "running" badge — across
// reloads, and without self-healing — for a run that had ended 40 s earlier.
// The server now refuses those commands; this is the second lock, so neither
// half can lie on its own.
test('a run the wire says has ended outranks a live-looking executor block',
  () => {
    const { doc, api } = loadRunWatch();
    api.noteLinkOk();
    for (const executorState of ['paused', 'running', 'recovering']) {
      api.applySnapshot(cancelledSnapshot({ state: executorState }));
      const badge = doc.getElementById('state-badge');
      assert.equal(badge.textContent, 'cancelled',
        'a cancelled run cannot be repainted ' + executorState);
      assert.ok(badge.className.includes('badge-idle'),
        'and it must not be styled as a live run');
    }
    // Every terminal word the wire can carry, not just the one that was
    // measured: `SequenceExecutionState` has a member for none of them.
    for (const wireState of ['completed', 'failed', 'stopped', 'error']) {
      api.applySnapshot(runningSnapshot({
        sequencer: {
          state: wireState,
          currentNodeName: null,
          progress: { state: 'running', currentTarget: 'D1 Simulated Field' },
        },
      }));
      assert.equal(doc.getElementById('state-badge').textContent, wireState);
    }
  });

// ---------------------------------------------------------------------------
// D4-2 — the controls, and what they claim
// ---------------------------------------------------------------------------

/** The four gated controls' disabled flags, as the operator would find them. */
function controlState(doc) {
  const read = (id) => Boolean(doc.getElementById(id).disabled);
  return {
    pause: read('btn-pause'), resume: read('btn-resume'),
    skip: read('btn-skip'), stop: read('btn-stop'),
    reset: read('btn-reset'),
  };
}

// Measured on a fresh-boot rig with no run ever started: every control
// rendered enabled (disabled === false for all five), Pause drew
// "Pause accepted", Skip drew "Skip accepted", Resume drew "Resume accepted",
// and GET /api/sequencer/status still read "idle" afterwards. The desktop
// dashboard gated the same three on the executor state; this surface did not.
test('the run controls open only for the state the rig reports', () => {
  const { doc, api } = loadRunWatch();
  api.noteLinkOk();

  api.applySnapshot(runningSnapshot());
  assert.deepEqual(controlState(doc), {
    pause: false, resume: true, skip: false, stop: false, reset: false,
  }, 'a running rig offers pause, skip and stop — not resume');

  api.applySnapshot(runningSnapshot({
    sequencer: {
      state: 'paused', currentNodeName: 'Exposure L',
      progress: { state: 'paused', currentTarget: 'D1 Simulated Field' },
    },
  }));
  assert.deepEqual(controlState(doc), {
    pause: true, resume: false, skip: false, stop: false, reset: false,
  }, 'a paused rig offers resume, skip and stop — not pause');

  api.applySnapshot(cancelledSnapshot());
  assert.deepEqual(controlState(doc), {
    pause: true, resume: true, skip: true, stop: true, reset: false,
  }, 'a run that has ended offers nothing but reset');

  api.applySnapshot(runningSnapshot({
    sequencer: { state: 'idle', currentNodeName: null, progress: { state: 'idle' } },
  }));
  assert.deepEqual(controlState(doc), {
    pause: true, resume: true, skip: true, stop: true, reset: false,
  }, 'an idle rig offers nothing but reset');
});

test('a link nobody can vouch for offers no run controls', () => {
  const { doc, api } = loadRunWatch();
  api.noteLinkOk();
  api.applySnapshot(runningSnapshot());
  assert.equal(controlState(doc).pause, false);
  api.noteLinkFailure('unreachable', 'connection refused');
  api.renderLinkState();
  assert.deepEqual(controlState(doc), {
    pause: true, resume: true, skip: true, stop: true, reset: false,
  }, 'a control whose precondition nobody can confirm is not offerable');
});

test('the shipped markup offers no run control before the first snapshot', () => {
  const html = fs.readFileSync(path.join(RUN_WATCH, 'index.html'), 'utf8');
  for (const id of ['btn-pause', 'btn-resume', 'btn-skip', 'btn-stop']) {
    const tag = html.match(new RegExp('<button id="' + id + '"[^>]*>'));
    assert.ok(tag, id + ' must exist in the markup');
    assert.match(tag[0], /\bdisabled\b/,
      id + ' must not look live before the page has heard anything');
  }
  const reset = html.match(/<button id="btn-reset"[^>]*>/);
  assert.ok(reset && !/\bdisabled\b/.test(reset[0]),
    'Reset is the way out of a wedged executor and stays available');
});

/** The declarations of one CSS rule, normalised for comparison. */
function ruleBody(css, selector) {
  const at = css.indexOf(selector + ' {');
  assert.notEqual(at, -1, selector + ' must exist in the stylesheet');
  const body = css.slice(at + selector.length + 2, css.indexOf('}', at));
  return body.split(';').map((d) => d.trim()).filter(Boolean).sort();
}

// D4-W1. `updateRunControls` set `disabled` truthfully in every state, but the
// stylesheet carried no `.pb-btn:disabled` rule, so the flag painted nothing:
// with the daemon killed under a live run the bar read `disabled: true` on all
// four controls while rendering opacity 1, cursor pointer and full saturation
// — computed-style byte-identical to the same bar seconds earlier with the run
// live. A dead Stop looked like a live one and swallowed the tap in silence.
// The DOM shim carries no cascade, so the stylesheet is where this is pinned.
test('a run control the state does not admit is painted dead', () => {
  const css = fs.readFileSync(path.join(RUN_WATCH, 'css', 'style.css'), 'utf8');
  const playback = ruleBody(css, '.pb-btn:disabled');
  assert.deepEqual(playback, ruleBody(css, '.btn:disabled'),
    'the phone bar and the page buttons owe the operator one visual language '
    + 'for a control that is off');
  assert.ok(playback.includes('opacity: var(--opacity-disabled)'),
    'a control that cannot fire must not paint at full strength');
  assert.ok(playback.includes('cursor: not-allowed'),
    'a pointer over a dead control promises a tap that goes nowhere');
});

// The server answers 409 `sequencer_not_running` with the same `wasRunning`
// verdict Stop's 200 no-op carries. "Nothing to pause" is a fact about the
// rig, not a fault in the request, so it earns the warning toast Stop's no-op
// earns rather than a red failure.
test('a refused control reports the refusal in the server\'s own words',
  async () => {
    const { doc, api } = loadRunWatch({
      fetch: async () => ({
        ok: false, status: 409, statusText: 'Conflict',
        headers: new Headers(),
        json: async () => ({
          error: 'sequencer_not_running',
          message: 'No sequence is running; nothing to pause.',
          wasRunning: false,
          state: 'cancelled',
        }),
      }),
    });
    await api.sequencerAction('/api/sequencer/pause', 'Pause');
    const toasts = doc.getElementById('toast-region').children;
    assert.equal(toasts.length, 1);
    assert.equal(toasts[0].textContent,
      'No sequence is running; nothing to pause.');
    assert.ok(toasts[0].className.includes('toast-warning'),
      'a refusal is neither a success nor a fault');
    assert.ok(!toasts[0].className.includes('toast-success'));
  });

test('a control that genuinely failed still reads as a failure', async () => {
  const { doc, api } = loadRunWatch({
    fetch: async () => ({
      ok: false, status: 503, statusText: 'Service Unavailable',
      headers: new Headers(),
      json: async () => ({
        error: 'sequencer_state_unreadable',
        message: 'Cannot pause: the sequencer state could not be read, so '
          + 'this host cannot tell whether a run is in flight.',
      }),
    }),
  });
  await api.sequencerAction('/api/sequencer/pause', 'Pause');
  const toasts = doc.getElementById('toast-region').children;
  assert.equal(toasts.length, 1);
  assert.match(toasts[0].textContent, /^Pause failed: Cannot pause/);
  assert.ok(toasts[0].className.includes('toast-error'));
});

// ---------------------------------------------------------------------------
// D4-5 — a figure whose source is gone
// ---------------------------------------------------------------------------

// The null-progress path has been honest since D4W-03; the read-FAILED path
// was not. Measured after a SIGTERM at wire progress 0.05: the badge flipped
// to "unknown" and the banner said every value below might be wrong, while
// #progress-pct read "5%", the bar stayed 5% wide and aria-valuenow kept
// announcing 5 at +10 s, +25 s and +45 s. The dashboard's paintRunUnknown
// settled the stance for the same loss — "a figure whose source is gone is not
// a smaller truth than a state whose source is gone" — and this is that stance
// applied here.
test('a percentage nobody can vouch for is dropped with the state', () => {
  const { doc, api } = loadRunWatch();
  const bar = doc.getElementById('progress-bar-aria');
  api.noteLinkOk();
  api.applySnapshot(runningSnapshot());
  assert.equal(doc.getElementById('progress-pct').textContent, '8%');
  assert.equal(bar.getAttribute('aria-valuenow'), '8');

  api.noteLinkFailure('unreachable', 'connection refused');
  api.renderLinkState();

  assert.equal(doc.getElementById('state-badge').textContent, 'unknown');
  assert.equal(doc.getElementById('progress-pct').textContent, '--',
    'the figure cannot outlive the state it was measured with');
  assert.equal(doc.getElementById('progress-bar').style.width, '0%');
  assert.equal(bar.getAttribute('aria-valuenow'), null,
    'and it must stop being announced');
  assert.ok(bar.classList.contains('unknown'),
    'the graphic says what the text says');
});

test('a healthy snapshot after an outage takes the figure back', () => {
  const { doc, api } = loadRunWatch();
  const bar = doc.getElementById('progress-bar-aria');
  api.noteLinkOk();
  api.applySnapshot(runningSnapshot());
  api.noteLinkFailure('unreachable', 'connection refused');
  api.renderLinkState();
  assert.equal(doc.getElementById('progress-pct').textContent, '--');

  api.noteLinkOk();
  api.applySnapshot(runningSnapshot());
  assert.equal(doc.getElementById('progress-pct').textContent, '8%');
  assert.equal(bar.getAttribute('aria-valuenow'), '8');
  assert.ok(!bar.classList.contains('unknown'));
});

// ---------------------------------------------------------------------------
// D4W-5 — before the first snapshot, the page is connecting
// ---------------------------------------------------------------------------

test('the shipped markup asserts no rig state before the first snapshot', () => {
  const html = fs.readFileSync(path.join(RUN_WATCH, 'index.html'), 'utf8');
  const badge = html.match(/<span id="state-badge"[^>]*>([^<]*)</);
  assert.ok(badge, 'the state badge must exist in the markup');
  assert.equal(badge[1].trim(), 'connecting',
    'a page that has heard nothing must not claim the rig is idle');
  const name = html.match(/<span id="seq-name"[^>]*>([^<]*)</);
  assert.ok(name, 'the sequence-name slot must exist in the markup');
  assert.match(name[1].trim(), /^Connecting/);
});

// D4W-03. `progressPercent: null` is the server's own degraded payload
// (`_unavailableProgressJson` in run_watch_handlers.dart — every measured field
// null, `state: 'unknown'`, a message naming the failed read). The text and the
// aria attribute were already honest about it. The BAR was not: it painted
// `width: 0%`, which is byte-identical to a fresh boot that has genuinely done
// nothing — verified side by side on the running bundle, same computed width,
// same classes, same background.
test('an unknown progress percentage does not draw as a real zero', () => {
  const { doc, api } = loadRunWatch();
  const bar = doc.getElementById('progress-bar-aria');

  const snap = runningSnapshot();
  snap.sequencer.progress.progressPercent = null;
  api.applySnapshot(snap);
  assert.equal(doc.getElementById('progress-pct').textContent, '--');
  assert.equal(bar.getAttribute('aria-valuenow'), null);
  assert.ok(bar.classList.contains('unknown'),
    'the graphic must say what the text says');

  // A genuine 0% — a run that has started and completed nothing — keeps the
  // ordinary empty track, because that IS a figure the server sent.
  const zero = runningSnapshot();
  zero.sequencer.progress.progressPercent = 0;
  api.applySnapshot(zero);
  assert.equal(doc.getElementById('progress-pct').textContent, '0%');
  assert.equal(bar.getAttribute('aria-valuenow'), '0');
  assert.ok(!bar.classList.contains('unknown'));
});

test('the unknown track has a rendering of its own', () => {
  const css = fs.readFileSync(path.join(RUN_WATCH, 'css', 'style.css'), 'utf8');
  assert.match(css, /\.bar\.unknown\s*\{[\s\S]*?background-image/,
    'without a paint rule the class distinguishes nothing');
});

// D4W-04. A token the desktop revoked dropped this page back to the first-run
// pair screen with nothing said: `#pair-status` empty, no toast, and a screen
// byte-identical to the one a browser that had never paired gets (the two
// screenshots hashed the same). The thrown 'Pairing is no longer accepted'
// reached no caller that renders it.
test('a rejected pairing says what happened and what to do next', async () => {
  const { doc, api } = loadRunWatch({
    fetch: async () => ({
      ok: false, status: 403, statusText: 'Forbidden',
      headers: new Headers(),
      json: async () => ({ error: 'forbidden' }),
      text: async () => 'forbidden',
    }),
  });
  // The scenario is a REVOKED pairing, so the token has to be one the desktop
  // once accepted — which is what the pairing exchange hands back.
  api.setToken('a-token-the-desktop-revoked', true);

  await assert.rejects(
    () => api.apiFetch('/api/run-watch/snapshot'),
    (e) => e.kind === 'auth_required',
  );

  const status = doc.getElementById('pair-status');
  assert.match(status.textContent, /no longer accepted/);
  assert.match(status.textContent, /Pair again/,
    'a dead end is not an explanation — say the next move');
  assert.ok(status.className.includes('error'));
  assert.ok(!doc.getElementById('pair-screen').classList.contains('hidden'));
  assert.ok(doc.getElementById('main-screen').classList.contains('hidden'));
});

// D4-05. A device that has never paired, whose operator mistyped a token into
// the manual box, was told its pairing "is no longer accepted — the desktop
// rejected it, which happens when the pairing was revoked there or the profile
// it belonged to was replaced" — measured verbatim against the release bundle
// on a browser whose localStorage had just been cleared. That is a diagnosis
// of an event that never happened, and it sends the operator to fetch a fresh
// code for a pairing that never existed.
test('a token that was never accepted is not called a revoked pairing', async () => {
  const { doc, api } = loadRunWatch({
    fetch: async () => ({
      ok: false, status: 403, statusText: 'Forbidden',
      headers: new Headers(),
      json: async () => ({ error: 'forbidden' }),
      text: async () => 'forbidden',
    }),
  });
  api.setToken('typed-by-hand-never-seen-by-the-desktop', false);
  assert.equal(api.tokenWasEverAccepted(), false);

  await assert.rejects(
    () => api.apiFetch('/api/run-watch/snapshot'),
    (e) => e.kind === 'auth_required',
  );

  const status = doc.getElementById('pair-status');
  assert.doesNotMatch(status.textContent, /no longer accepted/,
    'nothing was withdrawn from a device that was never granted anything');
  assert.doesNotMatch(status.textContent, /revoked/);
  assert.match(status.textContent, /was not accepted/);
  assert.match(status.textContent, /rig/,
    'say where the right credential is — the rig, which may have no GUI');
  assert.doesNotMatch(status.textContent, /Remote Access/,
    'a headless rig has no Remote Access screen to check against');
  assert.ok(status.className.includes('error'));
});

// The same typed token, once the desktop has honoured it, IS a credential that
// can later be revoked — so a refusal after a working session gets the
// revocation sentence. The distinction is provenance plus history, not whether
// a token happens to exist.
test('a typed token the desktop accepted earns the revoked sentence later', async () => {
  let refuse = false;
  const { doc, api } = loadRunWatch({
    fetch: async () => (refuse
      ? {
        ok: false, status: 401, statusText: 'Unauthorized',
        headers: new Headers(),
        json: async () => ({ error: 'unauthorized' }),
        text: async () => 'unauthorized',
      }
      : {
        ok: true, status: 200, headers: new Headers(),
        json: async () => ({ sequencer: {} }),
        text: async () => '{}',
      }),
  });
  api.setToken('typed-but-it-worked', false);

  await api.apiFetch('/api/run-watch/snapshot');
  assert.equal(api.tokenWasEverAccepted(), true,
    'a 2xx carrying the credential is the desktop honouring it');

  refuse = true;
  await assert.rejects(
    () => api.apiFetch('/api/run-watch/snapshot'),
    (e) => e.kind === 'auth_required',
  );
  assert.match(doc.getElementById('pair-status').textContent, /no longer accepted/);
});

test('a first-run pair screen accuses nothing', () => {
  const { doc, api } = loadRunWatch();
  doc.getElementById('pair-status').textContent = 'stale text';
  api.showPairScreen();
  assert.equal(doc.getElementById('pair-status').textContent, '',
    'a browser that never paired has had nothing rejected');
  assert.equal(doc.getElementById('pair-status').className, 'pair-status');
});

// ---------------------------------------------------------------------------
// D4-02 — the settings sheet may not offer an ability this origin lacks
//
// Measured in the running bundle over the LAN address a phone actually uses,
// http://192.168.1.20:8212/run-watch: isSecureContext false, 'wakeLock' in
// navigator false, the service worker never registered, Notification.permission
// already "denied". Both toggles were ticked, localStorage read
// {"wakeLock":true,"push":true}, no toast fired, and the word HTTPS appeared
// nowhere on the surface. The screen slept and no notification could ever be
// delivered.
// ---------------------------------------------------------------------------

/** The page as served over plain HTTP to a phone on the observatory LAN. */
function insecureOrigin(opts) {
  const { doc, api } = loadRunWatch({
    window: {
      isSecureContext: false,
      // Chrome exposes the interface on an insecure origin and pins the
      // permission at "denied", which is exactly why testing for the
      // interface alone was not enough.
      Notification: { permission: 'denied', requestPermission: async () => 'denied' },
    },
    // Screen Wake Lock is [SecureContext], so the property is simply absent.
    navigator: {},
  });
  if (opts) {
    doc.getElementById('opt-wake-lock').checked = true;
    doc.getElementById('opt-push').checked = true;
  }
  return { doc, api };
}

test('an insecure origin says why the wake lock cannot work', () => {
  const { doc, api } = insecureOrigin();
  api.refreshCapabilityToggles();

  const input = doc.getElementById('opt-wake-lock');
  const note = doc.getElementById('opt-wake-lock-note');
  assert.equal(input.disabled, true, 'an inert control must not look usable');
  assert.equal(input.checked, false);
  assert.ok(!note.classList.contains('hidden'), 'the reason must be on screen');
  assert.match(note.textContent, /HTTPS/,
    'the operator has to be told what the requirement is');
  assert.ok(doc.getElementById('opt-wake-lock-row').classList
    .contains('unavailable'));
});

test('an insecure origin says why notifications cannot be delivered', () => {
  const { doc, api } = insecureOrigin();
  api.refreshCapabilityToggles();

  const input = doc.getElementById('opt-push');
  const note = doc.getElementById('opt-push-note');
  assert.equal(input.disabled, true);
  assert.equal(input.checked, false);
  assert.ok(!note.classList.contains('hidden'));
  assert.match(note.textContent, /HTTPS/);
});

test('a stored opt-in for a capability this origin lacks is dropped', () => {
  const { api } = insecureOrigin();
  // A device paired over a secure origin and later opened on the LAN address
  // arrives carrying both opt-ins.
  api.pokeOpts({ wakeLock: true, push: true });
  api.refreshCapabilityToggles();
  assert.deepEqual(api.readOpts(), { wakeLock: false, push: false },
    'nothing on this device may go on claiming an ability it has lost');
});

test('a wake-lock request that cannot be made is refused out loud', async () => {
  const { doc, api } = insecureOrigin();
  api.pokeOpts({ wakeLock: true });
  await api.applyWakeLockOption();
  const toasts = doc.getElementById('toast-region').children
    .map((c) => c.textContent);
  assert.equal(toasts.length, 1, 'silence is what let the toggle stay ticked');
  assert.match(toasts[0], /unavailable/);
  assert.match(toasts[0], /HTTPS/);
  assert.equal(api.readOpts().wakeLock, false);
});

test('a push opt-in that cannot be honoured is refused out loud', async () => {
  const { doc, api } = insecureOrigin();
  api.pokeOpts({ push: true });
  await api.applyPushOption();
  const toasts = doc.getElementById('toast-region').children
    .map((c) => c.textContent);
  assert.equal(toasts.length, 1);
  assert.match(toasts[0], /unavailable/);
  assert.equal(api.readOpts().push, false);
});

test('a secure origin leaves both toggles alone', () => {
  const { doc, api } = loadRunWatch({
    window: {
      isSecureContext: true,
      Notification: { permission: 'default', requestPermission: async () => 'granted' },
    },
    navigator: { wakeLock: { request: async () => ({ addEventListener() {} }) } },
  });
  // The shipped markup starts both notes hidden; the shim starts bare.
  for (const id of ['opt-wake-lock-note', 'opt-push-note']) {
    doc.getElementById(id).className = 'opt-note hidden';
  }
  api.refreshCapabilityToggles();
  for (const id of ['opt-wake-lock', 'opt-push']) {
    assert.notEqual(doc.getElementById(id).disabled, true,
      id + ' works here and must stay offered');
  }
  for (const id of ['opt-wake-lock-note', 'opt-push-note']) {
    assert.ok(doc.getElementById(id).classList.contains('hidden'),
      id + ' must not warn about a capability that is present');
  }
});

test('a browser that CLAIMS the capability but lacks the API is still refused', () => {
  // A user-agent string is a claim about the browser; the presence of the
  // interface is a fact about this origin. A UA that names a Chrome build
  // which does ship Screen Wake Lock, served from an origin where the
  // interface is absent, must be judged on the fact.
  const { doc, api } = loadRunWatch({
    window: { isSecureContext: false },
    navigator: {
      userAgent: 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        + '(KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36',
    },
  });
  api.refreshCapabilityToggles();
  assert.equal(doc.getElementById('opt-wake-lock').disabled, true);
  assert.match(doc.getElementById('opt-wake-lock-note').textContent, /HTTPS/);
});

/** Every word the shim's tree renders under `el`, in order. */
function textOf(el) {
  if (!el) return '';
  const own = el.textContent || '';
  const kids = el.children.map(textOf).join(' ');
  return (own + ' ' + kids).trim();
}

// D4W-3. With the run stalled on a failing meridian flip, the wire carried the
// reason in `sequencer.message` AND `progress.message` while the page showed
// "RUNNING / 33% / 1 of 3" and nothing else: a DOM grep for "meridian" found
// only the static "TIME TO MERIDIAN" label. The desktop dashboard's Sequencer
// panel has always rendered the same field, so the two clients disagreed about
// whether the operator gets told.
test('the executor\'s own message about a live run reaches the page', () => {
  const { doc, api } = loadRunWatch();
  const snap = runningSnapshot();
  snap.sequencer.message =
    'Meridian flip is overdue by 415 min and has not fired (hour angle '
    + '+7.00h, threshold 5 min past meridian) - proceeding with the next 4s '
    + 'exposure instead of waiting for it.';
  snap.sequencer.progress.message =
    'MeridianFlip: attempt 3/4 failed, retrying in 120s';
  api.applySnapshot(snap);

  const slot = doc.getElementById('seq-message');
  assert.ok(!slot.classList.contains('hidden'),
    'a run with something to say must show it');
  assert.match(slot.textContent, /Meridian flip is overdue by 415 min/);
  assert.match(slot.textContent, /attempt 3\/4 failed, retrying in 120s/);
});

test('a message already read in the header is not repeated underneath it', () => {
  const { doc, api } = loadRunWatch();
  const snap = runningSnapshot();
  // `currentTarget` wins the header; an identical message adds nothing.
  snap.sequencer.message = 'D1 Simulated Field';
  snap.sequencer.progress.message = 'Exposure: Frame 5/40 (4.0s) (12%)';
  api.applySnapshot(snap);

  const slot = doc.getElementById('seq-message');
  assert.equal(slot.textContent, 'Exposure: Frame 5/40 (4.0s) (12%)');
});

test('a run that says nothing raises no message surface', () => {
  const { doc, api } = loadRunWatch();
  api.applySnapshot(runningSnapshot());
  assert.ok(doc.getElementById('seq-message').classList.contains('hidden'),
    'an empty message must not paint an empty box');
});

// D4W-4. `exposureAdjusted` is an ordinary event of an adaptive-exposure night,
// and the mapper had no case for it, so the feed printed
// "SequencerEvent.exposureAdjusted(nodeId: exp_r, adaptedSecs: 2.0, …)" — Dart
// source text — on the operator's phone during routine imaging.
test('an event this build cannot read names itself instead of printing source', () => {
  const { doc, api } = loadRunWatch();
  api.applySnapshot(runningSnapshot({
    recentEvents: [{
      timestamp: Date.now(),
      severity: 'info',
      eventType: 'UnknownSequencerEvent',
      data: {
        variant: 'ExposureAdjusted',
        message: 'This build has no reading for the ExposureAdjusted '
          + 'sequencer event, so only its name is reported.',
      },
    }],
  }));

  const feed = textOf(doc.getElementById('event-feed'));
  assert.match(feed, /ExposureAdjusted/, 'the event is named');
  assert.match(feed, /no reading for the ExposureAdjusted sequencer event/);
  assert.ok(!/UnknownSequencerEvent/.test(feed),
    'the row is titled by the variant, not by the fallback bucket: ' + feed);
});

test('a stringified event object is never rendered, whoever sends one', () => {
  const { doc, api } = loadRunWatch();
  api.applySnapshot(runningSnapshot({
    recentEvents: [{
      timestamp: Date.now(),
      severity: 'info',
      eventType: 'UnknownSequencerEvent',
      // `event` first, the way the mapper used to send it and the way the
      // generic field walk would find it.
      data: {
        event: 'SequencerEvent.exposureAdjusted(nodeId: exp_r, adaptedSecs: '
          + '2.0, nominalSecs: 2.0, skyBrightnessMag: null, filter: R, '
          + 'reason: disabled)',
        variant: 'ExposureAdjusted',
        message: 'This build has no reading for the ExposureAdjusted '
          + 'sequencer event, so only its name is reported.',
      },
    }],
  }));

  const feed = textOf(doc.getElementById('event-feed'));
  assert.ok(!/SequencerEvent\./.test(feed),
    'source text must not reach the operator: ' + feed);
  assert.ok(!/nodeId:/.test(feed), feed);
});

// The host has an unread bucket per event family, and only the sequencer one
// has been taught to name its variants — the other five still hand over
// `<Family>Event.someVariant(...)` in `data.event`. Whichever bucket a row
// arrives in, the page must not print that object at the operator.
test('an unread event from any family renders no stringified object', () => {
  const { doc, api } = loadRunWatch();
  api.applySnapshot(runningSnapshot({
    recentEvents: [{
      timestamp: Date.now(),
      severity: 'warning',
      eventType: 'UnknownImagingEvent',
      data: {
        event: 'ImagingEvent.coolerRamp(deviceId: sim_camera_1, '
          + 'targetC: -10.0, currentC: 3.5)',
      },
    }],
  }));

  const feed = textOf(doc.getElementById('event-feed'));
  assert.match(feed, /Unknown ?ImagingEvent/,
    'the row still says which family the event came from: ' + feed);
  assert.ok(!/ImagingEvent\./.test(feed),
    'source text must not reach the operator: ' + feed);
  assert.ok(!/deviceId:/.test(feed), feed);
});

// ---------------------------------------------------------------------------
// D4WEB-01 / D4WEB-02 — what the page may call a healthy link
//
// Both defects share one root: the exchange was declared successful on the
// status code, before anything had been learned from the body. Measured
// against the release bundle with the snapshot answers supplied by CDP:
//
//   * 200 with the body `null`, for 51 s past a 20 s staleness threshold, with
//     the wire advancing 30% -> 90%: badge "running", "30%", "9 / 30", the
//     connection dot in conn-connected and no banner. The SAME page answers a
//     dead daemon with badge "unknown", "--" and "Cannot reach the observatory
//     server…", so the honesty machinery existed and this path went round it.
//
//   * a payload whose activeTarget coordinates were strings: the page printed
//     `NaNh NaNm NaNs · -NaN° NaN′ NaN″`, then `"not-a-number".toFixed(1)`
//     threw, and every field below the target block — 25% instead of 75%,
//     5 / 20 instead of 15 / 20, filter L instead of R, SNR 30.0 instead of
//     12.0 — kept the PREVIOUS payload with nothing said anywhere.
// ---------------------------------------------------------------------------

/** A fetch stub whose snapshot answers are read off `state.body`. */
function snapshotServer(state) {
  return {
    fetch: async () => ({
      ok: true,
      status: 200,
      statusText: 'OK',
      headers: new Headers(),
      json: async () => {
        if (state.throws) throw new SyntaxError('Unexpected token < in JSON');
        return state.body;
      },
    }),
  };
}

/** The three things an operator reads at a glance, as the page holds them. */
function surface(doc) {
  const banner = doc.getElementById('link-banner');
  return {
    badge: doc.getElementById('state-badge').textContent,
    pct: doc.getElementById('progress-pct').textContent,
    dot: doc.getElementById('connection-dot').className,
    banner: banner.classList.contains('hidden') ? '' : banner.textContent,
  };
}

test('a 200 whose body is falsy is a failed exchange, not a healthy link',
  async () => {
    // Every falsy JSON body a 200 can carry. `null` is the one that was
    // measured; the others reach the identical `if (!data) return;`.
    for (const body of [null, 0, false, '']) {
      const state = { body: runningSnapshot() };
      const { doc, api } = loadRunWatch(snapshotServer(state));

      await api.fetchSnapshot();
      assert.equal(surface(doc).badge, 'running',
        'a well-formed snapshot still paints the run');
      assert.equal(api.isLinkStale(), false);
      const healthyAt = api.peek().lastSnapshotAt;

      state.body = body;
      await api.fetchSnapshot();

      const after = surface(doc);
      assert.equal(after.badge, 'unknown',
        `a body of ${JSON.stringify(body)} may not leave "running" asserted`);
      assert.equal(after.pct, '--',
        'the figure cannot outlive the exchange that carried it');
      assert.ok(after.dot.includes('conn-disconnected'),
        'the dot may not stay green on an answer that said nothing');
      assert.match(after.banner, /cannot read/,
        'the operator has to be told the answer was unreadable');
      assert.doesNotMatch(after.banner, /Cannot reach/,
        'the server answered — saying it is unreachable would be the '
        + 'opposite lie');
      assert.equal(api.peek().lastSnapshotAt, healthyAt,
        'an exchange that taught the page nothing may not reset the '
        + 'staleness clock');
      assert.equal(api.isLinkStale(), true);
    }
  });

test('a 200 whose body is not JSON is the same failed exchange', async () => {
  const state = { body: runningSnapshot() };
  const { doc, api } = loadRunWatch(snapshotServer(state));
  await api.fetchSnapshot();
  assert.equal(api.isLinkStale(), false);

  state.throws = true;
  await api.fetchSnapshot();
  assert.equal(api.isLinkStale(), true,
    'a body that will not parse is not an answer');
  assert.equal(surface(doc).badge, 'unknown');
  assert.match(surface(doc).banner, /cannot read/);
});

test('a payload that is not a snapshot is refused, never swallowed', () => {
  const { api } = loadRunWatch();
  for (const body of [null, undefined, 0, false, '', 'running', 42, []]) {
    assert.throws(
      () => api.applySnapshot(body),
      (e) => e.kind === 'unusable_answer',
      'applySnapshot must refuse ' + JSON.stringify(body ?? null));
  }
});

test('a snapshot that arrives after an unreadable answer takes the page back',
  async () => {
    const state = { body: null };
    const { doc, api } = loadRunWatch(snapshotServer(state));
    await api.fetchSnapshot();
    assert.equal(surface(doc).badge, 'unknown');

    state.body = runningSnapshot();
    await api.fetchSnapshot();
    const after = surface(doc);
    assert.equal(after.badge, 'running');
    assert.equal(after.pct, '8%');
    assert.equal(after.banner, '', 'a link that is answering raises no banner');
    assert.ok(after.dot.includes('conn-connected'));
  });

/** The running snapshot with every activeTarget number typed as a string. */
function poisonedTargetSnapshot() {
  const snap = runningSnapshot();
  snap.sequencer.progress.progressPercent = 0.75;
  snap.sequencer.progress.completedExposures = 9;
  snap.sequencer.progress.currentFilter = 'R';
  snap.activeTarget = {
    unavailable: false, coordinatesKnown: true, message: null,
    id: 't', name: 'Poisoned Field',
    raHours: 'abc', decDegrees: 'def', altitudeDeg: 'not-a-number',
    azimuthDeg: 'ghi', timeToSetSecs: 'soon', timeToTransitSecs: 'later',
  };
  snap.guiding = {
    state: 'Guiding', connected: true,
    rmsRa: '0.41', rmsDec: 0.38, rmsTotal: 0.56, snr: 'high',
  };
  return snap;
}

test('a wrongly-typed number states no reading rather than painting NaN', () => {
  const { doc, api } = loadRunWatch();
  api.noteLinkOk();
  api.applySnapshot(poisonedTargetSnapshot());

  const read = (id) => doc.getElementById(id).textContent;
  for (const id of ['target-coords', 'target-alt', 'target-az',
    'target-time-set', 'target-time-transit', 'guide-ra', 'guide-snr']) {
    assert.equal(read(id), '--',
      id + ' carries no number, and no number is not a number to print');
    assert.ok(!/NaN/.test(read(id)), id + ' printed a literal NaN');
  }
  // The name IS a string on the wire and stays readable — only the arithmetic
  // fields lose their reading.
  assert.equal(read('target-name'), 'Poisoned Field');
  assert.equal(read('guide-dec'), '0.38″', 'a well-typed neighbour is unharmed');
});

test('one poisoned field does not abort the fields under it', () => {
  const { doc, api } = loadRunWatch();
  api.noteLinkOk();
  api.applySnapshot(runningSnapshot());
  assert.equal(doc.getElementById('progress-pct').textContent, '8%');
  assert.equal(doc.getElementById('progress-filter').textContent, 'L');

  // The target block runs FIRST. Everything below it must still take this
  // payload's values rather than staying on the last one.
  api.applySnapshot(poisonedTargetSnapshot());
  assert.equal(doc.getElementById('progress-pct').textContent, '75%');
  assert.equal(doc.getElementById('progress-frames').textContent, '9 / 12');
  assert.equal(doc.getElementById('progress-filter').textContent, 'R');
  assert.equal(doc.getElementById('weather-badge').textContent, 'no sensor');
});

test('a progress percentage that is not a number is unknown, not NaN%', () => {
  const { doc, api } = loadRunWatch();
  const snap = runningSnapshot();
  snap.sequencer.progress.progressPercent = 'lots';
  snap.sequencer.progress.completedExposures = 'some';
  api.applySnapshot(snap);
  assert.equal(doc.getElementById('progress-pct').textContent, '--');
  assert.equal(doc.getElementById('progress-frames').textContent, '--');
  assert.equal(doc.getElementById('progress-bar').style.width, '0%');
  assert.equal(doc.getElementById('progress-bar-aria')
    .getAttribute('aria-valuenow'), null);
});

test('a render that throws degrades instead of freezing silently', async () => {
  // `recentEvents` typed as a string has a truthy `.length` and no `.forEach`,
  // so the feed block throws part-way through the render. Whatever the shape,
  // a half-painted page is not a picture of anything.
  const state = { body: runningSnapshot() };
  const { doc, api } = loadRunWatch(snapshotServer(state));
  await api.fetchSnapshot();
  assert.equal(surface(doc).badge, 'running');

  state.body = runningSnapshot({ recentEvents: 'FrameAccepted' });
  await api.fetchSnapshot();

  const after = surface(doc);
  assert.equal(after.badge, 'unknown',
    'a render that could not finish may not leave the old state asserted');
  assert.equal(after.pct, '--');
  assert.ok(after.dot.includes('conn-disconnected'));
  assert.match(after.banner, /cannot read/);
  assert.equal(api.isLinkStale(), true);
});

// ---------------------------------------------------------------------------
// D4-04 — the Recent-events feed carries events, not a progress read-out
//
// Measured against the release bundle during one live sim sequence: 327 events
// in 60 s on /api/run-watch/events, of which ExposureProgress 84, Progress 53,
// InstructionProgress 46 and InstructionProgressStructured 46. Sampling the
// page every 2 s for 50 s of that run, 104 of 125 row slots held a progress
// tick and not one of the 25 samples showed a FrameAccepted row or a node
// transition — the five-row cap was spent before anything discrete could be
// read.
// ---------------------------------------------------------------------------

/** Push one SSE frame through the page's own handler. */
function sse(api, payload) {
  api.handleSseMessage({ data: JSON.stringify(payload) });
}

function feedTitles(doc) {
  const rows = doc.getElementById('event-feed').children;
  const titles = [];
  for (const li of rows) {
    if (li.classList.contains('event-folded')) continue;
    // renderEventLi builds <li><span.event-time><div.event-body><div.event-title>
    const body = li.children[1];
    if (body && body.children[0]) titles.push(body.children[0].textContent);
  }
  return titles;
}

function foldRowText(doc) {
  for (const li of doc.getElementById('event-feed').children) {
    if (li.classList.contains('event-folded')) return li.textContent;
  }
  return null;
}

test('the progress families the server emits at ~Hz are recognised as ticks', () => {
  const { api } = loadRunWatch();
  for (const t of ['ExposureProgress', 'Progress', 'InstructionProgress',
    'InstructionProgressStructured']) {
    assert.equal(api.isProgressTickEvent(t), true, t + ' is a progress tick');
  }
  for (const t of ['FrameAccepted', 'NodeStarted', 'NodeCompleted',
    'ExposureCompleted', 'DecisionLogged', 'SchedulerDecision']) {
    assert.equal(api.isProgressTickEvent(t), false, t + ' is a discrete event');
  }
});

test('a burst of progress ticks cannot evict a FrameAccepted row', () => {
  const { doc, api } = loadRunWatch();
  sse(api, { eventType: 'FrameAccepted', severity: 'info',
    timestamp: Date.now(), data: { filter: 'L' } });
  assert.deepEqual(feedTitles(doc), ['FrameAccepted']);

  // The measured cadence: four ticks a second. Sixty of them is fifteen
  // seconds of one exposure — under the old rule the row above was gone
  // after five.
  for (let i = 0; i < 60; i++) {
    sse(api, { eventType: 'ExposureProgress', severity: 'info',
      timestamp: Date.now(), data: { progress: i / 60 } });
  }
  assert.deepEqual(feedTitles(doc), ['FrameAccepted'],
    'the frame the operator is waiting on must survive the ticks');
});

test('the fold says how many ticks it is holding back', () => {
  const { doc, api } = loadRunWatch();
  sse(api, { eventType: 'NodeStarted', severity: 'info', timestamp: Date.now() });
  assert.equal(foldRowText(doc), null, 'nothing folded yet, nothing claimed');

  sse(api, { eventType: 'ExposureProgress', severity: 'info', timestamp: Date.now() });
  assert.match(foldRowText(doc), /^1 progress update since/);
  assert.match(foldRowText(doc), /progress bar/,
    'say where the figure the fold hides actually lives');

  for (let i = 0; i < 4; i++) {
    sse(api, { eventType: 'Progress', severity: 'info', timestamp: Date.now() });
  }
  assert.match(foldRowText(doc), /^5 progress updates since/);

  // A discrete event closes the gap the fold was describing.
  sse(api, { eventType: 'FrameAccepted', severity: 'info', timestamp: Date.now() });
  assert.equal(foldRowText(doc), null);
  assert.deepEqual(feedTitles(doc), ['FrameAccepted', 'NodeStarted']);
});

test('the fold row does not consume one of the five discrete slots', () => {
  const { doc, api } = loadRunWatch();
  const names = ['NodeStarted', 'ExposureStarted', 'FrameAccepted',
    'ExposureCompleted', 'DecisionLogged'];
  for (const n of names) {
    sse(api, { eventType: n, severity: 'info', timestamp: Date.now() });
  }
  sse(api, { eventType: 'ExposureProgress', severity: 'info', timestamp: Date.now() });
  assert.equal(feedTitles(doc).length, 5,
    'five events plus a fold row is still five events');
  assert.ok(foldRowText(doc));
});

test('a critical event is still surfaced even when its name says progress', () => {
  const { doc, api } = loadRunWatch();
  sse(api, { eventType: 'ExposureProgress', severity: 'critical',
    timestamp: Date.now(), data: { message: 'dome closing' } });
  const toasts = doc.getElementById('toast-region').children;
  assert.equal(toasts.length, 1,
    'a severity the server calls critical is not this page\'s to suppress');
});

test('the snapshot\'s own recent list is filtered by the same rule', async () => {
  const state = {
    body: runningSnapshot({
      recentEvents: [
        { eventType: 'Progress', severity: 'info', timestamp: Date.now() },
        { eventType: 'FrameAccepted', severity: 'info', timestamp: Date.now() },
        { eventType: 'Progress', severity: 'info', timestamp: Date.now() },
        { eventType: 'NodeCompleted', severity: 'info', timestamp: Date.now() },
      ],
    }),
  };
  const { doc, api } = loadRunWatch(snapshotServer(state));
  await api.fetchSnapshot();
  assert.deepEqual(feedTitles(doc), ['FrameAccepted', 'NodeCompleted']);
});

// The refusal is stated ONCE per credential. `bootSession` fires the snapshot,
// the frame poll and the SSE subscription together, so a refused token
// produces several 401s within a tick; the first tears the token down, and
// without a guard the ones already in flight re-read a flag that first one had
// just cleared. Measured on the running bundle: an accepted-then-revoked
// pairing was described, after a reload, as a token that had never been
// accepted — the second 401 overwrote the first one's sentence.
test('concurrent refusals do not rewrite the first one\'s account', async () => {
  const { doc, api } = loadRunWatch({
    fetch: async () => ({
      ok: false, status: 401, statusText: 'Unauthorized',
      headers: new Headers(),
      json: async () => ({ error: 'unauthorized' }),
      text: async () => 'unauthorized',
    }),
  });
  api.setToken('a-pairing-the-desktop-revoked', true);

  const refusals = [
    api.apiFetch('/api/run-watch/snapshot'),
    api.apiFetch('/api/run-watch/frame-thumbnail'),
    api.apiFetch('/api/run-watch/snapshot'),
  ];
  for (const r of refusals) {
    await assert.rejects(() => r, (e) => e.kind === 'auth_required');
  }
  assert.match(doc.getElementById('pair-status').textContent, /no longer accepted/,
    'the account of what happened is settled by the first refusal, not the last');
});

// The seam the feed actually rides on. Measured on the release bundle: 327 of
// 327 frames over one live minute carried an `event:` name, and EventSource
// hands a named frame ONLY to a listener registered for that name — so
// `sse.onmessage` never fired at all and the feed was painted solely by the
// snapshot poll's five-deep `recentEvents` ring. Mid-exposure that ring is
// progress ticks, which is why 25 consecutive samples of a live run held no
// FrameAccepted row and no node transition.
test('the feed is fed by the named frames the server actually sends', async () => {
  const listeners = {};
  function FakeEventSource() {
    this.close = () => {};
    this.addEventListener = (name, fn) => {
      (listeners[name] = listeners[name] || []).push(fn);
    };
  }
  const { doc, api } = loadRunWatch({
    EventSource: FakeEventSource,
    // refreshFrame rides the same named events; a 404 is its documented
    // "no image yet" and keeps it quiet.
    fetch: async () => ({
      ok: false, status: 404, headers: new Headers(),
      json: async () => ({}), text: async () => '',
    }),
  });
  api.setToken('a-paired-token', true);
  api.openSSE();

  for (const name of ['FrameAccepted', 'NodeStarted', 'NodeCompleted',
    'ExposureCompleted', 'DecisionLogged']) {
    assert.ok(listeners[name] && listeners[name].length,
      name + ' must be subscribed or it can never reach the feed');
  }
  assert.ok(listeners.ExposureProgress && listeners.ExposureProgress.length,
    'a tick family unsubscribed is a tick family the fold can never count');

  const deliver = (name, timestamp) => {
    for (const fn of listeners[name]) {
      fn({ data: JSON.stringify({ eventType: name, severity: 'info', timestamp }) });
    }
  };
  deliver('NodeStarted', 1000);
  deliver('FrameAccepted', 2000);
  assert.deepEqual(feedTitles(doc), ['FrameAccepted', 'NodeStarted'],
    'the newest discrete event is at the top and the older one survives');

  // The ticks are counted and stated, and they take no row.
  deliver('ExposureProgress', 2100);
  deliver('ExposureProgress', 2200);
  assert.deepEqual(feedTitles(doc), ['FrameAccepted', 'NodeStarted']);
  assert.match(foldRowText(doc), /^2 progress updates since/);
});

test('the snapshot ring cannot erase what the stream delivered', async () => {
  // The ring the server answered with mid-run, verbatim in shape: five deep,
  // ticks on top. Merging it must not take the frame off the screen.
  const state = {
    body: runningSnapshot({
      recentEvents: [
        { eventType: 'Progress', severity: 'info', timestamp: 3000 },
        { eventType: 'Progress', severity: 'info', timestamp: 2900 },
        { eventType: 'DecisionLogged', severity: 'info', timestamp: 1500 },
      ],
    }),
  };
  const { doc, api } = loadRunWatch(snapshotServer(state));
  api.handleSseMessage({ data: JSON.stringify({
    eventType: 'FrameAccepted', severity: 'info', timestamp: 2000 }) });
  assert.deepEqual(feedTitles(doc), ['FrameAccepted']);

  await api.fetchSnapshot();
  assert.deepEqual(feedTitles(doc), ['FrameAccepted', 'DecisionLogged'],
    'the ring adds what the stream missed; it does not overwrite the feed');
});

test('an event that arrives twice is shown once', async () => {
  const frame = { eventType: 'FrameAccepted', severity: 'info', timestamp: 4242 };
  const state = { body: runningSnapshot({ recentEvents: [frame] }) };
  const { doc, api } = loadRunWatch(snapshotServer(state));
  api.handleSseMessage({ data: JSON.stringify(frame) });
  await api.fetchSnapshot();
  await api.fetchSnapshot();
  assert.deepEqual(feedTitles(doc), ['FrameAccepted']);
});

// ---------------------------------------------------------------------------
// W16-C — the counter, the absence, the handoff and the wall
//
// Four measurements against the release bundle on a headless rig, all four of
// them the page saying something its own screen or its own server contradicts.
// ---------------------------------------------------------------------------

/** The frame counter exactly as the operator reads it. */
function frameCounter(doc) {
  return doc.getElementById('progress-frames').textContent;
}

/** A snapshot whose progress block reports `done` of `planned` frames. */
function snapshotAtFrame(done, planned) {
  const snap = runningSnapshot();
  snap.sequencer.progress.completedExposures = done;
  snap.sequencer.progress.totalExposures = planned;
  return snap;
}

// D4-WEB-01. Measured over one 25-frame run: the page read "22 / 25" with
// "ExposureCompleted frame: 24" rendered directly beneath it and
// /api/run-watch/snapshot agreeing with the feed, because only sequence-level
// transitions re-polled the snapshot while frame events went to the thumbnail
// alone. No badge, no styling and no "last updated" distinguished that screen
// from an agreeing one.
test('a frame event the feed took marks the counter beside it as behind', () => {
  const { doc, api } = loadRunWatch();
  api.renderSnapshot(snapshotAtFrame(22, 25));
  assert.equal(frameCounter(doc), '22 / 25');

  api.noteFrameEvent({
    eventType: 'ExposureCompleted', timestamp: 1, data: { frame: 24, total: 25 },
  });
  assert.equal(frameCounter(doc), '22 / 25 · updating',
    'the page may not print a figure its own feed has already outrun');
});

test('the counter stops saying it is behind once the snapshot catches up', () => {
  const { doc, api } = loadRunWatch();
  api.renderSnapshot(snapshotAtFrame(22, 25));
  api.noteFrameEvent({
    eventType: 'FrameAccepted', timestamp: 1, data: { frame: 24, total: 25 },
  });
  assert.equal(frameCounter(doc), '22 / 25 · updating');

  api.renderSnapshot(snapshotAtFrame(24, 25));
  assert.equal(frameCounter(doc), '24 / 25');
});

test('a frame event schedules the re-read that catches the counter up', async () => {
  const state = { body: snapshotAtFrame(24, 25) };
  const { doc, api, deferred } = loadRunWatch(snapshotServer(state));
  api.renderSnapshot(snapshotAtFrame(22, 25));

  // A frame lands under several names in the same millisecond on the wire.
  api.noteFrameEvent({ eventType: 'FrameAccepted', timestamp: 1, data: { frame: 23 } });
  api.noteFrameEvent({ eventType: 'ExposureCompleted', timestamp: 1, data: { frame: 23 } });
  api.noteFrameEvent({ eventType: 'ImageSaved', timestamp: 1, data: {} });
  assert.equal(deferred.length, 1,
    'one burst of names for one frame earns one re-read, not three');

  deferred[0].fn();
  // The re-read is a fetch chain; let its microtasks settle before reading.
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(frameCounter(doc), '24 / 25',
    'the counter advances on the events the feed does');
});

// A frame event carrying no frame number still means the counter is behind:
// the arrival is the evidence when the payload has none.
test('a numberless frame event still marks the counter as behind', () => {
  const { doc, api } = loadRunWatch();
  api.renderSnapshot(snapshotAtFrame(22, 25));
  api.noteFrameEvent({ eventType: 'ImageSaved', timestamp: 1, data: {} });
  assert.equal(frameCounter(doc), '22 / 25 · updating');
});

// D4-WEB-02. Measured with four simulator devices genuinely connected and the
// snapshot endpoint answering 500 to every read: EQUIPMENT read "No connected
// devices" while GUIDING, WEATHER, PROGRESS, FRAMES and FILTER all read "--".
// The shipped placeholder was the false claim, and it survived every failed
// read.
test('the shipped equipment placeholder claims nothing about the rig', () => {
  const html = fs.readFileSync(path.join(RUN_WATCH, 'index.html'), 'utf8');
  const block = html.slice(html.indexOf('id="equipment-list"'));
  const shipped = block.slice(0, block.indexOf('</div>', block.indexOf('class="empty"')));
  assert.doesNotMatch(shipped, /No connected devices/,
    'a page that has read nothing may not assert an empty rig');
  assert.match(shipped, /--/,
    'the unknown surface the sibling fields ship');
});

test('an absent device list is unknown, never an empty rig', () => {
  const { doc, api } = loadRunWatch();
  const snap = runningSnapshot();
  delete snap.devices;
  api.applySnapshot(snap);
  assert.equal(doc.getElementById('equipment-list').children[0].textContent, '--',
    'nothing was said about equipment, so nothing is claimed about it');
});

test('a device list the server sent and that is empty says so', () => {
  const { doc, api } = loadRunWatch();
  api.applySnapshot(runningSnapshot({ devices: [] }));
  assert.equal(
    doc.getElementById('equipment-list').children[0].textContent,
    'No connected devices',
    'an empty list IS a reading, and the page keeps saying it');
});

test('a device list the server sent renders its rows', () => {
  const { doc, api } = loadRunWatch();
  api.applySnapshot(runningSnapshot({
    devices: [{ name: 'Simulator camera 1', type: 'camera' }],
  }));
  const rows = doc.getElementById('equipment-list').children;
  assert.equal(rows.length, 1);
  assert.equal(rows[0].children[0].textContent, 'Simulator camera 1');
});

// ---------------------------------------------------------------------------
// D4-WEB-03 — an operator authenticated to the dashboard is authenticated here
//
// Measured: the dashboard read "Connected" with its bearer in this tab's
// sessionStorage, and its own Run-Watch link landed on the pairing wall.
// ---------------------------------------------------------------------------

test('the bearer the dashboard left in this tab is used, not re-requested', async () => {
  const { doc, api } = loadRunWatch({
    sessionStorage: [['skotiq_token', 'dashboard-bearer']],
    fetch: async () => ({
      ok: true, status: 200, headers: new Headers(),
      json: async () => runningSnapshot(),
    }),
  });
  await api.resolveCredentialAndShow();
  assert.ok(doc.getElementById('pair-screen').classList.contains('hidden'),
    'an operator who signed in seconds ago is not asked to pair');
  const cred = api.peekCredential();
  assert.equal(cred.effective, 'dashboard-bearer');
  assert.equal(cred.credentialSource, 'dashboard-tab');
});

test('a borrowed dashboard bearer is never persisted to this page storage', async () => {
  const { api, sandbox } = loadRunWatch({
    sessionStorage: [['skotiq_token', 'dashboard-bearer']],
    fetch: async () => ({
      ok: true, status: 200, headers: new Headers(),
      json: async () => runningSnapshot(),
    }),
  });
  await api.resolveCredentialAndShow();
  assert.equal(sandbox.localStorage.getItem('skotiq.runwatch.token'), null,
    'the dashboard chose sessionStorage; this page does not overrule that');
  assert.equal(
    sandbox.localStorage.getItem('skotiq.runwatch.tokenAccepted'), null);
});

test('an HttpOnly session the server confirms opens the run, with no bearer', async () => {
  const seen = [];
  const { doc, api } = loadRunWatch({
    fetch: async (path, opts) => {
      seen.push({ path, opts });
      if (path === '/api/auth/csrf') {
        return {
          ok: true, status: 200, headers: new Headers(),
          json: async () => ({ csrfToken: 'csrf-abc', expiresInSeconds: 900 }),
        };
      }
      return {
        ok: true, status: 200, headers: new Headers(),
        json: async () => runningSnapshot(),
      };
    },
  });
  await api.resolveCredentialAndShow();
  assert.ok(doc.getElementById('pair-screen').classList.contains('hidden'));
  const cred = api.peekCredential();
  assert.equal(cred.credentialSource, 'session-cookie');
  assert.ok(!cred.effective, 'the cookie is HttpOnly — there is no bearer to hold');

  // A write on the cookie path must echo the CSRF token the server bound to it.
  await api.apiFetch('/api/sequencer/pause', { method: 'POST' });
  const write = seen[seen.length - 1];
  assert.equal(write.opts.headers.get('X-Skotiq-CSRF'), 'csrf-abc');
  assert.equal(write.opts.headers.get('Authorization'), null);
  assert.equal(write.opts.credentials, 'same-origin');
});

// The refusal that matters: nothing above widens what an unauthenticated
// browser can reach. With no pairing, no dashboard bearer and no session, the
// server answers 401 and the wall is what is left.
test('a browser that has signed in nowhere still meets the pairing wall', async () => {
  const { doc, api } = loadRunWatch({
    fetch: async () => ({
      ok: false, status: 401, statusText: 'Unauthorized',
      headers: new Headers(),
      json: async () => ({ error: 'no_session' }),
      text: async () => 'no_session',
    }),
  });
  await api.resolveCredentialAndShow();
  assert.ok(!doc.getElementById('pair-screen').classList.contains('hidden'));
  assert.ok(doc.getElementById('main-screen').classList.contains('hidden'));
  assert.equal(api.peekCredential().effective, null,
    'no credential was invented to get past the wall');
});

test('an ended dashboard session is not described as a revoked pairing', () => {
  assert.match(
    api_credentialRefusal('session-cookie', null, false),
    /session has ended/);
  assert.doesNotMatch(
    api_credentialRefusal('session-cookie', null, false), /pairing.*revoked/);
  assert.match(
    api_credentialRefusal('dashboard-tab', 'borrowed', false),
    /dashboard session/);
  assert.match(
    api_credentialRefusal('paired', 'mine', true), /pairing is no longer accepted/);
});

/** Reads the refusal sentence out of a freshly loaded page. */
function api_credentialRefusal(source, token, wasAccepted) {
  const { api } = loadRunWatch();
  return api.credentialRefusalText(source, token, wasAccepted);
}

// ---------------------------------------------------------------------------
// D4-WEB-04 — the wall names a step the rig it is running on can perform
//
// Measured on a headless bundle with no GUI anywhere on the machine: the wall
// said "Open the Skotiq desktop app's Remote Access screen", offered no
// control that causes a code to exist, and the code the server does make sat in
// an owner-only pairing-code.txt this page named nowhere.
// ---------------------------------------------------------------------------

test('the wall names a code source a headless rig actually has', () => {
  const html = fs.readFileSync(path.join(RUN_WATCH, 'index.html'), 'utf8');
  const wall = html.slice(html.indexOf('id="pair-screen"'),
    html.indexOf('id="main-screen"'));
  assert.match(wall, /pairing-code\.txt/,
    'the file a headless rig writes the code to');
  assert.match(wall, /--pairing-print-codes/,
    'the flag that puts it on a headless console');
  assert.match(wall, /id="btn-request-code"/,
    'naming a source without a way to make a code is still a dead end');
});

test('the request button reports where the rig actually put the code', async () => {
  const { doc, api } = loadRunWatch({
    fetch: async () => ({
      ok: true, status: 200, headers: new Headers(),
      json: async () => ({
        expiresAt: '2026-08-31T15:50:49Z',
        expiresInSeconds: 299,
        codeDelivery: {
          operatorFile: true,
          operatorFileName: 'pairing-code.txt',
          console: false,
        },
      }),
    }),
  });
  await api.requestPairingCode();
  const status = doc.getElementById('pair-status').textContent;
  assert.match(status, /pairing-code\.txt/);
  assert.doesNotMatch(status, /console/,
    'this host was not started with printing on; do not send them to a console');
  assert.match(status, /5 min/);
});

test('a rig that could not deliver the code says so instead of naming a file', () => {
  const { api } = loadRunWatch();
  const text = api.codeDeliveryText({
    codeDelivery: { operatorFile: false, operatorFileName: 'pairing-code.txt', console: false },
  });
  assert.match(text, /could not put it anywhere readable/);
  assert.doesNotMatch(text, /Read it from/,
    'naming a file the rig failed to write is the same defect in a new place');
});

test('a console-printing host is named as such', () => {
  const { api } = loadRunWatch();
  const text = api.codeDeliveryText({
    codeDelivery: { operatorFile: true, operatorFileName: 'pairing-code.txt', console: true },
  });
  assert.match(text, /pairing-code\.txt/);
  assert.match(text, /console output/);
});

// The wall's own Pair button, driven end-to-end against the release bundle with
// a code read out of the rig's pairing-code.txt: the server answered 200 with
// {"token": "...", "tokenScope": "control"} and this screen said "Pairing
// failed." and threw the token away. It was reading `sessionToken`, which is
// the server's internal name for the field and has never been on the wire.
test('the token the server actually mints is the one the page keeps', async () => {
  const { doc, api, sandbox } = loadRunWatch({
    fetch: async () => ({
      ok: true, status: 200, headers: new Headers(),
      json: async () => ({
        token: 'minted-by-the-rig',
        tokenScope: 'control',
        expiresAt: '2027-08-31T16:03:35Z',
      }),
    }),
  });
  await api.startPairing('MOON-NOVA-9664');

  assert.equal(
    sandbox.localStorage.getItem('skotiq.runwatch.token'),
    'minted-by-the-rig');
  assert.equal(api.tokenWasEverAccepted(), true,
    'the pairing endpoint minted it, so it is accepted by construction');
  assert.match(doc.getElementById('pair-status').textContent, /Paired successfully/);
  assert.ok(doc.getElementById('pair-screen').classList.contains('hidden'));
});

test('a 2xx that carries no token is not blamed on the operator typing', async () => {
  const { doc, api } = loadRunWatch({
    fetch: async () => ({
      ok: true, status: 200, headers: new Headers(),
      json: async () => ({ tokenScope: 'control' }),
    }),
  });
  await api.startPairing('MOON-NOVA-9664');
  const status = doc.getElementById('pair-status').textContent;
  assert.match(status, /sent no token back/);
  assert.doesNotMatch(status, /not recognised/,
    'the code was accepted; do not tell them to re-read it');
  assert.ok(!doc.getElementById('pair-screen').classList.contains('hidden'));
});

// A counter with no figure on it cannot be behind. Measured with the snapshot
// endpoint answering 500 while the SSE stream still delivered frames: the
// counter read "-- · updating", a staleness claim about a number that was not
// on the screen.
test('an unknown frame counter is not decorated with a staleness cue', () => {
  const { doc, api } = loadRunWatch();
  const snap = runningSnapshot();
  snap.sequencer.progress.completedExposures = null;
  snap.sequencer.progress.totalExposures = null;
  api.renderSnapshot(snap);
  api.noteFrameEvent({ eventType: 'FrameAccepted', timestamp: 1, data: { frame: 4 } });
  assert.equal(frameCounter(doc), '--',
    'there is no figure here for the feed to have outrun');
});

// ---------------------------------------------------------------------------
// The LAST FRAME card
// ---------------------------------------------------------------------------
// D4-1. Measured on the release bundle: a rig whose library held 26 frames and
// whose sim camera was connected answered `/api/run-watch/frame-thumbnail` 404
// (the driver's in-memory buffer is empty after a relaunch), and this card
// rendered "No frame captured yet" — an absolute about the whole rig, from a
// page that had been told only about one process's buffer. The sibling
// dashboard read the same wire correctly. `refreshFrame` discarded the typed
// body with `if (!res.ok) return;` and index.html's static string simply stood.

/** The 404 the server sends when this process has buffered no exposure. */
function emptyBufferBody() {
  return {
    error: 'no_live_preview',
    scope: 'process',
    library: '/api/images',
    message: 'No live preview for sim_camera_1 in this server process — the ' +
      'preview buffer holds the last exposure taken since the server ' +
      'started, and no exposure has run yet. Frames already captured are ' +
      'listed by /api/images.',
  };
}

function refusal(status, body) {
  return async () => ({
    ok: false,
    status,
    headers: new Headers(),
    json: async () => {
      if (body === undefined) throw new Error('not JSON');
      return body;
    },
    text: async () => '',
  });
}

/** A 200 carrying a JPEG and the frame headers the server stamps on it. */
function servedFrame(headers) {
  return async () => ({
    ok: true,
    status: 200,
    headers: new Headers(headers),
    blob: async () => ({ size: 1024 }),
  });
}

/** Seed the placeholder with the exact string index.html ships. */
function shippedPlaceholder(doc) {
  const html = fs.readFileSync(path.join(RUN_WATCH, 'index.html'), 'utf8');
  const m = html.match(/id="frame-placeholder"[^>]*>([^<]*)</);
  assert.ok(m, 'index.html must still carry a #frame-placeholder');
  doc.getElementById('frame-placeholder').textContent = m[1];
  return m[1];
}

test('an empty preview buffer is a fact about this process, not about the rig',
  async () => {
    const { doc, api } = loadRunWatch({
      fetch: refusal(404, emptyBufferBody()),
    });
    shippedPlaceholder(doc);
    api.setToken('a-paired-token', true);
    await api.refreshFrame();

    const said = doc.getElementById('frame-placeholder').textContent;
    assert.match(said, /since the server started/,
      'the emptiness is scoped to this process, which is the fact the ' +
      'server sent');
    assert.doesNotMatch(said, /No frame captured yet/,
      'a rig holding 26 frames may not be told nothing was ever captured');
    assert.match(said, /\/api\/images/,
      'the operator is pointed at what the rig actually holds');
    assert.equal(doc.getElementById('frame-wrap').getAttribute('aria-label'),
      said, 'the sentence reaches a screen reader too, not only the sighted ' +
      'reader');
    assert.ok(!doc.getElementById('frame-placeholder').classList
      .contains('hidden'));
  });

test('the shipped frame placeholder claims nothing before the server answers',
  () => {
    const html = fs.readFileSync(path.join(RUN_WATCH, 'index.html'), 'utf8');
    const m = html.match(/id="frame-placeholder"[^>]*>([^<]*)</);
    assert.ok(m, 'index.html must still carry a #frame-placeholder');
    assert.doesNotMatch(m[1], /No frame captured yet/,
      'a page that has asked nothing may not assert an empty rig');
  });

test('a refusal that carries no reason is reported as one, not as an empty rig',
  async () => {
    const { doc, api } = loadRunWatch({ fetch: refusal(503, undefined) });
    shippedPlaceholder(doc);
    api.setToken('a-paired-token', true);
    await api.refreshFrame();

    const said = doc.getElementById('frame-placeholder').textContent;
    assert.match(said, /HTTP 503/,
      'the status is the only evidence there is, so it is what gets stated');
    assert.match(said, /sent no reason/);
    assert.doesNotMatch(said, /captured/,
      'nothing was learned about what the rig has captured');
  });

test('a frame that stops being served is taken off the screen with its caption',
  async () => {
    let serving = true;
    const { doc, api, sandbox } = loadRunWatch({
      fetch: (path) => (serving
        ? servedFrame({
          'x-frame-timestamp': '2026-08-31T17:53:20.000Z',
          'x-frame-hfr': '2.0032',
          'x-frame-hfr-basis': 'live-preview-median-brightest-half',
        })()
        : refusal(404, emptyBufferBody())()),
    });
    api.setToken('a-paired-token', true);
    await api.refreshFrame();
    assert.ok(!doc.getElementById('frame-img').classList.contains('hidden'),
      'the served frame is on screen');
    assert.equal(sandbox.URL._live.size, 1);

    serving = false;
    await api.refreshFrame();
    assert.ok(doc.getElementById('frame-img').classList.contains('hidden'),
      'a stale JPEG under "no live preview" is the same lie in another medium');
    assert.equal(doc.getElementById('frame-img').getAttribute('src'), null);
    assert.equal(doc.getElementById('frame-meta').textContent, '--',
      'the caption of a frame that is no longer shown goes with it');
    assert.equal(sandbox.URL._live.size, 0, 'the object URL is released');
  });

// D4-2. One physical frame carries two HFRs: the live-preview measurement on
// `x-frame-hfr` (the median of the brightest half of the detected stars) and
// the graded measurement in `captured_images.hfr` (the mean over every
// detected star), which is what the session report and the reject threshold
// read. Joined on timestamp with an identical star count, three consecutive
// sim frames read preview 2.0032 / 2.0139 / 2.0368 against library 2.4770 /
// 2.4732 / 2.4807. Neither surface said which it was showing.
test('the preview HFR says which measurement it is', async () => {
  const { doc, api } = loadRunWatch({
    fetch: servedFrame({
      'x-frame-timestamp': '2026-08-31T17:53:20.000Z',
      'x-frame-hfr': '2.0032',
      'x-frame-hfr-basis': 'live-preview-median-brightest-half',
    }),
  });
  api.setToken('a-paired-token', true);
  await api.refreshFrame();

  const meta = doc.getElementById('frame-meta');
  assert.match(meta.textContent, /HFR 2\.00 \(preview\)/,
    'an unlabelled 2.00 is what an operator sets a reject threshold from');
  assert.match(meta.title, /median of the brightest half/);
  assert.match(meta.title, /mean over every detected star/,
    'the other measurement is named, so the two numbers can be reconciled');
});

test('an HFR the server did not name is not given a name', async () => {
  const { doc, api } = loadRunWatch({
    fetch: servedFrame({
      'x-frame-timestamp': '2026-08-31T17:53:20.000Z',
      'x-frame-hfr': '2.0032',
    }),
  });
  api.setToken('a-paired-token', true);
  await api.refreshFrame();

  const meta = doc.getElementById('frame-meta');
  assert.match(meta.textContent, /HFR 2\.00/);
  assert.doesNotMatch(meta.textContent, /preview/,
    'an older server sent no basis, so the page guesses none');
  assert.equal(meta.title, '');
});

// D4W-3. Numbers on this page are guarded by `wireNumber` and lists throw a
// TypeError; strings were the one wire type with no guard at all, and the DOM
// stringifies whatever it is handed. Reproduced against the release bundle in
// a real browser with ONE field of a real snapshot changed — `currentFilter`
// from "L" to `{name:"L"}` — which put the literal text "[object Object]" in
// the filter slot and in the active-target line.
test('a filter that is not a string is not a filter', () => {
  const { doc, api } = loadRunWatch();
  const snapshot = runningSnapshot();
  snapshot.sequencer.progress.currentFilter = { name: 'L' };
  snapshot.activeTarget.coordinatesKnown = true;
  snapshot.activeTarget.raHours = 0.712;
  snapshot.activeTarget.decDegrees = 41.27;
  api.applySnapshot(snapshot);

  assert.equal(doc.getElementById('progress-filter').textContent, '--',
    'the slot reads "[object Object]" the moment the value is passed through');
  assert.equal(doc.getElementById('target-state').textContent, '',
    'and the target line concatenates the same object into a sentence');
});

test('a name that is not a string leaves the field unnamed', () => {
  const { doc, api } = loadRunWatch();
  const snapshot = runningSnapshot();
  snapshot.sequencer.progress.currentTarget = 42;
  snapshot.sequencer.currentNodeName = { a: 1 };
  snapshot.sequencer.progress.currentNodeName = ['a'];
  snapshot.activeTarget.name = ['a'];
  api.applySnapshot(snapshot);

  assert.equal(doc.getElementById('target-name').textContent, '--');
  assert.equal(doc.getElementById('progress-node').textContent, '--');
  assert.equal(doc.getElementById('seq-name').textContent, 'Running',
    'with no candidate carrying a name, the headline falls to the state word '
    + 'this page owns rather than printing "42"');
});

test('a blank string is an absence, not a reading', () => {
  const { doc, api } = loadRunWatch();
  const snapshot = runningSnapshot();
  snapshot.sequencer.progress.currentFilter = '   ';
  api.applySnapshot(snapshot);

  assert.equal(doc.getElementById('progress-filter').textContent, '--',
    'a field of spaces painted a blank where "--" says nothing is known');
});

test('the strings the server does send still reach the screen', () => {
  const { doc, api } = loadRunWatch();
  api.applySnapshot(runningSnapshot());

  assert.equal(doc.getElementById('progress-filter').textContent, 'L');
  assert.equal(doc.getElementById('progress-node').textContent, 'Exposure L');
  assert.equal(doc.getElementById('seq-name').textContent, 'D1 Simulated Field');
  assert.equal(doc.getElementById('target-name').textContent,
    'D1 Simulated Field');
});

// ---------------------------------------------------------------------------
// W19-A / D4-01 — a scope 403 is not a revoked pairing
//
// Measured against the release bundle on a live run: a viewer holding a valid
// read-only token pressed Pause once, the rig answered 403 naming
// sequencer:control, and the page hid the run, wrote "This device's pairing is
// no longer accepted — the rig rejected it, which happens when the pairing was
// revoked there…", and emptied localStorage. Nothing had been revoked: the
// same token answered 200 on /api/run-watch/snapshot a second later. The
// viewer lost a working credential and a live night over a button they were
// never entitled to press.
// ---------------------------------------------------------------------------

/** A 403 that names the capability it refused on, as the rig sends it. */
function scopeDenied(resource, requiredLevel, tokenLevel) {
  const body = {
    error: 'Access denied',
    message: 'Token scope is not permitted for this endpoint: this credential '
      + 'holds ' + tokenLevel + ' on ' + resource + ', and ' + requiredLevel
      + ' is required.',
    requiredResource: resource,
    requiredLevel,
    tokenLevel,
  };
  const res = {
    ok: false, status: 403, statusText: 'Forbidden',
    headers: new Headers(),
    json: async () => body,
    text: async () => JSON.stringify(body),
  };
  res.clone = () => res;
  return res;
}

test('a scope refusal keeps the credential and the viewer on the run', async () => {
  const { doc, api } = loadRunWatch({
    fetch: async () => scopeDenied('sequencer', 'control', 'view'),
  });
  api.setToken('a-valid-read-only-token', true);
  doc.getElementById('main-screen').classList.remove('hidden');
  doc.getElementById('pair-screen').classList.add('hidden');

  await assert.rejects(
    () => api.apiFetch('/api/sequencer/pause', { method: 'POST' }),
    (e) => e.kind === 'scope_denied',
  );

  assert.equal(api.peekCredential().effective, 'a-valid-read-only-token',
    'the rig accepted this credential — refusing one action does not revoke it');
  assert.ok(doc.getElementById('pair-screen').classList.contains('hidden'),
    'a viewer is not ejected from a live run by a button they cannot press');
  assert.ok(!doc.getElementById('main-screen').classList.contains('hidden'));
  assert.equal(doc.getElementById('pair-status').textContent, '',
    'nothing was revoked, so nothing may say it was');
});

test('a 401 still tears the credential down and says why', async () => {
  const { doc, api } = loadRunWatch({
    fetch: async () => ({
      ok: false, status: 401, statusText: 'Unauthorized',
      headers: new Headers(),
      json: async () => ({ error: 'Authentication required' }),
      text: async () => 'unauthorized',
    }),
  });
  api.setToken('a-token-the-rig-stopped-accepting', true);

  await assert.rejects(
    () => api.apiFetch('/api/run-watch/snapshot'),
    (e) => e.kind === 'auth_required',
  );
  assert.equal(api.peekCredential().effective, null);
  assert.match(doc.getElementById('pair-status').textContent, /no longer accepted/);
});

test('a 403 that names no capability is still a credential refusal', async () => {
  // The rig answers an unknown bearer with 403 too, so keeping every 403 would
  // strand a genuinely revoked device holding a dead token forever.
  const res = {
    ok: false, status: 403, statusText: 'Forbidden',
    headers: new Headers(),
    json: async () => ({
      error: 'Access denied', message: 'Invalid authentication token',
    }),
    text: async () => 'denied',
  };
  res.clone = () => res;
  const { doc, api } = loadRunWatch({ fetch: async () => res });
  api.setToken('a-token-the-rig-does-not-know', true);

  await assert.rejects(
    () => api.apiFetch('/api/run-watch/snapshot'),
    (e) => e.kind === 'auth_required',
  );
  assert.equal(api.peekCredential().effective, null);
  assert.ok(!doc.getElementById('pair-screen').classList.contains('hidden'));
});

test('a refused control names its refusal on the control and in a toast', async () => {
  const { doc, api } = loadRunWatch({
    fetch: async () => scopeDenied('sequencer', 'control', 'view'),
  });
  api.setToken('a-valid-read-only-token', true);

  await api.sequencerAction('/api/sequencer/pause', 'Pause');

  const btn = doc.getElementById('btn-pause');
  assert.equal(btn.disabled, true,
    'a control this credential cannot use may not stay live and do nothing');
  assert.match(btn.title, /control access to sequencer/);
  assert.match(btn.title, /view access to sequencer/,
    'say what this device does hold, not only what it lacks');

  const toastText = doc.getElementById('toast-region').children
    .map((c) => c.textContent).join(' ');
  assert.match(toastText, /control access to sequencer/);
  assert.doesNotMatch(toastText, /\{|Access denied/,
    'the wire body is a diagnostic, not a sentence for the operator');

  // And the next status poll must not hand the button straight back.
  api.updateRunControls('running');
  assert.equal(doc.getElementById('btn-pause').disabled, true);
});

test('the refusal sentence never invents a level the rig did not state', () => {
  const { api } = loadRunWatch();
  const text = api.scopeRefusalText('Pause', {
    resource: 'sequencer', requiredLevel: 'control', tokenLevel: null,
  });
  assert.match(text, /control access to sequencer/);
  assert.doesNotMatch(text, /no access|view access/,
    'an answer that named no tokenLevel gets a sentence without one');
});

// The event feed de-dupes on the pair (serverInstanceId, seq) the server
// stamps, not on the timestamp+type key it used to. A host stamps a whole
// burst with ONE millisecond, so a same-type burst — three FrameAccepted in
// the same tick — collapsed onto one row under the old key and the second and
// third events vanished. seq is server-assigned and monotonic, so the burst
// stays distinct while the same event heard twice (stream, then the snapshot's
// recent ring) still shows once.
test('a same-millisecond same-type burst keeps every event by seq', () => {
  const { api } = loadRunWatch();
  const base = {
    timestamp: 1000,
    eventType: 'FrameAccepted',
    serverInstanceId: 'srv-1',
  };
  api.noteFeedEvent({ ...base, seq: 1 });
  api.noteFeedEvent({ ...base, seq: 2 });
  api.noteFeedEvent({ ...base, seq: 3 });
  assert.equal(
    api.peekFeed().events.length, 3,
    'three siblings in one millisecond must not collapse to one row',
  );
});

test('the same server event heard twice is shown once', () => {
  const { api } = loadRunWatch();
  const evt = {
    timestamp: 1000,
    eventType: 'FrameAccepted',
    serverInstanceId: 'srv-1',
    seq: 7,
  };
  // Once off the stream, once out of the snapshot's recent ring — same
  // (serverInstanceId, seq), so one row.
  api.noteFeedEvent({ ...evt });
  api.noteFeedEvent({ ...evt });
  assert.equal(api.peekFeed().events.length, 1);
});

test('a seqless event falls back to the timestamp and type key', () => {
  const { api } = loadRunWatch();
  // No seq (a client-synthesised entry, or an older host): same timestamp AND
  // type still de-dupes, because that pair is all it carries.
  api.noteFeedEvent({ timestamp: 2000, eventType: 'NodeTransition' });
  api.noteFeedEvent({ timestamp: 2000, eventType: 'NodeTransition' });
  assert.equal(
    api.peekFeed().events.length, 1,
    'a seqless duplicate still collapses on timestamp+type',
  );
  // A different type at the same timestamp is a different event.
  api.noteFeedEvent({ timestamp: 2000, eventType: 'FrameAccepted' });
  assert.equal(api.peekFeed().events.length, 2);
});

test('a seq key and a seqless key never collide', () => {
  const { api } = loadRunWatch();
  const withSeq = api.feedEventKey({
    timestamp: 1000, eventType: 'FrameAccepted', serverInstanceId: 'srv-1', seq: 5,
  });
  const withoutSeq = api.feedEventKey({
    timestamp: 1000, eventType: 'FrameAccepted',
  });
  assert.notEqual(withSeq, withoutSeq);
  assert.match(withSeq, /^seq:srv-1:5$/);
});

test('seq zero is a real sequence number, not an absence', () => {
  const { api } = loadRunWatch();
  // `seq` can be 0 on the first event; `|| ''` would have dropped it back to
  // the timestamp key, so the guard is an explicit null/undefined check.
  const key = api.feedEventKey({
    timestamp: 1000, eventType: 'FrameAccepted', serverInstanceId: 'srv-1', seq: 0,
  });
  assert.equal(key, 'seq:srv-1:0');
});
