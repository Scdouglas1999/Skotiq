part of '../headless_api_server.dart';

/// Bearer-token authentication, session ownership and paired-device activity.
extension _HeadlessApiServerAuthMiddleware on HeadlessApiServer {
  /// Holds each request until `start()` has loaded the paired session tokens,
  /// so the auth check below never refuses a valid paired device because the
  /// pairing database had not been read yet. The hold is bounded (see
  /// `_pairedTokenHydrationWaitLimit`) so a database that never answers cannot
  /// hang every request.
  Middleware _pairedTokenHydrationGate() {
    return (innerHandler) {
      return (request) async {
        final pending = _pairedTokenHydration;
        if (pending != null) {
          await pending.timeout(
            HeadlessApiServer._pairedTokenHydrationWaitLimit,
            onTimeout: () {},
          );
        }
        return innerHandler(request);
      };
    };
  }

  /// Middleware that validates Bearer token authentication.
  ///
  /// A route is served without a token when it is declared
  /// `ApiScope.public`; `GET /api/info` lists those same routes as
  /// `publicEndpoints`.
  ///
  /// Every other route takes the credentials [_credentialsFrom] reads, each
  /// answered by [_admit].
  Middleware _authMiddleware() {
    return (innerHandler) {
      return (request) {
        // FAIL CLOSED when unconfigured. Short-circuiting every request
        // because no tokens are configured would serve a fresh appliance wide
        // open, so that path is reachable only behind the explicit
        // `--allow-unauthenticated` / SKOTIQ_ALLOW_UNAUTHENTICATED opt-in
        // (a prominent warning is logged at startup, see server_lifecycle).
        //
        // Without the opt-in the request falls through to the public-path
        // allowlist below: an unconfigured server exposes only the
        // pairing/discovery/dashboard bootstrap surface so the appliance can be
        // onboarded, while every privileged endpoint requires a bearer token
        // and returns 401 until a token is configured or a device pairs.
        //
        // The override only opens a server that has NO configured tokens.
        // [isAuthRequired] is this test, and it is also what `authRequired` on
        // GET /api/info and the discovery advertisement publish, so a client
        // is told to pair exactly when this check would refuse it. A
        // configured token also moves the socket onto the LAN
        // (`bindLocalOnly`); if the override beat configured tokens, a server
        // announced as locked would serve every endpoint open on the network,
        // so `--allow-unauthenticated` must never outrank a token.
        // Restored PAIRING sessions are a different matter and are deliberately
        // NOT part of this test: they must not silently re-enable auth after an
        // operator asked for an open server, which is why `_pairedSessionTokens`
        // is not consulted here.
        if (!isAuthRequired) {
          return innerHandler(
            request.change(
              context: {ctx.authGrantContextKey: HeadlessAuthGrant.admin()},
            ),
          );
        }

        // Skip auth for the declared public surface (exact paths plus the two
        // SPA bundle roots) — the same declaration /api/info publishes.
        final requestId = _requestIdFrom(request);
        final path = '/${request.url.path}';
        final route = RouteTable.of(request).policy;
        if (route.scope == ApiScope.public) {
          return innerHandler(request);
        }

        final scopeRefusal = _Refusal();
        for (final credential in _credentialsFrom(request, route)) {
          final answer = _admit(
            innerHandler,
            request,
            requestId,
            path,
            route,
            credential,
            scopeRefusal,
          );
          if (answer != null) return answer;
        }
        if (scopeRefusal.value case final refusal?) return refusal;
        _logWarning(
          '[AUTH][$requestId] Rejected request to $path - no Authorization header or session cookie',
        );
        return _authenticationRequired(
          requestId,
          ApiErrorCodes.authRequired,
          'Missing Authorization header or session cookie',
        );
      };
    };
  }

  /// The credentials [request] presents for [route], in the order they are
  /// tried.
  ///
  /// A socket upgrade may carry a single-use `?ticket=` (then nothing else is
  /// tried, so a replayed ticket is never masked by a working bearer) or the
  /// older `?token=`, which falls through to the forms below when it does not
  /// admit. Then one bearer: `?access_token=` on the routes that take it
  /// (browser EventSource cannot set headers), else the Authorization header,
  /// else the `skotiq_session` cookie set by `POST /api/auth/cookie`.
  List<_Credential> _credentialsFrom(Request request, ApiRoute route) {
    final query = request.url.queryParameters;
    final credentials = <_Credential>[];
    if (route.method == ApiMethod.ws) {
      final ticket = query['ticket'];
      if (ticket != null && ticket.isNotEmpty) return [_Ticket(ticket)];
      final token = query['token'];
      if (token != null && token.isNotEmpty) {
        credentials.add(_QueryToken(token));
      }
    }
    final sessionCookie = AuthCookieManager.extractCookie(
      request.headers['cookie'],
    );
    final accessToken = route.queryToken ? query['access_token'] : null;
    final authHeader = request.headers['authorization'];
    if (accessToken != null && accessToken.isNotEmpty) {
      credentials.add(_Bearer(accessToken, sessionCookie: sessionCookie));
    } else if (authHeader != null) {
      credentials.add(
        authHeader.startsWith('Bearer ')
            ? _Bearer(authHeader.substring(7), sessionCookie: sessionCookie)
            : const _MalformedHeader(),
      );
    } else if (sessionCookie != null) {
      final cookieBearer = _authCookieManager.resolveBearer(sessionCookie);
      if (cookieBearer != null) {
        credentials.add(
          _Bearer(cookieBearer, sessionCookie: sessionCookie, fromCookie: true),
        );
      }
    }
    return credentials;
  }

  /// The answer to [credential]: the request passed on with its principal,
  /// a refusal, or null to try the next credential.
  ///
  /// What differs between the forms:
  ///  * a ticket is checked against no failure limiter (it is single use and
  ///    already consumed), its principal must still be active, and its
  ///    device is not marked seen;
  ///  * `?token=` is limited like a bearer; when it does not admit the next
  ///    credential is tried. An unknown token counts as a failure; a known
  ///    one without the scope does not, and is answered with the ticket
  ///    path's 403 when nothing else admits;
  ///  * a bearer from the cookie must carry the CSRF header on a
  ///    state-changing method (except logout); a recognized bearer clears the
  ///    client's failures and marks its device seen before the scope check.
  FutureOr<Response>? _admit(
    Handler innerHandler,
    Request request,
    String requestId,
    String path,
    ApiRoute route,
    _Credential credential,
    _Refusal scopeRefusal,
  ) {
    switch (credential) {
      case _Ticket(:final ticket):
        // The ticket resolves to the digest of the token that minted it,
        // which is the socket's identity.
        final identity = _wsTicketManager.consume(ticket);
        if (identity == null) {
          _logWarning(
            '[AUTH][$requestId] Rejected WS upgrade to $path - invalid or expired ticket',
          );
          return _authenticationRequired(
            requestId,
            ApiErrorCodes.invalidTicket,
            'Invalid or expired WebSocket ticket',
          );
        }
        final grant = identity.isEmpty ? null : _grantForIdentity(identity);
        if (grant == null) {
          _logWarning(
            '[AUTH][$requestId] Rejected WS upgrade to $path - '
            'ticket principal is no longer active',
          );
          return _authenticationRequired(
            requestId,
            ApiErrorCodes.invalidTicket,
            'Invalid or expired WebSocket ticket',
          );
        }
        if (!HeadlessAuthPolicy.permits(grant: grant, route: route)) {
          _logWarning(
            '[AUTH][$requestId] Rejected WS upgrade to $path - '
            'insufficient scope for ticket principal',
          );
          return _scopeDenied(requestId, grant, route);
        }
        return _admitted(innerHandler, request, route, identity, grant);

      case _QueryToken(:final token):
        final clientKey = _rateLimitClientKey(request);
        if (_tokenResolver.isRateLimited(clientKey)) {
          _logWarning(
            '[AUTH][$requestId] Rate-limited WS ?token= attempts from '
            '$clientKey on $path',
          );
          return _authenticationRateLimited(requestId);
        }
        final grant = _grantForToken(token);
        if (grant == null) {
          _tokenResolver.recordFailure(clientKey);
          return null;
        }
        _tokenResolver.clearFailures(clientKey);
        // A known token without the scope is no failed guess: the next
        // credential is tried, and with none admitting the route answers
        // the ticket path's refusal.
        if (!HeadlessAuthPolicy.permits(grant: grant, route: route)) {
          _logWarning(
            '[AUTH][$requestId] WS upgrade to $path - '
            'insufficient scope for ?token= principal',
          );
          scopeRefusal.value = _scopeDenied(requestId, grant, route);
          return null;
        }
        // A phone that only holds the event socket open all night must still
        // register as seen.
        _touchPairedDeviceSeen(token);
        _logWarning(
          '[AUTH][$requestId] WS upgrade to $path used legacy ?token=. '
          'Switch to POST /api/ws/ticket + ?ticket=.',
        );
        return _admitted(
          innerHandler,
          request,
          route,
          computeServerFingerprint(token),
          grant,
        );

      case _MalformedHeader():
        _logWarning(
          '[AUTH][$requestId] Rejected request to $path - invalid auth format',
        );
        return _authenticationRequired(
          requestId,
          ApiErrorCodes.invalidAuthHeader,
          'Invalid Authorization header format. Expected: Bearer <token>',
        );

      case _Bearer(:final token, :final fromCookie, :final sessionCookie):
        // Only cookie requests need CSRF: the browser attaches the cookie to
        // every same-site request on its own, a header it never does. Reads
        // change nothing, and logout stays open after the CSRF lifetime so an
        // idle tab can still drop its cookie.
        final isLogout =
            request.method.toUpperCase() == 'POST' &&
            path == AuthApi.logout.route.path;
        if (fromCookie &&
            !isLogout &&
            HeadlessApiServer._methodNeedsCsrf(request.method) &&
            !_authCookieManager.validateCsrf(
              cookieToken: sessionCookie,
              presented:
                  request.headers[AuthCookieManager.csrfHeader.toLowerCase()],
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
        // The token lookup is a constant-time scan of every token; the
        // limiter sheds a client spamming bad tokens before it runs.
        final clientKey = _rateLimitClientKey(request);
        if (_tokenResolver.isRateLimited(clientKey)) {
          _logWarning(
            '[AUTH][$requestId] Rate-limited token comparisons from $clientKey on $path',
          );
          return _authenticationRateLimited(requestId);
        }
        final grant = _grantForToken(token);
        if (grant == null) {
          _tokenResolver.recordFailure(clientKey);
          _logWarning(
            '[AUTH][$requestId] Rejected request to $path - invalid token',
          );
          return jsonForbidden(
            const ApiErrorBody(
              code: ApiErrorBody.invalidToken,
              message: 'Invalid authentication token',
              layout: ApiErrorLayout.codeAsError,
            ).toJson(),
            headers: {HeadlessApiServer._requestIdHeader: requestId},
          );
        }
        _tokenResolver.clearFailures(clientKey);
        _touchPairedDeviceSeen(token);
        if (!HeadlessAuthPolicy.permits(grant: grant, route: route)) {
          final requiredCapability = HeadlessAuthPolicy.requiredCapabilityFor(
            route,
          );
          final requiredScope = HeadlessAuthPolicy.requiredScopeFor(route);
          _logWarning(
            '[AUTH][$requestId] Rejected request to $path - '
            'scope=${headlessTokenScopeName(grant.coarseScope)} '
            'required=${headlessTokenScopeName(requiredScope)} '
            'resource=${requiredCapability.resource.wireName} '
            'level=${headlessAccessLevelName(requiredCapability.level)}',
          );
          return _scopeDenied(requestId, grant, route);
        }
        return _admitted(
          innerHandler,
          request,
          route,
          computeServerFingerprint(token),
          grant,
        );
    }
  }

  /// The request passed on with its principal: the token's digest (never the
  /// raw token), the route class and the grant.
  FutureOr<Response> _admitted(
    Handler innerHandler,
    Request request,
    ApiRoute route,
    String identity,
    HeadlessAuthGrant grant,
  ) => innerHandler(
    _attachAuthIdentity(
      request,
      identity: identity,
      routeClass: route.bucket,
      grant: grant,
    ),
  );

  /// 403 built from the grant and the route that refused it, by
  /// [HeadlessAuthPolicy], so the body cannot drift from the decision.
  Response _scopeDenied(
    String requestId,
    HeadlessAuthGrant grant,
    ApiRoute route,
  ) => jsonForbidden(
    HeadlessAuthPolicy.scopeDenialBody(grant: grant, route: route),
    headers: {HeadlessApiServer._requestIdHeader: requestId},
  );

  /// 401 for a request whose credential is missing or unusable, coded by
  /// which.
  Response _authenticationRequired(
    String requestId,
    String code,
    String message,
  ) => jsonUnauthorized(
    {'error': 'Authentication required', 'code': code, 'message': message},
    headers: {HeadlessApiServer._requestIdHeader: requestId},
  );

  /// 429 for a client whose bad tokens tripped the failure limiter.
  Response _authenticationRateLimited(String requestId) => jsonRateLimited(
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
    required ApiBucket routeClass,
    HeadlessAuthGrant? grant,
  }) {
    return request.change(
      context: {
        HeadlessApiServer._authIdentityContextKey: identity,
        HeadlessApiServer._authRouteClassContextKey: routeClass,
        if (grant != null) ctx.authGrantContextKey: grant,
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

  ApiBucket? _authRouteClassFrom(Request request) {
    final value = request.context[HeadlessApiServer._authRouteClassContextKey];
    return value is ApiBucket ? value : null;
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
        if (!RouteTable.of(request).policy.sessionOwner) {
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

  /// The grant of the token whose digest is [identity], the form a socket
  /// keeps its principal in (the raw bearer is never stored on it). Null when
  /// no configured or paired token has that digest any more.
  HeadlessAuthGrant? _grantForIdentity(String identity) {
    HeadlessAuthGrant? match;
    for (final entry in _effectiveAuthTokensByValue.entries) {
      if (constantTimeCompareStrings(
        computeServerFingerprint(entry.key),
        identity,
      )) {
        match = entry.value;
      }
    }
    for (final entry in _pairedSessionTokens.entries) {
      if (constantTimeCompareStrings(
        computeServerFingerprint(entry.key),
        identity,
      )) {
        match ??= entry.value;
      }
    }
    return match;
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

/// The refusal a `?token=` without the route's scope earned, answered when no
/// other credential admits the request.
final class _Refusal {
  Response? value;
}

/// A credential a request presents; see `_credentialsFrom`.
sealed class _Credential {
  const _Credential();
}

/// A socket's single-use `?ticket=`.
final class _Ticket extends _Credential {
  const _Ticket(this.ticket);
  final String ticket;
}

/// A socket's `?token=<bearer>`.
final class _QueryToken extends _Credential {
  const _QueryToken(this.token);
  final String token;
}

/// An Authorization header that is not `Bearer <token>`.
final class _MalformedHeader extends _Credential {
  const _MalformedHeader();
}

/// A bearer token from `?access_token=`, the Authorization header or the
/// session cookie ([fromCookie]); [sessionCookie] is the request's cookie,
/// which the CSRF check reads.
final class _Bearer extends _Credential {
  const _Bearer(this.token, {this.sessionCookie, this.fromCookie = false});
  final String token;
  final String? sessionCookie;
  final bool fromCookie;
}
