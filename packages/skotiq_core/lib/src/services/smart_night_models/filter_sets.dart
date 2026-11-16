part of '../smart_night_models.dart';

/// A combination of filters a plan images through on one rig, as the Filters
/// picker lists it: a set Skotiq knows ([preset]), one filter alone, or a set
/// the user saved ([CustomFilterSet]). [key] names the set across screens and
/// nights, so a choice remembered for a target finds the same set again.
class FilterSet {
  const FilterSet._({
    required this.key,
    required this.label,
    required this.filters,
    this.preset,
  });

  /// [preset] through [filters], its wheel slots on this rig.
  FilterSet.preset(SmartNightStrategy preset, List<String> filters)
    : this._(
        key: preset.name,
        label: filterSetPresetLabel(preset),
        filters: List.unmodifiable(filters),
        preset: preset,
      );

  /// [filter] alone; [smartNightUnfilteredName] is no filter at all.
  FilterSet.single(String filter)
    : this._(
        key: '$_singlePrefix$filter',
        label: filter.trim().isEmpty
            ? 'No filter'
            : isMultiBandFilter(filter)
            ? '$filter, dual-band'
            : filter,
        filters: List.unmodifiable([filter]),
      );

  FilterSet._custom(String name, List<String> filters)
    : this._(
        key: '$_customPrefix$name',
        label: name,
        filters: List.unmodifiable(filters),
      );

  static const _singlePrefix = 'filter:';
  static const _customPrefix = 'custom:';

  /// Names the set: the preset's name, `filter:<slot>` or `custom:<name>`.
  final String key;

  /// What the picker and the plan call the set ("SHO", "LRGB + Ha").
  final String label;

  /// The wheel slots, in capture order.
  final List<String> filters;

  /// The set Skotiq knows this is; null for one filter alone and for a set
  /// the user saved.
  final SmartNightStrategy? preset;

  /// Whether the user saved this set.
  bool get isCustom => key.startsWith(_customPrefix);

  /// Share of the planned time each filter gets, by filter identity
  /// (`filterIdentity`); a filter not listed gets 1. LRGB gives luminance
  /// twice a color's time; a saved set gives every filter the same time.
  Map<String, double> get timeShares => switch (preset) {
    SmartNightStrategy.autoLrgb ||
    SmartNightStrategy.haLrgb => const {'L': 2.0},
    _ => const {},
  };

  /// The set's line in a plan's name or summary: its label, and its filters
  /// when the label does not already say them ("My HaRGB: Ha, R, G, B").
  String get description => isCustom ? '$label: ${filters.join(', ')}' : label;

  @override
  bool operator ==(Object other) =>
      other is FilterSet &&
      other.key == key &&
      _sameList(other.filters, filters);

  @override
  int get hashCode => Object.hash(key, Object.hashAll(filters));
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// What the Filters picker calls [preset].
String filterSetPresetLabel(SmartNightStrategy preset) => switch (preset) {
  SmartNightStrategy.autoLrgb => 'LRGB',
  SmartNightStrategy.monoLrgb => 'LRGB, equal time',
  SmartNightStrategy.haLrgb => 'LRGB + Ha',
  SmartNightStrategy.rgb => 'RGB',
  SmartNightStrategy.luminance => 'L',
  SmartNightStrategy.narrowbandSho => 'SHO',
  SmartNightStrategy.narrowbandHoo => 'HOO',
  SmartNightStrategy.narrowbandHa => 'Ha',
  SmartNightStrategy.narrowbandOiii => 'OIII',
  SmartNightStrategy.narrowbandSii => 'SII',
  SmartNightStrategy.oscOneShot => 'One filter',
};

/// A combination of filters the user built and named, kept per equipment
/// profile ([FilterSetPreferences]). [filters] are the wheel names as the
/// user ticked them; they are matched to the wheel by the filter-name rule
/// each time, so "Ha" still finds a slot renamed "Ha 7nm".
class CustomFilterSet {
  const CustomFilterSet({required this.name, required this.filters});

  final String name;
  final List<String> filters;

  /// This set on a wheel holding [availableFilters]; null unless every
  /// filter is on it.
  FilterSet? resolve(List<String> availableFilters) {
    final slots = [
      for (final filter in filters)
        matchingFilterName(filter, availableFilters),
    ];
    if (slots.isEmpty || slots.contains(null)) return null;
    return FilterSet._custom(name, slots.cast<String>());
  }

  Map<String, dynamic> toJson() => {'name': name, 'filters': filters};

  factory CustomFilterSet.fromJson(Map<String, dynamic> json) =>
      CustomFilterSet(
        name: json['name'] as String,
        filters: [for (final f in json['filters'] as List) f as String],
      );
}

/// One equipment profile's Filters picker state: the sets the user saved,
/// and the set the user picked for each target over Skotiq's choice
/// (target key, see [filterSetTargetKey], to [FilterSet.key]).
class FilterSetPreferences {
  const FilterSetPreferences({
    this.custom = const [],
    this.targetChoices = const {},
  });

  final List<CustomFilterSet> custom;
  final Map<String, String> targetChoices;

  /// The set the user picked for [target] among [sets], else
  /// [recommended]. A remembered set the rig can no longer image (a filter
  /// left the wheel) falls back to [recommended].
  FilterSet setFor(
    TargetSuggestion target, {
    required List<FilterSet> sets,
    required FilterSet recommended,
  }) {
    final key = targetChoices[filterSetTargetKey(target)];
    return sets.where((set) => set.key == key).firstOrNull ?? recommended;
  }

  /// With [set] remembered for [target]; picking [recommended] forgets the
  /// choice, so the target follows Skotiq's choice again.
  FilterSetPreferences choose(
    TargetSuggestion target,
    FilterSet set, {
    required FilterSet recommended,
  }) {
    final choices = Map<String, String>.of(targetChoices);
    final key = filterSetTargetKey(target);
    if (set.key == recommended.key) {
      choices.remove(key);
    } else {
      choices[key] = set.key;
    }
    return FilterSetPreferences(custom: custom, targetChoices: choices);
  }

  /// With [set] saved, replacing a saved set of the same name.
  FilterSetPreferences save(CustomFilterSet set) => FilterSetPreferences(
    custom: [
      for (final kept in custom)
        if (kept.name != set.name) kept,
      set,
    ],
    targetChoices: targetChoices,
  );

  /// Without the saved set [name]; targets that used it follow Skotiq's
  /// choice again.
  FilterSetPreferences delete(String name) => FilterSetPreferences(
    custom: [
      for (final kept in custom)
        if (kept.name != name) kept,
    ],
    targetChoices: {
      for (final entry in targetChoices.entries)
        if (entry.value != '${FilterSet._customPrefix}$name')
          entry.key: entry.value,
    },
  );

  Map<String, dynamic> toJson() => {
    'custom': [for (final set in custom) set.toJson()],
    'targets': targetChoices,
  };

  factory FilterSetPreferences.fromJson(Map<String, dynamic> json) =>
      FilterSetPreferences(
        custom: [
          for (final set in json['custom'] as List? ?? const [])
            CustomFilterSet.fromJson((set as Map).cast<String, dynamic>()),
        ],
        targetChoices: {
          for (final entry in (json['targets'] as Map? ?? const {}).entries)
            entry.key as String: entry.value as String,
        },
      );
}

/// The key a target's remembered filter set is kept under: its catalog
/// designation, else its name.
String filterSetTargetKey(TargetSuggestion target) =>
    target.catalogId ?? target.targetName;
