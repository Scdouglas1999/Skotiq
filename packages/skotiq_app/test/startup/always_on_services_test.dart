import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/run_dashboard_providers.dart';
import 'package:skotiq_app/startup/location_sync_service.dart';
import 'package:skotiq_app/startup/always_on_services.dart';
import 'package:skotiq_core/providers.dart';

AlwaysOnService _entry(ProviderListenable<Object?> provider) =>
    alwaysOnServices.singleWhere((s) => identical(s.provider, provider));

void main() {
  group('the table', () {
    test('names each service once and gives it a role and a purpose', () {
      final names = alwaysOnServices.map((s) => s.name).toList();
      expect(names.toSet().length, names.length);
      final providers = alwaysOnServices.map((s) => s.provider).toList();
      expect(providers.toSet().length, providers.length);
      for (final service in alwaysOnServices) {
        expect(service.roles, isNotEmpty, reason: service.name);
        expect(service.does.trim(), isNotEmpty, reason: service.name);
      }
    });

    test('the bridges that were defined but never ran are in it', () {
      const hosts = {AppRole.hostGui, AppRole.hostDaemon};
      const windows = {AppRole.hostGui, AppRole.linkedClient, AppRole.mobile};

      expect(_entry(usbDisconnectEventBridgeProvider).roles,
          AppRole.values.toSet());
      expect(_entry(hotplugEventBridgeProvider).roles, AppRole.values.toSet());
      // The session record reads the recovery history on a daemon too, where
      // no banner is ever mounted.
      expect(_entry(recoveryEventBridgeProvider).roles, AppRole.values.toSet());
      // A sound needs someone to hear it; a push needs the host's queue.
      expect(_entry(recoveryAudibleBridgeProvider).roles, windows);
      expect(_entry(recoveryPushBridgeProvider).roles, hosts);
      expect(_entry(liveStackingKillSwitchBridgeProvider).roles, hosts);
      // Critical run alerts reach the operator whichever screen is open.
      expect(_entry(runCriticalAlertsProvider).roles, AppRole.values.toSet());
      expect(_entry(runCriticalAlertSoundProvider).roles, windows);
      expect(_entry(runCriticalAlertPushProvider).roles, hosts);
    });

    test('host-only work runs on the daemon as well as the GUI host', () {
      for (final provider in <ProviderListenable<Object?>>[
        focuserTempCompensationProvider,
        cameraPresetsSeedOnConnectProvider,
        capabilityRefreshOnConnectProvider,
        mountGuardSettingsSyncProvider,
        homeAssistantDiscoveryProvider,
        notificationRouterProvider,
        autofocusPreviewFeederProvider,
        sessionNightSeedProvider,
        // The daemon serves its native site to linked clients; it has to be
        // the site its settings hold.
        locationSyncProvider,
      ]) {
        expect(
          _entry(provider).roles,
          containsAll([AppRole.hostGui, AppRole.hostDaemon]),
          reason: _entry(provider).name,
        );
      }
    });
  });

  group('starting', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    test('starts the services of the role and no others', () {
      var hostBuilt = 0;
      var clientBuilt = 0;
      final host = Provider<void>((ref) => hostBuilt++);
      final client = Provider<void>((ref) => clientBuilt++);

      final running = startAlwaysOnServices(
        container,
        AppRole.hostDaemon,
        services: [
          AlwaysOnService('host', host, {AppRole.hostDaemon}, 'x'),
          AlwaysOnService('client', client, {AppRole.linkedClient}, 'x'),
        ],
      );

      expect(running.running, ['host']);
      expect(hostBuilt, 1);
      expect(clientBuilt, 0);
    });

    test('a service follows what it watches, which a single read does not',
        () async {
      final dependency = StateProvider<int>((ref) => 0);
      final seen = <int>[];
      final service = Provider<void>((ref) {
        seen.add(ref.watch(dependency));
      });

      startAlwaysOnServices(
        container,
        AppRole.hostGui,
        services: [
          AlwaysOnService('follows', service, {AppRole.hostGui}, 'x'),
        ],
      );
      container.read(dependency.notifier).state = 1;
      await container.pump();

      expect(seen, [0, 1]);
    });

    test('one service that fails to start does not stop the next', () {
      var built = false;
      final broken = Provider<void>((ref) => throw StateError('no backend'));
      final healthy = Provider<void>((ref) => built = true);

      final running = startAlwaysOnServices(
        container,
        AppRole.mobile,
        services: [
          AlwaysOnService('broken', broken, {AppRole.mobile}, 'x'),
          AlwaysOnService('healthy', healthy, {AppRole.mobile}, 'x'),
        ],
      );

      expect(built, isTrue);
      expect(running.running, contains('healthy'));
    });

    test('platform services start with the shared ones', () {
      var built = false;
      final platform = Provider<void>((ref) => built = true);

      startAlwaysOnServices(
        container,
        AppRole.mobile,
        services: const [],
        platformServices: [
          AlwaysOnService('platform', platform, {AppRole.mobile}, 'x'),
        ],
      );

      expect(built, isTrue);
    });

    test('stop lets a service go quiet', () async {
      final dependency = StateProvider<int>((ref) => 0);
      var builds = 0;
      final service = Provider<void>((ref) {
        ref.watch(dependency);
        builds++;
      });

      final running = startAlwaysOnServices(
        container,
        AppRole.hostGui,
        services: [
          AlwaysOnService('service', service, {AppRole.hostGui}, 'x'),
        ],
      );
      running.stop();
      container.read(dependency.notifier).state = 1;
      await container.pump();

      expect(builds, 1);
    });
  });
}
