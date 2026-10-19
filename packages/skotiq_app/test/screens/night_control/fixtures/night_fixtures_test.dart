// The fixtures stand in for the providers in every widget test, so a control
// a fixture enables that the provider disables makes those tests pass on a
// screen the app never shows.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_header_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../data/plan/plan_test_support.dart';
import 'night_fixtures.dart';

void main() {
  test('the autofocus board offers the controls the provider offers', () {
    final plan = TwoTargetPlan();
    final container = planContainer(
      now: NightFixtures.at(23, 52),
      sequence: plan.sequence,
      execution: SequenceExecutionState.paused,
      action: const ManualActionState(
        phase: ManualActionPhase.running,
        active: ManualActionId.autofocus,
        startedRunPause: true,
      ),
    );
    addTearDown(container.dispose);
    final real = container.read(nightHeaderProvider);
    final fixture = NightFixtures.autofocus().header;

    expect(real.phase, NightRunPhase.pausedForAction,
        reason: 'precondition: the provider sees the run held by autofocus');
    expect(fixture.phase, real.phase);
    expect(fixture.pauseResume, real.pauseResume);
    expect(fixture.skipStep, real.skipStep);
    expect(fixture.pauseResume?.enabled, isFalse);
    expect(fixture.skipStep?.enabled, isFalse);
  });
}
