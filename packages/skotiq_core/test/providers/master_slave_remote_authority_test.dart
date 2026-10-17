import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/skotiq_core.dart';
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
      const EquipmentProfile(id: 'fallback', name: 'fallback'),
    );
  });

  group('master/slave host authority', () {
    test('profile CRUD uses NetworkBackend not local DAO', () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      when(() => backend.saveProfile(any())).thenAnswer((_) async {});
      when(() => backend.lastSavedProfileId).thenReturn('42');
      when(() => backend.getProfiles()).thenAnswer(
        (_) async => [
          const EquipmentProfile(id: '42', name: 'Remote Rig', isActive: true),
        ],
      );
      when(() => backend.getActiveProfile()).thenAnswer(
        (_) async => const EquipmentProfile(
          id: '42',
          name: 'Remote Rig',
          isActive: true,
        ),
      );

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(equipmentProfilesProvider.notifier);
      await notifier.createProfile(name: 'Remote Rig');

      verify(() => backend.saveProfile(any())).called(1);
      verifyNever(() => backend.loadProfile('0'));
    });

    test('setActiveProfile on slave calls host loadProfile', () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      when(() => backend.getProfiles()).thenAnswer((_) async => []);
      when(() => backend.getActiveProfile()).thenAnswer((_) async => null);
      when(() => backend.loadProfile('7')).thenAnswer((_) async {});

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(equipmentProfilesProvider.future);
      await container
          .read(equipmentProfilesProvider.notifier)
          .setActiveProfile(7);

      verify(() => backend.loadProfile('7')).called(1);
    });

    test(
      'a delayed profile save cannot return an id from the old host',
      () async {
        final hostA = _MockNetworkBackend();
        final hostB = _MockNetworkBackend();
        final save = Completer<void>();
        for (final backend in [hostA, hostB]) {
          when(
            () => backend.eventStream,
          ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
          when(() => backend.getProfiles()).thenAnswer((_) async => []);
          when(() => backend.getActiveProfile()).thenAnswer((_) async => null);
        }
        when(() => hostA.lastSavedProfileId).thenReturn('42');
        when(() => hostA.saveProfile(any())).thenAnswer((_) => save.future);

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
        await container.read(equipmentProfilesProvider.future);

        final creating = container
            .read(equipmentProfilesProvider.notifier)
            .createProfile(name: 'Delayed host A profile');
        await untilCalled(() => hostA.saveProfile(any()));
        backendNotifier.switchTo(hostB);
        save.complete();

        await expectLater(creating, throwsStateError);
        expect(container.read(backendProvider), same(hostB));
      },
    );

    test('HostStateChanged target invalidates remote target catalog', () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      when(() => backend.getAllTargets()).thenAnswer(
        (_) async => [
          {'id': 1, 'name': 'M42', 'ra': 5.58, 'dec': -5.39},
        ],
      );

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(allDbTargetsProvider.future);
      clearInteractions(backend);

      when(() => backend.getAllTargets()).thenAnswer(
        (_) async => [
          {'id': 1, 'name': 'M42', 'ra': 5.58, 'dec': -5.39},
          {'id': 2, 'name': 'M43', 'ra': 5.6, 'dec': -5.2},
        ],
      );

      await applyRemoteSyncEvent(
        container,
        buildHostMutationEvent(
          entityType: HostMutationEntity.target,
          action: HostMutationAction.created,
          entityId: '2',
        ),
      );

      final targets = await container.read(allDbTargetsProvider.future);
      expect(targets, hasLength(2));
      verify(() => backend.getAllTargets()).called(greaterThanOrEqualTo(1));
    });
  });
}
