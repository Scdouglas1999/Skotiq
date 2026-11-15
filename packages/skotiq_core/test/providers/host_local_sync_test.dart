import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';

class _MockFfiBackend extends Mock implements FfiBackend {}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void use(SkotiqBackend backend) => state = backend;
}

class _RemoteEnabledSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async {
    return const AppSettingsState(webServerEnabled: true);
  }
}

void main() {
  test(
    'hostLocalSyncProvider applies hub HostStateChanged when remote access on',
    () async {
      final backend = _MockFfiBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());

      var loadCount = 0;
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          appSettingsProvider.overrideWith(_RemoteEnabledSettingsNotifier.new),
          equipmentProfilesProvider.overrideWith(() {
            return _TestProfilesNotifier(onLoad: () => loadCount++);
          }),
        ],
      );
      addTearDown(container.dispose);

      container.read(hostLocalSyncProvider);
      await pumpEventQueue();
      await container.read(equipmentProfilesProvider.future);

      container
          .read(hostMutationEventHubProvider)
          .publish(
            entityType: HostMutationEntity.profile,
            action: HostMutationAction.updated,
            entityId: '1',
          );
      await pumpEventQueue();

      await container.read(equipmentProfilesProvider.future);
      expect(loadCount, greaterThanOrEqualTo(2));
    },
  );

  test(
    'a window that stops being linked follows its own host at once',
    () async {
      final linked = _MockNetworkBackend();
      final local = _MockFfiBackend();
      for (final backend in [linked, local]) {
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      }
      var loadCount = 0;
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, linked),
          ),
          appSettingsProvider.overrideWith(_RemoteEnabledSettingsNotifier.new),
          equipmentProfilesProvider.overrideWith(() {
            return _TestProfilesNotifier(onLoad: () => loadCount++);
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(hostLocalSyncProvider);
      container.read(diagnosticsBackendProvider);
      await pumpEventQueue();
      await container.read(equipmentProfilesProvider.future);

      (container.read(backendProvider.notifier) as _FixedBackendNotifier).use(
        local,
      );
      await pumpEventQueue();
      final loadsBefore = loadCount;
      container
          .read(hostMutationEventHubProvider)
          .publish(
            entityType: HostMutationEntity.profile,
            action: HostMutationAction.updated,
            entityId: '1',
          );
      await pumpEventQueue();
      await container.read(equipmentProfilesProvider.future);

      expect(loadCount, greaterThan(loadsBefore));
    },
  );
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
