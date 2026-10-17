// Regression coverage: the "Push critical alerts to mobile" row must report
// the REAL delivery state, not restate the toggle's intent.
//
// Observed live on Android (2026-07-25): the row rendered
//   title:    "Push critical alerts to mobile"
//   subtitle: "Forward critical events to paired phones (separate from
//              per-event push toggles below)"
//   toggle:   ON
// with nothing indicating that this device could not receive them. It could
// not: `apps/mobile/android/app/google-services.json` does not exist, so the
// client logs `FCM not configured (no google-services.json); push registration
// dormant` and never registers a token. The row asserted a capability the
// system did not have.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_settings.dart';
import 'package:drift/native.dart';
import 'package:skotiq_app/services/push_delivery_targets_provider.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// A container whose backend is the local host (FFI), not the default
/// [DisconnectedBackend] — the host branch of the provider is only reachable
/// when something can actually answer.
class _HostBackendNotifier extends BackendNotifier {
  _HostBackendNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = FfiBackend();
  }
}

void main() {
  group('push delivery subtitle', () {
    test(
        'no registered device and no channel — says so, does not imply it '
        'works', () {
      final subtitle = pushDeliverySubtitleFor(
        const AsyncData(PushDeliveryTargets.none),
      );

      // It must not restate the intent-only copy.
      expect(subtitle, isNot(contains('Forward critical events')));
      // It must name the actual blocker…
      expect(subtitle, contains('No device has registered for push'));
      expect(subtitle, contains('no push delivery configured'));
      // …and say what DOES happen today (in-app / LAN only).
      expect(subtitle, contains('only appear in the app'));
    });

    test(
        'registered devices but no host channel names the host as the '
        'blocker', () {
      final subtitle = pushDeliverySubtitleFor(
        const AsyncData(
          PushDeliveryTargets(
            registeredDeviceCount: 1,
            fcmTokenCount: 1,
            apnsTokenCount: 0,
            cloudDeliveryConfigured: false,
          ),
        ),
      );

      expect(subtitle, contains('This host has no push delivery configured'));
      expect(subtitle, isNot(contains('Delivering to')));
    });

    test(
        'a configured host with no registrations names the devices as the '
        'blocker', () {
      final subtitle = pushDeliverySubtitleFor(
        const AsyncData(
          PushDeliveryTargets(
            registeredDeviceCount: 0,
            fcmTokenCount: 0,
            apnsTokenCount: 0,
            cloudDeliveryConfigured: true,
          ),
        ),
      );

      expect(subtitle, contains('No paired device has registered for push'));
      expect(subtitle, isNot(contains('Delivering to')));
    });

    test('reports real delivery once a device can actually receive', () {
      expect(
        pushDeliverySubtitleFor(
          const AsyncData(
            PushDeliveryTargets(
              registeredDeviceCount: 1,
              fcmTokenCount: 1,
              apnsTokenCount: 0,
              cloudDeliveryConfigured: true,
            ),
          ),
        ),
        'Delivering to 1 registered device',
      );

      expect(
        pushDeliverySubtitleFor(
          const AsyncData(
            PushDeliveryTargets(
              registeredDeviceCount: 3,
              fcmTokenCount: 2,
              apnsTokenCount: 1,
              cloudDeliveryConfigured: true,
            ),
          ),
        ),
        'Delivering to 3 registered devices',
      );
    });

    test('an unanswered host reads as checking, never as working', () {
      final subtitle = pushDeliverySubtitleFor(
        const AsyncLoading<PushDeliveryTargets>(),
      );
      expect(subtitle, contains('Checking'));
      expect(subtitle, isNot(contains('Delivering to')));
    });

    test('an errored host is never reported as delivering', () {
      final subtitle = pushDeliverySubtitleFor(
        AsyncError<PushDeliveryTargets>(
          Exception('host unreachable'),
          StackTrace.empty,
        ),
      );
      expect(subtitle, isNot(contains('Delivering to')));
    });
  });

  group('PushDeliveryTargets verdict', () {
    test('canDeliver requires BOTH a registration and a configured channel',
        () {
      const registeredOnly = PushDeliveryTargets(
        registeredDeviceCount: 2,
        fcmTokenCount: 2,
        apnsTokenCount: 0,
        cloudDeliveryConfigured: false,
      );
      const configuredOnly = PushDeliveryTargets(
        registeredDeviceCount: 0,
        fcmTokenCount: 0,
        apnsTokenCount: 0,
        cloudDeliveryConfigured: true,
      );
      const both = PushDeliveryTargets(
        registeredDeviceCount: 1,
        fcmTokenCount: 1,
        apnsTokenCount: 0,
        cloudDeliveryConfigured: true,
      );

      expect(registeredOnly.canDeliver, isFalse);
      expect(configuredOnly.canDeliver, isFalse);
      expect(both.canDeliver, isTrue);
      expect(both.blockedReason, isNull);
    });

    test('survives a JSON round trip', () {
      const original = PushDeliveryTargets(
        registeredDeviceCount: 2,
        fcmTokenCount: 1,
        apnsTokenCount: 1,
        cloudDeliveryConfigured: true,
      );
      expect(PushDeliveryTargets.fromJson(original.toJson()), original);
    });
  });

  group('pushDeliveryTargetsProvider host branch', () {
    test('reads registered tokens from the host pairing database', () async {
      final database = PairingDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.addPairedDevice(
        deviceId: 'phone-1',
        deviceName: 'Phone 1',
        deviceType: 'mobile',
        sessionToken: 'tok-1',
        expiresAt: DateTime.now().add(const Duration(days: 30)),
      );
      await database.upsertPushToken(
        deviceId: 'phone-1',
        platform: 'fcm',
        token: 'fcm-1',
      );

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(_HostBackendNotifier.new),
          pushPairingDatabaseProvider.overrideWithValue(database),
          hostCloudPushConfiguredProvider.overrideWith((ref) async => true),
        ],
      );
      addTearDown(container.dispose);

      final targets = await container.read(pushDeliveryTargetsProvider.future);
      expect(targets.registeredDeviceCount, 1);
      expect(targets.fcmTokenCount, 1);
      expect(targets.cloudDeliveryConfigured, isTrue);
      expect(targets.canDeliver, isTrue);
    });

    test('an empty host database reports nothing can receive', () async {
      final database = PairingDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(_HostBackendNotifier.new),
          pushPairingDatabaseProvider.overrideWithValue(database),
          hostCloudPushConfiguredProvider.overrideWith((ref) async => true),
        ],
      );
      addTearDown(container.dispose);

      final targets = await container.read(pushDeliveryTargetsProvider.future);
      expect(targets.registeredDeviceCount, 0);
      expect(targets.canDeliver, isFalse);
      expect(
        targets.blockedReason,
        contains('No paired device has registered for push'),
      );
    });
  });
}
