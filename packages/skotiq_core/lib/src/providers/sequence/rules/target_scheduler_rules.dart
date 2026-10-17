import '../../../models/sequence/sequence_models.dart';
import '../sequence_validation.dart';

/// TargetScheduler validation rules.
///
///   * [TargetSchedulerNoChildrenRule]  — scheduler with no children is an
///     error (it would skip immediately at runtime).
///   * [TargetSchedulerNonTargetChildRule] — children that are not
///     TargetHeaders is an error (the Rust executor refuses to schedule them
///     by design — surfacing the same fact in pre-flight).
///   * [TargetSchedulerWeightsRule] — weights that do not sum to ~1.0 is a
///     warning, not an error. The scheduler normalises internally and still
///     produces sensible output; the warning helps users notice an unbalanced
///     ranking.

/// Errors when a TargetScheduler has no TargetHeader children.
class TargetSchedulerNoChildrenRule implements SequenceValidator {
  @override
  String get name => 'TargetSchedulerNoChildren';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! TargetSchedulerNode) continue;
      if (!node.isEnabled) continue;
      if (node.childIds.isEmpty) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.structure,
            title: 'Target Scheduler has no targets',
            description:
                'Target Scheduler "${node.name}" has no child targets. At '
                'runtime the scheduler will return Skipped immediately.',
            affectedNodeId: node.id,
            resolutionHint:
                'Drag at least one TargetHeader under the scheduler so it has '
                'something to choose from.',
          ),
        );
      }
    }
    return issues;
  }
}

/// Errors when a TargetScheduler has children that are not TargetHeaders.
///
/// The Rust executor refuses to run a TargetScheduler whose children are not
/// all TargetHeader variants (see `target_scheduler.rs`). Catching this at
/// validation time stops the user from saving a sequence that will fail-loud
/// at runtime.
class TargetSchedulerNonTargetChildRule implements SequenceValidator {
  @override
  String get name => 'TargetSchedulerNonTargetChild';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! TargetSchedulerNode) continue;
      if (!node.isEnabled) continue;
      for (final childId in node.childIds) {
        final child = sequence.nodes[childId];
        if (child == null) continue;
        if (child is! TargetHeaderNode) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              category: ValidationCategory.structure,
              title: 'Target Scheduler has a non-target child',
              description:
                  'Target Scheduler "${node.name}" contains a '
                  '"${child.nodeType}" child ("${child.name}"). The scheduler '
                  'requires every child to be a Target Header — the Rust '
                  'executor will refuse to run an invalid tree.',
              affectedNodeId: node.id,
              resolutionHint:
                  'Remove the child or move it outside the scheduler. To group '
                  'imaging steps under a target, put them inside the '
                  'TargetHeader instead.',
            ),
          );
        }
      }
    }
    return issues;
  }
}

/// Warns when the five weights do not sum to approximately 1.0.
///
/// The scheduler still works (it normalises internally by dividing by the
/// weight sum), but unbalanced weights mean the user's ranking is not what
/// they probably intended — surfacing this lets them notice before they
/// press Start.
class TargetSchedulerWeightsRule implements SequenceValidator {
  @override
  String get name => 'TargetSchedulerWeights';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! TargetSchedulerNode) continue;
      if (!node.isEnabled) continue;
      if (!node.weightsNormalised) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            category: ValidationCategory.structure,
            title: 'Target Scheduler weights are not normalised',
            description:
                'Target Scheduler "${node.name}" has weights that sum to '
                '${node.weightsSum.toStringAsFixed(2)} (expected ~1.00). The '
                'scheduler still works, but the ranking may not match the '
                'relative importance you intended.',
            affectedNodeId: node.id,
            resolutionHint:
                'Press the "Normalise" button in the properties panel, or '
                'adjust the five weight sliders so they sum to 1.0.',
          ),
        );
      }
    }
    return issues;
  }
}
