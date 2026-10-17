import '../../../models/sequence/sequence_models.dart';
import '../sequence_validation.dart';

/// Errors out when the sequence has zero nodes or its root container has no
/// children. A newly-created sequence already contains an empty root node, but
/// still has nothing the executor can run.
class EmptySequenceRule implements SequenceValidator {
  @override
  String get name => 'EmptySequence';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final root = sequence.rootNode;
    final hasEmptyRootContainer =
        root != null && isContainerNode(root) && root.childIds.isEmpty;
    if (sequence.nodes.isEmpty || hasEmptyRootContainer) {
      return const [
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.structure,
          title: 'Empty Sequence',
          description:
              'The sequence has no runnable instructions. Add at least one instruction to run.',
          resolutionHint:
              'Add exposure or other instruction nodes to the sequence.',
        ),
      ];
    }
    return const [];
  }
}

/// Errors out when there is no root node. The executor walks from the root
/// outward; without one, nothing happens.
class MissingRootNodeRule implements SequenceValidator {
  @override
  String get name => 'MissingRootNode';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    // Don't double-fire on an empty sequence — EmptySequenceRule already
    // covered that.
    if (sequence.nodes.isEmpty) return const [];

    if (sequence.rootNodeId == null) {
      return const [
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.structure,
          title: 'No Root Node',
          description: 'The sequence has no root node to execute.',
          resolutionHint: 'Ensure the sequence has a root node.',
        ),
      ];
    }
    return const [];
  }
}

/// Warns about nodes that are not reachable from the root. These nodes will
/// not run; they're either bugs or stale leftovers.
class OrphanedNodesRule implements SequenceValidator {
  @override
  String get name => 'OrphanedNodes';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final rootId = sequence.rootNodeId;
    if (rootId == null) {
      // Can't compute reachability without a root. The MissingRootNodeRule
      // handles that case.
      return const [];
    }

    // True root-reachability walk, not a flat "any node references this id"
    // set: a detached subtree whose nodes cross-reference each other all read
    // as "referenced" while none of them hangs off the root. Walk from the
    // root following childIds and collect only the genuinely-reachable ids.
    final reachable = <String>{};
    final queue = <String>[rootId];
    while (queue.isNotEmpty) {
      final id = queue.removeLast();
      if (!sequence.nodes.containsKey(id)) continue;
      if (!reachable.add(id)) continue; // already visited
      queue.addAll(sequence.nodes[id]!.childIds);
    }

    final orphaned = sequence.nodes.keys
        .where((id) => !reachable.contains(id))
        .toList();
    if (orphaned.isEmpty) return const [];

    return [
      ValidationIssue(
        severity: ValidationSeverity.warning,
        category: ValidationCategory.structure,
        title: 'Orphaned Nodes',
        description:
            '${orphaned.length} node${orphaned.length == 1 ? '' : 's'} '
            '${orphaned.length == 1 ? 'is' : 'are'} not connected to the '
            'sequence.',
        resolutionHint: 'Remove unused nodes or connect them to a parent.',
      ),
    ];
  }
}

/// Warns about empty container nodes (Target with no exposures, empty
/// Loop, etc.). These are skipped at runtime but usually represent an
/// in-progress edit the user forgot about.
class EmptyContainerRule implements SequenceValidator {
  @override
  String get name => 'EmptyContainer';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      // Targets have their own dedicated empty-check (with a friendlier
      // message), so let TargetEmptyRule own that one.
      if (node is TargetHeaderNode) continue;
      // EmptySequenceRule owns an empty root because it blocks execution;
      // avoid also presenting the same condition as a weaker warning.
      if (node.id == sequence.rootNodeId && node.childIds.isEmpty) continue;
      if (isContainerNode(node) && node.childIds.isEmpty) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            category: ValidationCategory.structure,
            title: 'Empty Container',
            description: '${node.name} is empty and will be skipped.',
            affectedNodeId: node.id,
            resolutionHint: 'Add child nodes or remove the empty container.',
          ),
        );
      }
    }
    return issues;
  }
}

/// A [LoopNode] is "structurally unbounded" iff its condition type alone
/// could in principle never terminate AND there is no safety cap AND no
/// terminating sub-condition that could end the loop.
///
/// Concretely:
///   * `LoopConditionType.forever` and `LoopConditionType.whileDark` are
///     the only inherently unbounded condition types.
///   * `maxSafetyIterations` is a hard cap that always terminates.
///   * `repeatUntil` (wall-clock target) and `repeatUntilAltitude` (target
///     altitude crossing) act as terminating triggers.
///
/// Run forever / WhileDark with no cap → ERROR (refuse to validate clean): a
/// loop without any terminating condition is a runaway.
class UnboundedLoopRule implements SequenceValidator {
  @override
  String get name => 'UnboundedLoop';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! LoopNode) continue;
      if (!node.isUnbounded) continue;

      final hasSafetyCap = node.maxSafetyIterations != null;
      final hasUntilTime = node.repeatUntil != null;
      final hasUntilAltitude = node.repeatUntilAltitude != null;
      if (hasSafetyCap || hasUntilTime || hasUntilAltitude) continue;

      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.structure,
          title: 'Unbounded Loop',
          description:
              'Loop "${node.name}" has no terminating condition or safety cap '
              'and will run indefinitely.',
          affectedNodeId: node.id,
          resolutionHint:
              'Set a maximum iteration count, an "until" time, an altitude limit, '
              'or a safety iteration cap on the loop.',
        ),
      );
    }
    return issues;
  }
}
