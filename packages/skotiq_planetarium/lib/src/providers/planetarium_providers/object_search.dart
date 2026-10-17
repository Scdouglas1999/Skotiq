part of '../planetarium_providers.dart';

// Search provider

/// Object type filter for search
enum SearchObjectTypeFilter { all, stars, galaxies, nebulae, clusters }

/// Search filter configuration
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

/// Object search state
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

/// Compute Levenshtein distance between two strings.
/// Used for fuzzy matching in search.
int _levenshteinDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  // Use two-row optimization to save memory
  var prevRow = List<int>.generate(b.length + 1, (i) => i);
  var currRow = List<int>.filled(b.length + 1, 0);

  for (var i = 1; i <= a.length; i++) {
    currRow[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      currRow[j] = [
        currRow[j - 1] + 1, // insertion
        prevRow[j] + 1, // deletion
        prevRow[j - 1] + cost, // substitution
      ].reduce(math.min);
    }
    final temp = prevRow;
    prevRow = currRow;
    currRow = temp;
  }
  return prevRow[b.length];
}

/// Score a query match against a target string.
/// Returns null if no match, or a score (lower = better).
/// 0 = exact match, 1 = starts with, 2 = contains, 3+ = fuzzy match
int? _scoreMatch(String query, String target) {
  final q = query.toLowerCase();
  final t = target.toLowerCase();
  final qNorm = q.replaceAll(RegExp(r'\s+'), '');
  final tNorm = t.replaceAll(RegExp(r'\s+'), '');

  // Exact match
  if (t == q || tNorm == qNorm) return 0;

  // Starts with
  if (t.startsWith(q) || tNorm.startsWith(qNorm)) return 1;

  // Contains
  if (t.contains(q) || tNorm.contains(qNorm)) return 2;

  // Fuzzy match: only if query is >= 3 chars to avoid too many false positives
  if (q.length >= 3) {
    // For short targets, compare directly
    if (tNorm.length <= qNorm.length + 3) {
      final dist = _levenshteinDistance(qNorm, tNorm);
      // Allow edit distance up to ~30% of query length, minimum 1
      final maxDist = math.max(1, (qNorm.length * 0.35).floor());
      if (dist <= maxDist) return 3 + dist;
    }

    // For longer targets, check each word
    final words = t.split(RegExp(r'\s+'));
    for (final word in words) {
      if (word.length >= q.length - 2) {
        final dist = _levenshteinDistance(q, word);
        final maxDist = math.max(1, (q.length * 0.35).floor());
        if (dist <= maxDist) return 3 + dist;
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
/// `NGC 6720` -> `('ngc', 6720)`, `IC0059` -> `('ic', 59)`, `6720` -> `('', 6720)`.
///
/// Returns null for anything that is not a single prefix + number, which keeps
/// survey identifiers like `2MASX J21422663+1234093` or `ESO 287-052` out of
/// designation matching entirely.
({String prefix, int number})? _splitDesignation(String value) {
  final normalized = value.toLowerCase().replaceAll(RegExp(r'[\s_]+'), '');
  final match = RegExp(r'^([a-z]*)0*(\d+)$').firstMatch(normalized);
  if (match == null) return null;
  final number = int.tryParse(match.group(2)!);
  if (number == null) return null;
  return (prefix: match.group(1)!, number: number);
}

/// Whether [designation] is the object the designation-shaped [query] names.
///
/// A prefixed query pins the catalogue (`ugc 6720` must not answer NGC6720);
/// a bare number is only honoured for [_bareNumberCatalogs].
bool _isExactDesignation(
  ({String prefix, int number}) query,
  String designation,
) {
  final parsed = _splitDesignation(designation);
  if (parsed == null || parsed.number != query.number) return false;
  if (query.prefix.isEmpty) return _bareNumberCatalogs.contains(parsed.prefix);
  return parsed.prefix == query.prefix;
}

/// Map of well-known DSO common names to their catalog IDs
/// Used as a supplemental lookup for objects whose common names
/// may not be in the catalog data
const Map<String, List<String>> _wellKnownDsoNames = {
  'andromeda galaxy': ['M31', 'NGC224'],
  'orion nebula': ['M42', 'NGC1976'],
  'great orion nebula': ['M42', 'NGC1976'],
  'ring nebula': ['M57', 'NGC6720'],
  'crab nebula': ['M1', 'NGC1952'],
  'whirlpool galaxy': ['M51', 'NGC5194'],
  'sombrero galaxy': ['M104', 'NGC4594'],
  'pinwheel galaxy': ['M101', 'NGC5457'],
  'triangulum galaxy': ['M33', 'NGC598'],
  'lagoon nebula': ['M8', 'NGC6523'],
  'eagle nebula': ['M16', 'NGC6611'],
  'pillars of creation': ['M16', 'NGC6611'],
  'omega nebula': ['M17', 'NGC6618'],
  'swan nebula': ['M17', 'NGC6618'],
  'trifid nebula': ['M20', 'NGC6514'],
  'dumbbell nebula': ['M27', 'NGC6853'],
  'hercules cluster': ['M13', 'NGC6205'],
  'great hercules cluster': ['M13', 'NGC6205'],
  'wild duck cluster': ['M11', 'NGC6705'],
  'pleiades': ['M45'],
  'seven sisters': ['M45'],
  'beehive cluster': ['M44', 'NGC2632'],
  'praesepe': ['M44', 'NGC2632'],
  'horsehead nebula': ['IC434'],
  'flame nebula': ['NGC2024'],
  'rosette nebula': ['NGC2237'],
  'north america nebula': ['NGC7000'],
  'pelican nebula': ['IC5070'],
  'veil nebula': ['NGC6960', 'NGC6992'],
  'owl nebula': ['M97', 'NGC3587'],
  'cat eye nebula': ['NGC6543'],
  'helix nebula': ['NGC7293'],
  'double cluster': ['NGC869', 'NGC884'],
  'bode galaxy': ['M81', 'NGC3031'],
  'cigar galaxy': ['M82', 'NGC3034'],
  'sunflower galaxy': ['M63', 'NGC5055'],
  'black eye galaxy': ['M64', 'NGC4826'],
  'sculptor galaxy': ['NGC253'],
  'centaurus a': ['NGC5128'],
  'southern pinwheel': ['M83', 'NGC5236'],
  'antennae galaxies': ['NGC4038', 'NGC4039'],
  'leo triplet': ['M65', 'M66', 'NGC3628'],
  'hamburger galaxy': ['NGC3628'],
  'needle galaxy': ['NGC4565'],
  'cocoon nebula': ['IC5146'],
  'bubble nebula': ['NGC7635'],
  'elephant trunk nebula': ['IC1396'],
  'barnard loop': ['Sh2-276'],
  'soul nebula': ['IC1848'],
  'heart nebula': ['IC1805'],
  'running man nebula': ['NGC1977'],
  'california nebula': ['NGC1499'],
  'pacman nebula': ['NGC281'],
  'flaming star nebula': ['IC405'],
  'cone nebula': ['NGC2264'],
  'christmas tree cluster': ['NGC2264'],
  'blinking planetary': ['NGC6826'],
  'blue snowball': ['NGC7662'],
  'saturn nebula': ['NGC7009'],
  'eskimo nebula': ['NGC2392'],
  'little dumbbell': ['M76', 'NGC650'],
  'phantom galaxy': ['M74', 'NGC628'],
  'butterfly cluster': ['M6', 'NGC6405'],
  'ptolemy cluster': ['M7', 'NGC6475'],
  'starfish cluster': ['M38', 'NGC1912'],
};

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

class ObjectSearchNotifier extends StateNotifier<ObjectSearchState> {
  final Ref _ref;
  int _searchGeneration = 0;

  ObjectSearchNotifier(this._ref) : super(const ObjectSearchState());

  void updateFilters(SearchFilters filters) {
    state = state.copyWith(filters: filters);
    // Re-run search with new filters if there's an active query
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

    final qLower = query.toLowerCase().trim();
    final filters = state.filters;

    // Catalogue numbers are zero-padded in cross-identifiers, so a plain
    // substring match on a typed designation drags in every object whose
    // PGC/UGC digits happen to contain it. A designation-shaped query resolves
    // its own catalogue entry first, deterministically.
    final designationQuery = _splitDesignation(qLower);

    try {
      final scored = <ScoredSearchResult>[];

      // Check well-known name mappings first for DSO names
      final wellKnownIds = <String>{};
      for (final entry in _wellKnownDsoNames.entries) {
        final score = _scoreMatch(qLower, entry.key);
        if (score != null) {
          wellKnownIds.addAll(
            entry.value.map((v) => v.toLowerCase().replaceAll(' ', '')),
          );
        }
      }

      // Check well-known star name aliases
      String? starNameAlias;
      for (final entry in _wellKnownStarNames.entries) {
        final score = _scoreMatch(qLower, entry.key);
        if (score != null) {
          starNameAlias = entry.value.toLowerCase();
          break;
        }
      }

      // Search stars
      if (filters.typeFilter == SearchObjectTypeFilter.all ||
          filters.typeFilter == SearchObjectTypeFilter.stars) {
        try {
          final loadedStars = await _ref.read(loadedStarsProvider.future);
          for (final star in loadedStars) {
            if (!_passesFilters(star, filters)) continue;

            // "HD 48915" names one star; nothing weaker may outrank it.
            if (designationQuery != null &&
                (_isExactDesignation(designationQuery, star.id) ||
                    star.catalogIds.any(
                      (id) => _isExactDesignation(designationQuery, id),
                    ))) {
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
            final nameScore = _scoreMatch(qLower, star.name);
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

            // Check star name alias
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
            final idScore = _scoreMatch(qLower, star.id);
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
              final catScore = _scoreMatch(qLower, catId);
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

      // Search DSOs
      if (filters.typeFilter == SearchObjectTypeFilter.all ||
          filters.typeFilter != SearchObjectTypeFilter.stars) {
        try {
          final loadedDsos = await _ref.read(loadedDsosProvider.future);

          for (final dso in loadedDsos) {
            // Apply type filter
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
                final cnScore = _scoreMatch(qLower, trimmed);
                if (cnScore != null &&
                    (bestScore == null || cnScore < bestScore)) {
                  bestScore = cnScore;
                  matchSource = 'common name';
                }
              }
            }

            // Check display name
            final (displayName, _) = _getDsoDisplayInfoForSearch(dso);
            final displayScore = _scoreMatch(qLower, displayName);
            if (displayScore != null &&
                (bestScore == null || displayScore < bestScore)) {
              bestScore = displayScore;
              matchSource = 'name';
            }

            // Check id
            final idScore = _scoreMatch(qLower, dso.id);
            if (idScore != null && (bestScore == null || idScore < bestScore)) {
              bestScore = idScore;
              matchSource = 'id';
            }

            // Check catalog IDs
            for (final catId in dso.catalogIds) {
              final catScore = _scoreMatch(qLower, catId);
              if (catScore != null &&
                  (bestScore == null || catScore < bestScore)) {
                bestScore = catScore;
                matchSource = 'catalog';
              }
            }

            // Check constellation
            final constellation = dso.constellation;
            if (constellation != null) {
              final conScore = _scoreMatch(qLower, constellation);
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
            if (designationQuery != null &&
                (_isExactDesignation(designationQuery, dso.id) ||
                    dso.catalogIds.any(
                      (id) => _isExactDesignation(designationQuery, id),
                    ))) {
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
            final nameScore = _scoreMatch(qLower, body.name);
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
    // Magnitude filter
    if (filters.minMagnitude != null && obj.magnitude != null) {
      if (obj.magnitude! < filters.minMagnitude!) return false;
    }
    if (filters.maxMagnitude != null && obj.magnitude != null) {
      if (obj.magnitude! > filters.maxMagnitude!) return false;
    }

    // Constellation filter
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

    // Observable now filter
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
