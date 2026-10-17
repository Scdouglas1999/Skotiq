import '../route_metadata.dart' as route_metadata;

/// CORS allow-list policy for the headless API.
///
/// Explicit allow-list, never origin reflection: echoing the request `Origin`
/// whenever it matches the bound host:port would let a malicious local-loopback
/// app on `http://127.0.0.1:NNNN` script Skotiq through the browser, which
/// sees same-origin and proceeds. By default only the dashboard's own origin is
/// allowed; high-risk control endpoints get a stricter check that omits the
/// CORS header entirely on a disallowed origin, so the browser blocks the
/// request.
class CorsAllowList {
  final Set<String> _allowedOrigins;
  final bool _allowSameOrigin;

  CorsAllowList._(this._allowedOrigins, this._allowSameOrigin);

  factory CorsAllowList.fromConfig({
    required Iterable<String> additionalOrigins,
    bool allowSameOrigin = true,
  }) {
    final normalized = <String>{};
    for (final raw in additionalOrigins) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final parsed = Uri.tryParse(trimmed);
      if (parsed == null || parsed.scheme.isEmpty || parsed.host.isEmpty) {
        continue;
      }
      // Normalise: scheme://host[:port] without trailing slash.
      normalized.add(_canonicalOrigin(parsed));
    }
    return CorsAllowList._(normalized, allowSameOrigin);
  }

  /// Returns the value to set as `Access-Control-Allow-Origin`, or `null` if
  /// the request must be denied (no header set, browser will block).
  ///
  /// [requestOrigin] is the value of the request's `Origin` header.
  /// [requestUri] is the URL the request hit (so we can detect same-origin).
  /// [path] is the URL path; high-risk paths use a stricter rule.
  String? resolve({
    required String? requestOrigin,
    required Uri requestUri,
    required String path,
  }) {
    if (requestOrigin == null || requestOrigin.isEmpty) {
      return null;
    }

    final originUri = Uri.tryParse(requestOrigin);
    if (originUri == null || originUri.scheme.isEmpty) {
      return null;
    }

    final canonical = _canonicalOrigin(originUri);
    final isSameOrigin =
        originUri.scheme == requestUri.scheme &&
        originUri.host.toLowerCase() == requestUri.host.toLowerCase() &&
        originUri.port == requestUri.port;

    final isHighRisk = route_metadata.isHighRiskControlPath(path);
    final inAllowList = _allowedOrigins.contains(canonical);

    if (isHighRisk) {
      // High-risk POSTs must come from an explicitly allow-listed origin OR
      // be same-origin (the dashboard served by this server). Loopback
      // same-origin is still considered "trusted" because the user binds
      // there intentionally; the alternative would break the bundled UI.
      if (inAllowList || (_allowSameOrigin && isSameOrigin)) {
        return requestOrigin;
      }
      return null;
    }

    // Non-high-risk: also restrict to allow-list / same-origin. Drop the
    // legacy "reflect any origin that matches host:port" behaviour that let
    // a different scheme or hijacked host bypass via spoofed Host headers
    // upstream.
    if (inAllowList || (_allowSameOrigin && isSameOrigin)) {
      return requestOrigin;
    }
    return null;
  }

  static String _canonicalOrigin(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '$scheme://$host$port';
  }
}
