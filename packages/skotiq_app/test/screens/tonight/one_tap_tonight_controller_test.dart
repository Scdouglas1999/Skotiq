import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/tonight/one_tap_tonight_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart' as planetarium;

/// Controller-level test of the one-tap chain (pick -> frame -> plan -> GO)
/// using fake service seams. No DB / network / native bridge — the chain logic
/// and its phase/error transitions are exercised in isolation, mirroring the
/// fake-service contract used by `smart_night_plan_launcher_test.dart`.
void main() {
  TargetSuggestion suggestion() => const TargetSuggestion(
        targetId: 42,
        targetName: 'M51',
        catalogId: 'M51',
        raHours: 13.5,
        decDegrees: 47.2,
        totalScore: 91,
        objectType: 'Galaxy',
        reasoning: 'Excellent altitude tonight.',
        visibility: planetarium.TargetVisibilityInfo(
          currentAltitude: 72,
          currentAzimuth: 180,
          transitAltitude: 78,
          peakAltitude: 78,
          hoursAboveMinAlt: 5,
          airmass: 1.1,
          moonDistance: 100,
        ),
      );

  SingleTargetSequenceResult result(TargetSuggestion target) {
    final header = TargetHeaderNode(
      id: 'target',
      name: target.targetName,
      targetName: target.targetName,
      raHours: target.raHours,
      decDegrees: target.decDegrees,
    );
    final sequence = Sequence.create(
      id: 'one-tap-${target.targetName}',
      name: 'Smart Night ${target.targetName}',
      rootNodeId: header.id,
      nodes: {header.id: header},
    );
    return SingleTargetSequenceResult(
      sequence: sequence,
      strategy: SmartNightStrategy.autoLrgb,
      filterPlans: const [],
      plannedTarget: SmartNightPlannedTarget(
        suggestion: target,
        windowStart: DateTime(2026, 5, 22, 21),
        windowEnd: DateTime(2026, 5, 23, 5),
        filterPlans: const [],
        integrationSecs: 0,
        rationale: 'Seeded test target.',
      ),
    );
  }

  test('go() runs the full chain in order and ends running', () async {
    final calls = <String>[];
    final target = suggestion();
    TargetSuggestion? framedWith;
    SingleTargetSequenceResult? ranWith;

    final controller = OneTapTonightController(
      pick: () async {
        calls.add('pick');
        return target;
      },
      frame: (t) {
        calls.add('frame');
        framedWith = t;
      },
      plan: (t) async {
        calls.add('plan');
        return result(t);
      },
      run: (p) async {
        calls.add('run');
        ranWith = p;
      },
    );
    addTearDown(controller.dispose);

    await controller.go();

    // The four phases fired exactly once, in dependency order.
    expect(calls, ['pick', 'frame', 'plan', 'run']);
    expect(controller.state.phase, OneTapPhase.running);
    expect(controller.state.target, target);
    expect(framedWith, target);
    expect(ranWith?.sequence.name, 'Smart Night M51');
    expect(controller.state.error, isNull);
  });

  test('go() surfaces a loud failure when nothing is imageable', () async {
    var planCalled = false;
    final controller = OneTapTonightController(
      pick: () async => null,
      frame: (_) => fail('frame must not run without a target'),
      plan: (_) async {
        planCalled = true;
        return result(suggestion());
      },
      run: (_) async => fail('run must not run without a plan'),
    );
    addTearDown(controller.dispose);

    await controller.go();

    expect(controller.state.phase, OneTapPhase.failed);
    expect(controller.state.error, isNotNull);
    expect(planCalled, isFalse);
  });

  test('go() stops at planning and never starts a run when the build fails',
      () async {
    var ranCalled = false;
    final controller = OneTapTonightController(
      pick: () async => suggestion(),
      frame: (_) {},
      plan: (_) async => throw const SmartNightBuildException(
        'No filters configured on the equipment profile.',
      ),
      run: (_) async => ranCalled = true,
    );
    addTearDown(controller.dispose);

    await controller.go();

    expect(controller.state.phase, OneTapPhase.failed);
    expect(
      controller.state.error,
      contains('No filters configured'),
    );
    expect(ranCalled, isFalse);
  });

  test('a failed run re-arms via reset() then re-runs cleanly', () async {
    var pickCount = 0;
    final target = suggestion();
    final controller = OneTapTonightController(
      pick: () async {
        pickCount++;
        if (pickCount == 1) return null; // first attempt: nothing imageable
        return target; // retry: sky cleared
      },
      frame: (_) {},
      plan: (t) async => result(t),
      run: (_) async {},
    );
    addTearDown(controller.dispose);

    await controller.go();
    expect(controller.state.phase, OneTapPhase.failed);

    controller.reset();
    expect(controller.state.phase, OneTapPhase.idle);
    expect(controller.state.error, isNull);

    await controller.go();
    expect(controller.state.phase, OneTapPhase.running);
    expect(controller.state.target, target);
    expect(pickCount, 2);
  });

  test('go() swallows its post-await publish after dispose mid-run', () async {
    final runGate = Completer<void>();
    final controller = OneTapTonightController(
      pick: () async => suggestion(),
      frame: (_) {},
      plan: (t) async => result(t),
      run: (_) => runGate.future,
    );

    final chain = controller.go();
    // Drain the chain up to the awaited run.
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.phase, OneTapPhase.starting);

    // The screen navigates away while the run is still awaiting; the trailing
    // `value = running` must be swallowed, not thrown on a disposed notifier.
    controller.dispose();
    runGate.complete();

    await expectLater(chain, completes);
    expect(controller.state.phase, OneTapPhase.starting);
  });

  test('go() is a no-op while a chain is already busy', () async {
    final gate = Completer<TargetSuggestion?>();
    var pickStarts = 0;
    final controller = OneTapTonightController(
      pick: () {
        pickStarts++;
        return gate.future;
      },
      frame: (_) {},
      plan: (t) async => result(t),
      run: (_) async {},
    );
    addTearDown(controller.dispose);

    final first = controller.go();
    expect(controller.state.phase, OneTapPhase.picking);

    // Second tap while the first is mid-flight must not start a new chain.
    await controller.go();
    expect(pickStarts, 1);

    gate.complete(suggestion());
    await first;
    expect(controller.state.phase, OneTapPhase.running);
  });
}
