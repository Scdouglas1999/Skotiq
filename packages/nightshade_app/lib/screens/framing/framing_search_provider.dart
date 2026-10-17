import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_planetarium/nightshade_planetarium.dart';

/// State for the target search in Framing tool
class TargetSearchState {
  final String query;
  final List<FramingTarget> results;
  final bool isSearching;
  final String? errorMessage;

  const TargetSearchState({
    this.query = '',
    this.results = const [],
    this.isSearching = false,
    this.errorMessage,
  });

  TargetSearchState copyWith({
    String? query,
    List<FramingTarget>? results,
    bool? isSearching,
    String? errorMessage,
    bool clearError = false,
  }) {
    return TargetSearchState(
      query: query ?? this.query,
      results: results ?? this.results,
      isSearching: isSearching ?? this.isSearching,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class TargetSearchNotifier extends StateNotifier<TargetSearchState> {
  final Ref _ref;
  int _requestRevision = 0;

  TargetSearchNotifier(this._ref) : super(const TargetSearchState());

  Future<void> search(String query) async {
    final trimmedQuery = query.trim();
    final revision = ++_requestRevision;
    if (trimmedQuery.isEmpty) {
      state = const TargetSearchState();
      return;
    }

    state = TargetSearchState(query: trimmedQuery, isSearching: true);

    try {
      final results = <FramingTarget>[];
      final qLower = trimmedQuery.toLowerCase();

      // Normalize query
      final normalizedQuery = qLower.replaceAll(RegExp(r'\s+'), '');

      // Search DSOs using the planetarium's loaded database
      final loadedDsos = await _ref.read(loadedDsosProvider.future);
      if (revision != _requestRevision || !mounted) return;

      final matchingDsos = loadedDsos
          .where((o) {
            final idLower = o.id.toLowerCase();
            final nameLower = o.name.toLowerCase();

            // Direct matches
            if (idLower.contains(qLower) || nameLower.contains(qLower)) {
              return true;
            }
            if (o.catalogIds.any((c) => c.toLowerCase().contains(qLower))) {
              return true;
            }

            // Normalized matches
            final normalizedId = idLower.replaceAll(RegExp(r'\s+'), '');
            if (normalizedId.contains(normalizedQuery)) return true;

            final normalizedName = nameLower.replaceAll(RegExp(r'\s+'), '');
            if (normalizedName.contains(normalizedQuery)) return true;

            if (o.catalogIds.any((c) {
              final cNormalized =
                  c.toLowerCase().replaceAll(RegExp(r'\s+'), '');
              return cNormalized.contains(normalizedQuery);
            })) {
              return true;
            }

            return false;
          })
          .take(50)
          .toList();

      // Convert to FramingTarget
      for (final dso in matchingDsos) {
        TargetType targetType;
        switch (dso.type) {
          case DsoType.galaxy:
          case DsoType.galaxyPair:
          case DsoType.galaxyTriplet:
          case DsoType.galaxyGroup:
            targetType = TargetType.galaxy;
            break;
          case DsoType.nebula:
          case DsoType.emissionNebula:
          case DsoType.reflectionNebula:
          case DsoType.planetaryNebula:
          case DsoType.darkNebula:
          case DsoType.hiiRegion:
          case DsoType.supernova:
            targetType = TargetType.nebula;
            break;
          case DsoType.openCluster:
          case DsoType.globularCluster:
          case DsoType.clusterWithNebulosity:
          case DsoType.association:
          case DsoType.starCloud:
            targetType = TargetType.cluster;
            break;
          case DsoType.star:
          case DsoType.doubleStar:
          case DsoType.nova:
            targetType = TargetType.star;
            break;
          default:
            targetType = TargetType.other;
        }

        results.add(FramingTarget(
          name: dso.name,
          raHours: dso.coordinates.ra,
          decDegrees: dso.coordinates.dec,
          catalogId: dso.id,
          magnitude: dso.magnitude,
          sizeArcmin: dso.sizeArcMin,
          type: targetType,
          objectType: dso.type.displayName,
        ));
      }

      // Sort results
      results.sort((a, b) {
        // Exact matches first (including normalized)
        final aName = a.name.toLowerCase();
        final bName = b.name.toLowerCase();
        final aId = a.catalogId?.toLowerCase();
        final bId = b.catalogId?.toLowerCase();

        // Check exact match
        bool isExact(String val) => val == qLower || val == normalizedQuery;

        final aExact = isExact(aName) || (aId != null && isExact(aId));
        final bExact = isExact(bName) || (bId != null && isExact(bId));

        if (aExact && !bExact) return -1;
        if (!aExact && bExact) return 1;

        // Then by magnitude (brighter first)
        return (a.magnitude ?? 99).compareTo(b.magnitude ?? 99);
      });

      state = TargetSearchState(
        query: trimmedQuery,
        results: results,
        isSearching: false,
      );
    } catch (error, stackTrace) {
      if (revision != _requestRevision || !mounted) return;
      _ref.read(loggingServiceProvider).error(
        '[Framing] Local catalog search failed: $error',
        source: 'TargetSearchNotifier',
        fields: {'error': error.toString(), 'stackTrace': '$stackTrace'},
      );
      state = TargetSearchState(
        query: trimmedQuery,
        results: [],
        isSearching: false,
        errorMessage: 'Local catalog search is unavailable.',
      );
    }
  }

  Future<void> retry() => search(state.query);

  void clear() {
    _requestRevision++;
    state = const TargetSearchState();
  }
}

// autoDispose: search results are page-scoped to the Framing screen. Stale
// query/results should not survive navigation away.
final targetSearchProvider =
    StateNotifierProvider.autoDispose<TargetSearchNotifier, TargetSearchState>(
        (ref) {
  return TargetSearchNotifier(ref);
});
