// Validation rules for the LiveStacking node.
//
// A LiveStacking node sitting in a sequence with no sibling exposure
// nodes is silently broken: the executor arms the broadcast, but no
// frames ever arrive to stack. Surface that as a warning so the user
// catches it before the outreach event starts.

import '../../sequence_models.dart';
import '../validation_issue.dart';

/// LiveStacking only does something useful if there are sibling
/// exposure-producing nodes in the same subtree. A LiveStacking node
/// with no sibling exposure (across the whole sequence) is a
/// misconfiguration.
///
/// We define "sibling exposure" broadly — any ExposureNode or
/// SmartExposureNode anywhere in the same enabled sequence. The
/// broadcast service feeds on `FrameAccepted` events from anywhere in
/// the run, so as long as *some* exposure node exists the broadcast
/// has frames to consume. The "no exposure node at all" case is the
/// one we want to flag.
class LiveStackingNoExposureRule implements SequenceValidator {
  @override
  String get name => 'LiveStackingNoExposure';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    final liveStackingNodes = sequence.enabledNodes
        .whereType<LiveStackingNode>()
        .toList(growable: false);
    if (liveStackingNodes.isEmpty) return issues;

    final hasExposureNode = sequence.enabledNodes.any(
      (n) => n is ExposureNode || n is SmartExposureNode,
    );

    if (hasExposureNode) return issues;

    for (final node in liveStackingNodes) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.exposures,
          title: 'Live Stacking has nothing to broadcast',
          description:
              'Live Stacking "${node.name}" is in this sequence but there are no '
              'Exposure or Smart Exposure nodes. The broadcast will arm but no '
              'frames will be stacked.',
          affectedNodeId: node.id,
          resolutionHint:
              'Add at least one Exposure or Smart Exposure node alongside Live '
              'Stacking.',
        ),
      );
    }
    return issues;
  }
}
