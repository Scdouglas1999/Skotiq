// Verifies that SequenceExecutor consumes
// `sessionHandoffDecisionProvider(family)` at start() and pushes the
// resolved per-target carry-over map into the Rust backend via
// `sequencerUpdatePendingIntegrationCarryOver`.
//
// Three operator decisions:
//   * Resume      → forwards the per-filter totals.
//   * Restart     → forwards an empty map (zeroes prior carry-over).
//   * ContinueNew → omits the target from the payload entirely.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db_ent;

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

Future<int> _createTarget(
  SkotiqDatabase db, {
  required String name,
  String? catalogId,
}) async {
  return db
      .into(db.targets)
      .insert(
        db_ent.TargetsCompanion.insert(
          name: name,
          ra: 0.7,
          dec: 41.3,
          catalogId: Value(catalogId),
        ),
      );
}

Future<int> _insertSession(
  SkotiqDatabase db, {
  required int targetId,
  required DateTime startTime,
}) async {
  final dao = SessionsDao(db);
  return dao.createSession(
    db_ent.ImagingSessionsCompanion.insert(
      targetId: Value(targetId),
      startTime: startTime,
      status: const Value('completed'),
    ),
  );
}

Future<void> _insertLight(
  SkotiqDatabase db, {
  required int sessionId,
  required int targetId,
  required String filter,
  required double exposure,
}) async {
  final dao = ImagesDao(db);
  await dao.createImage(
    db_ent.CapturedImagesCompanion.insert(
      filePath: 'C:/fake/$filter-$sessionId.fits',
      fileName: 'frame.fits',
      sessionId: Value(sessionId),
      targetId: Value(targetId),
      frameType: const Value('light'),
      exposureDuration: exposure,
      filter: Value(filter),
      capturedAt: DateTime(2026, 5, 17, 22),
    ),
  );
}

void main() {
  setUpAll(() {
    registerMocktailFallbackValues();
  });

  late MockBackend backend;
  late SkotiqDatabase db;
  late ProviderContainer container;

  setUp(() async {
    backend = MockBackend();
    when(
      () => backend.sequencerUpdatePendingIntegrationCarryOver(any()),
    ).thenAnswer((_) async {});
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await Future<void>.delayed(Duration.zero);
      await db.close();
    });
  });

  group('SequenceExecutor handoff carry-over seeding', () {
    test('Resume forwards per-filter totals to the backend', () async {
      // Seed the DB so detectCarryOver returns a real SessionCarryOver
      // for "M31" with 5 × 300s Lum frames.
      final now = DateTime.now();
      final targetId = await _createTarget(db, name: 'M31', catalogId: 'M31');
      final sid = await _insertSession(
        db,
        targetId: targetId,
        startTime: now.subtract(const Duration(days: 1)),
      );
      for (var i = 0; i < 5; i++) {
        await _insertLight(
          db,
          sessionId: sid,
          targetId: targetId,
          filter: 'L',
          exposure: 300,
        );
      }

      final header = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.7,
        decDegrees: 41.3,
      );
      final sequence = Sequence.create(
        name: 'tonight',
        nodes: {header.id: header},
        rootNodeId: header.id,
      );
      // Set the current sequence so sessionCarryOverProvider rebuilds
      // against it.
      container.read(currentSequenceProvider.notifier).loadSequence(sequence);

      // Operator chose Resume for this target.
      container
              .read(
                sessionHandoffDecisionProvider((
                  sequenceId: null,
                  targetId: targetId,
                )).notifier,
              )
              .state =
          SessionHandoffDecision.resume;

      final executor = container.read(sequenceExecutorProvider);
      await executor.seedIntegrationCarryOverFromHandoffForTest(
        backend,
        sequence,
      );

      final captured = verify(
        () => backend.sequencerUpdatePendingIntegrationCarryOver(captureAny()),
      ).captured;
      expect(captured, hasLength(1));
      final payload = captured.single as Map<String, Map<String, double>>;
      // Single target entry keyed by the Dart TargetHeaderNode.id (the
      // BudgetRegistry's lookup key).
      expect(payload.keys, [header.id]);
      // Lower-cased filter key matches detectCarryOver's normalisation.
      expect(payload[header.id], {'l': 1500.0});
    });

    test('Restart forwards an empty map for the target', () async {
      final now = DateTime.now();
      final targetId = await _createTarget(db, name: 'M42', catalogId: 'M42');
      final sid = await _insertSession(
        db,
        targetId: targetId,
        startTime: now.subtract(const Duration(days: 1)),
      );
      await _insertLight(
        db,
        sessionId: sid,
        targetId: targetId,
        filter: 'L',
        exposure: 120,
      );

      final header = TargetHeaderNode(
        targetName: 'M42',
        raHours: 5.6,
        decDegrees: -5.4,
      );
      final sequence = Sequence.create(
        name: 'orion',
        nodes: {header.id: header},
        rootNodeId: header.id,
      );
      container.read(currentSequenceProvider.notifier).loadSequence(sequence);
      container
              .read(
                sessionHandoffDecisionProvider((
                  sequenceId: null,
                  targetId: targetId,
                )).notifier,
              )
              .state =
          SessionHandoffDecision.restart;

      final executor = container.read(sequenceExecutorProvider);
      await executor.seedIntegrationCarryOverFromHandoffForTest(
        backend,
        sequence,
      );

      final captured = verify(
        () => backend.sequencerUpdatePendingIntegrationCarryOver(captureAny()),
      ).captured;
      final payload = captured.single as Map<String, Map<String, double>>;
      // Restart writes an explicit empty inner map so the Rust side
      // zeroes any pre-existing per-target state.
      expect(payload, {header.id: <String, double>{}});
    });

    test('ContinueNew omits the target from the payload', () async {
      final now = DateTime.now();
      final targetId = await _createTarget(
        db,
        name: 'NGC 7000',
        catalogId: 'NGC7000',
      );
      final sid = await _insertSession(
        db,
        targetId: targetId,
        startTime: now.subtract(const Duration(days: 1)),
      );
      await _insertLight(
        db,
        sessionId: sid,
        targetId: targetId,
        filter: 'Ha',
        exposure: 600,
      );

      final header = TargetHeaderNode(
        targetName: 'NGC 7000',
        raHours: 20.97,
        decDegrees: 44.3,
      );
      final sequence = Sequence.create(
        name: 'na',
        nodes: {header.id: header},
        rootNodeId: header.id,
      );
      container.read(currentSequenceProvider.notifier).loadSequence(sequence);
      container
              .read(
                sessionHandoffDecisionProvider((
                  sequenceId: null,
                  targetId: targetId,
                )).notifier,
              )
              .state =
          SessionHandoffDecision.continueNew;

      final executor = container.read(sequenceExecutorProvider);
      await executor.seedIntegrationCarryOverFromHandoffForTest(
        backend,
        sequence,
      );

      // ContinueNew → payload was empty → backend never called.
      verifyNever(
        () => backend.sequencerUpdatePendingIntegrationCarryOver(any()),
      );
    });

    test('no decision recorded → backend not called', () async {
      final now = DateTime.now();
      final targetId = await _createTarget(
        db,
        name: 'IC 1396',
        catalogId: 'IC1396',
      );
      final sid = await _insertSession(
        db,
        targetId: targetId,
        startTime: now.subtract(const Duration(days: 1)),
      );
      await _insertLight(
        db,
        sessionId: sid,
        targetId: targetId,
        filter: 'Oiii',
        exposure: 600,
      );

      final header = TargetHeaderNode(
        targetName: 'IC 1396',
        raHours: 21.65,
        decDegrees: 57.5,
      );
      final sequence = Sequence.create(
        name: 'elephant',
        nodes: {header.id: header},
        rootNodeId: header.id,
      );
      container.read(currentSequenceProvider.notifier).loadSequence(sequence);

      // No decision set — provider returns null. The seeder must NOT
      // pre-emptively zero or guess; the budget tracker starts default.
      final executor = container.read(sequenceExecutorProvider);
      await executor.seedIntegrationCarryOverFromHandoffForTest(
        backend,
        sequence,
      );

      verifyNever(
        () => backend.sequencerUpdatePendingIntegrationCarryOver(any()),
      );
    });

    test('no target headers → early return, no backend call', () async {
      // A sequence with no TargetHeaderNodes (e.g. raw exposure-only
      // session) cannot have any handoff decisions; the seeder bails
      // before reading the carry-over provider.
      final sequence = Sequence.create(name: 'unscoped', nodes: const {});
      final executor = container.read(sequenceExecutorProvider);
      await executor.seedIntegrationCarryOverFromHandoffForTest(
        backend,
        sequence,
      );
      verifyNever(
        () => backend.sequencerUpdatePendingIntegrationCarryOver(any()),
      );
    });

    test(
      'history failure blocks a direct start without authorization',
      () async {
        final errorContainer = ProviderContainer(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _TestBackendNotifier(ref, backend),
            ),
            sessionCarryOverProvider.overrideWith(
              (ref) => throw StateError('history unavailable'),
            ),
          ],
        );
        addTearDown(errorContainer.dispose);
        final header = TargetHeaderNode(
          targetName: 'M31',
          raHours: 0.7,
          decDegrees: 41.3,
        );
        final sequence = Sequence.create(
          name: 'tonight',
          nodes: {header.id: header},
          rootNodeId: header.id,
        );

        expect(
          () => errorContainer
              .read(sequenceExecutorProvider)
              .seedIntegrationCarryOverFromHandoffForTest(backend, sequence),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('explicit one-shot authorization skips one history failure', () async {
      final errorContainer = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
          sessionCarryOverProvider.overrideWith(
            (ref) => throw StateError('history unavailable'),
          ),
        ],
      );
      addTearDown(errorContainer.dispose);
      errorContainer
              .read(sessionHandoffIgnoreUnavailableOnceProvider.notifier)
              .state =
          true;
      final header = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.7,
        decDegrees: 41.3,
      );
      final sequence = Sequence.create(
        name: 'tonight',
        nodes: {header.id: header},
        rootNodeId: header.id,
      );

      await errorContainer
          .read(sequenceExecutorProvider)
          .seedIntegrationCarryOverFromHandoffForTest(backend, sequence);

      expect(
        errorContainer.read(sessionHandoffIgnoreUnavailableOnceProvider),
        isFalse,
      );
      verifyNever(
        () => backend.sequencerUpdatePendingIntegrationCarryOver(any()),
      );
    });
  });
}
