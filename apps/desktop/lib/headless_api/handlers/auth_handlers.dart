/// HTTP handlers for the headless API's web-auth surfaces.
///
/// Owns the four endpoints that issue and revoke the credentials a
/// browser dashboard or mobile client needs once the user has paired
/// (the pairing flow itself lives in [PairingHandlers]):
///   * `POST /api/ws/ticket` — mint a single-use WebSocket-upgrade
///     ticket so the browser doesn't have to leak the bearer token via
///     `?token=`.
///   * `POST /api/auth/cookie` — exchange a freshly-paired bearer token
///     for an HttpOnly session cookie + CSRF token. JS cannot read the
///     cookie; the SPA must echo the CSRF token on every state change.
///   * `GET /api/auth/csrf` — fetch the CSRF token bound to the
///     caller's session cookie. Called on page load when the SPA finds
///     a cookie has already been issued.
///   * `POST /api/auth/logout` — revoke the session cookie. Clears the
///     cookie on the browser AND drops the server-side session so a
///     copied cookie value cannot be reused after logout.
///
/// Bearer-token validation, the constant-time scope resolver, and the
/// auth middleware itself remain in [HeadlessApiServer]; this class
/// only handles the post-pairing browser-credential lifecycle.
library;

import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../auth/auth_cookie.dart';
import '../auth/ws_ticket_manager.dart';
import '../auth_policy.dart';
import '../request_context.dart';
import '../response_helpers.dart';

/// Resolves a bearer token to its [HeadlessTokenScope], or null if the
/// token is unknown. The auth middleware uses a constant-time
/// implementation; we accept any function with the same signature so
/// tests can substitute a deterministic resolver.
typedef TokenScopeResolver = HeadlessTokenScope? Function(String? token);

/// HTTP handlers for the headless API's WebSocket-ticket and
/// dashboard-cookie endpoints. Stateless beyond the two injected
/// managers; constructed once per server.
class AuthHandlers {
  final WsTicketManager wsTicketManager;
  final AuthCookieManager authCookieManager;
  final TokenScopeResolver scopeForToken;
  final LoggingService logger;

  AuthHandlers({
    required this.wsTicketManager,
    required this.authCookieManager,
    required this.scopeForToken,
    required this.logger,
  });

  void _logWarning(String message) =>
      logger.warning(message, source: 'AuthHandlers');

  /// `POST /api/ws/ticket` — mint a single-use ticket the caller can
  /// present on a subsequent WebSocket upgrade. The ticket is bound to
  /// the auth identity that minted it so the upgrade handler
  /// can identify the connection without trusting any client-supplied
  /// `viewerId` field.
  ///
  /// Auth middleware has already verified the bearer token before we
  /// get here (the route is not public), so the handler does not
  /// re-check it.
  Future<Response> handleWsTicketIssue(Request request) async {
    final requestId = requestIdFrom(request);
    final identity = authIdentityFrom(request);
    final ticket = wsTicketManager.issue(identity: identity);
    return jsonOk(
      {
        'ticket': ticket,
        'expiresInSeconds': wsTicketManager.ticketLifetime.inSeconds,
      },
      headers: {requestIdHeader: requestId},
    );
  }

  /// `POST /api/auth/cookie` — issue an HttpOnly session cookie + CSRF
  /// token for the dashboard "remember me" path (long form).
  ///
  /// The caller MUST already be authenticated with a raw
  /// `Authorization: Bearer <token>` header. We deliberately reject
  /// cookie-authenticated callers here so a stolen session cookie
  /// cannot mint a fresh cookie for itself — escalation requires the
  /// raw bearer the user typed (or retrieved from the pairing flow).
  ///
  /// Response shape: `{ "csrfToken": "...", "expiresInSeconds": N }`.
  /// The cookie value is NEVER returned in the body — only via
  /// `Set-Cookie` — so a logging proxy or response-scraping JS cannot
  /// read it.
  Future<Response> handleAuthCookieIssue(Request request) async {
    final requestId = requestIdFrom(request);
    final authHeader = request.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      _logWarning(
        '[AUTH][$requestId] Cookie issue rejected: bearer token required '
        '(no cookie escalation).',
      );
      return jsonUnauthorized(
        {
          'error': 'bearer_required',
          'message':
              'POST /api/auth/cookie requires an Authorization: Bearer <token> header.',
        },
        headers: {requestIdHeader: requestId},
      );
    }
    final bearer = authHeader.substring(7);
    final scope = scopeForToken(bearer);
    if (scope == null) {
      // Defence-in-depth: middleware would have rejected, but a future
      // middleware reorder must not be able to mint cookies for
      // unrecognised tokens.
      _logWarning(
        '[AUTH][$requestId] Cookie issue rejected: bearer token did not '
        'resolve to a scope.',
      );
      return jsonForbidden(
        {
          'error': 'invalid_token',
          'message': 'The bearer token is not recognised.',
        },
        headers: {requestIdHeader: requestId},
      );
    }
    final issue = authCookieManager.mint(bearer);
    final secure = !_isPlainHttpRequest(request);
    final setCookie = AuthCookieManager.buildSetCookieHeader(
      cookieToken: issue.cookieToken,
      maxAge: issue.maxAge,
      secure: secure,
    );
    return jsonOk(
      {
        'csrfToken': issue.csrfToken,
        'expiresInSeconds': issue.maxAge.inSeconds,
      },
      headers: {requestIdHeader: requestId, 'set-cookie': setCookie},
    );
  }

  /// `GET /api/auth/csrf` — return the CSRF token bound to the caller's
  /// session cookie. The dashboard SPA calls this on page load when it
  /// detects a session cookie has been sent (the cookie itself is
  /// HttpOnly so JS cannot read it, but the browser attaches it
  /// automatically and the server returns the matching CSRF token).
  Future<Response> handleAuthCsrfFetch(Request request) async {
    final requestId = requestIdFrom(request);
    final cookieHeader = request.headers['cookie'];
    final sessionCookie = AuthCookieManager.extractCookie(cookieHeader);
    final csrf = authCookieManager.fetchCsrf(sessionCookie);
    if (csrf == null) {
      return jsonUnauthorized(
        {
          'error': 'no_session',
          'message':
              'No active session cookie. Pair this browser, then POST /api/auth/cookie.',
        },
        headers: {requestIdHeader: requestId},
      );
    }
    return jsonOk(
      {
        'csrfToken': csrf,
        'expiresInSeconds': AuthCookieManager.csrfLifetime.inSeconds,
      },
      headers: {requestIdHeader: requestId},
    );
  }

  /// `POST /api/auth/logout` — revoke the caller's session cookie.
  /// Clears the cookie on the browser AND drops the server-side
  /// session so a copied cookie value cannot be reused after logout.
  Future<Response> handleAuthLogout(Request request) async {
    final requestId = requestIdFrom(request);
    final cookieHeader = request.headers['cookie'];
    final sessionCookie = AuthCookieManager.extractCookie(cookieHeader);
    authCookieManager.revoke(sessionCookie);
    final secure = !_isPlainHttpRequest(request);
    return jsonOk(
      {'loggedOut': true},
      headers: {
        requestIdHeader: requestId,
        'set-cookie': AuthCookieManager.buildClearCookieHeader(secure: secure),
      },
    );
  }

  /// Whether this request landed over plain HTTP.
  ///
  /// Browsers discard a `Secure` cookie received from any plain-HTTP origin,
  /// including the documented LAN dashboard (`http://<rig-ip>:8080`). The
  /// attribute must therefore follow the transport, not the hostname.
  ///
  /// This does not make HTTP private: bearer/cookie traffic on a plain LAN
  /// remains visible to that LAN. Operators who terminate TLS still receive a
  /// `Secure` cookie because Shelf preserves the request URI scheme.
  bool _isPlainHttpRequest(Request request) =>
      request.requestedUri.scheme.toLowerCase() != 'https';
}
