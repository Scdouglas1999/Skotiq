import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/equipment/equipment_models.dart';
import '../../models/sequence/sequence_models.dart';
import '../equipment_provider.dart';
import '../profiles_provider.dart';

/// The validation issue code of a step naming a filter the wheel or the
/// equipment profile does not list by that name.
const String kFilterNameMismatchCode = 'filter_name_mismatch';

/// [name] as the native filter wheel matches it: letters and digits only,
/// upper case, with the common long names folded onto the short ones
/// ("Lum", "Luminance", "Clear" are "L"; "Red" is "R"; "H-alpha" is "HA").
///
/// Mirrors `normalize_filter_name` in `bridge/src/filter_matching.rs`, which
/// is how a Change Filter step finds its slot at run time.
String canonicalFilterName(String name) {
  final normalized =
      name.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  return switch (normalized) {
    'LUMINANCE' || 'LUM' || 'CLEAR' => 'L',
    'RED' => 'R',
    'GREEN' => 'G',
    'BLUE' => 'B',
    'HALPHA' || 'HA' || 'H' => 'HA',
    'OIII' || 'O3' || 'OXYGENIII' => 'OIII',
    'SII' || 'S2' || 'SULFURII' => 'SII',
    _ => normalized,
  };
}

/// The filter in [available] that [requested] means: the same name ignoring
/// case, else the one with the same [canonicalFilterName]. Null when none.
String? matchingFilterName(String requested, Iterable<String> available) {
  final wanted = requested.trim().toLowerCase();
  for (final name in available) {
    if (name.trim().toLowerCase() == wanted) return name;
  }
  final canonical = canonicalFilterName(requested);
  for (final name in available) {
    if (canonicalFilterName(name) == canonical) return name;
  }
  return null;
}

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
