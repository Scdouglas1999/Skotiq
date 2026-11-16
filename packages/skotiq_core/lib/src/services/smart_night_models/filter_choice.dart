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
  /// offered beside [recommended] and never taken without the user (LRGB +
  /// Ha for a broadband target with catalogued emission regions inside it);
  /// null when there is none.
  final FilterSet? suggested;

  /// One line offering [suggested]; null with it.
  final String? suggestion;

  final List<String> _availableFilters;
  final bool _preferMultiBand;
  final bool _oneShotColor;
  final String _label;
  final String _why;

  const SmartNightFilterChoice._({
    required this.strategy,
    required this.filters,
    required this.reason,
    required String label,
    required String why,
    required this.suggested,
    required this.suggestion,
    required List<String> availableFilters,
    required bool preferMultiBand,
    required bool oneShotColor,
  }) : _label = label,
       _why = why,
       _availableFilters = availableFilters,
       _preferMultiBand = preferMultiBand,
       _oneShotColor = oneShotColor;

  /// The named filters on the rig's wheel or profile, in slot order; empty
  /// for no wheel.
  List<String> get wheelFilters => _availableFilters;

  /// The Filters picker's line for [recommended]
  /// ("Recommended: narrowband SHO, M1 is a supernova remnant.").
  String get recommendation {
    final lowered = _label.length > 1 && _label[1] == _label[1].toLowerCase()
        ? '${_label[0].toLowerCase()}${_label.substring(1)}'
        : _label;
    return 'Recommended: $lowered, $_why.';
  }

  /// The chosen set as the Filters picker lists it.
  FilterSet get recommended => strategy == SmartNightStrategy.oscOneShot
      ? FilterSet.single(filters.single)
      : FilterSet.preset(strategy, filters);

  /// The wheel slots [set] means for this target on this rig; empty when
  /// the wheel lacks what [set] needs.
  List<String> filtersFor(SmartNightStrategy set) => set == strategy
      ? filters
      : resolveSmartNightFilterSet(
          strategy: set,
          availableFilters: _availableFilters,
          preferMultiBand: _preferMultiBand,
        );

  /// The combinations this rig can image, for the Filters picker, in the
  /// order it lists them: [recommended] among them, then the user's
  /// [saved] sets whose every filter is on the wheel.
  ///
  /// A color camera images through one filter at a time: each filter on its
  /// wheel or profile alone, or no filter without one. A mono camera gets
  /// every set Skotiq knows whose filters are all on the wheel.
  List<FilterSet> sets({List<CustomFilterSet> saved = const []}) {
    final named = smartNightPlanningFilters(_availableFilters);
    final known = _oneShotColor || _availableFilters.isEmpty
        ? [for (final filter in named) FilterSet.single(filter)]
        : [
            for (final preset in filterSetPresetOrder)
              if (filtersFor(preset) case final slots when slots.isNotEmpty)
                FilterSet.preset(preset, slots),
          ];
    final custom = [
      for (final set in saved)
        if (set.resolve(_availableFilters) case final resolved?) resolved,
    ];
    final all = [...known, ...custom];
    return [
      if (!all.any((set) => set.key == recommended.key)) recommended,
      ...all,
    ];
  }

  /// The line for a plan built with [set]: [reason] when [set] is the
  /// chosen one, else that the user picked it.
  String reasonFor(FilterSet set) =>
      set.key == recommended.key ? reason : '${set.label}: your choice.';

  /// [suggestion] for a plan built with [set]: only the chosen set carries
  /// it, so a plan the user changed does not repeat the offer.
  String? suggestionFor(FilterSet set) =>
      set.key == recommended.key ? suggestion : null;
}

/// The order the Filters picker lists the sets Skotiq knows.
const List<SmartNightStrategy> filterSetPresetOrder = [
  SmartNightStrategy.autoLrgb,
  SmartNightStrategy.monoLrgb,
  SmartNightStrategy.rgb,
  SmartNightStrategy.luminance,
  SmartNightStrategy.haLrgb,
  SmartNightStrategy.narrowbandSho,
  SmartNightStrategy.narrowbandHoo,
  SmartNightStrategy.narrowbandHa,
  SmartNightStrategy.narrowbandOiii,
  SmartNightStrategy.narrowbandSii,
];

/// The filter set for [target] on a rig whose wheel holds
/// [availableFilters] (empty for no wheel).
///
/// - A color camera ([oneShotColor]) takes one filter: a dual-band filter
///   for a target with emission, else a broadband light filter, else none.
/// - An emission target is narrowband: SHO with Ha, OIII and SII on the
///   wheel, HOO with Ha and OIII, Ha alone with only Ha. Without Ha it falls
///   back to broadband.
/// - A broadband target is LRGB, else RGB, else L, narrowband only on a
///   wheel with none of those. When the catalog holds emission objects
///   inside the target's extent ([catalogedEmissionRegions], such as a
///   galaxy's HII regions) and the wheel has Ha, LRGB + Ha is offered
///   ([SmartNightFilterChoice.suggestion]) but not taken: people often image
///   a full night of LRGB and add Ha on a later night.
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
  }) {
    final offered = suggested == null
        ? null
        : FilterSet.preset(
            suggested,
            resolveSmartNightFilterSet(
              strategy: suggested,
              availableFilters: named,
            ),
          );
    final shown = label ?? smartNightStrategyLabel(set);
    return SmartNightFilterChoice._(
      strategy: set,
      filters: resolveSmartNightFilterSet(
        strategy: set,
        availableFilters: named,
        preferMultiBand: preferMultiBand,
      ),
      reason: '$shown: $why.',
      label: shown,
      why: why,
      suggested: offered,
      suggestion: offered == null
          ? null
          : '${target.targetName} holds $catalogedEmissionRegions '
                'emission region${catalogedEmissionRegions == 1 ? '' : 's'} in '
                'the catalog, and you have an Ha filter: add Ha to this plan '
                'or a later night.',
      availableFilters: named,
      preferMultiBand: preferMultiBand,
      oneShotColor: oneShotColor,
    );
  }

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
      label: isMultiBandFilter(filter)
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
  final broadband = const [
    SmartNightStrategy.autoLrgb,
    SmartNightStrategy.rgb,
    SmartNightStrategy.luminance,
  ].where(capturable).firstOrNull;
  const noBroadband = 'the wheel has no L, R, G or B filter';

  switch (light) {
    case TargetLight.emission:
      if (narrowband != null) return choose(narrowband, what);
      if (broadband != null) {
        return choose(broadband, '$what, but the wheel has no Ha filter');
      }
    case TargetLight.broadband:
      if (broadband != null) {
        return choose(
          broadband,
          what,
          suggested:
              broadband == SmartNightStrategy.autoLrgb &&
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
/// in capture order; empty unless the wheel has every filter the set
/// names. [SmartNightStrategy.oscOneShot] is one slot: a broadband light
/// filter (L, UV/IR cut, L-Pro, CLS) or, with [preferMultiBand] or when
/// there is no light filter, a dual- or multi-band filter; else the first
/// slot; else [smartNightUnfilteredName] for no wheel. A slot two names
/// could mean ("Ha 3nm" and "Ha 7nm" for Ha) is not guessed: that band
/// counts as missing.
List<String> resolveSmartNightFilterSet({
  required SmartNightStrategy strategy,
  required List<String> availableFilters,
  bool preferMultiBand = false,
}) {
  final named = [
    for (final f in availableFilters)
      if (f.trim().isNotEmpty) f,
  ];
  List<String> all(List<String> bands) {
    final slots = [for (final band in bands) matchingFilterName(band, named)];
    return slots.contains(null) ? const [] : slots.cast<String>();
  }

  switch (strategy) {
    case SmartNightStrategy.autoLrgb:
    case SmartNightStrategy.monoLrgb:
      return all(const ['L', 'R', 'G', 'B']);
    case SmartNightStrategy.haLrgb:
      return all(const ['L', 'R', 'G', 'B', 'Ha']);
    case SmartNightStrategy.rgb:
      return all(const ['R', 'G', 'B']);
    case SmartNightStrategy.luminance:
      return all(const ['L']);
    case SmartNightStrategy.narrowbandHa:
      return all(const ['Ha']);
    case SmartNightStrategy.narrowbandHoo:
      return all(const ['Ha', 'OIII']);
    case SmartNightStrategy.narrowbandSho:
      return all(const ['Ha', 'OIII', 'SII']);
    case SmartNightStrategy.narrowbandOiii:
      return all(const ['OIII']);
    case SmartNightStrategy.narrowbandSii:
      return all(const ['SII']);
    case SmartNightStrategy.oscOneShot:
      final multiBand = named.where(isMultiBandFilter);
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
      SmartNightStrategy.rgb => 'RGB',
      SmartNightStrategy.luminance => 'Luminance',
      SmartNightStrategy.narrowbandHa => 'Narrowband Ha',
      SmartNightStrategy.narrowbandHoo => 'Narrowband HOO',
      SmartNightStrategy.narrowbandSho => 'Narrowband SHO',
      SmartNightStrategy.narrowbandOiii => 'Narrowband OIII',
      SmartNightStrategy.narrowbandSii => 'Narrowband SII',
      SmartNightStrategy.oscOneShot => 'One filter',
    };

/// Broadband filters a color camera images through.
const Set<String> _lightFilterIdentities = {'L', 'UVIRCUT', 'LPRO', 'CLS'};

/// Whether [filter] passes Ha and OIII in one frame (L-eXtreme, ALP-T).
bool isMultiBandFilter(String filter) =>
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
