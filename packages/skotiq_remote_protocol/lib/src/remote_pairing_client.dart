import 'dart:convert';

import 'package:http/http.dart' as http;

import 'server_compatibility.dart';
import 'network_uri.dart';

/// Result of `POST /api/pairing/start`.
class RemotePairingStartResult {
  final DateTime expiresAt;
  final int expiresInSeconds;

  const RemotePairingStartResult({
    required this.expiresAt,
    required this.expiresInSeconds,
  });

  factory RemotePairingStartResult.fromJson(Map<String, dynamic> json) {
    final expiresAtRaw = json['expiresAt'] as String?;
    final expiresAt = expiresAtRaw != null
        ? DateTime.parse(expiresAtRaw).toUtc()
        : DateTime.now().toUtc().add(const Duration(minutes: 5));
    return RemotePairingStartResult(
      expiresAt: expiresAt,
      expiresInSeconds:
          json['expiresInSeconds'] as int? ??
          expiresAt.difference(DateTime.now().toUtc()).inSeconds,
    );
  }
}

/// Result of `POST /api/pairing/verify`.
class RemotePairingVerifyResult {
  final bool success;
  final String? token;
  final String? tokenScope;
  final DateTime? expiresAt;
  final String? error;
  final String? message;
  final int? statusCode;

  const RemotePairingVerifyResult({
    required this.success,
    this.token,
    this.tokenScope,
    this.expiresAt,
    this.error,
    this.message,
    this.statusCode,
  });

  factory RemotePairingVerifyResult.successFromJson(Map<String, dynamic> json) {
    final expiresAtRaw = json['expiresAt'] as String?;
    return RemotePairingVerifyResult(
      success: true,
      token: json['token'] as String?,
      tokenScope: json['tokenScope'] as String?,
      expiresAt: expiresAtRaw != null ? DateTime.parse(expiresAtRaw) : null,
    );
  }

  factory RemotePairingVerifyResult.failure({
    required int statusCode,
    required Map<String, dynamic> body,
  }) {
    return RemotePairingVerifyResult(
      success: false,
      statusCode: statusCode,
      error: body['error'] as String?,
      message: body['message'] as String? ?? body['error'] as String?,
    );
  }
}

/// HTTP client for the headless pairing endpoints (`/api/pairing/*`).
///
/// Pairing codes are entered by the operator on the desktop (or embedded in a
/// QR payload). The six-digit dashboard flow and the `WORD-WORD-NNNN` GUI flow
/// share the same Drift-backed session table via [TokenManager].
///
/// ## Scheme
///
/// [scheme] selects `http` (default) or `https`. The Tailscale remote-
/// observatory topology normally runs TLS, in which case the server answers
/// pairing requests only on `https` — speaking plain `http` to it returns a
/// `400 Bad Request`. The scheme the phone learned from the QR payload
/// ([QrConnectionData.scheme]) or mDNS TXT record flows through here.
///
/// ## Fingerprint pinning
///
/// When [pinnedFingerprint] is supplied, [verify] first fetches
/// `GET /api/info` and refuses to send the pairing code unless the server's
/// reported `fingerprint` matches the pin. This closes a MITM window that
/// matters specifically on the Tailscale / Internet-reachable path, where the
/// phone is no longer protected by being on the same trusted LAN segment as
/// the rig: a hostile node that intercepts the connection could otherwise
/// present its own pairing UI, harvest the code the operator reads off the
/// real desktop, and mint itself a scoped token. The pin is the fingerprint
/// the operator already verified out-of-band (it travels in the QR and is
/// shown on the desktop remote-access screen), so checking it before handing
/// over the code makes impersonation detectable.
class RemotePairingClient {
  final String host;
  final int port;
  final String scheme;
  final Duration timeout;

  /// SHA-256 server fingerprint the caller trusts. When non-null, [verify]
  /// performs a pre-flight `/api/info` check and throws
  /// [RemotePairingFingerprintMismatch] if the live server reports a different
  /// fingerprint. Null disables pinning (LAN flows that established trust by
  /// other means).
  final String? pinnedFingerprint;

  RemotePairingClient({
    required this.host,
    required this.port,
    this.scheme = 'http',
    this.pinnedFingerprint,
    this.timeout = const Duration(seconds: 15),
  }) : assert(
         scheme == 'http' || scheme == 'https',
         'scheme must be "http" or "https"',
       );

  Uri _uri(String path) => buildSkotiqServerUri(
    scheme: scheme,
    host: host,
    port: port,
    pathAndQuery: path,
  );

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    SkotiqServerCompatibility.apiVersionHeader:
        SkotiqServerCompatibility.clientApiVersion.format(),
  };

  /// Opens a pairing session on the desktop host. The pairing code itself is
  /// shown on the desktop UI / QR — it is intentionally omitted from the HTTP
  /// body so passive network observers cannot harvest it.
  Future<RemotePairingStartResult> start() async {
    final response = await http
        .post(_uri('/api/pairing/start'), headers: _headers)
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw RemotePairingException(
        'Pairing start failed (${response.statusCode}): ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return RemotePairingStartResult.fromJson(decoded);
  }

  /// Fetches the server's advertised SHA-256 fingerprint from `/api/info`.
  ///
  /// Returns null when the server does not report one (older servers, or a
  /// reachability blip). Throws [RemotePairingException] on a non-200 / non
  /// JSON response so a genuinely broken endpoint is not mistaken for "no
  /// fingerprint".
  Future<String?> fetchFingerprint() async {
    final response = await http
        .get(_uri('/api/info'), headers: _headers)
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw RemotePairingException(
        'Fingerprint pre-flight failed (${response.statusCode}): '
        '${response.body}',
      );
    }
    final dynamic decoded = response.body.isNotEmpty
        ? jsonDecode(response.body)
        : <String, dynamic>{};
    if (decoded is! Map<String, dynamic>) {
      throw const RemotePairingException(
        'Fingerprint pre-flight returned a non-object body.',
      );
    }
    final fingerprint = decoded['fingerprint'];
    if (fingerprint is String && fingerprint.isNotEmpty) {
      return fingerprint;
    }
    return null;
  }

  /// Runs the pinning pre-flight when [pinnedFingerprint] is set.
  ///
  /// Throws [RemotePairingFingerprintMismatch] if the server's live
  /// fingerprint differs from the pin, or if pinning is requested but the
  /// server reports no fingerprint at all — fail closed: we will not hand a
  /// pairing code to a host we cannot positively identify.
  Future<void> _enforcePinning() async {
    final pin = pinnedFingerprint;
    if (pin == null || pin.isEmpty) return;
    final live = await fetchFingerprint();
    if (live == null) {
      throw RemotePairingFingerprintMismatch(expected: pin, actual: null);
    }
    // Constant-time-ish comparison is unnecessary here (the fingerprint is not
    // secret — it travels in the QR), but a case-insensitive exact match keeps
    // hex-casing differences from causing false mismatches.
    if (live.toLowerCase() != pin.toLowerCase()) {
      throw RemotePairingFingerprintMismatch(expected: pin, actual: live);
    }
  }

  /// Claims a pairing code and returns a scoped bearer token.
  ///
  /// [requestedScope] defaults to `control`. Pass `admin` only when the
  /// operator explicitly opts in on the mobile/tablet UI.
  ///
  /// When [pinnedFingerprint] is set, the server identity is verified before
  /// the code is transmitted (see class docs). A mismatch throws
  /// [RemotePairingFingerprintMismatch] and the code is never sent.
  Future<RemotePairingVerifyResult> verify({
    required String code,
    required String deviceId,
    required String deviceName,
    String deviceType = 'mobile',
    String requestedScope = 'control',
  }) async {
    await _enforcePinning();

    final response = await http
        .post(
          _uri('/api/pairing/verify'),
          headers: _headers,
          body: jsonEncode({
            'code': code.trim(),
            'deviceId': deviceId,
            'deviceName': deviceName,
            'deviceType': deviceType,
            'requestedScope': requestedScope,
          }),
        )
        .timeout(timeout);

    final dynamic decoded = response.body.isNotEmpty
        ? jsonDecode(response.body)
        : <String, dynamic>{};
    final body = decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{};

    if (response.statusCode == 200) {
      return RemotePairingVerifyResult.successFromJson(body);
    }

    return RemotePairingVerifyResult.failure(
      statusCode: response.statusCode,
      body: body,
    );
  }

  /// Attempts one-tap LAN pairing via `POST /api/pairing/lan-claim`.
  ///
  /// Returns a success result (with a token) when the appliance grants it — no
  /// code needed because the request came from the same private LAN. Returns
  /// `null` when one-tap pairing is unavailable for this connection (the server
  /// is in `code-required` mode, or we reached it over tailnet/relay/Internet so
  /// the source isn't a trusted LAN address) — the caller should fall back to
  /// the code flow. Throws only on transport/unexpected errors.
  ///
  /// Honours [pinnedFingerprint] the same way [verify] does: if a pin is set we
  /// confirm the server identity before trusting its token.
  Future<RemotePairingVerifyResult?> lanClaim({
    required String deviceId,
    required String deviceName,
    String deviceType = 'mobile',
  }) async {
    await _enforcePinning();

    final response = await http
        .post(
          _uri('/api/pairing/lan-claim'),
          headers: _headers,
          body: jsonEncode({
            'deviceId': deviceId,
            'deviceName': deviceName,
            'deviceType': deviceType,
          }),
        )
        .timeout(timeout);

    final dynamic decoded = response.body.isNotEmpty
        ? jsonDecode(response.body)
        : <String, dynamic>{};
    final body = decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{};

    if (response.statusCode == 200) {
      return RemotePairingVerifyResult.successFromJson(body);
    }
    // 403 (not on the LAN / mode disabled) and 404 (older server without the
    // endpoint) are the expected "fall back to a code" signals — not errors.
    if (response.statusCode == 403 || response.statusCode == 404) {
      return null;
    }
    if (response.statusCode == 429) {
      // Rate-limited: surface as a failure so the caller can show the message.
      return RemotePairingVerifyResult.failure(
        statusCode: response.statusCode,
        body: body,
      );
    }
    throw RemotePairingException(
      'LAN pairing failed (${response.statusCode}): ${response.body}',
    );
  }
}

class RemotePairingException implements Exception {
  final String message;
  const RemotePairingException(this.message);

  @override
  String toString() => 'RemotePairingException: $message';
}

/// Thrown by [RemotePairingClient.verify] when the server's live fingerprint
/// does not match the pinned value. [actual] is null when the server reported
/// no fingerprint at all (also a fail-closed rejection).
class RemotePairingFingerprintMismatch extends RemotePairingException {
  final String expected;
  final String? actual;

  RemotePairingFingerprintMismatch({
    required this.expected,
    required this.actual,
  }) : super(
         actual == null
             ? 'Server reported no fingerprint; expected '
                   '${_short(expected)}. Refusing to pair.'
             : 'Server fingerprint ${_short(actual)} does not match the '
                   'pinned ${_short(expected)}. Refusing to pair.',
       );

  static String _short(String fp) => fp.length <= 16 ? fp : fp.substring(0, 16);
}
