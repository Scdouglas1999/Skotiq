import '../../../models/sequence/sequence_models.dart';
import '../../backend_provider.dart';
import '../node_palette.dart';
import '../sequence_validation.dart';
import '../../../models/sequence/validation/validation_issue.dart';

/// Verifies that every enabled plugin node resolves on the process that will
/// execute it.
///
/// Enabled registrations are mirrored into [pluginNodeBlueprintsProvider] by
/// the app composition layer. Absence therefore covers all of the important
/// launch failures: the plugin is not compiled into this build, is disabled,
/// failed to register, or no longer publishes this node type. A thin network
/// client skips the check because the remote imaging host owns that registry
/// and performs its own preflight.
class PluginNodeAvailabilityRule implements RefAwareSequenceValidator {
  @override
  String get name => 'PluginNodeAvailability';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final backend = ctx.ref.read(diagnosticsBackendProvider);
    if (!backend.dispatchPluginNodesLocally) {
      return const [];
    }

    final availableKeys = ctx.ref
        .read(pluginNodeBlueprintsProvider)
        .map((blueprint) => blueprint.registrationKey)
        .toSet();
    final issues = <ValidationIssue>[];
    for (final node in sequence.enabledNodes) {
      if (node is! PluginInstructionNode) continue;
      if (node.pluginId.trim().isEmpty || node.nodeTypeId.trim().isEmpty) {
        // The pure configuration rule provides the more specific identity
        // repair message for this case.
        continue;
      }
      if (availableKeys.contains(node.registrationKey)) continue;

      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.settings,
          title: 'Plugin node is unavailable',
          description:
              'Plugin node "${node.name}" requires ${node.pluginId} / '
              '${node.nodeTypeId}, but that enabled node type is not loaded '
              'on the imaging host.',
          resolutionHint:
              'Enable the bundled plugin in Settings > Integrations, or '
              'remove and replace this node with one available in the '
              'Plugins palette.',
          affectedNodeId: node.id,
          code: 'plugin_node_unavailable',
        ),
      );
    }
    return issues;
  }
}
