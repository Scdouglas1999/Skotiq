import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart'
    hide CameraState;
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/models/equipment_profile.dart'
    as remote_profile;
import 'package:skotiq_core/src/providers/remote_sync_handler.dart';
import 'package:skotiq_core/src/services/device_service.dart';
import 'package:skotiq_core/src/services/profile_service.dart';
import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

void main() {
  setUpAll(() {
    registerFallbackValue(const Stream<SkotiqEvent>.empty());
    registerFallbackValue(
      const remote_profile.EquipmentProfile(id: '0', name: 'fallback'),
    );
    registerFallbackValue(DeviceType.camera);
  });

  group('equipment remote parity', () {
    test(
      'updateProfileDevices saves through host API on NetworkBackend',
      () async {
        final backend = _MockNetworkBackend();
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
        when(() => backend.getProfiles()).thenAnswer(
          (_) async => [
            const remote_profile.EquipmentProfile(
              id: '9',
              name: 'Rig',
              cameraId: 'old-cam',
            ),
          ],
        );
        when(() => backend.saveProfile(any())).thenAnswer((_) async {});

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
          ],
        );
        addTearDown(container.dispose);

        final service = container.read(profileServiceProvider);
        await service.updateProfileDevices(9, cameraId: 'new-cam');

        final captured = verify(
          () => backend.saveProfile(captureAny()),
        ).captured;
        final saved = captured.single as remote_profile.EquipmentProfile;
        expect(saved.id, '9');
        expect(saved.cameraId, 'new-cam');
      },
    );

    test(
      'a delayed profile assignment cannot be retargeted to a new host',
      () async {
        final hostA = _MockNetworkBackend();
        final hostB = _MockNetworkBackend();
        final profiles = Completer<List<remote_profile.EquipmentProfile>>();
        for (final backend in [hostA, hostB]) {
          when(
            () => backend.eventStream,
          ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
        }
        when(() => hostA.getProfiles()).thenAnswer((_) => profiles.future);

        late _SwappableBackendNotifier backendNotifier;
        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith((ref) {
              backendNotifier = _SwappableBackendNotifier(ref, hostA);
              return backendNotifier;
            }),
          ],
        );
        addTearDown(container.dispose);

        final assigning = container
            .read(profileServiceProvider)
            .updateProfileDevices(9, cameraId: 'new-cam');
        await untilCalled(() => hostA.getProfiles());
        backendNotifier.switchTo(hostB);
        profiles.complete([
          const remote_profile.EquipmentProfile(
            id: '9',
            name: 'Host A rig',
            cameraId: 'old-cam',
          ),
        ]);

        await expectLater(assigning, throwsStateError);
        verifyNever(() => hostA.saveProfile(any()));
        verifyNever(() => hostB.saveProfile(any()));
      },
    );

    // A mirrored equipment Connected/Disconnected event must NOT reload the
    // profile catalog: connecting a device does not change the profile LIST or
    // the active profile, and on a slave equipmentProfilesProvider is
    // network-backed, so invalidating it round-trips to the host and cascades
    // through opticalConfig -> tonightSuggestions, making "Plan Tonight" thrash
    // on every Connected/Disconnected. Connection STATE is mirrored via the
    // per-device state providers instead. (See remote_sync_handler.dart's
    // _applyEquipmentEvent 'Connected' case.) Catalog refreshes are driven by
    // actual PROFILE events (profile_changed / HostMutationEntity.profile),
    // asserted in the next test.
    test(
      'equipment Connected WS event does NOT reload profile catalog',
      () async {
        final backend = _MockNetworkBackend();
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());

        var loadCount = 0;
        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
            equipmentProfilesProvider.overrideWith(() {
              return _TestProfilesNotifier(onLoad: () => loadCount++);
            }),
          ],
        );
        addTearDown(container.dispose);

        await container.read(equipmentProfilesProvider.future);
        expect(loadCount, 1, reason: 'one initial build');

        await applyRemoteSyncEvent(
          container,
          const SkotiqEvent(
            timestamp: 1,
            severity: EventSeverity.info,
            category: EventCategory.equipment,
            eventType: 'Connected',
            data: {'device_type': 'camera', 'device_id': 'cam-42'},
          ),
        );

        await container.read(equipmentProfilesProvider.future);
        expect(
          loadCount,
          1,
          reason:
              'Connected must not invalidate the profile catalog (no thrash)',
        );
      },
    );

    // The replacement mechanism for catalog parity: a genuine PROFILE change
    // (profile_changed) DOES invalidate equipmentProfilesProvider, so the slave
    // re-pulls the host's profile list / active profile on real profile
    // mutations without thrashing on device connects.
    test('profile_changed WS event reloads profile catalog', () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());

      var loadCount = 0;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          equipmentProfilesProvider.overrideWith(() {
            return _TestProfilesNotifier(onLoad: () => loadCount++);
          }),
        ],
      );
      addTearDown(container.dispose);

      await container.read(equipmentProfilesProvider.future);
      expect(loadCount, 1, reason: 'one initial build');

      await applyRemoteSyncEvent(
        container,
        const SkotiqEvent(
          timestamp: 1,
          severity: EventSeverity.info,
          category: EventCategory.system,
          eventType: 'profile_changed',
          data: {},
        ),
      );

      await container.read(equipmentProfilesProvider.future);
      expect(
        loadCount,
        greaterThanOrEqualTo(2),
        reason: 'a real profile change must re-pull the catalog',
      );
    });
  });
}

class _TestProfilesNotifier extends EquipmentProfilesNotifier {
  _TestProfilesNotifier({required this.onLoad});

  final void Function() onLoad;

  @override
  Future<EquipmentProfilesState> build() async {
    onLoad();
    return const EquipmentProfilesState(profiles: [], activeProfile: null);
  }
}
