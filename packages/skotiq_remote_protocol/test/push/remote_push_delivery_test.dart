// Phase D cellular-push delivery tests. No real network: the FCM sender runs
// against an http MockClient and the APNs sender against a fake HTTP/2
// transport, so the OAuth2 exchange, payload assembly, per-device fan-out,
// preference gating and stale-token pruning are all asserted offline.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import 'fixtures/test_keys.dart';

/// Built exactly as `event_forwarding._buildPushFrameFromNotification` does:
/// `eventType` is the per-event `NotificationCategory.storageKey` (the enum
/// name, e.g. `weatherUnsafe`) and `category` is the coarse `EventCategory.name`
/// (`safety`). The mute gate keys on `eventType`, so a realistic fixture must
/// carry the storageKey value there.
PushNotificationFrame _frame({
  String severity = 'critical',
  String eventType = 'weatherUnsafe',
  String category = 'safety',
}) {
  return PushNotificationFrame(
    id: '11111111-2222-3333-4444-555555555555',
    severity: severity,
    title: 'Weather Unsafe',
    body: 'Safety monitor reports unsafe conditions; the mount was parked.',
    data: <String, Object?>{'eventType': eventType, 'category': category},
    timestamp: DateTime.utc(2026, 6, 8, 3, 30),
    serverFingerprint: 'fp-abc',
  );
}

/// In-memory store that ALSO records stale-token removals so the senders'
/// 404/410 cleanup path can be asserted.
class _RecordingStore implements PushTokenStore, StalePushTokenSink {
  final List<RegisteredPushToken> tokens;
  final Map<String, DevicePushPreferences> prefs;
  final List<String> removed = <String>[];

  _RecordingStore({required this.tokens, this.prefs = const {}});

  @override
  Future<List<RegisteredPushToken>> tokensForPlatform(String platform) async =>
      tokens.where((t) => t.platform == platform).toList();

  @override
  Future<DevicePushPreferences> preferencesFor(String deviceId) async =>
      prefs[deviceId] ?? DevicePushPreferences.allEnabled;

  @override
  Future<void> removeStaleToken(String token) async {
    removed.add(token);
    tokens.removeWhere((t) => t.token == token);
  }
}

class _CapturedApnsRequest {
  final String deviceToken;
  final Map<String, String> headers;
  final Map<String, Object?> body;
  _CapturedApnsRequest(this.deviceToken, this.headers, this.body);
}

/// Fake APNs transport: captures every request and returns a scripted status.
class _FakeApnsTransport implements ApnsHttp2Transport {
  final int Function(String deviceToken) statusFor;
  final List<_CapturedApnsRequest> requests = <_CapturedApnsRequest>[];
  bool closed = false;

  _FakeApnsTransport({int Function(String deviceToken)? statusFor})
    : statusFor = statusFor ?? ((_) => 200);

  @override
  Future<int> post({
    required String deviceToken,
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    requests.add(
      _CapturedApnsRequest(
        deviceToken,
        headers,
        jsonDecode(utf8.decode(body)) as Map<String, Object?>,
      ),
    );
    return statusFor(deviceToken);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  group('FCM payload assembly', () {
    test('critical frame => high priority, string-coerced data', () {
      final msg =
          buildFcmMessage(_frame(), 'DEVTOKEN1')['message']!
              as Map<String, Object?>;
      expect(msg['token'], 'DEVTOKEN1');
      final notif = msg['notification']! as Map<String, Object?>;
      expect(notif['title'], 'Weather Unsafe');

      final android = msg['android']! as Map<String, Object?>;
      expect(android['priority'], 'high');
      final androidNotif = android['notification']! as Map<String, Object?>;
      expect(androidNotif['channel_id'], 'skotiq_critical');
      expect(androidNotif['notification_priority'], 'PRIORITY_MAX');

      final data = msg['data']! as Map<String, Object?>;
      expect(data['id'], '11111111-2222-3333-4444-555555555555');
      expect(data['severity'], 'critical');
      expect(data['eventType'], 'weatherUnsafe');
      expect(data['category'], 'safety');
      // FCM data values must be strings.
      for (final v in data.values) {
        expect(v, isA<String>());
      }
    });

    test('info frame => normal priority', () {
      final msg =
          buildFcmMessage(_frame(severity: 'info'), 'T')['message']!
              as Map<String, Object?>;
      final android = msg['android']! as Map<String, Object?>;
      expect(android['priority'], 'normal');
    });
  });

  group('APNs payload assembly', () {
    test('critical => critical sound + interruption-level, priority 10', () {
      final payload = buildApnsPayload(_frame());
      final aps = payload['aps']! as Map<String, Object?>;
      final sound = aps['sound']! as Map<String, Object?>;
      expect(sound['critical'], 1);
      expect(sound['volume'], 1.0);
      expect(aps['interruption-level'], 'critical');
      expect((aps['alert']! as Map)['title'], 'Weather Unsafe');
      expect(payload['id'], '11111111-2222-3333-4444-555555555555');
      expect(payload['eventType'], 'weatherUnsafe');
      expect(payload['category'], 'safety');
      expect(apnsPriorityFor('critical'), '10');
    });

    test('warning => plain sound, no critical fields, priority 5', () {
      final payload = buildApnsPayload(_frame(severity: 'warning'));
      final aps = payload['aps']! as Map<String, Object?>;
      expect(aps['sound'], 'default');
      expect(aps.containsKey('interruption-level'), isFalse);
      expect(apnsPriorityFor('warning'), '5');
    });
  });

  group('FcmRemotePushDelivery (MockClient, no network)', () {
    test(
      'exchanges a token then POSTs once per registered fcm token',
      () async {
        const account = FcmServiceAccount(
          projectId: 'demo-proj',
          clientEmail: 'svc@demo-proj.iam.gserviceaccount.com',
          privateKeyPem: fcmTestPrivateKeyPem,
          tokenUri: 'https://oauth2.googleapis.com/token',
        );
        final store = _RecordingStore(
          tokens: [
            const RegisteredPushToken(
              deviceId: 'phone-a',
              platform: 'fcm',
              token: 'TOK_A',
            ),
            const RegisteredPushToken(
              deviceId: 'phone-b',
              platform: 'fcm',
              token: 'TOK_B',
            ),
            // An APNs token must be ignored by the FCM sender.
            const RegisteredPushToken(
              deviceId: 'phone-c',
              platform: 'apns',
              token: 'IGNORED',
            ),
          ],
        );

        final sends = <Map<String, Object?>>[];
        var tokenExchanges = 0;
        final client = MockClient((req) async {
          if (req.url.toString() == account.tokenUri) {
            tokenExchanges++;
            expect(
              req.bodyFields['grant_type'],
              'urn:ietf:params:oauth:grant-type:jwt-bearer',
            );
            expect(req.bodyFields['assertion'], isNotEmpty);
            return http.Response(
              jsonEncode({'access_token': 'ya29.fake', 'expires_in': 3600}),
              200,
            );
          }
          expect(
            req.url.toString(),
            'https://fcm.googleapis.com/v1/projects/demo-proj/messages:send',
          );
          expect(req.headers['authorization'], 'Bearer ya29.fake');
          sends.add(jsonDecode(req.body) as Map<String, Object?>);
          return http.Response('{}', 200);
        });

        final delivery = FcmRemotePushDelivery(
          account: account,
          store: store,
          httpClient: client,
        );

        await delivery.deliver(_frame());
        // Two fcm tokens => two sends; one token exchange.
        expect(sends, hasLength(2));
        expect(tokenExchanges, 1);
        final sentTokens = sends
            .map((s) => (s['message']! as Map)['token'])
            .toList();
        expect(sentTokens, containsAll(<String>['TOK_A', 'TOK_B']));

        // Second deliver reuses the cached access token (no new exchange).
        await delivery.deliver(_frame());
        expect(tokenExchanges, 1);
        await delivery.dispose();
      },
    );

    test('404 prunes the stale fcm token', () async {
      const account = FcmServiceAccount(
        projectId: 'p',
        clientEmail: 'svc@p.iam.gserviceaccount.com',
        privateKeyPem: fcmTestPrivateKeyPem,
        tokenUri: 'https://oauth2.googleapis.com/token',
      );
      final store = _RecordingStore(
        tokens: [
          const RegisteredPushToken(
            deviceId: 'd',
            platform: 'fcm',
            token: 'DEAD',
          ),
        ],
      );
      final client = MockClient((req) async {
        if (req.url.toString() == account.tokenUri) {
          return http.Response(
            jsonEncode({'access_token': 't', 'expires_in': 3600}),
            200,
          );
        }
        return http.Response('{"error":{"status":"UNREGISTERED"}}', 404);
      });

      final delivery = FcmRemotePushDelivery(
        account: account,
        store: store,
        httpClient: client,
      );
      await expectLater(delivery.deliver(_frame()), throwsStateError);

      expect(store.removed, ['DEAD']);
    });

    test(
      '400 INVALID_ARGUMENT does NOT prune (payload bug, not a dead token)',
      () async {
        const account = FcmServiceAccount(
          projectId: 'p',
          clientEmail: 'svc@p.iam.gserviceaccount.com',
          privateKeyPem: fcmTestPrivateKeyPem,
          tokenUri: 'https://oauth2.googleapis.com/token',
        );
        final store = _RecordingStore(
          tokens: [
            const RegisteredPushToken(
              deviceId: 'd',
              platform: 'fcm',
              token: 'LIVE',
            ),
          ],
        );
        final client = MockClient((req) async {
          if (req.url.toString() == account.tokenUri) {
            return http.Response(
              jsonEncode({'access_token': 't', 'expires_in': 3600}),
              200,
            );
          }
          // A malformed payload is a 400 INVALID_ARGUMENT — a code bug, not a
          // dead recipient. The token MUST survive so the live device keeps
          // receiving safety alerts once the payload is fixed.
          return http.Response('{"error":{"status":"INVALID_ARGUMENT"}}', 400);
        });

        final delivery = FcmRemotePushDelivery(
          account: account,
          store: store,
          httpClient: client,
        );
        await expectLater(delivery.deliver(_frame()), throwsStateError);

        expect(
          store.removed,
          isEmpty,
          reason: 'a 400 must not prune a live token',
        );
        expect(store.tokens.map((t) => t.token), ['LIVE']);
      },
    );

    test('muted device is skipped (no send)', () async {
      const account = FcmServiceAccount(
        projectId: 'p',
        clientEmail: 'svc@p.iam.gserviceaccount.com',
        privateKeyPem: fcmTestPrivateKeyPem,
        tokenUri: 'https://oauth2.googleapis.com/token',
      );
      final store = _RecordingStore(
        tokens: [
          const RegisteredPushToken(
            deviceId: 'muted',
            platform: 'fcm',
            token: 'TOK',
          ),
        ],
        prefs: {'muted': const DevicePushPreferences(muteWeatherUnsafe: true)},
      );
      var sends = 0;
      final client = MockClient((req) async {
        if (req.url.toString() == account.tokenUri) {
          return http.Response(
            jsonEncode({'access_token': 't', 'expires_in': 3600}),
            200,
          );
        }
        sends++;
        return http.Response('{}', 200);
      });

      await FcmRemotePushDelivery(
        account: account,
        store: store,
        httpClient: client,
      ).deliver(_frame(eventType: 'weatherUnsafe'));

      expect(sends, 0);
    });

    test('one throwing recipient does not block later recipients', () async {
      const account = FcmServiceAccount(
        projectId: 'p',
        clientEmail: 'svc@p.iam.gserviceaccount.com',
        privateKeyPem: fcmTestPrivateKeyPem,
        tokenUri: 'https://oauth2.googleapis.com/token',
      );
      final store = _RecordingStore(
        tokens: [
          const RegisteredPushToken(
            deviceId: 'bad',
            platform: 'fcm',
            token: 'BAD',
          ),
          const RegisteredPushToken(
            deviceId: 'good',
            platform: 'fcm',
            token: 'GOOD',
          ),
        ],
      );
      final attemptedTokens = <String>[];
      final client = MockClient((request) async {
        if (request.url.toString() == account.tokenUri) {
          return http.Response(
            jsonEncode({'access_token': 't', 'expires_in': 3600}),
            200,
          );
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final token =
            (body['message'] as Map<String, dynamic>)['token'] as String;
        attemptedTokens.add(token);
        if (token == 'BAD') throw StateError('socket reset');
        return http.Response('{}', 200);
      });

      await FcmRemotePushDelivery(
        account: account,
        store: store,
        httpClient: client,
      ).deliver(_frame());

      expect(attemptedTokens, ['BAD', 'GOOD']);
    });
  });

  group('ApnsRemotePushDelivery (fake transport, no network)', () {
    ApnsPushConfig config() => const ApnsPushConfig(
      enabled: true,
      p8KeyPath: '',
      keyId: 'KID1234567',
      teamId: 'TEAM123456',
      bundleId: 'com.skotiq.app',
      useSandbox: false,
    );

    test('POSTs one request per apns token with the right headers', () async {
      final transport = _FakeApnsTransport();
      final store = _RecordingStore(
        tokens: [
          const RegisteredPushToken(
            deviceId: 'i1',
            platform: 'apns',
            token: 'HEX_1',
          ),
          const RegisteredPushToken(
            deviceId: 'i2',
            platform: 'apns',
            token: 'HEX_2',
          ),
          const RegisteredPushToken(
            deviceId: 'a1',
            platform: 'fcm',
            token: 'IGNORED',
          ),
        ],
      );

      final delivery = ApnsRemotePushDelivery(
        config: config(),
        privateKeyPem: apnsTestPrivateKeyPem,
        store: store,
        transport: transport,
      );
      await delivery.deliver(_frame());

      expect(transport.requests, hasLength(2));
      final r = transport.requests.first;
      expect(r.headers['apns-topic'], 'com.skotiq.app');
      expect(r.headers['apns-push-type'], 'alert');
      expect(r.headers['apns-priority'], '10'); // critical
      expect(r.headers['apns-id'], '11111111-2222-3333-4444-555555555555');
      expect(r.headers['authorization'], startsWith('bearer '));
      final aps = r.body['aps']! as Map<String, Object?>;
      expect((aps['sound']! as Map)['critical'], 1);

      await delivery.dispose();
      expect(transport.closed, isTrue);
    });

    test('410 prunes the stale apns token', () async {
      final transport = _FakeApnsTransport(
        statusFor: (t) => t == 'GONE' ? 410 : 200,
      );
      final store = _RecordingStore(
        tokens: [
          const RegisteredPushToken(
            deviceId: 'i1',
            platform: 'apns',
            token: 'GONE',
          ),
          const RegisteredPushToken(
            deviceId: 'i2',
            platform: 'apns',
            token: 'LIVE',
          ),
        ],
      );

      final delivery = ApnsRemotePushDelivery(
        config: config(),
        privateKeyPem: apnsTestPrivateKeyPem,
        store: store,
        transport: transport,
      );
      await delivery.deliver(_frame());

      expect(store.removed, ['GONE']);
    });

    test('400 does NOT prune an apns token (payload/config fault)', () async {
      final transport = _FakeApnsTransport(
        statusFor: (t) => t == 'BAD' ? 400 : 200,
      );
      final store = _RecordingStore(
        tokens: [
          const RegisteredPushToken(
            deviceId: 'i1',
            platform: 'apns',
            token: 'BAD',
          ),
        ],
      );

      final delivery = ApnsRemotePushDelivery(
        config: config(),
        privateKeyPem: apnsTestPrivateKeyPem,
        store: store,
        transport: transport,
      );
      await expectLater(delivery.deliver(_frame()), throwsStateError);

      expect(
        store.removed,
        isEmpty,
        reason: 'a 400 must not prune a live apns token',
      );
    });

    test(
      'one throwing APNs recipient does not block later recipients',
      () async {
        final transport = _FakeApnsTransport(
          statusFor: (token) {
            if (token == 'BAD') throw StateError('stream reset');
            return 200;
          },
        );
        final store = _RecordingStore(
          tokens: [
            const RegisteredPushToken(
              deviceId: 'bad',
              platform: 'apns',
              token: 'BAD',
            ),
            const RegisteredPushToken(
              deviceId: 'good',
              platform: 'apns',
              token: 'GOOD',
            ),
          ],
        );

        await ApnsRemotePushDelivery(
          config: config(),
          privateKeyPem: apnsTestPrivateKeyPem,
          store: store,
          transport: transport,
        ).deliver(_frame());

        expect(transport.requests.map((request) => request.deviceToken), [
          'BAD',
          'GOOD',
        ]);
      },
    );
  });

  group('MockRemotePushDelivery records (cloudless)', () {
    test('records (frame, token) for every enabled recipient', () async {
      final store = InMemoryPushTokenStore(
        tokens: [
          const RegisteredPushToken(
            deviceId: 'a',
            platform: 'fcm',
            token: 'FCM_A',
          ),
          const RegisteredPushToken(
            deviceId: 'b',
            platform: 'apns',
            token: 'APNS_B',
          ),
        ],
      );
      final mock = MockRemotePushDelivery(store: store);
      await mock.deliver(_frame());

      expect(mock.delivered, hasLength(2));
      expect(
        mock.delivered.map((d) => d.token.token),
        containsAll(<String>['FCM_A', 'APNS_B']),
      );
    });
  });

  group('absent config => no-op (never crash)', () {
    test('buildRemotePushDelivery returns null with disabled config', () {
      final store = InMemoryPushTokenStore();
      final delivery = buildRemotePushDelivery(PushConfig.disabled, store);
      expect(delivery, isNull);
    });

    test('buildRemotePushDelivery returns the mock when mock flag is set', () {
      final store = InMemoryPushTokenStore();
      final delivery = buildRemotePushDelivery(
        const PushConfig(
          fcm: FcmPushConfig.disabled,
          apns: ApnsPushConfig.disabled,
          mock: true,
        ),
        store,
      );
      expect(delivery, isA<MockRemotePushDelivery>());
    });
  });
}
