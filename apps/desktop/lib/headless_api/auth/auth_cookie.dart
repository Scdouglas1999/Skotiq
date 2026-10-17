import 'dart:math';

import 'timing.dart';

/// HttpOnly cookie + CSRF token session store for the web dashboard.
///
/// Why a dedicated store: the bearer token is the only credential that proves
/// "this caller is allowed to drive the rig", and `localStorage` is
/// JS-readable, so an XSS could exfiltrate it from there. The cookie path
/// stashes the token in an `HttpOnly; Secure; SameSite=Strict` cookie that JS
/// cannot read at all, and pairs it with a CSRF token (random, server-issued)
/// that the dashboard must echo via `X-Skotiq-CSRF` on every state-changing
/// request. The CSRF token is JS-readable but cookies are not — that asymmetry
/// is what defeats both XSS-driven exfiltration and cross-origin form posts.
///
/// Concurrency: the headless server is single-isolate; mutations happen inside
/// shelf middleware so there is no need for synchronization primitives.
class AuthCookieManager {
  /// How long an HttpOnly cookie is valid for. Mirrored into the
  /// `Max-Age` attribute when issuing the cookie. 30 days so an operator does
  /// not have to re-pair every time they reopen the browser.
  static const Duration cookieLifetime = Duration(days: 30);

  /// How long a CSRF token remains valid for before the dashboard must
  /// re-fetch one. Why generous: a single dashboard tab can sit open all
  /// night during an imaging run; expiring the CSRF mid-session would force
  /// the operator to re-issue commands. We extend on every successful
  /// validation so an active session never times out.
  static const Duration csrfLifetime = Duration(days: 7);

  static const String cookieName = 'skotiq_session';
  static const String csrfHeader = 'X-Skotiq-CSRF';

  static const int _cookieTokenBytes = 32;
  static const int _csrfTokenBytes = 32;
  static const int _maxSessions = 256;

  final Random _random;
  final DateTime Function() _now;

  // Sessions keyed by the cookie-token value. Each entry holds the bearer
  // token exchanged for the cookie (so the auth middleware can resolve a
  // cookie-bearing request back to the same scope resolution a bearer-header
  // request would get) and the CSRF token bound to that session.
  final Map<String, _CookieSession> _sessions = {};

  AuthCookieManager({Random? random, DateTime Function()? now})
    : _random = random ?? Random.secure(),
      _now = now ?? DateTime.now;

  /// Mint a new session for [bearerToken]. Returns the pair of values the
  /// caller must hand back to the browser: the cookie value (which the
  /// server emits via `Set-Cookie`) and the CSRF token (returned in the
  /// JSON body for JS to stash in memory).
  ///
  /// Why both at once: the dashboard only ever calls this from the "remember
  /// me" success path, and re-fetching the CSRF separately would require a
  /// second authenticated round-trip immediately after issuance.
  AuthCookieIssue mint(String bearerToken) {
    _purgeExpired();
    _evictIfOverCapacity();
    final cookieToken = _randomToken(_cookieTokenBytes);
    final csrfToken = _randomToken(_csrfTokenBytes);
    final now = _now();
    _sessions[cookieToken] = _CookieSession(
      bearerToken: bearerToken,
      csrfToken: csrfToken,
      cookieExpiresAt: now.add(cookieLifetime),
      csrfExpiresAt: now.add(csrfLifetime),
    );
    return AuthCookieIssue(
      cookieToken: cookieToken,
      csrfToken: csrfToken,
      maxAge: cookieLifetime,
    );
  }

  /// Resolve the bearer token associated with [cookieToken] if it exists and
  /// has not expired. Returns `null` on miss. Uses constant-time comparison
  /// so the lookup does not leak which session matched via timing.
  String? resolveBearer(String? cookieToken) {
    if (cookieToken == null || cookieToken.isEmpty) {
      return null;
    }
    _purgeExpired();
    String? matchedKey;
    for (final entry in _sessions.entries) {
      if (constantTimeCompareStrings(entry.key, cookieToken)) {
        matchedKey = entry.key;
      }
    }
    if (matchedKey == null) {
      return null;
    }
    return _sessions[matchedKey]!.bearerToken;
  }

  /// Fetch (and refresh) the CSRF token bound to [cookieToken]. Refresh
  /// semantics: every successful read pushes the CSRF expiry forward, so an
  /// active operator never sees their CSRF token expire mid-session.
  ///
  /// Returns `null` if the cookie is unknown or expired — callers should
  /// treat that as "the session needs to be re-minted via the cookie
  /// endpoint with a fresh bearer header."
  String? fetchCsrf(String? cookieToken) {
    if (cookieToken == null || cookieToken.isEmpty) {
      return null;
    }
    _purgeExpired();
    String? matchedKey;
    for (final entry in _sessions.entries) {
      if (constantTimeCompareStrings(entry.key, cookieToken)) {
        matchedKey = entry.key;
      }
    }
    if (matchedKey == null) {
      return null;
    }
    final session = _sessions[matchedKey]!;
    session.csrfExpiresAt = _now().add(csrfLifetime);
    return session.csrfToken;
  }

  /// Validate [presented] CSRF token against the one currently bound to
  /// [cookieToken]. Both inputs are required and must match. Returns `true`
  /// only on a constant-time match and a live (non-expired) session.
  bool validateCsrf({
    required String? cookieToken,
    required String? presented,
  }) {
    if (cookieToken == null ||
        cookieToken.isEmpty ||
        presented == null ||
        presented.isEmpty) {
      return false;
    }
    _purgeExpired();
    String? matchedKey;
    for (final entry in _sessions.entries) {
      if (constantTimeCompareStrings(entry.key, cookieToken)) {
        matchedKey = entry.key;
      }
    }
    if (matchedKey == null) {
      return false;
    }
    final session = _sessions[matchedKey]!;
    // Why compare against the session's CSRF using constant-time as well:
    // a timing leak here would let an attacker who already controls some
    // origin (and can therefore forge POSTs) brute-force the CSRF byte-by-
    // byte to bypass it.
    if (!constantTimeCompareStrings(session.csrfToken, presented)) {
      return false;
    }
    session.csrfExpiresAt = _now().add(csrfLifetime);
    return true;
  }

  /// Invalidate the session associated with [cookieToken] (logout). No-op if
  /// the cookie does not match an active session.
  void revoke(String? cookieToken) {
    if (cookieToken == null || cookieToken.isEmpty) {
      return;
    }
    String? matchedKey;
    for (final entry in _sessions.entries) {
      if (constantTimeCompareStrings(entry.key, cookieToken)) {
        matchedKey = entry.key;
      }
    }
    if (matchedKey != null) {
      _sessions.remove(matchedKey);
    }
  }

  /// Visible for diagnostics/tests.
  int get activeSessionCount {
    _purgeExpired();
    return _sessions.length;
  }

  /// Extract the [cookieName] cookie value from a `Cookie:` header. Returns
  /// `null` if the cookie is absent or the header is malformed.
  ///
  /// Why hand-rolled: shelf does not parse cookies, and we deliberately
  /// avoid pulling in `dart:io` `Cookie` here so this stays testable in
  /// isolation. The grammar we accept is the standard `name=value; name2=v2`
  /// pair form — values with `=` inside are not used by the dashboard so we
  /// split on the first `=` only.
  static String? extractCookie(
    String? cookieHeader, {
    String name = cookieName,
  }) {
    if (cookieHeader == null || cookieHeader.isEmpty) {
      return null;
    }
    for (final raw in cookieHeader.split(';')) {
      final pair = raw.trim();
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final key = pair.substring(0, eq).trim();
      if (key != name) continue;
      final value = pair.substring(eq + 1).trim();
      return value;
    }
    return null;
  }

  /// Build the `Set-Cookie` header value for an issued session cookie.
  ///
  /// Why `SameSite=Strict`: blocks the cookie on every cross-site navigation,
  /// not just on top-level form posts. The dashboard is always loaded from
  /// the same origin as the API, so Strict is safe.
  ///
  /// Why `Path=/api`: limits the cookie to API requests. The static
  /// `/dashboard/*` files do not need it, and scoping reduces accidental
  /// transmission to unrelated routes.
  ///
  /// Why omit `Domain`: defaults to the exact host the dashboard was loaded
  /// from, which is what we want — no inherited subdomain access.
  static String buildSetCookieHeader({
    required String cookieToken,
    required Duration maxAge,
    bool secure = true,
  }) {
    final secureAttr = secure ? '; Secure' : '';
    return '$cookieName=$cookieToken; HttpOnly$secureAttr; '
        'SameSite=Strict; Path=/api; Max-Age=${maxAge.inSeconds}';
  }

  /// Build the `Set-Cookie` header that invalidates the session cookie on the
  /// browser side (paired with [revoke] on the server side).
  static String buildClearCookieHeader({bool secure = true}) {
    final secureAttr = secure ? '; Secure' : '';
    return '$cookieName=; HttpOnly$secureAttr; SameSite=Strict; '
        'Path=/api; Max-Age=0';
  }

  void _purgeExpired() {
    final now = _now();
    _sessions.removeWhere((_, s) => now.isAfter(s.cookieExpiresAt));
  }

  void _evictIfOverCapacity() {
    if (_sessions.length < _maxSessions) {
      return;
    }
    // Oldest session is at the front of the insertion-ordered map. Removing
    // it caps memory while leaving recent active sessions untouched.
    final firstKey = _sessions.keys.first;
    _sessions.remove(firstKey);
  }

  String _randomToken(int byteCount) {
    // Hex encoding keeps the cookie value within the printable ASCII range
    // and avoids characters that would need cookie escaping. byteCount bytes
    // -> byteCount*2 hex chars.
    final buffer = StringBuffer();
    for (var i = 0; i < byteCount; i++) {
      final b = _random.nextInt(256);
      if (b < 16) buffer.write('0');
      buffer.write(b.toRadixString(16));
    }
    return buffer.toString();
  }
}

/// Result of [AuthCookieManager.mint].
class AuthCookieIssue {
  final String cookieToken;
  final String csrfToken;
  final Duration maxAge;

  const AuthCookieIssue({
    required this.cookieToken,
    required this.csrfToken,
    required this.maxAge,
  });
}

class _CookieSession {
  final String bearerToken;
  final String csrfToken;
  final DateTime cookieExpiresAt;
  DateTime csrfExpiresAt;

  _CookieSession({
    required this.bearerToken,
    required this.csrfToken,
    required this.cookieExpiresAt,
    required this.csrfExpiresAt,
  });
}
