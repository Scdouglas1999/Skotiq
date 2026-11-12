// The rules that check a sequence on its own, without rig state, settings or
// I/O. They run first in every validation (the live tree, the pre-flight
// dialog, the start paths) and are what [validateSequence] runs where no
// `Ref` is at hand: a file import, the conversational builder. Rules that read
// the rig are in `providers/sequence/sequence_validation.dart`.

import '../sequence_models.dart';
import 'rules/adaptive_exposure_rules.dart';
import 'rules/exposure_rules.dart';
import 'rules/live_stacking_rules.dart';
import 'rules/logic_node_rules.dart';
import 'rules/plugin_node_rules.dart';
import 'rules/science_photometry_rules.dart';
import 'rules/smart_exposure_rules.dart';
import 'rules/structure_rules.dart';
import 'rules/target_rules.dart';
import 'rules/target_scheduler_rules.dart';
import 'rules/timing_rules.dart';
import 'validation_issue.dart';

/// The full set of pure structural validators. Order is preserved in the
/// output.
final List<SequenceValidator> defaultSequenceValidators =
    List<SequenceValidator>.unmodifiable(<SequenceValidator>[
      EmptySequenceRule(),
      MissingRootNodeRule(),
      OrphanedNodesRule(),
      EmptyContainerRule(),
      TargetCoordinatesRule(),
      TargetCoordinatesUnsetRule(),
      EmptyTargetRule(),
      CaptureBeforeAimRule(),
      LowAltitudeLimitRule(),
      IntegrationBudgetEmptyRule(),
      IntegrationBudgetRatioZeroSumRule(),
      IntegrationBudgetRatioWithoutTotalRule(),
      // Per-target altitude/time crossing validators. The
      // ImpossibleAltitude rule needs an observer latitude to be useful; we
      // wire it up below in `sequenceValidatorsFor(latitude)` if/when the
      // caller has one. The structural rules (empty compound,
      // start/end contradiction) work without an observer.
      TargetTriggerEmptyCompoundRule(),
      const TargetTriggerStartEndContradictionRule(),
      NoTargetForExposuresRule(),
      ExposureParamsRule(),
      HighBinningRule(),
      NoExposuresRule(),
      LongTotalIntegrationRule(),
      UnboundedLoopRule(),
      SlewCoordinatesRule(),
      WaitTimePastRule(),
      WaitTimeUnconfiguredRule(),
      LoopUntilTimeUnsetRule(),
      LoopEndTimePastRule(),
      RecoveryNodeConfigRule(),
      CloudTriggerConfigRule(),
      ParallelNodeRequiredSuccessesRule(),
      ConditionalNodeEmptyBranchRule(),
      LoopUnreachableTerminationRule(),
      // A Loop at 1 iteration and a Conditional set to Always are both no-ops
      // and must be flagged.
      NoOpLogicNodeRule(),
      PluginNodeConfigurationRule(),
      SmartExposureEmptyPlansRule(),
      SmartExposureNegativeCountRule(),
      SmartExposureUnboundedLoopRule(),
      SciencePhotometryFilterRule(),
      SciencePhotometryReferenceStarsEmptyRule(),
      SciencePhotometryCadenceRule(),
      LiveStackingNoExposureRule(),
      TargetSchedulerNoChildrenRule(),
      TargetSchedulerNonTargetChildRule(),
      TargetSchedulerWeightsRule(),
      AdaptiveExposureBoundsRule(),
      AdaptiveExposureNoFilterEnabledRule(),
      AdaptiveExposureNominalOutOfBoundsRule(),
    ]);

/// Convenience top-level function for the pure structural validators only.
///
/// Kept for callers that have no `Ref` (e.g. the sequence executor's
/// `start()` pre-check, which already executes inside Riverpod but needed a
/// way to validate before paying for equipment lookups). For full
/// validation including equipment / disk space, depend on
/// `sequenceValidatorProvider` instead.
List<ValidationIssue> validateSequence(Sequence sequence) {
  final issues = <ValidationIssue>[];
  for (final rule in defaultSequenceValidators) {
    issues.addAll(rule.validate(sequence));
  }
  return issues;
}

/// [ValidationIssue.code] of a target still at the 0h / +0° placeholder.
const String kTargetCoordinatesUnsetCode = 'target_coordinates_unset';

/// Rejects a target whose sky position was never chosen.
///
/// [TargetHeaderNode] has no nullable coordinate meaning "no pointing picked
/// yet", so a target added from the palette starts at exactly RA 0h / Dec +0°.
/// That is a real point in Pisces and both values are in range, so
/// [TargetCoordinatesRule] passes it. The runtime then stamps the placeholder
/// onto the execution context for the whole subtree: a Slew below it drives
/// the mount to Pisces and every frame captured under it is recorded claiming
/// that pointing under the target's name. Only validation runs before the
/// mount moves, so this is the last place an unattended run can be stopped.
///
/// The editor surfaces that render this state already refuse to confirm it
/// (the Slew editor warns instead of showing "Will use target: M31" in
/// green); this rule is the matching gate on the start path.
class TargetCoordinatesUnsetRule implements SequenceValidator {
  /// True while [node] still carries the (0h, +0°) placeholder. A deliberate
  /// origin pointing reads as unset as well; nudging either value by the
  /// ten-thousandth of a unit the coordinate editor already exposes claims it
  /// back.
  static bool isUnset(TargetHeaderNode node) =>
      node.raHours == 0 && node.decDegrees == 0;

  @override
  String get name => 'TargetCoordinatesUnset';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final target in sequence.targetHeaders) {
      if (!isUnset(target)) continue;

      // Block only when the placeholder actually reaches hardware or frame
      // metadata on this run. A half-built target nobody has wired up yet is
      // still worth flagging in the tree, but blocking an unrelated run on it
      // would train the operator to ignore the pre-flight dialog.
      final consumed =
          _isLive(sequence, target) &&
          (_hasEnabledInstruction(sequence, target) ||
              _hasExternalPointingConsumer(sequence, target));

      issues.add(
        ValidationIssue(
          severity: consumed
              ? ValidationSeverity.error
              : ValidationSeverity.warning,
          category: ValidationCategory.targets,
          title: 'Target Coordinates Not Set',
          description: consumed
              ? 'Target "${target.targetName}" is still at the RA 0h / Dec +0° '
                    'placeholder. Starting this sequence would point the mount '
                    'at that spot in Pisces and record every frame under it as '
                    '"${target.targetName}".'
              : 'Target "${target.targetName}" is still at the RA 0h / Dec +0° '
                    'placeholder. Nothing enabled under it points there yet, so '
                    'the run is not affected — but the target does not know '
                    'where it is.',
          affectedNodeId: target.id,
          code: kTargetCoordinatesUnsetCode,
          resolutionHint:
              'Look "${target.targetName}" up in the target editor, or enter '
              'its RA/Dec by hand.',
        ),
      );
    }
    return issues;
  }

  /// True when [node] and every ancestor up to the root are enabled — i.e.
  /// the node is reachable on this run. A disabled container silences
  /// everything beneath it, so its subtree can never move the mount.
  static bool _isLive(Sequence sequence, SequenceNode node) {
    final seen = <String>{};
    SequenceNode? cursor = node;
    while (cursor != null && seen.add(cursor.id)) {
      if (!cursor.isEnabled) return false;
      final parentId = cursor.parentId;
      cursor = parentId == null ? null : sequence.nodes[parentId];
    }
    return true;
  }

  /// True when at least one enabled leaf instruction sits under [parent] with
  /// no disabled container in between. Containers alone execute nothing, so
  /// an empty (or fully disabled) target never consumes its own coordinates.
  static bool _hasEnabledInstruction(
    Sequence sequence,
    SequenceNode parent, [
    Set<String>? seen,
  ]) {
    final visited = seen ?? <String>{parent.id};
    for (final id in parent.childIds) {
      final child = sequence.nodes[id];
      if (child == null || !child.isEnabled) continue;
      if (!visited.add(child.id)) continue;
      if (!child.kind.isContainer) return true;
      if (_hasEnabledInstruction(sequence, child, visited)) return true;
    }
    return false;
  }

  /// True when an enabled Slew/Center that inherits its pointing resolves to
  /// [target] from outside the target's own subtree. Such a node has no
  /// TargetHeader ancestor and falls back to the first target in the
  /// sequence — the same resolution the Slew editor shows the user — so an
  /// otherwise-idle target can still be what aims the mount.
  static bool _hasExternalPointingConsumer(
    Sequence sequence,
    TargetHeaderNode target,
  ) {
    for (final node in sequence.nodes.values) {
      final inheritsPointing = switch (node) {
        SlewNode(useTargetCoords: final use) ||
        CenterNode(useTargetCoords: final use) => use,
        _ => false,
      };
      if (!inheritsPointing) continue;
      if (!_isLive(sequence, node)) continue;
      if (_resolvePointingSource(sequence, node)?.id != target.id) continue;
      return true;
    }
    return false;
  }

  /// The TargetHeader a pointing-inheriting node reads its coordinates from:
  /// the nearest TargetHeader ancestor, else the first target in the
  /// sequence.
  static TargetHeaderNode? _resolvePointingSource(
    Sequence sequence,
    SequenceNode node,
  ) {
    final seen = <String>{};
    SequenceNode? cursor = node;
    while (cursor != null && seen.add(cursor.id)) {
      if (cursor is TargetHeaderNode) return cursor;
      final parentId = cursor.parentId;
      cursor = parentId == null ? null : sequence.nodes[parentId];
    }
    final targets = sequence.targetHeaders;
    return targets.isEmpty ? null : targets.first;
  }
}
