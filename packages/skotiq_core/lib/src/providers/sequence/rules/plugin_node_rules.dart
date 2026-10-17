import 'dart:convert';

import '../../../models/sequence/sequence_models.dart';
import '../../backend_provider.dart';
import '../node_palette.dart';
import '../sequence_validation.dart';

/// Blocks plugin nodes whose opaque payload cannot be executed as authored.
///
/// Imported/legacy sequences can bypass the properties editor, so runtime
/// parsing is not a sufficient validation boundary. In particular, replacing
/// malformed JSON with `{}` can invoke a notification or automation plugin
/// with unintended defaults.
class PluginNodeConfigurationRule implements SequenceValidator {
  static const maxTimeoutSecs = 7200;

  @override
  String get name => 'PluginNodeConfiguration';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! PluginInstructionNode || !node.isEnabled) continue;

      if (node.pluginId.trim().isEmpty || node.nodeTypeId.trim().isEmpty) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.settings,
            title: 'Plugin node identity is incomplete',
            description:
                'Plugin node "${node.name}" is missing its plugin id or node '
                'type id, so the runtime cannot resolve an implementation.',
            resolutionHint:
                'Remove the node and add it again from the Plugins palette.',
            affectedNodeId: node.id,
            code: 'plugin_node_identity_missing',
          ),
        );
      }

      try {
        final decoded = jsonDecode(node.configJson);
        if (decoded is! Map) {
          throw const FormatException('Configuration must be a JSON object');
        }
      } catch (error) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.settings,
            title: 'Plugin configuration is invalid',
            description:
                'Plugin node "${node.name}" does not contain a valid JSON '
                'object: $error',
            resolutionHint:
                'Open the node properties and enter a JSON object such as {}.',
            affectedNodeId: node.id,
            code: 'plugin_node_config_invalid',
          ),
        );
      }

      final timeout = node.timeoutSecs;
      if (timeout != null && (timeout < 0 || timeout > maxTimeoutSecs)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.timing,
            title: 'Plugin timeout is outside the supported range',
            description:
                'Plugin node "${node.name}" has timeout_secs=$timeout. The '
                'supported range is 0-$maxTimeoutSecs seconds; 0 uses the '
                'runtime default.',
            resolutionHint:
                'Set the timeout between 0 and $maxTimeoutSecs seconds.',
            affectedNodeId: node.id,
            code: 'plugin_node_timeout_invalid',
          ),
        );
      }
    }
    return issues;
  }
}

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
    for (final node in sequence.nodes.values) {
      if (node is! PluginInstructionNode || !node.isEnabled) continue;
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
