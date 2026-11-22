// What a linked client reads again from its host on connect, on reconnect and
// with each periodic re-read: exactly the stored data the host holds.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart' show exposureProgressProvider;

import '../../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _Rebuilds extends ProviderObserver {
  final disposed = <ProviderBase<Object?>>{};

  @override
  void didDisposeProvider(
    ProviderBase<Object?> provider,
    ProviderContainer container,
  ) => disposed.add(provider);
}

final _reread = <String, ProviderListenable<Object?>>{
  'equipmentProfilesProvider': equipmentProfilesProvider,
  'allProfilesProvider': allProfilesProvider,
  'activeProfileProvider': activeProfileProvider,
  'appSettingsProvider': appSettingsProvider,
  'savedSequencesProvider': savedSequencesProvider,
  'savedSequenceSummariesProvider': savedSequenceSummariesProvider,
  'schedulerPreviewDecisionProvider': schedulerPreviewDecisionProvider,
  'projectListProvider': projectListProvider,
  'integrationGoalsStreamProvider': integrationGoalsStreamProvider,
  'targetConstraintsStreamProvider': targetConstraintsStreamProvider,
  'sequenceRunsProvider': sequenceRunsProvider,
  'observingListsProvider': observingListsProvider,
  'listedCatalogIdsProvider': listedCatalogIdsProvider,
};

/// Host data a client follows by other means (runtime channels, events).
final _notReread = <String, ProviderListenable<Object?>>{
  'liveStackingProvider': liveStackingProvider,
  'eventHistoryProvider': eventHistoryProvider,
  'exposureProgressProvider': exposureProgressProvider,
  'mountStateProvider': mountStateProvider,
  'flipExecutionStateProvider': flipExecutionStateProvider,
};

void main() {
  test('a re-read reads again exactly the stored host data', () async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(
      () => backend.connectionState,
    ).thenReturn(BackendConnectionState.connected);
    final rebuilds = _Rebuilds();
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
      observers: [rebuilds],
    );
    addTearDown(container.dispose);

    final watched = {..._reread, ..._notReread};
    final origins = <String, ProviderBase<Object?>>{};
    for (final MapEntry(:key, :value) in watched.entries) {
      container.listen(value, (_, _) {});
      origins[key] = value is ProviderBase<Object?>
          ? value
          : throw StateError('$key is not a provider');
    }
    await pumpEventQueue(times: 20);
    rebuilds.disposed.clear();

    rereadStoredHostData(container);
    for (final value in watched.values) {
      container.read(value);
    }
    await pumpEventQueue(times: 20);

    final reread = {
      for (final MapEntry(:key, :value) in origins.entries)
        if (rebuilds.disposed.contains(value)) key,
    };
    expect(reread, _reread.keys.toSet());
  });
}
