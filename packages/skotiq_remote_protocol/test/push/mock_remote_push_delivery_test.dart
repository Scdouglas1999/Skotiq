import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

/// Phase D — the no-cloud [MockRemotePushDelivery] fan-out: it enumerates the
/// [PushTokenStore], applies the per-device preference gate, and records every
/// (frame, token) it would have sent. This is the recipient-selection logic the
/// real FCM/APNs deliveries share, exercised with zero network.
void main() {
  const fingerprint =
      'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';

  // Built as the production frame builder does: the per-device mute gate keys
  // on `eventType` (the per-event NotificationCategory.storageKey, e.g.
  // 'weatherUnsafe'), so the gate-driving value goes there — NOT into the
  // coarse `category` (EventCategory.name) field.
  PushNotificationFrame frame({
    String severity = 'critical',
    String? eventType,
    String category = 'safety',
  }) {
    return PushNotificationFrame(
      id: 'id-1',
      severity: severity,
      title: 'Weather Unsafe',
      body: 'Safety monitor reports unsafe conditions.',
      data: {
        if (eventType != null) 'eventType': eventType,
        'category': category,
      },
      timestamp: DateTime.utc(2026, 6, 8, 1, 30),
      serverFingerprint: fingerprint,
    );
  }

  test('enumerates every registered token across platforms', () async {
    final store = InMemoryPushTokenStore(
      tokens: const [
        RegisteredPushToken(deviceId: 'phone-1', platform: 'fcm', token: 'f1'),
        RegisteredPushToken(deviceId: 'phone-2', platform: 'fcm', token: 'f2'),
        RegisteredPushToken(deviceId: 'phone-3', platform: 'apns', token: 'a3'),
      ],
    );
    final mock = MockRemotePushDelivery(store: store);

    await mock.deliver(frame(eventType: 'weatherUnsafe'));

    expect(mock.delivered, hasLength(3));
    expect(mock.delivered.map((d) => d.token.token).toSet(), {
      'f1',
      'f2',
      'a3',
    });
    // Every recipient received the same frame instance content.
    expect(mock.delivered.every((d) => d.frame.id == 'id-1'), isTrue);
  });

  test('respects the master per-device enabled gate', () async {
    final store = InMemoryPushTokenStore(
      tokens: const [
        RegisteredPushToken(deviceId: 'phone-on', platform: 'fcm', token: 'on'),
        RegisteredPushToken(
          deviceId: 'phone-off',
          platform: 'fcm',
          token: 'off',
        ),
      ],
      prefs: const {'phone-off': DevicePushPreferences(enabled: false)},
    );
    final mock = MockRemotePushDelivery(store: store);

    await mock.deliver(frame(eventType: 'weatherUnsafe'));

    expect(mock.delivered, hasLength(1));
    expect(mock.delivered.single.token.deviceId, 'phone-on');
  });

  test('respects a per-category mute flag for the matching category', () async {
    final store = InMemoryPushTokenStore(
      tokens: const [
        RegisteredPushToken(deviceId: 'tablet', platform: 'fcm', token: 'tab'),
        RegisteredPushToken(deviceId: 'pocket', platform: 'fcm', token: 'pkt'),
      ],
      prefs: const {
        // The pocket phone mutes weather; the wall tablet still wants it.
        'pocket': DevicePushPreferences(muteWeatherUnsafe: true),
      },
    );
    final mock = MockRemotePushDelivery(store: store);

    await mock.deliver(frame(eventType: 'weatherUnsafe'));
    expect(mock.delivered.map((d) => d.token.deviceId), ['tablet']);

    // A DIFFERENT category still reaches the pocket phone — the mute is
    // category-scoped, not a blanket gate.
    mock.delivered.clear();
    await mock.deliver(frame(eventType: 'guidingLost'));
    expect(mock.delivered.map((d) => d.token.deviceId).toSet(), {
      'tablet',
      'pocket',
    });
  });

  test(
    'a missing prefs row delivers every category (fail-open default)',
    () async {
      final store = InMemoryPushTokenStore(
        tokens: const [
          RegisteredPushToken(
            deviceId: 'new-phone',
            platform: 'apns',
            token: 'np',
          ),
        ],
      );
      final mock = MockRemotePushDelivery(store: store);

      await mock.deliver(frame(eventType: 'equipmentDisconnected'));
      expect(mock.delivered, hasLength(1));
    },
  );

  test(
    'an unknown category is never muted (new criticals still reach)',
    () async {
      final store = InMemoryPushTokenStore(
        tokens: const [
          RegisteredPushToken(
            deviceId: 'phone-1',
            platform: 'fcm',
            token: 'f1',
          ),
        ],
        prefs: const {
          'phone-1': DevicePushPreferences(muteWeatherUnsafe: true),
        },
      );
      final mock = MockRemotePushDelivery(store: store);

      await mock.deliver(frame(eventType: 'someBrandNewCategory'));
      expect(mock.delivered, hasLength(1));
    },
  );

  test('platforms filter restricts the fan-out set', () async {
    final store = InMemoryPushTokenStore(
      tokens: const [
        RegisteredPushToken(deviceId: 'android', platform: 'fcm', token: 'f'),
        RegisteredPushToken(deviceId: 'ios', platform: 'apns', token: 'a'),
      ],
    );
    // An FCM-only delivery (as the real FcmHttpV1Delivery would be) sees only
    // the Android token.
    final fcmOnly = MockRemotePushDelivery(
      store: store,
      platforms: const ['fcm'],
    );

    await fcmOnly.deliver(frame(eventType: 'weatherUnsafe'));
    expect(fcmOnly.delivered.map((d) => d.token.deviceId), ['android']);
  });

  // The production wire frame carries the per-event key in
  // `eventType` (NotificationCategory.storageKey == 'weatherUnsafe') and the
  // coarse EventCategory in `category` ('safety'). The mute gate MUST read
  // `eventType` — if it reads `category` ('safety') the mute matrix is inert
  // and a device that muted weather still gets weather pushes. This frame is
  // built exactly as `event_forwarding._buildPushFrameFromNotification` does.
  test(
    'mute gate matches the production wire frame (eventType, not category)',
    () async {
      PushNotificationFrame wireFrame() => PushNotificationFrame(
        id: 'id-prod',
        severity: 'critical',
        title: 'Weather Unsafe',
        body: 'Safety monitor reports unsafe conditions.',
        // Production shape: eventType = storageKey, category = EventCategory.
        data: const {'eventType': 'weatherUnsafe', 'category': 'safety'},
        timestamp: DateTime.utc(2026, 6, 8, 1, 30),
        serverFingerprint: fingerprint,
      );

      final store = InMemoryPushTokenStore(
        tokens: const [
          RegisteredPushToken(deviceId: 'muted', platform: 'fcm', token: 'm'),
          RegisteredPushToken(deviceId: 'wants', platform: 'fcm', token: 'w'),
        ],
        prefs: const {'muted': DevicePushPreferences(muteWeatherUnsafe: true)},
      );
      final mock = MockRemotePushDelivery(store: store);

      await mock.deliver(wireFrame());

      // The muted device must be skipped; the other still receives it.
      expect(mock.delivered.map((d) => d.token.deviceId), ['wants']);
    },
  );
}
