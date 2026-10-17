// Recipient store + preference gate for cellular push delivery (Phase D).
//
// `RemotePushDelivery.deliver(frame)` receives the *content* of a critical
// alert but no *recipient* — the LAN-broadcast frame is identical for every
// phone. FCM/APNs are unicast-per-device, so each delivery must look up the
// registered device tokens itself and fan out one request per token. This
// file defines the small store interface the deliveries read from, decoupled
// from Drift so the abstract surface stays dependency-free; the desktop wiring
// supplies a `PairingDatabase`-backed implementation.

import 'lan_push_broadcaster.dart';
import 'remote_push_delivery.dart';

/// A single registered cellular-push recipient — one row of
/// `device_push_tokens`, flattened to the fields a delivery needs.
class RegisteredPushToken {
  /// Paired-device id (matches `paired_devices.deviceId`). Used to look up
  /// the device's [DevicePushPreferences] before sending.
  final String deviceId;

  /// `fcm` (Android) or `apns` (iOS).
  final String platform;

  /// The opaque FCM registration / APNs device token to POST to.
  final String token;

  const RegisteredPushToken({
    required this.deviceId,
    required this.platform,
    required this.token,
  });
}

/// Per-device notification preferences — one row of `device_push_prefs`,
/// flattened. A delivery consults [allows] for each token before sending.
class DevicePushPreferences {
  /// Master per-device gate. When false the device receives no cellular push.
  final bool enabled;
  final bool muteSequenceFailed;
  final bool muteWeatherUnsafe;
  final bool muteGuidingLost;
  final bool muteAutofocusFailed;
  final bool muteEquipmentDisconnected;

  const DevicePushPreferences({
    this.enabled = true,
    this.muteSequenceFailed = false,
    this.muteWeatherUnsafe = false,
    this.muteGuidingLost = false,
    this.muteAutofocusFailed = false,
    this.muteEquipmentDisconnected = false,
  });

  /// The default applied when a device has never written a prefs row: every
  /// category enabled. A freshly paired phone receives every critical until
  /// the operator mutes something.
  static const DevicePushPreferences allEnabled = DevicePushPreferences();

  /// Whether a frame for [eventType] (a `NotificationCategory.storageKey` ==
  /// the enum name, read from `frame.data['eventType']`) should be delivered
  /// to this device. NOTE: this is the per-event key (`weatherUnsafe`,
  /// `guidingLost`, …), NOT the coarse `EventCategory` carried in
  /// `frame.data['category']` (`safety`, `guiding`, …) — the mute flags are
  /// per-event, so the gate must match the per-event key. The master [enabled]
  /// gate wins; an unknown event type is never muted (fail-open so a new
  /// critical event still reaches the operator before prefs catch up).
  bool allows(String? eventType) {
    if (!enabled) return false;
    switch (eventType) {
      case 'sequenceFailed':
      case 'exposureFailed':
        return !muteSequenceFailed;
      case 'weatherUnsafe':
        return !muteWeatherUnsafe;
      case 'guidingLost':
        return !muteGuidingLost;
      case 'autofocusFailed':
        return !muteAutofocusFailed;
      case 'equipmentDisconnected':
        return !muteEquipmentDisconnected;
      default:
        return true;
    }
  }
}

/// Read surface over the `device_push_tokens` + `device_push_prefs` tables
/// that a [RemotePushDelivery] enumerates on each `deliver(frame)`.
///
/// Kept abstract (no Drift import) so the FCM/APNs/mock deliveries that live
/// in this dependency-free package can fan out without depending on the
/// desktop's `PairingDatabase`. The desktop bootstrap supplies a concrete
/// adapter backed by that database.
abstract class PushTokenStore {
  /// Every registered token for [platform] (`fcm` | `apns`).
  Future<List<RegisteredPushToken>> tokensForPlatform(String platform);

  /// The preferences for [deviceId], or [DevicePushPreferences.allEnabled]
  /// when the device has no row yet.
  Future<DevicePushPreferences> preferencesFor(String deviceId);
}

/// In-memory [PushTokenStore] for tests and zero-cloud local dev. Seed it with
/// tokens + (optionally) per-device prefs and hand it to a delivery.
class InMemoryPushTokenStore implements PushTokenStore {
  final List<RegisteredPushToken> tokens;
  final Map<String, DevicePushPreferences> prefs;

  InMemoryPushTokenStore({
    List<RegisteredPushToken>? tokens,
    Map<String, DevicePushPreferences>? prefs,
  }) : tokens = tokens ?? <RegisteredPushToken>[],
       prefs = prefs ?? <String, DevicePushPreferences>{};

  @override
  Future<List<RegisteredPushToken>> tokensForPlatform(String platform) async {
    return tokens.where((t) => t.platform == platform).toList();
  }

  @override
  Future<DevicePushPreferences> preferencesFor(String deviceId) async {
    return prefs[deviceId] ?? DevicePushPreferences.allEnabled;
  }
}

/// A record of one (frame, recipient) pair the mock "would have sent".
class MockDeliveredPush {
  final PushNotificationFrame frame;
  final RegisteredPushToken token;

  const MockDeliveredPush({required this.frame, required this.token});
}

/// No-cloud [RemotePushDelivery] that enumerates the [PushTokenStore], applies
/// the per-device preference gate, and records every (frame, token) it *would*
/// have sent into [delivered] (rather than hitting FCM/APNs).
///
/// Two uses:
///  - tests assert the full event → enqueue → fan-out → `deliver` chain
///    produces the expected recipient set, with no network;
///  - local dev: the operator watches "would-send" frames before they ever
///    create a Firebase project / Apple key.
///
/// Mirrors what the real FCM/APNs deliveries do (loop tokens, skip muted
/// devices) so the recipient-selection logic is exercised identically.
class MockRemotePushDelivery implements RemotePushDelivery {
  final PushTokenStore store;

  /// Which platforms to fan out to. Defaults to both so a single mock proves
  /// the Android + iOS recipient paths at once.
  final List<String> platforms;

  /// Optional log sink for "would-send" breadcrumbs in local dev. Frames are
  /// always recorded into [delivered] regardless.
  final void Function(String message)? log;

  /// Every (frame, token) the mock would have delivered, in order.
  final List<MockDeliveredPush> delivered = <MockDeliveredPush>[];

  MockRemotePushDelivery({
    required this.store,
    this.platforms = const ['fcm', 'apns'],
    this.log,
  });

  @override
  Future<void> deliver(PushNotificationFrame frame) async {
    final eventType = frame.data['eventType']?.toString();
    for (final platform in platforms) {
      final tokens = await store.tokensForPlatform(platform);
      for (final token in tokens) {
        final prefs = await store.preferencesFor(token.deviceId);
        if (!prefs.allows(eventType)) {
          continue;
        }
        delivered.add(MockDeliveredPush(frame: frame, token: token));
        log?.call(
          '[push:mock] would send "${frame.title}" '
          '(${frame.severity}, eventType=$eventType) to '
          '${token.platform}:${token.deviceId}',
        );
      }
    }
  }

  @override
  Future<void> dispose() async {}
}
