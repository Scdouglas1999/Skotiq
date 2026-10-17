/// Re-pointing a target must move the `targets` row the scheduler evaluates.
///
/// A builder-typed target gets its `targets` row lazily at run start, keyed by
/// name. Resolving that row on a later run must also REFRESH its RA/Dec:
/// returning the existing id unchanged leaves the autopilot — which reads only
/// that row — scoring the coordinates the operator replaced.
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as backend_events;

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  setUpAll(registerMocktailFallbackValues);

  late MockBackend backend;
  late StreamController<backend_events.SkotiqEvent> eventController;
  late SkotiqDatabase db;

  setUp(() {
    backend = MockBackend();
    eventController = StreamController<backend_events.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await eventController.close();
    await db.close();
  });

  SequenceExecutor buildExecutor() {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container.read(sequenceExecutorProvider);
  }

  Sequence sequenceFor({required double raHours, required double decDegrees}) {
    final exposure = ExposureNode(
      id: 'expo1',
      durationSecs: 15,
      count: 4,
      parentId: 'target1',
    );
    final target = TargetHeaderNode(
      id: 'target1',
      name: 'Target',
      targetName: 'M42-TEST',
      raHours: raHours,
      decDegrees: decDegrees,
      childIds: const ['expo1'],
    );
    return Sequence.create(
      name: 'S',
      nodes: {target.id: target, exposure.id: exposure},
      rootNodeId: target.id,
    );
  }

  test('re-pointing a target updates the row the scheduler reads', () async {
    final executor = buildExecutor();
    final dao = TargetsDao(db);

    await executor.bindCatalogTargetsForTest(
      sequenceFor(raHours: 5.5885, decDegrees: -5.39),
    );
    final firstRun = await dao.getAllTargets();
    expect(firstRun, hasLength(1));
    final id = firstRun.single.id;

    // The operator re-points the same target in the builder and runs again.
    await executor.bindCatalogTargetsForTest(
      sequenceFor(raHours: 21.42, decDegrees: -35.0),
    );

    final row = await dao.getTargetById(id);
    expect(row, isNotNull);
    expect(row!.ra, closeTo(21.42, 1e-6));
    expect(row.dec, closeTo(-35.0, 1e-6));
    expect(
      await dao.getAllTargets(),
      hasLength(1),
      reason: 'the same target, re-pointed — not a second library entry',
    );
  });

  test('a target with no coordinates never blanks the stored ones', () async {
    final executor = buildExecutor();
    final dao = TargetsDao(db);

    await executor.bindCatalogTargetsForTest(
      sequenceFor(raHours: 21.42, decDegrees: -35.0),
    );
    await executor.bindCatalogTargetsForTest(
      sequenceFor(raHours: 0.0, decDegrees: 0.0),
    );

    final row = (await dao.getAllTargets()).single;
    expect(row.ra, closeTo(21.42, 1e-6));
    expect(row.dec, closeTo(-35.0, 1e-6));
  });
}
