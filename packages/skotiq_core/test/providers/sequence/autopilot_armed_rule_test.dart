// Pre-flight must say that the scheduler is holding the rig when a run is
// started by hand while Unattended Autopilot is engaged.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/scheduler/scheduler_status.dart';
import 'package:skotiq_core/src/models/sequence/active_plan_owner.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/scheduler_provider.dart';
import 'package:skotiq_core/src/services/scheduler/scheduler_engine.dart';
import 'package:skotiq_core/src/providers/sequence/rules/autopilot_rules.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_editor.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_validation.dart';

/// Publishes a fixed status, standing in for a live engine.
class _FixedStatusNotifier extends SchedulerStatusNotifier {
  _FixedStatusNotifier(SchedulerEngine engine, SchedulerStatus fixed)
    : super(engine) {
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

ProviderContainer _containerWith({
  required SchedulerStatus status,
  required ActivePlanOwner owner,
}) {
  final engine = SchedulerEngine(
    site: const SchedulerSite(
      latitudeDegrees: 40,
      longitudeDegrees: -75,
      localOffset: Duration(hours: -5),
    ),
    sequenceSink: _NoopSink(),
  );
  final container = ProviderContainer(
    overrides: [
      schedulerStatusProvider.overrideWith(
        (ref) => _FixedStatusNotifier(engine, status),
      ),
      activePlanOwnerProvider.overrideWith((ref) => owner),
    ],
  );
  addTearDown(engine.dispose);
  return container;
}

Sequence _sequence() {
  const rootId = 'root';
  return Sequence.create(
    name: 'Manual run',
    nodes: {rootId: InstructionSetNode(id: rootId, name: 'Sequence')},
    rootNodeId: rootId,
  );
}

void main() {
  final rule = AutopilotArmedRule();

  test('warns when a manual run starts while the autopilot is running', () {
    final container = _containerWith(
      status: const SchedulerStatus(
        state: SchedulerState.running,
        currentTargetId: 7,
        currentTargetName: 'M42-TEST',
      ),
      owner: ActivePlanOwner.manual,
    );
    addTearDown(container.dispose);

    final issues = rule.validate(
      _sequence(),
      ValidationContext(container.read(_probeProvider)),
    );

    expect(issues, hasLength(1));
    expect(issues.single.severity, ValidationSeverity.warning);
    expect(issues.single.title, contains('Autopilot'));
    expect(
      issues.single.description,
      allOf(contains('M42-TEST'), contains('parks')),
    );
  });

  test('a paused autopilot still holds the rig, so it still warns', () {
    final container = _containerWith(
      status: const SchedulerStatus(state: SchedulerState.paused),
      owner: ActivePlanOwner.manual,
    );
    addTearDown(container.dispose);

    final issues = rule.validate(
      _sequence(),
      ValidationContext(container.read(_probeProvider)),
    );
    expect(issues, hasLength(1));
  });

  test('an idle autopilot says nothing', () {
    final container = _containerWith(
      status: const SchedulerStatus(),
      owner: ActivePlanOwner.manual,
    );
    addTearDown(container.dispose);

    expect(
      rule.validate(
        _sequence(),
        ValidationContext(container.read(_probeProvider)),
      ),
      isEmpty,
    );
  });

  test('the autopilot\'s OWN dispatched run is not warned about itself', () {
    final container = _containerWith(
      status: const SchedulerStatus(
        state: SchedulerState.running,
        currentTargetId: 7,
        currentTargetName: 'M42-TEST',
      ),
      owner: ActivePlanOwner.autopilot,
    );
    addTearDown(container.dispose);

    expect(
      rule.validate(
        _sequence(),
        ValidationContext(container.read(_probeProvider)),
      ),
      isEmpty,
    );
  });
}

/// Hands the container's own [Ref] to the rule — rules take a `Ref`, not a
/// container, and this is the standard way to borrow one in a unit test.
final _probeProvider = Provider<Ref>((ref) => ref);
