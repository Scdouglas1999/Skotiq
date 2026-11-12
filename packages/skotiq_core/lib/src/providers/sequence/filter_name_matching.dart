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
  final normalized = name.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  return switch (normalized) {
    'LUMINANCE' || 'LUMINOSITY' || 'LUM' || 'CLEAR' => 'L',
    'RED' => 'R',
    'GREEN' => 'G',
    'BLUE' => 'B',
    'HALPHA' || 'HA' || 'H' || 'HYDROGEN' || 'HYDROGENALPHA' => 'HA',
    'OIII' || 'O3' || 'OXYGEN' || 'OXYGENIII' => 'OIII',
    'SII' ||
    'S2' ||
    'SULFUR' ||
    'SULPHUR' ||
    'SULFURII' ||
    'SULPHURII' => 'SII',
    'NII' || 'N2' || 'NITROGEN' || 'NITROGENII' => 'NII',
    _ => normalized,
  };
}

/// The 0-based slot in [available] that [requested] means: the same name
/// ignoring case and surrounding space, else the first with the same
/// [canonicalFilterName], else the first whose canonical name contains the
/// request's or is contained in it ("Ha" finds "Ha 7nm"). A blank name or
/// request matches nothing. Null when none.
///
/// The same rule as `find_filter_match` in `bridge/src/filter_matching.rs`,
/// which picks the slot at run time; both are tested against
/// `test/fixtures/filter_matching_cases.json`.
int? matchingFilterIndex(String requested, List<String> available) {
  final canonical = canonicalFilterName(requested);
  if (canonical.isEmpty) return null;
  final wanted = requested.trim().toLowerCase();
  var index = available.indexWhere(
    (name) => name.trim().toLowerCase() == wanted,
  );
  if (index < 0) {
    index = available.indexWhere(
      (name) => canonicalFilterName(name) == canonical,
    );
  }
  if (index < 0) {
    index = available.indexWhere((name) {
      final other = canonicalFilterName(name);
      return other.isNotEmpty &&
          (other.contains(canonical) || canonical.contains(other));
    });
  }
  return index < 0 ? null : index;
}

/// The name in [available] that [requested] means (see
/// [matchingFilterIndex]). Null when none.
String? matchingFilterName(String requested, Iterable<String> available) {
  final names = available.toList();
  final index = matchingFilterIndex(requested, names);
  return index == null ? null : names[index];
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
