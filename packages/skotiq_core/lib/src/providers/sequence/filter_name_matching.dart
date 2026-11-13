import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/equipment/equipment_models.dart';
import '../../models/equipment/filter_names.dart';
import '../../models/sequence/sequence_models.dart';
import '../equipment_provider.dart';
import '../profiles_provider.dart';

/// The validation issue code of a step naming a filter the wheel or the
/// equipment profile does not list by that name.
const String kFilterNameMismatchCode = 'filter_name_mismatch';

/// Every filter name [sequence]'s enabled steps use.
Set<String> filterNamesUsedBy(Sequence sequence) => {
  for (final node in sequence.nodes.values)
    if (node.isEnabled) ...node.kind.filtersOf(node),
};

/// The renames that make [sequence] call its filters what [available] calls
/// them, for every filter that is spelled differently but is the same
/// filter ("Lum" -> "L"). Filters with no match are left out.
Map<String, String> filterRenamesFor(
  Sequence sequence,
  Iterable<String> available,
) => {
  for (final used in filterNamesUsedBy(sequence))
    if (matchingFilterName(used, available) case final match?
        when match != used)
      used: match,
};

/// [sequence] with every filter name in [renames] replaced, in every step
/// that names one. A step whose name only said its filter ("Filter: Lum")
/// is renamed with it.
Sequence renameFilters(Sequence sequence, Map<String, String> renames) {
  if (renames.isEmpty) return sequence;
  return sequence.copyWith(
    nodes: {
      for (final MapEntry(key: id, value: node) in sequence.nodes.entries)
        id: node.kind.renameFilters(node, renames),
    },
  );
}

/// The filter names a plan is checked and matched against: the connected
/// wheel's when it reports them, else the active equipment profile's.
final filterNamesToMatchProvider = Provider<List<String>>((ref) {
  final wheel = ref.watch(filterWheelStateProvider);
  if (wheel.connectionState == DeviceConnectionState.connected &&
      wheel.filterNames.isNotEmpty) {
    return wheel.filterNames;
  }
  return ref.watch(activeEquipmentProfileProvider)?.filterNames ??
      const <String>[];
});
