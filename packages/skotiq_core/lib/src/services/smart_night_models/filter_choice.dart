part of '../smart_night_models.dart';

// Which filters a target is imaged through on a rig. Every automatic plan
// (Image tonight, the Build sequence recipe, Smart Night, the planner's
// suggested filters and sub length) asks [chooseSmartNightFilters]; a filter
// set the user picks instead is mapped to wheel slots by
// [resolveSmartNightFilterSet]. Wheel slots are matched by the filter-name
// rule (`filter_names.dart`), so "Ha 7nm" is Ha and "Dark" is never R.

/// What light a target gives, read from its catalog object type. Nothing
/// here names an object: the class comes from the type the catalog gives.
///
/// The deep-sky catalog types a nebula emission or reflection from published
/// emission and reflection catalogs (the nebula light table, see
/// `dsoTypeFromOpenNgcCode`): a nebula OpenNGC files only as "Neb" or
/// "Cl+N" reads "Reflection Nebula" or "Cluster + Emission Nebula" when one
/// of those catalogs classifies it.
enum TargetLight {
  /// Line emission, imaged through narrowband filters: emission nebulae, HII
  /// regions, supernova remnants, planetary nebulae, a cluster in an
  /// emission nebula, and a nebula no catalog classifies further (OpenNGC
  /// "Neb" or "Cl+N" with no match in the nebula light table).
  emission,

  /// Starlight, imaged through LRGB: galaxies, reflection and dark nebulae,
  /// a cluster in a reflection nebula, clusters, stars, and a target whose
  /// type is not known.
  broadband,
}

/// The light [objectType] gives. Reads the app's type names ("Supernova
/// Remnant", "Cluster + Nebula"), OpenNGC codes ("SNR", "Cl+N") and SIMBAD
/// codes ("HII", "PN", "RNe"). A type naming emission is emission even when
/// it names reflection too; a reflection or dark nebula is broadband; any
/// other nebula is emission.
TargetLight targetLight(String? objectType) {
  final type = (objectType ?? '').toLowerCase();
  final words = type
      .split(RegExp('[^a-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toSet();
  final emission =
      type.contains('emission') ||
      type.contains('supernova') ||
      type.contains('planetary') ||
      type.contains('h ii') ||
      words.contains('hii') ||
      words.contains('snr') ||
      words.contains('pn') ||
      words.contains('emn');
  final reflection =
      type.contains('reflection') ||
      words.contains('rfn') ||
      words.contains('rne');
  final dark =
      type.contains('dark') || words.contains('drkn') || words.contains('dne');
  final nebula =
      type.contains('nebul') || type.contains('cl+n') || words.contains('neb');

  if (emission) return TargetLight.emission;
  if (reflection || dark) return TargetLight.broadband;
  if (nebula) return TargetLight.emission;
  return TargetLight.broadband;
}

/// The filter set chosen for one target on one rig, and why.
class SmartNightFilterChoice {
  /// The set chosen.
  final SmartNightStrategy strategy;

  /// The wheel slots [strategy] means on this rig, in capture order;
  /// [smartNightUnfilteredName] alone for a rig with no wheel.
  final List<String> filters;

  /// One line for the user: the set and the reason
  /// ("Narrowband SHO: {target} is a supernova remnant.").
  final String reason;

  /// A set that would also suit the target and that the wheel can capture,
  /// offered beside [strategy] and never taken without the user
  /// ([SmartNightStrategy.haLrgb] for a broadband target with catalogued
  /// emission regions inside it); null when there is none.
  final SmartNightStrategy? suggested;

  /// One line offering [suggested]; null with it.
  final String? suggestion;

  final List<String> _availableFilters;
  final bool _preferMultiBand;

  const SmartNightFilterChoice._({
    required this.strategy,
    required this.filters,
    required this.reason,
    required this.suggested,
    required this.suggestion,
    required List<String> availableFilters,
    required bool preferMultiBand,
  }) : _availableFilters = availableFilters,
       _preferMultiBand = preferMultiBand;

  /// The wheel slots [set] means for this target on this rig; empty when
  /// the wheel lacks what [set] needs.
  List<String> filtersFor(SmartNightStrategy set) => set == strategy
      ? filters
      : resolveSmartNightFilterSet(
          strategy: set,
          availableFilters: _availableFilters,
          preferMultiBand: _preferMultiBand,
        );

  /// The sets this rig can capture, the chosen one among them.
  List<SmartNightStrategy> get capturable => [
    for (final set in SmartNightStrategy.values)
      if (filtersFor(set).isNotEmpty) set,
  ];

  /// The line for a plan built with [set]: [reason] when [set] is the
  /// chosen one, else that the user picked it.
  String reasonFor(SmartNightStrategy set) => set == strategy
      ? reason
      : '${smartNightStrategyLabel(set)}: your choice.';

  /// [suggestion] for a plan built with [set]: only the chosen set carries
  /// it, so a plan the user changed does not repeat the offer.
  String? suggestionFor(SmartNightStrategy set) =>
      set == strategy ? suggestion : null;
}

/// The filter set for [target] on a rig whose wheel holds
/// [availableFilters] (empty for no wheel).
///
/// - A color camera ([oneShotColor]) takes one filter: a dual-band filter
///   for a target with emission, else a broadband light filter, else none.
/// - An emission target is narrowband: SHO with Ha, OIII and SII on the
///   wheel, HOO with Ha and OIII, Ha alone with only Ha. Without Ha it falls
///   back to LRGB.
/// - A broadband target is LRGB (with whichever of L, R, G and B the wheel
///   has), narrowband only on a wheel with none of them. When the catalog
///   holds emission objects inside the target's extent
///   ([catalogedEmissionRegions], such as a galaxy's HII regions) and the
///   wheel has Ha, LRGB + Ha is offered ([SmartNightFilterChoice.suggestion])
///   but not taken: people often image a full night of LRGB and add Ha on a
///   later night.
/// - A wheel that names no known band takes one filter, its first slot.
SmartNightFilterChoice chooseSmartNightFilters({
  required TargetSuggestion target,
  required List<String> availableFilters,
  bool oneShotColor = false,
  int catalogedEmissionRegions = 0,
}) {
  final light = targetLight(target.objectType);
  final preferMultiBand = light == TargetLight.emission;
  final named = [
    for (final f in availableFilters)
      if (f.trim().isNotEmpty) f,
  ];
  final kind = _objectKindPhrase(target.objectType);
  final what = kind == null
      ? '${target.targetName} has no object type in the catalog'
      : '${target.targetName} is $kind';

  SmartNightFilterChoice choose(
    SmartNightStrategy set,
    String why, {
    String? label,
    SmartNightStrategy? suggested,
  }) => SmartNightFilterChoice._(
    strategy: set,
    filters: resolveSmartNightFilterSet(
      strategy: set,
      availableFilters: named,
      preferMultiBand: preferMultiBand,
    ),
    reason: '${label ?? smartNightStrategyLabel(set)}: $why.',
    suggested: suggested,
    suggestion: suggested == null
        ? null
        : '${target.targetName} holds $catalogedEmissionRegions '
              'emission region${catalogedEmissionRegions == 1 ? '' : 's'} in '
              'the catalog, and you have an Ha filter: add Ha to this plan or '
              'a later night.',
    availableFilters: named,
    preferMultiBand: preferMultiBand,
  );

  if (named.isEmpty) {
    return choose(
      SmartNightStrategy.oscOneShot,
      'this rig has no filter wheel',
      label: oneShotColor ? 'One-shot color' : 'No filter',
    );
  }

  if (oneShotColor) {
    final filter = resolveSmartNightFilterSet(
      strategy: SmartNightStrategy.oscOneShot,
      availableFilters: named,
      preferMultiBand: preferMultiBand,
    ).single;
    return choose(
      SmartNightStrategy.oscOneShot,
      '$what, and the camera is a color camera',
      label: _isMultiBand(filter)
          ? 'One-shot color through $filter'
          : 'One-shot color',
    );
  }

  bool capturable(SmartNightStrategy set) => resolveSmartNightFilterSet(
    strategy: set,
    availableFilters: named,
  ).isNotEmpty;
  final narrowband = const [
    SmartNightStrategy.narrowbandSho,
    SmartNightStrategy.narrowbandHoo,
    SmartNightStrategy.narrowbandHa,
  ].where(capturable).firstOrNull;
  final hasBroadband = capturable(SmartNightStrategy.autoLrgb);
  const noBroadband = 'the wheel has no L, R, G or B filter';

  switch (light) {
    case TargetLight.emission:
      if (narrowband != null) return choose(narrowband, what);
      if (hasBroadband) {
        return choose(
          SmartNightStrategy.autoLrgb,
          '$what, but the wheel has no Ha filter',
        );
      }
    case TargetLight.broadband:
      if (hasBroadband) {
        return choose(
          SmartNightStrategy.autoLrgb,
          what,
          suggested:
              catalogedEmissionRegions > 0 &&
                  capturable(SmartNightStrategy.haLrgb)
              ? SmartNightStrategy.haLrgb
              : null,
        );
      }
      if (narrowband != null) {
        return choose(narrowband, '$what, but $noBroadband');
      }
  }
  final single = resolveSmartNightFilterSet(
    strategy: SmartNightStrategy.oscOneShot,
    availableFilters: named,
    preferMultiBand: preferMultiBand,
  ).single;
  return choose(
    SmartNightStrategy.oscOneShot,
    'the wheel names no L, R, G, B, Ha, OIII or SII filter',
    label: 'One filter, $single',
  );
}

/// The wheel slots [strategy] means on a wheel holding [availableFilters],
/// in capture order. A narrowband set needs each of its filters; LRGB takes
/// whichever of L, R, G and B are there; LRGB + Ha needs Ha and one of them.
/// [SmartNightStrategy.oscOneShot] is one slot: a broadband light filter
/// (L, UV/IR cut, L-Pro, CLS) or, with [preferMultiBand] or when there is no
/// light filter, a dual- or multi-band filter; else the first slot; else
/// [smartNightUnfilteredName] for no wheel. A slot two names could mean
/// ("Ha 3nm" and "Ha 7nm" for Ha) is not guessed: that band counts as
/// missing.
List<String> resolveSmartNightFilterSet({
  required SmartNightStrategy strategy,
  required List<String> availableFilters,
  bool preferMultiBand = false,
}) {
  final named = [
    for (final f in availableFilters)
      if (f.trim().isNotEmpty) f,
  ];
  String? slot(String band) => matchingFilterName(band, named);
  List<String> all(List<String> bands) {
    final slots = bands.map(slot).toList();
    return slots.contains(null) ? const [] : slots.cast<String>();
  }

  final lrgb = [
    for (final band in const ['L', 'R', 'G', 'B'])
      if (slot(band) case final name?) name,
  ];

  switch (strategy) {
    case SmartNightStrategy.autoLrgb:
    case SmartNightStrategy.monoLrgb:
      return lrgb;
    case SmartNightStrategy.haLrgb:
      final ha = slot('Ha');
      return ha == null || lrgb.isEmpty ? const [] : [...lrgb, ha];
    case SmartNightStrategy.narrowbandHa:
      return all(const ['Ha']);
    case SmartNightStrategy.narrowbandHoo:
      return all(const ['Ha', 'OIII']);
    case SmartNightStrategy.narrowbandSho:
      return all(const ['Ha', 'OIII', 'SII']);
    case SmartNightStrategy.oscOneShot:
      final multiBand = named.where(_isMultiBand);
      final light = named.where(
        (f) => _lightFilterIdentities.contains(filterIdentity(f)),
      );
      final preferred = preferMultiBand
          ? [...multiBand, ...light]
          : [...light, ...multiBand];
      if (preferred.isNotEmpty) return [preferred.first];
      if (named.isNotEmpty) return [named.first];
      return const [smartNightUnfilteredName];
  }
}

/// The name of [strategy] for the user, as plans and reasons say it.
String smartNightStrategyLabel(SmartNightStrategy strategy) =>
    switch (strategy) {
      SmartNightStrategy.autoLrgb => 'LRGB',
      SmartNightStrategy.monoLrgb => 'LRGB, equal time',
      SmartNightStrategy.haLrgb => 'LRGB + Ha',
      SmartNightStrategy.narrowbandHa => 'Narrowband Ha',
      SmartNightStrategy.narrowbandHoo => 'Narrowband HOO',
      SmartNightStrategy.narrowbandSho => 'Narrowband SHO',
      SmartNightStrategy.oscOneShot => 'One filter',
    };

/// Broadband filters a color camera images through.
const Set<String> _lightFilterIdentities = {'L', 'UVIRCUT', 'LPRO', 'CLS'};

/// Whether [filter] passes Ha and OIII in one frame (L-eXtreme, ALP-T).
bool _isMultiBand(String filter) =>
    filterBands(filter).containsAll(const {'HA', 'OIII'});

/// "a supernova remnant", "an HII region" for an object type; null when
/// the type is unknown. Words in capitals (HII, SNR) keep them.
String? _objectKindPhrase(String? objectType) {
  final type = objectType?.trim() ?? '';
  if (type.isEmpty) return null;
  final phrase = type
      .split(RegExp(r'\s+'))
      .map((w) => w.length > 1 && w == w.toUpperCase() ? w : w.toLowerCase())
      .join(' ')
      .replaceAll(' + ', ' and ');
  final first = phrase[0];
  final vowelSound =
      'aeiou'.contains(first) || RegExp('^H[A-Z]').hasMatch(phrase);
  return '${vowelSound ? 'an' : 'a'} $phrase';
}
