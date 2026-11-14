import '../../sequence_models.dart';
import '../validation_issue.dart';

/// Empty plans = nothing to do. Sequence will still run, but the
/// SmartExposure node returns Success immediately without capturing any
/// frames. Treat as an error so the user fixes it before pressing Start.
class SmartExposureEmptyPlansRule implements SequenceValidator {
  @override
  String get name => 'SmartExposureEmptyPlans';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.enabledNodes) {
      if (node is! SmartExposureNode) continue;
      if (node.plans.isEmpty) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.exposures,
            title: 'SmartExposure has no filter plans',
            description:
                'Smart Exposure "${node.name}" has no filter plans. It will run but capture no images.',
            affectedNodeId: node.id,
            resolutionHint:
                'Add at least one filter plan (filter + count + duration).',
          ),
        );
      }
    }
    return issues;
  }
}

/// Any plan with count <= 0 will never execute a single exposure. Treat
/// as a warning — the rest of the SmartExposure run still works — but
/// surface it so the user notices the dead row.
class SmartExposureNegativeCountRule implements SequenceValidator {
  @override
  String get name => 'SmartExposureNegativeCount';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.enabledNodes) {
      if (node is! SmartExposureNode) continue;
      for (var i = 0; i < node.plans.length; i++) {
        final p = node.plans[i];
        // In loop-until-stopped mode the per-plan count is ignored entirely
        // (1 sub per filter, looping), so a zero/negative count is not a
        // dead row — skip the warning to avoid a false positive.
        if (!node.loopUntilStopped && p.count <= 0) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.warning,
              category: ValidationCategory.exposures,
              title: 'SmartExposure plan never runs',
              description:
                  'Smart Exposure "${node.name}": plan ${i + 1} ("${p.filterName}") has count ${p.count} — no frames will be taken for this filter.',
              affectedNodeId: node.id,
              resolutionHint:
                  'Set count to a positive number, or remove the row entirely.',
            ),
          );
        }
        if (p.durationSecs <= 0) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              category: ValidationCategory.exposures,
              title: 'SmartExposure plan has invalid duration',
              description:
                  'Smart Exposure "${node.name}": plan ${i + 1} ("${p.filterName}") has duration ${p.durationSecs}s.',
              affectedNodeId: node.id,
              resolutionHint: 'Set a positive sub-exposure duration.',
            ),
          );
        }
        if (p.filterName.trim().isEmpty) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              category: ValidationCategory.exposures,
              title: 'SmartExposure plan has no filter',
              description:
                  'Smart Exposure "${node.name}": plan ${i + 1} has an empty filter name. The runtime cannot route the filter change.',
              affectedNodeId: node.id,
              resolutionHint:
                  'Pick a filter from the active equipment profile.',
            ),
          );
        }
      }

      // Duplicate filter names: legal but usually a UX mistake.
      if (node.hasDuplicateFilter && node.plans.length > 1) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            category: ValidationCategory.exposures,
            title: 'SmartExposure has duplicate filter rows',
            description:
                'Smart Exposure "${node.name}" has two or more rows for the same filter — usually a mistake. SmartExposure tracks per-filter completed counts by name, so duplicate rows compete for the same counter.',
            affectedNodeId: node.id,
            resolutionHint:
                'Merge duplicate filter rows, or rename one to a different filter.',
          ),
        );
      }
    }
    return issues;
  }
}

/// Loop-until-stopped mode is bounded by EITHER an integration budget OR the
/// surrounding target's end window (`endWhen` / legacy `endBefore`). With
/// neither, the Rust executor fails closed at runtime rather than looping
/// forever (errors-are-a-feature). This rule surfaces that at edit time as an
/// error so the user fixes it before pressing Start instead of hitting a
/// runtime failure.
class SmartExposureUnboundedLoopRule implements SequenceValidator {
  @override
  String get name => 'SmartExposureUnboundedLoop';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.enabledNodes) {
      if (node is! SmartExposureNode) continue;
      if (!node.loopUntilStopped) continue;
      // A positive integration budget is a valid automatic bound.
      if (node.integrationBudgetSecs > 0) continue;
      // Otherwise, the only automatic bound is a parent target window.
      if (_hasBoundingTargetWindow(sequence, node)) continue;

      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.exposures,
          title: 'SmartExposure loop is unbounded',
          description:
              'Smart Exposure "${node.name}" is in "switch filter every frame" '
              '(loop until stopped) mode but has no integration budget and is not '
              'under a target with an end condition. It would loop forever, so the '
              'run will refuse to start.',
          affectedNodeId: node.id,
          resolutionHint:
              'Set an integration budget on the node, or place it under a target '
              'with an ends-when / ends-before condition.',
        ),
      );
    }
    return issues;
  }

  /// Walk parents to find a [TargetHeaderNode] with an end condition.
  bool _hasBoundingTargetWindow(Sequence sequence, SequenceNode node) {
    var currentId = node.parentId;
    final seen = <String>{};
    while (currentId != null && seen.add(currentId)) {
      final parent = sequence.nodes[currentId];
      if (parent == null) break;
      if (parent is TargetHeaderNode &&
          (parent.endWhen != null || parent.endBefore != null)) {
        return true;
      }
      currentId = parent.parentId;
    }
    return false;
  }
}
