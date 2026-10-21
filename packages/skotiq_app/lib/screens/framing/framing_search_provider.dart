import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

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
  List<RankedTarget> _ranked = const [];
  String? _rankedQuery;

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
      final loadedDsos = await _ref.read(loadedDsosProvider.future);
      if (revision != _requestRevision || !mounted) return;

      _ranked = TargetNameResolver.rank(trimmedQuery, loadedDsos);
      _rankedQuery = trimmedQuery;
      final results = [for (final r in _ranked) framingTargetFromDso(r.object)];

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

  /// What Enter on [query] should do.
  ///
  /// Ranks the query itself rather than reading [state], which can still hold
  /// the previous keystroke's results (or none, while the catalog loads):
  /// Enter used to fall through to SIMBAD in that window and take whatever
  /// substring match came back first.
  ///
  /// A single object named exactly by the query is selected. Several exact
  /// matches, or only partial ones, leave the list open to pick from. With no
  /// exact local match the name goes to SIMBAD's exact resolver.
  Future<TargetSubmitOutcome> submit(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const TargetSubmitOutcome.none();
    if (_rankedQuery != trimmed || state.isSearching) {
      await search(trimmed);
    }
    // The user kept typing while the catalog was searched: this Enter is stale.
    if (!mounted || state.query != trimmed) {
      return const TargetSubmitOutcome.none();
    }
    if (state.errorMessage == null && _rankedQuery == trimmed) {
      switch (TargetNameResolver.decide(_ranked)) {
        case SelectTarget(:final object):
          return TargetSubmitOutcome.select(framingTargetFromDso(object));
        case ChooseTarget():
          return const TargetSubmitOutcome.choose();
        case ResolveTargetOnline():
          break;
      }
    }

    final revision = _requestRevision;
    state = state.copyWith(isSearching: true);
    try {
      final resolved =
          await _ref.read(sesameNameResolverProvider).resolve(trimmed);
      if (!mounted || revision != _requestRevision) {
        return const TargetSubmitOutcome.none();
      }
      state = state.copyWith(isSearching: false);
      if (resolved != null) {
        return TargetSubmitOutcome.select(
          FramingTarget(
            name: resolved.mainId,
            catalogId: resolved.mainId,
            raHours: resolved.raHours,
            decDegrees: resolved.decDegrees,
            objectType: resolved.objectType,
          ),
        );
      }
      if (state.results.isNotEmpty) return const TargetSubmitOutcome.choose();
      return TargetSubmitOutcome.failed(
          'No object named "$trimmed" was found.');
    } on TargetNameLookupUnavailable catch (error) {
      if (!mounted || revision != _requestRevision) {
        return const TargetSubmitOutcome.none();
      }
      state = state.copyWith(isSearching: false);
      _ref.read(loggingServiceProvider).warning(
            '[Framing] Online name lookup unavailable: ${error.message}',
            source: 'TargetSearchNotifier',
          );
      if (state.results.isNotEmpty) return const TargetSubmitOutcome.choose();
      return TargetSubmitOutcome.failed(
        '"$trimmed" is not in the installed catalog and SIMBAD could not be '
        'reached to look it up.',
      );
    }
  }

  void clear() {
    _requestRevision++;
    _ranked = const [];
    _rankedQuery = null;
    state = const TargetSearchState();
  }
}

/// Result of [TargetSearchNotifier.submit].
class TargetSubmitOutcome {
  /// The object to frame, when the query named exactly one.
  final FramingTarget? target;

  /// Why nothing could be selected, for the user.
  final String? failure;

  /// Leave the result list open so the user can pick.
  final bool showList;

  const TargetSubmitOutcome.select(FramingTarget this.target)
      : failure = null,
        showList = false;
  const TargetSubmitOutcome.choose()
      : target = null,
        failure = null,
        showList = true;
  const TargetSubmitOutcome.failed(String this.failure)
      : target = null,
        showList = false;
  const TargetSubmitOutcome.none()
      : target = null,
        failure = null,
        showList = false;
}

/// A catalog object as a framing target.
FramingTarget framingTargetFromDso(DeepSkyObject dso) {
  final TargetType targetType;
  switch (dso.type) {
    case DsoType.galaxy:
    case DsoType.galaxyPair:
    case DsoType.galaxyTriplet:
    case DsoType.galaxyGroup:
      targetType = TargetType.galaxy;
    case DsoType.nebula:
    case DsoType.emissionNebula:
    case DsoType.reflectionNebula:
    case DsoType.planetaryNebula:
    case DsoType.darkNebula:
    case DsoType.hiiRegion:
    case DsoType.supernova:
      targetType = TargetType.nebula;
    case DsoType.openCluster:
    case DsoType.globularCluster:
    case DsoType.clusterWithNebulosity:
    case DsoType.association:
    case DsoType.starCloud:
      targetType = TargetType.cluster;
    case DsoType.star:
    case DsoType.doubleStar:
    case DsoType.nova:
      targetType = TargetType.star;
    default:
      targetType = TargetType.other;
  }
  return FramingTarget(
    name: dso.name,
    raHours: dso.coordinates.ra,
    decDegrees: dso.coordinates.dec,
    catalogId: dso.id,
    magnitude: dso.magnitude,
    sizeArcmin: dso.sizeArcMin,
    type: targetType,
    objectType: dso.type.displayName,
  );
}

// autoDispose: search results are page-scoped to the Framing screen. Stale
// query/results should not survive navigation away.
final targetSearchProvider =
    StateNotifierProvider.autoDispose<TargetSearchNotifier, TargetSearchState>(
        (ref) {
  return TargetSearchNotifier(ref);
});
