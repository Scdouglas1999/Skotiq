/// Shared shelf-request-context utilities for headless-API handlers.
///
/// The headless API server attaches a few values to every inbound
/// [shelf.Request]'s `context` map so middleware downstream of the
/// request-tracking middleware can read them without re-parsing the
/// request:
///
///   * the per-request UUID-like id used for log correlation
///     ([requestIdContextKey] / [requestIdFrom]),
///   * the SHA-256 digest of the bearer token that authenticated the
///     request, if any ([authIdentityContextKey] / [authIdentityFrom]),
///   * the [route_metadata.TokenRouteClass] the request mapped to
///     ([authRouteClassContextKey] / [authRouteClassFrom]).
///
/// The constants and accessor functions live in this module rather than
/// the server class so handler classes extracted out of
/// `HeadlessApiServer` can read them without a back-reference to the
/// server (which would re-introduce the god-class coupling we just
/// untangled).
library;

import 'package:shelf/shelf.dart';

import 'route_metadata.dart' as route_metadata;

/// HTTP header name carrying the per-request id. Echoed back on every
/// non-WebSocket response by `_requestTrackingMiddleware`.
const String requestIdHeader = 'x-request-id';

/// Shelf request-context key holding the per-request id assigned by the
/// request-tracking middleware. Always a [String] when present.
const String requestIdContextKey = 'requestId';

/// Shelf request-context key holding the SHA-256 digest of the bearer
/// token that authenticated the current request. Populated by the auth
/// middleware ONLY on requests that successfully resolved a token; reads
/// return null when auth is disabled or the request is anonymous.
///
/// We never propagate the raw token through the request context — only
/// the digest — so a misbehaving handler that dumps `request.context`
/// for diagnostics cannot accidentally leak the secret to a log file.
const String authIdentityContextKey = 'skotiq.authIdentity';

/// Shelf request-context key holding the bound
/// [route_metadata.TokenRouteClass] for the current request. Memoised by
/// the auth middleware so the rate-limit middleware doesn't have to
/// re-classify the path.
const String authRouteClassContextKey = 'skotiq.authRouteClass';

/// Extract the per-request id off [request]. Returns the literal string
/// `unknown` when the request-tracking middleware did not run (e.g. unit
/// tests that hit a handler directly).
String requestIdFrom(Request request) =>
    request.context[requestIdContextKey] as String? ?? 'unknown';

/// Extract the authenticated principal's SHA-256 digest off [request].
/// Returns null when the auth middleware didn't run (e.g. test fixtures
/// with no token configured, or anonymous requests on public endpoints).
String? authIdentityFrom(Request request) {
  final value = request.context[authIdentityContextKey];
  return value is String ? value : null;
}

/// Extract the classified [route_metadata.TokenRouteClass] off
/// [request]. Returns null when the auth middleware didn't run, which
/// makes the rate-limit middleware fall back to the legacy per-IP
/// endpoint bucket.
route_metadata.TokenRouteClass? authRouteClassFrom(Request request) {
  final value = request.context[authRouteClassContextKey];
  return value is route_metadata.TokenRouteClass ? value : null;
}

/// Redact a bearer or auth-identity token for structured-log output.
///
/// Shows the first 4 + last 4 characters and masks the middle, so log
/// readers can correlate a token across log lines without exposing the
/// secret in plaintext. Tokens shorter than 9 characters are fully
/// masked because the prefix/suffix overlap would otherwise reveal the
/// whole value.
String redactBearer(String token) {
  if (token.length <= 8) return '*' * token.length;
  return '${token.substring(0, 4)}...${token.substring(token.length - 4)}';
}
