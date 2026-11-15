import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nsd/nsd.dart';

import 'discovery.dart';
import 'host_info.dart';
import 'network_uri.dart';
import 'link_version.dart';
import 'tailnet_detector.dart';
import 'wire/routes/system_api.dart';

/// SharedPreferences keys for server persistence.
///
/// The auth-token key has been split: [lastServerAuthToken] is the legacy
/// plaintext SharedPreferences slot we read once on first launch and then
/// purge. The live token now lives in [_secureAuthTokenKey] inside
/// flutter_secure_storage (Keychain on iOS, EncryptedSharedPreferences on
/// Android, libsecret/DPAPI on desktop).
class _DiscoveryPrefs {
  static const lastServerHost = 'skotiq_last_server_host';
  static const lastServerPort = 'skotiq_last_server_port';
  static const lastServerSignalingPort = 'skotiq_last_server_signaling_port';
  static const lastServerName = 'skotiq_last_server_name';
  static const lastServerVersion = 'skotiq_last_server_version';
  static const lastServerMode = 'skotiq_last_server_mode';
  static const lastServerAuthRequired = 'skotiq_last_server_auth_required';
  static const lastServerAuthMode = 'skotiq_last_server_auth_mode';
  static const lastServerPairingSupported =
      'skotiq_last_server_pairing_supported';
  static const lastServerScheme = 'skotiq_last_server_scheme';
  // SHA-256 server fingerprint persisted so the LAN UDP push
  // receiver can derive the same HMAC key as the broadcaster without a
  // round-trip to /api/info. Stored next to host/port — the fingerprint
  // is NOT a secret (it's also embedded in the pairing QR), so plaintext
  // is acceptable.
  static const lastServerFingerprint = 'skotiq_last_server_fingerprint';
  // Legacy plaintext slot. Reads only — never written. Cleared after migration.
  static const lastServerAuthToken = 'skotiq_last_server_auth_token';
  // Set once after the legacy plaintext token has been read into secure
  // storage so we don't keep poking SharedPreferences on every load.
  static const authTokenMigrated = 'skotiq_auth_token_migrated_v1';
}

const String _secureAuthTokenKey = 'skotiq_last_server_auth_token';

const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
  // iOS: token survives reinstall but is bound to passcode/biometrics so a
  // jailbroken or backed-up device cannot exfiltrate it without unlock.
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  ),
  // Android: EncryptedSharedPreferences with hardware-backed keys when
  // available.
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

/// One-shot migration: lift any plaintext token sitting in SharedPreferences
/// into secure storage and wipe the original. Idempotent — guarded by
/// [_DiscoveryPrefs.authTokenMigrated].
Future<void> _migrateAuthTokenIfNeeded(SharedPreferences prefs) async {
  if (prefs.getBool(_DiscoveryPrefs.authTokenMigrated) == true) return;
  final legacy = prefs.getString(_DiscoveryPrefs.lastServerAuthToken);
  if (legacy != null && legacy.isNotEmpty) {
    // Don't clobber an existing secure value — if both somehow exist, the
    // secure one wins (it was the result of an explicit save).
    final existing = await _secureStorage.read(key: _secureAuthTokenKey);
    if (existing == null || existing.isEmpty) {
      await _secureStorage.write(key: _secureAuthTokenKey, value: legacy);
    }
  }
  await prefs.remove(_DiscoveryPrefs.lastServerAuthToken);
  await prefs.setBool(_DiscoveryPrefs.authTokenMigrated, true);
  developer.log(
    'Migrated auth token from SharedPreferences to secure storage',
    name: 'EnhancedDiscovery',
  );
}

/// Service discriminator embedded in every Skotiq pairing QR.
/// Mobile clients reject any payload whose `service` field does not match this
/// constant — the QR scanner must refuse arbitrary JSON-shaped blobs.
const String kQrServiceMarker = 'skotiq';

/// Reasons a QR payload can be rejected. Surfaced to the UI so operators see
/// *why* the scan failed instead of a generic "invalid QR".
enum QrRejectionReason {
  notJson,
  missingService,
  wrongService,
  missingHost,
  invalidHost,
  hostNotLocal,
  missingPort,
  invalidPort,
  missingVersion,
  invalidVersion,
  missingFingerprint,
  invalidFingerprint,
  invalidScheme,
}

class QrValidationException implements Exception {
  final QrRejectionReason reason;
  final String message;
  const QrValidationException(this.reason, this.message);

  @override
  String toString() => 'QrValidationException(${reason.name}): $message';
}

/// QR code connection data format.
///
/// `service`, `host`, `port`, `version`, and `fingerprint` are mandatory and
/// validated by [QrConnectionData.parseStrict]. The remaining fields are
/// optional metadata that survives round-tripping but is not part of the
/// trust-establishment contract.
class QrConnectionData {
  final String service;
  final String host;
  final int webPort;
  final int signalingPort;
  final String version;
  final String fingerprint;
  final String? serverName;
  final String mode;
  final bool authRequired;
  final String authenticationMode;
  final bool pairingSupported;
  final String? authToken;

  /// Optional pairing code embedded in QR for one-scan enrollment.
  final String? pairingCode;

  /// Transport scheme the server speaks — `http` (plain) or `https` (TLS).
  ///
  /// Why this is in the QR payload: a server with TLS enabled rejects plain
  /// HTTP on its HTTPS socket with a `400 Bad Request`, so the first
  /// `GET /api/info` the phone makes after a scan must already target the
  /// right scheme. mDNS carries this in a TXT record, but QR pairing — the
  /// primary Tailscale onboarding path, where the phone is never on the LAN —
  /// has no other channel to learn it. Defaults to `http` for backward
  /// compatibility with pre-2.6 QR payloads that omit the field.
  final String scheme;

  QrConnectionData({
    this.service = kQrServiceMarker,
    required this.host,
    required this.webPort,
    required this.version,
    required this.fingerprint,
    this.signalingPort = 45678,
    this.serverName,
    this.mode = 'desktop',
    this.authRequired = false,
    this.authenticationMode = 'none',
    this.pairingSupported = false,
    this.authToken,
    this.pairingCode,
    this.scheme = 'http',
  });

  /// `true` when the QR advertised a TLS endpoint.
  bool get isTls => scheme == 'https';

  /// Short hash for confirmation UI (first 16 chars of the fingerprint).
  String get shortFingerprint =>
      fingerprint.length <= 16 ? fingerprint : fingerprint.substring(0, 16);

  Map<String, dynamic> toJson() => {
    'service': service,
    'host': host,
    'port': webPort,
    'signalingPort': signalingPort,
    'version': version,
    'fingerprint': fingerprint,
    'scheme': scheme,
    if (serverName != null) 'name': serverName,
    'mode': mode,
    'authRequired': authRequired,
    'authenticationMode': authenticationMode,
    'pairingSupported': pairingSupported,
    if (authToken != null && authToken!.isNotEmpty) 'authToken': authToken,
    if (pairingCode != null && pairingCode!.isNotEmpty)
      'pairingCode': pairingCode,
  };

  String toQrString() => jsonEncode(toJson());

  /// Strict parser. Throws [QrValidationException] on any schema violation —
  /// the audit calls out that lenient parsing was the bug. Callers are
  /// expected to surface the reason to the operator.
  static QrConnectionData parseStrict(String data) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      throw const QrValidationException(
        QrRejectionReason.notJson,
        'QR payload is not valid JSON.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const QrValidationException(
        QrRejectionReason.notJson,
        'QR payload is not a JSON object.',
      );
    }

    final service = decoded['service'];
    if (service == null) {
      throw const QrValidationException(
        QrRejectionReason.missingService,
        'QR payload is missing the "service" discriminator.',
      );
    }
    if (service is! String || service != kQrServiceMarker) {
      throw const QrValidationException(
        QrRejectionReason.wrongService,
        'QR payload is not a Skotiq pairing code.',
      );
    }

    final host = decoded['host'];
    if (host == null) {
      throw const QrValidationException(
        QrRejectionReason.missingHost,
        'QR payload is missing "host".',
      );
    }
    if (host is! String || host.isEmpty) {
      throw const QrValidationException(
        QrRejectionReason.invalidHost,
        'QR payload "host" is not a non-empty string.',
      );
    }
    if (!isLocalNetworkHost(host)) {
      throw QrValidationException(
        QrRejectionReason.hostNotLocal,
        'QR payload "$host" is not on a local/private network.',
      );
    }

    final port = decoded['port'];
    if (port == null) {
      throw const QrValidationException(
        QrRejectionReason.missingPort,
        'QR payload is missing "port".',
      );
    }
    if (port is! int || port <= 0 || port > 65535) {
      throw const QrValidationException(
        QrRejectionReason.invalidPort,
        'QR payload "port" is not a valid TCP port.',
      );
    }

    final version = decoded['version'];
    if (version == null) {
      throw const QrValidationException(
        QrRejectionReason.missingVersion,
        'QR payload is missing "version".',
      );
    }
    if (version is! String || version.isEmpty) {
      throw const QrValidationException(
        QrRejectionReason.invalidVersion,
        'QR payload "version" is not a non-empty string.',
      );
    }

    final fingerprint = decoded['fingerprint'];
    if (fingerprint == null) {
      throw const QrValidationException(
        QrRejectionReason.missingFingerprint,
        'QR payload is missing "fingerprint".',
      );
    }
    if (fingerprint is! String || fingerprint.length < 8) {
      throw const QrValidationException(
        QrRejectionReason.invalidFingerprint,
        'QR payload "fingerprint" is not at least 8 characters.',
      );
    }

    final signalingPort = decoded['signalingPort'];
    final int parsedSignalingPort;
    if (signalingPort == null) {
      parsedSignalingPort = 45678;
    } else if (signalingPort is int &&
        signalingPort > 0 &&
        signalingPort <= 65535) {
      parsedSignalingPort = signalingPort;
    } else {
      throw const QrValidationException(
        QrRejectionReason.invalidPort,
        'QR payload "signalingPort" is not a valid TCP port.',
      );
    }

    // Scheme is optional for backward compatibility with pre-2.6 payloads, but
    // when present it MUST be `http` or `https` — a bogus scheme would route
    // the first /api/info request to a protocol the server cannot answer, so
    // we surface it as a hard rejection rather than silently defaulting.
    final rawScheme = decoded['scheme'];
    final String parsedScheme;
    if (rawScheme == null) {
      parsedScheme = 'http';
    } else if (rawScheme is String &&
        (rawScheme.toLowerCase() == 'http' ||
            rawScheme.toLowerCase() == 'https')) {
      parsedScheme = rawScheme.toLowerCase();
    } else {
      throw const QrValidationException(
        QrRejectionReason.invalidScheme,
        'QR payload "scheme" is not "http" or "https".',
      );
    }

    return QrConnectionData(
      service: service,
      host: host,
      webPort: port,
      signalingPort: parsedSignalingPort,
      version: version,
      fingerprint: fingerprint,
      scheme: parsedScheme,
      serverName: decoded['name'] is String ? decoded['name'] as String : null,
      mode: decoded['mode'] is String ? decoded['mode'] as String : 'desktop',
      authRequired: decoded['authRequired'] is bool
          ? decoded['authRequired'] as bool
          : false,
      authenticationMode: decoded['authenticationMode'] is String
          ? decoded['authenticationMode'] as String
          : 'none',
      pairingSupported: decoded['pairingSupported'] is bool
          ? decoded['pairingSupported'] as bool
          : false,
      authToken: decoded['authToken'] is String
          ? decoded['authToken'] as String
          : null,
      pairingCode: decoded['pairingCode'] is String
          ? decoded['pairingCode'] as String
          : null,
    );
  }

  DiscoveredServer toDiscoveredServer() => DiscoveredServer(
    host: host,
    webPort: webPort,
    signalingPort: signalingPort,
    name: serverName ?? 'Skotiq',
    version: version,
    mode: mode,
    authRequired: authRequired,
    authenticationMode: authenticationMode,
    pairingSupported: pairingSupported,
    authToken: authToken,
    fingerprint: fingerprint,
    scheme: scheme,
  );
}

/// Returns `true` iff [host] is in an RFC1918 / RFC6598 CGNAT / link-local /
/// loopback / IPv6 link-local / IPv6 unique-local range, or is an `.local`
/// mDNS name. Public-Internet hosts in a pairing QR almost certainly mean the
/// QR was tampered with.
///
/// Tailscale CGNAT addresses (100.64.0.0/10) and IPv6 ULA addresses (fc00::/7)
/// are accepted: a remote observatory exposed over Tailscale never puts the
/// phone on the same LAN as the rig. 100.0.0.0/8 is NOT accepted wholesale —
/// that would let a crafted QR point at any of the 16M public hosts in the /10
/// before the CGNAT block starts.
bool isLocalNetworkHost(String host) => TailnetDetector.isAccepted(host);

/// Decode a TXT-record value into a UTF-8 string.
///
/// The `nsd` package surfaces TXT values as `Uint8List?` because mDNS
/// permits raw binary, but our advertisement spec (see [MdnsServiceRegistration])
/// only uses printable UTF-8. Older platform-interface versions might also
/// emit a plain `String` via `toString()`, so we normalise both shapes here.
/// Returns null for empty values so callers can treat "key present, value
/// blank" the same as "key absent".
String? _decodeTxtValue(Object? raw) {
  if (raw == null) return null;
  if (raw is List<int>) {
    if (raw.isEmpty) return null;
    try {
      return utf8.decode(raw);
    } on FormatException {
      // Why: a non-UTF8 TXT value can't be ours, but it can come from a
      // foreign `_skotiq._tcp` registration colliding on the LAN. Treat
      // as missing rather than throwing — the caller falls back to defaults.
      return null;
    }
  }
  final asString = raw.toString();
  return asString.isEmpty ? null : asString;
}

String _normalizeTransportScheme(Object? raw, {String fallback = 'http'}) {
  if (raw is! String) return fallback;
  final lowered = raw.toLowerCase();
  return (lowered == 'http' || lowered == 'https') ? lowered : fallback;
}

typedef DiscoveryStatusCallback = void Function(String status);

/// A discovered or entered server after it was asked who it is.
class ServerRead {
  const ServerRead(this.server, this.problem);

  /// The server with what its `/api/info` said merged in; as it was given
  /// when no Skotiq host answered.
  final DiscoveredServer server;

  /// Why this device cannot link to it, or null when it can.
  final LinkProblem? problem;
}

/// Why a server probe succeeded or failed.
///
/// Reachable and authorised are different answers. A Skotiq host drops
/// every paired token when it restarts, so the commonest failure is a perfectly
/// reachable host rejecting a stale token; reported as "Could not reach
/// `<host>`" it sends the operator to debug their network instead of pairing
/// again.
enum ServerProbeOutcome {
  /// Answered, compatible, and accepted the credential (or needs none).
  reachable,

  /// Answered, but rejected the credential (HTTP 401/403). The host is UP.
  authRejected,

  /// Answered, but runs another Skotiq release ([LinkVersion]).
  incompatible,

  /// No usable answer: refused, DNS failure, timeout, TLS error, 5xx.
  unreachable,
}

class EnhancedSkotiqDiscovery {
  /// Save successful connection for future reconnects.
  ///
  /// Host/port/version metadata stays in SharedPreferences — none of it is
  /// secret and reading it on the cold path doesn't need a Keychain unlock.
  /// The bearer token is written exclusively to secure storage.
  static Future<void> saveLastServer(DiscoveredServer server) async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateAuthTokenIfNeeded(prefs);
    await prefs.setString(_DiscoveryPrefs.lastServerHost, server.host);
    await prefs.setInt(_DiscoveryPrefs.lastServerPort, server.webPort);
    await prefs.setInt(
      _DiscoveryPrefs.lastServerSignalingPort,
      server.signalingPort,
    );
    await prefs.setString(_DiscoveryPrefs.lastServerName, server.name);
    final version = server.version;
    if (version != null) {
      await prefs.setString(_DiscoveryPrefs.lastServerVersion, version);
    } else {
      await prefs.remove(_DiscoveryPrefs.lastServerVersion);
    }
    await prefs.setString(_DiscoveryPrefs.lastServerMode, server.mode);
    await prefs.setBool(
      _DiscoveryPrefs.lastServerAuthRequired,
      server.authRequired,
    );
    await prefs.setString(
      _DiscoveryPrefs.lastServerAuthMode,
      server.authenticationMode,
    );
    await prefs.setBool(
      _DiscoveryPrefs.lastServerPairingSupported,
      server.pairingSupported,
    );
    await prefs.setString(_DiscoveryPrefs.lastServerScheme, server.scheme);
    final fp = server.fingerprint;
    if (fp != null && fp.isNotEmpty) {
      await prefs.setString(_DiscoveryPrefs.lastServerFingerprint, fp);
    } else {
      await prefs.remove(_DiscoveryPrefs.lastServerFingerprint);
    }
    if (server.authToken != null && server.authToken!.isNotEmpty) {
      await _secureStorage.write(
        key: _secureAuthTokenKey,
        value: server.authToken,
      );
    } else {
      await _secureStorage.delete(key: _secureAuthTokenKey);
    }
    developer.log(
      'Saved server: ${server.name} at ${server.host}',
      name: 'EnhancedDiscovery',
    );
  }

  /// Load last server from preferences. Migrates the auth token out of
  /// plaintext SharedPreferences on first call.
  static Future<DiscoveredServer?> loadLastServer() async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateAuthTokenIfNeeded(prefs);
    final host = prefs.getString(_DiscoveryPrefs.lastServerHost);
    final port = prefs.getInt(_DiscoveryPrefs.lastServerPort);

    if (host == null || port == null) {
      return null;
    }

    final authToken = await _secureStorage.read(key: _secureAuthTokenKey);

    return DiscoveredServer(
      host: host,
      webPort: port,
      signalingPort:
          prefs.getInt(_DiscoveryPrefs.lastServerSignalingPort) ?? 45678,
      name: prefs.getString(_DiscoveryPrefs.lastServerName) ?? 'Skotiq',
      version: prefs.getString(_DiscoveryPrefs.lastServerVersion),
      mode: prefs.getString(_DiscoveryPrefs.lastServerMode) ?? 'desktop',
      authRequired:
          prefs.getBool(_DiscoveryPrefs.lastServerAuthRequired) ?? false,
      authenticationMode:
          prefs.getString(_DiscoveryPrefs.lastServerAuthMode) ?? 'none',
      pairingSupported:
          prefs.getBool(_DiscoveryPrefs.lastServerPairingSupported) ?? false,
      authToken: (authToken != null && authToken.isNotEmpty) ? authToken : null,
      fingerprint: prefs.getString(_DiscoveryPrefs.lastServerFingerprint),
      scheme: _normalizeTransportScheme(
        prefs.getString(_DiscoveryPrefs.lastServerScheme),
      ),
    );
  }

  /// Clear saved server (and wipe the secure-storage token).
  static Future<void> clearLastServer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_DiscoveryPrefs.lastServerHost);
    await prefs.remove(_DiscoveryPrefs.lastServerPort);
    await prefs.remove(_DiscoveryPrefs.lastServerSignalingPort);
    await prefs.remove(_DiscoveryPrefs.lastServerName);
    await prefs.remove(_DiscoveryPrefs.lastServerVersion);
    await prefs.remove(_DiscoveryPrefs.lastServerMode);
    await prefs.remove(_DiscoveryPrefs.lastServerAuthRequired);
    await prefs.remove(_DiscoveryPrefs.lastServerAuthMode);
    await prefs.remove(_DiscoveryPrefs.lastServerPairingSupported);
    await prefs.remove(_DiscoveryPrefs.lastServerScheme);
    await prefs.remove(_DiscoveryPrefs.lastServerFingerprint);
    // Legacy slot — should already be empty post-migration but flush anyway
    // in case the user wiped storage out from under us.
    await prefs.remove(_DiscoveryPrefs.lastServerAuthToken);
    await _secureStorage.delete(key: _secureAuthTokenKey);
    developer.log('Cleared saved server', name: 'EnhancedDiscovery');
  }

  static Map<String, String> _authHeaders(String? authToken) {
    final headers = {LinkVersion.header: skotiqRelease};
    if (authToken == null || authToken.isEmpty) {
      return headers;
    }
    return {...headers, 'Authorization': 'Bearer $authToken'};
  }

  static DiscoveredServer _mergeServerInfo(
    DiscoveredServer seed,
    Map<String, dynamic> info,
  ) {
    return seed.copyWith(
      name: info['name'] as String? ?? seed.name,
      version: info['version'] as String? ?? seed.version,
      mode: info['mode'] as String? ?? seed.mode,
      authRequired: info['authRequired'] as bool? ?? seed.authRequired,
      authenticationMode:
          info['authenticationMode'] as String? ?? seed.authenticationMode,
      pairingSupported:
          info['pairingSupported'] as bool? ?? seed.pairingSupported,
      fingerprint: info['fingerprint'] as String? ?? seed.fingerprint,
      lanPairing: info['lanPairing'] as bool? ?? seed.lanPairing,
      scheme: _normalizeTransportScheme(info['scheme'], fallback: seed.scheme),
      // /api/info now advertises the rig's tailnet address and relay
      // appliance id when those uplinks are up. Carry them through so the
      // connect path can persist them into the saved-server row and the
      // Tailscale/relay setup sheets prefill them on the next reconnect.
      tailscaleHost: info['tailscaleHost'] as String? ?? seed.tailscaleHost,
      relayApplianceId:
          info['relayApplianceId'] as String? ?? seed.relayApplianceId,
      hostName: _nonEmpty(info['hostName']) ?? seed.hostName,
      platform: _nonEmpty(info['platform']) ?? seed.platform,
      hostMode: _nonEmpty(info['hostMode']) ?? seed.hostMode,
    );
  }

  static String? _nonEmpty(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  /// Merge a parsed `/api/info` body into [seed]. Public for the desktop
  /// discovery, which fetches the info itself so it can keep the fingerprint
  /// it pins.
  static DiscoveredServer mergeServerInfo(
    DiscoveredServer seed,
    Map<String, dynamic> info,
  ) => _mergeServerInfo(seed, info);

  /// Ask [server] who it is (`GET /api/info`) and merge the answer. The
  /// result says why this device cannot link to it, if it cannot
  /// ([ServerRead.problem]): no answer, refused, not a Skotiq host, or another
  /// release. The request follows the server's scheme, because a TLS-only
  /// host answers plain HTTP with a 400.
  static Future<ServerRead> readServer(
    DiscoveredServer server, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final read = await readHostInfo(
      scheme: server.scheme,
      host: server.host,
      port: server.webPort,
      headers: _authHeaders(server.authToken),
      timeout: timeout,
    );
    switch (read) {
      case HostInfoAnswer(:final info):
        return ServerRead(_mergeServerInfo(server, info), read.problem);
      case HostInfoFailure(:final problem):
        developer.log(
          'No Skotiq host at ${server.host}:${server.webPort}: '
          '${problem.kind.name}',
          name: 'EnhancedDiscovery',
          level: 900,
        );
        return ServerRead(server, problem);
    }
  }

  /// `401`/`403` both mean "I heard you, your credential is not good" — the
  /// host is up. A Skotiq host answers 401 with no credential and 403 with
  /// a stale one; neither is an unreachable host.
  static bool _isAuthRejection(int statusCode) =>
      statusCode == 401 || statusCode == 403;

  /// Test if a server is reachable.
  ///
  /// Thin `bool` wrapper over [probeServer], kept for the many callers that
  /// only need a yes/no. Prefer [probeServer] anywhere the answer is shown to
  /// a human: collapsing "the host refused my credential" into `false` makes
  /// the UI report an unreachable host and sends the operator off to debug
  /// their network instead of re-pairing.
  ///
  /// [scheme] selects the transport — `http` (default) or `https`. A
  /// TLS-enabled server (the typical Tailscale remote-observatory setup)
  /// answers only on `https`; probing it over plain `http` returns a
  /// `400 Bad Request` and the host wrongly reads as unreachable. Callers that
  /// learned the scheme from a QR payload or mDNS TXT record pass it through
  /// here so the probe lands on the right protocol. Invalid scheme values are
  /// rejected rather than silently coerced — an unexpected scheme is a caller
  /// bug, not something to paper over.
  static Future<bool> testServerConnection(
    String host,
    int port, {
    String? authToken,
    String scheme = 'http',
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final outcome = await probeServer(
      host,
      port,
      authToken: authToken,
      scheme: scheme,
      timeout: timeout,
    );
    return outcome == ServerProbeOutcome.reachable;
  }

  /// Reachability probe that preserves WHY the probe failed.
  ///
  /// The distinction that matters in the UI is reachable-but-rejected versus
  /// genuinely-unreachable. A Skotiq host invalidates every paired token
  /// when it restarts, so the single most common failure an operator hits is a
  /// live, pingable host answering 401/403 to a stale token — which must be
  /// reported as "pair again", not "could not reach".
  static Future<ServerProbeOutcome> probeServer(
    String host,
    int port, {
    String? authToken,
    String scheme = 'http',
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final lowered = scheme.toLowerCase();
    if (lowered != 'http' && lowered != 'https') {
      throw ArgumentError.value(scheme, 'scheme', 'must be "http" or "https"');
    }
    try {
      final read = await readHostInfo(
        scheme: lowered,
        host: host,
        port: port,
        headers: _authHeaders(authToken),
        timeout: timeout,
      );
      if (read is! HostInfoAnswer) {
        final status = (read as HostInfoFailure).httpStatus;
        return status != null && _isAuthRejection(status)
            ? ServerProbeOutcome.authRejected
            : ServerProbeOutcome.unreachable;
      }
      if (read.problem != null) return ServerProbeOutcome.incompatible;
      final info = read.info;

      final authRequired = info['authRequired'] as bool? ?? false;
      if (!authRequired) {
        return ServerProbeOutcome.reachable;
      }

      if (authToken == null || authToken.isEmpty) {
        // Host is up; mobile will pair via /api/pairing/* before connecting.
        final pairingSupported = info['pairingSupported'] as bool? ?? false;
        return pairingSupported
            ? ServerProbeOutcome.reachable
            : ServerProbeOutcome.unreachable;
      }

      final statusResponse = await http
          .get(
            buildSkotiqServerUri(
              scheme: lowered,
              host: host,
              port: port,
              pathAndQuery: SystemApi.status.route.path,
            ),
            headers: _authHeaders(authToken),
          )
          .timeout(timeout);

      if (_isAuthRejection(statusResponse.statusCode)) {
        return ServerProbeOutcome.authRejected;
      }
      return statusResponse.statusCode == 200
          ? ServerProbeOutcome.reachable
          : ServerProbeOutcome.unreachable;
    } catch (e, stackTrace) {
      // Why: reachability probe — any exception (connection refused, DNS
      // failure, timeout, TLS error) is by definition "not reachable" and
      // the caller treats it accordingly. Log so an operator chasing
      // "why doesn't my server show up" can see the actual cause.
      developer.log(
        'probeServer failed for $host:$port: $e\n$stackTrace',
        name: 'EnhancedDiscovery',
        level: 900,
      );
      return ServerProbeOutcome.unreachable;
    }
  }

  /// The discovered host to offer: one this device can link to when there is
  /// one, otherwise the first that answered, so the connect flow can say
  /// which release it runs and which side to update.
  static Future<DiscoveredServer?> firstLinkableServer(
    List<DiscoveredServer> servers,
  ) async {
    DiscoveredServer? other;
    for (final server in servers) {
      final read = await readServer(server);
      if (read.problem == null) return read.server;
      if (read.problem!.kind == LinkProblemKind.mismatch) {
        other ??= read.server;
      }
    }
    return other;
  }

  /// Try to reconnect to last saved server
  static Future<DiscoveredServer?> tryLastServer({
    Duration timeout = const Duration(seconds: 2),
    DiscoveryStatusCallback? onStatus,
  }) async {
    onStatus?.call('Checking last server...');
    final server = await loadLastServer();
    if (server == null) {
      developer.log('No saved server found', name: 'EnhancedDiscovery');
      return null;
    }

    developer.log(
      'Testing saved server: ${server.host}:${server.webPort}',
      name: 'EnhancedDiscovery',
    );
    final isReachable = await testServerConnection(
      server.host,
      server.webPort,
      authToken: server.authToken,
      scheme: server.scheme,
      timeout: timeout,
    );

    if (isReachable) {
      developer.log('Saved server is reachable', name: 'EnhancedDiscovery');
      return (await readServer(server, timeout: timeout)).server;
    }

    developer.log('Saved server not reachable', name: 'EnhancedDiscovery');
    return null;
  }

  /// Discover via mDNS/Bonjour (platform-dependent)
  /// Uses the nsd package for cross-platform mDNS service discovery
  static Future<List<DiscoveredServer>> discoverViaMdns({
    Duration timeout = const Duration(seconds: 10),
    DiscoveryStatusCallback? onStatus,
  }) async {
    onStatus?.call('Searching via Bonjour...');
    developer.log('mDNS discovery starting...', name: 'EnhancedDiscovery');

    final List<DiscoveredServer> servers = [];

    Discovery? discovery;
    Timer? timeoutTimer;

    try {
      discovery = await startDiscovery('_skotiq._tcp');

      // Collect discovered services
      final completer = Completer<List<DiscoveredServer>>();

      discovery.addServiceListener((service, status) async {
        if (status == ServiceStatus.found) {
          try {
            // Resolve the service to get host and port
            final resolvedService = await resolve(service);

            if (resolvedService.host != null && resolvedService.port != null) {
              final host = resolvedService.host!;
              final port = resolvedService.port!;

              // Parse service name and TXT records for metadata.
              //
              // The server registers `_skotiq._tcp` with a full TXT
              // record set (version, scheme, fingerprint, pairingSupported,
              // name). Parsing the extra keys here means a Tailscale / locked-
              // down-Wi-Fi client connecting via mDNS-only (no QR, no UDP
              // broadcast) lands on the right scheme and can cross-check the
              // fingerprint against a previously-saved value before sending
              // its bearer token.
              String serverName = resolvedService.name ?? 'Skotiq';
              String version = '2.0.0';
              int signalingPort = 45678;
              String scheme = 'http';
              String? fingerprint;
              bool pairingSupported = false;

              final txtRecords = resolvedService.txt;
              if (txtRecords != null && txtRecords.isNotEmpty) {
                for (final record in txtRecords.entries) {
                  final key = record.key;
                  final rawValue = record.value;
                  final value = _decodeTxtValue(rawValue);
                  if (value == null) continue;

                  switch (key) {
                    case 'version':
                      version = value;
                      break;
                    case 'name':
                      serverName = value;
                      break;
                    case 'signaling_port':
                      signalingPort = int.tryParse(value) ?? signalingPort;
                      break;
                    case 'scheme':
                      final lowered = value.toLowerCase();
                      if (lowered == 'http' || lowered == 'https') {
                        scheme = lowered;
                      }
                      break;
                    case 'fingerprint':
                      if (value.isNotEmpty) {
                        fingerprint = value;
                      }
                      break;
                    case 'pairingSupported':
                      pairingSupported =
                          value.toLowerCase() == 'true' || value == '1';
                      break;
                  }
                }
              }

              final server = DiscoveredServer(
                host: host,
                webPort: port,
                signalingPort: signalingPort,
                name: serverName,
                version: version,
                scheme: scheme,
                fingerprint: fingerprint,
                pairingSupported: pairingSupported,
              );

              // Avoid duplicates
              if (!servers.any(
                (s) => s.host == server.host && s.webPort == server.webPort,
              )) {
                servers.add((await readServer(server)).server);
              }
            }
          } catch (e, stackTrace) {
            // Why: a single service-resolution failure during mDNS discovery
            // must not abort the whole sweep — another service in the same
            // broadcast may still resolve cleanly. Log at fine level so a
            // systemic Bonjour failure is visible in the dev console.
            developer.log(
              'mDNS service resolution failed; skipping: $e\n$stackTrace',
              name: 'EnhancedDiscovery',
              level: 500,
            );
          }
        }
      });

      timeoutTimer = Timer(timeout, () {
        if (!completer.isCompleted) {
          completer.complete(servers);
        }
      });

      // Wait for timeout
      await completer.future;

      return servers;
    } catch (e) {
      // mDNS discovery can fail on platforms without Bonjour support
      return servers;
    } finally {
      timeoutTimer?.cancel();
      if (discovery != null) {
        try {
          await stopDiscovery(discovery);
        } catch (e, stackTrace) {
          // Why: cleanup in a finally block — the discovery sweep already
          // completed (or timed out); failing to close the mDNS handle is
          // non-fatal but should not propagate and mask the real outcome.
          // Log so a leaking handle pattern would be visible.
          developer.log(
            'stopDiscovery cleanup failed: $e\n$stackTrace',
            name: 'EnhancedDiscovery',
            level: 500,
          );
        }
      }
    }
  }

  static Future<List<DiscoveredServer>> discoverViaUdp({
    Duration timeout = const Duration(seconds: 3),
    DiscoveryStatusCallback? onStatus,
  }) async {
    onStatus?.call('Searching via network broadcast...');
    return SkotiqDiscovery.discoverServers(timeout: timeout);
  }

  /// Parse QR code data into connection info.
  ///
  /// Returns the validated [QrConnectionData] (NOT a [DiscoveredServer]) so
  /// callers can show a confirmation sheet with host + fingerprint *before*
  /// any network call. Throws [QrValidationException] on schema violation.
  static QrConnectionData parseQrCodeStrict(String qrData) =>
      QrConnectionData.parseStrict(qrData);

  /// Full discovery flow with cascading fallbacks
  /// Order: Last server (2s) → mDNS (3s) → UDP broadcast (3s) → null
  static Future<DiscoveredServer?> discoverWithFallback({
    DiscoveryStatusCallback? onStatus,
  }) async {
    developer.log('Starting cascading discovery...', name: 'EnhancedDiscovery');

    // 1. Try last saved server (2s timeout)
    onStatus?.call('Reconnecting to last server...');
    final lastServer = await tryLastServer(
      timeout: const Duration(seconds: 2),
      onStatus: onStatus,
    );
    if (lastServer != null) {
      developer.log('Connected via saved server', name: 'EnhancedDiscovery');
      return lastServer;
    }

    // 2. Try mDNS discovery (3s timeout)
    onStatus?.call('Searching via Bonjour...');
    final mdnsServers = await discoverViaMdns(
      timeout: const Duration(seconds: 3),
      onStatus: onStatus,
    );
    if (mdnsServers.isNotEmpty) {
      developer.log('Found server via mDNS', name: 'EnhancedDiscovery');
      return firstLinkableServer(mdnsServers);
    }

    // 3. Fall back to UDP broadcast (3s timeout)
    onStatus?.call('Searching via network broadcast...');
    final udpServers = await discoverViaUdp(
      timeout: const Duration(seconds: 3),
      onStatus: onStatus,
    );
    if (udpServers.isNotEmpty) {
      developer.log(
        'Found server via UDP broadcast',
        name: 'EnhancedDiscovery',
      );
      return firstLinkableServer(udpServers);
    }

    // 4. No server found
    developer.log(
      'No server found via any method',
      name: 'EnhancedDiscovery',
      level: 900,
    );
    onStatus?.call('No server found');
    return null;
  }

  /// Generate QR code data string for a server.
  ///
  /// `version` and `fingerprint` are mandatory — the mobile scanner refuses
  /// payloads without them.
  static String generateQrData({
    required String host,
    required int webPort,
    required String version,
    required String fingerprint,
    int signalingPort = 45678,
    String? serverName,
    String mode = 'desktop',
    bool authRequired = false,
    String authenticationMode = 'none',
    bool pairingSupported = false,
    String? authToken,
    String? pairingCode,
    String scheme = 'http',
  }) {
    final lowered = scheme.toLowerCase();
    if (lowered != 'http' && lowered != 'https') {
      throw ArgumentError.value(scheme, 'scheme', 'must be "http" or "https"');
    }
    final data = QrConnectionData(
      host: host,
      webPort: webPort,
      signalingPort: signalingPort,
      version: version,
      fingerprint: fingerprint,
      serverName: serverName,
      mode: mode,
      authRequired: authRequired,
      authenticationMode: authenticationMode,
      pairingSupported: pairingSupported,
      authToken: authToken,
      pairingCode: pairingCode,
      scheme: lowered,
    );
    return data.toQrString();
  }
}
