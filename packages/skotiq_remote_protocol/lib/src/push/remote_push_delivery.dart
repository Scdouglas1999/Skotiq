// Cellular/remote push delivery for critical notifications (Phase D).
//
// The LAN UDP broadcaster in `lan_push_broadcaster.dart` covers the "phone
// is on the same Wi-Fi as the rig" case. This file covers the OTHER half —
// phone on cellular, hours away from the rig — via an actual cloud push:
// FCM for Android, APNs for iOS.
//
// Critical correctness note. The [PushNotificationFrame] handed to
// [RemotePushDelivery.deliver] has NO target device token — it is the
// LAN-broadcast frame, identical for every phone. FCM/APNs are unicast
// per-device. So each delivery, on every frame, looks up its platform's
// registered tokens (via a [PushTokenStore]) and fans out one HTTP request
// per token. The frame carries the *content*; the delivery owns the
// *recipient list*. Each device's [DevicePushPreferences] are consulted
// before a send so a muted device is skipped.
//
// Auth uses short-lived JWTs minted with PointyCastle (see push_jwt.dart):
//   - FCM: RS256 assertion -> OAuth2 access_token -> messages:send (HTTP/1.1)
//   - APNs: ES256 provider token -> POST /3/device/<token> (HTTP/2)
//
// The concrete [FcmRemotePushDelivery] + [ApnsRemotePushDelivery] senders and
// the [CompositeRemotePushDelivery] fan-out live here. The no-cloud
// [MockRemotePushDelivery] lives in `push_token_store.dart` next to the store
// it records against. Absent config => the caller wires the mock / nothing
// (never crash).

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http2/http2.dart';

import 'lan_push_broadcaster.dart';
import 'push_config.dart';
import 'push_jwt.dart';
import 'push_token_store.dart';

/// Abstract surface for delivering a [PushNotificationFrame] outside
/// the LAN — typically via FCM for Android or APNs for iOS. The
/// headless API server registers an implementation via
/// `HeadlessApiServer.setRemotePushDelivery`; frames that flow through the
/// WebSocket fan-out are additionally handed off here.
///
/// Implementations MUST be safe to call from the headless event loop —
/// they should not block. Use a `Future` for the per-frame work.
///
/// Errors:
///   - Implementations may throw on a misconfigured cloud account
///     (invalid key, expired credential). The headless server catches
///     these per-frame so one bad credential does not kill the
///     broadcaster.
abstract class RemotePushDelivery {
  /// Deliver [frame] to the cellular/remote channel. Implementations
  /// are responsible for matching `frame.severity` to the cloud-push
  /// priority field (FCM `priority`, APNs `apns-priority`).
  Future<void> deliver(PushNotificationFrame frame);

  /// Release any cloud-SDK handles. Idempotent. Called when the
  /// headless server stops.
  Future<void> dispose() async {}
}

// Payload assembly (pure, no network — directly unit-testable)

/// Cloud-push priority derived from a frame's severity.
/// `critical`/`warning` escalate; everything else is normal.
bool _isHighPriority(String severity) =>
    severity == 'critical' || severity == 'warning';

/// Build the FCM HTTP v1 `messages:send` body for one device token.
///
/// `frame.severity == 'critical'`/`'warning'` => `android.priority: 'high'`;
/// otherwise `'normal'`. The `data` block is string-only per the FCM
/// contract, so every value is coerced to a string.
Map<String, Object?> buildFcmMessage(
  PushNotificationFrame frame,
  String deviceToken,
) {
  final data = <String, String>{'id': frame.id, 'severity': frame.severity};
  frame.data.forEach((k, v) {
    if (v != null) data[k] = v.toString();
  });

  final high = _isHighPriority(frame.severity);
  return <String, Object?>{
    'message': <String, Object?>{
      'token': deviceToken,
      'notification': <String, Object?>{
        'title': frame.title,
        'body': frame.body,
      },
      'data': data,
      'android': <String, Object?>{
        'priority': high ? 'high' : 'normal',
        'notification': <String, Object?>{
          'channel_id': 'skotiq_critical',
          'notification_priority': high ? 'PRIORITY_MAX' : 'PRIORITY_DEFAULT',
          'sound': 'default',
        },
      },
    },
  };
}

/// Build the APNs payload body for one device. A `critical` frame requests
/// the critical-alert sound + interruption level (requires the iOS
/// entitlement, see CRITICAL_ALERTS_SETUP.md); lower severities are plain
/// alerts.
Map<String, Object?> buildApnsPayload(PushNotificationFrame frame) {
  final critical = frame.severity == 'critical';
  final aps = <String, Object?>{
    'alert': <String, Object?>{'title': frame.title, 'body': frame.body},
    if (critical)
      'sound': <String, Object?>{
        'critical': 1,
        'name': 'default',
        'volume': 1.0,
      }
    else
      'sound': 'default',
    if (critical) 'interruption-level': 'critical',
  };
  final payload = <String, Object?>{
    'aps': aps,
    'id': frame.id,
    'severity': frame.severity,
  };
  frame.data.forEach((k, v) {
    if (v != null) payload[k] = v;
  });
  return payload;
}

/// `apns-priority` header value: `10` for critical, `5` otherwise.
String apnsPriorityFor(String severity) => severity == 'critical' ? '10' : '5';

/// Optional capability a [PushTokenStore] may also implement so a delivery can
/// prune a token the cloud reported dead (FCM 404/UNREGISTERED, APNs 410). The
/// desktop's `PairingDatabase`-backed store implements it; the in-memory store
/// used in tests may too. Stores that don't implement it simply keep the
/// (now-dead) token until the device re-registers.
abstract class StalePushTokenSink {
  /// Drop [token] (the cloud rejected it as no longer valid). Idempotent.
  Future<void> removeStaleToken(String token);
}

Future<void> _pruneIfStale(PushTokenStore store, String token) async {
  if (store is StalePushTokenSink) {
    await (store as StalePushTokenSink).removeStaleToken(token);
  }
}

/// Clamp a cloud error body to keep the log line readable.
String _truncateBody(String body, [int max = 200]) =>
    body.length <= max ? body : '${body.substring(0, max)}…';

// FCM (Android) — HTTP v1

/// Parsed Firebase service-account JSON (the bits the sender needs).
class FcmServiceAccount {
  final String projectId;
  final String clientEmail;
  final String privateKeyPem;
  final String tokenUri;

  const FcmServiceAccount({
    required this.projectId,
    required this.clientEmail,
    required this.privateKeyPem,
    required this.tokenUri,
  });

  factory FcmServiceAccount.fromJson(Map<String, Object?> json) {
    final projectId = json['project_id'];
    final clientEmail = json['client_email'];
    final privateKey = json['private_key'];
    if (projectId is! String || projectId.isEmpty) {
      throw const FormatException('service account: missing project_id');
    }
    if (clientEmail is! String || clientEmail.isEmpty) {
      throw const FormatException('service account: missing client_email');
    }
    if (privateKey is! String || privateKey.isEmpty) {
      throw const FormatException('service account: missing private_key');
    }
    final tokenUri = json['token_uri'];
    return FcmServiceAccount(
      projectId: projectId,
      clientEmail: clientEmail,
      privateKeyPem: privateKey,
      tokenUri: tokenUri is String && tokenUri.isNotEmpty
          ? tokenUri
          : 'https://oauth2.googleapis.com/token',
    );
  }

  factory FcmServiceAccount.fromJsonString(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('service account: not a JSON object');
    }
    return FcmServiceAccount.fromJson(decoded);
  }
}

const String _fcmScope = 'https://www.googleapis.com/auth/firebase.messaging';

/// Mint the RS256 OAuth2 assertion JWT used to exchange the service account
/// for an access token. Exposed for testing the JWT shape.
String buildFcmAssertionJwt(
  FcmServiceAccount account, {
  DateTime? now,
  Duration ttl = const Duration(hours: 1),
}) {
  final issued = (now ?? DateTime.now()).toUtc();
  final iat = issued.millisecondsSinceEpoch ~/ 1000;
  final exp = iat + ttl.inSeconds;
  return signRs256Jwt(
    privateKeyPem: account.privateKeyPem,
    claims: <String, Object?>{
      'iss': account.clientEmail,
      'sub': account.clientEmail,
      'aud': account.tokenUri,
      'scope': _fcmScope,
      'iat': iat,
      'exp': exp,
    },
  );
}

/// FCM Cloud Messaging HTTP v1 delivery.
///
/// On each [deliver] it: refreshes a cached OAuth2 access token if needed,
/// then POSTs one `messages:send` request per registered Android token.
/// A `404 NOT_FOUND` / `UNREGISTERED` response prunes the stale token from
/// the [PushTokenSource]. A `400 INVALID_ARGUMENT` is deliberately NOT
/// pruned: 400 signals a malformed *payload*, not a dead token, and dropping
/// the recipient on a payload bug would silently and permanently delete a
/// live device from the safety-alert fan-out.
class FcmRemotePushDelivery implements RemotePushDelivery {
  final FcmServiceAccount account;
  final PushTokenStore store;
  final http.Client _http;
  final bool _ownsClient;
  final Duration timeout;

  String? _accessToken;
  DateTime? _accessTokenExpiry;

  FcmRemotePushDelivery({
    required this.account,
    required this.store,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 15),
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// Construct from a [FcmPushConfig] by reading the service-account JSON.
  factory FcmRemotePushDelivery.fromConfig(
    FcmPushConfig config,
    PushTokenStore store, {
    http.Client? httpClient,
  }) {
    final raw = File(config.serviceAccountPath).readAsStringSync();
    return FcmRemotePushDelivery(
      account: FcmServiceAccount.fromJsonString(raw),
      store: store,
      httpClient: httpClient,
    );
  }

  Uri get _sendUri => Uri.parse(
    'https://fcm.googleapis.com/v1/projects/${account.projectId}/messages:send',
  );

  Future<String> _ensureAccessToken({DateTime? now}) async {
    final clock = (now ?? DateTime.now()).toUtc();
    final cached = _accessToken;
    final expiry = _accessTokenExpiry;
    if (cached != null &&
        expiry != null &&
        clock.isBefore(expiry.subtract(const Duration(minutes: 5)))) {
      return cached;
    }
    final assertion = buildFcmAssertionJwt(account, now: clock);
    final resp = await _http
        .post(
          Uri.parse(account.tokenUri),
          headers: const {'content-type': 'application/x-www-form-urlencoded'},
          body: {
            'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
            'assertion': assertion,
          },
        )
        .timeout(timeout);
    if (resp.statusCode != 200) {
      throw StateError(
        'FCM token exchange failed: ${resp.statusCode} '
        '${_truncateBody(resp.body)}',
      );
    }
    final body = jsonDecode(resp.body) as Map<String, Object?>;
    final token = body['access_token'];
    if (token is! String || token.isEmpty) {
      throw StateError('FCM token exchange: no access_token in response');
    }
    final expiresRaw = body['expires_in'];
    final expiresIn = expiresRaw == null
        ? 3600
        : expiresRaw is num &&
              expiresRaw.isFinite &&
              expiresRaw > 0 &&
              expiresRaw.truncateToDouble() == expiresRaw.toDouble()
        ? expiresRaw.toInt()
        : throw StateError('FCM token exchange: invalid expires_in');
    _accessToken = token;
    _accessTokenExpiry = clock.add(Duration(seconds: expiresIn));
    return token;
  }

  @override
  Future<void> deliver(PushNotificationFrame frame) async {
    final tokens = await store.tokensForPlatform('fcm');
    if (tokens.isEmpty) return;
    final accessToken = await _ensureAccessToken();
    // The per-device mute gate keys on the per-event `eventType`
    // (NotificationCategory.storageKey, e.g. 'weatherUnsafe'), NOT the coarse
    // EventCategory in frame.data['category'] ('safety', …).
    final eventType = frame.data['eventType']?.toString();

    var attempted = 0;
    var failed = 0;
    for (final device in tokens) {
      var attemptCounted = false;
      var failureCounted = false;
      try {
        final prefs = await store.preferencesFor(device.deviceId);
        if (!prefs.allows(eventType)) continue;

        attempted++;
        attemptCounted = true;
        final body = jsonEncode(buildFcmMessage(frame, device.token));
        final resp = await _http
            .post(
              _sendUri,
              headers: {
                'authorization': 'Bearer $accessToken',
                'content-type': 'application/json',
              },
              body: body,
            )
            .timeout(timeout);
        if (resp.statusCode >= 200 && resp.statusCode < 300) continue;

        failed++;
        failureCounted = true;
        developer.log(
          'FCM send failed for ${device.deviceId}: ${resp.statusCode} '
          '${_truncateBody(resp.body)}',
          name: 'FcmRemotePushDelivery',
          level: 1000,
        );
        if (resp.statusCode == 404) {
          // NOT_FOUND / UNREGISTERED => the token is genuinely dead; prune it.
          // 400 remains registered because it usually signals a payload bug.
          await _pruneIfStale(store, device.token);
        }
      } catch (error, stackTrace) {
        // One bad recipient or network request must not prevent later devices
        // from receiving a safety alert.
        if (!attemptCounted) attempted++;
        if (!failureCounted) failed++;
        developer.log(
          'FCM send threw for ${device.deviceId}: $error',
          name: 'FcmRemotePushDelivery',
          level: 1000,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    if (attempted > 0 && failed == attempted) {
      throw StateError(
        'FCM delivery failed: all $attempted '
        'send${attempted == 1 ? '' : 's'} errored',
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_ownsClient) _http.close();
  }
}

// APNs (iOS) — token auth over HTTP/2

/// Opens an HTTP/2 connection to an APNs host and POSTs a single request.
/// Abstracted so tests can capture the assembled request without a real
/// TLS/HTTP/2 connection to Apple.
abstract class ApnsHttp2Transport {
  /// POST [body] to `/3/device/<deviceToken>` with [headers] and return the
  /// HTTP `:status`. [headers] are the APNs request headers (authorization,
  /// apns-topic, apns-priority, apns-push-type, apns-id).
  Future<int> post({
    required String deviceToken,
    required Map<String, String> headers,
    required List<int> body,
  });

  Future<void> close();
}

/// Real HTTP/2 transport over a TLS SecureSocket negotiating ALPN `h2`.
/// One connection is reused across many tokens; it reconnects lazily if the
/// previous connection closed (idle / GOAWAY).
class SecureSocketApnsTransport implements ApnsHttp2Transport {
  final String host;
  final int port;

  ClientTransportConnection? _conn;
  Socket? _socket;

  SecureSocketApnsTransport({required this.host, this.port = 443});

  Future<ClientTransportConnection> _connection() async {
    final existing = _conn;
    if (existing != null && existing.isOpen) return existing;
    final socket = await SecureSocket.connect(
      host,
      port,
      supportedProtocols: const ['h2'],
    );
    final conn = ClientTransportConnection.viaSocket(socket);
    _socket = socket;
    _conn = conn;
    return conn;
  }

  @override
  Future<int> post({
    required String deviceToken,
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    final conn = await _connection();
    final h2Headers = <Header>[
      Header.ascii(':method', 'POST'),
      Header.ascii(':scheme', 'https'),
      Header.ascii(':authority', host),
      Header.ascii(':path', '/3/device/$deviceToken'),
      for (final entry in headers.entries) Header.ascii(entry.key, entry.value),
    ];
    final stream = conn.makeRequest(h2Headers);
    stream.outgoingMessages.add(DataStreamMessage(body));
    await stream.outgoingMessages.close();

    var status = 0;
    await for (final message in stream.incomingMessages) {
      if (message is HeadersStreamMessage) {
        for (final header in message.headers) {
          if (ascii.decode(header.name) == ':status') {
            status = int.tryParse(ascii.decode(header.value)) ?? status;
          }
        }
      }
    }
    return status;
  }

  @override
  Future<void> close() async {
    final conn = _conn;
    _conn = null;
    if (conn != null) {
      try {
        await conn.finish();
      } catch (_) {
        /* best effort */
      }
    }
    try {
      await _socket?.close();
    } catch (_) {
      /* best effort */
    }
    _socket = null;
  }
}

/// Apple Push Notification service delivery (token-based auth, HTTP/2).
///
/// On each [deliver] it mints/reuses an ES256 provider JWT, then POSTs one
/// request per registered APNs token. A `410 Gone` prunes the stale token
/// from the [PushTokenSource]. A `400` is NOT pruned: APNs reuses 400 for
/// several payload/config faults (DeviceTokenNotForTopic, BadCertificate-
/// Environment, PayloadEmpty, …) that are not dead-recipient conditions, so
/// pruning on 400 would silently drop live devices from the safety fan-out.
class ApnsRemotePushDelivery implements RemotePushDelivery {
  final ApnsPushConfig config;
  final String privateKeyPem;
  final PushTokenStore store;
  final ApnsHttp2Transport _transport;
  final Duration timeout;

  /// Apple rejects provider tokens older than 1h; refresh well before that.
  static const Duration _jwtTtl = Duration(minutes: 40);

  String? _jwt;
  DateTime? _jwtIssuedAt;

  ApnsRemotePushDelivery({
    required this.config,
    required this.privateKeyPem,
    required this.store,
    ApnsHttp2Transport? transport,
    this.timeout = const Duration(seconds: 15),
  }) : _transport =
           transport ??
           SecureSocketApnsTransport(
             host: config.useSandbox
                 ? 'api.sandbox.push.apple.com'
                 : 'api.push.apple.com',
           );

  /// Construct from an [ApnsPushConfig] by reading the `.p8` key file.
  factory ApnsRemotePushDelivery.fromConfig(
    ApnsPushConfig config,
    PushTokenStore store, {
    ApnsHttp2Transport? transport,
  }) {
    final pem = File(config.p8KeyPath).readAsStringSync();
    return ApnsRemotePushDelivery(
      config: config,
      privateKeyPem: pem,
      store: store,
      transport: transport,
    );
  }

  /// Mint (or reuse) the ES256 provider JWT. Exposed for testing the shape.
  String providerToken({DateTime? now}) {
    final clock = (now ?? DateTime.now()).toUtc();
    final cached = _jwt;
    final issued = _jwtIssuedAt;
    if (cached != null &&
        issued != null &&
        clock.difference(issued) < _jwtTtl) {
      return cached;
    }
    final iat = clock.millisecondsSinceEpoch ~/ 1000;
    final jwt = signEs256Jwt(
      privateKeyPem: privateKeyPem,
      keyId: config.keyId,
      claims: <String, Object?>{'iss': config.teamId, 'iat': iat},
    );
    _jwt = jwt;
    _jwtIssuedAt = clock;
    return jwt;
  }

  @override
  Future<void> deliver(PushNotificationFrame frame) async {
    final tokens = await store.tokensForPlatform('apns');
    if (tokens.isEmpty) return;
    final jwt = providerToken();
    // The per-device mute gate keys on the per-event `eventType`
    // (NotificationCategory.storageKey, e.g. 'weatherUnsafe'), NOT the coarse
    // EventCategory in frame.data['category'] ('safety', …).
    final eventType = frame.data['eventType']?.toString();
    final body = utf8.encode(jsonEncode(buildApnsPayload(frame)));

    var attempted = 0;
    var failed = 0;
    for (final device in tokens) {
      var attemptCounted = false;
      var failureCounted = false;
      try {
        final prefs = await store.preferencesFor(device.deviceId);
        if (!prefs.allows(eventType)) continue;

        attempted++;
        attemptCounted = true;
        final status = await _transport
            .post(
              deviceToken: device.token,
              headers: <String, String>{
                'authorization': 'bearer $jwt',
                'apns-topic': config.bundleId,
                'apns-push-type': 'alert',
                'apns-priority': apnsPriorityFor(frame.severity),
                'apns-id': frame.id,
              },
              body: body,
            )
            .timeout(timeout);
        if (status >= 200 && status < 300) continue;

        failed++;
        failureCounted = true;
        developer.log(
          'APNs send failed for ${device.deviceId}: status $status',
          name: 'ApnsRemotePushDelivery',
          level: 1000,
        );
        if (status == 410) {
          // Gone is genuinely unregistered. A 400 remains registered because
          // APNs also uses it for payload and environment faults.
          await _pruneIfStale(store, device.token);
        }
      } catch (error, stackTrace) {
        if (!attemptCounted) attempted++;
        if (!failureCounted) failed++;
        developer.log(
          'APNs send threw for ${device.deviceId}: $error',
          name: 'ApnsRemotePushDelivery',
          level: 1000,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    if (attempted > 0 && failed == attempted) {
      throw StateError(
        'APNs delivery failed: all $attempted '
        'send${attempted == 1 ? '' : 's'} errored',
      );
    }
  }

  @override
  Future<void> dispose() async {
    await _transport.close();
  }
}

// Composite — runs FCM + APNs (+ mock) side by side.
//
// The no-cloud [MockRemotePushDelivery] lives in `push_token_store.dart`,
// next to the [PushTokenStore] it records (frame, recipient) pairs against.

/// Fan-out delivery that forwards each frame to every wrapped
/// implementation. Lets an operator run FCM + APNs in parallel — one
/// instance per platform, both registered on the same server.
class CompositeRemotePushDelivery implements RemotePushDelivery {
  final List<RemotePushDelivery> deliveries;

  CompositeRemotePushDelivery(this.deliveries);

  @override
  Future<void> deliver(PushNotificationFrame frame) async {
    final failures = <Object>[];
    final futures = <Future<void>>[];
    for (final d in deliveries) {
      futures.add(
        d.deliver(frame).catchError((Object error) {
          failures.add(error);
        }),
      );
    }
    await Future.wait(futures);
    if (failures.isNotEmpty) {
      throw StateError(
        '${failures.length} of ${deliveries.length} remote push delivery '
        'channel${deliveries.length == 1 ? '' : 's'} failed: '
        '${failures.join('; ')}',
      );
    }
  }

  @override
  Future<void> dispose() async {
    for (final d in deliveries) {
      try {
        await d.dispose();
      } catch (_) {
        // dispose() errors are not actionable at the composite level;
        // each delivery is responsible for its own clean shutdown.
      }
    }
  }
}

/// Build the cellular-push delivery for a parsed [PushConfig] and [store].
/// Returns `null` when no channel is configured AND the mock is off (the
/// caller then leaves remote delivery unset so LAN + WS push keep working).
/// When `config.mock` is set (and no cloud channel) a [MockRemotePushDelivery]
/// is returned for cloudless dev.
///
/// Constructed senders read their secret files eagerly; a malformed secret
/// surfaces here rather than on the first frame.
RemotePushDelivery? buildRemotePushDelivery(
  PushConfig config,
  PushTokenStore store, {
  http.Client? httpClient,
}) {
  final deliveries = <RemotePushDelivery>[
    if (config.fcm.enabled)
      FcmRemotePushDelivery.fromConfig(
        config.fcm,
        store,
        httpClient: httpClient,
      ),
    if (config.apns.enabled)
      ApnsRemotePushDelivery.fromConfig(config.apns, store),
  ];
  if (deliveries.isEmpty) {
    return config.mock ? MockRemotePushDelivery(store: store) : null;
  }
  if (deliveries.length == 1) return deliveries.single;
  return CompositeRemotePushDelivery(deliveries);
}
