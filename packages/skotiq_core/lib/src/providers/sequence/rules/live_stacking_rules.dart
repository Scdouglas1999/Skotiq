import '../../../models/sequence/sequence_models.dart';
import '../sequence_validation.dart';
import '../../../models/sequence/validation/validation_issue.dart';
import '../sequencer_defaults.dart';

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
    for (final node in sequence.enabledNodes) {
      if (node is! LiveStackingNode) continue;
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
