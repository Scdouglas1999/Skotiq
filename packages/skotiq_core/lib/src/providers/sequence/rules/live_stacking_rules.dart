// Validation rules for the LiveStacking node.
//
// A LiveStacking node sitting in a sequence with no sibling exposure
// nodes is silently broken: the executor arms the broadcast, but no
// frames ever arrive to stack. Surface that as a warning so the user
// catches it before the outreach event starts.

import '../../../models/sequence/sequence_models.dart';
import '../sequence_validation.dart';
import '../sequencer_defaults.dart';

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
    final liveStackingNodes = sequence.nodes.values
        .whereType<LiveStackingNode>()
        .where((n) => n.isEnabled)
        .toList(growable: false);
    if (liveStackingNodes.isEmpty) return issues;

    final hasExposureNode = sequence.nodes.values.any(
      (n) => n.isEnabled && (n is ExposureNode || n is SmartExposureNode),
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

/// Warns when the global "disable Live Stacking everywhere" kill switch is
/// on but the sequence still contains an enabled [LiveStackingNode].
///
/// `SequencerDefaults.livestackingDisableEverywhere` is a master override
/// consulted at sequence-start: when true, every LiveStackingNode has its
/// broadcast forced off (the stack still builds in memory but the broadcast
/// endpoint returns 404). A user who dropped a Live Stacking node and then
/// flipped the global switch in Settings would otherwise get no feedback
/// that the node will arm nothing at runtime — surface it at edit time so
/// they re-enable broadcasts (or remove the node) before the outreach event.
class LiveStackingGloballyDisabledRule implements RefAwareSequenceValidator {
  @override
  String get name => 'LiveStackingGloballyDisabled';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final defaults = ctx.ref.read(sequencerDefaultsProvider);
    if (!defaults.livestackingDisableEverywhere) return const [];

    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! LiveStackingNode) continue;
      if (!node.isEnabled) continue;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.exposures,
          title: 'Live Stacking is globally disabled',
          description:
              'Live Stacking "${node.name}" is enabled, but Live Stacking is '
              'globally disabled in Settings; this node will arm nothing and '
              'the broadcast endpoint will return 404.',
          affectedNodeId: node.id,
          resolutionHint:
              'Turn off "Disable Live Stacking everywhere" in Sequencer '
              'Settings, or remove this Live Stacking node.',
        ),
      );
    }
    return issues;
  }
}
