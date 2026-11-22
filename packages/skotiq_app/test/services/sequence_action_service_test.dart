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
import 'package:skotiq_app/services/command_action_result.dart';
import 'package:skotiq_app/services/sequence_action_service.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// A rule that always finds one warning, for the non-blocking pre-flight.
class _WarnRule extends SequenceValidator {
  @override
  String get name => 'warn';

  @override
  List<ValidationIssue> validate(Sequence sequence) => const [
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.targets,
          title: 'Target sets before the plan ends',
          description: 'test',
        ),
      ];
}

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
  Object? startError;
  Completer<void>? pauseGate;
  Completer<void>? stopGate;
  Completer<void>? skipGate;

  @override
  Future<void> start() async {
    startCount++;
    if (startGate != null) await startGate!.future;
    final error = startError;
    if (error != null) throw error;
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
  List<Override> overrides = const [],
}) {
  late _RecordingExecutor executor;
  final container = ProviderContainer(overrides: [
    inMemoryDatabaseOverride(),
    sequenceExecutorProvider.overrideWith((ref) {
      executor = _RecordingExecutor(ref);
      return executor;
    }),
    runRecordProvider.overrideWith(
      (ref) => RunRecordNotifier(ref, RunRecord(lifecycle: state)),
    ),
    ...overrides,
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
    h.container
        .read(runRecordProvider.notifier)
        .setLifecycle(SequenceExecutionState.running);
    final stop = h.service.stop();

    expect(h.executor.stopCount, 0);
    gate.complete();
    await start;
    await stop;
    expect(h.executor.stopCount, 1);
  });

  test(
      'concurrent pause() joins: one executor pause, both callers succeed '
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

  test(
      'a refused start reaches the operator as an app-wide notification, '
      'even when the Start control that asked is gone', () async {
    final h = _harness(state: SequenceExecutionState.failed);
    addTearDown(h.container.dispose);
    h.executor.startError = Exception(
      'Session already active. End current session before starting a new '
      'one.',
    );

    final result = await h.service.start();

    expect(result.isSuccess, isFalse);
    expect(result.alreadyShown, isTrue);
    final shown = h.container.read(uiNotificationProvider);
    expect(shown, hasLength(1));
    expect(shown.single.level, UiNotificationLevel.error);
    expect(shown.single.title, 'The run did not start');
    expect(shown.single.message, startsWith('Session already active.'));
  });

  group('startOwnedPlan', () {
    Sequence plan(String name) {
      final root = InstructionSetNode(id: 'root-$name', name: name);
      return Sequence.create(
        id: name,
        name: name,
        rootNodeId: root.id,
        nodes: {root.id: root},
      );
    }

    test('closing the pre-flight gives the editor back and starts nothing',
        () async {
      final h = _harness(state: SequenceExecutionState.idle);
      addTearDown(h.container.dispose);
      h.container
          .read(currentSequenceProvider.notifier)
          .loadSequence(plan('Operator'));
      String? checked;

      await expectLater(
        h.service.startOwnedPlan(
          plan('Generated'),
          ActivePlanOwner.smartNight,
          confirm: () async {
            checked = h.container.read(currentSequenceProvider)?.name;
            return false;
          },
        ),
        throwsA(isA<PlanStartCanceled>()),
      );

      expect(checked, 'Generated', reason: 'pre-flight checks the plan');
      expect(h.container.read(currentSequenceProvider)?.name, 'Operator');
      expect(
        h.container.read(activePlanOwnerProvider),
        ActivePlanOwner.manual,
      );
      expect(h.executor.startCount, 0);
    });

    test('a pre-flight that fails gives the editor back', () async {
      final h = _harness(state: SequenceExecutionState.idle);
      addTearDown(h.container.dispose);
      h.container
          .read(currentSequenceProvider.notifier)
          .loadSequence(plan('Operator'));

      await expectLater(
        h.service.startOwnedPlan(
          plan('Generated'),
          ActivePlanOwner.smartNight,
          confirm: () async => throw StateError('dialog failed'),
        ),
        throwsA(isA<StateError>()),
      );

      expect(h.container.read(currentSequenceProvider)?.name, 'Operator');
      expect(
        h.container.read(activePlanOwnerProvider),
        ActivePlanOwner.manual,
      );
      expect(h.executor.startCount, 0);
    });

    test('Start in the pre-flight starts the plan', () async {
      final h = _harness(state: SequenceExecutionState.idle);
      addTearDown(h.container.dispose);
      var asked = 0;

      await h.service.startOwnedPlan(
        plan('Generated'),
        ActivePlanOwner.smartNight,
        confirm: () async {
          asked++;
          return true;
        },
      );

      expect(asked, 1);
      expect(h.executor.startCount, 1);
      expect(h.container.read(currentSequenceProvider)?.name, 'Generated');
      expect(
        h.container.read(activePlanOwnerProvider),
        ActivePlanOwner.smartNight,
      );
    });

    test(
        'a plan started with no screen posts its pre-flight findings and '
        'starts anyway', () async {
      final h = _harness(
        state: SequenceExecutionState.idle,
        overrides: [
          sequenceValidatorProvider.overrideWith(
            (ref) => SequenceValidatorService(
              ref: ref,
              syncRules: [_WarnRule()],
              refAwareRules: const [],
              asyncRules: const [],
            ),
          ),
        ],
      );
      addTearDown(h.container.dispose);

      await h.service.startOwnedPlan(plan('Mosaic'), ActivePlanOwner.mosaic);
      await Future<void>.delayed(Duration.zero);

      expect(h.executor.startCount, 1);
      final shown = h.container.read(uiNotificationProvider);
      expect(
        shown.map((n) => n.message),
        contains('Target sets before the plan ends'),
      );
    });

    test('a run that cannot start leaves the editor as it was', () async {
      final h = _harness(state: SequenceExecutionState.idle);
      addTearDown(h.container.dispose);
      h.executor.startError = StateError('Cannot start');
      h.container
          .read(currentSequenceProvider.notifier)
          .loadSequence(plan('Operator'));
      h.container
          .read(runRecordProvider.notifier)
          .setLifecycle(SequenceExecutionState.running);

      await expectLater(
        h.service.startOwnedPlan(plan('Generated'), ActivePlanOwner.smartNight),
        throwsA(isA<StateError>()),
      );

      expect(h.container.read(currentSequenceProvider)?.name, 'Operator');
      expect(
        h.container.read(activePlanOwnerProvider),
        ActivePlanOwner.manual,
      );
      expect(h.executor.startCount, 0);
    });

    // A flip or a flat capture holding the rig refused the start only after
    // the plan had taken the editor, so the operator's sequence was replaced
    // by a plan that never ran.
    test(
        'a rig another activity holds refuses the plan before it takes the '
        'editor', () async {
      final h = _harness(state: SequenceExecutionState.idle);
      addTearDown(h.container.dispose);
      h.executor.startError = StateError(
        'Cannot start: A meridian flip is using the mount.',
      );
      h.container
          .read(currentSequenceProvider.notifier)
          .loadSequence(plan('Operator'));
      h.container
          .read(flipMonitorProgressProvider.notifier)
          .set(const FlipMonitorProgress(
            state: FlipExecutionState.executing,
            attempt: 1,
            step: null,
            percent: 10,
            error: null,
          ));

      await expectLater(
        h.service.startOwnedPlan(plan('Generated'), ActivePlanOwner.smartNight),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Cannot start: A meridian flip is using the mount.',
          ),
        ),
      );

      expect(h.container.read(currentSequenceProvider)?.name, 'Operator');
      expect(
        h.container.read(activePlanOwnerProvider),
        ActivePlanOwner.manual,
      );
      expect(h.executor.startCount, 0);
    });

    test(
        'a flip that starts while the pre-flight is open gives the editor '
        'back', () async {
      final h = _harness(state: SequenceExecutionState.idle);
      addTearDown(h.container.dispose);
      h.executor.startError = StateError(
        'Cannot start: A meridian flip is using the mount.',
      );
      h.container
          .read(currentSequenceProvider.notifier)
          .loadSequence(plan('Operator'));

      await expectLater(
        h.service.startOwnedPlan(
          plan('Generated'),
          ActivePlanOwner.smartNight,
          confirm: () async {
            h.container.read(flipMonitorProgressProvider.notifier).set(
                  const FlipMonitorProgress(
                    state: FlipExecutionState.executing,
                    attempt: 1,
                    step: null,
                    percent: 0,
                    error: null,
                  ),
                );
            return true;
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(h.container.read(currentSequenceProvider)?.name, 'Operator');
      expect(
        h.container.read(activePlanOwnerProvider),
        ActivePlanOwner.manual,
      );
      expect(h.executor.startCount, 0);
    });

    test('a start already in flight is not replaced by the plan', () async {
      final h = _harness(state: SequenceExecutionState.idle);
      addTearDown(h.container.dispose);
      final gate = Completer<void>();
      h.executor.startGate = gate;
      h.container
          .read(currentSequenceProvider.notifier)
          .loadSequence(plan('Operator'));
      final first = h.service.start();

      await expectLater(
        h.service.startOwnedPlan(plan('Mosaic'), ActivePlanOwner.mosaic),
        throwsA(isA<StateError>()),
      );

      expect(h.container.read(currentSequenceProvider)?.name, 'Operator');
      expect(h.executor.startCount, 1);
      gate.complete();
      expect((await first).isSuccess, isTrue);
    });

    test('a Start pressed while a plan starts joins that start', () async {
      final h = _harness(state: SequenceExecutionState.idle);
      addTearDown(h.container.dispose);
      final gate = Completer<void>();
      h.executor.startGate = gate;

      final owned =
          h.service.startOwnedPlan(plan('Generated'), ActivePlanOwner.mosaic);
      final pressed = h.service.start();
      gate.complete();
      await owned;

      expect((await pressed).isSuccess, isTrue);
      expect(h.executor.startCount, 1);
    });

    test('a refused plan start answers a joined Start with a failure',
        () async {
      final h = _harness(state: SequenceExecutionState.idle);
      addTearDown(h.container.dispose);
      final gate = Completer<void>();
      h.executor
        ..startGate = gate
        ..startError = StateError('validation failed');

      final owned =
          h.service.startOwnedPlan(plan('Generated'), ActivePlanOwner.mosaic);
      final pressed = h.service.start();
      final paused = h.service.pause();
      gate.complete();

      await expectLater(owned, throwsA(isA<StateError>()));
      final result = await pressed;
      expect(result.isSuccess, isFalse);
      expect(result.message, contains('validation failed'));
      expect((await paused).isSuccess, isTrue);
      expect(h.executor.startCount, 1);
    });

    test('an idle executor takes the plan and starts it', () async {
      final h = _harness(state: SequenceExecutionState.idle);
      addTearDown(h.container.dispose);

      await h.service.startOwnedPlan(plan('Generated'), ActivePlanOwner.mosaic);

      expect(h.container.read(currentSequenceProvider)?.name, 'Generated');
      expect(
        h.container.read(activePlanOwnerProvider),
        ActivePlanOwner.mosaic,
      );
      expect(h.executor.startCount, 1);
    });
  });
}
