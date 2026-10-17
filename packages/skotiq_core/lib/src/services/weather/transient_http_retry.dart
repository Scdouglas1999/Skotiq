import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// GET [uri] on [client], retrying transient failures with a short backoff.
///
/// Retried failures: 5xx responses, dropped sockets, TLS handshakes cut
/// mid-flight, client-level connection errors, and per-attempt timeouts.
/// Open-Meteo publishes a single API host that degrades under load by
/// answering 502 or killing TLS handshakes outright (observed 2026-06-11,
/// ~1-in-4 requests succeeding); a short retry pass turns most of those
/// blips into successes without masking real outages.
///
/// Semantics preserved for callers:
///   * a non-5xx response (including 4xx) returns immediately — client
///     errors are not transient;
///   * a 5xx on the FINAL attempt is returned, not thrown, so callers keep
///     handling status codes exactly as before;
///   * a network-level error on the final attempt rethrows.
///
/// [backoff] is injectable so tests can run with zero delay.
///
/// [headers] are forwarded to every attempt's `client.get`. Some providers
/// (e.g. MET Norway) reject requests without an identifying User-Agent, so the
/// header must survive each retry. Defaults to null to leave existing callers
/// (Open-Meteo) byte-for-byte unchanged.
Future<http.Response> getWithTransientRetry(
  http.Client client,
  Uri uri, {
  int maxAttempts = 3,
  Duration perAttemptTimeout = const Duration(seconds: 12),
  Duration Function(int attempt)? backoff,
  Map<String, String>? headers,
}) async {
  assert(maxAttempts >= 1);
  final delayFor =
      backoff ?? (attempt) => Duration(milliseconds: 500 * attempt);

  Object? lastError;
  StackTrace? lastStack;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      final response = await client
          .get(uri, headers: headers)
          .timeout(perAttemptTimeout);
      if (response.statusCode < 500 || attempt == maxAttempts) {
        return response;
      }
      lastError = null;
    } on SocketException catch (e, s) {
      lastError = e;
      lastStack = s;
    } on TlsException catch (e, s) {
      // Covers HandshakeException (TLS cut mid-handshake).
      lastError = e;
      lastStack = s;
    } on http.ClientException catch (e, s) {
      lastError = e;
      lastStack = s;
    } on TimeoutException catch (e, s) {
      lastError = e;
      lastStack = s;
    }
    if (attempt == maxAttempts) break;
    await Future<void>.delayed(delayFor(attempt));
  }

  // Only reachable when the final attempt threw a transient error.
  Error.throwWithStackTrace(lastError!, lastStack ?? StackTrace.current);
}
