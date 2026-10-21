import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../models/planning/target_suggestion.dart';
import '../services/sesame_name_resolver.dart';
import 'simbad_provider.dart';
import 'target_suggestion_provider.dart';

// Planner-side sort options

/// UI-only sort modes for the planner workspace. These re-sort the already-
/// scored suggestion list without touching the scoring service.
enum PlannerSortMode {
  score,
  altitude,
  magnitude,
  size,
  constellation,
  objectType,
  catalogId,
}

// Filter state

/// Client-side filter state for narrowing down the suggestions list.
///
/// All fields default to null / empty, which means "no filter applied".
/// This sits between [tonightSuggestionsProvider] and the UI — the scoring
/// service and [TargetSuggestionConfig] are never modified by these filters.
class SuggestionFilterState {
  final double? minMagnitude;
  final double? maxMagnitude;
  final double? minSizeArcmin;
  final double? maxSizeArcmin;
  final Set<String> selectedConstellations;
  final double? minMoonDistance;
  final double? minImagingHours;

  /// Free-text search applied to target name / catalog id / common name.
  final String searchQuery;

  /// Multi-select object type filter. An empty set means "no filter".
  /// Matching is case-insensitive substring against [TargetSuggestion.objectType].
  final Set<String> selectedObjectTypes;

  /// Filter on the target's altitude RIGHT NOW (not the night peak). Null
  /// means "no filter". Distinct from the scoring service's [minAltitude],
  /// which is evaluated against the entire night window.
  final double? minCurrentAltitude;

  /// UI-only sort override for the planner workspace. Null means "use the
  /// upstream [TargetSuggestionConfig.sortMode]".
  final PlannerSortMode? plannerSort;

  const SuggestionFilterState({
    this.minMagnitude,
    this.maxMagnitude,
    this.minSizeArcmin,
    this.maxSizeArcmin,
    this.selectedConstellations = const {},
    this.minMoonDistance,
    this.minImagingHours,
    this.searchQuery = '',
    this.selectedObjectTypes = const {},
    this.minCurrentAltitude,
    this.plannerSort,
  });

  SuggestionFilterState copyWith({
    double? Function()? minMagnitude,
    double? Function()? maxMagnitude,
    double? Function()? minSizeArcmin,
    double? Function()? maxSizeArcmin,
    Set<String>? selectedConstellations,
    double? Function()? minMoonDistance,
    double? Function()? minImagingHours,
    String? searchQuery,
    Set<String>? selectedObjectTypes,
    double? Function()? minCurrentAltitude,
    PlannerSortMode? Function()? plannerSort,
  }) {
    return SuggestionFilterState(
      minMagnitude: minMagnitude != null ? minMagnitude() : this.minMagnitude,
      maxMagnitude: maxMagnitude != null ? maxMagnitude() : this.maxMagnitude,
      minSizeArcmin: minSizeArcmin != null
          ? minSizeArcmin()
          : this.minSizeArcmin,
      maxSizeArcmin: maxSizeArcmin != null
          ? maxSizeArcmin()
          : this.maxSizeArcmin,
      selectedConstellations:
          selectedConstellations ?? this.selectedConstellations,
      minMoonDistance: minMoonDistance != null
          ? minMoonDistance()
          : this.minMoonDistance,
      minImagingHours: minImagingHours != null
          ? minImagingHours()
          : this.minImagingHours,
      searchQuery: searchQuery ?? this.searchQuery,
      selectedObjectTypes: selectedObjectTypes ?? this.selectedObjectTypes,
      minCurrentAltitude: minCurrentAltitude != null
          ? minCurrentAltitude()
          : this.minCurrentAltitude,
      plannerSort: plannerSort != null ? plannerSort() : this.plannerSort,
    );
  }

  /// Returns the number of active (non-default) filters.
  int get activeCount {
    int count = 0;
    if (minMagnitude != null) count++;
    if (maxMagnitude != null) count++;
    if (minSizeArcmin != null) count++;
    if (maxSizeArcmin != null) count++;
    if (selectedConstellations.isNotEmpty) count++;
    if (minMoonDistance != null) count++;
    if (minImagingHours != null) count++;
    if (searchQuery.trim().isNotEmpty) count++;
    if (selectedObjectTypes.isNotEmpty) count++;
    if (minCurrentAltitude != null) count++;
    return count;
  }
}

// Providers

/// Holds the current UI filter state. Defaults = no filtering.
final suggestionFilterProvider = StateProvider<SuggestionFilterState>(
  (ref) => const SuggestionFilterState(),
);

List<TargetSuggestion> _applyFilters(
  List<TargetSuggestion> suggestions,
  SuggestionFilterState filters,
) {
  // Fast path: no filters active
  if (filters.activeCount == 0) return suggestions;

  return suggestions.where((s) => _passesAllFilters(s, filters)).toList();
}

/// Returns true iff [s] passes every active filter in [filters].
bool _passesAllFilters(TargetSuggestion s, SuggestionFilterState filters) {
  if (filters.minMagnitude != null) {
    if (s.magnitude == null) return false;
    if (s.magnitude! < filters.minMagnitude!) return false;
  }
  if (filters.maxMagnitude != null) {
    if (s.magnitude == null) return false;
    if (s.magnitude! > filters.maxMagnitude!) return false;
  }
  if (filters.minSizeArcmin != null) {
    if (s.sizeArcmin == null) return false;
    if (s.sizeArcmin! < filters.minSizeArcmin!) return false;
  }
  if (filters.maxSizeArcmin != null) {
    if (s.sizeArcmin == null) return false;
    if (s.sizeArcmin! > filters.maxSizeArcmin!) return false;
  }
  if (filters.selectedConstellations.isNotEmpty) {
    if (s.constellation == null) return false;
    if (!filters.selectedConstellations.contains(s.constellation)) return false;
  }
  if (filters.minMoonDistance != null) {
    if (s.visibility.moonDistance < filters.minMoonDistance!) return false;
  }
  if (filters.minImagingHours != null) {
    final hours = s.visibility.hoursAboveMinAlt;
    if (hours == null) return false;
    if (hours < filters.minImagingHours!) return false;
  }
  if (filters.searchQuery.trim().isNotEmpty) {
    if (!_matchesSearchQuery(s, filters.searchQuery)) return false;
  }
  if (filters.selectedObjectTypes.isNotEmpty) {
    if (!_matchesObjectTypes(s, filters.selectedObjectTypes)) return false;
  }
  if (filters.minCurrentAltitude != null) {
    if (s.visibility.currentAltitude < filters.minCurrentAltitude!) {
      return false;
    }
  }
  return true;
}

bool _matchesSearchQuery(TargetSuggestion s, String rawQuery) {
  final q = rawQuery.trim().toLowerCase();
  if (q.isEmpty) return true;
  final qNoSpace = q.replaceAll(RegExp(r'\s+'), '');
  final candidates = <String>[
    s.targetName.toLowerCase(),
    s.targetName.toLowerCase().replaceAll(RegExp(r'\s+'), ''),
    if (s.catalogId != null) s.catalogId!.toLowerCase(),
    if (s.catalogId != null)
      s.catalogId!.toLowerCase().replaceAll(RegExp(r'\s+'), ''),
    if (s.constellation != null) s.constellation!.toLowerCase(),
  ];
  return candidates.any((c) => c.contains(q) || c.contains(qNoSpace));
}

bool _matchesObjectTypes(TargetSuggestion s, Set<String> selected) {
  final raw = (s.objectType ?? '').toLowerCase();
  if (raw.isEmpty) return false;
  for (final type in selected) {
    final t = type.toLowerCase();
    if (raw.contains(t)) return true;
    // Map UI canonical buckets onto the catalog's free-text object types.
    final aliases = _objectTypeAliases[t];
    if (aliases != null && aliases.any((a) => raw.contains(a))) {
      return true;
    }
  }
  return false;
}

/// Format an arcminute value for compact display in filter labels.
/// Sub-arcminute values render in arcseconds (e.g. `45"`); otherwise arcminutes
/// with one decimal (e.g. `12.4'`).
String _formatArcminLabel(double arcmin) {
  if (arcmin < 1.0) {
    final arcsec = arcmin * 60.0;
    return '${arcsec.toStringAsFixed(0)}"';
  }
  return "${arcmin.toStringAsFixed(1)}'";
}

const Map<String, List<String>> _objectTypeAliases = {
  'galaxy': ['galaxy', 'galaxies'],
  'nebula': ['nebula', 'emission', 'reflection', 'dark nebula', 'hii', 'h ii'],
  'cluster': ['cluster', 'association'],
  'planetary': ['planetary nebula'],
  'supernova remnant': ['supernova', 'snr'],
  'comet': ['comet'],
  'asteroid': ['asteroid', 'minor planet'],
};

// Derived / convenience providers

/// Extracts sorted unique constellation abbreviations from the full
/// (unfiltered) suggestion list.
final availableConstellationsProvider = Provider.autoDispose<List<String>>((
  ref,
) {
  final suggestionsAsync = ref.watch(tonightSuggestionsProvider);

  return suggestionsAsync.when(
    data: (suggestions) {
      final constellations = <String>{};
      for (final s in suggestions) {
        if (s.constellation != null && s.constellation!.isNotEmpty) {
          constellations.add(s.constellation!);
        }
      }
      final sorted = constellations.toList()..sort();
      return sorted;
    },
    loading: () => <String>[],
    error: (_, __) => <String>[],
  );
});

/// Returns the (min, max) magnitude range present in the unfiltered data.
/// Returns null if no suggestions have magnitude data.
final availableMagnitudeRangeProvider = Provider.autoDispose<(double, double)?>(
  (ref) {
    final suggestionsAsync = ref.watch(tonightSuggestionsProvider);

    return suggestionsAsync.when(
      data: (suggestions) {
        double? lo;
        double? hi;
        for (final s in suggestions) {
          if (s.magnitude != null) {
            final m = s.magnitude!;
            if (lo == null || m < lo) lo = m;
            if (hi == null || m > hi) hi = m;
          }
        }
        if (lo == null || hi == null) return null;
        return (lo, hi);
      },
      loading: () => null,
      error: (_, __) => null,
    );
  },
);

/// Returns the (min, max) angular size range (arcmin) present in the
/// unfiltered data. Returns null if no suggestions have size data.
final availableSizeRangeProvider = Provider.autoDispose<(double, double)?>((
  ref,
) {
  final suggestionsAsync = ref.watch(tonightSuggestionsProvider);

  return suggestionsAsync.when(
    data: (suggestions) {
      double? lo;
      double? hi;
      for (final s in suggestions) {
        if (s.sizeArcmin != null && s.sizeArcmin! > 0) {
          final sz = s.sizeArcmin!;
          if (lo == null || sz < lo) lo = sz;
          if (hi == null || sz > hi) hi = sz;
        }
      }
      if (lo == null || hi == null) return null;
      return (lo, hi);
    },
    loading: () => null,
    error: (_, __) => null,
  );
});

// Planner workspace providers

/// Per-filter breakdown of how many suggestions the planner UI excluded.
/// Used by the empty-state hint to tell the user which constraint is hurting.
class FilterExclusionBreakdown {
  final int total;
  final int passed;
  final Map<String, int> excludedByFilter;

  const FilterExclusionBreakdown({
    required this.total,
    required this.passed,
    required this.excludedByFilter,
  });

  /// Filter label (or null) responsible for the largest single exclusion.
  String? get worstOffender {
    String? worst;
    int worstCount = 0;
    excludedByFilter.forEach((label, count) {
      if (count > worstCount) {
        worstCount = count;
        worst = label;
      }
    });
    return worst;
  }
}

/// Suggestions after applying the planner filters AND the planner sort.
final plannerFilteredSuggestionsProvider =
    Provider.autoDispose<AsyncValue<List<TargetSuggestion>>>((ref) {
      final suggestionsAsync = ref.watch(tonightSuggestionsProvider);
      final filters = ref.watch(suggestionFilterProvider);

      return suggestionsAsync.when(
        data: (suggestions) {
          final filtered = _applyFilters(suggestions, filters);
          final sortMode = filters.plannerSort ?? PlannerSortMode.score;
          final sorted = _sortPlannerSuggestions(filtered, sortMode);
          return AsyncData(sorted);
        },
        loading: () => const AsyncLoading(),
        error: (error, stackTrace) => AsyncError(error, stackTrace),
      );
    });

/// Builds a breakdown of which planner filters excluded the most candidates.
/// Empty filters report zero; a filter is counted once per suggestion it
/// removed, even when other filters would have removed the same suggestion.
final plannerFilterExclusionProvider =
    Provider.autoDispose<FilterExclusionBreakdown>((ref) {
      final suggestionsAsync = ref.watch(tonightSuggestionsProvider);
      final filters = ref.watch(suggestionFilterProvider);

      final suggestions =
          suggestionsAsync.valueOrNull ?? const <TargetSuggestion>[];
      final breakdown = <String, int>{};

      int countExcluded(String label, bool Function(TargetSuggestion) reject) {
        final n = suggestions.where(reject).length;
        if (n > 0) breakdown[label] = n;
        return n;
      }

      if (filters.searchQuery.trim().isNotEmpty) {
        countExcluded(
          'Search "${filters.searchQuery.trim()}"',
          (s) => !_matchesSearchQuery(s, filters.searchQuery),
        );
      }
      if (filters.selectedObjectTypes.isNotEmpty) {
        countExcluded(
          'Object type filter',
          (s) => !_matchesObjectTypes(s, filters.selectedObjectTypes),
        );
      }
      if (filters.selectedConstellations.isNotEmpty) {
        countExcluded(
          'Constellation filter',
          (s) =>
              s.constellation == null ||
              !filters.selectedConstellations.contains(s.constellation),
        );
      }
      if (filters.minMagnitude != null) {
        countExcluded(
          'Min magnitude ${filters.minMagnitude!.toStringAsFixed(1)}',
          (s) => s.magnitude == null || s.magnitude! < filters.minMagnitude!,
        );
      }
      if (filters.maxMagnitude != null) {
        countExcluded(
          'Max magnitude ${filters.maxMagnitude!.toStringAsFixed(1)}',
          (s) => s.magnitude == null || s.magnitude! > filters.maxMagnitude!,
        );
      }
      if (filters.minSizeArcmin != null) {
        countExcluded(
          'Min size ${_formatArcminLabel(filters.minSizeArcmin!)}',
          (s) => s.sizeArcmin == null || s.sizeArcmin! < filters.minSizeArcmin!,
        );
      }
      if (filters.maxSizeArcmin != null) {
        countExcluded(
          'Max size ${_formatArcminLabel(filters.maxSizeArcmin!)}',
          (s) => s.sizeArcmin == null || s.sizeArcmin! > filters.maxSizeArcmin!,
        );
      }
      if (filters.minCurrentAltitude != null) {
        countExcluded(
          'Min altitude now ${filters.minCurrentAltitude!.toStringAsFixed(0)}°',
          (s) => s.visibility.currentAltitude < filters.minCurrentAltitude!,
        );
      }
      if (filters.minMoonDistance != null) {
        countExcluded(
          'Min moon separation ${filters.minMoonDistance!.toStringAsFixed(0)}°',
          (s) => s.visibility.moonDistance < filters.minMoonDistance!,
        );
      }

      final passed = suggestions
          .where((s) => _passesAllFilters(s, filters))
          .length;

      return FilterExclusionBreakdown(
        total: suggestions.length,
        passed: passed,
        excludedByFilter: breakdown,
      );
    });

/// External-catalog (SIMBAD) name-search results for the planner search bar.
///
/// Watches the planner search query, debounces ~350 ms, then asks SIMBAD to
/// resolve the name (exact object first, then identifiers containing it). Empty when query has fewer than 3
/// characters. Failure returns an empty list (logged) so the planner search
/// keeps working when SIMBAD is unreachable.
///
/// Why family-keyed: each new keystroke watches a NEW provider instance, and
/// the previous one is no longer subscribed — autoDispose tears it down
/// before its delayed work resolves, which is the cleanest cancellation
/// pattern in Riverpod 2.x without pulling in a CancelToken dependency.
final plannerSimbadResultsProvider = FutureProvider.autoDispose
    .family<List<SimbadNameMatch>, String>((ref, query) async {
      final trimmed = query.trim();
      if (trimmed.length < 3) return const <SimbadNameMatch>[];

      // Why an explicit Timer instead of Future.delayed: the dart:async Timer
      // can be cancelled when ref is disposed (next keystroke arrives), which
      // matters for widget tests — Future.delayed schedules a Timer that
      // remains pending after the tree disposes and trips the framework's
      // !timersPending invariant.
      final completer = Completer<void>();
      final debounceTimer = Timer(const Duration(milliseconds: 350), () {
        if (!completer.isCompleted) completer.complete();
      });
      var cancelled = false;
      ref.onDispose(() {
        cancelled = true;
        debounceTimer.cancel();
        if (!completer.isCompleted) completer.complete();
      });

      await completer.future;
      if (cancelled) return const <SimbadNameMatch>[];

      final results = await SimbadProvider(
        sesame: ref.read(sesameNameResolverProvider),
      ).searchByName(trimmed);
      if (cancelled) return const <SimbadNameMatch>[];
      return results;
    });

/// Installed-catalog search results for the planner search bar.
///
/// The main candidate list is intentionally limited to targets that survived
/// tonight's scoring constraints. This provider searches the locally installed
/// catalogs directly so a query can still surface objects that exist in the
/// database but are not recommendation candidates right now.
final plannerInstalledCatalogSearchProvider = FutureProvider.autoDispose
    .family<List<CatalogSearchResult>, String>((ref, query) async {
      final trimmed = query.trim();
      if (trimmed.length < 2) return const <CatalogSearchResult>[];

      final manager = CatalogManager.instance;
      if (!manager.isInitialized) return const <CatalogSearchResult>[];

      final suggestions =
          ref.watch(tonightSuggestionsProvider).valueOrNull ??
          const <TargetSuggestion>[];
      final existingKeys = <String>{};
      for (final suggestion in suggestions) {
        existingKeys.add(_catalogSearchKey(suggestion.targetName));
        final catalogId = suggestion.catalogId;
        if (catalogId != null && catalogId.isNotEmpty) {
          existingKeys.add(_catalogSearchKey(catalogId));
        }
      }

      final results = await manager.search(trimmed);
      return results
          .where((result) {
            final resultKeys = <String>{
              _catalogSearchKey(result.name),
              _catalogSearchKey(result.catalogId),
            };
            return resultKeys.intersection(existingKeys).isEmpty;
          })
          .take(12)
          .toList(growable: false);
    });

/// Installed-catalog name search with NO exclusions.
///
/// [plannerInstalledCatalogSearchProvider] deliberately hides objects that are
/// already in tonight's scored candidate list, because there it is a
/// "beyond tonight's candidates" supplement. Anything that needs to put a
/// catalog object INTO the target library (the project Add Target sheet) needs
/// the opposite: M31 must be findable precisely because it is a good target
/// tonight. Same underlying search, different question.
final installedCatalogSearchProvider = FutureProvider.autoDispose
    .family<List<CatalogSearchResult>, String>((ref, query) async {
      final trimmed = query.trim();
      if (trimmed.length < 2) return const <CatalogSearchResult>[];

      final manager = CatalogManager.instance;
      if (!manager.isInitialized) return const <CatalogSearchResult>[];

      final results = await manager.search(trimmed);
      return results.take(20).toList(growable: false);
    });

String _catalogSearchKey(String value) =>
    value.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');

List<TargetSuggestion> _sortPlannerSuggestions(
  List<TargetSuggestion> suggestions,
  PlannerSortMode mode,
) {
  final copy = List<TargetSuggestion>.of(suggestions);
  switch (mode) {
    case PlannerSortMode.score:
      copy.sort((a, b) => b.totalScore.compareTo(a.totalScore));
      break;
    case PlannerSortMode.altitude:
      copy.sort((a, b) {
        final aAlt = a.visibility.peakAltitude ?? a.visibility.currentAltitude;
        final bAlt = b.visibility.peakAltitude ?? b.visibility.currentAltitude;
        return bAlt.compareTo(aAlt);
      });
      break;
    case PlannerSortMode.magnitude:
      // Brighter (smaller magnitude number) first. Nulls sink.
      copy.sort((a, b) {
        if (a.magnitude == null && b.magnitude == null) return 0;
        if (a.magnitude == null) return 1;
        if (b.magnitude == null) return -1;
        return a.magnitude!.compareTo(b.magnitude!);
      });
      break;
    case PlannerSortMode.size:
      // Largest first. Nulls/zero sink to the bottom.
      copy.sort((a, b) {
        final aSize = (a.sizeArcmin != null && a.sizeArcmin! > 0)
            ? a.sizeArcmin!
            : null;
        final bSize = (b.sizeArcmin != null && b.sizeArcmin! > 0)
            ? b.sizeArcmin!
            : null;
        if (aSize == null && bSize == null) return 0;
        if (aSize == null) return 1;
        if (bSize == null) return -1;
        return bSize.compareTo(aSize);
      });
      break;
    case PlannerSortMode.constellation:
      copy.sort((a, b) {
        final ac = a.constellation ?? '';
        final bc = b.constellation ?? '';
        if (ac.isEmpty && bc.isEmpty) return 0;
        if (ac.isEmpty) return 1;
        if (bc.isEmpty) return -1;
        final c = ac.compareTo(bc);
        return c != 0 ? c : b.totalScore.compareTo(a.totalScore);
      });
      break;
    case PlannerSortMode.objectType:
      copy.sort((a, b) {
        final at = a.objectType ?? '';
        final bt = b.objectType ?? '';
        if (at.isEmpty && bt.isEmpty) return 0;
        if (at.isEmpty) return 1;
        if (bt.isEmpty) return -1;
        final c = at.toLowerCase().compareTo(bt.toLowerCase());
        return c != 0 ? c : b.totalScore.compareTo(a.totalScore);
      });
      break;
    case PlannerSortMode.catalogId:
      copy.sort((a, b) {
        final aid = a.catalogId ?? a.targetName;
        final bid = b.catalogId ?? b.targetName;
        return aid.toLowerCase().compareTo(bid.toLowerCase());
      });
      break;
  }
  return copy;
}
