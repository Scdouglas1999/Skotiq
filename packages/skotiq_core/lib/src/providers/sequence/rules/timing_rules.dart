import '../../../models/sequence/sequence_models.dart';
import '../sequence_validation.dart';

/// Warns when a WaitTime node's `waitUntil` is in the past. The sequence
/// will skip the wait entirely, which may not be what the user intended.
class WaitTimePastRule implements SequenceValidator {
  @override
  String get name => 'WaitTimePast';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final now = DateTime.now();
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! WaitTimeNode) continue;
      final waitUntil = node.waitUntil;
      if (waitUntil == null) continue;
      if (!waitUntil.isBefore(now)) continue;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.timing,
          title: 'Wait Time Passed',
          description:
              'Wait node "${node.name}" is set for a time that has already passed.',
          affectedNodeId: node.id,
          resolutionHint: 'Update the wait time or remove the node.',
        ),
      );
    }
    return issues;
  }
}

/// Blocks a Wait node that was never given anything to wait for.
///
/// A [WaitTimeNode] waits on exactly one of two things: an absolute
/// `waitUntil` instant or a `waitForTwilight` condition. With neither set
/// there is nothing to wait for, so the node completes in microseconds. The
/// canonical use of this node is "wait until astronomical dark before
/// imaging"; a silent instant-success there starts the run in daylight, so
/// this is an error rather than a warning — [WaitTimePastRule] only ever
/// looked at a `waitUntil` that WAS set.
class WaitTimeUnconfiguredRule implements SequenceValidator {
  @override
  String get name => 'WaitTimeUnconfigured';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! WaitTimeNode) continue;
      if (!node.isEnabled) continue;
      if (node.waitUntil != null || node.waitForTwilight != null) continue;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.timing,
          title: 'Wait Has No Time Set',
          description:
              'Wait node "${node.name}" has no wait time and no twilight '
              'condition, so it will complete instantly instead of waiting.',
          affectedNodeId: node.id,
          resolutionHint:
              'Pick a "Wait Until" time or a twilight condition on the node, '
              'or remove it.',
        ),
      );
    }
    return issues;
  }
}

/// Blocks an until-time Loop that was never given an end time.
///
/// The executor evaluates `UntilTime` against the loop's end instant and
/// exits immediately when there is none (`loop_node.rs`: `condition_value ==
/// None` => `should_continue = false`), so the loop body never runs once.
/// [LoopEndTimePastRule] skips a null `repeatUntil` and [UnboundedLoopRule]
/// only inspects forever/while-dark loops, so nothing else covers this.
class LoopUntilTimeUnsetRule implements SequenceValidator {
  @override
  String get name => 'LoopUntilTimeUnset';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! LoopNode) continue;
      if (!node.isEnabled) continue;
      if (node.conditionType != LoopConditionType.untilTime) continue;
      if (node.repeatUntil != null) continue;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.timing,
          title: 'Loop Has No End Time',
          description:
              'Loop "${node.name}" repeats until a time that was never set, '
              'so its contents will never run.',
          affectedNodeId: node.id,
          resolutionHint:
              'Set the loop end time, or switch the loop to a count.',
        ),
      );
    }
    return issues;
  }
}

/// Warns when a LoopNode's `repeatUntil` is in the past. The loop will not
/// execute any iterations.
class LoopEndTimePastRule implements SequenceValidator {
  @override
  String get name => 'LoopEndTimePast';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final now = DateTime.now();
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! LoopNode) continue;
      final repeatUntil = node.repeatUntil;
      if (repeatUntil == null) continue;
      if (!repeatUntil.isBefore(now)) continue;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.timing,
          title: 'Loop End Time Passed',
          description: 'Loop "${node.name}" end time has already passed.',
          affectedNodeId: node.id,
          resolutionHint: 'Update the end time or change loop condition.',
        ),
      );
    }
    return issues;
  }
}
