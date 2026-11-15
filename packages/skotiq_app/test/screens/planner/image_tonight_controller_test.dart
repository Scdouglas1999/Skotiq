import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planner/image_tonight_controller.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_astro/skotiq_astro.dart' as planetarium;

/// The Image tonight chain (check -> frame -> plan -> start) on fake seams: no
/// database, network or native bridge, only the chain's order, phases and
/// failures.
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

    final controller = ImageTonightController(
      preflight: () async {
        calls.add('check');
        return null;
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

    await controller.go(target);

    expect(calls, ['check', 'frame', 'plan', 'run']);
    expect(controller.state.phase, ImageTonightPhase.running);
    expect(controller.state.target, target);
    expect(framedWith, target);
    expect(ranWith?.sequence.name, 'Smart Night M51');
    expect(controller.state.error, isNull);
  });

  test('go() stops at planning and never starts a run when the build fails',
      () async {
    var ranCalled = false;
    final controller = ImageTonightController(
      frame: (_) {},
      plan: (_) async => throw const SmartNightBuildException(
        'No filters configured on the equipment profile.',
      ),
      run: (_) async => ranCalled = true,
    );
    addTearDown(controller.dispose);

    await controller.go(suggestion());

    expect(controller.state.phase, ImageTonightPhase.failed);
    expect(controller.state.error, contains('No filters configured'));
    expect(ranCalled, isFalse);
  });

  test('a failed chain re-arms via reset() then runs cleanly', () async {
    var plans = 0;
    final target = suggestion();
    final controller = ImageTonightController(
      frame: (_) {},
      plan: (t) async {
        plans++;
        if (plans == 1) {
          throw const SmartNightBuildException('No filter wheel connected.');
        }
        return result(t);
      },
      run: (_) async {},
    );
    addTearDown(controller.dispose);

    await controller.go(target);
    expect(controller.state.phase, ImageTonightPhase.failed);

    controller.reset();
    expect(controller.state.phase, ImageTonightPhase.idle);
    expect(controller.state.error, isNull);

    await controller.go(target);
    expect(controller.state.phase, ImageTonightPhase.running);
    expect(controller.state.target, target);
    expect(plans, 2);
  });

  test('go() swallows its post-await publish after dispose mid-run', () async {
    final runGate = Completer<void>();
    final controller = ImageTonightController(
      frame: (_) {},
      plan: (t) async => result(t),
      run: (_) => runGate.future,
    );

    final chain = controller.go(suggestion());
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.phase, ImageTonightPhase.starting);

    // The page goes away while the run is still awaiting; the trailing
    // publish must be swallowed, not thrown on a disposed notifier.
    controller.dispose();
    runGate.complete();

    await expectLater(chain, completes);
    expect(controller.state.phase, ImageTonightPhase.starting);
  });

  test('go() is a no-op while a chain is already busy', () async {
    final gate = Completer<String?>();
    var checks = 0;
    final controller = ImageTonightController(
      preflight: () {
        checks++;
        return gate.future;
      },
      frame: (_) {},
      plan: (t) async => result(t),
      run: (_) async {},
    );
    addTearDown(controller.dispose);

    final first = controller.go(suggestion());
    expect(controller.state.phase, ImageTonightPhase.checking);

    await controller.go(suggestion());
    expect(checks, 1);

    gate.complete(null);
    await first;
    expect(controller.state.phase, ImageTonightPhase.running);
  });

  test('planning that never answers ends failed with a plain reason', () async {
    var ranCalled = false;
    final controller = ImageTonightController(
      frame: (_) {},
      plan: (_) => Completer<SingleTargetSequenceResult>().future,
      run: (_) async => ranCalled = true,
      planTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(controller.dispose);

    await controller.go(suggestion());

    expect(controller.state.phase, ImageTonightPhase.failed);
    expect(controller.state.error, contains('Planning the night'));
    expect(controller.state.error, contains('try again'));
    expect(ranCalled, isFalse);
  });

  test('cancel while planning returns to idle and the late plan never runs',
      () async {
    final planGate = Completer<SingleTargetSequenceResult>();
    var ranCalled = false;
    final controller = ImageTonightController(
      frame: (_) {},
      plan: (_) => planGate.future,
      run: (_) async => ranCalled = true,
    );
    addTearDown(controller.dispose);

    final chain = controller.go(suggestion());
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.phase, ImageTonightPhase.planning);
    expect(controller.state.canCancel, isTrue);

    controller.cancel();
    expect(controller.state.phase, ImageTonightPhase.idle);
    expect(controller.state.error, isNull);

    planGate.complete(result(suggestion()));
    await chain;
    expect(ranCalled, isFalse);
    expect(controller.state.phase, ImageTonightPhase.idle);
  });

  test('a run that is starting cannot be canceled from here', () async {
    final runGate = Completer<void>();
    final controller = ImageTonightController(
      frame: (_) {},
      plan: (t) async => result(t),
      run: (_) => runGate.future,
    );
    addTearDown(controller.dispose);

    final chain = controller.go(suggestion());
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.phase, ImageTonightPhase.starting);
    expect(controller.state.canCancel, isFalse);

    controller.cancel();
    expect(controller.state.phase, ImageTonightPhase.starting);

    runGate.complete();
    await chain;
    expect(controller.state.phase, ImageTonightPhase.running);
  });

  test('a new press after a cancel runs a fresh chain', () async {
    final firstPlan = Completer<SingleTargetSequenceResult>();
    var plans = 0;
    final controller = ImageTonightController(
      frame: (_) {},
      plan: (t) {
        plans++;
        return plans == 1 ? firstPlan.future : Future.value(result(t));
      },
      run: (_) async {},
    );
    addTearDown(controller.dispose);

    final abandoned = controller.go(suggestion());
    await Future<void>.delayed(Duration.zero);
    controller.cancel();

    await controller.go(suggestion());
    expect(controller.state.phase, ImageTonightPhase.running);

    firstPlan.complete(result(suggestion()));
    await abandoned;
    expect(controller.state.phase, ImageTonightPhase.running);
    expect(plans, 2);
  });

  test('a rig that cannot run the plan says so before framing or planning',
      () async {
    final calls = <String>[];
    final controller = ImageTonightController(
      preflight: () async => 'No plate solver is set up on home.',
      frame: (_) => calls.add('frame'),
      plan: (t) async {
        calls.add('plan');
        return result(t);
      },
      run: (_) async => calls.add('run'),
    );
    addTearDown(controller.dispose);

    await controller.go(suggestion());

    expect(controller.state.phase, ImageTonightPhase.failed);
    expect(controller.state.error, 'No plate solver is set up on home.');
    expect(controller.state.target?.targetName, 'M51',
        reason: 'the failure names the target it was for');
    expect(calls, isEmpty);
  });
}
