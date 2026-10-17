// Coverage for the remote flat-suggestion fallback in
// `FlatWizardNotifier.loadFiltersFromWheel`.
//
// On a remote client the local `flat_history` table is empty, so the wizard
// derives a suggested exposure from the master via `NetworkBackend.listFlats`.
// That call legitimately throws on transport/host faults. The wizard must
// still load — it falls back to a null suggestion so the user can enter
// exposures manually — but a fault must NOT be silently conflated with an
// empty history: it is logged as a diagnostic (see `_remoteSuggestedExposure`).
//
// These tests assert the user-visible contract:
//   - a throwing `listFlats` does not escape and break wizard init; the
//     filter's `suggestedExposure` ends up null (manual-entry fallback);
//   - an empty host history yields the same null suggestion;
//   - CRUCIALLY, the two are NOT conflated: the fault path records a
//     diagnostic, the empty-history path does not.
//
// The production diagnostic is emitted via `dart:developer`'s `developer.log`,
// which writes to the Dart VM service and is not interceptable by the standard
// `runZoned`/print capture used in unit tests. To pin which fault occurred we
// inject the notifier's `debugRemoteFaultSink` (a test-only seam that fires on
// the SAME catch branch as the `developer.log` line) and assert it fires on the
// fault path and stays silent on the empty-history path.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/skotiq_core.dart';

import '../mocks/mock_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// Filter-wheel notifier seeded with a fixed set of filter names. The
/// override slot requires the concrete `FilterWheelStateNotifier`, so we
/// extend it and just seed the state — the inherited profile listener is
/// inert here (it only acts when a wheel is connected).
class _SeededFilterWheelNotifier extends FilterWheelStateNotifier {
  _SeededFilterWheelNotifier(super.ref, List<String> names) {
    state = FilterWheelState(filterNames: names);
  }
}

void main() {
  late SkotiqDatabase db;

  setUp(() {
    db = createTestDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer makeContainer(SkotiqBackend backend) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        activeEquipmentProfileProvider.overrideWithValue(null),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        filterWheelStateProvider.overrideWith(
          (ref) => _SeededFilterWheelNotifier(ref, const ['L']),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'remote listFlats throwing does not break wizard init; suggestion is null',
    () async {
      final backend = _MockNetworkBackend();
      final thrown = Exception('host unreachable');
      when(
        () => backend.listFlats(
          filter: any(named: 'filter'),
          equipmentProfileId: any(named: 'equipmentProfileId'),
          limit: any(named: 'limit'),
        ),
      ).thenThrow(thrown);

      final container = makeContainer(backend);
      final notifier = container.read(flatWizardProvider.notifier);
      final faults = <Object>[];
      notifier.debugRemoteFaultSink = faults.add;

      // Must complete without the transport exception escaping.
      await notifier.loadFiltersFromWheel();

      final settings = container.read(flatWizardProvider).filterSettings;
      expect(settings, hasLength(1));
      expect(settings.single.filterName, 'L');
      expect(
        settings.single.suggestedExposure,
        isNull,
        reason: 'fault falls back to manual entry (null suggestion)',
      );
      // The fault path is DISTINGUISHED from empty history: the diagnostic
      // fired exactly once, carrying the underlying transport error.
      expect(
        faults,
        equals([thrown]),
        reason:
            'a transport fault must record a diagnostic, not be silently '
            'treated as empty history',
      );
    },
  );

  test('empty remote history yields a null suggestion (no fault)', () async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.listFlats(
        filter: any(named: 'filter'),
        equipmentProfileId: any(named: 'equipmentProfileId'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => const []);

    final container = makeContainer(backend);
    final notifier = container.read(flatWizardProvider.notifier);
    final faults = <Object>[];
    notifier.debugRemoteFaultSink = faults.add;

    await notifier.loadFiltersFromWheel();

    final settings = container.read(flatWizardProvider).filterSettings;
    expect(settings, hasLength(1));
    expect(settings.single.suggestedExposure, isNull);
    // Empty history is the NON-fault path: no diagnostic is recorded, which
    // is what separates it from a failed fetch.
    expect(
      faults,
      isEmpty,
      reason: 'an empty host history must NOT record a fault diagnostic',
    );
  });
}
