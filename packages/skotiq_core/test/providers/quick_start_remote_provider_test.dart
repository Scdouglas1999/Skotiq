import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _PinnedBackendNotifier extends BackendNotifier {
  _PinnedBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

db.ImagingSession _session({
  required int id,
  required String status,
  required DateTime startTime,
}) {
  return db.ImagingSession(
    id: id,
    name: 'Andromeda night',
    targetId: 8,
    sequenceId: 9,
    startTime: startTime,
    endTime: startTime.add(const Duration(hours: 2)),
    totalExposures: 20,
    successfulExposures: 10,
    failedExposures: 1,
    totalIntegrationSecs: 3600,
    autofocusCount: 1,
    status: status,
  );
}

void main() {
  test(
    'remote Quick Start uses host records and a real backend checkpoint',
    () async {
      final now = DateTime.now();
      final backend = _MockNetworkBackend();
      when(() => backend.getCheckpointInfo()).thenAnswer(
        (_) async => CheckpointInfo(
          sequenceName: 'M31 sequence',
          timestamp: now,
          completedExposures: 12,
          completedIntegrationSecs: 4200,
          canResume: true,
          ageSeconds: 30,
        ),
      );

      final hostTarget = db.Target(
        id: 8,
        name: 'M31',
        objectType: 'galaxy',
        ra: 0.71,
        dec: 41.27,
        minAltitude: 20,
        priority: 1,
        totalPlannedSubs: 20,
        capturedSubs: 10,
        totalIntegrationSecs: 3600,
        goalIntegrationSecs: 7200,
        createdAt: now,
        updatedAt: now,
        isFavorite: true,
      );
      final hostSequence = db.Sequence(
        id: 9,
        name: 'M31 sequence',
        estimatedDurationMins: 120,
        createdAt: now,
        updatedAt: now,
        isTemplate: false,
        tagsJson: '[]',
        isFavorite: false,
      );
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _PinnedBackendNotifier(ref, backend),
          ),
          databaseProvider.overrideWith(
            (ref) => throw StateError('controller database was accessed'),
          ),
          allSessionsProvider.overrideWith(
            (ref) => Stream.value([
              _session(
                id: 99,
                status: 'aborted',
                startTime: now.subtract(const Duration(minutes: 30)),
              ),
              _session(
                id: 7,
                status: 'completed',
                startTime: now.subtract(const Duration(hours: 3)),
              ),
            ]),
          ),
          allDbTargetsProvider.overrideWith(
            (ref) => Stream.value([hostTarget]),
          ),
          allDbSequencesProvider.overrideWith(
            (ref) => Stream.value([hostSequence]),
          ),
          allProfilesProvider.overrideWith((ref) => Stream.value(const [])),
        ],
      );
      addTearDown(container.dispose);

      final context = await container.read(quickStartContextProvider.future);

      expect(context, isNotNull);
      expect(
        context!.sessionId,
        7,
        reason: 'aborted sessions are not resumable',
      );
      expect(context.targetName, 'M31');
      expect(context.sequenceName, 'M31 sequence');
      expect(context.completedFrames, 12);
      expect(context.totalFrames, 20);
      expect(context.canResumeFromCheckpoint, isTrue);
      verify(() => backend.getCheckpointInfo()).called(1);
    },
  );
}
