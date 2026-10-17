/// `GET /pair` — the self-contained browser pairing page.
///
/// The ~300-line inline HTML page (a distinct responsibility — a no-app,
/// no-SSH pairing UI) lives apart from the JSON info/self-test handlers.
/// The handler is an extension on
/// [SystemHandlers] so the route wiring (`h.handlePairPage`) resolves
/// unchanged.
library;

import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import 'system_handlers.dart';

/// The `/pair` browser pairing page handler.
extension SystemPairPageHandler on SystemHandlers {
  /// `GET /pair` — a self-contained browser pairing page.
  ///
  /// Lets an operator pair from ANY browser on the LAN without the mobile app
  /// and without reading the appliance terminal. The page is pure vanilla JS
  /// (no build pipeline, kept inline like `/broadcast`) and does all its work
  /// client-side against the already-public pairing endpoints.
  ///
  /// Security note: this page never surfaces the pairing code itself. The
  /// code is the out-of-band trust factor and is intentionally kept to the
  /// operator-visible log only; printing it on a same-LAN HTTP page would
  /// defeat the code flow (any LAN device could read it). The expiry
  /// envelope from `/api/pairing/start` is safe to show.
  Future<Response> handlePairPage(Request request) async {
    return contentResponse(
      _pairPageHtml,
      contentType: 'text/html; charset=utf-8',
      headers: {
        'cache-control': 'no-cache, no-store, must-revalidate',
        // Same-origin only; the page uses inline <style>/<script> and fetches
        // its own /api/* endpoints, nothing external.
        'content-security-policy':
            "default-src 'self'; img-src 'self'; "
            "style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
            "connect-src 'self'",
      },
    );
  }
}

/// Inline HTML for `GET /pair` (see [SystemPairPageHandler.handlePairPage]).
///
/// A raw Dart string so the embedded JavaScript can use `$`, `${}`, and
/// backslashes without Dart interpolation getting in the way. The page is
/// fully self-contained: no external CSS/JS/images, no build pipeline.
const String _pairPageHtml = r'''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pair with Skotiq</title>
<style>
  :root {
    color-scheme: dark;
    font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    --color-background: #0A0C0F;
    --color-surface: #111418;
    --color-surface-alt: #181C22;
    --color-border: #2E353F;
    --color-text-primary: #E8EAED;
    --color-text-muted: #6B7380;
    --color-accent: #4C8DFF;
    --color-success: #3DAA6D;
    --color-warning: #D49A3A;
    --color-error: #D85C5C;
    --tint-warning: rgba(212, 154, 58, 0.2);
    --tint-success: rgba(61, 170, 109, 0.18);
  }
  body {
    background: var(--color-background);
    color: var(--color-text-primary);
    margin: 0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 16px;
    box-sizing: border-box;
  }
  .card {
    width: 100%;
    max-width: 460px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    padding: 24px;
  }
  h1 { font-size: 1.25rem; margin: 0 0 4px; }
  .rig { color: var(--color-text-muted); margin: 0 0 20px; font-size: 0.95rem; }
  .mode {
    display: inline-block;
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 3px 8px;
    border-radius: 4px;
    border: 1px solid var(--color-border);
    color: var(--color-text-muted);
    margin-bottom: 16px;
  }
  p { line-height: 1.5; }
  button {
    width: 100%;
    background: var(--color-accent);
    color: #fff;
    border: none;
    border-radius: 8px;
    padding: 12px 16px;
    font-size: 1rem;
    font-weight: 600;
    cursor: pointer;
    margin-top: 8px;
  }
  button:disabled { opacity: 0.5; cursor: default; }
  input[type=text] {
    width: 100%;
    box-sizing: border-box;
    background: var(--color-surface-alt);
    color: var(--color-text-primary);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    padding: 12px;
    font-size: 1.4rem;
    letter-spacing: 0.3em;
    text-align: center;
    margin-top: 12px;
  }
  .banner {
    border-radius: 8px;
    padding: 12px 14px;
    font-size: 0.9rem;
    margin-top: 16px;
    border: 1px solid var(--color-border);
  }
  .banner.ok { background: var(--tint-success); border-color: var(--color-success); }
  .banner.warn { background: var(--tint-warning); border-color: var(--color-warning); }
  .banner.err { background: rgba(216,92,92,0.18); border-color: var(--color-error); }
  code {
    background: var(--color-surface-alt);
    padding: 1px 6px;
    border-radius: 3px;
    word-break: break-all;
  }
  .token {
    display: block;
    margin-top: 8px;
    font-size: 0.8rem;
    user-select: all;
  }
  .muted { color: var(--color-text-muted); font-size: 0.85rem; }
  .hidden { display: none; }
</style>
</head>
<body>
  <div class="card">
    <h1>Pair with Skotiq</h1>
    <p class="rig" id="rig-name">Connecting to this appliance…</p>
    <span class="mode" id="mode-badge">checking…</span>

    <!-- lan-open flow -->
    <div id="lan-open" class="hidden">
      <p>This appliance allows one-tap pairing from the local network. Click
        below to pair this browser.</p>
      <button id="lan-claim-btn" type="button">Pair this browser</button>
    </div>

    <!-- code-required flow -->
    <div id="code-required" class="hidden">
      <p>This appliance requires a pairing code. Click below to start pairing,
        then read the code from the appliance's log
        (<code>journalctl -fu skotiq-headless</code>) and enter it here.</p>
      <button id="start-btn" type="button">Start pairing</button>
      <div id="code-entry" class="hidden">
        <input id="code-input" type="text"
               autocomplete="one-time-code" maxlength="32"
               placeholder="STAR-LYRA-1234">
        <p class="muted" id="expiry-note"></p>
        <button id="verify-btn" type="button">Complete pairing</button>
      </div>
    </div>

    <div id="result" class="banner hidden"></div>
  </div>

  <script>
    var modeBadge = document.getElementById('mode-badge');
    var rigName = document.getElementById('rig-name');
    var lanOpenEl = document.getElementById('lan-open');
    var codeReqEl = document.getElementById('code-required');
    var resultEl = document.getElementById('result');

    function show(el) { el.classList.remove('hidden'); }
    function hide(el) { el.classList.add('hidden'); }

    function showResult(kind, html) {
      resultEl.className = 'banner ' + kind;
      resultEl.innerHTML = html;
      show(resultEl);
    }

    function escapeHtml(s) {
      return String(s)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
    }

    function showPaired(token) {
      if (!token) {
        showResult('err', 'Pairing did not return a session token.');
        return Promise.resolve(false);
      }
      // A pairing token alone does not authenticate normal browser navigation.
      // Exchange it immediately for the HttpOnly session cookie used by the
      // dashboard and WebSocket ticket endpoint.
      return fetch('/api/auth/cookie', {
        method: 'POST',
        headers: {
          'authorization': 'Bearer ' + token,
          'content-type': 'application/json'
        },
        body: '{}'
      })
        .then(function (r) {
          return r.json().then(function (b) {
            return { ok: r.ok, body: b };
          });
        })
        .then(function (res) {
          if (!res.ok || !res.body || !res.body.csrfToken) {
            var msg = (res.body && (res.body.message || res.body.error))
              || 'Could not establish the browser session.';
            showResult('err', escapeHtml(msg));
            return false;
          }
          var html = 'Paired ✓ '
            + '<a href="/dashboard/">Open dashboard</a>'
            + '<span class="muted">A secure browser session is active. '
            + 'The long-lived bearer credential is intentionally hidden.</span>';
          showResult('ok', html);
          return true;
        })
        .catch(function () {
          showResult('err', 'Network error while establishing the browser session.');
          return false;
        });
    }

    // Discover this rig: name + pairing mode.
    fetch('/api/info', { cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (info) {
        rigName.textContent = (info.name || 'Skotiq')
          + ' · v' + (info.version || '?');
        var mode = info.pairingMode || (info.lanPairing ? 'lan-open' : 'code-required');
        modeBadge.textContent = mode;
        if (mode === 'lan-open') {
          show(lanOpenEl);
        } else {
          show(codeReqEl);
        }
      })
      .catch(function () {
        rigName.textContent = 'Could not reach this appliance.';
        showResult('err', 'Failed to contact <code>/api/info</code>. '
          + 'Reload the page and try again.');
      });

    // lan-open: one-tap claim.
    var lanBtn = document.getElementById('lan-claim-btn');
    lanBtn.addEventListener('click', function () {
      lanBtn.disabled = true;
      lanBtn.textContent = 'Pairing…';
      fetch('/api/pairing/lan-claim', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ deviceName: 'Browser', deviceType: 'browser' })
      })
        .then(function (r) { return r.json().then(function (b) { return { ok: r.ok, body: b }; }); })
        .then(function (res) {
          if (res.ok && res.body && res.body.token) {
            showPaired(res.body.token);
            lanBtn.textContent = 'Paired ✓';
          } else {
            lanBtn.disabled = false;
            lanBtn.textContent = 'Pair this browser';
            var msg = (res.body && res.body.message) || 'Pairing was refused.';
            showResult('err', escapeHtml(msg));
            if (res.body && res.body.error === 'not_local_network') {
              hide(lanOpenEl);
              show(codeReqEl);
            }
          }
        })
        .catch(function () {
          lanBtn.disabled = false;
          lanBtn.textContent = 'Pair this browser';
          showResult('err', 'Network error while pairing. Try again.');
        });
    });

    // code-required: start, then verify the operator-entered code.
    var startBtn = document.getElementById('start-btn');
    var codeEntry = document.getElementById('code-entry');
    var verifyBtn = document.getElementById('verify-btn');
    var codeInput = document.getElementById('code-input');
    var expiryNote = document.getElementById('expiry-note');

    startBtn.addEventListener('click', function () {
      startBtn.disabled = true;
      startBtn.textContent = 'Starting…';
      fetch('/api/pairing/start', { method: 'POST' })
        .then(function (r) { return r.json().then(function (b) { return { ok: r.ok, body: b }; }); })
        .then(function (res) {
          if (res.ok) {
            show(codeEntry);
            startBtn.textContent = 'Restart pairing';
            startBtn.disabled = false;
            var secs = res.body && res.body.expiresInSeconds;
            var mins = secs ? Math.round(secs / 60) : 0;
            expiryNote.textContent = secs
              ? ('Code is valid for about ' + mins
                 + (mins === 1 ? ' minute' : ' minutes')
                 + '. Read it from the appliance log.')
              : 'Read the code from the appliance log.';
            showResult('warn', 'Pairing started. The code was printed '
              + 'to the appliance log — it is deliberately not sent over '
              + 'the network. Enter it below.');
          } else {
            startBtn.disabled = false;
            startBtn.textContent = 'Start pairing';
            var msg = (res.body && res.body.error) || 'Could not start pairing.';
            showResult('err', escapeHtml(msg));
          }
        })
        .catch(function () {
          startBtn.disabled = false;
          startBtn.textContent = 'Start pairing';
          showResult('err', 'Network error while starting pairing.');
        });
    });

    verifyBtn.addEventListener('click', function () {
      var code = (codeInput.value || '').trim();
      if (!code) { showResult('err', 'Enter the code first.'); return; }
      verifyBtn.disabled = true;
      verifyBtn.textContent = 'Verifying…';
      fetch('/api/pairing/verify', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ code: code, deviceName: 'Browser', deviceType: 'browser' })
      })
        .then(function (r) { return r.json().then(function (b) { return { ok: r.ok, body: b }; }); })
        .then(function (res) {
          verifyBtn.disabled = false;
          verifyBtn.textContent = 'Complete pairing';
          if (res.ok && res.body && res.body.token) {
            hide(codeEntry);
            showPaired(res.body.token);
          } else {
            var msg = (res.body && res.body.message) || 'The code was not accepted.';
            showResult('err', escapeHtml(msg));
          }
        })
        .catch(function () {
          verifyBtn.disabled = false;
          verifyBtn.textContent = 'Complete pairing';
          showResult('err', 'Network error while verifying the code.');
        });
    });
  </script>
</body>
</html>
''';
