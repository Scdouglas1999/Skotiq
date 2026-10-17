/**
 * Skotiq Headless API Client
 *
 * Wraps all REST and WebSocket endpoints exposed by the headless server.
 * Handles authentication, request retries, and event streaming.
 */

/**
 * Typed failure from a REST call. Callers switch on `kind` instead of
 * pattern-matching message text:
 *
 *   'unreachable'   the fetch never completed — the server is gone, not slow.
 *                   This is the only proof the dashboard gets that the rig it
 *                   is painting green may have been off for an hour.
 *   'timeout'       the request was aborted at _requestTimeoutMs.
 *   'rate_limited'  429. `retryAfterSecs` is the server's own window
 *                   (rate_limit_middleware `_denyRateLimited`).
 *   'scope_denied'  403 that NAMES the capability it refused on
 *                   (`requiredResource` + `requiredLevel`, from
 *                   `HeadlessAuthPolicy.scopeDenialBody`). The credential was
 *                   ACCEPTED and is not permitted here — a different event
 *                   from one the server would not accept at all, and the
 *                   difference decides whether the operator should re-pair or
 *                   pair with more scope. `detail` carries the server's own
 *                   `resource`/`requiredLevel`/`tokenLevel` so a caller can
 *                   state the reason instead of pasting the JSON.
 *   'http_error'    any other non-2xx, including a 401 and any 403 that named
 *                   no capability (an unknown bearer answers that way).
 *   'bad_json'      2xx whose body would not parse.
 *   'unusable_answer'
 *                   2xx that parsed and carries no answer this client can
 *                   read — an empty body, or a body that is not a JSON object
 *                   (`null`/`0`/`false`/`""`, a list, a bare string or number).
 *                   Every route here answers with an object and every caller
 *                   reads named fields off it, so the rest is the wrong SHAPE.
 *                   The exchange FAILED: nothing was learned from it, so no
 *                   panel may render a positive state off the back of it. Same
 *                   kind, and the same stance, as web_run_watch/js/run-watch.js.
 */
class SkotiqApiError extends Error {
  constructor(kind, message, detail) {
    super(message);
    this.name = 'SkotiqApiError';
    this.kind = kind;
    this.detail = detail || {};
    if (this.detail.retryAfterSecs != null) {
      this.retryAfterSecs = this.detail.retryAfterSecs;
    }
    if (this.detail.status != null) this.status = this.detail.status;
  }
}

class SkotiqApi {
  constructor() {
    this._baseUrl = '';
    this._authToken = '';
    this._deviceId = '';
    this._apiVersion = '2.6.0';
    this._requestCounter = 0;
    this._ws = null;
    this._wsReconnectTimer = null;
    this._wsReconnectDelay = 1000;
    this._maxReconnectDelay = 30000;
    this._wsHeartbeatTimer = null;
    this._lastWsMessageAt = 0;
    this._wsHeartbeatTimeoutMs = 90000;
    this._requestTimeoutMs = 8000;
    this._connectionTimeoutMs = 4000;
    this._eventListeners = new Map();
    this._connected = false;
    this._wsConnected = false;
    // CSRF token bound to the HttpOnly session cookie.
    // In-memory only — never persisted to storage. The cookie itself is
    // HttpOnly so JS can't read it; the CSRF token is what proves a
    // request originated from the SPA rather than from an attacker who
    // tricked the browser into sending the cookie ambient-style.
    this._csrfToken = '';
    // When true, fetches include the session cookie via
    // `credentials: 'include'` AND echo `X-Skotiq-CSRF` on writes.
    // Toggled on after a successful POST /api/auth/cookie OR when the
    // server confirms a pre-existing session via GET /api/auth/csrf.
    this._useSessionCookie = false;
    // Rate-limit gate. The server budgets 60 reads/s and 20 writes/s per token
    // (`defaultTokenBucketConfigs`); `fetchAllStatus` alone fires a dozen
    // requests in one tick, so a burst can meet the ceiling. Requests are held
    // until the server's own retry window elapses rather than hammering the
    // limiter and printing its refusal body on screen.
    this._rateLimitedUntil = 0;
    // Epoch ms of the last completed exchange with the server, whatever the
    // status code. A response — even a 500 — proves it is there.
    this._lastContactAt = 0;
  }

  /** Epoch ms of the last completed HTTP exchange, or 0 if there has been none. */
  get lastContactAt() { return this._lastContactAt; }

  /** Whole seconds left on the server's rate-limit window; 0 when clear. */
  get rateLimitRemainingSecs() {
    const ms = this._rateLimitedUntil - Date.now();
    return ms > 0 ? Math.ceil(ms / 1000) : 0;
  }

  /**
   * Read the retry window off a 429 response: the JSON body's
   * `retryAfterSecs` first, then the `retry-after` header, then one second.
   * Clamped so a hostile or buggy value cannot park the dashboard for hours.
   */
  /**
   * The capability a 403 refused on, or null when the answer named none.
   *
   * 401 and 403 are two different events. 401 says the credential was not
   * accepted; 403 says it WAS accepted and is not permitted here. The status
   * alone does not separate them on this API, because the middleware also
   * answers an unknown bearer with 403 ("Invalid authentication token"), so
   * what is keyed on is the body NAMING the requirement it refused on —
   * `requiredResource` + `requiredLevel`, which only the scope refusal sends.
   * Every other 4xx stays a plain `http_error`, so a genuinely bad credential
   * is still treated as one.
   */
  static _scopeRefusalFrom(status, text) {
    if (status !== 403 || !text) return null;
    let body;
    try { body = JSON.parse(text); } catch (_) { return null; }
    if (!body || typeof body !== 'object') return null;
    const resource = body.requiredResource;
    const requiredLevel = body.requiredLevel;
    if (typeof resource !== 'string' || !resource) return null;
    if (typeof requiredLevel !== 'string' || !requiredLevel) return null;
    return {
      resource,
      requiredLevel,
      tokenLevel: typeof body.tokenLevel === 'string' ? body.tokenLevel : null,
    };
  }

  static _retryAfterSecsFrom(res, text) {
    let secs = null;
    try {
      const body = JSON.parse(text);
      const raw = body && (body.retryAfterSecs ?? body.retryAfterSeconds);
      if (typeof raw === 'number' && isFinite(raw) && raw > 0) secs = raw;
    } catch (_) { /* not the JSON shape we know */ }
    if (secs == null) {
      const header = Number(res.headers.get('retry-after'));
      if (isFinite(header) && header > 0) secs = header;
    }
    return secs == null ? 1 : Math.min(Math.ceil(secs), 300);
  }

  /**
   * Configure the API base URL and auth token.
   * @param {string} baseUrl - e.g. "http://192.168.1.8:8080"
   * @param {string} authToken - Bearer token (empty string if auth disabled)
   * @param {string} deviceId - Paired device identifier for authenticated access
   */
  configure(baseUrl, authToken, deviceId) {
    this._baseUrl = baseUrl.replace(/\/+$/, '');
    this._authToken = authToken || '';
    this._deviceId = deviceId || '';
    this._connected = false;
    // Reconfiguring (e.g. user pasted a new token) invalidates any prior
    // cookie session — the caller will re-establish it via beginCookieSession.
    this._csrfToken = '';
    this._useSessionCookie = false;
  }

  get baseUrl() { return this._baseUrl; }
  get isConnected() { return this._connected; }
  get isWsConnected() { return this._wsConnected; }
  get hasSessionCookie() { return this._useSessionCookie; }
  get usesHeaderAuth() {
    return !this._useSessionCookie && Boolean(this._authToken);
  }

  // =========================================================================
  // HTTP helpers
  // =========================================================================

  _headers(extraHeaders, method) {
    const h = {
      'Content-Type': 'application/json',
      'X-Skotiq-API-Version': this._apiVersion,
      'X-Request-ID': this._nextRequestId(),
      ...extraHeaders,
    };
    // Cookie path: rely on the HttpOnly session cookie attached by the
    // browser; do NOT echo the bearer in the Authorization header (the
    // server's middleware accepts either, and avoiding the duplicate
    // ensures a single audit trail per session).
    //
    // Bearer path: continue to send Authorization as before. Mobile and
    // legacy clients keep working unchanged.
    if (!this._useSessionCookie && this._authToken) {
      h['Authorization'] = 'Bearer ' + this._authToken;
    }
    // Echo the CSRF token on every state-changing fetch when we're on the
    // cookie path. GET/HEAD do not need it (the server skips CSRF for
    // read-only methods because cross-site GET can't mutate state).
    if (this._useSessionCookie && this._csrfToken &&
        method && method !== 'GET' && method !== 'HEAD') {
      h['X-Skotiq-CSRF'] = this._csrfToken;
    }
    if (this._deviceId) {
      h['X-Skotiq-Device-Id'] = this._deviceId;
    }
    return h;
  }

  _nextRequestId() {
    this._requestCounter = (this._requestCounter + 1) % 1048575;
    return 'dash-' + Date.now().toString(36) + '-' + this._requestCounter.toString(36);
  }

  async _get(path) {
    return this._request('GET', path);
  }

  async _post(path, body) {
    return this._request('POST', path, body);
  }

  async _put(path, body) {
    return this._request('PUT', path, body);
  }

  async _delete(path) {
    return this._request('DELETE', path);
  }

  async _request(method, path, body, timeoutMs) {
    const waiting = this.rateLimitRemainingSecs;
    if (waiting > 0) {
      throw new SkotiqApiError(
        'rate_limited',
        'Server is rate-limiting this session',
        { retryAfterSecs: waiting, method, path },
      );
    }

    const controller = new AbortController();
    const timeout = setTimeout(
      () => controller.abort(),
      timeoutMs || this._requestTimeoutMs,
    );

    let resp;
    try {
      resp = await fetch(this._baseUrl + path, {
        method,
        headers: this._headers(undefined, method),
        // Always attach cookies on same-origin requests. Why unconditional:
        // the "remember" path rides an HttpOnly cookie, and omitting
        // credentials would stop that cookie round-tripping even when it is
        // present. Cross-origin allowance is gated by
        // Access-Control-Allow-Credentials server-side, so this stays
        // safe on disallowed origins.
        credentials: 'include',
        body: body != null
          ? JSON.stringify(body)
          : (method === 'POST' || method === 'PUT' ? '{}' : undefined),
        signal: controller.signal,
      });
    } catch (e) {
      if (e && e.name === 'AbortError') {
        throw new SkotiqApiError(
          'timeout',
          method + ' ' + path + ' timed out',
          { method, path },
        );
      }
      throw new SkotiqApiError(
        'unreachable',
        method + ' ' + path + ' could not reach the server',
        { method, path, cause: e },
      );
    } finally {
      clearTimeout(timeout);
    }

    this._lastContactAt = Date.now();
    const text = await resp.text();
    if (resp.status === 429) {
      const secs = SkotiqApi._retryAfterSecsFrom(resp, text);
      this._rateLimitedUntil = Date.now() + secs * 1000;
      // The body is deliberately not carried into the message: a rate-limit
      // refusal is a cadence problem, and pasting its JSON into the operator's
      // log panel taught nobody anything.
      throw new SkotiqApiError(
        'rate_limited',
        'Server is rate-limiting this session',
        { retryAfterSecs: secs, method, path },
      );
    }
    this._rateLimitedUntil = 0;
    if (!resp.ok) {
      const scope = SkotiqApi._scopeRefusalFrom(resp.status, text);
      if (scope) {
        throw new SkotiqApiError(
          'scope_denied',
          method + ' ' + path + ' is not permitted for this credential',
          Object.assign({ status: resp.status, method, path }, scope),
        );
      }
      throw new SkotiqApiError(
        'http_error',
        method + ' ' + path + ' failed (' + resp.status + '): ' + text,
        { status: resp.status, method, path, body: text },
      );
    }
    // A 2xx carrying nothing is a FAILED exchange wearing a success code.
    // This used to `return {}`, which handed every caller a well-formed empty
    // payload: measured against the release bundle, an empty-bodied 200 on
    // /api/devices/connected made the dashboard state "No devices connected"
    // over four connected devices — no stale line, no toast, no log entry,
    // header still reading "Connected" — and the same body on /api/images
    // produced "No captured images yet." over a night with 12 registered
    // frames. The sibling client already refuses this shape; this is that
    // refusal, here.
    if (!text) {
      throw new SkotiqApiError(
        'unusable_answer',
        method + ' ' + path + ' answered ' + resp.status +
          ' with an empty body',
        { status: resp.status, method, path },
      );
    }
    let payload;
    try {
      payload = JSON.parse(text);
    } catch (_) {
      throw new SkotiqApiError(
        'bad_json',
        method + ' ' + path + ' returned invalid JSON',
        { method, path },
      );
    }
    // The answer has to be the SHAPE the caller expects. Every route this
    // client calls answers with a JSON object and every caller reads named
    // fields off it, so anything else is unusable — not only the four falsy
    // values `JSON.parse` can produce (`null`, `0`, `false`, `""`), but a list
    // or a bare string/number/boolean, which has no fields to read at all.
    // Both end the same way: the caller falls through to its own defaults and
    // presents them as the server's. The falsy half used to be the whole
    // guard, and measured against the release bundle a 200 on `/api/info`
    // carrying `[1,2,3]` — identically `"hello"`, `42`, `true` — logged
    // `Connected to undefined vundefined`, left the header pill reading
    // "Connected", and dropped the Auth chip entirely, because
    // `info.authRequired` was `undefined` and the needs-credential branch
    // never fired. The sibling client refuses the whole set already
    // (`web_run_watch/js/run-watch.js` `applySnapshot`); this is that refusal,
    // here.
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
      throw new SkotiqApiError(
        'unusable_answer',
        method + ' ' + path + ' answered ' + resp.status + ' and ' +
          SkotiqApi.describeWireValue(payload),
        { status: resp.status, method, path },
      );
    }
    return payload;
  }

  /// What a 2xx body that is not a JSON object was, in words, for the refusal
  /// message. JSON carries no `undefined`, so every value reaching here came
  /// off the wire. The value itself is never interpolated: a hostile body must
  /// not reach the operator's log through an error string.
  static describeWireValue(v) {
    if (v === null) return 'the body is null';
    if (Array.isArray(v)) return 'the body is a list';
    if (v === '') return 'the body is an empty string';
    if (typeof v === 'string') return 'the body is a string';
    if (typeof v === 'boolean') return 'the body is the boolean ' + v;
    if (typeof v === 'number') return 'the body is a number';
    return 'the body is a ' + typeof v;
  }

  async _getWithTimeout(path, timeoutMs) {
    return this._request('GET', path, undefined, timeoutMs);
  }

  async _getBlob(path, timeoutMs) {
    const controller = new AbortController();
    const timeout = setTimeout(
      () => controller.abort(),
      timeoutMs || this._requestTimeoutMs,
    );
    let resp;
    try {
      resp = await fetch(this._baseUrl + path, {
        method: 'GET',
        headers: this._headers(undefined, 'GET'),
        credentials: 'include',
        signal: controller.signal,
      });
    } catch (e) {
      if (e && e.name === 'AbortError') {
        throw new SkotiqApiError('timeout', 'GET ' + path + ' timed out', {
          path,
        });
      }
      throw new SkotiqApiError(
        'unreachable',
        'GET ' + path + ' could not reach the server',
        { path, cause: e },
      );
    } finally {
      clearTimeout(timeout);
    }
    this._lastContactAt = Date.now();
    if (resp.status === 429) {
      const secs = SkotiqApi._retryAfterSecsFrom(resp, await resp.text());
      this._rateLimitedUntil = Date.now() + secs * 1000;
      throw new SkotiqApiError(
        'rate_limited',
        'Server is rate-limiting this session',
        { retryAfterSecs: secs, path },
      );
    }
    this._rateLimitedUntil = 0;
    if (!resp.ok) {
      const text = await resp.text();
      throw new SkotiqApiError(
        'http_error',
        'GET ' + path + ' failed (' + resp.status + '): ' + text,
        { status: resp.status, path, body: text },
      );
    }
    return {
      blob: await resp.blob(),
      contentDisposition: resp.headers.get('content-disposition') || '',
    };
  }

  // =========================================================================
  // Core
  // =========================================================================

  async getInfo() { return this._get('/api/info'); }
  async getStatus() { return this._get('/api/status'); }

  // =========================================================================
  // Devices
  // =========================================================================

  async getDevices(deviceType) {
    const q = deviceType ? '?deviceType=' + encodeURIComponent(deviceType) : '';
    return this._get('/api/devices' + q);
  }

  async getConnectedDevices() {
    return this._get('/api/devices/connected');
  }

  async connectDevice(deviceId, deviceType) {
    return this._post('/api/devices/connect', { deviceId, deviceType });
  }

  async disconnectDevice(deviceId, deviceType) {
    return this._post('/api/devices/disconnect', { deviceId, deviceType });
  }

  // =========================================================================
  // Camera
  // =========================================================================

  async cameraExpose(deviceId, exposureTime, opts) {
    return this._post('/api/camera/expose', {
      deviceId,
      exposureTime,
      frameType: (opts && opts.frameType) || 'light',
      gain: opts && opts.gain,
      offset: opts && opts.offset,
      binX: (opts && opts.binX) || 1,
      binY: (opts && opts.binY) || 1,
      // Subframe x/y/width/height pass through whenever the dashboard panel
      // has explicit values entered — undefined falls back to full-frame on
      // the backend, which is the same default as the desktop UI.
      x: opts && opts.x,
      y: opts && opts.y,
      width: opts && opts.width,
      height: opts && opts.height,
    });
  }

  async cameraAbort(deviceId) {
    return this._post('/api/camera/abort', { deviceId });
  }

  async cameraGetLastImage(deviceId) {
    return this._get('/api/camera/last-image?deviceId=' + encodeURIComponent(deviceId));
  }

  /**
   * JPEG preview of the last capture (preferred for browser clients).
   * Stats/histogram arrive in the `x-image-meta` header (base64 JSON).
   */
  async cameraGetLastImageJpeg(deviceId, opts) {
    const o = opts || {};
    const q = ['deviceId=' + encodeURIComponent(deviceId || '')];
    if (o.maxWidth != null) q.push('maxWidth=' + encodeURIComponent(o.maxWidth));
    if (o.quality != null) q.push('quality=' + encodeURIComponent(o.quality));
    const path = '/api/camera/last-image/jpeg?' + q.join('&');
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this._requestTimeoutMs);
    let resp;
    try {
      resp = await fetch(this._baseUrl + path, {
        method: 'GET',
        headers: this._headers(undefined, 'GET'),
        credentials: 'include',
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timeout);
    }
    if (resp.status === 404) {
      return { image: null, blob: null, meta: null };
    }
    if (!resp.ok) {
      const text = await resp.text();
      throw new Error('GET ' + path + ' failed (' + resp.status + '): ' + text);
    }
    const metaHeader = resp.headers.get('x-image-meta');
    let meta = null;
    if (metaHeader) {
      try {
        const json = atob(metaHeader);
        meta = JSON.parse(json);
      } catch (_) {
        meta = null;
      }
    }
    const blob = await resp.blob();
    return { image: meta, blob, meta };
  }

  /**
   * Host-authoritative 16-bit raw pixels for the last capture (little-endian u16).
   */
  async getLastRawImageData(deviceId) {
    const path =
      '/api/imaging/raw-data?deviceId=' + encodeURIComponent(deviceId || '');
    const controller = new AbortController();
    const timeout = setTimeout(
      () => controller.abort(),
      Math.max(this._requestTimeoutMs, 60000),
    );
    let resp;
    try {
      resp = await fetch(this._baseUrl + path, {
        method: 'GET',
        headers: this._headers(undefined, 'GET'),
        credentials: 'include',
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timeout);
    }
    if (resp.status === 404 || resp.status === 503) {
      const err = new Error('GET ' + path + ' failed (' + resp.status + ')');
      err.status = resp.status;
      throw err;
    }
    if (!resp.ok) {
      const text = await resp.text();
      throw new Error('GET ' + path + ' failed (' + resp.status + '): ' + text);
    }
    const buffer = await resp.arrayBuffer();
    if (buffer.byteLength % 2 !== 0) {
      throw new Error(
        'GET ' + path + ' returned an odd-length 16-bit payload (' +
        buffer.byteLength + ' bytes)',
      );
    }
    // The wire contract is explicitly little-endian. Uint16Array uses the
    // browser host's native byte order, so decode through DataView instead.
    const view = new DataView(buffer);
    const pixels = new Uint16Array(buffer.byteLength / 2);
    for (let i = 0; i < pixels.length; i += 1) {
      pixels[i] = view.getUint16(i * 2, true);
    }
    return pixels;
  }

  async cameraSetCooling(deviceId, enabled, targetTemp) {
    return this._post('/api/camera/cooling', { deviceId, enabled, targetTemp });
  }

  async cameraSetGain(deviceId, gain) {
    return this._post('/api/camera/gain', { deviceId, gain });
  }

  async cameraSetOffset(deviceId, offset) {
    return this._post('/api/camera/offset', { deviceId, offset });
  }

  // The backend uses camelCase /api/camera/readoutMode (see device_handlers
  // and the route table in headless_api_server.dart). Match that exactly —
  // hyphenated variants 404 on the current server.
  async cameraSetReadoutMode(deviceId, modeIndex) {
    return this._post('/api/camera/readoutMode', { deviceId, modeIndex });
  }

  // Dedicated readout-mode list endpoint. Backed by the camera abstraction's
  // capabilities, but returns only the {readoutModes: [...]} subset so the
  // dropdown doesn't have to round-trip the full capabilities payload.
  async cameraGetReadoutModes(deviceId) {
    return this._get(
      '/api/camera/readout-modes?deviceId=' + encodeURIComponent(deviceId || ''),
    );
  }

  // Dedicated cooling-state endpoint. Source of truth is the camera status
  // model; this endpoint just projects the four cooling fields so the cooling
  // panel can poll at its own cadence without pulling the full status blob.
  async cameraGetCooling(deviceId) {
    return this._get(
      '/api/camera/cooling?deviceId=' + encodeURIComponent(deviceId || ''),
    );
  }

  // Binning and subframe are committed by cameraExpose's binX/binY/x/y/
  // width/height body fields. Why no separate /api/camera/binning or
  // /api/camera/subframe endpoint: ASCOM cameras only commit these at
  // StartExposure time, so a standalone setter would either no-op or
  // fight the next expose body. The dashboard sends them per-expose.
  // These no-op shims keep the endpoint names alive in the
  // client surface so future code can call them uniformly.
  async cameraSetBinning(_deviceId, _binX, _binY) {
    return { status: 'queued', message: 'Binning applies on next Expose' };
  }

  async cameraSetSubframe(_deviceId, _x, _y, _width, _height) {
    return { status: 'queued', message: 'Subframe applies on next Expose' };
  }

  // Reset any pending subframe state — currently a no-op (subframe lives in
  // the input fields), kept so callers can express intent uniformly.
  clearPendingSubframe() { /* nothing to clear today */ }

  // =========================================================================
  // Equipment Status
  // =========================================================================

  async getCameraStatus(deviceId) {
    return this._get('/api/equipment/camera/status?deviceId=' + encodeURIComponent(deviceId || ''));
  }

  async getMountStatus(deviceId) {
    return this._get('/api/equipment/mount/status?deviceId=' + encodeURIComponent(deviceId || ''));
  }

  async getFocuserStatus(deviceId) {
    return this._get('/api/equipment/focuser/status?deviceId=' + encodeURIComponent(deviceId || ''));
  }

  async getFilterWheelStatus(deviceId) {
    return this._get('/api/equipment/filter-wheel/status?deviceId=' + encodeURIComponent(deviceId || ''));
  }

  async getRotatorStatus(deviceId) {
    return this._get('/api/equipment/rotator/status?deviceId=' + encodeURIComponent(deviceId || ''));
  }

  // =========================================================================
  // Mount
  // =========================================================================

  async mountSlew(deviceId, ra, dec) {
    return this._post('/api/mount/slew', { deviceId, ra, dec });
  }

  async mountSync(deviceId, ra, dec) {
    return this._post('/api/mount/sync', { deviceId, ra, dec });
  }

  async mountPark(deviceId) {
    return this._post('/api/mount/park', { deviceId });
  }

  async mountUnpark(deviceId) {
    return this._post('/api/mount/unpark', { deviceId });
  }

  async mountSetTracking(deviceId, enabled) {
    return this._post('/api/mount/tracking', { deviceId, enabled });
  }

  async mountAbort(deviceId) {
    return this._post('/api/mount/abort', { deviceId });
  }

  async mountGetStatus(deviceId) {
    return this._get('/api/mount/status?deviceId=' + encodeURIComponent(deviceId || ''));
  }

  async mountMoveAxis(deviceId, axis, rate) {
    return this._post('/api/mount/move-axis', { deviceId, axis, rate });
  }

  // =========================================================================
  // Focuser
  // =========================================================================

  async focuserMoveTo(deviceId, position) {
    return this._post('/api/focuser/move-to', { deviceId, position });
  }

  async focuserMoveRelative(deviceId, delta) {
    return this._post('/api/focuser/move-relative', { deviceId, delta });
  }

  async focuserHalt(deviceId) {
    return this._post('/api/focuser/halt', { deviceId });
  }

  // Returns FocuserStatus (position, moving, temperature). Why a wrapper:
  // the dashboard reads from /api/equipment/focuser/status and renders
  // position/temp from the same payload — keeping the call here matches the
  // mountGetStatus/cameraGetStatus pattern.
  async focuserGetStatus(deviceId) {
    return this._get(
      '/api/equipment/focuser/status?deviceId=' + encodeURIComponent(deviceId || ''),
    );
  }

  // Autofocus requires a camera + exposure parameters; the dashboard sends
  // sensible defaults from the connected camera's last gain and a 3s sub.
  // Step sizes mirror the desktop AutofocusDialog defaults.
  async autofocusStart(deviceId, cameraId, opts) {
    return this._post('/api/focuser/autofocus/start', {
      deviceId,
      cameraId,
      exposureTime: (opts && opts.exposureTime) || 3.0,
      stepSize: (opts && opts.stepSize) || 50,
      stepsOut: (opts && opts.stepsOut) || 5,
      method: (opts && opts.method) || 'VCurve',
      binning: (opts && opts.binning) || 2,
    });
  }

  async autofocusCancel(deviceId) {
    return this._post('/api/focuser/autofocus/cancel', { deviceId });
  }

  // =========================================================================
  // Filter Wheel
  // =========================================================================

  async filterWheelSetPosition(deviceId, position) {
    return this._post('/api/filter-wheel/position', { deviceId, position });
  }

  async filterWheelGetNames(deviceId) {
    return this._get('/api/filter-wheel/names?deviceId=' + encodeURIComponent(deviceId || ''));
  }

  async filterWheelSetByName(deviceId, filterName) {
    // The backend payload key is `name` (see handleFilterWheelSetByName).
    // Sending `filterName` instead trips the validator with
    // "field 'name' required".
    return this._post('/api/filter-wheel/set-by-name', { deviceId, name: filterName });
  }

  // Combined "list of positions with names + offsets" for the click-to-rotate
  // panel. Filter offsets come from /api/focus-model/filter-offsets (the
  // single source of truth shared with the autofocus model). Why two GETs:
  // there is no combined endpoint and we want offsets to survive even when
  // a wheel reports placeholder names like "Filter 1" .. "Filter 8".
  async filterWheelGetPositions(deviceId) {
    const [namesResp, status, offsetsResp] = await Promise.all([
      this.filterWheelGetNames(deviceId),
      this._get('/api/equipment/filter-wheel/status?deviceId=' +
        encodeURIComponent(deviceId || '')),
      // Why catch: the focus model offsets endpoint requires an active
      // profile; on a fresh install it can 404. Treat that as "no offsets"
      // rather than failing the whole panel render.
      this._get('/api/focus-model/filter-offsets').catch(() => ({})),
    ]);
    const names = (namesResp && namesResp.names) || [];
    const offsets = (offsetsResp && (offsetsResp.offsets || offsetsResp)) || {};
    const positions = names.map((name, idx) => ({
      position: idx,
      name: name || ('Slot ' + idx),
      // offsets is keyed by filter name in the focus model service
      offset: offsets && offsets[name] != null ? Number(offsets[name]) : null,
    }));
    return {
      positions,
      currentPosition: status && status.position != null ? Number(status.position) : -1,
      filterCount: positions.length,
    };
  }

  // =========================================================================
  // Rotator
  // =========================================================================

  async rotatorMoveTo(deviceId, angle) {
    return this._post('/api/rotator/move-to', { deviceId, angle });
  }

  async rotatorMoveRelative(deviceId, delta) {
    return this._post('/api/rotator/move-relative', { deviceId, delta });
  }

  async rotatorHalt(deviceId) {
    return this._post('/api/rotator/halt', { deviceId });
  }

  async rotatorGetAngle(deviceId) {
    return this._get(
      '/api/rotator/status?deviceId=' + encodeURIComponent(deviceId || ''),
    );
  }

  async rotatorGetStatus(deviceId) {
    return this._get(
      '/api/equipment/rotator/status?deviceId=' + encodeURIComponent(deviceId || ''),
    );
  }

  // POST /api/rotator/sync — Sync rotator's reported sky angle to the
  // supplied position-angle without moving the hardware. Canonical field is
  // `positionAngle` (matches plate-solve terminology); the handler also
  // accepts `angle` as an alias for older clients.
  async rotatorSync(deviceId, positionAngle) {
    return this._post('/api/rotator/sync', { deviceId, positionAngle });
  }

  // =========================================================================
  // Targets (autocomplete)
  // =========================================================================

  async targetsSearch(query) {
    const encoded = encodeURIComponent(query || '');
    // Search both user-saved targets and the installed star/DSO catalogs.
    // The dashboard labels this surface "Target Catalog" and the framing
    // wizard promises catalog IDs; querying only /api/targets/search made M31
    // return no matches on a host with a fully installed catalog.
    const [savedResult, catalogResult] = await Promise.allSettled([
      this._get('/api/targets/search?query=' + encoded),
      this._get('/api/planetarium/catalog/search?query=' + encoded),
    ]);
    if (savedResult.status === 'rejected'
        && catalogResult.status === 'rejected') {
      throw savedResult.reason;
    }

    const saved = savedResult.status === 'fulfilled'
      ? ((savedResult.value && savedResult.value.targets) || [])
      : [];
    const catalog = catalogResult.status === 'fulfilled'
      ? ((catalogResult.value && catalogResult.value.results) || [])
      : [];
    const targets = saved.slice();
    const seen = new Set(saved.map((target) => String(
      target.catalogId || target.name || '',
    ).trim().toLowerCase()));

    for (const object of catalog) {
      const key = String(object.catalogId || object.name || '')
        .trim().toLowerCase();
      if (key && seen.has(key)) continue;
      if (key) seen.add(key);
      targets.push({
        // Catalog entries are not target-table rows until the user saves one.
        // Keep id null so framing save creates a row instead of PUTting a
        // synthetic catalog identifier to /api/targets/<id>.
        id: null,
        name: object.name,
        catalogId: object.catalogId,
        ra: object.raHours,
        dec: object.dec,
        objectType: object.type,
        constellation: object.constellation,
        magnitude: object.magnitude,
        sizeArcmin: object.size,
      });
    }
    return { targets };
  }

  // Mount Slew helpers — names match the brief. mountSlewToRaDec
  // and mountAbortSlew are aliases over the existing mountSlew / mountAbort
  // to keep app.js handlers readable.
  async mountSlewToRaDec(deviceId, raHours, decDeg) {
    return this.mountSlew(deviceId, raHours, decDeg);
  }

  async mountAbortSlew(deviceId) {
    return this.mountAbort(deviceId);
  }

  // =========================================================================
  // PHD2 Guiding
  // =========================================================================

  async phd2Connect(host, port) {
    return this._post('/api/phd2/connect', { host: host || 'localhost', port: port || 4400 });
  }

  async phd2Disconnect() {
    return this._post('/api/phd2/disconnect', {});
  }

  async phd2StartGuiding(settlePixels, settleTime, settleTimeout) {
    return this._post('/api/phd2/start-guiding', {
      settlePixels: settlePixels || 1.0,
      settleTime: settleTime || 10.0,
      settleTimeout: settleTimeout || 60.0,
    });
  }

  async phd2StopGuiding() {
    return this._post('/api/phd2/stop-guiding', {});
  }

  async phd2GetStatus() {
    return this._get('/api/phd2/status');
  }

  async phd2Dither(amount) {
    return this._post('/api/phd2/dither', { amount: amount || 5.0 });
  }

  async phd2SetPaused(paused) {
    return this._post('/api/phd2/pause', { paused });
  }

  // =========================================================================
  // Sequencer
  // =========================================================================

  async sequencerGetStatus() {
    return this._get('/api/sequencer/status');
  }

  async sequencerStart() {
    return this._post('/api/sequencer/start', {});
  }

  async sequencerStop() {
    return this._post('/api/sequencer/stop', {});
  }

  async sequencerPause() {
    return this._post('/api/sequencer/pause', {});
  }

  async sequencerResume() {
    return this._post('/api/sequencer/resume', {});
  }

  async sequencerSkip() {
    return this._post('/api/sequencer/skip', {});
  }

  async sequencerReset() {
    return this._post('/api/sequencer/reset', {});
  }

  async sequencerLoad(sequenceData) {
    return this._post('/api/sequencer/load', sequenceData);
  }

  // =========================================================================
  // Profiles
  // =========================================================================

  async getProfiles() { return this._get('/api/profiles'); }
  async getActiveProfile() { return this._get('/api/profiles/active'); }

  // =========================================================================
  // Settings
  // =========================================================================

  async getSettings() { return this._get('/api/settings'); }
  async getLocation() { return this._get('/api/settings/location'); }

  // =========================================================================
  // Weather
  // =========================================================================

  async getWeatherSafeImaging() { return this._get('/api/weather/safe-imaging'); }

  async weatherGetCurrent() {
    return this._get('/api/weather/current');
  }

  // =========================================================================
  // Safety — ops panels
  // =========================================================================

  // Aggregate safety status across all connected safety monitors.
  // Returns { isSafe, monitorsConnected, monitors[], failModeWarning, ... }
  async safetyGetStatus() {
    return this._get('/api/safety/status');
  }

  // =========================================================================
  // Sequences — listing + load by id (ops panels)
  // =========================================================================

  // List sequences saved in the database. Excludes templates (handled by a
  // separate endpoint). Each entry: { id, name, description, rootNodeId,
  // isTemplate, createdAt, updatedAt }.
  async sequencerList() {
    return this._get('/api/sequence-management/list');
  }

  // Load and start atomically on the host. The host owns both the persisted
  // sequence schema and native-executor serialization; browser-side database
  // DTOs are intentionally not treated as native sequence definitions.
  async sequencerLoadAndStart(sequenceId) {
    const parsedId = Number(sequenceId);
    if (!Number.isInteger(parsedId) || parsedId < 1) {
      throw new Error('Invalid sequence id: ' + sequenceId);
    }
    return this._post('/api/sequencer/load-and-start', {
      sequenceId: parsedId,
    });
  }

  // Abort = stop. The dashboard UI labels this control "Abort"; the server
  // route is "stop". The alias lets each side keep its own vocabulary.
  async sequencerAbort() {
    return this.sequencerStop();
  }

  // =========================================================================
  // Checkpoint resume — ops panels
  // =========================================================================

  // TODO: the sequencer supports a single active checkpoint, not a list.
  // /api/sequencer/checkpoint/has + /api/sequencer/checkpoint/info return
  // that single entry. The UI renders a picker, so normalise the response to
  // an array of length 0 or 1; multi-checkpoint support would change the wire
  // format here and nothing in the UI, which already iterates over an array.
  async sequencerListCheckpoints() {
    const hasResp = await this._get('/api/sequencer/checkpoint/has');
    if (!hasResp || !hasResp.hasCheckpoint) {
      return { checkpoints: [] };
    }
    const infoResp = await this._get('/api/sequencer/checkpoint/info');
    const info = infoResp && infoResp.info;
    if (!info) {
      return { checkpoints: [] };
    }
    return { checkpoints: [info] };
  }

  async sequencerResumeCheckpoint() {
    return this._post('/api/sequencer/checkpoint/resume', {});
  }

  async sequencerDiscardCheckpoint() {
    return this._post('/api/sequencer/checkpoint/discard', {});
  }

  // =========================================================================
  // Dome — ops panels
  // =========================================================================

  async domeOpen(deviceId) {
    return this._post('/api/dome/open', { deviceId });
  }

  async domeClose(deviceId) {
    return this._post('/api/dome/close', { deviceId });
  }

  async domeSlew(deviceId, azimuth) {
    return this._post('/api/dome/slew', { deviceId, azimuth });
  }

  async domePark(deviceId) {
    return this._post('/api/dome/park', { deviceId });
  }

  async domeGetStatus(deviceId) {
    return this._get(
      '/api/dome/status?deviceId=' + encodeURIComponent(deviceId || ''),
    );
  }

  // The host payload key is `enable` (matching NetworkBackend and
  // DomeHandlers). Sending `enabled` made the server apply its default `true`,
  // so turning this toggle off silently re-enabled dome slaving.
  async domeSyncToMount(deviceId, enabled) {
    return this._post('/api/dome/sync', { deviceId, enable: enabled });
  }

  // =========================================================================
  // Profiles — ops panels
  // =========================================================================

  async profilesGetList() {
    return this._get('/api/profiles');
  }

  async profilesGetActive() {
    return this._get('/api/profiles/active');
  }

  async profilesActivate(profileId) {
    return this._post(
      '/api/profiles/' + encodeURIComponent(profileId) + '/load',
      {},
    );
  }

  // TODO: no /api/profiles/reload endpoint exists. The desktop UI re-reads
  // the active profile to pick up out-of-band edits; re-activating the active
  // profile id has equivalent effect here, forcing device caches + filter
  // offsets to repopulate from disk.
  async profilesReload() {
    const active = await this.profilesGetActive();
    const profile = active && active.profile;
    if (!profile || !profile.id) {
      throw new Error('No active profile to reload');
    }
    return this.profilesActivate(profile.id);
  }

  // =========================================================================
  // Analytics — session summary (ops panels)
  // =========================================================================

  // TODO: there is no /api/analytics/session-summary endpoint. The closest
  // are /api/sessions/active (the row with totalExposures /
  // totalIntegrationSecs / avgHfr) and the science bundle (the transparency
  // sample series behind the sparkline). Compose them so the dashboard panel
  // has both the headline stats and the transparency trend without a new
  // server route.
  async analyticsGetSessionSummary() {
    const active = await this._get('/api/sessions/active');
    const session = active && active.session;
    if (!session) {
      return {
        session: null,
        transparency: [],
      };
    }
    let transparency = [];
    try {
      const bundle = await this._get(
        '/api/science/session/' + encodeURIComponent(session.id) + '/bundle',
      );
      transparency = (bundle && bundle.transparency) || [];
    } catch (e) {
      // Why swallow: science telemetry is optional — many sessions are
      // imaging-only and have no transparency samples recorded. A 404 or
      // empty bundle is not an error condition for the analytics panel.
      transparency = [];
    }
    return { session, transparency };
  }
  // =========================================================================
  // Plate Solve
  // =========================================================================

  // /api/plate-solve takes a file system path. The web dashboard finds the
  // path by querying /api/images/recent?limit=1 for the most recently
  // captured image (the desktop's AutoSaveService writes it to disk before
  // the row lands in the images table) and feeds the resulting filePath in.
  async plateSolve(imagePath, hint) {
    return this._post('/api/plate-solve', {
      imagePath,
      ra: hint && hint.ra,
      dec: hint && hint.dec,
      fov: hint && hint.fov,
    });
  }

  // Most-recent captured image — used so the plate-solve panel can solve
  // "the current frame" without the operator typing a filesystem path.
  async imagesGetRecent(limit) {
    return this._get('/api/images/recent?limit=' + encodeURIComponent(limit || 1));
  }

  // =========================================================================
  // Image gallery + log tail
  //
  // The gallery panel uses /api/images?limit=N (full listing) plus
  // /api/images/{id}/thumbnail for the per-row image. The log panel
  // uses /api/logs/tail (SSE) — EventSource doesn't accept custom
  // headers so the bearer goes through ?access_token=, the query-param
  // fallback the server accepts on SSE endpoints (see
  // headless_api_server.dart).
  // =========================================================================

  /// Paginated list of captured images, newest first. The query mirrors
  /// the desktop's image-history panel so the JSON shape is reused
  /// without a new wire type. Defaults limit to 24 — enough rows to
  /// fill a typical 6-wide gallery on a laptop without paginating.
  async imagesGetAll(opts) {
    const o = opts || {};
    const q = [];
    q.push('limit=' + encodeURIComponent(o.limit != null ? o.limit : 24));
    if (o.offset != null) q.push('offset=' + encodeURIComponent(o.offset));
    if (o.sessionId != null) {
      q.push('sessionId=' + encodeURIComponent(o.sessionId));
    }
    if (o.targetId != null) {
      q.push('targetId=' + encodeURIComponent(o.targetId));
    }
    const path = '/api/images' + (q.length ? '?' + q.join('&') : '');
    return this._get(path);
  }

  /// Build the URL for the per-image thumbnail. We do NOT fetch the
  /// blob here — `<img src>` lets the browser cache it across re-
  /// renders, which is much friendlier on slow LAN links than blob
  /// URL juggling.
  imageThumbnailUrl(imageId, opts) {
    const o = opts || {};
    const q = [];
    if (o.maxWidth != null) q.push('maxWidth=' + encodeURIComponent(o.maxWidth));
    if (o.quality != null) q.push('quality=' + encodeURIComponent(o.quality));
    const qs = q.length ? '?' + q.join('&') : '';
    return this._baseUrl + '/api/images/' + encodeURIComponent(imageId) +
        '/thumbnail' + qs;
  }

  async imageThumbnailBlob(imageId, opts) {
    const url = this.imageThumbnailUrl(imageId, opts);
    const path = url.slice(this._baseUrl.length);
    return this._getBlob(path, 60000);
  }

  /// Build the download URL for cookie/no-auth sessions. Bearer-only browser
  /// sessions must use imageDownloadBlob() because URL navigation cannot add
  /// an Authorization header and the server intentionally rejects bearer
  /// tokens in general query strings.
  imageDownloadUrl(imageId) {
    return this._baseUrl + '/api/images/' + encodeURIComponent(imageId) +
        '/download';
  }

  async imageDownloadBlob(imageId) {
    const path = '/api/images/' + encodeURIComponent(imageId) + '/download';
    return this._getBlob(path, 120000);
  }

  /// Subscribe to /api/logs/tail (SSE). Returns the [EventSource] so
  /// the caller can `.close()` it on teardown.
  ///
  /// TWO things about this endpoint are not the SSE defaults, and getting
  /// either wrong produces a stream that opens cleanly and tells you nothing.
  ///
  /// 1. Its frames are NAMED. `log_handlers.dart` writes
  ///    `id: …\nevent: log\ndata: {…}` per entry and `event: replay-done`
  ///    once the ring-buffer replay is finished — and says why in its own
  ///    comment ("A custom event name is used so default `message` listeners
  ///    don't see it"). `EventSource.onmessage` fires only for frames with NO
  ///    event name, so a client wired to onmessage receives nothing at all: the
  ///    logs panel sat on "Waiting for log entries…" behind a "live" badge
  ///    while 174 named frames arrived in 12 s on the same socket. Listen per
  ///    name.
  /// 2. The severity parameter is `severity`, and it is an allow-LIST of exact
  ///    level names — not the `minSeverity` floor that /api/logs/recent reads.
  ///    Sending `minSeverity` here is not an error, it is silently ignored, so
  ///    the panel's "Min severity" selector filtered nothing and a debug-level
  ///    firehose arrived no matter what it said. [minSeverity] is expanded to
  ///    the levels at or above it, which is what the control promises.
  ///
  /// Why we send the bearer via ?access_token: EventSource has no
  /// header API, so the server's SSE handler accepts the token as a
  /// query parameter for this endpoint specifically (same convention
  /// as run-watch SSE).
  subscribeLogTail(minSeverity, onEntry, onError, onReplayDone) {
    const q = [];
    const severities = SkotiqApi.logSeveritiesAtOrAbove(minSeverity);
    if (severities.length) {
      q.push('severity=' + encodeURIComponent(severities.join(',')));
    }
    if (this._authToken) {
      q.push('access_token=' + encodeURIComponent(this._authToken));
    }
    const path = '/api/logs/tail' + (q.length ? '?' + q.join('&') : '');
    const source = new EventSource(this._baseUrl + path);
    source.addEventListener('log', (msg) => {
      if (!msg || !msg.data) return;
      try {
        const payload = JSON.parse(msg.data);
        onEntry(payload);
      } catch (_) {
        // A frame whose data will not parse is not an entry we can render.
      }
    });
    if (typeof onReplayDone === 'function') {
      source.addEventListener('replay-done', () => onReplayDone());
    }
    if (typeof onError === 'function') {
      source.onerror = (err) => onError(err);
    }
    return source;
  }

  /// `LogLevel` as the server declares it (logging_service.dart), in order.
  ///
  /// `trace` and `warn` are NOT members: `LoggingService.parseLogLevel` matches
  /// `LogLevel.values` by exact name, so those two were rejected outright by
  /// any endpoint that reads them. The dashboard's own selector offered both.
  static get logLevels() {
    return ['debug', 'info', 'warning', 'error', 'critical'];
  }

  /// The allow-list the tail wants for a "minimum severity" of [minSeverity].
  ///
  /// An unknown name yields the empty list, which sends no filter at all —
  /// every entry, rather than a silently narrowed stream the operator did not
  /// ask for.
  static logSeveritiesAtOrAbove(minSeverity) {
    const levels = SkotiqApi.logLevels;
    const at = levels.indexOf(String(minSeverity || '').toLowerCase());
    return at < 0 ? [] : levels.slice(at);
  }

  // Save the camera's last in-memory capture to disk as FITS so the plate
  // solver can read it. The server already exposes this endpoint for the
  // desktop's auto-save fallback; the web client reuses it for "plate-solve
  // current frame" when no DB-tracked image exists yet.
  async imagingSaveFitsFromCapture(deviceId, filePath, headerData) {
    return this._post('/api/imaging/save-fits-from-capture', {
      deviceId,
      filePath,
      headerData: headerData || {},
    });
  }

  // =========================================================================
  // Polar Alignment
  // =========================================================================

  // The desktop backend uses snake_case for the polar alignment payload (see
  // SessionHandlers.handleStartPolarAlignment). Keep the wire shape identical
  // here rather than auto-camelCasing — the validator on the server side
  // rejects unknown fields.
  async polarAlignmentStart(opts) {
    const o = opts || {};
    return this._post('/api/polar-alignment/start', {
      exposure_time: o.exposureTime != null ? o.exposureTime : 3.0,
      step_size: o.stepSize != null ? o.stepSize : 5.0,
      binning: o.binning != null ? o.binning : 2,
      is_north: o.isNorth != null ? o.isNorth : true,
      manual_rotation: o.manualRotation != null ? o.manualRotation : false,
      rotate_east: o.rotateEast != null ? o.rotateEast : true,
      gain: o.gain,
      offset: o.offset,
      solve_timeout: o.solveTimeout,
      start_from_current: o.startFromCurrent,
    });
  }

  async polarAlignmentStop() {
    return this._post('/api/polar-alignment/stop', {});
  }

  async polarAlignmentStartAllSky(opts) {
    const o = opts || {};
    return this._post('/api/polar-alignment/all-sky/start', {
      exposure_time: o.exposureTime != null ? o.exposureTime : 3.0,
      solve_timeout: o.solveTimeout != null ? o.solveTimeout : 60.0,
      binning: o.binning != null ? o.binning : 2,
      is_north: o.isNorth != null ? o.isNorth : true,
      acceptance_threshold_arcsec: o.acceptanceThresholdArcsec != null
        ? o.acceptanceThresholdArcsec : 120.0,
      iteration_cadence_secs: o.iterationCadenceSecs != null
        ? o.iterationCadenceSecs : 30.0,
      gain: o.gain,
      offset: o.offset,
    });
  }

  // =========================================================================
  // Flat Wizard
  // =========================================================================

  // Multi-filter ADU calibration. Returns an array of FlatResult JSON objects
  // — one per filter — each carrying the converged exposure for the chosen
  // ADU target. Streams progress via `imaging` / `sequencer` WebSocket events
  // while running (the backend's FlatWizardService emits them through the
  // shared event bus).
  async flatWizardCalibrateMulti(deviceId, filters, opts) {
    const o = opts || {};
    return this._request('POST', '/api/flat-wizard/calibrate-multi', {
      deviceId,
      filters,
      targetAdu: o.targetAdu != null ? o.targetAdu : 30000,
      tolerance: o.tolerance != null ? o.tolerance : 10.0,
      minExposure: o.minExposure != null ? o.minExposure : 0.001,
      maxExposure: o.maxExposure != null ? o.maxExposure : 30.0,
      maxIterations: o.maxIterations != null ? o.maxIterations : 10,
      binX: o.binX != null ? o.binX : 1,
      binY: o.binY != null ? o.binY : 1,
    // ADU calibration can run many iterations per filter; the default 8s
    // _requestTimeoutMs would abort before any real wheel can settle.
    }, /* timeoutMs */ 300000);
  }

  // Quick single-filter calibration — useful as the simplest panel-flat path.
  async flatWizardQuickCalibrate(deviceId, filter, opts) {
    const o = opts || {};
    return this._request('POST', '/api/flat-wizard/quick-calibrate', {
      deviceId,
      filter,
      targetAdu: o.targetAdu != null ? o.targetAdu : 30000,
      tolerancePercent: o.tolerancePercent != null ? o.tolerancePercent : 10.0,
      binX: o.binX != null ? o.binX : 1,
      binY: o.binY != null ? o.binY : 1,
    }, 120000);
  }

  // Turn a set of calibrations into a full flat-frame sequence the operator
  // can hand to the sequencer.
  async flatWizardGenerateSequence(calibrations, opts) {
    const o = opts || {};
    return this._post('/api/flat-wizard/generate-sequence', {
      calibrations,
      framesPerFilter: o.framesPerFilter != null ? o.framesPerFilter : 20,
      sequenceName: o.sequenceName || 'Flat Frame Sequence',
      description: o.description,
      binX: o.binX != null ? o.binX : 1,
      binY: o.binY != null ? o.binY : 1,
      gain: o.gain,
      offset: o.offset,
      onlySuccessful: o.onlySuccessful != null ? o.onlySuccessful : true,
    });
  }

  // =========================================================================
  // Mosaic Planner
  // =========================================================================

  // Compute the panel centers for a mosaic — useful for the preview step
  // before committing to a sequence.
  async mosaicGeneratePanels(config) {
    return this._post('/api/mosaic/generate-panels', { config });
  }

  // Time estimate for the mosaic. Surfaced in the wizard preview step so
  // operators see "this will take 4h12m" before pressing Build.
  async mosaicEstimateTime(config, exposure, overheadPerPanelSecs) {
    const body = { config, exposure };
    if (overheadPerPanelSecs != null) {
      body.overheadPerPanelSecs = overheadPerPanelSecs;
    }
    return this._post('/api/mosaic/estimate-time', body);
  }

  async mosaicRecommendedExposure() {
    return this._get('/api/mosaic/recommended-exposure');
  }

  async mosaicValidate(config) {
    return this._post('/api/mosaic/validate', { config });
  }

  // Generate the full mosaic sequence (panel slews + per-panel exposures).
  // The dashboard's mosaic wizard hands the result off to the sequencer load
  // endpoint so the operator can press Start immediately.
  async mosaicGenerateSequence(opts) {
    const o = opts || {};
    return this._post('/api/mosaic/generate-sequence', {
      mosaicName: o.mosaicName || 'Mosaic',
      config: o.config,
      exposure: o.exposure,
      options: o.options || {},
    });
  }

  // =========================================================================
  // Framing Assistant
  // =========================================================================

  // Slew without solve-and-correct — the cheap "go close to" path.
  async framingSlewToTarget(ra, dec) {
    return this._post('/api/framing/slew-to-target', { ra, dec });
  }

  // Iterative plate-solve-and-correct centering. The server uses the
  // configured plate-solver settings to drive the mount onto the target.
  async framingCenterOnTarget(ra, dec, opts) {
    const o = opts || {};
    return this._request('POST', '/api/framing/center-on-target', {
      ra,
      dec,
      maxIterations: o.maxIterations != null ? o.maxIterations : 5,
      toleranceArcsec: o.toleranceArcsec != null ? o.toleranceArcsec : 30.0,
      exposureTime: o.exposureTime != null ? o.exposureTime : 3.0,
      binning: o.binning != null ? o.binning : 2,
      gain: o.gain != null ? o.gain : 100,
      syncMount: o.syncMount != null ? o.syncMount : false,
    // Centering can iterate up to maxIterations plate-solves; allow a long
    // window so a 5-iteration run with 3s exposures + a slow solver completes.
    }, 600000);
  }

  // Rotate to a chosen sky PA — used by the framing wizard's rotation step
  // when a rotator is connected.
  async framingRotateTo(angle) {
    return this._post('/api/framing/rotate-to', { angle });
  }

  // Mount sync to the framing-chosen coordinates (i.e. "the scope is HERE
  // now"). Optional — the wizard offers it as a sanity step after centering.
  async framingSyncMount(ra, dec) {
    return this._post('/api/framing/sync', { ra, dec });
  }

  async framingSave(payload) {
    return this._post('/api/framing/save', payload);
  }

  async planetariumSlewTo(ra, dec) {
    return this._post('/api/planetarium/slew-to', { ra, dec });
  }

  async planetariumGetMountPosition() {
    return this._get('/api/planetarium/mount-position');
  }

  // =========================================================================
  // Planetarium / FOV
  // =========================================================================

  // Returns the effective FOV (width/height in degrees) for the active
  // profile + camera. The framing wizard renders the FOV box on a sky chart
  // and the mosaic wizard auto-fills panelWidth/panelHeight from this.
  async getFovConfig() {
    return this._get('/api/planetarium/fov-config');
  }

  // =========================================================================
  // Targets (CRUD subset — used by the framing wizard to persist framing)
  // =========================================================================

  // Update an existing target (the framing wizard PUTs ra/dec/positionAngle
  // onto a previously-saved target row).
  async targetsUpdate(targetId, payload) {
    return this._put('/api/targets/' + encodeURIComponent(targetId), payload);
  }

  // Create a new target row. Used as the fallback path when the framing
  // wizard saves an ad-hoc framing for coordinates the operator typed in
  // without first selecting a target from the catalog.
  async targetsCreate(payload) {
    return this._post('/api/targets', payload);
  }


  /**
   * Start a pairing session. The server prints a pairing code to its console;
   * the operator then types it into the dashboard's pairing modal.
   * @returns {Promise<{expiresAt:string, expiresInSeconds:number}>}
   */
  async pairingStart() {
    return this._post('/api/pairing/start', {});
  }

  /**
   * Complete pairing by submitting the code shown on the desktop
   * console. On success the server returns a bearer token and scope.
   * The server expects field name `code` (not `pairingCode`).
   * @param {string} code Pairing code
   * @param {string} deviceName Human-readable browser identity
   * @param {string} deviceId Stable identifier for this browser profile
   */
  async pairWithCode(code, deviceName, deviceId) {
    return this._post('/api/pairing/verify', {
      code,
      deviceName,
      deviceId,
      deviceType: 'browser',
    });
  }

  /**
   * Request a single-use 60-second WebSocket auth ticket. Used so the bearer
   * token never has to appear as a query parameter on the /events upgrade
   * (which would leak it into HTTP/proxy logs). Requires an authenticated
   * session — the server's auth middleware verifies the bearer first.
   * @returns {Promise<{ticket:string, expiresInSeconds:number}>}
   */
  async issueWebSocketTicket() {
    return this._post('/api/ws/ticket', {});
  }

  /**
   * Exchange the current bearer token for an HttpOnly session cookie + CSRF
   * token. The server sets `Set-Cookie` with HttpOnly,
   * Secure, SameSite=Strict; the cookie value never enters JS. The returned
   * CSRF token is stashed in memory and echoed via `X-Skotiq-CSRF` on
   * every subsequent write.
   *
   * After this call the API client switches to the cookie path: the bearer
   * is no longer sent in the Authorization header, and the in-memory bearer
   * is cleared so a stray console.log cannot exfiltrate it.
   */
  async beginCookieSession() {
    if (!this._authToken) {
      throw new Error('No bearer token to upgrade — pair first.');
    }
    // Why we still send Authorization on THIS call: the server requires the
    // raw bearer to mint a cookie (no cookie-to-cookie escalation). After
    // it returns we flip _useSessionCookie on so future requests omit it.
    const result = await this._request('POST', '/api/auth/cookie', {});
    const csrf = result && result.csrfToken ? String(result.csrfToken) : '';
    if (!csrf) {
      throw new Error('Server did not return a CSRF token.');
    }
    this._csrfToken = csrf;
    this._useSessionCookie = true;
    // Drop the in-memory bearer so an XSS leak cannot scrape window.api
    // for the raw token. The HttpOnly cookie still carries it server-
    // side; we never need it back in JS.
    this._authToken = '';
    return { csrfToken: csrf, expiresInSeconds: result.expiresInSeconds };
  }

  /**
   * Fetch the CSRF token for an existing session cookie. Called on page
   * load when the dashboard suspects a cookie is present (since cookies are
   * HttpOnly the only way to know is to ask the server). Returns null when
   * the server reports no active session (e.g. cookie expired).
   */
  async tryResumeCookieSession() {
    try {
      const result = await this._request('GET', '/api/auth/csrf');
      const csrf = result && result.csrfToken ? String(result.csrfToken) : '';
      if (!csrf) {
        return null;
      }
      this._csrfToken = csrf;
      this._useSessionCookie = true;
      this._authToken = '';
      return { csrfToken: csrf, expiresInSeconds: result.expiresInSeconds };
    } catch (e) {
      // 401 from /api/auth/csrf simply means "no active session" — return
      // null so the caller falls back to the bearer/pairing path instead
      // of treating it as a hard error.
      return null;
    }
  }

  /**
   * Revoke the HttpOnly session cookie (logout). The browser clears the
   * cookie via the response Set-Cookie; the server drops the bound bearer
   * token so a copied cookie value cannot be reused.
   */
  async endCookieSession() {
    if (!this._useSessionCookie) {
      return;
    }
    try {
      await this._request('POST', '/api/auth/logout', {});
    } catch (_) {
      // Best-effort: even if the network round-trip fails we still want to
      // forget the CSRF token client-side so the SPA stops sending it.
    }
    this._csrfToken = '';
    this._useSessionCookie = false;
  }

  // =========================================================================
  // WebSocket Events
  // =========================================================================

  /**
   * Connect to the event WebSocket.
   * Events are dispatched to listeners registered via on().
   *
   * Why request a ticket first: ?token=<bearer> still works (legacy) but
   * leaks the bearer into HTTP/proxy access logs. A single-use 60-second
   * ticket is preferred; ?token is the fallback when the ticket endpoint is
   * unavailable or when no token is configured.
   */
  async connectWebSocket() {
    if (this._ws && (this._ws.readyState === WebSocket.OPEN || this._ws.readyState === WebSocket.CONNECTING)) {
      return;
    }

    let ticket = '';
    if (this._authToken || this._useSessionCookie) {
      try {
        const result = await this.issueWebSocketTicket();
        ticket = result && result.ticket ? String(result.ticket) : '';
      } catch (e) {
        // Why swallow: older servers did not expose /api/ws/ticket. Fall back
        // to ?token= for bearer sessions, which the server explicitly
        // continues to accept. Cookie sessions have no raw-token fallback;
        // a failed ticket request will therefore fail closed at the upgrade.
        ticket = '';
      }
    }

    let wsUrl = this._baseUrl.replace(/^http/, 'ws') + '/events';
    const query = [];
    if (ticket) {
      query.push('ticket=' + encodeURIComponent(ticket));
    } else if (this._authToken) {
      query.push('token=' + encodeURIComponent(this._authToken));
    }
    if (this._deviceId) {
      query.push('deviceId=' + encodeURIComponent(this._deviceId));
    }
    query.push('apiVersion=' + encodeURIComponent(this._apiVersion));
    if (query.length > 0) {
      wsUrl += (wsUrl.includes('?') ? '&' : '?') + query.join('&');
    }
    this._ws = new WebSocket(wsUrl);

    this._ws.onopen = () => {
      this._wsConnected = true;
      this._wsReconnectDelay = 1000;
      this._lastWsMessageAt = Date.now();
      this._startWebSocketHeartbeatMonitor();
      this._emit('ws:connected', {});
    };

    this._ws.onclose = () => {
      this._wsConnected = false;
      this._stopWebSocketHeartbeatMonitor();
      this._emit('ws:disconnected', {});
      this._scheduleReconnect();
    };

    this._ws.onerror = (err) => {
      this._wsConnected = false;
      this._emit('ws:error', { error: err });
    };

    this._ws.onmessage = (msg) => {
      try {
        const data = JSON.parse(msg.data);
        this._lastWsMessageAt = Date.now();
        // Heartbeat ping/pong frames are real proof that the socket is alive.
        // Surface that activity before the early returns below so consumers
        // do not mistake a healthy, quiet connection for a dead event stream.
        this._emit('ws:activity', { type: data.type || 'event' });

        if (data.type === 'ping') {
          this._ws.send(JSON.stringify({
            type: 'pong',
            timestamp: new Date().toISOString(),
          }));
          return;
        }

        if (data.type === 'pong') {
          return;
        }

        this._emit('event', data);

        // Also emit by category if present
        if (data.category) {
          this._emit('event:' + data.category, data);
        }
      } catch (e) {
        // Non-JSON message, emit as raw
        this._emit('event:raw', { raw: msg.data });
      }
    };
  }

  disconnectWebSocket() {
    if (this._wsReconnectTimer) {
      clearTimeout(this._wsReconnectTimer);
      this._wsReconnectTimer = null;
    }
    this._stopWebSocketHeartbeatMonitor();
    if (this._ws) {
      this._ws.close();
      this._ws = null;
    }
    this._wsConnected = false;
  }

  _scheduleReconnect() {
    if (this._wsReconnectTimer) return;
    this._wsReconnectTimer = setTimeout(() => {
      this._wsReconnectTimer = null;
      // Why fire-and-forget: connectWebSocket is async because it requests an
      // auth ticket first. Failures here are surfaced via ws:error events.
      this.connectWebSocket().catch((err) => {
        this._emit('ws:error', { error: err });
      });
    }, this._wsReconnectDelay);
    // Exponential backoff
    this._wsReconnectDelay = Math.min(this._wsReconnectDelay * 1.5, this._maxReconnectDelay);
  }

  /** Send a ping to keep the WebSocket alive */
  sendPing() {
    if (this._ws && this._ws.readyState === WebSocket.OPEN) {
      this._ws.send(JSON.stringify({
        type: 'ping',
        timestamp: new Date().toISOString(),
      }));
    }
  }

  _startWebSocketHeartbeatMonitor() {
    this._stopWebSocketHeartbeatMonitor();
    this._wsHeartbeatTimer = setInterval(() => {
      if (!this._ws || this._ws.readyState !== WebSocket.OPEN) return;
      if (Date.now() - this._lastWsMessageAt <= this._wsHeartbeatTimeoutMs) {
        return;
      }

      this._emit('ws:error', { error: new Error('WebSocket heartbeat timed out') });
      this._ws.close();
    }, 15000);
  }

  _stopWebSocketHeartbeatMonitor() {
    if (this._wsHeartbeatTimer) {
      clearInterval(this._wsHeartbeatTimer);
      this._wsHeartbeatTimer = null;
    }
  }

  // =========================================================================
  // Event Emitter
  // =========================================================================

  /**
   * Listen for events.
   * @param {string} eventName - e.g. 'event', 'event:camera', 'ws:connected'
   * @param {Function} callback
   */
  on(eventName, callback) {
    if (!this._eventListeners.has(eventName)) {
      this._eventListeners.set(eventName, []);
    }
    this._eventListeners.get(eventName).push(callback);
  }

  off(eventName, callback) {
    const listeners = this._eventListeners.get(eventName);
    if (listeners) {
      const idx = listeners.indexOf(callback);
      if (idx >= 0) listeners.splice(idx, 1);
    }
  }

  /**
   * Remove all registered event listeners.
   * Call this before re-registering listeners on reconnect to prevent duplicates.
   */
  removeAllListeners() {
    this._eventListeners.clear();
  }

  _emit(eventName, data) {
    const listeners = this._eventListeners.get(eventName);
    if (listeners) {
      for (const cb of listeners) {
        try { cb(data); } catch (e) { console.error('Event listener error:', e); }
      }
    }
  }

  // =========================================================================
  // Connection test
  // =========================================================================

  /**
   * Test connectivity by hitting /api/info (public, no auth required).
   * Returns the info response or throws on failure.
   */
  async testConnection() {
    const info = await this._getWithTimeout('/api/info', this._connectionTimeoutMs);
    return info;
  }

  setConnectionState(isConnected) {
    this._connected = Boolean(isConnected);
  }
}

// Singleton instance
const api = new SkotiqApi();
