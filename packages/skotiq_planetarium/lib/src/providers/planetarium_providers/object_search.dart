part of '../planetarium_providers.dart';

enum SearchObjectTypeFilter { all, stars, galaxies, nebulae, clusters }

class SearchFilters {
  final SearchObjectTypeFilter typeFilter;
  final double? minMagnitude;
  final double? maxMagnitude;
  final bool observableNow;
  final String? constellationFilter;

  const SearchFilters({
    this.typeFilter = SearchObjectTypeFilter.all,
    this.minMagnitude,
    this.maxMagnitude,
    this.observableNow = false,
    this.constellationFilter,
  });

  SearchFilters copyWith({
    SearchObjectTypeFilter? typeFilter,
    double? minMagnitude,
    double? maxMagnitude,
    bool? observableNow,
    String? constellationFilter,
    bool clearMinMagnitude = false,
    bool clearMaxMagnitude = false,
    bool clearConstellation = false,
  }) {
    return SearchFilters(
      typeFilter: typeFilter ?? this.typeFilter,
      minMagnitude: clearMinMagnitude
          ? null
          : (minMagnitude ?? this.minMagnitude),
      maxMagnitude: clearMaxMagnitude
          ? null
          : (maxMagnitude ?? this.maxMagnitude),
      observableNow: observableNow ?? this.observableNow,
      constellationFilter: clearConstellation
          ? null
          : (constellationFilter ?? this.constellationFilter),
    );
  }

  bool get hasActiveFilters =>
      typeFilter != SearchObjectTypeFilter.all ||
      minMagnitude != null ||
      maxMagnitude != null ||
      observableNow ||
      constellationFilter != null;
}

/// A scored search result with match quality information
class ScoredSearchResult {
  final CelestialObject object;

  /// 0 = best (exact match), higher = worse match quality
  final int score;

  /// Which field matched (for display purposes)
  final String matchSource;

  const ScoredSearchResult({
    required this.object,
    required this.score,
    required this.matchSource,
  });
}

class ObjectSearchState {
  final String query;
  final List<CelestialObject> results;
  final bool isSearching;
  final SearchFilters filters;

  const ObjectSearchState({
    this.query = '',
    this.results = const [],
    this.isSearching = false,
    this.filters = const SearchFilters(),
  });

  ObjectSearchState copyWith({
    String? query,
    List<CelestialObject>? results,
    bool? isSearching,
    SearchFilters? filters,
  }) {
    return ObjectSearchState(
      query: query ?? this.query,
      results: results ?? this.results,
      isSearching: isSearching ?? this.isSearching,
      filters: filters ?? this.filters,
    );
  }
}

final RegExp _whitespaceRun = RegExp(r'\s+');

/// Whether [text] has a character `\s` matches. Most catalog names have
/// none, and this skips the regular expression for them.
bool _hasWhitespace(String text) {
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c <= 0x20) {
      if (c == 0x20 || (c >= 0x09 && c <= 0x0D)) return true;
    } else if (c >= 0xA0 &&
        (c == 0xA0 ||
            c == 0x1680 ||
            (c >= 0x2000 && c <= 0x200A) ||
            c == 0x2028 ||
            c == 0x2029 ||
            c == 0x202F ||
            c == 0x205F ||
            c == 0x3000 ||
            c == 0xFEFF)) {
      return true;
    }
  }
  return false;
}

/// A search string prepared once for matching against every catalog name.
class _SearchQuery {
  factory _SearchQuery(String query) {
    final lower = query.toLowerCase();
    return _SearchQuery._(
      lower,
      lower.replaceAll(_whitespaceRun, ''),
      _splitDesignation(lower),
    );
  }

  _SearchQuery._(this.lower, this.compact, this.designation)
    : designationDigits = designation?.number.toString();

  final String lower;

  /// [lower] without whitespace.
  final String compact;

  /// The query as a catalog designation (`NGC 7331` -> `('ngc', 7331)`).
  final ({String prefix, int number})? designation;

  /// The digits every designation with [designation]'s number contains.
  final String? designationDigits;
}

/// Levenshtein distance between two strings, for fuzzy matching in search.
int _levenshteinDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  var prevRow = Int32List(b.length + 1);
  var currRow = Int32List(b.length + 1);
  for (var j = 0; j <= b.length; j++) {
    prevRow[j] = j;
  }

  for (var i = 1; i <= a.length; i++) {
    currRow[0] = i;
    final ai = a.codeUnitAt(i - 1);
    for (var j = 1; j <= b.length; j++) {
      final cost = ai == b.codeUnitAt(j - 1) ? 0 : 1;
      final insertion = currRow[j - 1] + 1;
      final deletion = prevRow[j] + 1;
      final substitution = prevRow[j - 1] + cost;
      var best = insertion < deletion ? insertion : deletion;
      if (substitution < best) best = substitution;
      currRow[j] = best;
    }
    final temp = prevRow;
    prevRow = currRow;
    currRow = temp;
  }
  return prevRow[b.length];
}

/// The edit distance between [a] and [b] when it is at most [maxDistance],
/// else null. Lengths that differ by more than that answer without the
/// distance.
int? _distanceWithin(String a, String b, int maxDistance) {
  if ((a.length - b.length).abs() > maxDistance) return null;
  final distance = _levenshteinDistance(a, b);
  return distance <= maxDistance ? distance : null;
}

/// Score a query match against a target string.
/// Returns null if no match, or a score (lower = better).
/// 0 = exact match, 1 = starts with, 2 = contains, 3+ = fuzzy match
int? _scoreMatch(_SearchQuery query, String target) {
  final q = query.lower;
  final qNorm = query.compact;
  final t = target.toLowerCase();
  final spaced = _hasWhitespace(t);
  final tNorm = spaced ? t.replaceAll(_whitespaceRun, '') : t;

  if (t == q || tNorm == qNorm) return 0;

  if (t.startsWith(q) || tNorm.startsWith(qNorm)) return 1;

  if (t.contains(q) || tNorm.contains(qNorm)) return 2;

  // Fuzzy match: only if query is >= 3 chars to avoid too many false positives
  if (q.length >= 3) {
    // For short targets, compare directly
    if (tNorm.length <= qNorm.length + 3) {
      // Allow edit distance up to ~30% of query length, minimum 1
      final maxDist = math.max(1, (qNorm.length * 0.35).floor());
      final dist = _distanceWithin(qNorm, tNorm, maxDist);
      if (dist != null) return 3 + dist;
    }

    // For longer targets, check each word
    final maxDist = math.max(1, (q.length * 0.35).floor());
    for (final word in spaced ? t.split(_whitespaceRun) : [t]) {
      if (word.length >= q.length - 2) {
        final dist = _distanceWithin(q, word, maxDist);
        if (dist != null) return 3 + dist;
      }
    }
  }

  return null; // No match
}

/// Rank given to a result whose catalogue designation IS the query.
///
/// Below 0 so it outranks every [_scoreMatch] band, including the exact
/// whole-string match at 0 — a designation match is the same idea expressed
/// tolerantly (`ngc 6720` / `NGC6720` / `6720` all name one object).
const int _exactDesignationScore = -1;

/// Catalogues in which a bare number is conventional shorthand for a target.
///
/// Deliberately narrow. Observers say "6888" or "7000" and mean NGC; nobody
/// says "48915" and means HD, so a bare number must not promote stars — that
/// would just replace one wrong first result with another.
const Set<String> _bareNumberCatalogs = {'m', 'ngc', 'ic'};

/// Split a catalogue designation into its prefix and number, e.g.
/// `NGC 6720` -> `('ngc', 6720)`, `Messier 42` -> `('m', 42)`,
/// `Sh2-129` -> `('sh2', 129)`, `IC0059` -> `('ic', 59)`, `6720` -> `('', 6720)`.
///
/// Returns null for anything that is not a single prefix + number, which keeps
/// survey identifiers like `2MASX J21422663+1234093` or `ESO 287-052` out of
/// designation matching entirely.
({String prefix, int number})? _splitDesignation(String value) {
  final known = CatalogDesignation.parse(value);
  if (known != null && known.suffix.isEmpty) {
    return (prefix: known.catalog.toLowerCase(), number: known.number);
  }
  final normalized = value.toLowerCase().replaceAll(_designationSeparators, '');
  final match = _bareDesignation.firstMatch(normalized);
  if (match == null) return null;
  final number = int.tryParse(match.group(2)!);
  if (number == null) return null;
  return (prefix: match.group(1)!, number: number);
}

final RegExp _designationSeparators = RegExp(r'[\s_]+');
final RegExp _bareDesignation = RegExp(r'^([a-z]*)0*(\d+)$');

/// Whether [designation] is the object the designation-shaped [query] names.
///
/// A prefixed query pins the catalogue (`ugc 6720` must not answer NGC6720);
/// a bare number is only honoured for [_bareNumberCatalogs].
bool _isExactDesignation(_SearchQuery query, String designation) {
  final wanted = query.designation;
  if (wanted == null) return false;
  // A designation with this number spells its digits out; most catalog ids
  // do not, and skip the parse.
  if (!designation.contains(query.designationDigits!)) return false;
  final parsed = _splitDesignation(designation);
  if (parsed == null || parsed.number != wanted.number) return false;
  if (wanted.prefix.isEmpty) return _bareNumberCatalogs.contains(parsed.prefix);
  return parsed.prefix == wanted.prefix;
}

/// Map of well-known star proper names to their common designations
const Map<String, String> _wellKnownStarNames = {
  'north star': 'Polaris',
  'pole star': 'Polaris',
  'dog star': 'Sirius',
  'evening star': 'Vega',
  'summer triangle': 'Vega',
  'barnard\'s star': 'Barnard\'s Star',
};

/// A solar-system body (major planet, comet, or asteroid) exposed to the
/// unified search as a searchable [CelestialObject].
///
/// Positions are computed on demand from the orbital theory (VSOP87 for
/// planets, Keplerian propagation for minor bodies), so the omnibox resolves
/// "jupiter" or "ceres" whether or not the sky overlay is on.
///
/// Each body is wrapped as a [SolarSystemBody] (a [Star] subtype) under the
/// same ids the sky-view tap handler uses (`PLANET_<name>` /
/// `MINORBODY_<name>`), so selection, fly-to and the details panel treat a
/// searched planet identically to a tapped one.
final solarSystemSearchObjectsProvider = Provider<List<CelestialObject>>((ref) {
  final time = ref.watch(observationMinuteProvider);
  final objects = <CelestialObject>[];

  for (final planet in PlanetaryPositions.getAllPlanetPositions(time)) {
    objects.add(
      SolarSystemBody(
        id: 'PLANET_${planet.name}',
        name: planet.name,
        coordinates: CelestialCoordinate(ra: planet.ra, dec: planet.dec),
        kind: SolarSystemBodyKind.planet,
        magnitude: planet.magnitude,
      ),
    );
  }

  final minorBodies = KeplerianPropagator.computePositions(
    elements: ref.watch(effectiveMinorBodyElementsProvider),
    time: time,
  );
  for (final body in minorBodies) {
    objects.add(
      SolarSystemBody(
        id: 'MINORBODY_${body.name}',
        name: body.name,
        coordinates: body.coordinates,
        kind: SolarSystemBodyKind.minorBody,
        magnitude: body.visualMag,
      ),
    );
  }

  return objects;
});

/// Hands the isolate back to the event loop between slices of a catalog
/// scan, so frames and input keep being handled while a search walks the
/// whole star catalog, and ends the scan once a newer search replaced it.
class _ScanSlicer {
  _ScanSlicer(this._isCurrent);

  final bool Function() _isCurrent;
  final Stopwatch _slice = Stopwatch()..start();

  /// Under one frame at 60 Hz, leaving room for the frame itself.
  static const int _sliceMicroseconds = 8000;

  /// Whether the scan at object [index] has used up its slice. Read every
  /// 256 objects.
  bool due(int index) =>
      index & 0xFF == 0 && _slice.elapsedMicroseconds >= _sliceMicroseconds;

  /// Lets queued events run; false when the scan should stop because a newer
  /// search started.
  Future<bool> yieldSlice() async {
    await Future<void>.delayed(Duration.zero);
    _slice.reset();
    return _isCurrent();
  }
}

class ObjectSearchNotifier extends StateNotifier<ObjectSearchState> {
  final Ref _ref;
  int _searchGeneration = 0;

  ObjectSearchNotifier(this._ref) : super(const ObjectSearchState());

  void updateFilters(SearchFilters filters) {
    state = state.copyWith(filters: filters);
    if (state.query.isNotEmpty) {
      search(state.query);
    }
  }

  Future<void> search(String query) async {
    final generation = ++_searchGeneration;
    if (query.isEmpty) {
      state = ObjectSearchState(filters: state.filters);
      return;
    }

    state = state.copyWith(query: query, isSearching: true);

    // Catalogue numbers are zero-padded in cross-identifiers, so a plain
    // substring match on a typed designation drags in every object whose
    // PGC/UGC digits happen to contain it. A designation-shaped query resolves
    // its own catalogue entry first, deterministically.
    final q = _SearchQuery(query.trim());
    final filters = state.filters;
    final slicer = _ScanSlicer(() => _canPublish(generation));

    try {
      final scored = <ScoredSearchResult>[];

      // Check well-known name mappings first for DSO names
      final wellKnownIds = <String>{};
      for (final entry in kWellKnownDsoNames.entries) {
        final score = _scoreMatch(q, entry.key);
        if (score != null) {
          wellKnownIds.addAll(
            entry.value.map((v) => v.toLowerCase().replaceAll(' ', '')),
          );
        }
      }

      // Check well-known star name aliases
      String? starNameAlias;
      for (final entry in _wellKnownStarNames.entries) {
        final score = _scoreMatch(q, entry.key);
        if (score != null) {
          starNameAlias = entry.value.toLowerCase();
          break;
        }
      }

      if (filters.typeFilter == SearchObjectTypeFilter.all ||
          filters.typeFilter == SearchObjectTypeFilter.stars) {
        try {
          final loadedStars = await _ref.read(loadedStarsProvider.future);
          for (var i = 0; i < loadedStars.length; i++) {
            if (slicer.due(i) && !await slicer.yieldSlice()) return;
            final star = loadedStars[i];
            if (!_passesFilters(star, filters)) continue;

            // "HD 48915" names one star; nothing weaker may outrank it.
            if (_isExactDesignation(q, star.id) ||
                star.catalogIds.any((id) => _isExactDesignation(q, id))) {
              scored.add(
                ScoredSearchResult(
                  object: star,
                  score: _exactDesignationScore,
                  matchSource: 'designation',
                ),
              );
              continue;
            }

            // Check proper name
            final nameScore = _scoreMatch(q, star.name);
            if (nameScore != null) {
              scored.add(
                ScoredSearchResult(
                  object: star,
                  score: nameScore,
                  matchSource: 'name',
                ),
              );
              continue;
            }

            if (starNameAlias != null &&
                star.name.toLowerCase().contains(starNameAlias)) {
              scored.add(
                ScoredSearchResult(
                  object: star,
                  score: 2,
                  matchSource: 'alias',
                ),
              );
              continue;
            }

            // Check catalog IDs (HIP, HD, HR)
            final idScore = _scoreMatch(q, star.id);
            if (idScore != null) {
              scored.add(
                ScoredSearchResult(
                  object: star,
                  score: idScore + 1, // Slightly lower priority than name
                  matchSource: 'id',
                ),
              );
              continue;
            }

            for (final catId in star.catalogIds) {
              final catScore = _scoreMatch(q, catId);
              if (catScore != null) {
                scored.add(
                  ScoredSearchResult(
                    object: star,
                    score: catScore + 1,
                    matchSource: 'catalog',
                  ),
                );
                break;
              }
            }
          }
        } catch (e) {
          developer.log(
            '[Planetarium] Star search error: $e',
            name: 'PlanetariumProviders',
            level: 900,
            error: e,
          );
        }
      }

      if (filters.typeFilter == SearchObjectTypeFilter.all ||
          filters.typeFilter != SearchObjectTypeFilter.stars) {
        try {
          final loadedDsos = await _ref.read(loadedDsosProvider.future);
          final catalogIds = {for (final d in loadedDsos) d.id};

          final dsos = [
            ...loadedDsos,
            // The Pleiades, M40 and a few Caldwell objects are not in the
            // downloaded OpenNGC file; search them too.
            ...kSupplementalDsos.where((d) => !catalogIds.contains(d.id)),
          ];
          for (var i = 0; i < dsos.length; i++) {
            if (slicer.due(i) && !await slicer.yieldSlice()) return;
            final dso = dsos[i];
            if (!_passesDsoTypeFilter(dso, filters.typeFilter)) continue;
            if (!_passesFilters(dso, filters)) continue;

            int? bestScore;
            String matchSource = 'id';

            // Check well-known ID match
            final normalizedId = dso.id.toLowerCase().replaceAll(' ', '');
            if (wellKnownIds.contains(normalizedId)) {
              bestScore = 1; // Good match via well-known name
              matchSource = 'common name';
            }

            // Also check if any catalog IDs match well-known
            if (bestScore == null) {
              for (final catId in dso.catalogIds) {
                final normalizedCat = catId.toLowerCase().replaceAll(' ', '');
                if (wellKnownIds.contains(normalizedCat)) {
                  bestScore = 1;
                  matchSource = 'common name';
                  break;
                }
              }
            }

            // Check common names from catalog data
            final commonNames = dso.commonNames;
            if (commonNames != null && commonNames.isNotEmpty) {
              for (final cn in commonNames.split(',')) {
                final trimmed = cn.trim();
                if (trimmed.isEmpty) continue;
                final cnScore = _scoreMatch(q, trimmed);
                if (cnScore != null &&
                    (bestScore == null || cnScore < bestScore)) {
                  bestScore = cnScore;
                  matchSource = 'common name';
                }
              }
            }

            final (displayName, _) = _getDsoDisplayInfoForSearch(dso);
            final displayScore = _scoreMatch(q, displayName);
            if (displayScore != null &&
                (bestScore == null || displayScore < bestScore)) {
              bestScore = displayScore;
              matchSource = 'name';
            }

            final idScore = _scoreMatch(q, dso.id);
            if (idScore != null && (bestScore == null || idScore < bestScore)) {
              bestScore = idScore;
              matchSource = 'id';
            }

            for (final catId in dso.catalogIds) {
              final catScore = _scoreMatch(q, catId);
              if (catScore != null &&
                  (bestScore == null || catScore < bestScore)) {
                bestScore = catScore;
                matchSource = 'catalog';
              }
            }

            final constellation = dso.constellation;
            if (constellation != null) {
              final conScore = _scoreMatch(q, constellation);
              if (conScore != null &&
                  conScore <= 1 &&
                  (bestScore == null || conScore + 5 < bestScore)) {
                bestScore =
                    conScore + 5; // Lower priority for constellation matches
                matchSource = 'constellation';
              }
            }

            // An exact catalogue designation beats every fuzzier band above,
            // so it is applied last and unconditionally.
            if (_isExactDesignation(q, dso.id) ||
                dso.catalogIds.any((id) => _isExactDesignation(q, id))) {
              bestScore = _exactDesignationScore;
              matchSource = 'designation';
            }

            if (bestScore != null) {
              scored.add(
                ScoredSearchResult(
                  object: dso,
                  score: bestScore,
                  matchSource: matchSource,
                ),
              );
            }
          }
        } catch (e) {
          developer.log(
            '[Planetarium] DSO search error: $e',
            name: 'PlanetariumProviders',
            level: 900,
            error: e,
          );
        }
      }

      // Search solar-system bodies (major planets, comets, asteroids).
      //
      // These are not deep-sky catalog members, so they only participate when
      // the type filter is not narrowed to a specific DSO/star class.
      if (filters.typeFilter == SearchObjectTypeFilter.all) {
        try {
          final bodies = _ref.read(solarSystemSearchObjectsProvider);
          for (final body in bodies) {
            if (!_passesFilters(body, filters)) continue;
            final nameScore = _scoreMatch(q, body.name);
            if (nameScore != null) {
              scored.add(
                ScoredSearchResult(
                  object: body,
                  score: nameScore,
                  matchSource: 'name',
                ),
              );
            }
          }
        } catch (e) {
          developer.log(
            '[Planetarium] Solar-system search error: $e',
            name: 'PlanetariumProviders',
            level: 900,
            error: e,
          );
        }
      }

      // Sort by score (lower = better), then by magnitude (brighter first)
      scored.sort((a, b) {
        final scoreCmp = a.score.compareTo(b.score);
        if (scoreCmp != 0) return scoreCmp;
        return (a.object.magnitude ?? 99).compareTo(b.object.magnitude ?? 99);
      });

      // No hardcoded limit - return all scored results (UI can paginate)
      if (!_canPublish(generation)) return;
      state = ObjectSearchState(
        query: query,
        results: scored.map((s) => s.object).toList(),
        isSearching: false,
        filters: filters,
      );
    } catch (e) {
      if (!_canPublish(generation)) return;
      state = ObjectSearchState(
        query: query,
        results: [],
        isSearching: false,
        filters: filters,
      );
    }
  }

  /// Resolve [query] to the single best-matching object across all catalogs
  /// (Messier/NGC/IC/HIP/HD/common names/planets/comets/asteroids).
  ///
  /// Runs the full ranked search and returns the top result, or null if nothing
  /// matched. Used by the omnibox for Enter/submit "fly-to the best match"
  /// without the caller having to inspect search state. Leaves
  /// [state] populated so any open autocomplete reflects the same query.
  Future<CelestialObject?> resolveBest(String query) async {
    final generation = _searchGeneration + 1;
    await search(query);
    if (!_canPublish(generation)) return null;
    final results = state.results;
    return results.isEmpty ? null : results.first;
  }

  bool _passesFilters(CelestialObject obj, SearchFilters filters) {
    if (filters.minMagnitude != null && obj.magnitude != null) {
      if (obj.magnitude! < filters.minMagnitude!) return false;
    }
    if (filters.maxMagnitude != null && obj.magnitude != null) {
      if (obj.magnitude! > filters.maxMagnitude!) return false;
    }

    if (filters.constellationFilter != null) {
      String? objConstellation;
      if (obj is Star) {
        objConstellation = obj.constellation;
      } else if (obj is DeepSkyObject) {
        objConstellation = obj.constellation;
      }
      if (objConstellation == null) return false;
      if (!objConstellation.toLowerCase().contains(
        filters.constellationFilter!.toLowerCase(),
      )) {
        return false;
      }
    }

    if (filters.observableNow) {
      final site = _ref.read(observerLocationProvider).site;
      // Whether an object is up is a question about a place. With no site on
      // record nothing can pass the filter — listing objects as observable
      // would state an altitude nobody has computed.
      if (site == null) return false;
      final obsTime = _ref.read(observationTimeProvider);
      final (alt, _) = AstronomyCalculations.objectAltAz(
        raDeg: obj.coordinates.ra * 15,
        decDeg: obj.coordinates.dec,
        dt: obsTime.time,
        latitudeDeg: site.latitude,
        longitudeDeg: site.longitude,
      );
      if (alt < 10) return false; // Must be at least 10° above horizon
    }

    return true;
  }

  bool _passesDsoTypeFilter(DeepSkyObject dso, SearchObjectTypeFilter filter) {
    switch (filter) {
      case SearchObjectTypeFilter.all:
        return true;
      case SearchObjectTypeFilter.stars:
        return false; // Stars are handled separately
      case SearchObjectTypeFilter.galaxies:
        return dso.type.isGalaxy;
      case SearchObjectTypeFilter.nebulae:
        return dso.type.isNebula;
      case SearchObjectTypeFilter.clusters:
        return dso.type.isCluster;
    }
  }

  void clear() {
    _searchGeneration++;
    state = ObjectSearchState(filters: state.filters);
  }

  bool _canPublish(int generation) =>
      mounted && generation == _searchGeneration;
}

final objectSearchProvider =
    StateNotifierProvider<ObjectSearchNotifier, ObjectSearchState>((ref) {
      return ObjectSearchNotifier(ref);
    });
