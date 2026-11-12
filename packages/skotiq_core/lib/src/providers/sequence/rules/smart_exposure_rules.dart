import '../../../models/equipment/equipment_models.dart';
import '../../../models/sequence/sequence_models.dart';
import '../../equipment_provider.dart';
import '../../profiles_provider.dart';
import '../sequence_validation.dart';
import '../../../models/sequence/validation/validation_issue.dart';

/// SmartExposure picks its per-row filters from the active equipment
/// profile's filter list, so an empty list leaves every row unselectable
/// and the node cannot run.
///
/// The condition tested is the profile's filter list — NOT whether a filter
/// wheel is attached. Those are different facts and the app can show them
/// disagreeing: a wheel connected and green on the Equipment screen while
/// the profile still lists no filters. Reporting the empty list as "no
/// filter wheel" sent users to Equipment to look at a wheel that was fine,
/// so the wheel's real state is read here and the wording follows it.
class SmartExposureFilterWheelMissingRule implements RefAwareSequenceValidator {
  @override
  String get name => 'SmartExposureFilterWheelMissing';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final hasSmartExposureNode = sequence.nodes.values
        .whereType<SmartExposureNode>()
        .any((n) => n.isEnabled);
    if (!hasSmartExposureNode) return const [];

    // Read the active profile via the same provider the editor uses. If
    // it's null we can't decide; emit an `info` issue rather than silently
    // passing — matches the validator contract ("must not silently swallow
    // missing context").
    final profile = ctx.ref.read(activeEquipmentProfileProvider);
    if (profile == null) {
      return [
        const ValidationIssue(
          severity: ValidationSeverity.info,
          category: ValidationCategory.equipment,
          title: 'Cannot check SmartExposure filters',
          description:
              'No active equipment profile is selected, so the filter list SmartExposure draws its rows from could not be read.',
        ),
      ];
    }

    // The profile's `filterNames` list is what the SmartExposure editor
    // offers as row filters; empty means the rows have nothing to select.
    if (profile.filterNames.isNotEmpty) return const [];

    // Same source of truth the Equipment screen shows, so the message
    // cannot contradict what the user sees there.
    final wheel = ctx.ref.read(filterWheelStateProvider);
    final wheelConnected =
        wheel.connectionState == DeviceConnectionState.connected;
    final wheelAssignedToProfile = profile.filterWheelId?.isNotEmpty == true;
    final wheelLabel =
        wheel.deviceName ?? profile.filterWheelName ?? 'The filter wheel';

    final String title;
    final String cause;
    final String hint;
    if (wheelConnected || wheelAssignedToProfile) {
      title = 'No filters configured for SmartExposure';
      cause = wheelConnected
          ? '$wheelLabel is connected, but the active equipment profile "${profile.name}" lists no filters, so its rows have nothing to select.'
          : 'the active equipment profile "${profile.name}" assigns a filter wheel but lists no filters, so its rows have nothing to select.';
      // Echoing the slots the driver reports turns "add some filters" into
      // a list the user can copy, instead of a guess at their own hardware.
      hint = wheelConnected && wheel.filterNames.isNotEmpty
          ? 'Edit the active profile and name its filters — the wheel reports ${wheel.filterNames.length} slots: ${wheel.filterNames.join(', ')}.'
          : 'Edit the active profile and add at least one filter, or remove the SmartExposure node.';
    } else {
      title = 'No filter wheel for SmartExposure';
      cause =
          'no filter wheel is connected and the active equipment profile "${profile.name}" has none assigned, so there are no filters for its rows to select.';
      hint =
          'Assign a filter wheel to the active profile and add its filters, or remove the SmartExposure node.';
    }

    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! SmartExposureNode) continue;
      if (!node.isEnabled) continue;
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
/// must reference a filter that the active equipment profile actually has.
///
/// Without this check, a user can save (and start) a sequence that calls
/// for filter "OIII" while the profile only carries `L, R, G, B` — the
/// runtime then either silently routes to the wrong slot or fails partway
/// through. Audit item C6 ("SmartExposure validation doesn't verify per-row
/// filter names against the active profile") is exactly this gap.
///
/// Pairs with [SmartExposureFilterWheelMissingRule] (no filters at all) and
/// the per-row empty-name check inside [SmartExposureNegativeCountRule]
/// (empty `filterName`). This rule is the case in between: the row has a
/// name, the profile has names, they just don't agree. Comparison is
/// case-insensitive, matching the convention used by [FilterInWheelRule]
/// for ExposureNode/FilterChangeNode against the live wheel.
class SmartExposureFilterUnknownRule implements RefAwareSequenceValidator {
  @override
  String get name => 'SmartExposureFilterUnknown';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final smartExposureNodes = sequence.nodes.values
        .whereType<SmartExposureNode>()
        .where((n) => n.isEnabled)
        .toList();
    if (smartExposureNodes.isEmpty) return const [];

    final profile = ctx.ref.read(activeEquipmentProfileProvider);
    if (profile == null) {
      // No profile → SmartExposureFilterWheelMissingRule already emits an
      // info issue explaining that the check is skipped. Returning empty here
      // avoids double-reporting.
      return const [];
    }

    // Empty profile filter list is already flagged as an error by
    // SmartExposureFilterWheelMissingRule. Nothing useful to add here.
    if (profile.filterNames.isEmpty) return const [];

    // Case-insensitive lookup set, matching FilterInWheelRule's convention.
    final availableLower = profile.filterNames
        .map((f) => f.toLowerCase())
        .toSet();
    final availableLabel = profile.filterNames.join(', ');

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
            title: 'SmartExposure plan filter not in profile',
            description:
                'Smart Exposure "${node.name}": plan ${i + 1} uses filter "$raw" '
                'which is not in the active equipment profile. Available: $availableLabel.',
            affectedNodeId: node.id,
            resolutionHint:
                'Pick a filter from the active profile, or add "$raw" to the profile\'s filter list.',
          ),
        );
      }
    }
    return issues;
  }
}
