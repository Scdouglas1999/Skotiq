part of '../headless_api_server.dart';

/// Whether the rate limiter / pairing lockout should believe the
/// `x-forwarded-for` / `x-real-ip` forwarding headers (and only when the
/// socket peer is loopback).
///
/// OFF by default. In the direct-bind deployment those headers are
/// attacker-controlled, so the lockout/limiter key is derived from the real TCP
/// socket peer instead. Set `SKOTIQ_TRUST_PROXY=true` (or `1`/`yes`) ONLY
/// when the appliance runs behind the loopback nginx reverse proxy documented
/// in `docs/remote-control.md` (the "TLS with nginx" section), which binds
/// loopback and injects the forwarding headers itself; in that topology the
/// flag MUST be set or every proxied client collapses into one rate-limit /
/// lockout bucket. Even then the headers are believed only when the socket peer
/// is loopback (see [headlessRateLimitClientKey]). Evaluated once per process.
final bool _rateLimitTrustProxyHeaders = _readTrustProxyFlag();

bool _readTrustProxyFlag() {
  final raw = Platform.environment['SKOTIQ_TRUST_PROXY']?.trim().toLowerCase();
  return raw == 'true' || raw == '1' || raw == 'yes';
}

/// Rate limiting and the high-risk audit trail.
extension _HeadlessApiServerRateLimitMiddleware on HeadlessApiServer {
  Middleware _rateLimitMiddleware() {
    return createMiddleware(
      requestHandler: (request) {
        final path = '/${request.url.path}';
        // per-token / route-class bucket runs first. It supersedes
        // the endpoint window for authenticated requests because (a) it
        // is keyed by the principal rather than by the public IP (NAT-
        // safe), and (b) its route classes carve a per-token budget that
        // the endpoint window cannot express. The endpoint window stays
        // as a defence-in-depth backstop in case the route-class bucket
        // is somehow bypassed (unauthenticated path that still reaches
        // the rate limiter).
        final identity = _authIdentityFrom(request);
        final routeClass = _authRouteClassFrom(request);
        if (identity != null && routeClass != null) {
          final tokenDecision = _tokenBucketLimiter.tryConsume(
            tokenId: identity,
            routeClass: routeClass,
          );
          if (!tokenDecision.allowed) {
            return _denyRateLimited(
              request: request,
              path: path,
              decision: tokenDecision,
              bucketLabel: route_metadata.tokenRouteClassName(routeClass),
              identity: identity,
            );
          }
        }

        // Defence-in-depth: legacy sliding-window check keyed on IP/
        // path. Triggers for unauthenticated requests (which the auth
        // gate above already mostly rejected) and stays useful for
        // catching pathological per-endpoint bursts even after the
        // token bucket allowed the request.
        final decision = _rateLimiter.check(
          clientKey: _rateLimitClientKey(request),
          method: request.method,
          path: path,
        );
        if (decision.allowed) {
          return null;
        }

        return _denyRateLimited(
          request: request,
          path: path,
          decision: decision,
          bucketLabel: 'endpoint',
          identity: identity,
        );
      },
    );
  }

  /// Build the 429 response shared between the per-token and the legacy
  /// endpoint buckets. Body shape matches the task spec
  /// (`{code: 'rate_limited', message, retryAfterSecs}`) while still
  /// including the legacy `error` / `maxRequests` / `retryAfterSeconds`
  /// keys so existing dashboards (which key off `error`) keep working.
  Response _denyRateLimited({
    required Request request,
    required String path,
    required route_metadata.RateLimitDecision decision,
    required String bucketLabel,
    String? identity,
  }) {
    final requestId = _requestIdFrom(request);
    // Redacted form of the principal for log lines: the digest is itself
    // safe to log (it's not a credential) but it's noisy. We surface
    // only the first eight hex chars in human-readable logs while
    // retaining the full digest in the structured fields so log search
    // can correlate across requests.
    final principalLog = identity == null
        ? 'anonymous'
        : identity.substring(0, identity.length < 8 ? identity.length : 8);
    final principalForBody = identity == null
        ? 'anonymous'
        : 'token-$principalLog';
    final message = 'Token $principalForBody exceeded $bucketLabel bucket';
    _logWarning(
      '[RATE][$requestId] ${request.method} $path limited '
      'bucket=$bucketLabel principal=$principalLog '
      'max=${decision.maxRequests} retry=${decision.retryAfterSeconds}s',
      fields: {
        'requestId': requestId,
        'method': request.method,
        'path': path,
        'bucket': bucketLabel,
        'principal': identity,
        'maxRequests': decision.maxRequests,
        'retryAfterSeconds': decision.retryAfterSeconds,
      },
    );
    return jsonRateLimited(
      {
        'code': 'rate_limited',
        'error': 'Rate limit exceeded',
        'message': message,
        'bucket': bucketLabel,
        'maxRequests': decision.maxRequests,
        'retryAfterSecs': decision.retryAfterSeconds,
        'retryAfterSeconds': decision.retryAfterSeconds,
        'requestId': requestId,
      },
      headers: {'retry-after': decision.retryAfterSeconds.toString()},
    );
  }

  Middleware _highRiskAuditMiddleware() {
    return (innerHandler) {
      return (request) async {
        final path = '/${request.url.path}';
        final auditAction = route_metadata.highRiskAuditActionFor(
          method: request.method,
          path: path,
        );
        if (auditAction == null) {
          return innerHandler(request);
        }

        final requestId = _requestIdFrom(request);
        final clientKey = _rateLimitClientKey(request);
        _logger.info(
          '[AUDIT][$requestId] $auditAction requested '
          'method=${request.method} path=$path client=$clientKey',
          source: 'HeadlessApiAudit',
          fields: {
            'requestId': requestId,
            'auditAction': auditAction,
            'method': request.method,
            'path': path,
            'client': clientKey,
            'phase': 'requested',
          },
        );

        final response = await innerHandler(request);
        _logger.info(
          '[AUDIT][$requestId] $auditAction completed '
          'status=${response.statusCode}',
          source: 'HeadlessApiAudit',
          fields: {
            'requestId': requestId,
            'auditAction': auditAction,
            'method': request.method,
            'path': path,
            'client': clientKey,
            'phase': 'completed',
            'statusCode': response.statusCode,
          },
        );
        return response;
      };
    };
  }

  /// Stable key for the rate limiter and the pairing brute-force lockout.
  ///
  /// This MUST derive from the real TCP socket peer rather than the
  /// client-supplied `x-forwarded-for` / `x-real-ip` headers. In the default
  /// direct-bind deployment those headers are attacker-controlled, so keying
  /// off them lets a client rotate the header to evade both the pairing
  /// lockout and the bearer-token failure limiter. Forwarding headers are
  /// honoured only when the appliance is explicitly configured to sit behind
  /// the documented loopback reverse proxy (see [_rateLimitTrustProxyHeaders]).
  String _rateLimitClientKey(Request request) {
    return headlessRateLimitClientKey(
      request,
      trustForwardedHeaders: _rateLimitTrustProxyHeaders,
    );
  }
}
