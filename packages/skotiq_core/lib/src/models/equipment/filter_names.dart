/// The filter-name rule. A filter's name stands for the set of bands it
/// names: split at spaces, slashes, dashes, underscores, plus signs and bars,
/// long spellings folded onto the short ones ("Luminance" and "Clear" are L,
/// "Red" is R, "H-alpha" is HA, "Sulfur II" is SII), and a bandwidth such as
/// "7nm" left out. "Ha 7nm" is HA, "Ha/OIII" is HA and OIII, "UV/IR Cut" is
/// UV, IR and CUT. Two names are the same filter when their bands are the
/// same; a name is never matched by a piece of another ("R" is not "Dark").
///
/// `filter_name.rs` in the native `skotiq_device` crate holds the same rule
/// for the run's wheel moves; both are tested against
/// `test/fixtures/filter_matching_cases.json`.
library;

const Map<String, String> _bandAliases = {
  'L': 'L',
  'LUM': 'L',
  'LUMINANCE': 'L',
  'LUMINOSITY': 'L',
  'CLEAR': 'L',
  'R': 'R',
  'RED': 'R',
  'G': 'G',
  'GREEN': 'G',
  'B': 'B',
  'BLUE': 'B',
  'H': 'HA',
  'HA': 'HA',
  'HALPHA': 'HA',
  'HYDROGEN': 'HA',
  'HYDROGENALPHA': 'HA',
  'HB': 'HB',
  'HBETA': 'HB',
  'HYDROGENBETA': 'HB',
  'OIII': 'OIII',
  'O3': 'OIII',
  'OXYGEN': 'OIII',
  'OXYGENIII': 'OIII',
  'SII': 'SII',
  'S2': 'SII',
  'SULFUR': 'SII',
  'SULPHUR': 'SII',
  'SULFURII': 'SII',
  'SULPHURII': 'SII',
  'NII': 'NII',
  'N2': 'NII',
  'NITROGEN': 'NII',
  'NITROGENII': 'NII',
};

final RegExp _separators = RegExp(r'[\s/\-_+|]+');
final RegExp _notAlphanumeric = RegExp(r'[^A-Za-z0-9]');
final RegExp _width = RegExp(
  r'^\d+([.,]\d+)?(nm|a|å|Å)$',
  caseSensitive: false,
);
final RegExp _number = RegExp(r'^\d+([.,]\d+)?$');
final RegExp _widthUnit = RegExp(r'^(nm|a|å|Å)$', caseSensitive: false);

String _letters(String text) =>
    text.replaceAll(_notAlphanumeric, '').toUpperCase();

/// The bands [name] names (see the library comment); empty for a blank name.
Set<String> filterBands(String name) {
  final whole = _letters(name);
  if (whole.isEmpty) return const {};
  if (_bandAliases[whole] case final band?) return {band};
  final words = name.split(_separators).where((w) => w.isNotEmpty).toList();
  final bands = <String>{};
  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    if (_width.hasMatch(word)) continue;
    final next = i + 1 < words.length ? words[i + 1] : null;
    if (next != null && _number.hasMatch(word) && _widthUnit.hasMatch(next)) {
      i++;
      continue;
    }
    final letters = _letters(word);
    if (letters.isEmpty) continue;
    if (next != null) {
      if (_bandAliases[letters + _letters(next)] case final band?) {
        bands.add(band);
        i++;
        continue;
      }
    }
    bands.add(_bandAliases[letters] ?? letters);
  }
  return bands;
}

/// [name]'s bands as one key ("HA+OIII"), the same for every spelling of one
/// filter and empty for no filter. Records (frames, goals, campaigns, flats)
/// are the same filter exactly when their keys are equal.
String filterIdentity(String name) =>
    (filterBands(name).toList()..sort()).join('+');

/// Whether [a] and [b] are the same filter by the filter-name rule. Two blank
/// names are the same (no filter); a blank and a named filter are not.
bool sameFilter(String a, String b) => filterIdentity(a) == filterIdentity(b);

/// The slots of [available] that [requested] could mean, closest first: the
/// slots with the same name ignoring case and surrounding space, else the
/// slots that are [sameFilter]. Empty for a blank request or no match.
List<int> filterSlotCandidates(String requested, List<String> available) {
  final identity = filterIdentity(requested);
  if (identity.isEmpty) return const [];
  final wanted = requested.trim().toLowerCase();
  final exact = [
    for (var i = 0; i < available.length; i++)
      if (available[i].trim().toLowerCase() == wanted) i,
  ];
  if (exact.isNotEmpty) return exact;
  return [
    for (var i = 0; i < available.length; i++)
      if (filterIdentity(available[i]) == identity) i,
  ];
}

/// Whether [requested] could mean more than one different slot of
/// [available] ("Ha" on a wheel with "Ha 3nm" and "Ha 7nm"). Such a request
/// names no slot; the operator has to say which.
bool isAmbiguousFilter(String requested, List<String> available) =>
    {
      for (final i in filterSlotCandidates(requested, available))
        available[i].trim().toLowerCase(),
    }.length >
    1;

/// The 0-based slot in [available] that [requested] means: the first slot
/// with the same name ignoring case and surrounding space, else the one slot
/// that is [sameFilter]. Null when no slot is, or when several are
/// ([isAmbiguousFilter]); a filter is never guessed.
///
/// The same rule as `match_filter_slot` in the native `filter_name.rs`, which
/// picks the slot at run time. Everything in the app that asks whether a
/// wheel has a filter, or which slot it is in, asks this.
int? matchingFilterIndex(String requested, List<String> available) {
  final candidates = filterSlotCandidates(requested, available);
  if (candidates.isEmpty || isAmbiguousFilter(requested, available)) {
    return null;
  }
  return candidates.first;
}

/// The name in [available] that [requested] means (see
/// [matchingFilterIndex]). Null when none.
String? matchingFilterName(String requested, Iterable<String> available) {
  final names = available.toList();
  final index = matchingFilterIndex(requested, names);
  return index == null ? null : names[index];
}
