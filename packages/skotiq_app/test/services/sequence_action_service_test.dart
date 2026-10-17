// Unit tests for SequenceActionService's shared single-flight latch.
//
// Every playback surface (desktop toolbar, mobile playback bar, dashboard
// cockpit strip, app-shell mini bar) routes through ONE app-scoped
// SequenceActionService, and two of those surfaces are on screen at once during
// a run (the dashboard renders both the cockpit strip and the mini bar). These
// tests pin that a second concurrent call of the SAME command joins the
// in-flight future instead of issuing a duplicate backend command — so a stray
// double-press can't double-advance the node pointer (skip has no executor-side
// guard), start twice, or bounce off the executor's pause/resume latch with a
// "already in progress" error. They also pin skip's canSkip precheck so a skip
// dispatched after the run has ended is a truthful silent no-op, not a false
// "Skipped current item".

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/models/command_action_result.dart';
import 'package:skotiq_app/services/sequence_action_service.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// A [SequenceExecutor] stand-in that only records the playback calls the
/// service makes and lets each be parked on a [Completer] so a test can hold a
/// command "in flight" while it races a second call. Every other executor
/// member keeps its (unused) base implementation.
class _RecordingExecutor extends SequenceExecutor {
  _RecordingExecutor(super.ref);

  int startCount = 0;
  int pauseCount = 0;
  int resumeCount = 0;
  int stopCount = 0;
  int skipCount = 0;
  int resetCount = 0;
  bool? lastStopPreserveCheckpoint;

  Completer<void>? startGate;
  Completer<void>? pauseGate;
  Completer<void>? stopGate;
  Completer<void>? skipGate;

  @override
  Future<void> start() async {
    startCount++;
    if (startGate != null) await startGate!.future;
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    if (pauseGate != null) await pauseGate!.future;
  }

  @override
  Future<void> resume() async {
    resumeCount++;
  }

  @override
  Future<void> stop({bool preserveCheckpoint = false, String? origin}) async {
    stopCount++;
    lastStopPreserveCheckpoint = preserveCheckpoint;
    if (stopGate != null) await stopGate!.future;
  }

  @override
  Future<void> skip() async {
    skipCount++;
    if (skipGate != null) await skipGate!.future;
  }

  @override
  Future<void> reset() async {
    resetCount++;
  }
}

({
  ProviderContainer container,
  SequenceActionService service,
  _RecordingExecutor executor,
}) _harness({
  SequenceExecutionState state = SequenceExecutionState.running,
}) {
  late _RecordingExecutor executor;
  final container = ProviderContainer(overrides: [
    inMemoryDatabaseOverride(),
    sequenceExecutorProvider.overrideWith((ref) {
      executor = _RecordingExecutor(ref);
      return executor;
    }),
    sequenceExecutionStateProvider.overrideWith((ref) => state),
  ]);
  // Force the executor override to build so `executor` is captured before any
  // command runs.
  container.read(sequenceExecutorProvider);
  final service = container.read(sequenceActionServiceProvider);
  return (container: container, service: service, executor: executor);
}

void main() {
  test(
      'concurrent skip() issues exactly one native skip and both callers get '
      'the same success', () async {
    final h = _harness(state: SequenceExecutionState.running);
    addTearDown(h.container.dispose);
    final gate = Completer<void>();
    h.executor.skipGate = gate;

    final f1 = h.service.skip();
    final f2 = h.service.skip();

    // The second caller joined the first's in-flight future — one native skip.
    expect(h.executor.skipCount, 1);

    gate.complete();
    final r1 = await f1;
    final r2 = await f2;
    expect(r1.isSuccess, isTrue);
    expect(r2.isSuccess, isTrue);
    expect(h.executor.skipCount, 1);

    // Latch cleared once settled: a fresh press issues a new native skip.
    await h.service.skip();
    expect(h.executor.skipCount, 2);
  });

  test('skip() is a silent no-op when the run is not in a skippable state',
      () async {
    final h = _harness(state: SequenceExecutionState.completed);
    addTearDown(h.container.dispose);

    final result = await h.service.skip();

    // Truthful: no native skip issued, and no false "Skipped current item".
    expect(h.executor.skipCount, 0);
    expect(result.isSuccess, isTrue);
    expect(result.hasMessage, isFalse);
  });

  test('concurrent start() issues exactly one executor start', () async {
    final h = _harness(state: SequenceExecutionState.idle);
    addTearDown(h.container.dispose);
    final gate = Completer<void>();
    h.executor.startGate = gate;

    final f1 = h.service.start();
    final f2 = h.service.start();
    expect(h.executor.startCount, 1);

    gate.complete();
    await Future.wait<CommandActionResult>([f1, f2]);
    expect(h.executor.startCount, 1);
  });

  test('stop waits for in-flight start acquisition before stopping', () async {
    final h = _harness(state: SequenceExecutionState.idle);
    addTearDown(h.container.dispose);
    final gate = Completer<void>();
    h.executor.startGate = gate;

    final start = h.service.start();
    // The real executor publishes running during acquisition, exposing Stop
    // on the other playback surfaces before start() has returned.
    h.container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.running;
    final stop = h.service.stop();

    expect(h.executor.stopCount, 0);
    gate.complete();
    await start;
    await stop;
    expect(h.executor.stopCount, 1);
  });

  test(
      'concurrent pause() joins — one executor pause, both callers succeed '
      '(no "already in progress" error)', () async {
    final h = _harness(state: SequenceExecutionState.running);
    addTearDown(h.container.dispose);
    final gate = Completer<void>();
    h.executor.pauseGate = gate;

    final f1 = h.service.pause();
    final f2 = h.service.pause();
    expect(h.executor.pauseCount, 1);

    gate.complete();
    final r1 = await f1;
    final r2 = await f2;
    expect(r1.isSuccess, isTrue);
    expect(r2.isSuccess, isTrue);
  });

  test(
      'stop() defaults to preserveCheckpoint:true and joined callers do not '
      'duplicate the native stop (first caller intent wins)', () async {
    final h = _harness(state: SequenceExecutionState.running);
    addTearDown(h.container.dispose);
    final gate = Completer<void>();
    h.executor.stopGate = gate;

    // A UI Stop (preserve default true) races a discard-and-stop (preserve
    // false). The second joins the first, so only one native stop is issued and
    // it carries the FIRST caller's checkpoint intent.
    final f1 = h.service.stop();
    final f2 = h.service.stop(preserveCheckpoint: false);
    expect(h.executor.stopCount, 1);
    expect(h.executor.lastStopPreserveCheckpoint, isTrue);

    gate.complete();
    await Future.wait<CommandActionResult>([f1, f2]);
    expect(h.executor.stopCount, 1);
  });
}
