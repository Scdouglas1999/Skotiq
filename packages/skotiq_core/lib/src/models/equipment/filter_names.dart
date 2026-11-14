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
/// `test/fixtures/filter_matching_cases.json`. Everything in the app that
/// asks whether a wheel has a filter, or which slot it is in, asks this.
int? matchingFilterIndex(String requested, List<String> available) {
  final tier = _closestMatches(requested, available);
  return tier.isEmpty ? null : tier.first;
}

/// The name in [available] that [requested] means (see
/// [matchingFilterIndex]). Null when none.
String? matchingFilterName(String requested, Iterable<String> available) {
  final names = available.toList();
  final index = matchingFilterIndex(requested, names);
  return index == null ? null : names[index];
}

/// The name in [recorded] (filters as frames, goals or campaigns record them,
/// blank for none) that [requested] means: the first blank one for a blank
/// request, otherwise [matchingFilterName]'s. Null when none.
String? matchingRecordedFilter(String requested, Iterable<String> recorded) =>
    requested.trim().isEmpty
    ? recorded.where((name) => name.trim().isEmpty).firstOrNull
    : matchingFilterName(requested, recorded);

/// Every name in [available] that [requested] means at the closest step of
/// [matchingFilterIndex]'s rule: all spellings equal ignoring case, else all
/// with the same canonical name, else all that contain it or are contained in
/// it. Frames filed under several spellings of one filter ("Ha", "ha") all
/// count for it; a closer spelling hides a looser one, as on a wheel.
List<String> matchingFilterNames(String requested, Iterable<String> available) {
  final names = available.toList();
  return [for (final i in _closestMatches(requested, names)) names[i]];
}

List<int> _closestMatches(String requested, List<String> available) {
  final canonical = canonicalFilterName(requested);
  if (canonical.isEmpty) return const [];
  List<int> where(bool Function(String name) matches) => [
    for (var i = 0; i < available.length; i++)
      if (matches(available[i])) i,
  ];
  final wanted = requested.trim().toLowerCase();
  var tier = where((name) => name.trim().toLowerCase() == wanted);
  if (tier.isEmpty) {
    tier = where((name) => canonicalFilterName(name) == canonical);
  }
  if (tier.isEmpty) {
    tier = where((name) {
      final other = canonicalFilterName(name);
      return other.isNotEmpty &&
          (other.contains(canonical) || canonical.contains(other));
    });
  }
  return tier;
}
