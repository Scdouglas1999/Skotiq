/*
 * Skotiq Run-Watch — phone/tablet web client.
 *
 * Vanilla JS so the bundle stays tiny. Three concerns:
 *
 *  1. Credentials — three, in this order, because a browser already signed in
 *     to /dashboard/ on this origin must not be asked to authenticate twice:
 *       - this device's own pairing, in localStorage;
 *       - the bearer the dashboard left in this TAB's sessionStorage, adopted
 *         in memory and never persisted here;
 *       - the HttpOnly session cookie, confirmed by GET /api/auth/csrf and
 *         carried by the browser itself.
 *     With none of the three, the pairing wall: request a WORD-WORD-NNNN code
 *     via /api/pairing/start (which puts it on the rig, never on the wire —
 *     see PairingHandlers), read it off the rig, /api/pairing/verify.
 *
 *  2. Live data — once authenticated:
 *       - fetch /api/run-watch/snapshot every 15s as a baseline, on reconnect,
 *         and on every frame event so the frame counter keeps step with the
 *         feed rendered beside it,
 *       - subscribe to /api/run-watch/events (SSE) for the firehose,
 *       - poll /api/run-watch/frame-thumbnail when a FrameAccepted /
 *         ExposureFinished event arrives, plus every 10s as a fallback
 *         so the panel never goes stale.
 *
 *  3. Controls — POST to existing /api/sequencer/{pause,resume,skip,stop}
 *     so we don't duplicate any backend logic.
 */
'use strict';

// ---------------------------------------------------------------------------
// Auth + storage
// ---------------------------------------------------------------------------
const STORAGE_TOKEN_KEY = 'skotiq.runwatch.token';
const STORAGE_DEVICE_ID_KEY = 'skotiq.runwatch.deviceId';
const STORAGE_OPTS_KEY = 'skotiq.runwatch.opts';
/// Whether the token this device holds has ever been ACCEPTED by the desktop.
/// A pairing exchange mints one that is accepted by construction; a token typed
/// into the manual box has been accepted by nothing until a request carrying it
/// comes back 2xx. Persisted so the answer survives a reload — a phone that
/// watched a whole night on a typed token and then meets a 401 has met a
/// revocation, not a typo.
const STORAGE_TOKEN_ACCEPTED_KEY = 'skotiq.runwatch.tokenAccepted';

function getToken() {
  try { return localStorage.getItem(STORAGE_TOKEN_KEY); } catch { return null; }
}

/// Store a token and what is known about it.
///
/// [accepted] is true when the credential arrives already proven — the pairing
/// endpoint answered with it — and false for one the operator typed, which the
/// desktop has not seen yet.
function setToken(t, accepted) {
  inMemoryTokenAccepted = Boolean(t) && Boolean(accepted);
  authRefusalStated = false;
  clearControlRefusals();
  try {
    if (t) {
      localStorage.setItem(STORAGE_TOKEN_KEY, t);
      localStorage.setItem(
        STORAGE_TOKEN_ACCEPTED_KEY, accepted ? 'true' : 'false');
    } else {
      localStorage.removeItem(STORAGE_TOKEN_KEY);
      localStorage.removeItem(STORAGE_TOKEN_ACCEPTED_KEY);
    }
  } catch { /* private mode — fall back to in-memory */ inMemoryToken = t || null; }
}
let inMemoryToken = null;
let inMemoryTokenAccepted = false;
/// True once a refusal has torn this credential down and said so.
///
/// `bootSession` fires the snapshot, the frame poll and the SSE subscription
/// together, so a refused credential produces several 401s within a tick. The
/// first tears the token down; without this guard the ones already in flight
/// re-decided the sentence from a flag the first had just cleared, and an
/// accepted-then-revoked pairing ended up described as a token that was never
/// accepted — measured on the running bundle after a reload.
let authRefusalStated = false;
function effectiveToken() {
  return getToken() || inMemoryToken || adoptedBearer;
}

// ---------------------------------------------------------------------------
// Credentials this browser is already carrying
//
// An operator who signs in on /dashboard/ and taps the dashboard's own
// Run-Watch link is authenticated to this origin already, and used to land on
// the pairing wall: measured on the release bundle, the dashboard read
// "Connected", its bearer sat in this tab's sessionStorage, and this page
// asked for a pairing code from a screen the rig may not even have. Two
// credential models that never handed off.
//
// So this page reads the two the dashboard actually leaves behind, in the
// dashboard's own storage and with the dashboard's own lifetime. Neither is
// copied into this page's localStorage: a bearer the dashboard deliberately
// keeps in sessionStorage — the operator left "remember me" off — stays there
// and dies with the tab, and the session cookie stays HttpOnly and unreadable.
//
// Nothing here mints, guesses or widens a credential. A browser that has not
// signed in has no sessionStorage bearer and no session cookie, `GET
// /api/auth/csrf` answers it 401, and it meets the pairing wall exactly as
// before; every /api/run-watch/* read still carries a credential the server
// verifies for itself.
// ---------------------------------------------------------------------------

/// The key the dashboard keeps its bearer under, for this tab only — see
/// `setStoredToken` in web_dashboard/js/app.js, which writes sessionStorage and
/// scrubs the localStorage copy on every write.
const DASHBOARD_TAB_TOKEN_KEY = 'skotiq_token';

/// A bearer adopted from the dashboard's sessionStorage. Held for this page
/// load only, so the dashboard's own "do not remember me" keeps meaning what
/// it says.
let adoptedBearer = null;

/// The CSRF token bound to the HttpOnly session cookie this browser carries,
/// when it carries one. In memory only: the cookie is unreadable from JS, and
/// this token is what proves a write came from this page.
let sessionCsrfToken = null;

/// Where the credential in use came from: `'paired'`, `'dashboard-tab'` or
/// `'session-cookie'`. Read when a refusal has to be explained — a withdrawn
/// pairing, an ended dashboard session and a mistyped token are three different
/// events and only one of them is worth walking to the rig for.
let credentialSource = 'paired';

/// The bearer the dashboard left in this tab, or null.
function dashboardTabBearer() {
  try {
    return sessionStorage.getItem(DASHBOARD_TAB_TOKEN_KEY) || null;
  } catch {
    // No sessionStorage (private mode, or a host that does not provide one).
    return null;
  }
}

/// Drop every credential this page holds.
///
/// Called when the server refuses one: leaving the others in place would
/// re-fire the same refusal on the next poll under a different name.
function forgetAllCredentials() {
  setToken(null);
  adoptedBearer = null;
  sessionCsrfToken = null;
  credentialSource = 'paired';
  clearControlRefusals();
}

/// True when the token this device holds has been accepted by the desktop at
/// least once. Read before the 401/403 copy is chosen: it is the difference
/// between a pairing that was withdrawn and one that never existed.
function tokenWasEverAccepted() {
  try {
    if (localStorage.getItem(STORAGE_TOKEN_ACCEPTED_KEY) === 'true') return true;
  } catch { /* private mode — the in-memory answer below is all there is */ }
  return inMemoryTokenAccepted;
}

/// Record that the desktop honoured the credential this device is carrying.
/// Called on the first successful exchange, so a typed token that works stops
/// being described as unproven from then on.
function noteTokenAccepted() {
  if (inMemoryTokenAccepted) return;
  inMemoryTokenAccepted = true;
  try { localStorage.setItem(STORAGE_TOKEN_ACCEPTED_KEY, 'true'); } catch { /* in-memory only */ }
}

function getOrCreateDeviceId() {
  let id;
  try { id = localStorage.getItem(STORAGE_DEVICE_ID_KEY); } catch { id = null; }
  if (id) return id;
  // crypto.randomUUID is widely supported on modern mobile browsers;
  // fall back to a Math.random-based id otherwise (good enough for a
  // device handle that's only used to label the paired-devices table).
  const fresh = (window.crypto && crypto.randomUUID)
    ? crypto.randomUUID()
    : 'web-' + Math.random().toString(36).slice(2, 10);
  try { localStorage.setItem(STORAGE_DEVICE_ID_KEY, fresh); } catch { /* ignore */ }
  return fresh;
}

function loadOpts() {
  try {
    const raw = localStorage.getItem(STORAGE_OPTS_KEY);
    return raw ? JSON.parse(raw) : {};
  } catch { return {}; }
}
function saveOpts(opts) {
  try { localStorage.setItem(STORAGE_OPTS_KEY, JSON.stringify(opts)); } catch { /* ignore */ }
}

// ---------------------------------------------------------------------------
// Fetch helpers — all requests carry the bearer token automatically.
//
// Two cross-cutting concerns live here rather than in each caller:
//
//  * Rate limiting. The server budgets 60 reads/s per token
//    (`defaultTokenBucketConfigs`) and answers a denial with 429 +
//    `retryAfterSecs` + a `retry-after` header. This page shares that budget
//    with every other tab the operator has open, so a 429 is a normal thing to
//    meet, not a bug. Every request goes through one gate that honours the
//    server's own retry window; nothing here retries inside it, and the raw
//    429 body never reaches the screen.
//
//  * Link health. Whether the last exchange with the server succeeded is the
//    one fact the rest of the page cannot render honestly without, so it is
//    recorded on every call rather than at each call site.
// ---------------------------------------------------------------------------

/// Epoch ms before which no request may be sent, set from the server's own
/// `retryAfterSecs`. Zero means the budget is not exhausted.
let rateLimitedUntil = 0;

/// Typed refusals raised by [apiFetch] and by the snapshot render. Callers
/// switch on `error.kind` rather than on message text.
///
/// The kinds, and what each one says about the link:
///   'auth_required'   — the desktop no longer accepts this pairing.
///   'scope_denied'    — the desktop DOES accept this pairing and will not let
///                       it do this. A different event from 'auth_required',
///                       and the credential survives it.
///   'unreachable'     — no answer arrived; the server may be gone.
///   'rate_limited'    — the server answered, asking us to slow down. Healthy.
///   'http_error'      — the server answered with a status it named. Healthy.
///   'unusable_answer' — the server answered and the answer is not a snapshot
///                       this page can render. The exchange FAILED: nothing
///                       was learned from it, so it may not reset the
///                       staleness clock.
class ApiError extends Error {
  constructor(kind, message, detail) {
    super(message);
    this.kind = kind;
    this.detail = detail || {};
  }
}

function rateLimitRemainingSecs() {
  const ms = rateLimitedUntil - Date.now();
  return ms > 0 ? Math.ceil(ms / 1000) : 0;
}

/// Read the server's retry window off a 429. Prefers the JSON body's
/// `retryAfterSecs` (rate_limit_middleware `_denyRateLimited`), falls back to
/// the `retry-after` header, and finally to one second — the smallest window
/// the server ever asks for.
async function retryAfterSecsFrom(res) {
  let secs = null;
  try {
    const body = await res.clone().json();
    const raw = body && (body.retryAfterSecs ?? body.retryAfterSeconds);
    if (typeof raw === 'number' && isFinite(raw) && raw > 0) secs = raw;
  } catch { /* body is not the JSON shape we know — fall through */ }
  if (secs == null) {
    const header = Number(res.headers.get('retry-after'));
    if (isFinite(header) && header > 0) secs = header;
  }
  return secs == null ? 1 : Math.min(Math.ceil(secs), 300);
}

/// Why this device is back at the pairing wall, in the operator's own terms.
///
/// The credential that was refused decides the sentence. A pairing the desktop
/// withdrew is worth walking to the rig for; a dashboard session that ended in
/// this browser is worth signing in again for; a token typed into the box below
/// is worth re-reading. Keying on `token ?` alone told a device that had only
/// ever mistyped a token that its pairing "was revoked" — a diagnosis of an
/// event that never happened.
///
/// [credentialSource] is the source in use, [token] the credential that was
/// refused (null when this device was carrying none), and [wasAccepted] whether
/// the desktop had ever honoured it.
function credentialRefusalText(source, token, wasAccepted) {
  if (source === 'session-cookie') {
    return 'This browser\'s Skotiq session has ended. Sign in again on the '
      + 'dashboard, or pair this device with a code.';
  }
  if (source === 'dashboard-tab') {
    return 'The dashboard session this tab was using is no longer accepted. '
      + 'Sign in again on the dashboard, or pair this device with a code.';
  }
  if (!token) return null;
  return wasAccepted
    ? 'This device\'s pairing is no longer accepted — the rig rejected it, '
      + 'which happens when the pairing was revoked there or the profile it '
      + 'belonged to was replaced. Pair again with a fresh code.'
    : 'That token was not accepted. Check it against the rig, or pair with a '
      + 'code instead.';
}

/// What the rig's refusal actually was — a credential it will not accept, or a
/// credential it accepts and will not let do this.
///
/// These are two different events and this page must not treat them alike. A
/// 401 says the credential was not accepted at all: the pairing was withdrawn,
/// the browser session ended, the token was mistyped, and the only way forward
/// is a new credential. A scope refusal says the opposite — the credential IS
/// accepted, and this particular action is above what it holds. Deleting a
/// working credential and ejecting the viewer from a live run over a button
/// they were never entitled to press is destroying something that works to
/// report something that never happened.
///
/// The status alone does not settle it: the rig answers an unknown bearer with
/// 403 as well (`auth_middleware`'s "Invalid authentication token"). What
/// distinguishes a scope refusal is that it NAMES the requirement it refused
/// on — `requiredResource` + `requiredLevel`, from
/// `HeadlessAuthPolicy.scopeDenialBody` — so that is what is keyed on here.
/// Every other 401/403, named or not, is still a credential this rig will not
/// accept, and is still torn down.
///
/// Returns the parsed refusal detail for a scope refusal, or null.
async function scopeRefusalDetail(res) {
  if (res.status !== 403) return null;
  let body;
  try { body = await res.clone().json(); } catch { return null; }
  if (!body || typeof body !== 'object') return null;
  const resource = body.requiredResource;
  const requiredLevel = body.requiredLevel;
  if (typeof resource !== 'string' || !resource) return null;
  if (typeof requiredLevel !== 'string' || !requiredLevel) return null;
  const tokenLevel = typeof body.tokenLevel === 'string' ? body.tokenLevel : null;
  return { resource, requiredLevel, tokenLevel, status: res.status };
}

/// The rig's own account of a scope refusal, in the operator's terms.
///
/// Every clause comes off the wire: the resource the endpoint guards, the
/// level it demands, and the level this credential holds on it. Nothing here
/// guesses at a level the server did not state — an older rig that sends no
/// `tokenLevel` gets a sentence that simply omits it.
function scopeRefusalText(label, detail) {
  const held = detail.tokenLevel === 'none'
    ? 'no access to ' + detail.resource
    : detail.tokenLevel
      ? detail.tokenLevel + ' access to ' + detail.resource
      : null;
  const opening = held
    ? 'This device has ' + held + '.'
    : 'This device is not permitted here.';
  return label + ' needs ' + detail.requiredLevel + ' access to '
    + detail.resource + '. ' + opening
    + ' Pair this device again asking for '
    + detail.resource + ':' + detail.requiredLevel
    + ' to use it. The pairing you have still works for watching.';
}

async function apiFetch(path, opts) {
  opts = opts || {};
  const waiting = rateLimitRemainingSecs();
  if (waiting > 0) {
    throw new ApiError(
      'rate_limited',
      'Server is rate-limiting this device',
      { retryAfterSecs: waiting },
    );
  }
  const headers = new Headers(opts.headers || {});
  const token = effectiveToken();
  const method = String(opts.method || 'GET').toUpperCase();
  if (token) {
    headers.set('Authorization', 'Bearer ' + token);
  } else if (sessionCsrfToken && method !== 'GET' && method !== 'HEAD') {
    // Cookie path: the browser attaches the HttpOnly session cookie to these
    // same-origin requests itself. A write must additionally echo the CSRF
    // token the server bound to that cookie — that echo is what tells the
    // server the request came from this page rather than from a site that
    // tricked the browser into sending the cookie ambient-style.
    headers.set('X-Skotiq-CSRF', sessionCsrfToken);
  }
  if (opts.body && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json');
  }
  let res;
  try {
    res = await fetch(path, Object.assign(
      // Same-origin credentials are stated rather than left to the default so
      // the cookie path does not depend on which default a browser ships.
      { credentials: 'same-origin' }, opts, { headers }));
  } catch (e) {
    // A transport failure is the signal that the server is gone. It is the
    // only evidence this page ever gets that a run it is painting as
    // "running" may have stopped minutes ago.
    noteLinkFailure('unreachable', e && e.message ? e.message : String(e));
    throw new ApiError('unreachable', 'Cannot reach the server', {
      cause: e,
    });
  }
  if (res.status === 401 || res.status === 403) {
    // A scope refusal is NOT a revoked pairing — see [scopeRefusalDetail].
    // The credential stays exactly where it is, the viewer stays on the run,
    // and the caller is handed the rig's own account of what it lacked.
    const scope = await scopeRefusalDetail(res);
    if (scope) {
      // The rig honoured this credential enough to tell us what it is short
      // of, which is the same proof of acceptance a 2xx is.
      if (token && credentialSource === 'paired') noteTokenAccepted();
      rateLimitedUntil = 0;
      throw new ApiError(
        'scope_denied',
        'This device is not permitted to do that',
        scope,
      );
    }
    // Tokens can be revoked desktop-side; force re-pair. The reason goes ON
    // THE SCREEN, not only into the thrown error — nothing catches
    // 'auth_required' to render it, which is how this landed as a silent
    // logout.
    //
    // WHICH reason depends on where the credential came from, not on whether
    // one exists. Keying on `token ?` told a device that had never paired —
    // one whose operator had just mistyped a token into the manual box — that
    // its pairing "is no longer accepted… revoked… or the profile it belonged
    // to was replaced", a diagnosis of an event that never happened, and it
    // sent them to the desktop for a fresh code they did not need.
    if (!authRefusalStated) {
      const reason = credentialRefusalText(
        credentialSource, token, tokenWasEverAccepted());
      forgetAllCredentials();
      authRefusalStated = true;
      showPairScreen(reason);
    }
    throw new ApiError('auth_required', 'Pairing is no longer accepted');
  }
  if (res.status === 429) {
    const secs = await retryAfterSecsFrom(res);
    rateLimitedUntil = Date.now() + secs * 1000;
    noteLinkFailure('rate_limited', 'retry in ' + secs + 's');
    throw new ApiError(
      'rate_limited',
      'Server is rate-limiting this device',
      { retryAfterSecs: secs },
    );
  }
  // Any answer at all — including a 4xx/5xx — proves the server is there.
  rateLimitedUntil = 0;
  // A 2xx carrying this credential is the rig honouring it. That is the one
  // moment a typed token stops being unproven, and it is what lets a later
  // refusal be described as a revocation rather than as a typo.
  //
  // Only for THIS device's own credential. A bearer borrowed from the
  // dashboard's tab has no entry in this page's storage to annotate, and
  // recording it accepted left an orphan `tokenAccepted: true` behind — a flag
  // that would later describe a token this device never held as a pairing that
  // had been withdrawn.
  if (token && res.ok && credentialSource === 'paired') noteTokenAccepted();
  return res;
}

async function apiJson(path, opts) {
  const res = await apiFetch(path, opts);
  if (!res.ok) {
    let body;
    try { body = await res.json(); } catch { body = await res.text(); }
    throw new ApiError('http_error', typeof body === 'string'
      ? `${path} ${res.status}: ${body}`
      : `${path} ${res.status}: ${body.error || JSON.stringify(body)}`,
      { status: res.status });
  }
  // A 200 whose body will not parse is a failed exchange wearing a success
  // code. Left as a bare SyntaxError it reached the caller with no `kind`,
  // which is the one shape the caller has no case for.
  try {
    return await res.json();
  } catch (e) {
    throw new ApiError(
      'unusable_answer',
      `${path} answered ${res.status} with a body that is not JSON`,
      { status: res.status, cause: e },
    );
  }
}

/// Response body of a control POST, or null when the server sent none. A
/// control button must report the server's own answer, and that answer is in
/// the body, not in the status code.
async function apiJsonOrNull(res) {
  try { return await res.json(); } catch { return null; }
}

// ---------------------------------------------------------------------------
// UI helpers
// ---------------------------------------------------------------------------
function $(id) { return document.getElementById(id); }

function toast(message, kind) {
  kind = kind || 'info';
  const region = $('toast-region');
  if (!region) return;
  const el = document.createElement('div');
  el.className = 'toast toast-' + kind;
  el.textContent = message;
  region.appendChild(el);
  setTimeout(() => {
    el.style.opacity = '0';
    el.style.transition = 'opacity 0.2s';
    setTimeout(() => { try { region.removeChild(el); } catch {} }, 250);
  }, 3000);
}

function setConnectionState(state) {
  const dot = $('connection-dot');
  if (!dot) return;
  dot.classList.remove('conn-connected', 'conn-disconnected', 'conn-reconnecting');
  if (state === 'connected') {
    dot.classList.add('conn-connected');
    dot.title = 'Connected';
  } else if (state === 'reconnecting') {
    dot.classList.add('conn-reconnecting');
    dot.title = 'Reconnecting…';
  } else {
    dot.classList.add('conn-disconnected');
    dot.title = 'Disconnected';
  }
}

// ---------------------------------------------------------------------------
// Link health
//
// A phone left on the nightstand shows whatever the last successful snapshot
// said. Before this block that picture kept its green "running" badge for as
// long as the tab stayed open, however long ago the server had died — the only
// tell was an 8px dot's hover title, which a phone has no way to show. The
// state below is what lets the page say plainly that it has lost contact, and
// how stale what it is showing has become.
// ---------------------------------------------------------------------------

// Poll cadences. Declared here because the staleness threshold is derived
// from the snapshot interval and both are read by the watchdog below.
const SNAPSHOT_INTERVAL_MS = 15000;
const FRAME_FALLBACK_MS = 10000;

/// Epoch ms of the last snapshot the server actually answered. 0 = never.
let lastSnapshotAt = 0;
/// Epoch ms this session started polling, so "nothing yet" can be told apart
/// from "nothing for longer than a poll interval".
let sessionStartedAt = 0;
/// Non-null while the link is known bad: `{kind, detail}`.
let linkFailure = null;
/// The sequencer state the last good snapshot reported, kept so the banner can
/// name what is going stale without the badge continuing to assert it.
let lastKnownState = null;
let staleWatchdogTimer = null;

// One snapshot interval plus a poll's worth of slack. Past this the page has
// missed a scheduled exchange and must stop presenting its cache as live.
const SNAPSHOT_STALE_MS = SNAPSHOT_INTERVAL_MS + 5000;
const STALE_WATCHDOG_MS = 2000;

/// Record an exchange that TAUGHT this page something: a snapshot arrived and
/// was rendered. Called after the render, never before it — a 200 is not a
/// snapshot until one has been applied.
function noteLinkOk() {
  lastSnapshotAt = Date.now();
  linkFailure = null;
}

function noteLinkFailure(kind, detail) {
  linkFailure = { kind, detail: detail || '' };
}

/// Failure kinds after which this page knows nothing current, whatever the
/// clock says. A refused connection and an answer that is not a snapshot both
/// leave the screen holding a cache nobody has confirmed; a 429 does not,
/// because the server that sent it is demonstrably alive and will answer the
/// next poll.
const UNVOUCHABLE_FAILURE_KINDS = new Set([
  'unreachable', 'unusable_answer', 'scope_denied',
]);

/// True when this page cannot vouch for what it is showing: either the last
/// exchange failed outright, or no exchange has succeeded within a poll
/// interval.
function isLinkStale() {
  if (linkFailure && UNVOUCHABLE_FAILURE_KINDS.has(linkFailure.kind)) return true;
  // Nothing answered yet: the first exchange gets one poll interval to land
  // before "still loading" becomes "no contact". A failed first fetch does not
  // wait — it is already caught above.
  if (lastSnapshotAt === 0) {
    return sessionStartedAt > 0 && Date.now() - sessionStartedAt > SNAPSHOT_STALE_MS;
  }
  return Date.now() - lastSnapshotAt > SNAPSHOT_STALE_MS;
}

function formatAge(ms) {
  const s = Math.round(ms / 1000);
  if (s < 60) return s + 's';
  const m = Math.floor(s / 60);
  if (m < 60) return m + 'm ' + (s % 60) + 's';
  return Math.floor(m / 60) + 'h ' + (m % 60) + 'm';
}

/// Repaint the banner + badge + dot from the current link state. Called on
/// every snapshot outcome and on the watchdog tick, so the page can never sit
/// green past a missed poll.
function renderLinkState() {
  const banner = $('link-banner');
  const badge = $('state-badge');
  const stale = isLinkStale();
  const waiting = rateLimitRemainingSecs();

  if (!stale) {
    if (banner) {
      if (waiting > 0) {
        // The link is alive; the server is only asking us to slow down. Say
        // that instead of the raw 429 body.
        banner.classList.remove('hidden');
        banner.textContent =
          'Server is rate-limiting this device — next update in ' +
          waiting + 's.';
      } else {
        banner.classList.add('hidden');
        banner.textContent = '';
      }
    }
    return;
  }

  // Stale: the badge must stop asserting a state nobody has confirmed.
  if (badge) {
    badge.textContent = 'unknown';
    badge.className = 'badge badge-error';
  }
  // The percentage is the same assertion in another shape, and it outlived
  // the badge: measured after a SIGTERM at wire progress 0.05, the badge went
  // "unknown" and the banner said every value below might be wrong while "5%"
  // stayed on screen, the bar stayed 5% wide and aria-valuenow kept announcing
  // 5 for the next 45 s. The dashboard's `paintRunUnknown` settled the stance
  // for the same loss — "a figure whose source is gone is not a smaller truth
  // than a state whose source is gone" — and this is that stance, here.
  paintProgressUnknown();
  // A control whose precondition nobody can confirm is not offerable either.
  updateRunControls('unknown');
  setConnectionState('disconnected');

  const age = lastSnapshotAt === 0 ? null : Date.now() - lastSnapshotAt;
  const failedKind = linkFailure ? linkFailure.kind : null;
  // Each lead names what actually happened. "Cannot reach" would be a lie
  // about a server that answered; "no answer" would be a lie about a body
  // that arrived and could not be read.
  let lead;
  if (failedKind === 'unreachable') {
    lead = 'Cannot reach the observatory server.';
  } else if (failedKind === 'unusable_answer') {
    lead = 'The observatory server answered with something this page cannot '
      + 'read.';
  } else if (failedKind === 'scope_denied') {
    // The server is demonstrably there and this credential is demonstrably
    // accepted, so neither "cannot reach" nor "no answer" would be true. The
    // refusal itself is the lead, in the server's own terms.
    lead = linkFailure.detail;
  } else {
    lead = 'No answer from the observatory server.';
  }
  const since = age == null
    ? ' No update has arrived since this page opened.'
    : ' Last update ' + formatAge(age) + ' ago' +
      (lastKnownState ? ' (state was "' + lastKnownState + '")' : '') +
      '. The values below are from then and may be wrong.';
  if (banner) {
    banner.classList.remove('hidden');
    banner.textContent = lead + since;
  }
}

function startStaleWatchdog() {
  stopStaleWatchdog();
  staleWatchdogTimer = setInterval(renderLinkState, STALE_WATCHDOG_MS);
}

function stopStaleWatchdog() {
  if (staleWatchdogTimer) {
    clearInterval(staleWatchdogTimer);
    staleWatchdogTimer = null;
  }
}

/// Show the pair screen, saying WHY when this device has just lost a pairing
/// it had.
///
/// A device whose token the desktop revoked was dropped here silently: the
/// screen it landed on was byte-for-byte the one a browser that had never
/// paired gets (verified — the two screenshots hashed identically), with
/// `#pair-status` empty and the thrown 'Pairing is no longer accepted' reaching
/// nothing. From bed that reads as "the app forgot me", and the next move —
/// walk to the desktop for a fresh code — is the one thing it did not say.
///
/// [reason] is that sentence, and [tone] is `'error'` for something that
/// happened TO this device and `'info'` for something the operator did. Absent
/// (first run) the line is cleared rather than left holding the last one.
function showPairScreen(reason, tone) {
  $('pair-screen').classList.remove('hidden');
  $('main-screen').classList.add('hidden');
  const statusEl = $('pair-status');
  if (statusEl) {
    statusEl.textContent = reason || '';
    statusEl.className = reason
      ? 'pair-status ' + (tone || 'error')
      : 'pair-status';
  }
  closeSSE();
  stopPolling();
}

function showMainScreen() {
  $('pair-screen').classList.add('hidden');
  $('main-screen').classList.remove('hidden');
  bootSession();
}

/// Open on the screen the credentials in this browser justify.
///
/// In order: the pairing this device completed for itself; the bearer the
/// dashboard left in this tab; the HttpOnly session cookie, whose presence only
/// the server can confirm. The wall is what is left when all three are absent.
async function resolveCredentialAndShow() {
  if (getToken() || inMemoryToken) {
    credentialSource = 'paired';
  } else if (dashboardTabBearer()) {
    adoptedBearer = dashboardTabBearer();
    credentialSource = 'dashboard-tab';
  } else if (await adoptSessionCookie()) {
    credentialSource = 'session-cookie';
  } else {
    showPairScreen();
    return;
  }
  showMainScreen();
  applyWakeLockOption();
}

/// Ask the server whether this browser is carrying a live session cookie.
///
/// The cookie is HttpOnly, so its presence is not a question JS can answer for
/// itself: `GET /api/auth/csrf` answers 200 with the bound CSRF token when
/// there is a session and 401 when there is not. Deliberately not routed
/// through [apiFetch] — a 401 here is the ordinary answer for a browser that
/// has never signed in, and apiFetch would turn it into a refusal notice about
/// a credential this device never had.
async function adoptSessionCookie() {
  try {
    const res = await fetch('/api/auth/csrf', { credentials: 'same-origin' });
    if (!res.ok) return false;
    const body = await res.json();
    const csrf = body && typeof body.csrfToken === 'string' ? body.csrfToken : '';
    if (!csrf) return false;
    sessionCsrfToken = csrf;
    return true;
  } catch {
    // No answer at all. The pairing wall is the honest landing: this page
    // cannot show a run it cannot read.
    return false;
  }
}

/// Revoke the HttpOnly session cookie this browser is signed in with.
///
/// The cookie is the whole browser's credential, not this tab's, so the caller
/// has to say out loud that the dashboard goes with it.
async function endSessionCookie() {
  try {
    await apiFetch('/api/auth/logout', { method: 'POST', body: '{}' });
  } catch {
    // Best-effort: the credential is dropped client-side either way below.
  }
}

// ---------------------------------------------------------------------------
// Pairing flow
// ---------------------------------------------------------------------------
// Map the server's machine-readable pairing failures onto something an
// operator standing at the telescope can act on. Without this the raw code
// ("invalid_pairing_code") was printed straight into the status line. Mirrors
// the dashboard's handlePairSubmit mapping.
function pairingErrorText(data, status) {
  const raw = String((data && (data.error || data.message)) || '');
  if (raw.includes('invalid_pairing_code')) {
    return 'Pairing code is not recognised. Check it against the rig.';
  }
  if (raw.includes('pairing_code_expired')) {
    return 'Pairing code expired. Request a new one.';
  }
  if (raw.includes('pairing_code_already_used')) {
    return 'That code has already been claimed. Request a new one.';
  }
  if (status === 429 || raw.includes('temporarily locked')) {
    return 'Too many failed attempts. Wait a moment before trying again.';
  }
  return raw || 'Pairing failed.';
}

/// Where the code this request just made actually went, from the server's own
/// answer.
///
/// The code itself is never in that answer — it never leaves the rig — so this
/// sentence is the whole of what the page can tell the operator, and it has to
/// name a place that exists on the rig it is talking to. `codeDelivery` reports
/// whether the owner-only file was written (it can fail: an appliance with no
/// resolvable support directory writes nothing) and whether the host was
/// started with console printing on.
function codeDeliveryText(data) {
  const delivery = data && typeof data.codeDelivery === 'object'
    ? data.codeDelivery : null;
  if (!delivery) {
    // A server that does not report where it put the code. Naming a place on
    // its behalf would be a guess, so the standing copy below the button —
    // which names every place this project's hosts use — is what stands.
    return 'Read it on the rig, as described below.';
  }
  const places = [];
  if (delivery.operatorFile) {
    const name = typeof delivery.operatorFileName === 'string' &&
      delivery.operatorFileName ? delivery.operatorFileName : 'pairing-code.txt';
    places.push(name + ' in the rig\'s Skotiq support folder');
  }
  if (delivery.console) places.push('the rig\'s console output');
  if (places.length === 0) {
    return 'The rig could not put it anywhere readable. Restart the host with '
      + '--pairing-print-codes, or read the token off the host and use the '
      + 'manual box below.';
  }
  return 'Read it from ' + places.join(', or ') + '.';
}

/// Ask the rig to make a pairing code.
///
/// The wall used to have no such control at all: it named a code source and
/// offered nothing that caused a code to exist, which on a headless appliance
/// left the operator with no reachable next step.
async function requestPairingCode() {
  const statusEl = $('pair-status');
  const btn = $('btn-request-code');
  statusEl.className = 'pair-status';
  statusEl.textContent = 'Asking the rig for a code…';
  if (btn) btn.disabled = true;
  try {
    const res = await fetch('/api/pairing/start', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: '{}',
    });
    let data = null;
    try { data = await res.json(); } catch { /* refusal without a JSON body */ }
    if (!res.ok) {
      statusEl.textContent = pairingErrorText(data, res.status);
      statusEl.classList.add('error');
      return;
    }
    const secs = wireNumber(data && data.expiresInSeconds);
    const window = secs == null
      ? 'It expires shortly.'
      : 'It expires in about ' + Math.max(1, Math.round(secs / 60)) + ' min.';
    statusEl.textContent =
      'A code is now waiting on the rig. ' + codeDeliveryText(data) + ' ' +
      window;
    statusEl.classList.add('info');
  } catch (e) {
    statusEl.textContent = 'Could not reach the rig to ask for a code: ' +
      (e && e.message ? e.message : String(e));
    statusEl.classList.add('error');
  } finally {
    if (btn) btn.disabled = false;
  }
}

async function startPairing(code) {
  const trimmed = (code || '').trim();
  const statusEl = $('pair-status');
  statusEl.className = 'pair-status';
  // Codes are WORD-WORD-NNNN (TokenManager.generatePairingCode), never six
  // digits. Keep this in step with the dashboard's pair-modal guard.
  if (!/^[A-Za-z0-9-]{6,32}$/.test(trimmed)) {
    statusEl.textContent =
      'Enter the pairing code from the rig (like STAR-LYRA-1234).';
    statusEl.classList.add('error');
    return;
  }

  statusEl.textContent = 'Pairing…';

  try {
    const body = JSON.stringify({
      code: trimmed,
      deviceId: getOrCreateDeviceId(),
      deviceName: deviceLabel(),
      deviceType: 'browser',
    });
    const res = await fetch('/api/pairing/verify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
    });
    const data = await res.json();
    // The field is `token` — that is what `handlePairingVerify` answers with
    // and what the dashboard's own pair modal reads. Reading `sessionToken`
    // (the server's INTERNAL name for it, never a wire name) meant a pairing
    // the server had just completed was reported to the operator as "Pairing
    // failed." and the minted token thrown away: driven end-to-end against the
    // release bundle with a code read out of the rig's own pairing-code.txt,
    // the exchange answered 200 with a control-scoped token and this screen
    // stayed on the wall.
    const minted = data && typeof data.token === 'string' ? data.token : '';
    if (!res.ok) {
      statusEl.textContent = pairingErrorText(data, res.status);
      statusEl.classList.add('error');
      return;
    }
    if (!minted) {
      // A 2xx with no token is not a pairing, and it is not the operator's
      // typing either — say which of the two happened.
      statusEl.textContent = 'The rig accepted the code but sent no token back. '
        + 'Request a fresh code and try again.';
      statusEl.classList.add('error');
      return;
    }
    // The pairing endpoint minted this token and answered with it, so the rig
    // has already accepted it. It is this device's own credential from here on,
    // whatever it was watching with before.
    setToken(minted, true);
    adoptedBearer = null;
    sessionCsrfToken = null;
    credentialSource = 'paired';
    statusEl.textContent = 'Paired successfully.';
    statusEl.classList.add('success');
    showMainScreen();
  } catch (e) {
    statusEl.textContent = 'Network error: ' + e.message;
    statusEl.classList.add('error');
  }
}

function deviceLabel() {
  // The desktop's paired-device row should show something the operator
  // recognises — phone/tablet/browser model is good enough.
  const ua = navigator.userAgent || 'web';
  // Try to extract a brand+OS hint without dragging in a full parser.
  let label = 'Web';
  if (/iphone/i.test(ua)) label = 'iPhone';
  else if (/ipad/i.test(ua)) label = 'iPad';
  else if (/android/i.test(ua)) label = 'Android phone';
  else if (/macintosh/i.test(ua)) label = 'Mac browser';
  else if (/windows/i.test(ua)) label = 'Windows browser';
  return label + ' · Run-Watch';
}

// ---------------------------------------------------------------------------
// Main session: snapshot polling + SSE + frame refresh
// ---------------------------------------------------------------------------
let snapshotTimer = null;
let frameTimer = null;
let sse = null;
let lastFrameBlobUrl = null;
let frameBusy = false;

function bootSession() {
  setConnectionState('reconnecting');
  lastSnapshotAt = 0;
  sessionStartedAt = Date.now();
  linkFailure = null;
  lastKnownState = null;
  // A new session may be a different rig — a re-pair against another desktop.
  // Carrying the previous one's events into it would attribute them here.
  feedEvents = [];
  feedSeenKeys = new Set();
  foldedProgressTicks = 0;
  // The frame counter is a reading of the previous session's run; carrying it
  // — or the feed frame number it is compared against — into this one would
  // describe this rig with the last one's numbers.
  frameCounterText = '--';
  frameCounterDone = null;
  frameCounterReadSeq = nextOrderingTick();
  lastFrameEventSeq = 0;
  feedNewestFrameNumber = null;
  renderFeed();
  renderFrameCounter();
  fetchSnapshot();
  openSSE();
  startPolling();
  startStaleWatchdog();
  refreshFrame();
}

function startPolling() {
  stopPolling();
  snapshotTimer = setInterval(fetchSnapshot, SNAPSHOT_INTERVAL_MS);
  frameTimer = setInterval(refreshFrame, FRAME_FALLBACK_MS);
}

function stopPolling() {
  if (snapshotTimer) { clearInterval(snapshotTimer); snapshotTimer = null; }
  if (frameTimer) { clearInterval(frameTimer); frameTimer = null; }
  stopStaleWatchdog();
}

/// Fetch one snapshot and render it, and record what the exchange was worth.
///
/// The order is load-bearing. `noteLinkOk()` used to run on the status code,
/// before the payload had been looked at, so a 200 whose body was `null` reset
/// the staleness clock and `applySnapshot` then returned on its `if (!data)`
/// guard having painted nothing: measured against the release bundle, 51 s of
/// `null` bodies past a 20 s staleness threshold left a green "running" badge,
/// "30%" and "9 / 30" on screen while the wire read 90% / 27 of 30, with the
/// connection dot in its connected class and no banner. The link is healthy
/// only once a well-formed snapshot has been APPLIED, so that is where it is
/// recorded.
async function fetchSnapshot() {
  try {
    const data = await apiJson('/api/run-watch/snapshot');
    applySnapshot(data);
    noteLinkOk();
    setConnectionState('connected');
  } catch (e) {
    if (e.kind === 'auth_required') return;
    // A credential the rig accepts but will not let read the run leaves this
    // page knowing nothing current — the same position an unreadable answer
    // leaves it in — so it counts as a failed exchange and the banner names
    // the refusal rather than blaming the link.
    if (e.kind === 'scope_denied') {
      noteLinkFailure(
        'scope_denied', scopeRefusalText('Watching this run', e.detail));
      return;
    }
    // An answer this page cannot read teaches it nothing, so it counts as a
    // failed exchange and the degraded surface below says so.
    if (e.kind === 'unusable_answer') {
      noteLinkFailure('unusable_answer', e.message);
      return;
    }
    // 'unreachable' already recorded the failure inside apiFetch; a
    // rate-limited or HTTP-error answer still proves the server is alive, so
    // only the staleness clock decides those.
    if (e.kind !== 'unreachable' && e.kind !== 'rate_limited') {
      setConnectionState('reconnecting');
    }
  } finally {
    renderLinkState();
  }
}

// ---------------------------------------------------------------------------
// The frame counter, and the feed it sits beside
//
// The counter is snapshot data on a 15 s poll; the feed under it is the SSE
// stream, live. Only sequence-level transitions used to re-poll the snapshot,
// so a frame event moved the feed and left the counter where it was: measured
// on the release bundle over one 25-frame run, the page read "22 / 25" with
// "ExposureCompleted frame: 24" rendered directly beneath it and the wire
// agreeing with the feed, and nothing on screen distinguished that moment from
// an agreeing one.
//
// So the counter now advances on the same events the feed does, and while it
// has not yet caught up it says so rather than presenting a figure the page's
// own feed contradicts.
// ---------------------------------------------------------------------------

/// The frame-bearing events. One of these means a frame has landed, which is
/// both a new thumbnail and a new count, so one list drives both. Wiring them
/// to different halves of this page is what let the count fall behind the
/// picture.
const FRAME_EVENT_NAMES = [
  'FrameAccepted', 'FrameRejected', 'ExposureFinished', 'ExposureCompleted',
  'ImageSaved',
];

/// Smallest gap between two event-driven snapshot refreshes. A frame lands with
/// several of these names at once (FrameAccepted and ExposureCompleted share a
/// millisecond on the wire), and the server budgets 60 reads/s across every tab
/// the operator has open, so the burst is collapsed into one re-read.
const FRAME_SNAPSHOT_COALESCE_MS = 1000;

/// A monotonic tick stamped on both the snapshot render and each frame event,
/// so the two can be ordered. `Date.now()` cannot order them: a frame event
/// arriving in the same millisecond a snapshot rendered compared EQUAL, and the
/// counter went on presenting a figure the feed had already outrun — the exact
/// defect, one millisecond wide.
let orderingTick = 0;
function nextOrderingTick() { return ++orderingTick; }

/// The counter as the last snapshot reported it, and the tick it was read at.
let frameCounterText = '--';
let frameCounterDone = null;
let frameCounterReadSeq = 0;
/// The tick of the newest frame event the feed has taken, and the frame number
/// it carried when it carried one.
let lastFrameEventSeq = 0;
let feedNewestFrameNumber = null;
/// True while a coalesced snapshot re-read is already scheduled.
let frameSnapshotPending = false;

/// Draw the frame counter, saying plainly when the feed has moved past it.
///
/// Two ways the page can know it is behind, and it takes either: the feed
/// carries a frame number above the counter's own (provable from what is on
/// screen), or a frame event has arrived since the counter was read (true even
/// when the event carried no number).
function renderFrameCounter() {
  const el = $('progress-frames');
  if (!el) return;
  // A counter nobody has read cannot be behind. "-- · updating" is a staleness
  // claim about a figure that is not on the screen — measured with the snapshot
  // endpoint answering 500 while the stream still delivered frames. `--` says
  // the whole of what is known, and the link banner says why.
  const known = frameCounterText !== '--';
  const outrunByNumber = feedNewestFrameNumber != null &&
    frameCounterDone != null && feedNewestFrameNumber > frameCounterDone;
  const outrunByArrival = lastFrameEventSeq > frameCounterReadSeq;
  el.textContent = (known && (outrunByNumber || outrunByArrival))
    ? frameCounterText + ' · updating'
    : frameCounterText;
}

/// Take a frame event: mark the counter as outrun and schedule the re-read that
/// will catch it up.
function noteFrameEvent(evt) {
  lastFrameEventSeq = nextOrderingTick();
  const frame = wireNumber(evt && evt.data && evt.data.frame);
  if (frame != null &&
      (feedNewestFrameNumber == null || frame > feedNewestFrameNumber)) {
    feedNewestFrameNumber = frame;
  }
  renderFrameCounter();
  if (frameSnapshotPending) return;
  frameSnapshotPending = true;
  setTimeout(() => {
    frameSnapshotPending = false;
    fetchSnapshot();
  }, FRAME_SNAPSHOT_COALESCE_MS);
}

/// Wire states in which the run is OVER. `sequencer.state` is the only field
/// that can say so — `SequenceExecutionState` has no member for any of them.
const TERMINAL_WIRE_STATES = new Set(
  ['completed', 'failed', 'cancelled', 'stopped', 'error']);

/// The state the snapshot actually reports.
///
/// `progress.state` is the executor's own `SequenceExecutionState`, an enum
/// with no member for a cancelled run: once a run is stopped it reads `idle`
/// while `sequencer.state` — the field the same snapshot carries straight from
/// `/api/sequencer/status` — reads `cancelled`. Reading the executor block
/// unconditionally told the operator the rig was idle 8% into a night that had
/// just been cancelled. So: the executor block wins while it is describing a
/// live run, and the moment it falls back to `idle` the sequencer status —
/// which is the one that knows how the run ended — is what gets rendered.
///
/// A run the wire says has ENDED overrides the executor block outright, even
/// when that block names a live-looking state. Measured against the release
/// bundle: `POST /api/sequencer/pause` at a cancelled run left the snapshot
/// carrying `sequencer.state: cancelled` beside `progress.state: paused`, and
/// a resume left `progress.state: running` — this page rendered a green
/// `running` badge, across reloads, for a run that had ended 40 s earlier.
/// The server no longer admits those commands, and this tie-break means one
/// stale executor block can no longer outrank the field that knows how the
/// run finished.
function reportedSequencerState(progress, sequencer) {
  const executing = String((progress && progress.state) || '').toLowerCase();
  const reported = String((sequencer && sequencer.state) || '').toLowerCase();
  if (TERMINAL_WIRE_STATES.has(reported)) return reported;
  if (executing && executing !== 'idle') return executing;
  if (reported) return reported;
  // An executor that says idle with nothing to contradict it is idle. A
  // snapshot that names no state at all is not idle, it is unknown.
  return executing || 'unknown';
}

/// Enable exactly the run controls the reported state admits.
///
/// Every control used to be tappable at all times: on a rig with nothing
/// running, Pause / Skip / Resume each fired a request and each drew a green
/// "accepted" toast, while `/api/sequencer/status` went on reading "idle".
/// The desktop dashboard already gates the same controls on the executor
/// state (`updateSequencerButtons` in web_dashboard/js/app.js); this surface
/// now reads the same rule off the same state word.
///
/// Reset stays available in every state on purpose: it is the way out of a
/// wedged executor, and it does the thing it says on an idle one.
/// Controls the rig has refused for the credential this device is carrying,
/// keyed by button id, holding the sentence that refusal produced.
///
/// A read-only pairing renders the same control cluster as a control-scope
/// one, so before this the buttons stayed live and each press posted a request
/// the rig had already refused once. A control this credential cannot use is
/// disabled and carries its reason, so the refusal is on the control rather
/// than only in a toast that has since faded.
const refusedControls = new Map();

/// Which control drives which endpoint, so a refusal lands on the button that
/// caused it.
const CONTROL_BUTTON_FOR_PATH = {
  '/api/sequencer/pause': 'btn-pause',
  '/api/sequencer/resume': 'btn-resume',
  '/api/sequencer/skip': 'btn-skip',
  '/api/sequencer/stop': 'btn-stop',
  '/api/sequencer/reset': 'btn-reset',
  '/api/sequencer/checkpoint/resume': 'btn-checkpoint-resume',
  '/api/sequencer/checkpoint/discard': 'btn-checkpoint-discard',
  '/api/phd2/dither': 'btn-guide-dither',
};

/// Record that the rig refused [path] for this credential and put the reason
/// on the control that posts to it.
function noteControlRefused(path, sentence) {
  const id = CONTROL_BUTTON_FOR_PATH[path];
  if (!id) return;
  refusedControls.set(id, sentence);
  const el = $(id);
  if (!el) return;
  el.disabled = true;
  el.title = sentence;
  el.setAttribute('aria-disabled', 'true');
}

/// Forget every recorded refusal. Called whenever the credential changes: a
/// different pairing may hold more than the last one did, and carrying the old
/// pairing's refusals forward would disable controls the new one can use.
function clearControlRefusals() {
  for (const id of refusedControls.keys()) {
    const el = $(id);
    if (el) {
      el.title = '';
      el.removeAttribute('aria-disabled');
    }
  }
  refusedControls.clear();
}

function updateRunControls(state) {
  const s = String(state || '').toLowerCase().replace(/[_\s]/g, '');
  const set = (id, enabled) => {
    const el = $(id);
    if (!el) return;
    // A control the rig has already refused for this credential stays
    // refused, whatever the run state would otherwise admit.
    const refusal = refusedControls.get(id);
    if (refusal) {
      el.disabled = true;
      el.title = refusal;
      return;
    }
    el.disabled = !enabled;
  };
  const running = s === 'running' || s === 'executing';
  const paused = s === 'paused';
  const recovering = s === 'recovering';
  const stopRetry = s === 'stopfailed' || s === 'cleanupfailed';
  set('btn-pause', running || recovering);
  set('btn-resume', paused);
  set('btn-skip', running || paused || recovering);
  set('btn-stop', running || paused || recovering || stopRetry);
}

/// Paint the progress readout as UNKNOWN — no figure, no announcement, and a
/// bar that cannot be mistaken for a run which has genuinely done nothing.
///
/// Shared by the two ways the page can stop knowing: the server answering
/// `progressPercent: null` (its own documented degraded payload), and the
/// server answering nothing at all.
function paintProgressUnknown() {
  const pctEl = $('progress-pct');
  if (pctEl) pctEl.textContent = '--';
  const bar = $('progress-bar');
  if (bar) bar.style.width = '0%';
  const ariaBar = $('progress-bar-aria');
  if (ariaBar) {
    // A progressbar with no aria-valuenow is announced as indeterminate,
    // which is the truth when nobody has reported a percentage.
    // aria-valuenow="0" would announce "0 percent" — a number nobody sent.
    ariaBar.removeAttribute('aria-valuenow');
    // The GRAPHIC has to say the same thing the text and the announcement do.
    // A `width: 0%` track is pixel-identical to a fresh boot that has really
    // done nothing, verified side by side on the same page; the unknown track
    // is hatched so the two states cannot be confused at a glance.
    ariaBar.classList.add('unknown');
  }
}

/// Show what the run says about itself, and hide the surface when it says
/// nothing.
///
/// `sequencer.message` is the status line `/api/sequencer/status` carries;
/// `progress.message` is the executor's own line for the node it is on. They
/// often agree, and a message already spelled out in the header is not repeated
/// underneath it, so the surface holds what the operator has not already read.
function renderSequencerMessages(sequencer, progress, headline) {
  const slot = $('seq-message');
  if (!slot) return;
  const seen = new Set();
  const lines = [];
  for (const raw of [sequencer.message, progress.message]) {
    const text = wireString(raw);
    if (!text || text === headline || seen.has(text)) continue;
    seen.add(text);
    lines.push(text);
  }
  slot.textContent = lines.join('\n');
  slot.classList.toggle('hidden', lines.length === 0);
}

/// Render a snapshot, or refuse it out loud.
///
/// Refusal is a typed `unusable_answer`, which [fetchSnapshot] turns into the
/// same degraded surface a dead daemon produces. Two things earn it:
///
///  * a payload that is not a snapshot object at all — `null`, `0`, `false`,
///    `""`, a bare string, an array. The old guard was `if (!data) return;`,
///    which swallowed exactly these and left the caller believing the exchange
///    had succeeded.
///
///  * a render that throws. The formatters below no longer throw on a
///    wrongly-typed field, but the DOM is not this page's to guarantee, and a
///    throw part-way through leaves the fields above it holding a payload the
///    ones below never took. That mixture is not a picture of anything, and
///    nobody was told: the old catch in [fetchSnapshot] inspected `e.kind`
///    only, so a TypeError was discarded in silence.
function applySnapshot(data) {
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    throw new ApiError(
      'unusable_answer',
      'The snapshot answer is not a snapshot: ' + describeWireValue(data),
      { received: data },
    );
  }
  try {
    renderSnapshot(data);
  } catch (e) {
    if (e instanceof ApiError) throw e;
    throw new ApiError(
      'unusable_answer',
      'The snapshot could not be rendered: ' + (e && e.message ? e.message : String(e)),
      { cause: e },
    );
  }
}

/// What arrived, in words, for the refusal message. The value itself is not
/// interpolated — a hostile body must not reach the screen through an error
/// string.
function describeWireValue(v) {
  if (v === null) return 'it is null';
  if (v === undefined) return 'there is no body';
  if (Array.isArray(v)) return 'it is a list';
  return 'it is a ' + typeof v;
}

/// Draw one snapshot. Every field on the screen comes from `data` and nothing
/// else; [applySnapshot] owns what happens when `data` cannot supply one.
function renderSnapshot(data) {
  // Sequencer state badge
  const sequencer = data.sequencer || {};
  const progress = sequencer.progress || {};
  const state = reportedSequencerState(progress, sequencer);
  const unknown = state === 'unknown';
  const badge = $('state-badge');
  badge.textContent = state;
  badge.className = 'badge';
  if (state === 'running') badge.classList.add('badge-running');
  else if (state === 'paused') badge.classList.add('badge-paused');
  else if (state === 'recovering') badge.classList.add('badge-recovering');
  else if (state === 'error' || state === 'failed') badge.classList.add('badge-error');
  else if (unknown) badge.classList.add('badge-error');
  else badge.classList.add('badge-idle');
  lastKnownState = state;
  updateRunControls(state);

  // state 'unknown' means the server's read failed. Never fall back to
  // 'Idle' there — the run may well still be going. With nothing named and a
  // state that is not idle either (a cancelled run keeps no current node),
  // the state word itself is the only true thing left to show.
  //
  // Every candidate is a wire STRING, so every candidate is read as one: a
  // `currentTarget` of `42` printed "42" as the run's headline, and a
  // `currentNodeName` object printed "[object Object]" there. A field that is
  // not a string carries no name, and the next candidate — ending in the state
  // word, which this page owns — is what the operator gets instead.
  const headline =
    wireString(progress.currentTarget) || wireString(sequencer.currentNodeName) ||
    (unknown ? (wireString(progress.message) || 'Status unavailable')
             : state.charAt(0).toUpperCase() + state.slice(1));
  $('seq-name').textContent = headline;

  // What the executor is saying about the run. Both fields are rendered for
  // every state, not just `unknown`: they are where a failing meridian flip, a
  // trigger's retry countdown and the current exposure's own line arrive, and
  // the desktop dashboard has always shown them. Dropping them here meant a run
  // stalled on a flip read as "RUNNING 33%" on the phone while the wire carried
  // the reason in two fields.
  renderSequencerMessages(sequencer, progress, headline);

  // Active target. `coordinatesKnown: false` is the headless case — the native
  // executor holds the sequence, so the host can name the target but cannot
  // place it on the sky. Show the name it does have and label the rest.
  const target = data.activeTarget;
  if (target) {
    const placed = target.coordinatesKnown !== false;
    const targetMessage = wireString(target.message);
    const filter = wireString(progress.currentFilter);
    $('target-state').textContent = target.unavailable
      ? (targetMessage || 'Target unavailable')
      : (!placed
          ? (targetMessage || 'Coordinates unavailable')
          : (filter ? ('filter: ' + filter) : ''));
    $('target-name').textContent = wireString(target.name) || '--';
    $('target-coords').textContent = formatRaDec(target.raHours, target.decDegrees);
    $('target-alt').textContent = formatDeg(target.altitudeDeg);
    $('target-az').textContent = formatDeg(target.azimuthDeg);
    $('target-time-set').textContent = formatDuration(target.timeToSetSecs);
    $('target-time-transit').textContent = formatDuration(target.timeToTransitSecs);
  } else {
    $('target-name').textContent = '--';
    $('target-coords').textContent = '--';
    $('target-alt').textContent = '--';
    $('target-az').textContent = '--';
    $('target-time-set').textContent = '--';
    $('target-time-transit').textContent = '--';
    $('target-state').textContent = '';
  }

  // Progress
  const fraction = wireNumber(progress.progressPercent);
  if (fraction == null) {
    paintProgressUnknown();
  } else {
    const pct = Math.round(fraction * 100);
    $('progress-pct').textContent = pct + '%';
    $('progress-bar').style.width = pct + '%';
    const ariaBar = $('progress-bar-aria');
    if (ariaBar) {
      ariaBar.setAttribute('aria-valuenow', String(pct));
      ariaBar.classList.remove('unknown');
    }
  }
  const done = wireNumber(progress.completedExposures);
  const planned = wireNumber(progress.totalExposures);
  frameCounterText = done != null && planned != null
    ? done + ' / ' + planned
    : '--';
  frameCounterDone = done;
  frameCounterReadSeq = nextOrderingTick();
  renderFrameCounter();
  // The denominator is null whenever the host does not know the run's planned
  // integration (every native/headless start — see _knownIntegrationDenominator
  // in run_watch_handlers.dart). "24s / 0s" claimed a total the run had already
  // passed; "24s / --" says what is actually known.
  $('progress-integration').textContent =
    formatDurationSecs(progress.completedIntegrationSecs) + ' / ' +
    formatDurationSecs(progress.totalIntegrationSecs);
  $('progress-node').textContent =
    wireString(progress.currentNodeName) || wireString(sequencer.currentNodeName) || '--';
  $('progress-filter').textContent = wireString(progress.currentFilter) || '--';

  // Equipment. An ABSENT list is not an empty one: `data.devices || []` folded
  // "the snapshot said nothing about equipment" into "nothing is connected" and
  // printed that as a positive claim, measured with four simulator devices
  // genuinely connected and every sibling field on the same screen reading
  // `--`. Guiding, weather and progress all tell a reading from an absence, so
  // equipment does too — `--` for unknown, the sentence only for a list the
  // server actually sent and that was actually empty.
  const list = $('equipment-list');
  list.innerHTML = '';
  const devices = Array.isArray(data.devices) ? data.devices : null;
  if (devices == null || devices.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = devices == null ? '--' : 'No connected devices';
    list.appendChild(empty);
  } else {
    devices.forEach(d => {
      const row = document.createElement('div');
      row.className = 'equipment-row';
      const name = document.createElement('span');
      name.className = 'name';
      name.textContent = d.name;
      const type = document.createElement('span');
      type.className = 'type';
      type.textContent = d.type;
      row.appendChild(name);
      row.appendChild(type);
      list.appendChild(row);
    });
  }

  // Guiding. PHD2 reports 0.0 for every RMS while disconnected, which is a
  // placeholder, not a measurement — a disconnected guider has no error to
  // report at all. Only a connected guider's numbers are shown.
  const guiding = data.guiding || {};
  const guideConnected = guiding.connected === true;
  $('guide-state').textContent = guideConnected
    ? (guiding.state || 'connected')
    : 'disconnected';
  $('guide-ra').textContent = guideConnected ? formatRms(guiding.rmsRa) : '--';
  $('guide-dec').textContent = guideConnected ? formatRms(guiding.rmsDec) : '--';
  $('guide-total').textContent = guideConnected ? formatRms(guiding.rmsTotal) : '--';
  const snr = wireNumber(guiding.snr);
  $('guide-snr').textContent = guideConnected && snr != null
    ? snr.toFixed(1)
    : '--';

  // Weather. Two different absences share one payload and must not share one
  // rendering:
  //
  //   `safeToImage: false` is a VERDICT — the rig has decided not to image.
  //     It is reachable with `dataSource: 'unavailable'`, because a fail-closed
  //     safety policy refuses precisely when nothing could be read. A refusal
  //     is the one reading that may never soften into a neutral, so it is
  //     answered first, whatever the data source says.
  //
  //   `dataSource: 'unavailable'` with no refusal is NO VERDICT — no weather
  //     hardware, no safety monitor, no API source, and nothing asking. A run
  //     of green "clear"/"safe" out of that is the fail-honest rule's exact
  //     prohibition, so the sensor question is answered before any green.
  const weather = data.weather || {};
  const wbadge = $('weather-badge');
  const weatherSourced =
    weather.dataSource != null && weather.dataSource !== 'unavailable';
  const weatherRefused = weather.safeToImage === false;
  wbadge.className = 'badge';
  if (weatherRefused) {
    // The level qualifies the refusal; it never replaces the word for it. An
    // unsourced fail-closed refusal carries `alertLevel: 'clear'`, which read
    // alone is the opposite of what the rig decided.
    const level = weather.alertLevel;
    wbadge.textContent =
      weatherSourced && level && level !== 'clear' && level !== 'unsafe'
        ? 'unsafe · ' + level
        : 'unsafe';
    wbadge.classList.add('badge-error');
  } else if (!weatherSourced) {
    wbadge.textContent = 'no sensor';
    wbadge.classList.add('badge-idle');
  } else {
    wbadge.textContent = weather.alertLevel || 'unknown';
    if (weather.safeToImage) wbadge.classList.add('badge-running');
    else if (weather.alertLevel === 'warning') wbadge.classList.add('badge-paused');
    else if (weather.alertLevel === 'unsafe' || weather.alertLevel === 'critical') wbadge.classList.add('badge-error');
    else wbadge.classList.add('badge-idle');
  }
  $('weather-message').textContent = weatherRefused
    ? (weather.message || 'Not safe to image; the safety check gave no reason.')
    : weatherSourced
      ? (weather.message || '--')
      : (weather.message || 'No weather source configured.');

  // Recovery banner
  const banner = $('recovery-banner');
  if (data.recovery && typeof data.recovery === 'object') {
    banner.classList.remove('hidden');
    const reason = data.recovery.reason || data.recovery.trigger || 'Sequence recovery in progress';
    banner.textContent = 'Recovery: ' + reason;
  } else {
    banner.classList.add('hidden');
    banner.textContent = '';
  }

  // Recent events. The server's ring is five deep and, mid-exposure, made
  // almost entirely of progress ticks — measured on the release bundle, 2 of
  // the 5 rows it answered with were `Progress` while the stream ran 229 ticks
  // in 327 events. Overwriting the feed with that ring every 15 s is what
  // erased the frames and node transitions the stream had delivered, so the
  // ring is MERGED into the feed's own model, oldest first, and each entry is
  // judged by the same rule a streamed event is.
  if (Array.isArray(data.recentEvents)) {
    for (let i = data.recentEvents.length - 1; i >= 0; i--) {
      const evt = data.recentEvents[i];
      // A tick in the ring is not counted into the fold: the fold says how
      // many updates have arrived SINCE the newest event, and one the poll is
      // re-reading fifteen seconds later did not arrive now.
      if (isProgressTickEvent(evt && (evt.eventType || evt.eventName))) continue;
      noteFeedEvent(evt);
    }
  } else if (data.recentEvents && data.recentEvents.length) {
    throw new TypeError('recentEvents is not a list');
  }
}

function renderEventLi(evt) {
  const li = document.createElement('li');
  const severity = (evt.severity || 'info').toLowerCase();
  li.className = 'sev-' + severity;
  const time = document.createElement('span');
  time.className = 'event-time';
  time.textContent = formatTimeMs(evt.timestamp);
  const body = document.createElement('div');
  body.className = 'event-body';
  const title = document.createElement('div');
  title.className = 'event-title';
  title.textContent = eventTitleText(evt);
  const detail = document.createElement('div');
  detail.className = 'event-detail';
  detail.textContent = formatEventDetail(evt);
  body.appendChild(title);
  if (detail.textContent) body.appendChild(detail);
  li.appendChild(time);
  li.appendChild(body);
  return li;
}

/// Whether this row is the host's "no case for this variant" bucket.
///
/// The host has one such bucket per event family — `UnknownSequencerEvent`,
/// `UnknownImagingEvent`, `UnknownSafetyEvent` and the rest — and they are the
/// only rows whose data map is not a set of read fields. They are matched by
/// shape rather than by a list of names so a family added to the host later
/// arrives here already covered.
function isUnreadEventBucket(type) {
  return /^Unknown\w*Event$/.test(type);
}

/// The name a feed row carries.
///
/// An event the host has no mapping for arrives in an unread bucket carrying
/// the union variant it stands for; that variant is what the operator can act
/// on, so it is what the row is called. Without it the row was titled
/// "UnknownSequencerEvent" over a line of Dart source.
function eventTitleText(evt) {
  const type = evt.eventType || evt.eventName || 'event';
  if (isUnreadEventBucket(type) && evt.data && typeof evt.data.variant === 'string') {
    const variant = evt.data.variant.trim();
    if (variant) return variant;
  }
  return type.replace(/_/g, ' ');
}

function formatEventDetail(evt) {
  if (!evt.data || typeof evt.data !== 'object') return '';
  // An unmapped event carries one written sentence and a variant name that is
  // already this row's title. Render the sentence and nothing else: the
  // generic field walk below prints every string it finds, and a bucket whose
  // host has not been taught to name its variants still puts the stringified
  // event object in that map — which is how Dart source text reached the
  // operator's phone in the first place. A row with nothing written for a
  // person says only what it is named, which is the truth.
  if (isUnreadEventBucket(evt.eventType || evt.eventName || '')) {
    return typeof evt.data.message === 'string' ? evt.data.message : '';
  }
  // Surface the first 2 non-empty string-ish fields so the row stays
  // compact on a phone. Numeric fields render as `key: value`.
  const parts = [];
  for (const k of Object.keys(evt.data)) {
    if (parts.length >= 2) break;
    const v = evt.data[k];
    if (v == null) continue;
    if (typeof v === 'string') parts.push(v);
    else if (typeof v === 'number') parts.push(k + ': ' + formatShortNum(v));
  }
  return parts.join(' · ');
}

// ---------------------------------------------------------------------------
// Formatters
//
// Every figure on this page is drawn with arithmetic — a multiply, a
// Math.floor, a toFixed — and every one of those fields is typed by a wire
// this page does not control. A field carrying a string took that arithmetic
// two ways, both measured against the release bundle: `"abc"` through
// formatRaDec printed `NaNh NaNm NaNs · -NaN° NaN′ NaN″` on the operator's
// phone, and `"not-a-number".toFixed(1)` threw a TypeError that aborted the
// rest of the render.
//
// So the guard is the type, not just null: a field that is not a finite number
// carries no reading, and no reading renders as the same `--` a null does.
// ---------------------------------------------------------------------------

/// The number a wire field carries, or null when it carries something else.
/// `NaN` and `Infinity` are no more a reading than a string is.
function wireNumber(v) {
  return typeof v === 'number' && isFinite(v) ? v : null;
}

/// The text a wire field carries, or null when it carries something else.
///
/// The string sibling of [wireNumber], and it was the one wire type with no
/// guard. `textContent = progress.currentFilter || '--'` hands the DOM whatever
/// arrived, and the DOM stringifies it: with `currentFilter` an object — one
/// field of one real snapshot changed, everything else untouched — the filter
/// slot on the operator's phone read `[object Object]`, and the active-target
/// line read `filter: [object Object]`. That is not a reading, and a page that
/// guards its numbers and its lists has no business printing it.
///
/// Empty and blank are not readings either: `''` reaching a field would paint a
/// blank where `--` says "nothing known", and a name of spaces is the same
/// absence with different bytes. The value is returned TRIMMED, which is what
/// the messages block already did with the two fields it reads.
function wireString(v) {
  if (typeof v !== 'string') return null;
  const t = v.trim();
  return t === '' ? null : t;
}

function formatShortNum(rawN) {
  const n = wireNumber(rawN);
  if (n == null) return '--';
  if (n === Math.floor(n) && Math.abs(n) < 1000) return String(n);
  return n.toFixed(2);
}

function formatTimeMs(ms) {
  const t = wireNumber(ms);
  if (!t) return '--';
  const d = new Date(t);
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  const ss = String(d.getSeconds()).padStart(2, '0');
  return hh + ':' + mm + ':' + ss;
}

function formatRaDec(rawRaHours, rawDecDeg) {
  const raHours = wireNumber(rawRaHours);
  const decDeg = wireNumber(rawDecDeg);
  if (raHours == null || decDeg == null) return '--';
  const raH = Math.floor(raHours);
  const raMfull = (raHours - raH) * 60;
  const raM = Math.floor(raMfull);
  const raS = ((raMfull - raM) * 60).toFixed(1);
  const sign = decDeg >= 0 ? '+' : '-';
  const decAbs = Math.abs(decDeg);
  const decD = Math.floor(decAbs);
  const decMfull = (decAbs - decD) * 60;
  const decM = Math.floor(decMfull);
  const decS = ((decMfull - decM) * 60).toFixed(0);
  return `${raH}h ${raM}m ${raS}s · ${sign}${decD}° ${decM}′ ${decS}″`;
}

function formatDeg(rawDeg) {
  const deg = wireNumber(rawDeg);
  if (deg == null) return '--';
  return deg.toFixed(1) + '°';
}

function formatRms(rawV) {
  const v = wireNumber(rawV);
  if (v == null) return '--';
  return v.toFixed(2) + '″';
}

function formatDuration(rawSecs) {
  const secs = wireNumber(rawSecs);
  if (secs == null) return '--';
  if (secs <= 0) return 'now';
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  const s = Math.floor(secs % 60);
  if (h > 0) return h + 'h ' + m + 'm';
  if (m > 0) return m + 'm ' + s + 's';
  return s + 's';
}

function formatDurationSecs(secs) {
  // null means the server could not read the value, which is not zero.
  if (secs == null) return '--';
  return formatDuration(secs) === 'now' ? '0s' : formatDuration(secs);
}

// ---------------------------------------------------------------------------
// SSE — live event stream
// ---------------------------------------------------------------------------

/// The discrete event names the feed subscribes to.
///
/// EventSource hands a named frame ONLY to a listener registered for that
/// name, so this list is the feed's reach. Two sources, and nothing invented:
/// the first block is every non-progress name measured on
/// /api/run-watch/events across 60 s of one live sim sequence; the second is
/// the names the page already subscribes to below, plus siblings confirmed
/// present in the host's own sources. A name absent here can still reach the
/// feed through the snapshot's recent list, which is the backstop rather than
/// the path.
const FEED_EVENT_NAMES = [
  // Measured on the wire.
  'ExposureStarted', 'ExposureComplete', 'ExposureCompleted', 'FrameAccepted',
  'FocuserMoveStarted', 'FocuserMoveCompleted', 'FilterChanging',
  'FilterChanged', 'NodeStarted', 'NodeCompleted', 'TriggerFired',
  'DecisionLogged', 'IntegrationBudget', 'UnknownSequencerEvent',
  // Not seen in that minute, but emitted by this host on other paths.
  'ExposureFinished', 'ExposureAborted', 'ExposureAdjusted', 'FrameRejected',
  'ImageSaved', 'SequenceStarted', 'SequencePaused', 'SequenceResumed',
  'SequenceStopped', 'SequenceFinished', 'Completed', 'SchedulerDecision',
  'MeridianFlipCompleted', 'GuidingStarted', 'GuidingStopped',
  'DitherStarted', 'DitherCompleted', 'WeatherAlert',
  'RecoveryStarted', 'RecoveryCompleted',
];

/// The tick families, subscribed so they can be COUNTED.
///
/// They never take a row — [noteFeedEvent] folds anything
/// [isProgressTickEvent] recognises — but without a subscription they do not
/// reach this page at all, and the fold row would then be a mechanism that
/// only ever fired in its own tests. Counting them is what lets the panel say
/// "the rig is working, these updates are in the bar" rather than sit silent
/// through a five-minute exposure.
const PROGRESS_EVENT_NAMES = [
  'ExposureProgress', 'Progress',
  'InstructionProgress', 'InstructionProgressStructured',
];

function openSSE() {
  closeSSE();
  // EventSource doesn't accept custom headers natively. A bearer therefore
  // rides the `access_token` query param, which the server's auth middleware
  // accepts on this GET-only endpoint alone. A cookie session needs no carrier:
  // the browser attaches the HttpOnly cookie to this same-origin subscription
  // itself.
  const token = effectiveToken();
  let url;
  if (token) {
    url = '/api/run-watch/events?access_token=' + encodeURIComponent(token);
  } else if (sessionCsrfToken) {
    url = '/api/run-watch/events';
  } else {
    return;
  }
  try {
    sse = new EventSource(url, { withCredentials: false });
  } catch (e) {
    console.warn('SSE init failed', e);
    return;
  }

  sse.onopen = () => setConnectionState('connected');
  sse.onerror = () => {
    // EventSource retries forever and fires onerror on each attempt. Calling
    // it "reconnecting" is only honest while the snapshot poll still believes
    // the link is alive; once the link is known stale the dot must agree with
    // the banner rather than keep suggesting a recovery is under way.
    setConnectionState(isLinkStale() ? 'disconnected' : 'reconnecting');
  };
  sse.onmessage = (evt) => handleSseMessage(evt);

  // Every frame this server sends carries an `event:` name — measured on the
  // release bundle: 327 of 327 frames over one live minute — and EventSource
  // delivers a NAMED frame only to a listener registered for that name.
  // `onmessage` above therefore never fires here, which is why the feed was
  // painted solely by the snapshot poll's five-deep `recentEvents` ring, and
  // why that ring being all progress ticks mid-exposure emptied the panel of
  // everything that had actually happened.
  FEED_EVENT_NAMES.concat(PROGRESS_EVENT_NAMES).forEach(name => {
    sse.addEventListener(name, (evt) => {
      try { noteFeedEvent(JSON.parse(evt.data)); } catch { /* not our shape */ }
    });
  });

  // Frame events — refresh the thumbnail immediately rather than waiting for
  // the 10s fallback, and re-read the snapshot so the frame counter advances on
  // the same events the feed beside it does.
  FRAME_EVENT_NAMES.forEach(name => {
    sse.addEventListener(name, (evt) => {
      refreshFrame();
      let payload = null;
      try { payload = JSON.parse(evt.data); } catch { /* not our shape */ }
      noteFrameEvent(payload);
    });
  });

  // Sequencer state transitions — fetch a fresh snapshot so the
  // progress bar / current-target panel updates without waiting for
  // the 15s baseline poll.
  ['SequencePaused', 'SequenceResumed', 'SequenceStarted',
    'SequenceFinished', 'SequenceStopped', 'NodeStarted',
    'NodeCompleted', 'SchedulerDecision'].forEach(name => {
    sse.addEventListener(name, () => fetchSnapshot());
  });
}

function closeSSE() {
  if (sse) {
    try { sse.close(); } catch { /* ignore */ }
    sse = null;
  }
}

/// How many discrete events the feed shows.
const FEED_ROW_CAP = 5;

/// Whether an event is a progress tick rather than something that happened.
///
/// Measured against the release bundle over 60 s of one live sim sequence:
/// 327 events on /api/run-watch/events, of which ExposureProgress 84,
/// Progress 53, InstructionProgress 46 and InstructionProgressStructured 46 —
/// 229 of 327, about four a second. Against a five-row feed that cadence
/// evicts everything else within a second: sampled every 2 s across 50 s of a
/// live run, 104 of 125 row slots were ticks and not one of the 25 samples
/// held a FrameAccepted row or a node transition.
///
/// Matched by name so a family the host adds later (`FooProgress`,
/// `FooProgressStructured`) is folded on arrival rather than after it has
/// flooded a phone. The figure these carry is not lost — it is the progress
/// bar above, which is the surface built to show a number moving.
function isProgressTickEvent(type) {
  return /Progress/.test(String(type || ''));
}

/// The discrete events this page is holding, newest first, capped at
/// [FEED_ROW_CAP]. Owned here rather than read back off the DOM because the
/// snapshot poll repaints the same list every 15 s, and a list that lives only
/// in the DOM cannot survive its own repaint.
let feedEvents = [];
/// Keys of events already in the feed, so the same one arriving twice — once
/// on the stream, once in the snapshot's own recent list — is shown once.
let feedSeenKeys = new Set();
/// Ticks that have arrived since the newest discrete event. Reset by that
/// event, so the fold row always describes the gap at the top of the feed.
let foldedProgressTicks = 0;

function feedEventKey(evt) {
  // The pair (serverInstanceId, seq) uniquely identifies a server event, so a
  // burst the host stamps with ONE timestamp — the sibling case a timestamp+
  // type key collapses onto a single row, dropping every event after the
  // first — stays distinct here. seq is server-assigned and monotonic; the
  // same event arriving on the stream and again in the snapshot's recent ring
  // carries the same seq, so it still de-dupes to one row.
  //
  // Absent only on events that carry no seq at all (a client-synthesised entry,
  // or an older host that does not stamp one). Those fall back to timestamp+
  // type — all they carry — and take the collision the seq is meant to avoid.
  if (evt && evt.seq !== undefined && evt.seq !== null) {
    return 'seq:' + String(evt.serverInstanceId || '') + ':' + String(evt.seq);
  }
  return String((evt && evt.timestamp) || '') + '|' +
    String((evt && (evt.eventType || evt.eventName)) || '');
}

/// Take one event into the feed's model, or count it as a tick.
///
/// Everything that reaches the feed comes through here: the named SSE
/// listeners, the unnamed-frame handler, and the snapshot's own recent list.
function noteFeedEvent(evt) {
  if (!evt || typeof evt !== 'object') return;
  if (isProgressTickEvent(evt.eventType || evt.eventName)) {
    foldedProgressTicks += 1;
    renderFeed();
    return;
  }
  const key = feedEventKey(evt);
  if (feedSeenKeys.has(key)) return;
  feedSeenKeys.add(key);
  // A night is thousands of events long and this set exists only to stop a
  // double-render; the recent keys are the only ones that can collide.
  if (feedSeenKeys.size > 500) {
    feedSeenKeys = new Set(feedEvents.map(feedEventKey).concat([key]));
  }
  // Newest first by the server's own clock. The stream and the snapshot ring
  // both feed this list and they do not arrive in one order, so the order on
  // screen is the events' own, not the order this page happened to hear them.
  // Events sharing a millisecond are ordered by arrival, newest above — the
  // host stamps a whole burst with one timestamp and the later one is later.
  const ts = Number(evt.timestamp) || 0;
  let at = 0;
  while (at < feedEvents.length &&
         (Number(feedEvents[at].timestamp) || 0) > ts) at++;
  feedEvents.splice(at, 0, evt);
  if (feedEvents.length > FEED_ROW_CAP) feedEvents.length = FEED_ROW_CAP;
  // Only the newest event closes the gap the fold is describing. A ring entry
  // that lands below the top is older than the ticks counted since.
  if (feedEvents[0] === evt) foldedProgressTicks = 0;
  renderFeed();
}

/// Draw the feed from its model: the discrete events, then — when ticks have
/// arrived since the newest of them — one row accounting for those.
///
/// The fold row is not one of the five. A filter that stayed silent would
/// leave the panel looking frozen through the busiest part of a run, with no
/// way to tell "nothing is happening" from "the ticks are hidden".
function renderFeed() {
  const feed = $('event-feed');
  if (!feed) return;
  feed.innerHTML = '';
  if (feedEvents.length === 0) {
    const placeholder = document.createElement('li');
    placeholder.className = 'empty';
    placeholder.textContent = 'Waiting for events…';
    feed.appendChild(placeholder);
  } else {
    for (const evt of feedEvents) feed.appendChild(renderEventLi(evt));
  }
  if (foldedProgressTicks > 0) {
    const row = document.createElement('li');
    // `.empty` is the feed's existing muted style for a row that is commentary
    // rather than an event; `.event-folded` is what this code finds it by.
    row.className = 'empty event-folded';
    row.textContent = foldedProgressTicks === 1
      ? '1 progress update since — the live figure is in the progress bar above.'
      : foldedProgressTicks + ' progress updates since — the live figure is in ' +
        'the progress bar above.';
    feed.appendChild(row);
  }
}

function handleSseMessage(evt) {
  let payload;
  try { payload = JSON.parse(evt.data); }
  catch { return; }
  noteFeedEvent(payload);

  // Critical events — surface as a toast (web Push API is opt-in via
  // settings sheet and lives in registerPushIfEnabled() below). Judged on
  // every payload, folded or not: a severity the server calls critical is not
  // this page's to suppress on the strength of the event's name.
  if ((payload.severity || '').toLowerCase() === 'critical') {
    const title = (payload.eventType || payload.eventName)
      ? eventTitleText(payload)
      : 'Critical event';
    toast(title, 'error');
    // Also browser-level notification if permission granted.
    maybeShowNotification(title, formatEventDetail(payload));
  }
}

function maybeShowNotification(title, body) {
  if (!('Notification' in window)) return;
  if (Notification.permission !== 'granted') return;
  try {
    if (navigator.serviceWorker && navigator.serviceWorker.controller) {
      // Prefer the service-worker route so notifications survive when
      // the tab is backgrounded — `Notification` constructor is
      // deprecated on mobile Safari for that reason.
      navigator.serviceWorker.getRegistration().then(reg => {
        if (reg) reg.showNotification(title, { body, icon: '/run-watch/icons/icon-192.svg' });
      });
    } else {
      new Notification(title, { body, icon: '/run-watch/icons/icon-192.svg' });
    }
  } catch (e) { console.warn('Notification failed', e); }
}

// ---------------------------------------------------------------------------
// Frame thumbnail
// ---------------------------------------------------------------------------
function setFrameLoading(loading) {
  const wrap = $('frame-wrap');
  const badge = $('frame-loading-badge');
  if (wrap) wrap.classList.toggle('is-loading', !!loading);
  if (badge) badge.hidden = !loading;
}

/// Put a sentence where the frame would be, and say it twice: once as the
/// placeholder's text and once as the card's aria-label, because a screen
/// reader that lands on the frame region hears only the label.
function sayNoFrame(sentence) {
  const placeholder = $('frame-placeholder');
  const img = $('frame-img');
  const wrap = $('frame-wrap');
  if (placeholder) {
    placeholder.textContent = sentence;
    placeholder.classList.remove('hidden');
  }
  // The stale JPEG must go with the sentence. Leaving it painted under
  // "no live preview" is the same lie in a different medium.
  if (img) {
    img.classList.add('hidden');
    img.removeAttribute('src');
  }
  if (lastFrameBlobUrl) {
    URL.revokeObjectURL(lastFrameBlobUrl);
    lastFrameBlobUrl = null;
  }
  if (wrap) wrap.setAttribute('aria-label', sentence);
}

/// The server's own words for a refused frame, or an honest description of a
/// refusal that carried none.
///
/// The empty-buffer 404 is a PER-PROCESS fact and the body says so
/// (`error: no_live_preview`, `scope: process`, plus the library route). This
/// page used to discard that body entirely and leave index.html's static "No
/// frame captured yet" standing — an absolute about the whole rig, rendered by
/// a server whose library held 26 frames. The sibling dashboard read the same
/// wire correctly; now both do.
async function frameRefusalText(res) {
  let body = null;
  try {
    body = await res.json();
  } catch (e) {
    body = null;
  }
  const message = body && typeof body.message === 'string' ? body.message : '';
  if (message) {
    if (body.scope === 'process' && body.library) {
      return message + ' (Ask ' + body.library + ' what this rig holds.)';
    }
    return message;
  }
  // No typed body: report the status rather than inventing a cause for it.
  return 'The server refused the last frame (HTTP ' + res.status +
    ') and sent no reason.';
}

async function refreshFrame() {
  if (frameBusy) return;
  frameBusy = true;
  setFrameLoading(true);
  try {
    const res = await apiFetch('/api/run-watch/frame-thumbnail?maxWidth=1024&quality=75');
    if (!res.ok) {
      sayNoFrame(await frameRefusalText(res));
      $('frame-meta').textContent = '--';
      return;
    }
    const blob = await res.blob();
    const url = URL.createObjectURL(blob);
    const img = $('frame-img');
    const placeholder = $('frame-placeholder');
    const wrap = $('frame-wrap');
    img.src = url;
    img.classList.remove('hidden');
    placeholder.classList.add('hidden');
    if (wrap) wrap.removeAttribute('aria-label');
    if (lastFrameBlobUrl) URL.revokeObjectURL(lastFrameBlobUrl);
    lastFrameBlobUrl = url;

    // Meta (timestamp + HFR) from custom response headers.
    //
    // The HFR is LABELLED, because it is not the number the session report,
    // the reject threshold or the Analytics "Mean HFR" show for the same
    // frame: this one is the live-preview measurement (the median of the
    // brightest half of the detected stars), the graded one is the mean over
    // every detected star, and on the sim rig they differ by 8-19%. An
    // operator who sets a reject threshold from an unlabelled 2.00 here is
    // calibrating against the wrong scale. The server names its measurement on
    // `x-frame-hfr-basis`; an older server that sends no name gets no label
    // rather than a guessed one.
    const ts = res.headers.get('x-frame-timestamp');
    const hfr = res.headers.get('x-frame-hfr');
    const basis = res.headers.get('x-frame-hfr-basis');
    const meta = [];
    if (ts) meta.push(formatTimeMs(Date.parse(ts) || Date.now()));
    if (hfr) {
      meta.push('HFR ' + Number(hfr).toFixed(2) +
        (basis === 'live-preview-median-brightest-half' ? ' (preview)' : ''));
    }
    const metaEl = $('frame-meta');
    metaEl.textContent = meta.join(' · ');
    if (hfr && basis === 'live-preview-median-brightest-half') {
      metaEl.title = 'Live-preview HFR: the median of the brightest half of ' +
        'the stars detected in this frame. The graded HFR the session report ' +
        'and the reject threshold use is measured differently (the mean over ' +
        'every detected star) and reads higher.';
    } else {
      metaEl.title = '';
    }
  } catch (e) {
    if (e.kind === 'auth_required') return;
    // A frame this credential is not permitted to read is a refusal with a
    // reason, not an absence. Leaving the static "no frame yet" placeholder up
    // would report an empty buffer on a rig that has frames.
    if (e.kind === 'scope_denied') {
      sayNoFrame(scopeRefusalText('Seeing the latest frame', e.detail));
      return;
    }
    // A rate-limited or unreachable server is already stated by the link
    // banner; the placeholder simply remains.
    if (e.kind === 'rate_limited' || e.kind === 'unreachable') {
      renderLinkState();
    }
  } finally {
    setFrameLoading(false);
    frameBusy = false;
  }
}

// ---------------------------------------------------------------------------
// Playback controls
// ---------------------------------------------------------------------------
/// POST a control and report what the server actually answered.
///
/// A 200 is not consent. `POST /api/sequencer/stop` answers 200 with
/// `wasRunning: false` and "No sequence was running; nothing to stop." when
/// there is nothing to stop, and this surface used to reply "Stop sent" to
/// that — a green toast for a command the server declined. The body carries
/// the verdict; read it.
///
/// Pause / Resume / Skip carry that same `wasRunning` verdict, and they carry
/// it on a REFUSAL: the server answers 409 `sequencer_not_running` rather
/// than performing a command that would overwrite the state of a run that has
/// already ended. So the verdict is read before the status code is judged —
/// "nothing to pause" is a fact about the rig, not a fault, and it earns the
/// same warning toast Stop's no-op does rather than a red failure.
async function sequencerAction(path, label, body) {
  try {
    const opts = { method: 'POST' };
    if (body != null) {
      opts.headers = { 'Content-Type': 'application/json' };
      opts.body = JSON.stringify(body);
    }
    const res = await apiFetch(path, opts);
    const payload = await apiJsonOrNull(res);
    const refused = payload != null &&
      (payload.wasRunning === false || payload.accepted === false);
    if (refused) {
      toast(
        (payload.message || `${label} had no effect`),
        'warning',
      );
      // Refused or not, the answer describes a rig this page's cache may
      // disagree with — re-read it rather than leaving the stale badge up.
      fetchSnapshot();
      return;
    }
    if (!res.ok) {
      const msg = (payload && (payload.message || payload.error)) || res.statusText;
      toast(`${label} failed: ${msg}`, 'error');
      return;
    }
    toast(`${label} accepted`, 'success');
    fetchSnapshot();
  } catch (e) {
    if (e.kind === 'auth_required') return;
    if (e.kind === 'scope_denied') {
      // The rig refused the ACTION, not the credential. Say so on the control
      // and in a toast, and leave the control disabled with its reason so the
      // next press cannot be a silent no-op either.
      const sentence = scopeRefusalText(label, e.detail);
      noteControlRefused(path, sentence);
      toast(sentence, 'warning');
      return;
    }
    if (e.kind === 'rate_limited') {
      toast(
        `${label} not sent — server is rate-limiting this device. ` +
        `Try again in ${e.detail.retryAfterSecs}s.`,
        'warning',
      );
      renderLinkState();
      return;
    }
    if (e.kind === 'unreachable') {
      toast(`${label} not sent — cannot reach the server`, 'error');
      renderLinkState();
      return;
    }
    toast(`${label} failed: ${e.message}`, 'error');
  }
}

// ---------------------------------------------------------------------------
// Settings sheet (wake lock, push, logout)
//
// Both toggles ride on APIs the browser only exposes to a SECURE context, and
// the address a phone actually uses to reach an observatory rig — the plain
// http:// LAN address of the desktop — is not one. Measured on that origin:
// `'wakeLock' in navigator` is false, the service worker never registers, and
// Notification.permission is pinned at "denied" before anything is asked. The
// page's answer to all of that used to be a checkbox that stayed ticked: the
// wake-lock branch had no `else`, and the push branch only acted on a
// permission of "default", so at "denied" it returned having done nothing.
// The feature worked in loopback testing and was dead in deployment, which is
// exactly why it survived.
//
// The support verdicts below are FEATURE TESTS — what this origin can actually
// do — never a guess from the user agent.
// ---------------------------------------------------------------------------

/// Whether this origin can hold a screen wake lock, and why not when it
/// cannot. The reason is a sentence for the operator, not a diagnostic.
function wakeLockSupport() {
  if ('wakeLock' in navigator) return { available: true, reason: null };
  if (!window.isSecureContext) {
    return {
      available: false,
      reason: 'Your browser only allows this over HTTPS. This page is served '
        + 'over plain HTTP, so the screen will sleep as usual.',
    };
  }
  return {
    available: false,
    reason: 'This browser has no screen wake-lock support.',
  };
}

/// Whether this origin can raise a notification, and why not when it cannot.
///
/// A blocked permission is reported separately from a missing API: on an
/// insecure origin the permission is already "denied" and cannot be asked for,
/// while on a secure one the operator can still change their mind.
function notificationSupport() {
  if (!('Notification' in window)) {
    return {
      available: false,
      reason: 'This browser has no notification support.',
    };
  }
  if (!window.isSecureContext) {
    return {
      available: false,
      reason: 'Your browser only allows notifications over HTTPS. This page is '
        + 'served over plain HTTP, so nothing can be delivered — watch this '
        + 'screen instead.',
    };
  }
  if (window.Notification.permission === 'denied') {
    return {
      available: false,
      reason: 'Notifications are blocked for this site in your browser '
        + 'settings.',
    };
  }
  return { available: true, reason: null };
}

/// Paint one toggle from its support verdict: an unavailable capability is
/// disabled, forced off, and told plainly why. Any stored opt-in for it is
/// cleared, so nothing on this device goes on claiming an ability it lacks.
function applyCapabilitySupport(inputId, rowId, noteId, support, opts, optKey) {
  const input = $(inputId);
  const note = $(noteId);
  const label = $(rowId);
  if (!input) return;
  if (support.available) {
    input.disabled = false;
    if (label) label.classList.remove('unavailable');
    if (note) { note.classList.add('hidden'); note.textContent = ''; }
    return;
  }
  input.disabled = true;
  input.checked = false;
  if (label) label.classList.add('unavailable');
  if (note) { note.textContent = support.reason; note.classList.remove('hidden'); }
  if (opts[optKey]) {
    opts[optKey] = false;
    saveOpts(opts);
  }
}

/// Bring the sheet's two toggles in line with what this origin can do. Called
/// at boot and every time the sheet opens, because a permission can be revoked
/// from browser settings between openings.
function refreshCapabilityToggles() {
  const opts = loadOpts();
  applyCapabilitySupport(
    'opt-wake-lock', 'opt-wake-lock-row', 'opt-wake-lock-note',
    wakeLockSupport(), opts, 'wakeLock');
  applyCapabilitySupport(
    'opt-push', 'opt-push-row', 'opt-push-note',
    notificationSupport(), opts, 'push');
}

let wakeLock = null;
async function applyWakeLockOption() {
  const opts = loadOpts();
  const support = wakeLockSupport();
  if (!support.available) {
    // Refuse out loud. Silence here is what let the toggle stay ticked over a
    // screen that went on sleeping.
    if (opts.wakeLock) {
      opts.wakeLock = false;
      saveOpts(opts);
      toast('Keep screen awake is unavailable — ' + support.reason, 'warning');
    }
    refreshCapabilityToggles();
    return;
  }
  if (opts.wakeLock) {
    try {
      wakeLock = await navigator.wakeLock.request('screen');
      wakeLock.addEventListener('release', () => { wakeLock = null; });
    } catch (e) {
      // The API is here and the request was still refused — a background tab,
      // a battery-saver policy, the operator's own denial. Report the
      // browser's own reason and untick what did not take.
      opts.wakeLock = false;
      saveOpts(opts);
      $('opt-wake-lock').checked = false;
      toast('Could not keep the screen awake: ' +
        (e && e.message ? e.message : String(e)), 'warning');
    }
  } else if (wakeLock) {
    try { await wakeLock.release(); } catch { /* ignore */ }
    wakeLock = null;
  }
}

async function applyPushOption() {
  const opts = loadOpts();
  if (!opts.push) return;
  const support = notificationSupport();
  if (!support.available) {
    opts.push = false;
    saveOpts(opts);
    toast('Notifications are unavailable — ' + support.reason, 'warning');
    refreshCapabilityToggles();
    return;
  }
  if (window.Notification.permission === 'default') {
    const perm = await window.Notification.requestPermission();
    if (perm !== 'granted') {
      opts.push = false;
      saveOpts(opts);
      $('opt-push').checked = false;
      toast('Notifications stay off — permission was not granted.', 'warning');
      refreshCapabilityToggles();
    }
  }
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
window.addEventListener('DOMContentLoaded', () => {
  // Pairing screen wiring
  const btnRequestCode = $('btn-request-code');
  if (btnRequestCode) {
    btnRequestCode.addEventListener('click', () => requestPairingCode());
  }
  $('btn-pair').addEventListener('click', () => startPairing($('pair-code').value));
  $('pair-code').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') startPairing($('pair-code').value);
  });
  $('btn-manual-token').addEventListener('click', () => {
    const t = $('manual-token').value.trim();
    if (!t) return;
    // Typed by hand and shown to nobody yet — the rig has not accepted it, and
    // a refusal must not be described as a pairing that was withdrawn.
    setToken(t, false);
    adoptedBearer = null;
    sessionCsrfToken = null;
    credentialSource = 'paired';
    showMainScreen();
  });

  // Playback wiring
  $('btn-pause').addEventListener('click', () =>
    sequencerAction('/api/sequencer/pause', 'Pause'));
  $('btn-resume').addEventListener('click', () =>
    sequencerAction('/api/sequencer/resume', 'Resume'));
  $('btn-skip').addEventListener('click', () =>
    sequencerAction('/api/sequencer/skip', 'Skip'));
  $('btn-stop').addEventListener('click', () => {
    if (confirm('Stop the running sequence?')) {
      sequencerAction('/api/sequencer/stop', 'Stop');
    }
  });
  const btnReset = $('btn-reset');
  if (btnReset) {
    btnReset.addEventListener('click', () => {
      if (confirm('Reset the sequencer state?')) {
        sequencerAction('/api/sequencer/reset', 'Reset');
      }
    });
  }
  const btnDither = $('btn-guide-dither');
  if (btnDither) {
    btnDither.addEventListener('click', () =>
      sequencerAction('/api/phd2/dither', 'Dither', { amount: 5.0 }));
  }
  const btnCpResume = $('btn-checkpoint-resume');
  if (btnCpResume) {
    btnCpResume.addEventListener('click', () =>
      sequencerAction('/api/sequencer/checkpoint/resume', 'Restore checkpoint'));
  }
  const btnCpDiscard = $('btn-checkpoint-discard');
  if (btnCpDiscard) {
    btnCpDiscard.addEventListener('click', () => {
      if (confirm('Discard the saved checkpoint?')) {
        sequencerAction('/api/sequencer/checkpoint/discard', 'Discard checkpoint');
      }
    });
  }

  // Settings sheet
  $('btn-settings').addEventListener('click', () => {
    const opts = loadOpts();
    $('opt-wake-lock').checked = !!opts.wakeLock;
    $('opt-push').checked = !!opts.push;
    // Re-tested on every opening, not cached at boot: a notification
    // permission can be granted or revoked from browser settings while this
    // page stays open.
    refreshCapabilityToggles();
    $('settings-modal').classList.remove('hidden');
  });
  $('btn-settings-close').addEventListener('click', () => {
    $('settings-modal').classList.add('hidden');
  });
  $('opt-wake-lock').addEventListener('change', (e) => {
    const opts = loadOpts();
    opts.wakeLock = e.target.checked;
    saveOpts(opts);
    applyWakeLockOption();
  });
  $('opt-push').addEventListener('change', (e) => {
    const opts = loadOpts();
    opts.push = e.target.checked;
    saveOpts(opts);
    applyPushOption();
  });
  $('btn-logout').addEventListener('click', () => {
    // What "forget this device" costs depends on which credential is being
    // forgotten. A session cookie belongs to the whole browser, so signing out
    // of it signs the dashboard out too, and that is said rather than
    // discovered. A bearer borrowed from the dashboard's tab was never this
    // device's to keep in the first place.
    const source = credentialSource;
    if (source === 'session-cookie') endSessionCookie();
    forgetAllCredentials();
    // Named, so the same screen never appears without an account of how this
    // device got back to it.
    showPairScreen(
      source === 'session-cookie'
        ? 'Signed out of this browser\'s Skotiq session — the dashboard in '
          + 'this browser is signed out too. Pair with a code, or sign in again '
          + 'on the dashboard.'
        : source === 'dashboard-tab'
          ? 'Stopped using the dashboard\'s session in this tab. Pair this '
            + 'device with a code to keep watching after the tab closes.'
          : 'Signed out on this device. Pair again with a code when you want it '
            + 'back.',
      'info',
    );
  });

  // Service-worker registration. Failures are non-fatal — the app
  // still works without the offline shell.
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/run-watch/sw.js', { scope: '/run-watch/' })
      .catch(e => console.warn('SW register failed', e));
  }

  // Settle what this origin can do before anything reads the stored opt-ins,
  // so a device that was paired over HTTPS and is now on the LAN address does
  // not carry a tick for a capability it has lost.
  refreshCapabilityToggles();

  // Decide which screen to show, from the credentials this browser holds.
  resolveCredentialAndShow();

  // Re-apply wake-lock when the tab comes back to the foreground —
  // browsers drop the lock when the page is hidden.
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && loadOpts().wakeLock) {
      applyWakeLockOption();
    }
  });
});
