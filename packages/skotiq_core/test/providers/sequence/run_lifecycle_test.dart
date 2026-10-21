// RunLifecycle owns the executor's run phase. Every transition is checked
// against the phase it starts from; these pin the legal paths and that the
// illegal ones are rejected rather than silently applied.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

RunFinalization _finalization(
  RunLifecycle lifecycle, {
  String runStatus = 'completed',
  bool nativeStopRequired = false,
  String? stopOrigin,
}) => RunFinalization(
  generation: lifecycle.nextGeneration(),
  runStatus: runStatus,
  finalUiState: SequenceExecutionState.completed,
  runId: 1,
  dbSessionId: 2,
  preserveCheckpoint: false,
  nativeStopRequired: nativeStopRequired,
  nativeStopConfirmed: !nativeStopRequired,
  publishTerminalResult: true,
  discardCheckpointOnSuccess: false,
  isRollback: false,
  stopOrigin: stopOrigin,
);

Matcher _illegal(String transition) => throwsA(
  isA<IllegalRunTransition>().having(
    (e) => e.message,
    'message',
    contains('"$transition"'),
  ),
);

void main() {
  late RunLifecycle lifecycle;

  setUp(() => lifecycle = RunLifecycle());

  test('starts idle, with no finalization, drive or end origin', () {
    expect(lifecycle.phase, isA<RunIdle>());
    expect(lifecycle.finalization, isNull);
    expect(lifecycle.drive, isNull);
    expect(lifecycle.lastRunEndOrigin, isNull);
    expect(lifecycle.isPausedByExecutor, isFalse);
  });

  test('the launch path: Idle -> Launching -> Launching(native) -> Live', () {
    lifecycle.beginLaunch();
    expect(
      lifecycle.phase,
      isA<RunLaunching>().having(
        (p) => p.nativeLaunchAttempted,
        'native',
        false,
      ),
    );
    lifecycle.markNativeLaunchAttempted();
    expect(
      lifecycle.phase,
      isA<RunLaunching>().having(
        (p) => p.nativeLaunchAttempted,
        'native',
        true,
      ),
    );
    lifecycle.launchSucceeded();
    expect(lifecycle.phase, isA<RunLive>());
  });

  test('Live pauses and resumes; only a live run can', () {
    expect(() => lifecycle.setPaused(true), _illegal('setPaused(true)'));
    lifecycle
      ..beginLaunch()
      ..launchSucceeded();
    lifecycle.setPaused(true);
    expect(lifecycle.isPausedByExecutor, isTrue);
    lifecycle.setPaused(false);
    expect(lifecycle.isPausedByExecutor, isFalse);
  });

  test('a launch cannot begin while one is live, launching or finalizing', () {
    lifecycle.beginLaunch();
    expect(lifecycle.beginLaunch, _illegal('beginLaunch'));
    lifecycle.launchSucceeded();
    expect(lifecycle.beginLaunch, _illegal('beginLaunch'));
    lifecycle.claim(_finalization(lifecycle));
    expect(lifecycle.beginLaunch, _illegal('beginLaunch'));
  });

  test('the native launch boundary exists only inside a launch', () {
    expect(
      lifecycle.markNativeLaunchAttempted,
      _illegal('markNativeLaunchAttempted'),
    );
    lifecycle
      ..beginLaunch()
      ..claim(_finalization(lifecycle));
    expect(
      lifecycle.markNativeLaunchAttempted,
      _illegal('markNativeLaunchAttempted'),
    );
  });

  test('a launch that a terminal already claimed stays claimed', () {
    lifecycle.beginLaunch();
    final f = _finalization(lifecycle);
    lifecycle.claim(f);
    lifecycle.launchSucceeded();
    expect(lifecycle.finalization, same(f));
    expect(() => RunLifecycle().launchSucceeded(), _illegal('launchSucceeded'));
  });

  test('a run has exactly one finalization: a second claim is rejected', () {
    final first = _finalization(lifecycle);
    lifecycle.claim(first);
    expect(() => lifecycle.claim(_finalization(lifecycle)), _illegal('claim'));
    expect(lifecycle.finalization, same(first));
  });

  test('a drive is joined while in flight, retained when it fails, and '
      'settles the run when it succeeds', () {
    final f = _finalization(lifecycle, stopOrigin: 'scheduler');
    lifecycle.claim(f);
    final first = Completer<void>().future;
    lifecycle.driveStarted(f, first);
    expect(lifecycle.drive, same(first));
    expect(
      () => lifecycle.driveStarted(f, Completer<void>().future),
      _illegal('driveStarted'),
      reason: 'two drives of one finalization must never run at once',
    );

    lifecycle.driveEnded(f, first);
    expect(lifecycle.phase, isA<RunFinalizing>());
    expect(lifecycle.drive, isNull, reason: 'retained for a Stop retry');
    expect(lifecycle.finalization, same(f));

    final retry = Completer<void>().future;
    lifecycle.driveStarted(f, retry);
    lifecycle.settle(f, endOrigin: 'scheduler');
    expect(
      lifecycle.phase,
      isA<RunSettled>().having((p) => p.runStatus, 'status', 'completed'),
    );
    expect(lifecycle.lastRunEndOrigin, 'scheduler');
    // The drive's completion after it settled the run changes nothing.
    lifecycle.driveEnded(f, retry);
    expect(lifecycle.phase, isA<RunSettled>());
  });

  test('only the claimed finalization can drive or settle the run', () {
    final f = _finalization(lifecycle);
    final stranger = _finalization(lifecycle);
    lifecycle.claim(f);
    expect(
      () => lifecycle.driveStarted(stranger, Completer<void>().future),
      _illegal('driveStarted'),
    );
    expect(() => lifecycle.settle(stranger), _illegal('settle'));
    expect(() => RunLifecycle().settle(f), _illegal('settle'));
  });

  test('a settled run accepts no new claim until it is released', () {
    final f = _finalization(lifecycle);
    lifecycle
      ..claim(f)
      ..settle(f);
    expect(() => lifecycle.claim(_finalization(lifecycle)), _illegal('claim'));
    expect(lifecycle.releaseSettled(), isTrue);
    expect(lifecycle.phase, isA<RunIdle>());
    expect(lifecycle.releaseSettled(), isFalse);
    lifecycle.claim(_finalization(lifecycle));
    expect(lifecycle.phase, isA<RunFinalizing>());
  });

  test(
    'a settled run can launch again; the end origin outlives the launch',
    () {
      final f = _finalization(lifecycle, nativeStopRequired: true);
      lifecycle
        ..claim(f)
        ..settle(f, endOrigin: 'operator')
        ..beginLaunch();
      expect(lifecycle.phase, isA<RunLaunching>());
      expect(lifecycle.lastRunEndOrigin, 'operator');
    },
  );

  test('attaching a native run: Idle and Settled become Live, every other '
      'phase keeps its run', () {
    expect(lifecycle.attachNativeRun(), isFalse);
    expect(lifecycle.phase, isA<RunLive>());

    final settled = RunLifecycle();
    final f = _finalization(settled);
    settled
      ..claim(f)
      ..settle(f);
    expect(settled.attachNativeRun(), isTrue, reason: 'released the verdict');
    expect(settled.phase, isA<RunLive>());

    final retained = RunLifecycle();
    final g = _finalization(retained);
    retained.claim(g);
    expect(retained.attachNativeRun(), isFalse);
    expect(retained.finalization, same(g));

    final launching = RunLifecycle()..beginLaunch();
    expect(launching.attachNativeRun(), isFalse);
    expect(launching.phase, isA<RunLaunching>());
  });

  test('generations are never reused', () {
    final a = lifecycle.nextGeneration();
    final b = lifecycle.nextGeneration();
    expect(b, greaterThan(a));
  });

  test('a latch admits one holder at a time', () {
    final latch = lifecycle.launch;
    latch.acquire();
    expect(latch.isHeld, isTrue);
    expect(latch.acquire, throwsStateError);
    latch.release();
    expect(latch.isHeld, isFalse);
    latch.acquire();
    expect(lifecycle.pauseResume.isHeld, isFalse, reason: 'independent');
  });
}
