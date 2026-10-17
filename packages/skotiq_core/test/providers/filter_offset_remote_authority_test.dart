import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void replaceWith(SkotiqBackend backend) => state = backend;
}

const _profile = EquipmentProfileModel(
  id: 7,
  name: 'Imaging rig',
  isActive: true,
);

Map<String, dynamic> _offsetResponse({
  String reference = 'L',
  Map<String, int> offsets = const {'L': 0, 'R': 80},
}) => {
  'profileId': '7',
  'referenceFilter': reference,
  'offsets': {
    for (final entry in offsets.entries)
      entry.key: {'offsetSteps': entry.value},
  },
};

Future<FilterOffsetState> _waitUntilLoaded(ProviderContainer container) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final state = container.read(filterOffsetProvider);
    if (!state.isLoading) return state;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('Filter offsets did not finish loading');
}

void main() {
  test(
    'remote edits, reference changes, and clear mutate the imaging host',
    () async {
      final backend = _MockNetworkBackend();
      var hostState = _offsetResponse();
      when(backend.getFilterFocusOffsets).thenAnswer((_) async => hostState);
      when(
        () => backend.setFilterFocusOffsets(
          referenceFilter: any(named: 'referenceFilter'),
          offsets: any(named: 'offsets'),
        ),
      ).thenAnswer((invocation) async {
        final reference = invocation.namedArguments[#referenceFilter] as String;
        final changes = invocation.namedArguments[#offsets] as Map<String, int>;
        final current = <String, int>{
          for (final entry in (hostState['offsets'] as Map).entries)
            entry.key.toString(): (entry.value as Map)['offsetSteps'] as int,
        }..addAll(changes);
        hostState = _offsetResponse(reference: reference, offsets: current);
      });
      when(backend.clearFocusModelData).thenAnswer((_) async {
        hostState = _offsetResponse(offsets: const {});
      });
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, backend),
          ),
          activeEquipmentProfileProvider.overrideWithValue(_profile),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(filterOffsetProvider.notifier);
      await _waitUntilLoaded(container);

      await notifier.setFilterOffset('R', 125);
      await notifier.setReferenceFilter('R');
      await notifier.clearAllOffsets();

      verify(
        () => backend.setFilterFocusOffsets(
          referenceFilter: 'L',
          offsets: {'R': 125},
        ),
      ).called(1);
      verify(
        () => backend.setFilterFocusOffsets(
          referenceFilter: 'R',
          offsets: const {},
        ),
      ).called(1);
      verify(backend.clearFocusModelData).called(1);
      expect(container.read(filterOffsetProvider).offsets, isEmpty);
    },
  );

  test('failed remote edit rolls back the optimistic value', () async {
    final backend = _MockNetworkBackend();
    when(
      backend.getFilterFocusOffsets,
    ).thenAnswer((_) async => _offsetResponse());
    when(
      () => backend.setFilterFocusOffsets(
        referenceFilter: any(named: 'referenceFilter'),
        offsets: any(named: 'offsets'),
      ),
    ).thenThrow(StateError('host rejected update'));
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, backend),
        ),
        activeEquipmentProfileProvider.overrideWithValue(_profile),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(filterOffsetProvider.notifier);
    await _waitUntilLoaded(container);
    await notifier.setFilterOffset('R', 999);

    final state = container.read(filterOffsetProvider);
    expect(state.offsets['R'], 80);
    expect(state.error, contains('host rejected update'));
  });

  test(
    'host switch reloads offsets and discards the old host response',
    () async {
      final hostA = _MockNetworkBackend();
      final hostB = _MockNetworkBackend();
      final hostAGate = Completer<Map<String, dynamic>>();
      when(hostA.getFilterFocusOffsets).thenAnswer((_) => hostAGate.future);
      when(hostB.getFilterFocusOffsets).thenAnswer(
        (_) async => _offsetResponse(reference: 'Ha', offsets: const {'Ha': 0}),
      );
      late _SwappableBackendNotifier backendNotifier;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            backendNotifier = _SwappableBackendNotifier(ref, hostA);
            return backendNotifier;
          }),
          activeEquipmentProfileProvider.overrideWithValue(_profile),
        ],
      );
      addTearDown(container.dispose);

      container.read(filterOffsetProvider);
      await Future<void>.delayed(Duration.zero);
      backendNotifier.replaceWith(hostB);

      var state = await _waitUntilLoaded(container);
      expect(state.referenceFilter, 'Ha');
      expect(state.offsets, {'Ha': 0});

      hostAGate.complete(_offsetResponse(reference: 'L'));
      await Future<void>.delayed(Duration.zero);
      state = container.read(filterOffsetProvider);
      expect(state.referenceFilter, 'Ha');
      expect(state.offsets, {'Ha': 0});
    },
  );
}
