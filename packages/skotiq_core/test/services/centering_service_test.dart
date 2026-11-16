// Manual centering through the sequence's Center step: what the app asks the
// step for, and how the step's progress and end reach the caller. The step
// itself (frames, solves, sync, correction slews, the guider) is tested in
// the native sequencer.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart'
    show ApiCenteringRequest, ApiCenteringStep;
import 'package:skotiq_core/backend.dart' show HostPointing;
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_remote_protocol/wire_models.dart' show RemoteJob;

import '../harness/in_memory_database.dart';

/// A Center step that plays [steps] and records what it was asked.
class _ScriptedRunner implements CenteringRunner {
  _ScriptedRunner(this.steps);

  final List<ApiCenteringStep> steps;
  final requests = <ApiCenteringRequest>[];
  final _cancelled = Completer<void>();
  bool holdBeforeEnd = false;

  @override
  Stream<ApiCenteringStep> center(ApiCenteringRequest request) async* {
    requests.add(request);
    for (final step in steps) {
      yield step;
    }
    if (holdBeforeEnd) {
      await _cancelled.future;
      yield const ApiCenteringStep.finished(
        centered: false,
        cancelled: true,
        message: 'Center cancelled',
      );
    }
  }

  @override
  Future<void> cancel() async {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// A linked host whose centering job starts and then ends as [ending].
class _Host implements HostPointing {
  _Host(this.ending);

  final RemoteJob ending;
  final starts = <Map<String, Object>>[];
  final cancelled = <String>[];

  @override
  Future<String> startCentering({
    required double raHours,
    required double decDegrees,
    required int maxAttempts,
    required double accuracyArcsec,
    required double exposureSecs,
    required bool syncMount,
  }) async {
    starts.add({'ra': raHours, 'dec': decDegrees, 'sync': syncMount});
    return 'job-1';
  }

  @override
  Future<RemoteJob> awaitJobCompletion(
    String jobId, {
    Duration timeout = const Duration(minutes: 10),
    Duration pollInterval = const Duration(seconds: 5),
  }) async => ending;

  @override
  Future<void> cancelJob(String jobId) async => cancelled.add(jobId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late ProviderContainer container;

  ProviderContainer containerFor(CenteringRunner runner) {
    container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        centeringRunnerProvider.overrideWithValue(runner),
        cameraStateProvider.overrideWith((ref) {
          final notifier = CameraStateNotifier(ref);
          notifier.setConnecting('test_camera', 'Test Camera');
          notifier.setConnected();
          return notifier;
        }),
        mountStateProvider.overrideWith((ref) {
          final notifier = MountStateNotifier(ref);
          notifier.setConnecting('test_mount');
          notifier.setConnected();
          return notifier;
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  const solvedOff = ApiCenteringStep.solved(
    attempt: 1,
    raHours: 10.0,
    decDegrees: 45.1,
    separationArcsec: 360,
  );
  const solvedOn = ApiCenteringStep.solved(
    attempt: 2,
    raHours: 10.0,
    decDegrees: 45.0,
    separationArcsec: 4,
  );

  test('the step is asked to center on the target with the config', () async {
    final runner = _ScriptedRunner(const [
      ApiCenteringStep.finished(centered: true, cancelled: false, message: ''),
    ]);
    await containerFor(runner)
        .read(centeringServiceProvider)
        .centerOnTarget(
          targetRa: 10,
          targetDec: 45,
          config: const CenteringConfig(
            maxIterations: 4,
            toleranceArcsec: 12,
            exposureTime: 2,
            syncMount: false,
          ),
        );

    final request = runner.requests.single;
    expect(request.mountId, 'test_mount');
    expect(request.cameraId, 'test_camera');
    expect((request.raHours, request.decDegrees), (10.0, 45.0));
    expect(request.maxAttempts, 4);
    expect(request.accuracyArcsec, 12);
    expect(request.exposureSecs, 2);
    expect(request.syncMount, isFalse);
  });

  test(
    'each solved attempt joins the history and the end is the result',
    () async {
      final runner = _ScriptedRunner(const [
        ApiCenteringStep.capturing(attempt: 1),
        solvedOff,
        ApiCenteringStep.correcting(attempt: 1),
        ApiCenteringStep.capturing(attempt: 2),
        solvedOn,
        ApiCenteringStep.finished(
          centered: true,
          cancelled: false,
          message: 'Centered within 4.0" after 2 attempts',
        ),
      ]);
      final statuses = <CenteringStatus>[];
      final result = await containerFor(runner)
          .read(centeringServiceProvider)
          .centerOnTarget(
            targetRa: 10,
            targetDec: 45,
            onStatusUpdate: statuses.add,
          );

      expect(result.success, isTrue);
      expect(result.iterations, 2);
      expect(result.finalOffsetArcsec, 4);
      expect(result.iterationHistory.map((i) => i.offsetArcsec), [360, 4]);
      expect(statuses.map((s) => s.state), [
        CenteringState.exposing,
        CenteringState.verifying,
        CenteringState.slewing,
        CenteringState.exposing,
        CenteringState.verifying,
        CenteringState.completed,
      ]);
      expect(statuses[1].currentOffsetArcmin, 6);
    },
  );

  test('a step that gives up ends in a failure saying why', () async {
    final runner = _ScriptedRunner(const [
      solvedOff,
      ApiCenteringStep.finished(
        centered: false,
        cancelled: false,
        message: 'Failed to center within 30.0" after 5 attempts',
      ),
    ]);
    final result = await containerFor(runner)
        .read(centeringServiceProvider)
        .centerOnTarget(targetRa: 10, targetDec: 45);

    expect(result.success, isFalse);
    expect(result.errorMessage, contains('Failed to center'));
    expect(result.iterationHistory, hasLength(1));
  });

  test('Stop cancels the step and the run ends as aborted', () async {
    final runner = _ScriptedRunner(const [
      ApiCenteringStep.capturing(attempt: 1),
    ])..holdBeforeEnd = true;
    final service = containerFor(runner).read(centeringServiceProvider);
    final run = service.centerOnTarget(targetRa: 10, targetDec: 45);
    await pumpEventQueue();
    expect(service.isRunning, isTrue);

    await service.stop();
    final result = await run;

    expect(result.success, isFalse);
    expect(result.errorMessage, 'Aborted by user');
    expect(service.isRunning, isFalse);
  });

  test('a second centering while one runs is refused', () async {
    final runner = _ScriptedRunner(const [])..holdBeforeEnd = true;
    final service = containerFor(runner).read(centeringServiceProvider);
    final first = service.centerOnTarget(targetRa: 10, targetDec: 45);
    await pumpEventQueue();

    final second = await service.centerOnTarget(targetRa: 11, targetDec: 40);
    expect(second.errorMessage, contains('already running'));
    expect(runner.requests, hasLength(1));

    await service.stop();
    await first;
  });

  test('a run past its overall timeout is cancelled and says so', () async {
    final runner = _ScriptedRunner(const [])..holdBeforeEnd = true;
    final result = await containerFor(runner)
        .read(centeringServiceProvider)
        .centerOnTarget(
          targetRa: 10,
          targetDec: 45,
          config: const CenteringConfig(
            overallTimeout: Duration(milliseconds: 50),
          ),
        );

    expect(result.success, isFalse);
    expect(result.errorMessage, contains('timed out'));
  });

  test('an impossible target is refused before the step is asked', () async {
    final runner = _ScriptedRunner(const []);
    final result = await containerFor(runner)
        .read(centeringServiceProvider)
        .centerOnTarget(targetRa: 25, targetDec: 45);

    expect(result.success, isFalse);
    expect(runner.requests, isEmpty);
  });

  test(
    'a mount that is not connected is refused before the step is asked',
    () async {
      final runner = _ScriptedRunner(const []);
      container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          centeringRunnerProvider.overrideWithValue(runner),
          mountStateProvider.overrideWith((ref) {
            final notifier = MountStateNotifier(ref);
            notifier.setConnecting('test_mount');
            return notifier;
          }),
        ],
      );
      addTearDown(container.dispose);

      final result = await container
          .read(centeringServiceProvider)
          .centerOnTarget(targetRa: 10, targetDec: 45);

      expect(result.errorMessage, 'Mount not connected');
      expect(runner.requests, isEmpty);
    },
  );

  group('on a linked client the host centers', () {
    test('a host job that converged reads as its solved attempts and a '
        'success', () async {
      final host = _Host(
        const RemoteJob(
          jobId: 'job-1',
          operation: 'framing.center-on-target',
          state: 'succeeded',
          result: {
            'success': true,
            'iterationHistory': [
              {
                'iterationNumber': 1,
                'solvedRa': 10.0,
                'solvedDec': 45.1,
                'offsetArcsec': 360.0,
              },
              {
                'iterationNumber': 2,
                'solvedRa': 10.0,
                'solvedDec': 45.0,
                'offsetArcsec': 4.0,
              },
            ],
          },
        ),
      );
      final result = await containerFor(HostCenteringRunner(host))
          .read(centeringServiceProvider)
          .centerOnTarget(
            targetRa: 10,
            targetDec: 45,
            config: const CenteringConfig(syncMount: false),
          );

      expect(host.starts.single, {'ra': 10.0, 'dec': 45.0, 'sync': false});
      expect(result.success, isTrue);
      expect(result.iterations, 2);
      expect(result.finalOffsetArcsec, 4);
    });

    test('a host job that failed carries the host\'s reason', () async {
      final runner = HostCenteringRunner(
        _Host(
          const RemoteJob(
            jobId: 'job-1',
            operation: 'framing.center-on-target',
            state: 'failed',
            error: {
              'message': 'Failed to center within 30.0" after 5 attempts',
              'details': {'iterationHistory': <Object>[]},
            },
          ),
        ),
      );
      final result = await containerFor(runner)
          .read(centeringServiceProvider)
          .centerOnTarget(targetRa: 10, targetDec: 45);

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('Failed to center'));
    });
  });
}
