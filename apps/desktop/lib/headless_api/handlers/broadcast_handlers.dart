// Live-stacking broadcast endpoints.
//
// Public-facing HTTP surface for the EAA / outreach broadcast. When a
// `LiveStackingNode` is active the four endpoints below serve the
// building stack to anyone on the LAN (or a public outreach URL when
// `auth_token` is empty):
//
//   GET  /api/broadcast/live-stack       — the latest stacked JPEG.
//   GET  /api/broadcast/info             — JSON metadata (target,
//                                          frames, integration, mode).
//   GET  /api/broadcast/sse              — Server-Sent Events stream
//                                          pushing one event per new
//                                          stacked frame.
//   GET  /broadcast                      — minimal HTML page (no JS
//                                          frameworks) for direct
//                                          audience viewing on phones.
//
// Auth model: the broadcast endpoints DELIBERATELY bypass the
// dashboard's pairing-token middleware so a phone in the audience can
// hit them without going through the operator's login flow. When the
// `LiveStackingNode` has an `auth_token` set, every request requires
// `?token=…` matching that value (constant-time compared inside the
// broadcast service). Public broadcasts (no token) answer 200 to
// everyone. The `/dashboard` and `/run-watch` surfaces — which DO
// take rig-control actions — keep their own pairing-token middleware
// untouched.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';

class BroadcastHandlers {
  final ProviderContainer container;

  BroadcastHandlers({required this.container});

  LiveStackingBroadcastService get _service =>
      container.read(liveStackingBroadcastServiceProvider);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'BroadcastHandlers');
  void _logWarning(String message) =>
      _logger.warning(message, source: 'BroadcastHandlers');

  // GET /api/broadcast/info

  /// Returns a JSON snapshot of the broadcast state. When no broadcast
  /// is active the response is `{"active": false}` so the public HTML
  /// page can render a "broadcast not running" banner without
  /// triggering an error condition.
  Future<Response> handleInfo(Request request) async {
    final state = _service.state;

    if (!state.active) {
      return jsonOk({'active': false}, headers: _jsonHeaders());
    }

    final authError = _checkAuth(request, state);
    if (authError != null) return authError;

    // Side effect: bump the viewer-count hint so the operator sees
    // when the audience is engaged. Best-effort only — the count is
    // reset on a fixed cadence by the dashboard's refresh timer.
    _service.incrementViewers();

    final body = state.toInfoJson();
    body['watermark'] = _service.renderWatermark();
    body['serverTime'] = DateTime.now().toUtc().toIso8601String();
    return jsonOk(body, headers: _jsonHeaders());
  }

  // GET /api/broadcast/live-stack

  /// Returns the most-recently rendered watermarked JPEG. 404 when
  /// no frame has been stacked yet (the page should fall back to a
  /// "warming up" placeholder). 401 when a token is required and
  /// missing/incorrect.
  Future<Response> handleLiveStack(Request request) async {
    final state = _service.state;
    if (!state.active) {
      return jsonNotFound({
        'error': 'no_broadcast',
        'message': 'Broadcast not armed',
      }, headers: _jsonHeaders());
    }

    final authError = _checkAuth(request, state);
    if (authError != null) return authError;

    final jpeg = state.jpegBytes;
    if (jpeg == null || jpeg.isEmpty) {
      return jsonNotFound({
        'error': 'no_frame',
        'message': 'Broadcast armed but no frame stacked yet.',
      }, headers: _jsonHeaders());
    }
    return contentResponse(
      jpeg,
      contentType: 'image/jpeg',
      contentLength: jpeg.length,
      headers: {
        'cache-control': 'no-store, no-cache, must-revalidate',
        'x-broadcast-frames': state.framesStacked.toString(),
        'x-broadcast-integration-secs': state.integrationSecs.toStringAsFixed(
          0,
        ),
      },
    );
  }

  // GET /api/broadcast/sse

  /// Server-Sent Events stream. Emits one named `frame` event per new
  /// stacked frame, plus periodic `: keepalive` comments to defeat
  /// idle proxies.
  Response handleSse(Request request) {
    final state = _service.state;
    if (!state.active) {
      return jsonNotFound({'error': 'no_broadcast'}, headers: _jsonHeaders());
    }
    final authError = _checkAuth(request, state);
    if (authError != null) return authError;

    final controller = StreamController<List<int>>();
    StreamSubscription<BroadcastUpdate>? sub;
    Timer? keepAlive;
    var counter = 0;

    void write(String s) {
      if (controller.isClosed) return;
      controller.add(utf8.encode(s));
    }

    controller.onListen = () {
      _logInfo('Broadcast SSE client connected');
      // Tell EventSource to wait 5s before reconnecting after a drop.
      // Mirrors the run-watch stream so the broadcast page can
      // share its CSP / fetch policy.
      write('retry: 5000\n\n');

      sub = _service.updates.listen(
        (update) {
          try {
            counter += 1;
            final json = jsonEncode(update.toJson());
            write('event: frame\nid: $counter\ndata: $json\n\n');
          } catch (e) {
            _logWarning('Broadcast SSE encode failed: $e');
          }
        },
        onError: (Object e, _) {
          _logWarning('Broadcast SSE upstream error: $e');
        },
      );

      keepAlive = Timer.periodic(const Duration(seconds: 20), (_) {
        write(': keepalive\n\n');
      });
    };

    Future<void> cleanup() async {
      keepAlive?.cancel();
      keepAlive = null;
      await sub?.cancel();
      sub = null;
      _logInfo('Broadcast SSE client disconnected');
    }

    controller.onCancel = cleanup;

    return streamResponse(
      controller.stream,
      contentType: 'text/event-stream; charset=utf-8',
      headers: {
        'cache-control': 'no-cache, no-transform',
        'connection': 'keep-alive',
        'x-accel-buffering': 'no',
      },
      context: {'shelf.io.buffer_output': false},
    );
  }

  // GET /broadcast

  /// Returns a minimal, vanilla-JS, no-framework HTML page that an
  /// audience can open on their phone. Auto-refreshes the live image
  /// at 2 s intervals (slower than the typical sub cadence, so the
  /// browser never queues up requests) and renders the same telemetry
  /// the operator sees on the run dashboard.
  ///
  /// The page is intentionally framework-free so it loads on any
  /// browser and degrades to the bare image when JavaScript is
  /// disabled — the typical audience member running the latest mobile
  /// Safari does not need a build pipeline.
  Future<Response> handleBroadcastPage(Request request) async {
    final state = _service.state;
    final token = request.url.queryParameters['token'];
    final hasToken = token != null && token.isNotEmpty;
    // For the HTML page we are deliberately lenient when no token is
    // supplied: we render the page with a "private — token required"
    // message rather than 401, so an audience member sees a helpful
    // hint instead of a browser error.
    final showImage = state.active && _service.authorize(token);
    final html = _renderHtml(state, showImage: showImage, hasToken: hasToken);
    return contentResponse(
      html,
      contentType: 'text/html; charset=utf-8',
      headers: {
        'cache-control': 'no-cache, no-store, must-revalidate',
        // CSP that allows nothing but our own resources. The HTML uses
        // no external CSS / JS / images so default-src 'self' suffices.
        'content-security-policy':
            "default-src 'self'; img-src 'self';"
            " style-src 'unsafe-inline'; script-src 'unsafe-inline'",
      },
    );
  }

  // Internal helpers

  Map<String, String> _jsonHeaders() => {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  };

  /// Validate the `?token=` query parameter for endpoints that should
  /// reject mismatched / missing tokens with 401. Returns `null` on
  /// success, or a 401 [Response] on failure.
  Response? _checkAuth(Request request, BroadcastSessionState state) {
    final token = request.url.queryParameters['token'];
    if (_service.authorize(token)) return null;
    return jsonUnauthorized({
      'error': 'invalid_token',
      'message': 'This broadcast requires a token. Append ?token=… to the URL.',
    }, headers: _jsonHeaders());
  }

  /// Render the broadcast HTML page. Kept inline (rather than a static
  /// file) so the build doesn't have to ship an additional asset and
  /// the rendered page can interpolate the live broadcast state on
  /// first paint.
  String _renderHtml(
    BroadcastSessionState state, {
    required bool showImage,
    required bool hasToken,
  }) {
    const escapeAttr = _htmlAttrEscape;
    const escapeText = _htmlTextEscape;
    final imgSrc = showImage
        ? '/api/broadcast/live-stack${hasToken ? '?token=…' : ''}'
        : '';

    final infoSrc = '/api/broadcast/info${hasToken ? '?token=…' : ''}';
    final sseSrc = '/api/broadcast/sse${hasToken ? '?token=…' : ''}';

    final statusBlock = state.active
        ? '<span class="ok">Live</span>'
        : '<span class="off">Off-air</span>';

    final tokenBanner = (!showImage && state.active)
        ? '<div class="banner">This broadcast is private. '
              'Append <code>?token=…</code> to the URL to view.</div>'
        : '';

    final offlineBanner = state.active
        ? ''
        : '<div class="banner">The broadcast is not currently armed. '
              'It will start once the operator adds a Live Stacking node '
              'to their running sequence.</div>';

    final initialTarget = escapeText(state.currentTarget ?? '—');
    final initialFrames = state.framesStacked.toString();
    final initialIntegration = escapeText(state.integrationHms);
    final initialWatermark = escapeText(_service.renderWatermark());

    return '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Skotiq Broadcast</title>
<style>
  :root {
    color-scheme: dark;
    font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    /* Matches packages/skotiq_ui SkotiqColors.dark */
    --color-background: #0A0C0F;
    --color-surface: #111418;
    --color-surface-alt: #181C22;
    --color-border: #2E353F;
    --color-text-primary: #E8EAED;
    --color-text-muted: #6B7380;
    --color-success: #3DAA6D;
    --color-warning: #D49A3A;
    --color-error: #D85C5C;
    --tint-warning: rgba(212, 154, 58, 0.2);
  }
  body {
    background: var(--color-background);
    color: var(--color-text-primary);
    margin: 0;
    padding: 0;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
  }
  header {
    padding: 12px 16px;
    border-bottom: 1px solid var(--color-border);
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
  }
  header h1 {
    font-size: 1.05rem;
    font-weight: 600;
    margin: 0;
    color: var(--color-text-primary);
  }
  .status .ok { color: var(--color-success); font-weight: 600; }
  .status .off { color: var(--color-error); font-weight: 600; }
  main {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 16px;
    gap: 12px;
  }
  .stage {
    width: 100%;
    max-width: 1280px;
    background: #000;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    overflow: hidden;
    aspect-ratio: 16 / 9;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .stage img {
    width: 100%;
    height: 100%;
    object-fit: contain;
    display: block;
  }
  .stage .placeholder {
    color: var(--color-text-muted);
    font-size: 0.95rem;
    text-align: center;
    padding: 16px;
  }
  .telemetry {
    width: 100%;
    max-width: 1280px;
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
    gap: 8px;
  }
  .tile {
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 6px;
    padding: 10px 14px;
  }
  .tile .label {
    color: var(--color-text-muted);
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
  }
  .tile .value {
    color: var(--color-text-primary);
    font-size: 1.2rem;
    font-weight: 600;
    margin-top: 4px;
  }
  .banner {
    background: var(--tint-warning);
    border: 1px solid var(--color-warning);
    color: var(--color-text-primary);
    border-radius: 6px;
    padding: 10px 14px;
    width: 100%;
    max-width: 1280px;
    font-size: 0.9rem;
  }
  footer {
    color: var(--color-text-muted);
    font-size: 0.75rem;
    text-align: center;
    padding: 12px 16px;
    border-top: 1px solid var(--color-border);
  }
  code {
    background: var(--color-surface-alt);
    padding: 1px 6px;
    border-radius: 3px;
  }
</style>
</head>
<body>
  <header>
    <h1>Skotiq Live Broadcast</h1>
    <div class="status">$statusBlock</div>
  </header>
  <main>
    $tokenBanner
    $offlineBanner
    <div class="stage">
      ${showImage ? '<img id="broadcast-img" alt="Live stack" '
              'src="${escapeAttr(imgSrc)}">' : '<div class="placeholder">Awaiting first frame…</div>'}
    </div>
    <div class="telemetry">
      <div class="tile">
        <div class="label">Target</div>
        <div class="value" id="t-target">$initialTarget</div>
      </div>
      <div class="tile">
        <div class="label">Frames</div>
        <div class="value" id="t-frames">$initialFrames</div>
      </div>
      <div class="tile">
        <div class="label">Integration</div>
        <div class="value" id="t-integration">$initialIntegration</div>
      </div>
      <div class="tile">
        <div class="label">Stack method</div>
        <div class="value">${escapeText(state.stackMethod.label)}</div>
      </div>
    </div>
    ${initialWatermark.isNotEmpty ? '<div class="tile" style="max-width:1280px;width:100%"><div class="label">Watermark</div><div class="value" id="t-watermark">$initialWatermark</div></div>' : ''}
  </main>
  <footer>Powered by Skotiq · Live stacking refreshes automatically</footer>
  <script>
    // Auto-refresh the image at 2 s — slow enough to keep up with even
    // 60 s subs without flooding the network on burst captures, and the
    // ?t= query forces the browser to bypass intermediary caches.
    var imgEl = document.getElementById('broadcast-img');
    var imgSrc = ${jsonEncode(imgSrc)};
    function refreshImage() {
      if (!imgEl || !imgSrc) return;
      var separator = imgSrc.indexOf('?') >= 0 ? '&' : '?';
      imgEl.src = imgSrc + separator + 't=' + Date.now();
    }
    if (imgEl) setInterval(refreshImage, 2000);

    // Telemetry polling via /info. Same 2 s cadence as the image so
    // the displayed frame counter matches what's on the wire.
    var infoUrl = ${jsonEncode(infoSrc)};
    function refreshInfo() {
      if (!infoUrl) return;
      fetch(infoUrl, { credentials: 'omit', cache: 'no-store' })
        .then(function (r) { return r.ok ? r.json() : null; })
        .then(function (j) {
          if (!j || j.active !== true) return;
          var t = document.getElementById('t-target');
          var f = document.getElementById('t-frames');
          var i = document.getElementById('t-integration');
          var w = document.getElementById('t-watermark');
          if (t) t.textContent = j.currentTarget || '—';
          if (f) f.textContent = String(j.framesStacked);
          if (i) i.textContent = j.integrationHms || '0s';
          if (w && typeof j.watermark === 'string') w.textContent = j.watermark;
        })
        .catch(function () { /* swallow — best effort */ });
    }
    setInterval(refreshInfo, 2000);

    // SSE drives an immediate refresh when a new frame lands, so the
    // 2 s timer above only acts as a safety net for missed events.
    try {
      var es = new EventSource(${jsonEncode(sseSrc)}, { withCredentials: false });
      es.addEventListener('frame', function () {
        refreshImage();
        refreshInfo();
      });
    } catch (e) { /* No EventSource? Polling already handles it. */ }
  </script>
</body>
</html>
''';
  }
}

String _htmlAttrEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _htmlTextEscape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
