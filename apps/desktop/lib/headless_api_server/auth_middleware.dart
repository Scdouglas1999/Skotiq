part of '../headless_api_server.dart';

/// Bearer-token authentication, session ownership and paired-device activity.
extension _HeadlessApiServerAuthMiddleware on HeadlessApiServer {
  /// Holds each request until `start()` has loaded the paired session tokens,
  /// so the auth check below never refuses a valid paired device because the
  /// pairing database had not been read yet.
  Middleware _pairedTokenHydrationGate() {
    return (innerHandler) {
      return (request) async {
        final pending = _pairedTokenHydration;
        if (pending != null) {
          await pending;
        }
        return innerHandler(request);
      };
    };
  }

  /// Middleware that validates Bearer token authentication.
  ///
  /// The authentication-exempt surface is declared once in
  /// `headless_api/auth/public_paths.dart` and enforced here; `GET /api/info`
  /// publishes that same declaration as `publicEndpoints`.
  ///
  /// WebSocket endpoints (/api/ws, /events) require authentication when enabled.
  /// They accept the token via Authorization header or `token` query parameter
  /// (since browsers cannot set custom headers on WebSocket upgrades).
  Middleware _authMiddleware() {
    // WebSocket paths that support query-param auth: the legacy ?token= form
    // or the single-use ?ticket= form.
    //
    // /ws/live-view participates in the same query-param auth flow
    // because browser/WS clients can't always set custom headers on the
    // upgrade request — the phone passes the bearer token via ?token= and
    // we honour it here.
    const webSocketPaths = {'/api/ws', '/events', '/ws/live-view'};

    return (innerHandler) {
      return (request) {
        // FAIL CLOSED when unconfigured. Short-circuiting every request
        // because no tokens are configured would serve a fresh appliance wide
        // open, so that path is reachable only behind the explicit
        // `--allow-unauthenticated` / NIGHTSHADE_ALLOW_UNAUTHENTICATED opt-in
        // (a prominent warning is logged at startup, see server_lifecycle).
        //
        // Without the opt-in the request falls through to the public-path
        // allowlist below: an unconfigured server exposes only the
        // pairing/discovery/dashboard bootstrap surface so the appliance can be
        // onboarded, while every privileged endpoint requires a bearer token
        // and returns 401 until a token is configured or a device pairs.
        //
        // The override only opens a server that has NO configured tokens. A
        // token being present is what every truth surface reads as
        // "authentication is on": the startup banner (server_lifecycle),
        // `authRequired`/`authScopes` on GET /api/info, the mDNS advertisement,
        // and `bindLocalOnly` (a configured token is what moves the socket onto
        // the LAN). If the override also beat configured tokens, all four would
        // announce a locked server while it served every endpoint open on the
        // network — so `--allow-unauthenticated` must never outrank a token.
        // Restored PAIRING sessions are a different matter and are deliberately
        // NOT part of this test: they must not silently re-enable auth after an
        // operator asked for an open server, which is why `_pairedSessionTokens`
        // is not consulted here.
        if (allowUnauthenticated && _effectiveAuthTokensByValue.isEmpty) {
          return innerHandler(request);
        }

        // Skip auth for the declared public surface (exact paths plus the two
        // SPA bundle roots) — the same declaration /api/info publishes.
        final requestId = _requestIdFrom(request);
        final path = '/${request.url.path}';
        if (isPublicApiPath(path)) {
          return innerHandler(request);
        }

        // For WebSocket paths, accept either the legacy ?token=<bearer> (with
        // a deprecation warning) or the one-shot ?ticket=, which is consumed
        // and invalidated here so it cannot be reused.
        if (webSocketPaths.contains(path)) {
          final queryTicket = request.url.queryParameters['ticket'];
          if (queryTicket != null && queryTicket.isNotEmpty) {
            // ws_ticket_manager.consume returns the digest of the token
            // that minted the ticket, NOT the raw token. That digest IS
            // the authenticated identity for the upcoming WS — stash it
            // on the context so the upgrade handler can bind it to the
            // socket as the canonical viewer id.
            final ticketIdentity = _wsTicketManager.consume(queryTicket);
            if (ticketIdentity != null) {
              return innerHandler(
                _attachAuthIdentity(
                  request,
                  identity: ticketIdentity,
                  routeClass: route_metadata.tokenRouteClassFor(
                    method: request.method,
                    path: path,
                  ),
                ),
              );
            }
            // Bad/expired ticket — do NOT fall through to legacy token to
            // avoid masking a stolen-ticket replay attempt with a successful
            // bearer-token outcome. Reject explicitly.
            _logWarning(
              '[AUTH][$requestId] Rejected WS upgrade to $path - invalid or expired ticket',
            );
            return jsonUnauthorized(
              {
                'error': 'Authentication required',
                'message': 'Invalid or expired WebSocket ticket',
              },
              headers: {HeadlessApiServer._requestIdHeader: requestId},
            );
          }

          final queryToken = request.url.queryParameters['token'];
          if (queryToken != null && queryToken.isNotEmpty) {
            // The legacy ?token= path goes through the SAME bearer-token
            // failure limiter as the Authorization-header path. Unthrottled,
            // each garbage WS token attempt drives the O(N*L) constant-time
            // _scopeForToken scan pre-auth. Check the limiter BEFORE the scan;
            // record a failure when the token resolves to no/disallowed scope;
            // clear on success.
            final wsClientKey = _rateLimitClientKey(request);
            if (_tokenResolver.isRateLimited(wsClientKey)) {
              _logWarning(
                '[AUTH][$requestId] Rate-limited WS ?token= attempts from '
                '$wsClientKey on $path',
              );
              return jsonRateLimited(
                {
                  'error': 'Rate limit exceeded',
                  'message': 'Too many authentication failures',
                  'requestId': requestId,
                },
                headers: {
                  HeadlessApiServer._requestIdHeader: requestId,
                  'retry-after': '60',
                },
              );
            }
            final queryGrant = _grantForToken(queryToken);
            if (queryGrant != null &&
                HeadlessAuthPolicy.permits(
                  grant: queryGrant,
                  method: 'WS',
                  path: path,
                )) {
              _tokenResolver.clearFailures(wsClientKey);
              // The event stream is how a phone stays live all night; a client
              // that only ever holds this socket open must still register as
              // seen.
              _touchPairedDeviceSeen(queryToken);
              _logWarning(
                '[AUTH][$requestId] WS upgrade to $path used legacy ?token=. '
                'Switch to POST /api/ws/ticket + ?ticket=.',
              );
              return innerHandler(
                _attachAuthIdentity(
                  request,
                  identity: computeServerFingerprint(queryToken),
                  routeClass: route_metadata.tokenRouteClassFor(
                    method: request.method,
                    path: path,
                  ),
                ),
              );
            }
            // Unknown or scope-disallowed ?token= — count it against the
            // failure limiter so repeated bad attempts trip the 429 lockout,
            // mirroring the Authorization-header path's recordFailure.
            _tokenResolver.recordFailure(wsClientKey);
          }
          // Fall through to check Authorization header below.
        }

        // Resolve credentials. Acceptable forms:
        //  1. `Authorization: Bearer <token>` header (mobile clients, API
        //     consumers, the dashboard's pre-cookie path).
        //  2. The `nightshade_session` HttpOnly cookie set by
        //     `POST /api/auth/cookie` after a successful pairing. Cookie
        //     requests additionally require a matching CSRF token on every
        //     state-changing method.
        //  3. `?access_token=<bearer>` query parameter, but ONLY for the
        //     SSE endpoint. Why: browser EventSource cannot set
        //     custom headers and the SSE handler is GET-only / read-only,
        //     so a one-shot URL token is the only viable auth carrier
        //     for the phone client. This is gated to /api/run-watch/events
        //     so general endpoints still require the header form.
        //
        // We resolve the cookie BEFORE the Authorization header so a single
        // dashboard tab that has both (e.g. mid-migration) still gets the
        // CSRF check applied. If both are present the Authorization header
        // takes precedence (it is the active session the browser opted into
        // for this request).
        final authHeader = request.headers['authorization'];
        final cookieHeader = request.headers['cookie'];
        final sessionCookie = AuthCookieManager.extractCookie(cookieHeader);
        String? token;
        bool tokenFromCookie = false;
        // accept ?access_token= on the SSE endpoint only.
        // extends this to the /api/logs/tail SSE endpoint for the
        // same reason: browser EventSource cannot set custom headers,
        // so a one-shot query-param bearer is the only viable carrier
        // for the phone client. Both endpoints are GET-only and
        // read-only so a leaked URL token (e.g. via a screenshot) has
        // bounded blast radius.
        if (path == '/api/run-watch/events' || path == '/api/logs/tail') {
          final qToken = request.url.queryParameters['access_token'];
          if (qToken != null && qToken.isNotEmpty) {
            token = qToken;
          }
        }
        if (token == null && authHeader != null) {
          if (!authHeader.startsWith('Bearer ')) {
            _logWarning(
              '[AUTH][$requestId] Rejected request to $path - invalid auth format',
            );
            return jsonUnauthorized(
              {
                'error': 'Authentication required',
                'message':
                    'Invalid Authorization header format. Expected: Bearer <token>',
              },
              headers: {HeadlessApiServer._requestIdHeader: requestId},
            );
          }
          token = authHeader.substring(7); // Remove 'Bearer ' prefix
        }
        if (token == null && sessionCookie != null) {
          final cookieBearer = _authCookieManager.resolveBearer(sessionCookie);
          if (cookieBearer != null) {
            token = cookieBearer;
            tokenFromCookie = true;
          }
        }

        if (token == null) {
          _logWarning(
            '[AUTH][$requestId] Rejected request to $path - no Authorization header or session cookie',
          );
          return jsonUnauthorized(
            {
              'error': 'Authentication required',
              'message': 'Missing Authorization header or session cookie',
            },
            headers: {HeadlessApiServer._requestIdHeader: requestId},
          );
        }

        // CSRF gate for cookie-authenticated requests. Why only when the
        // token came from the cookie: bearer-header requests are not
        // ambient-credentialed by the browser, so a cross-origin attacker
        // cannot get the header attached automatically. Cookie requests,
        // however, are sent on every same-site fetch — the CSRF token
        // (in-memory in JS, mirrored to a request header) is what proves
        // the request actually originated from the dashboard SPA.
        //
        // GET/HEAD/OPTIONS are excluded because CSRF protects state
        // changes; read-only responses do not need it (and pre-flighting
        // every GET would break image/event endpoints).
        if (tokenFromCookie &&
            HeadlessApiServer._methodNeedsCsrf(request.method)) {
          final presented =
              request.headers[AuthCookieManager.csrfHeader.toLowerCase()];
          if (!_authCookieManager.validateCsrf(
            cookieToken: sessionCookie,
            presented: presented,
          )) {
            _logWarning(
              '[AUTH][$requestId] Rejected cookie request to $path - missing or invalid CSRF token',
            );
            return jsonForbidden(
              {
                'error': 'csrf_required',
                'message':
                    'A valid ${AuthCookieManager.csrfHeader} header is required for this method.',
              },
              headers: {HeadlessApiServer._requestIdHeader: requestId},
            );
          }
        }

        final clientKey = _rateLimitClientKey(request);
        // Why pre-check: the constant-time loop is O(N*L) over the token
        // table, so an attacker spamming bad tokens turns it into a CPU-burn
        // vector. The resolver tracks per-client failure counts and sheds load
        // with 429 once the bucket fills.
        if (_tokenResolver.isRateLimited(clientKey)) {
          _logWarning(
            '[AUTH][$requestId] Rate-limited token comparisons from $clientKey on $path',
          );
          return jsonRateLimited(
            {
              'error': 'Rate limit exceeded',
              'message': 'Too many authentication failures',
              'requestId': requestId,
            },
            headers: {
              HeadlessApiServer._requestIdHeader: requestId,
              'retry-after': '60',
            },
          );
        }
        final tokenGrant = _grantForToken(token);
        if (tokenGrant == null) {
          _tokenResolver.recordFailure(clientKey);
          _logWarning(
            '[AUTH][$requestId] Rejected request to $path - invalid token',
          );
          return jsonForbidden(
            {
              'error': 'Access denied',
              'message': 'Invalid authentication token',
            },
            headers: {HeadlessApiServer._requestIdHeader: requestId},
          );
        }
        // Token recognised — clear stale failures so a successful login
        // resets the counter for that client.
        _tokenResolver.clearFailures(clientKey);
        _touchPairedDeviceSeen(token);

        if (!HeadlessAuthPolicy.permits(
          grant: tokenGrant,
          method: request.method,
          path: path,
        )) {
          final requiredCapability = HeadlessAuthPolicy.requiredCapabilityFor(
            method: request.method,
            path: path,
          );
          final requiredScope = HeadlessAuthPolicy.requiredScopeFor(
            method: request.method,
            path: path,
          );
          _logWarning(
            '[AUTH][$requestId] Rejected request to $path - '
            'scope=${headlessTokenScopeName(tokenGrant.coarseScope)} '
            'required=${headlessTokenScopeName(requiredScope)} '
            'resource=${headlessResourceName(requiredCapability.resource)} '
            'level=${headlessAccessLevelName(requiredCapability.level)}',
          );
          // The body is built from the grant and the endpoint that decided the
          // refusal, in HeadlessAuthPolicy, so it cannot drift from the
          // decision — see [HeadlessAuthPolicy.scopeDenialBody] for why the
          // coarse pair is conditional.
          return jsonForbidden(
            HeadlessAuthPolicy.scopeDenialBody(
              grant: tokenGrant,
              method: request.method,
              path: path,
            ),
            headers: {HeadlessApiServer._requestIdHeader: requestId},
          );
        }

        // Token is valid, continue to handler. Stash the digest of the
        // resolved token + the request's route class so the rate-limit
        // middleware (and any handler that wants to log the principal
        // without a re-resolution) can read it back. We MUST NOT pass
        // the raw token through the context — see [_authIdentityContextKey].
        return innerHandler(
          _attachAuthIdentity(
            request,
            identity: computeServerFingerprint(token),
            routeClass: route_metadata.tokenRouteClassFor(
              method: request.method,
              path: path,
            ),
          ),
        );
      };
    };
  }

  /// stash the authenticated principal's digest + the
  /// classified route class on the shelf request context so downstream
  /// middleware (rate limit) and the WS upgrade handler can bind to them.
  ///
  /// The raw bearer is NEVER placed on the context — only its SHA-256
  /// digest via `computeServerFingerprint`, which is the same value the
  /// session-ownership manager uses to identify owners and what every
  /// other code path digests to.
  Request _attachAuthIdentity(
    Request request, {
    required String identity,
    required route_metadata.TokenRouteClass routeClass,
  }) {
    return request.change(
      context: {
        HeadlessApiServer._authIdentityContextKey: identity,
        HeadlessApiServer._authRouteClassContextKey: routeClass,
      },
    );
  }

  /// Read the authenticated principal digest off the request context.
  /// Returns null when the auth middleware didn't run (e.g. test fixtures
  /// with no token configured), in which case the rate limiter falls back
  /// to the IP-based key.
  String? _authIdentityFrom(Request request) {
    final value = request.context[HeadlessApiServer._authIdentityContextKey];
    return value is String ? value : null;
  }

  route_metadata.TokenRouteClass? _authRouteClassFrom(Request request) {
    final value = request.context[HeadlessApiServer._authRouteClassContextKey];
    return value is route_metadata.TokenRouteClass ? value : null;
  }

  /// extract the raw bearer token (or cookie-backed session token)
  /// from [request]. The auth middleware has already validated whatever
  /// we resolve here; we re-extract because the validated value is not
  /// currently propagated into the request context.
  ///
  /// Returns null when no token is present — callers must treat that as
  /// an unauthenticated request even though the auth middleware should
  /// have rejected it first.
  String? _extractBearerToken(Request request) {
    final authHeader = request.headers['authorization'];
    if (authHeader != null && authHeader.startsWith('Bearer ')) {
      return authHeader.substring(7);
    }
    final cookieHeader = request.headers['cookie'];
    final sessionCookie = AuthCookieManager.extractCookie(cookieHeader);
    if (sessionCookie != null) {
      final cookieBearer = _authCookieManager.resolveBearer(sessionCookie);
      if (cookieBearer != null) {
        return cookieBearer;
      }
    }
    return null;
  }

  /// gate destructive POSTs on the operator slot. Read-only and
  /// status endpoints fall through unchanged. The middleware also
  /// refreshes the owner's heartbeat on every authenticated mutating
  /// request so a phone polling the rig stays the owner without an
  /// explicit WS frame.
  Middleware _sessionOwnershipMiddleware() {
    return createMiddleware(
      requestHandler: (request) {
        final path = '/${request.url.path}';
        if (!isOwnershipRequired(method: request.method, path: path)) {
          return null;
        }
        // Reaching this branch means: (a) an authenticated request, (b)
        // a mutating verb, (c) a path on the destructive allow-list. If
        // there is no owner yet, the slot is unclaimed and every
        // control-scope client falls back to the legacy "first-come,
        // first-served" semantics — we do NOT block when nobody has
        // claimed the rig, because the dashboard's initial pairing flow
        // (which has not yet POSTed /api/session/claim) must still be
        // able to drive the gear.
        final owner = _sessionOwnership.current;
        if (owner == null) {
          return null;
        }
        final token = _extractBearerToken(request);
        if (token == null) {
          // Auth middleware should have caught this; defensive.
          return jsonForbidden({
            'error': 'auth_required',
            'message':
                'Session-ownership-gated endpoints require a bearer token.',
          });
        }
        if (!_sessionOwnership.isOwner(token)) {
          return jsonConflict({
            'error': 'not_session_owner',
            'message':
                'Another client is the operator. POST /api/session/take-over '
                'with a reason to displace them.',
            'currentOwner': owner.toJson(),
            'retryWithTakeOver': true,
          });
        }
        // Heartbeat refresh so an actively-driving client never auto-
        // releases under the 5-minute idle timeout.
        _sessionOwnership.touchHeartbeat(token);
        return null;
      },
    );
  }

  /// Resolve [token] to its [HeadlessAuthGrant], or null when unrecognised.
  ///
  /// Why constant-time + full-iteration: a naive Map[token] short-circuits on
  /// hash mismatch, leaking per-character timing of the bearer token to a
  /// network attacker. The resolver iterates the entire map and uses
  /// XOR-based comparison so timing is independent of which entry matches. The
  /// paired-session sweep below mirrors that property — we do NOT branch on the
  /// static-table outcome before completing the paired scan, so the choice
  /// between "static config token" and "paired token" is not observable.
  HeadlessAuthGrant? _grantForToken(String? token) {
    if (token == null || token.isEmpty) {
      return null;
    }
    final staticGrant = _tokenResolver.resolve(token);
    // Paired-session tokens live outside the immutable static map (Drift-
    // backed). Mirror the same constant-time iteration here.
    HeadlessAuthGrant? pairedMatch;
    for (final entry in _pairedSessionTokens.entries) {
      if (constantTimeCompareStrings(entry.key, token)) {
        pairedMatch = entry.value;
      }
    }
    return staticGrant ?? pairedMatch;
  }

  /// Coarse projection of [_grantForToken], kept for the AuthHandlers
  /// recognised-token check (`POST /api/auth/cookie`). Returns null iff the
  /// token is unknown.
  HeadlessTokenScope? _scopeForToken(String? token) {
    return _grantForToken(token)?.coarseScope;
  }

  /// Record that the device holding [token] is talking to us right now.
  ///
  /// Fire-and-forget: a paired client's request must never wait on, or fail
  /// because of, a bookkeeping write. Requests authenticated by a configured
  /// (non-pairing) token match no row and cost one throttled read.
  ///
  /// Goes through [TokenManager.verifySessionToken] rather than writing the
  /// column directly because that method is the auditable pairing-token check —
  /// it re-tests `is_active` and expiry in constant time and stamps
  /// `last_connected_at` as its documented effect — so this cannot record a
  /// device as seen on the strength of a credential the pairing layer would
  /// reject.
  void _touchPairedDeviceSeen(String? token) {
    if (token == null || token.isEmpty) return;
    final service = _pairingService;
    // Never lazily construct the service here: on a GUI host with no pairing DB
    // that would open Drift purely to bookkeep.
    if (service == null) return;

    final now = DateTime.now();
    final last = _pairedDeviceSeenStamps[token];
    if (last != null &&
        now.difference(last) < HeadlessApiServer._lastConnectedThrottle) {
      return;
    }
    _pairedDeviceSeenStamps[token] = now;
    // Bounded alongside the token map it shadows: entries whose token is no
    // longer paired (revoked, expired, evicted) can never be refreshed, so drop
    // everything stale rather than let a long-lived appliance accumulate.
    if (_pairedDeviceSeenStamps.length > _pairedSessionTokens.maxEntries) {
      _pairedDeviceSeenStamps.removeWhere(
        (_, stamped) =>
            now.difference(stamped) >= HeadlessApiServer._lastConnectedThrottle,
      );
    }

    unawaited(
      Future<void>(() async {
        try {
          final rows = await service.tokenManager
              .getActiveUnexpiredPairedDevices();
          String? deviceId;
          for (final row in rows) {
            if (constantTimeCompareStrings(row.sessionToken, token)) {
              deviceId = row.deviceId;
            }
          }
          if (deviceId == null) return;
          await service.tokenManager.verifySessionToken(
            deviceId: deviceId,
            token: token,
          );
        } catch (e) {
          // Let the next request retry instead of waiting out the throttle.
          _pairedDeviceSeenStamps.remove(token);
          _logWarning('[AUTH] Could not record paired-device activity: $e');
        }
      }),
    );
  }
}
