// Pre-flight keeps warning that the scheduler is armed for a plan the OPERATOR
// built after the autopilot dispatched — exactly the case where two owners have
// contended for one telescope.
//
// AutopilotArmedRule returns early when the editor slot is owned by the
// autopilot (correct in itself: the scheduler must not be warned about itself),
// so every manual entry point has to hand that ownership back. `loadSequence`
// does; "New Sequence" must too, or the gap is invisible to anyone who reclaims
// the slot by opening a saved plan instead of building a new one.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/scheduler/scheduler_status.dart';
import 'package:skotiq_core/src/models/sequence/active_plan_owner.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/scheduler_provider.dart';
import 'package:skotiq_core/src/providers/sequence/rules/autopilot_rules.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_editor.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_validation.dart';
import 'package:skotiq_core/src/services/scheduler/scheduler_engine.dart';

final _refProvider = Provider<Ref>((ref) => ref);

class _FixedStatusNotifier extends SchedulerStatusNotifier {
  _FixedStatusNotifier(super.engine, SchedulerStatus fixed) {
    state = fixed;
  }
}

class _NoopSink implements SchedulerSequenceSink {
  @override
  Future<void> dispatchSequence(Sequence sequence) async {}

  @override
  Future<void> pauseSequence() async {}

  @override
  Future<void> resumeSequence() async {}

  @override
  Future<void> stopSequence() async {}

  @override
  Future<void> releaseSequenceOwnership() async {}

  @override
  Future<void> parkForEndOfNight() async {}
}

Sequence _autopilotPlan() {
  const rootId = 'sched-root';
  return Sequence.create(
    name: 'Scheduler / M42-TEST',
    nodes: {rootId: InstructionSetNode(id: rootId, name: 'Sequence')},
    rootNodeId: rootId,
  );
}

void main() {
  late SchedulerEngine engine;
  late ProviderContainer container;
  late CurrentSequenceNotifier editor;

  setUp(() {
    engine = SchedulerEngine(
      site: const SchedulerSite(
        latitudeDegrees: 40,
        longitudeDegrees: -75,
        localOffset: Duration(hours: -5),
      ),
      sequenceSink: _NoopSink(),
    );
    container = ProviderContainer(
      overrides: [
        schedulerStatusProvider.overrideWith(
          (ref) => _FixedStatusNotifier(
            engine,
            const SchedulerStatus(
              state: SchedulerState.running,
              currentTargetId: 7,
              currentTargetName: 'M42-TEST',
            ),
          ),
        ),
      ],
    );
    editor = CurrentSequenceNotifier(ref: container.read(_refProvider));
  });

  tearDown(() async {
    editor.dispose();
    container.dispose();
    await engine.dispose();
  });

  test('New Sequence takes the editor slot back from the autopilot', () {
    editor.takeOwnership(_autopilotPlan(), ActivePlanOwner.autopilot);
    expect(container.read(activePlanOwnerProvider), ActivePlanOwner.autopilot);

    editor.createSequence();

    expect(
      editor.activeOwner,
      ActivePlanOwner.manual,
      reason:
          'the operator built this plan; leaving the slot marked "autopilot" '
          'makes every ownership question — including the pre-flight warning '
          'and the run-dashboard banner — answer for the wrong owner',
    );
    expect(container.read(activePlanOwnerProvider), ActivePlanOwner.manual);
  });

  test('clearing the canvas takes it back too', () {
    editor.takeOwnership(_autopilotPlan(), ActivePlanOwner.autopilot);

    editor.clearSequence();

    expect(editor.activeOwner, ActivePlanOwner.manual);
    expect(container.read(activePlanOwnerProvider), ActivePlanOwner.manual);
  });

  test(
    'the armed-autopilot warning comes back for a plan built after a dispatch',
    () {
      // The live sequence: autopilot dispatches -> that run ends -> operator
      // presses New Sequence, builds their own plan, presses Start.
      editor.takeOwnership(_autopilotPlan(), ActivePlanOwner.autopilot);
      editor.createSequence();
      editor.addNode(
        TargetHeaderNode(
          id: 't1',
          name: 'My target',
          targetName: 'My target',
          raHours: 5.0,
          decDegrees: 10.0,
        ),
      );

      final issues = AutopilotArmedRule().validate(
        editor.state!,
        ValidationContext(container.read(_refProvider)),
      );

      expect(
        issues.map((i) => i.title),
        contains('Unattended Autopilot is engaged'),
        reason:
            'the scheduler is Running and this is the operator\'s own plan — '
            'the one case where the warning matters most',
      );
    },
  );

  test('the autopilot\'s own dispatched plan is still not warned about', () {
    editor.takeOwnership(_autopilotPlan(), ActivePlanOwner.autopilot);

    expect(
      AutopilotArmedRule().validate(
        editor.state!,
        ValidationContext(container.read(_refProvider)),
      ),
      isEmpty,
    );
  });
}
