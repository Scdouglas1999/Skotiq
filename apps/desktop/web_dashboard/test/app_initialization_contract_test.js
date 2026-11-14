const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

test('cold dashboard discovers device ids before equipment status and preview', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'js', 'app.js'),
    'utf8',
  );
  const match = source.match(
    /async function fetchAllStatus\(\) \{([\s\S]*?)\n  \}/,
  );
  assert.ok(match, 'fetchAllStatus must exist');

  const body = match[1];
  const devices = body.indexOf('await fetchDevices()');
  const statuses = body.indexOf('await Promise.all([');
  const preview = body.indexOf('await fetchLastImage()');
  assert.ok(devices >= 0, 'device discovery must be awaited');
  assert.ok(statuses > devices, 'status fan-out must follow device discovery');
  assert.ok(preview > statuses, 'last-image hydration must follow status');
});

test('dashboard pairing accepts the server code format', () => {
  const appSource = fs.readFileSync(
    path.join(__dirname, '..', 'js', 'app.js'),
    'utf8',
  );
  const html = fs.readFileSync(
    path.join(__dirname, '..', 'index.html'),
    'utf8',
  );

  assert.match(appSource, /\^\[A-Za-z0-9-\]\{6,32\}\$/);
  assert.doesNotMatch(appSource, /Enter the 6-digit code/);
  assert.match(html, /maxlength="32"/);
  assert.match(html, /placeholder="STAR-LYRA-1234"/);
  assert.doesNotMatch(html, /inputmode="numeric"[^>]*pair-modal-code/);
});

test('dashboard treats WebSocket heartbeat traffic as live activity', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'js', 'app.js'),
    'utf8',
  );

  assert.match(
    source,
    /api\.on\('ws:activity',[\s\S]*?state\.lastWsMessageAt = Date\.now\(\)/,
  );
  assert.match(source, /const WS_FALLBACK_THRESHOLD_MS = 45000/);
});

test('healthy quiet WebSocket does not mark stable panels stale', () => {
  // The rule is unchanged and the mechanism that carries it is not: a
  // `wsHealthy` early-return used to suppress every panel's stale line while
  // the socket was alive, which also suppressed the one panel whose own REST
  // route was failing. The verdict now has a single source — a panel is stale
  // when its last refresh was REFUSED, or when contact is gone — so an idle
  // server that has simply pushed nothing marks nothing.
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'js', 'app.js'),
    'utf8',
  );
  const indicator = source.match(
    /function renderStaleIndicator\(panelKey, view\) \{([\s\S]*?)\n  \}/,
  );
  assert.ok(indicator, 'renderStaleIndicator must exist');
  assert.doesNotMatch(indicator[1], /lastWsMessageAt/,
    'panel staleness must not be inferred from how quiet the socket is');
  assert.match(
    source,
    /function isPanelDataStale\(panelKey\) \{[\s\S]*?failedAt > \(state\.panelLastUpdate\[panelKey\] \|\| 0\)/,
    'a panel is stale when its own refresh was refused, not when it is old',
  );
  // What the operator actually sees on a quiet-but-healthy night, and on a
  // night where one route is failing, is asserted in dashboard_honesty_test.js
  // ('a quiet but healthy night marks nothing stale' and its siblings).
});

test('device inventory refresh clears ids that are no longer connected', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'js', 'app.js'),
    'utf8',
  );
  const match = source.match(
    /async function fetchDevices\(\) \{([\s\S]*?)\n  \}/,
  );
  assert.ok(match, 'fetchDevices must exist');

  const body = match[1];
  const inventory = body.indexOf('state.connectedDevices = result.devices || []');
  const clearCamera = body.indexOf('state.cameraDeviceId = null');
  const selectDevices = body.indexOf('for (const dev of state.connectedDevices)');
  assert.ok(clearCamera > inventory, 'old ids must be cleared after inventory fetch');
  assert.ok(selectDevices > clearCamera, 'connected ids must be selected after clearing');
});

test('equipment property events do not refetch the full inventory', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'js', 'app.js'),
    'utf8',
  );

  const deviceListEvents = /const DEVICE_LIST_EVENTS = new Set\(\[([\s\S]*?)\]\);/
    .exec(source);
  assert.ok(deviceListEvents, 'the inventory follows a named set of events');
  assert.match(deviceListEvents[1], /WIRE_EVENTS\.equipment\.connected/);
  assert.doesNotMatch(deviceListEvents[1], /propertyChanged|heartbeat/);
  assert.match(
    source,
    /case 'equipment':\s*[^]*?if \(DEVICE_LIST_EVENTS\.has\(type\)[^]*?fetchDevices\(\);/,
  );
});

test('framing wizard validates coordinates before advancing to motion actions', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'js', 'app.js'),
    'utf8',
  );

  assert.match(
    source,
    /state\.wizardStep\[modalId\] === 0 && delta > 0[\s\S]*?!prepareFramingTargetForPreview\(\)/,
  );
  assert.match(
    source,
    /slew\.disabled = !hasCoordinates \|\| !state\.mountDeviceId/,
  );
  assert.match(
    source,
    /rotate\.disabled = !hasCoordinates \|\| !state\.rotatorDeviceId/,
  );
});

// `/api/sequencer/status` reports `progress` as a 0..1 FRACTION
// (`SequencerStatus.progress` — "Overall progress (0.0 to 1.0)"). A render
// path that feeds that fraction straight into a percent readout shows a
// finished run (progress 1.0) as "Progress 1%" with an empty bar,
// aria-valuenow="1" on a 0..100 progressbar, and an ETA that never reaches
// "complete". Execute the real helper so the math — not just its spelling —
// is pinned.
test('sequencer progress converts the 0..1 API fraction to percent', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'js', 'app.js'),
    'utf8',
  );

  const match = source.match(
    /function sequencerProgressPercent\(raw\) \{[\s\S]*?\n  \}/,
  );
  assert.ok(match, 'sequencerProgressPercent must exist');
  // eslint-disable-next-line no-new-func
  const toPercent = new Function(
    `${match[0]}; return sequencerProgressPercent;`,
  )();

  assert.equal(toPercent(1), 100, 'a finished run must read 100%');
  assert.equal(toPercent(0.9), 90);
  assert.equal(toPercent(0.1), 10);
  assert.equal(toPercent(0), 0, 'a run that HAS started and is at zero reads 0%');
  // Clamping + non-numeric input must never produce NaN%.
  assert.equal(toPercent(1.5), 100);
  assert.equal(toPercent(-1), 0);
  assert.equal(toPercent('0.42'), 42);
  // A wire that carries no figure gets null, never 0. `/api/sequencer/status`
  // withholds `progress` on a rig that has never run — the nulls
  // `/api/run-watch/snapshot` publishes there — and `Number(null)` is 0, so
  // returning 0 made both panels assert "Progress 0%" with aria-valuenow="0"
  // about a fresh install that had never exposed a frame.
  assert.equal(toPercent(null), null);
  assert.equal(toPercent(undefined), null);
  assert.equal(toPercent(''), null);
  assert.equal(toPercent('not a number'), null);

  // Both render paths must go through the helper rather than using the raw
  // fraction, and neither may reintroduce a bare `s.progress` percent.
  const renderers = [
    /function renderSequencerPanel\(\) \{[\s\S]*?\n  \}/,
    /function renderOpsSequencerLoadPanel\(\) \{[\s\S]*?\n  \}/,
  ];
  for (const re of renderers) {
    const body = source.match(re);
    assert.ok(body, `renderer ${re} must exist`);
    assert.match(body[0], /sequencerProgressPercent\(s\.progress\)/);
    assert.doesNotMatch(body[0], /=\s*s\.progress\s*!=\s*null/);
  }
});

// An observatory is routinely offline. Neither static surface may reference
// an external origin — a Google Fonts <link> costs a doomed DNS/TCP attempt
// and a CSP violation on every page load, because the server's own response
// header is `style-src 'self'`. Also: `frame-ancestors` is
// ignored when delivered via <meta> (browsers log an error) and belongs only in
// the response header.
test('static surfaces reference no external origins and no meta frame-ancestors', () => {
  const surfaces = [
    path.join(__dirname, '..', 'index.html'),
    path.join(__dirname, '..', '..', 'web_run_watch', 'index.html'),
  ];

  for (const file of surfaces) {
    const html = fs.readFileSync(file, 'utf8');
    const label = path.relative(path.join(__dirname, '..', '..'), file);

    assert.doesNotMatch(html, /fonts\.googleapis\.com/, `${label}: no font CDN`);
    assert.doesNotMatch(html, /fonts\.gstatic\.com/, `${label}: no font CDN`);
    assert.doesNotMatch(
      html,
      /(?:href|src)\s*=\s*["']https?:\/\//,
      `${label}: no absolute external asset URL`,
    );

    const csp = html.match(
      /<meta\s+http-equiv="Content-Security-Policy"\s+content="([^"]*)"/,
    );
    assert.ok(csp, `${label}: must declare a meta CSP`);
    assert.doesNotMatch(
      csp[1],
      /frame-ancestors/,
      `${label}: frame-ancestors is ignored in <meta>; use the response header`,
    );
    assert.match(csp[1], /style-src 'self'(?:;|$)/, `${label}: style-src self`);
    assert.match(csp[1], /font-src 'self'(?:;|$)/, `${label}: font-src self`);
  }
});

// `/api/images/<id>/thumbnail` 404s ("Image file not found") whenever the
// FITS behind a surviving DB row is gone. A failure path that hides the <img>
// collapses the gallery card's 100px media slot to a bare timestamp, so
// unreachable frames render as an unexplained list of dates.
test('gallery thumbnail failures keep the card and label the placeholder', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'js', 'app.js'),
    'utf8',
  );
  const css = fs.readFileSync(
    path.join(__dirname, '..', 'css', 'dashboard.css'),
    'utf8',
  );

  const helper = source.match(
    /function markGalleryThumbUnavailable\(img, reason\) \{[\s\S]*?\n  \}/,
  );
  assert.ok(helper, 'markGalleryThumbUnavailable must exist');
  // The placeholder must replace the <img> in the DOM, keep the sizing class,
  // and carry an accessible name.
  assert.match(helper[0], /gallery-thumb gallery-thumb-missing/);
  assert.match(helper[0], /replaceChild\(placeholder, img\)/);
  assert.match(helper[0], /aria-label/);
  assert.doesNotMatch(helper[0], /display\s*=\s*'none'/);

  // Both failure paths — the <img> onerror and the blob-fetch catch — must use
  // the helper, and neither may go back to hiding the element.
  const render = source.match(/function renderGallery\(\) \{[\s\S]*?\n  \}/);
  assert.ok(render, 'renderGallery must exist');
  assert.match(render[0], /img\.onerror = \(\) => markGalleryThumbUnavailable\(img\)/);

  // The parameter list is deliberately NOT pinned: the camera panel shares
  // this loader (and its two auth paths) while labelling failures in its own
  // markup, so the signature grew an optional `onUnavailable`. What must hold
  // is the CONTRACT — a failed thumbnail is labelled through a marker that
  // defaults to the gallery's own, and the element is never hidden.
  const loader = source.match(
    /async function loadGalleryThumbnail\([^)]*\) \{[\s\S]*?\n  \}/,
  );
  assert.ok(loader, 'loadGalleryThumbnail must exist');
  assert.match(
    loader[0],
    /const markUnavailable = onUnavailable \|\| markGalleryThumbUnavailable/,
    'the default labeller must still be the gallery helper',
  );
  assert.match(loader[0], /markUnavailable\(img, e\.message\)/);
  assert.doesNotMatch(loader[0], /img\.style\.display = 'none'/);

  // The placeholder needs real styling, otherwise the card collapses again.
  assert.match(css, /\.gallery-thumb-missing \{[\s\S]*?\}/);
  const rule = css.match(/\.gallery-thumb-missing \{([\s\S]*?)\}/)[1];
  assert.match(rule, /display:\s*flex/);
});

// Pairing codes are WORD-WORD-NNNN (TokenManager.generatePairingCode, e.g.
// STAR-LYRA-1234). A numeric 6-digit field — maxlength="6"
// pattern="[0-9]{6}" plus a /^\d{6}$/ guard — truncates a real code to
// "STAR-L" and then refuses to POST it at all, which leaves the surface's only
// pairing path impossible to complete with any input.
test('run-watch pairing accepts the real WORD-WORD-NNNN code format', () => {
  const root = path.join(__dirname, '..', '..', 'web_run_watch');
  const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
  const js = fs.readFileSync(path.join(root, 'js', 'run-watch.js'), 'utf8');

  const input = html.match(/<input\b[^>]*id="pair-code"[^>]*\/?>/s);
  assert.ok(input, 'pair-code input must exist');
  const attrs = input[0];
  assert.doesNotMatch(attrs, /inputmode="numeric"/, 'code is not numeric');
  assert.doesNotMatch(attrs, /maxlength="6"/, 'must not truncate a 14-char code');
  assert.doesNotMatch(attrs, /pattern="\[0-9\]\{6\}"/);
  assert.match(attrs, /maxlength="32"/);
  assert.match(attrs, /pattern="\[A-Za-z0-9-\]\{6,32\}"/);
  assert.match(attrs, /placeholder="STAR-LYRA-1234"/);

  // The client-side guard must admit the real format, and must match the
  // dashboard's pair-modal guard so the two surfaces never diverge again.
  assert.match(js, /\^\[A-Za-z0-9-\]\{6,32\}\$/);
  assert.doesNotMatch(js, /\^\\d\{6\}\$/);
  const dashJs = fs.readFileSync(
    path.join(__dirname, '..', 'js', 'app.js'), 'utf8',
  );
  assert.match(dashJs, /\^\[A-Za-z0-9-\]\{6,32\}\$/);

  // No surface may tell the operator the code is six digits.
  assert.doesNotMatch(html, /6-digit/i);
  assert.doesNotMatch(js, /6-digit/i);

  // Machine-readable server failures must be translated, not printed raw.
  assert.match(js, /function pairingErrorText\(data, status\)/);
  assert.match(js, /invalid_pairing_code/);
  assert.match(js, /pairing_code_expired/);
  assert.doesNotMatch(
    js,
    /statusEl\.textContent = data\.error \|\| data\.message/,
    'raw server error codes must not reach the status line',
  );
});

// The page CSP is `connect-src 'self' ws: wss:`, so the dashboard can only
// reach the origin that served it. Without an up-front check, a Server URL
// pointing at another host dismisses the login overlay, sits silent for ~6s
// inside the 3-attempt backoff, then flashes a 4s "Connection failed: Failed
// to fetch" toast — leaving the operator on a permanently Disconnected
// dashboard with no way back to the form short of a reload.
test('cross-origin server URLs are refused up front with a specific reason', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'js', 'app.js'),
    'utf8',
  );
  const html = fs.readFileSync(
    path.join(__dirname, '..', 'index.html'),
    'utf8',
  );

  const helper = source.match(
    /function isSameOriginServerUrl\(url\) \{[\s\S]*?\n  \}/,
  );
  assert.ok(helper, 'isSameOriginServerUrl must exist');
  // eslint-disable-next-line no-new-func
  const sameOrigin = new Function(
    'window',
    `${helper[0]}; return isSameOriginServerUrl;`,
  )({ location: { origin: 'http://host.local:8080',
                  href: 'http://host.local:8080/dashboard' } });
  assert.equal(sameOrigin('http://host.local:8080'), true);
  assert.equal(sameOrigin('http://host.local:8080/dashboard'), true);
  assert.equal(sameOrigin('http://192.168.1.20:8080'), false,
    'a different host must be refused');
  assert.equal(sameOrigin('http://host.local:9999'), false,
    'a different port is a different origin');
  assert.equal(sameOrigin('https://host.local:8080'), false,
    'a different scheme is a different origin');
  // A bare string resolves against the page as a relative path, which really
  // is same-origin. Callers pass normalizeServerUrl() output, which is already
  // guaranteed to be an absolute http(s) URL, so this case cannot reach here.
  assert.equal(sameOrigin('some/path'), true);

  // The overlay path must refuse BEFORE hiding itself, and the header Connect
  // path must refuse before entering the retry loop.
  const submit = source.match(
    /async function handleLoginSubmit\(\) \{[\s\S]*?\n  \}/,
  );
  assert.ok(submit, 'handleLoginSubmit must exist');
  const guardAt = submit[0].indexOf('isSameOriginServerUrl');
  const hideAt = submit[0].indexOf('hideLoginOverlay()');
  assert.ok(guardAt >= 0, 'overlay path must check the origin');
  assert.ok(hideAt >= 0 && guardAt < hideAt,
    'the origin check must run before the overlay is dismissed');

  const connect = source.match(/async function handleConnect\(\) \{[\s\S]*?\n  \}/);
  assert.ok(connect, 'handleConnect must exist');
  assert.match(connect[0], /isSameOriginServerUrl\(url\)/);
  assert.ok(
    connect[0].indexOf('isSameOriginServerUrl') <
      connect[0].indexOf('const delays'),
    'the origin check must precede the connect retry loop',
  );

  // And the page must declare an icon so the browser stops probing
  // /favicon.ico, which is unrouted and answers 401.
  assert.match(html, /<link rel="icon" href="data:image\/svg\+xml,/);
});
