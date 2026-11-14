import '../../../models/equipment/equipment_models.dart';
import '../../../models/sequence/sequence_models.dart';
import '../../equipment_provider.dart';
import '../../profiles_provider.dart';
import '../sequence_validation.dart';
import '../../../models/sequence/validation/validation_issue.dart';

/// SmartExposure picks its per-row filters from [effectiveFiltersProvider],
/// so an empty list leaves every row unselectable and the node cannot run.
///
/// The wording follows the wheel's real state: a wheel that is connected but
/// reports no slots, or one the profile assigns, is not "missing", and saying
/// so sent users to Equipment to look at a wheel that was fine.
class SmartExposureFilterWheelMissingRule implements RefAwareSequenceValidator {
  @override
  String get name => 'SmartExposureFilterWheelMissing';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final hasSmartExposureNode = sequence.enabledNodes
        .whereType<SmartExposureNode>()
        .isNotEmpty;
    if (!hasSmartExposureNode) return const [];

    if (ctx.ref.read(effectiveFiltersProvider).isNotEmpty) return const [];

    final profile = ctx.ref.read(activeEquipmentProfileProvider);
    final wheel = ctx.ref.read(filterWheelStateProvider);
    final wheelConnected =
        wheel.connectionState == DeviceConnectionState.connected;
    final wheelAssignedToProfile = profile?.filterWheelId?.isNotEmpty == true;
    final wheelLabel =
        wheel.deviceName ?? profile?.filterWheelName ?? 'The filter wheel';
    final profileLabel = profile == null
        ? 'no equipment profile is active'
        : 'the active equipment profile "${profile.name}" lists none';

    final String title;
    final String cause;
    final String hint;
    if (wheelConnected || wheelAssignedToProfile) {
      title = 'No filters configured for SmartExposure';
      cause = wheelConnected
          ? '$wheelLabel is connected but reports no filter slots, and $profileLabel, so its rows have nothing to select.'
          : 'the active equipment profile "${profile!.name}" assigns a filter wheel but lists no filters, so its rows have nothing to select.';
      hint =
          'Edit the active profile and add at least one filter, or remove the SmartExposure node.';
    } else {
      title = 'No filter wheel for SmartExposure';
      cause =
          'no filter wheel is connected and $profileLabel, so there are no filters for its rows to select.';
      hint =
          'Connect the filter wheel or add its filters to the active profile, or remove the SmartExposure node.';
    }

    final issues = <ValidationIssue>[];
    for (final node in sequence.enabledNodes) {
      if (node is! SmartExposureNode) continue;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.equipment,
          title: title,
          description: 'Smart Exposure "${node.name}": $cause',
          affectedNodeId: node.id,
          resolutionHint: hint,
        ),
      );
    }
    return issues;
  }
}

/// Per-row check: every SmartExposure plan whose `filterName` is non-empty
/// must name a filter in [effectiveFiltersProvider], the list its editor
/// offers. A row calling for "OIII" on an `L, R, G, B` rig would otherwise
/// fail partway through the run.
///
/// Pairs with [SmartExposureFilterWheelMissingRule] (no filters at all) and
/// the per-row empty-name check inside [SmartExposureNegativeCountRule]
/// (empty `filterName`). Comparison is case-insensitive, as in
/// [FilterInWheelRule].
class SmartExposureFilterUnknownRule implements RefAwareSequenceValidator {
  @override
  String get name => 'SmartExposureFilterUnknown';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final smartExposureNodes = sequence.enabledNodes
        .whereType<SmartExposureNode>()
        .toList();
    if (smartExposureNodes.isEmpty) return const [];

    final available = ctx.ref.read(effectiveFiltersProvider);
    if (available.isEmpty) return const [];
    final availableLower = available.map((f) => f.toLowerCase()).toSet();
    final availableLabel = available.join(', ');

    final issues = <ValidationIssue>[];
    for (final node in smartExposureNodes) {
      for (var i = 0; i < node.plans.length; i++) {
        final plan = node.plans[i];
        final raw = plan.filterName;
        // Empty filter names are handled by SmartExposureNegativeCountRule's
        // per-row empty-filter check — skip to avoid double-counting.
        if (raw.trim().isEmpty) continue;
        if (availableLower.contains(raw.toLowerCase())) continue;
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.equipment,
            title: 'SmartExposure plan filter not available',
            description:
                'Smart Exposure "${node.name}": plan ${i + 1} uses filter "$raw", '
                'which the filter wheel and the active profile do not have. Available: $availableLabel.',
            affectedNodeId: node.id,
            resolutionHint:
                'Pick one of the available filters, or add "$raw" to the wheel or the profile\'s filter list.',
          ),
        );
      }
    }
    return issues;
  }
}
