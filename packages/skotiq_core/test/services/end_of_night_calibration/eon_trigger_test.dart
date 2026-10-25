import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';
import 'eon_service_test.dart' show FakeRig;

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  group('classifyRunEnd', () {
    test('a completed plan ends the night', () {
      expect(
        classifyRunEnd(
          runStatus: 'completed',
          stopOrigin: null,
          nightEnding: false,
        ),
        EonEndReason.targetsComplete,
      );
    });

    test('the dawn trigger ends the night', () {
      expect(
        classifyRunEnd(
          runStatus: 'stopped',
          stopOrigin: 'dawn_approaching',
          nightEnding: false,
        ),
        EonEndReason.dawn,
      );
    });

    test('a dawn park filed as aborted ends the night', () {
      // The native side files a stop it made itself (the dawn trigger's park)
      // as `aborted`, not `stopped`.
      expect(
        classifyRunEnd(
          runStatus: 'aborted',
          stopOrigin: 'dawn_approaching',
          nightEnding: true,
        ),
        EonEndReason.dawn,
      );
    });

    test('an obstruction park ends the night at any hour', () {
      for (final status in ['aborted', 'stopped']) {
        expect(
          classifyRunEnd(
            runStatus: status,
            stopOrigin: 'obstruction',
            nightEnding: false,
          ),
          EonEndReason.obstruction,
          reason: status,
        );
      }
    });

    test('a weather or safety stop ends the night only at dawn', () {
      for (final origin in ['weather_unsafe', 'safety', null]) {
        expect(
          classifyRunEnd(
            runStatus: 'stopped',
            stopOrigin: origin,
            nightEnding: true,
          ),
          EonEndReason.dawn,
          reason: '$origin',
        );
        expect(
          classifyRunEnd(
            runStatus: 'stopped',
            stopOrigin: origin,
            nightEnding: false,
          ),
          isNull,
          reason: '$origin',
        );
      }
    });

    test('an operator stop or a failure leaves the night open', () {
      expect(
        classifyRunEnd(
          runStatus: 'stopped',
          stopOrigin: 'operator',
          nightEnding: true,
        ),
        isNull,
      );
      expect(
        classifyRunEnd(
          runStatus: 'failed',
          stopOrigin: null,
          nightEnding: true,
        ),
        isNull,
      );
    });
  });

  group('isNightEnding', () {
    // The owner's site, the morning of 2026-10-22: astronomical dawn 05:48
    // EDT (09:48 UTC).
    const lat = 39.97;
    const lon = -75.36;

    test('true in the half hour before astronomical dawn and after it', () {
      expect(
        isNightEnding(
          time: DateTime.utc(2026, 10, 22, 9, 25),
          latitude: lat,
          longitude: lon,
        ),
        isTrue,
      );
      expect(
        isNightEnding(
          time: DateTime.utc(2026, 10, 22, 11, 0),
          latitude: lat,
          longitude: lon,
        ),
        isTrue,
      );
    });

    test('false in the middle of the night and at dusk', () {
      expect(
        isNightEnding(
          time: DateTime.utc(2026, 10, 22, 6, 0),
          latitude: lat,
          longitude: lon,
        ),
        isFalse,
      );
      expect(
        isNightEnding(
          time: DateTime.utc(2026, 10, 22, 23, 0),
          latitude: lat,
          longitude: lon,
        ),
        isFalse,
      );
    });
  });

  group('EndOfNightCalibrationCoordinator', () {
    late SkotiqDatabase db;
    late FakeRig rig;
    late ProviderContainer container;

    setUpAll(registerMocktailFallbackValues);

    setUp(() async {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      rig = FakeRig()..runGate = Completer<void>();
      final backend = MockBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<bridge_event.SkotiqEvent>.empty());
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
          endOfNightCalibrationProvider.overrideWith(
            (ref) => EndOfNightCalibrationService(
              rig,
              () => EonSettings.load(ref.read(settingsDaoProvider)),
            ),
          ),
        ],
      );
      container.read(endOfNightCalibrationCoordinatorProvider);
    });

    tearDown(() async {
      if (!rig.runGate!.isCompleted) rig.runGate!.complete();
      container.dispose();
      await db.close();
    });

    Future<void> recordRunFrame(int runId, String frameType) async {
      await ImagesDao(db).insertSequenceFrame(
        filePath: '/n/$frameType-$runId.fits',
        fileName: '$frameType-$runId.fits',
        fileFormat: 'fits',
        exposureDuration: 90,
        capturedAt: DateTime.now(),
        isAccepted: true,
        producingNodeId: 'node',
        producingRunId: '$runId',
        frameType: frameType,
      );
    }

    void finishRun(int generation, int runId, String status) {
      container
          .read(sequenceTerminalRunResultProvider.notifier)
          .state = SequenceTerminalRunResult(
        generation: generation,
        outcome: SequenceExecutionState.completed,
        runStatus: status,
        runId: runId,
        dbSessionId: null,
      );
    }

    Future<void> settle() async {
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    Future<void> enable(bool on) => container
        .read(settingsDaoProvider)
        .setSetting(EonSettings.enabledKey, '$on');

    test('a completed imaging run starts the step when it is on', () async {
      await enable(true);
      await recordRunFrame(7, 'light');
      finishRun(1, 7, 'completed');
      await settle();
      expect(rig.calls, contains('run'));
      expect(
        container.read(endOfNightCalibrationProvider).report?.reason,
        EonEndReason.targetsComplete.description,
      );
    });

    test('nothing starts while the setting is off', () async {
      await enable(false);
      await recordRunFrame(7, 'light');
      finishRun(1, 7, 'completed');
      await settle();
      expect(rig.calls, isEmpty);
    });

    test('a run that took no lights does not start it', () async {
      await enable(true);
      await recordRunFrame(8, 'dark');
      finishRun(1, 8, 'completed');
      await settle();
      expect(rig.calls, isEmpty);
    });

    test('an operator stop does not start it; the dawn trigger does', () async {
      await enable(true);
      await recordRunFrame(9, 'light');
      container.read(sequenceStopEvidenceProvider.notifier).state =
          const SequenceStopDecision(SequenceStopAuthor.operatorPress);
      finishRun(1, 9, 'stopped');
      await settle();
      expect(rig.calls, isEmpty);

      container
          .read(sequenceStopEvidenceProvider.notifier)
          .state = const SequenceStopDecision(
        SequenceStopAuthor.system,
        origin: 'dawn_approaching',
        parked: true,
      );
      finishRun(2, 9, 'stopped');
      await settle();
      expect(rig.calls, contains('run'));
    });

    test('the dawn park, filed as aborted, starts it', () async {
      await enable(true);
      await recordRunFrame(10, 'light');
      container
          .read(sequenceStopEvidenceProvider.notifier)
          .state = const SequenceStopDecision(
        SequenceStopAuthor.system,
        origin: 'dawn_approaching',
        parked: true,
      );
      finishRun(1, 10, 'aborted');
      await settle();
      expect(rig.calls, contains('run'));
      expect(
        container.read(endOfNightCalibrationProvider).report?.reason,
        EonEndReason.dawn.description,
      );
    });

    test('the night settles only after the calibration it started', () async {
      await enable(true);
      await recordRunFrame(11, 'light');
      final coordinator = container.read(
        endOfNightCalibrationCoordinatorProvider,
      );
      finishRun(1, 11, 'completed');
      expect(await coordinator.runEnded(1), EonEndReason.targetsComplete);
      var settled = false;
      unawaited(coordinator.nightSettled(1).then((_) => settled = true));
      await settle();
      expect(rig.calls, contains('run'));
      expect(settled, isFalse, reason: 'the calibration run is still going');
      rig.runGate!.complete();
      await settle();
      expect(settled, isTrue);
    });

    test('an operator stop settles at once as not ending the night', () async {
      await enable(true);
      await recordRunFrame(12, 'light');
      container.read(sequenceStopEvidenceProvider.notifier).state =
          const SequenceStopDecision(SequenceStopAuthor.operatorPress);
      final coordinator = container.read(
        endOfNightCalibrationCoordinatorProvider,
      );
      finishRun(1, 12, 'stopped');
      expect(await coordinator.runEnded(1), isNull);
      await coordinator.nightSettled(1);
      expect(rig.calls, isEmpty);
    });

    test('a run that deferred its warm-up hands it to the step', () async {
      await enable(true);
      await recordRunFrame(13, 'light');
      container.read(shutdownWarmUpDeferredProvider.notifier).state = true;
      final coordinator = container.read(
        endOfNightCalibrationCoordinatorProvider,
      );
      finishRun(1, 13, 'completed');
      await settle();
      rig.runGate!.complete();
      await coordinator.nightSettled(1);
      expect(rig.calls, containsAllInOrder(['run', 'warmUp']));
      expect(container.read(shutdownWarmUpDeferredProvider), isFalse);
    });

    test('a deferred warm-up happens when the step cannot run', () async {
      await enable(true);
      // No light frames: the step does not start.
      await recordRunFrame(14, 'dark');
      container.read(shutdownWarmUpDeferredProvider.notifier).state = true;
      final coordinator = container.read(
        endOfNightCalibrationCoordinatorProvider,
      );
      finishRun(1, 14, 'completed');
      await coordinator.nightSettled(1);
      expect(rig.calls, isNot(contains('run')));
      expect(rig.calls, contains('warmUp'));
    });

    test('a manual run after an operator stop queues the night', () async {
      await enable(true);
      await recordRunFrame(15, 'light');
      container.read(sequenceStopEvidenceProvider.notifier).state =
          const SequenceStopDecision(SequenceStopAuthor.operatorPress);
      final coordinator = container.read(
        endOfNightCalibrationCoordinatorProvider,
      );
      container
          .read(sequenceTerminalRunResultProvider.notifier)
          .state = const SequenceTerminalRunResult(
        generation: 1,
        outcome: SequenceExecutionState.idle,
        runStatus: 'stopped',
        runId: 15,
        dbSessionId: 40,
      );
      await coordinator.nightSettled(1);
      expect(container.read(nightIntegrationRequestProvider), isNull);

      rig.runGate!.complete();
      await coordinator.runNow();
      expect(container.read(nightIntegrationRequestProvider)?.sessionId, 40);

      // The night is handed over once.
      await coordinator.runNow();
      expect(container.read(nightIntegrationRequestProvider)?.generation, 1);
    });

    test('another feature ending the night starts it', () async {
      await enable(true);
      final started = await container
          .read(endOfNightCalibrationCoordinatorProvider)
          .imagingEnded(EonEndReason.obstruction);
      await settle();
      expect(started, isTrue);
      expect(rig.calls, contains('run'));
    });
  });
}
