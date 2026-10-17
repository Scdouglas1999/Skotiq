import 'dart:developer' as developer;

import '../../../models/scheduler/scheduler_status.dart';
import '../../../models/sequence/active_plan_owner.dart';
import '../../../models/sequence/sequence_models.dart';
import '../../scheduler_provider.dart' show schedulerStatusProvider;
import '../sequence_editor.dart' show activePlanOwnerProvider;
import '../sequence_validation.dart';

/// Pre-flight rule: Unattended Autopilot is armed while a run is started by
/// hand.
///
/// Two things want the same rig. The autopilot evaluates every tick and will
/// slew, swap targets, or park the mount at dawn; the operator pressing Start
/// in the Sequencer is asking for something else entirely. The two are now
/// arbitrated safely (the autopilot only ever stops the run it dispatched
/// itself), but nothing on the way into a manual run SAID the autopilot was
/// engaged — no banner in the Sequencer and no pre-flight entry — so the first
/// evidence was the mount moving on its own.
///
/// Emitted as a warning: it is legitimate to hand-start a sequence with the
/// scheduler armed (that is how you take a quick calibration frame mid-night),
/// but it must be a decision rather than a surprise.
class AutopilotArmedRule implements RefAwareSequenceValidator {
  @override
  String get name => 'AutopilotArmed';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final ref = ctx.ref;
    // The autopilot's OWN dispatched run goes through this same pre-flight;
    // warning there would be telling the scheduler about itself.
    //
    // This suppression is only sound while the ownership flag is truthful. A
    // slot left marked `autopilot` after a single dispatch hands the operator's
    // own plan the scheduler's exemption, so the flag is reclaimed by every
    // manual load/create/clear
    // (`CurrentSequenceNotifier._reclaimManualOwnership`). This line is how a
    // live log says WHICH answer this rule got — "suppressed" in a log for a
    // plan the operator built is the fingerprint of that failure.
    if (ref.read(activePlanOwnerProvider) == ActivePlanOwner.autopilot) {
      developer.log(
        'AutopilotArmedRule: suppressed for "${sequence.name}" — the editor '
        'slot is owned by the autopilot, so this plan IS the scheduler\'s own '
        'dispatch',
        name: 'AutopilotArmedRule',
        level: 500, // FINE / trace
      );
      return const [];
    }

    final status = ref.read(schedulerStatusProvider);
    final engaged =
        status.state == SchedulerState.running ||
        status.state == SchedulerState.paused;
    if (!engaged) return const [];

    final target = status.currentTargetName;
    final armed = status.state == SchedulerState.running
        ? 'running'
        : 'paused (still holding the rig)';
    return [
      ValidationIssue(
        severity: ValidationSeverity.warning,
        category: ValidationCategory.equipment,
        title: 'Unattended Autopilot is engaged',
        description:
            'The scheduler is $armed'
            '${target == null ? '' : ' and currently on "$target"'}. It keeps '
            'evaluating targets while your sequence runs, and at dawn it parks '
            'the mount — it will not stop the run you are starting here, but '
            'the two are sharing one telescope.',
        resolutionHint:
            'Stop Unattended Autopilot in Plan Tonight ▸ Schedule if this run '
            'should own the rig for the rest of the night.',
      ),
    ];
  }
}
