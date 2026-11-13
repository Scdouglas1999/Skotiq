import '../../../models/equipment/filter_names.dart';
import '../../../models/equipment/equipment_models.dart';
import '../../../models/sequence/sequence_models.dart';
import '../../equipment_provider.dart';
import '../../profiles_provider.dart';
import '../filter_name_matching.dart';
import '../sequence_validation.dart';
import '../../../models/sequence/validation/validation_issue.dart';

/// Every filter name an enabled step of [sequence] asks for, paired with its
/// step.
Iterable<({SequenceNode node, String filter})> _filterUses(
  Sequence sequence,
) sync* {
  for (final node in sequence.nodes.values) {
    if (!node.isEnabled) continue;
    for (final filter in node.kind.filtersOf(node)) {
      yield (node: node, filter: filter);
    }
  }
}

/// The hint for a filter [available] does not list by that name: the one it
/// does list for the same filter, when there is one.
String _filterHint(String filter, List<String> available, String otherwise) {
  final match = matchingFilterName(filter, available);
  if (match == null) return otherwise;
  return '"$match" is the same filter. Use "Match filter names" to rename '
      'every "$filter" in the plan to "$match".';
}

/// Warns when a node references a filter by name that the connected filter
/// wheel does not have. Only runs when a filter wheel is connected — if no
/// wheel is connected, [FilterInProfileRule] checks the same names against
/// the active equipment profile instead.
class FilterInWheelRule implements RefAwareSequenceValidator {
  @override
  String get name => 'FilterInWheel';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final fwState = ctx.ref.read(filterWheelStateProvider);
    if (fwState.connectionState != DeviceConnectionState.connected) {
      // Not connected — different rule. Don't double-complain.
      return const [];
    }

    final available = fwState.filterNames.map((f) => f.toLowerCase()).toSet();
    if (available.isEmpty) {
      // Connected but driver hasn't reported filter names yet. Surface as
      // info — we can't validate, but the user should know.
      return [
        const ValidationIssue(
          severity: ValidationSeverity.info,
          category: ValidationCategory.equipment,
          title: 'Filter Wheel Reports No Filters',
          description:
              'A filter wheel is connected but reports no filter names. Filter validation skipped.',
          resolutionHint:
              'Configure filter names in the equipment profile or wait for the driver to populate them.',
        ),
      ];
    }

    final issues = <ValidationIssue>[];
    final availableLabel = fwState.filterNames.join(', ');

    for (final use in _filterUses(sequence)) {
      if (available.contains(use.filter.toLowerCase())) continue;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.equipment,
          title: 'Filter Not in Wheel',
          description:
              '"${use.node.name}" uses filter "${use.filter}", which is not '
              'in the connected filter wheel. Available: $availableLabel.',
          affectedNodeId: use.node.id,
          code: kFilterNameMismatchCode,
          resolutionHint: _filterHint(
            use.filter,
            fwState.filterNames,
            'Change the filter name or check the filter wheel configuration.',
          ),
        ),
      );
    }
    return issues;
  }
}

/// Warns when a node names a filter the ACTIVE EQUIPMENT PROFILE does not
/// declare, while no filter wheel is connected.
///
/// Sequences are built in daylight with nothing plugged in, which is exactly
/// when [FilterInWheelRule] cannot run, so the profile is the only check
/// available at build time — otherwise a typo ("Ha" vs "H-alpha") survives
/// until the run tries to move the wheel. The profile is the
/// operator's own declaration of what is in the rig, and it is already the
/// source the palette seeds filter names from and the Change Filter editor
/// binds its dropdown to, so it is the right build-time reference.
///
/// Deliberately silent when the profile declares no filters: there is nothing
/// to check against, and a warning there would be noise rather than news.
class FilterInProfileRule implements RefAwareSequenceValidator {
  @override
  String get name => 'FilterInProfile';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final fwState = ctx.ref.read(filterWheelStateProvider);
    if (fwState.connectionState == DeviceConnectionState.connected) {
      // A live wheel is the better authority; FilterInWheelRule owns it.
      return const [];
    }

    final profileFilters =
        ctx.ref.read(activeEquipmentProfileProvider)?.filterNames ??
        const <String>[];
    if (profileFilters.isEmpty) return const [];

    final declared = profileFilters.map((f) => f.toLowerCase()).toSet();
    final declaredLabel = profileFilters.join(', ');

    return [
      for (final use in _filterUses(sequence))
        if (!declared.contains(use.filter.toLowerCase()))
          ValidationIssue(
            severity: ValidationSeverity.warning,
            category: ValidationCategory.equipment,
            title: 'Filter Not in Profile',
            description:
                '"${use.node.name}" uses filter "${use.filter}", which the '
                'active equipment profile does not list. Profile filters: '
                '$declaredLabel.',
            affectedNodeId: use.node.id,
            code: kFilterNameMismatchCode,
            resolutionHint: _filterHint(
              use.filter,
              profileFilters,
              'Fix the filter name, or add it to the equipment profile if '
              'the wheel really carries it.',
            ),
          ),
    ];
  }
}
