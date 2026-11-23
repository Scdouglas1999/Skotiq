import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

import 'linked_host.dart';
import '../database/database.dart' as db;
import '../models/planning/target_suggestion.dart';
import '../services/catalog_target_types.dart';
import '../utils/logging_service.dart';
import '../services/smart_night_service.dart';
import '../services/target_suggestion_service.dart';
import '../services/tonight_dark_window.dart';
import 'clock_provider.dart';
import 'database_provider.dart';
import 'hardware_presets_provider.dart';
import 'profiles_provider.dart';
import 'scheduler_provider.dart' show altitudeFloorProvider;
import 'settings_provider.dart';
import 'logging_service_provider.dart';
import 'target_scorer_provider.dart';

final targetSuggestionServiceProvider = Provider<TargetSuggestionService>((
  ref,
) {
  return TargetSuggestionService(
    loggingService: ref.watch(loggingServiceProvider),
    scorer: ref.watch(targetScorerProvider),
  );
});

/// Smart Night, planning against the site's altitude floor.
final smartNightServiceProvider = Provider<SmartNightService>((ref) {
  return SmartNightService(
    suggestionService: ref.watch(targetSuggestionServiceProvider),
    logging: ref.watch(loggingServiceProvider),
    floor: ref.watch(altitudeFloorProvider),
    cameraLibrary: ref.watch(hardwarePresetsServiceProvider),
    emissionObjects:
        ref.watch(catalogEmissionObjectsProvider).valueOrNull ?? const [],
  );
});

/// The installed deep-sky catalog's emission objects ([TargetLight.emission]
/// by their catalog type), every magnitude: a galaxy's HII regions are
/// fainter than the targets themselves. Empty with no catalog installed.
final catalogEmissionObjectsProvider = FutureProvider<List<DeepSkyObject>>((
  ref,
) async {
  final manager = CatalogManager.instance;
  if (!manager.isInitialized ||
      !(await manager.status(SkyCatalog.dso)).isInstalled) {
    return const [];
  }
  final objects = await manager.dsos.load();
  return [
    for (final object in objects)
      if (object.type.light == TargetLight.emission) object,
  ];
});

/// Provider for target suggestion configuration.
///
/// This allows the UI to modify filter and sort settings for suggestions.
/// Default values provide sensible defaults for most imaging scenarios.
final targetSuggestionConfigProvider = StateProvider<TargetSuggestionConfig>((
  ref,
) {
  return const TargetSuggestionConfig(
    minScore: 50.0,
    prioritizeIncomplete: true,
    sortMode: SuggestionSortMode.bestScore,
    preferredObjectTypes: [],
  );
});

/// Catalog targets built from one OpenNGC reader. The catalog manager
/// replaces the reader when the file changes, which retires the entry.
class _CatalogTargetsCache {
  OpenNgcDsoCatalog? reader;
  Future<List<db.DbTarget>>? targets;
}

final _catalogTargetsCacheProvider = Provider<_CatalogTargetsCache>(
  (ref) => _CatalogTargetsCache(),
);

/// Fires when a catalog file is installed or removed. Suggestions watch this
/// so a list scored before the file arrived is dropped.
final catalogChangeProvider = StreamProvider<SkyCatalog>((ref) {
  return CatalogManager.instance.changes;
});

/// The user's own targets and the catalog's, one entry per object. A user
/// target is the catalog object it designates ([DsoDesignations.ofTarget]: a
/// run saves "M1" by name, which is NGC1952): it keeps its own progress,
/// takes the catalog's type, and its description where it has none, and the
/// catalog entry is dropped.
List<db.DbTarget> joinUserAndCatalogTargets(
  List<db.DbTarget> userTargets,
  List<db.DbTarget> catalog,
  DsoDesignations designations,
) {
  final byObjectId = {for (final entry in catalog) entry.catalogId: entry};

  final claimed = <int>{};
  final joined = <db.DbTarget>[];
  for (final user in userTargets) {
    final object = designations.ofTarget(
      catalogId: user.catalogId,
      name: user.name,
    );
    final match = object == null ? null : byObjectId[object.id];
    if (match == null) {
      joined.add(user);
      continue;
    }
    claimed.add(match.id);
    joined.add(
      user.copyWith(
        catalogId: Value(user.catalogId ?? match.catalogId),
        objectType: Value(match.objectType ?? user.objectType),
        magnitude: Value(user.magnitude ?? match.magnitude),
        constellation: Value(user.constellation ?? match.constellation),
        sizeArcmin: Value(user.sizeArcmin ?? match.sizeArcmin),
      ),
    );
  }
  return [
    ...joined,
    for (final entry in catalog)
      if (!claimed.contains(entry.id)) entry,
  ];
}

/// Provider that generates target suggestions for tonight's imaging session.
///
/// ADVISORY night-outlook supplement: this is NOT the authoritative "what runs
/// tonight" order. The headline pick comes from
/// `schedulerPreviewDecisionProvider` (a read-only preview of the live
/// autopilot); these suggestions add whole-night context — peak altitude,
/// transit time, imaging-window hours, framing-fit — beneath it.
///
/// A client linked to an imaging host shows the host's ranking: the host
/// scores its own catalog with its own optics, horizon and target progress,
/// so both machines list the same candidates.
final tonightSuggestionsProvider =
    FutureProvider.autoDispose<List<TargetSuggestion>>((ref) async {
      final config = ref.watch(targetSuggestionConfigProvider);

      final remote = ref.watch(linkedHostPlanningProvider);
      if (remote != null) {
        final suggestions = await remote.fetchRankedTonightSuggestions(config);
        ref.keepAlive();
        return suggestions;
      }

      final suggestions = await ref.watch(
        localTonightSuggestionsProvider(config).future,
      );
      // Keep alive to prevent constant refetching while the user is viewing
      ref.keepAlive();
      return suggestions;
    });

/// Whether the Sun stays up all night at the site tonight, so tonight's
/// suggestions are empty and the planner says why ([midnightSunNotice]).
/// False with no site set.
final tonightSunStaysUpProvider = Provider.autoDispose<bool>((ref) {
  final site = ref.watch(appObserverLocationProvider);
  if (site == null || !siteLocationIsSet(site.latitude, site.longitude)) {
    return false;
  }
  return sunStaysUpTonight(
    now: ref.read(clockProvider).instant,
    latitudeDeg: site.latitude,
    longitudeDeg: site.longitude,
  );
});

/// Tonight's ranking computed on this machine from its own catalog, optics,
/// horizon, targets and sessions.
///
/// The imaging host serves this to linked clients through
/// `GET /api/suggestions/ranked`.
final localTonightSuggestionsProvider = FutureProvider.autoDispose
    .family<List<TargetSuggestion>, TargetSuggestionConfig>((
      ref,
      config,
    ) async {
      // Install and uninstall, not a status refresh: a timer must not re-score.
      ref.watch(catalogChangeProvider);

      // Watch optical config for FOV-aware framing fit scoring
      final opticalConfig = ref.watch(opticalConfigProvider);

      final observerLocation = ref.watch(appObserverLocationProvider);
      if (observerLocation == null) {
        // Settings not loaded yet, return empty list
        return [];
      }

      final latitude = observerLocation.latitude;
      final longitude = observerLocation.longitude;

      if (!siteLocationIsSet(latitude, longitude)) {
        // No location configured, return empty list
        // The UI should prompt user to set location in settings
        return [];
      }

      final service = ref.read(targetSuggestionServiceProvider);
      final logging = ref.read(loggingServiceProvider);

      try {
        final List<db.DbTarget> userTargets = await ref.watch(
          allDbTargetsProvider.future,
        );
        final List<db.ImagingSession> sessions = await ref.watch(
          allSessionsProvider.future,
        );

        final catalogTargets = await _loadCatalogTargets(
          ref.read(_catalogTargetsCacheProvider),
          logging,
        );
        final allTargets = joinUserAndCatalogTargets(
          userTargets,
          catalogTargets,
          await installedDsoDesignations(logging),
        );

        logging.info(
          'Loaded ${userTargets.length} user targets + '
          '${allTargets.length - userTargets.length} catalog targets = '
          '${allTargets.length} total',
          source: 'TargetSuggestionProvider',
        );

        final suggestions = await service.getSuggestionsForTonight(
          config: config,
          latitude: latitude,
          longitude: longitude,
          targets: allTargets,
          sessions: sessions,
          observationTime: ref.read(clockProvider).instant,
          opticalConfig: opticalConfig,
          floor: ref.read(altitudeFloorProvider),
        );

        return suggestions;
      } catch (e, stackTrace) {
        logging.error(
          'Failed to generate target suggestions: $e',
          source: 'TargetSuggestionProvider',
        );
        logging.debug(
          'Stack trace: $stackTrace',
          source: 'TargetSuggestionProvider',
        );

        // Rethrow to let the UI show the error state
        rethrow;
      }
    });

/// Suggestion candidates from the OpenNGC catalog: every object to
/// magnitude 14 (which covers most imageable objects), as [db.DbTarget] rows
/// with negative ids so they cannot be mistaken for the user's own targets.
Future<List<db.DbTarget>> _loadCatalogTargets(
  _CatalogTargetsCache cache,
  LoggingService logging,
) async {
  final manager = CatalogManager.instance;

  if (!manager.isInitialized) {
    logging.warning(
      'CatalogManager not initialized - no catalog suggestions available',
      source: 'TargetSuggestionProvider',
    );
    return [];
  }

  if (!(await manager.status(SkyCatalog.dso)).isInstalled) {
    logging.info(
      'OpenNGC catalog not installed - suggestions limited to user targets',
      source: 'TargetSuggestionProvider',
    );
    return [];
  }

  final reader = manager.dsos;
  if (!identical(reader, cache.reader)) {
    cache
      ..reader = reader
      ..targets = null;
  }
  final targets = cache.targets ??= _readCatalogTargets(reader, logging);
  try {
    return await targets;
  } catch (e, stackTrace) {
    logging.error(
      'Failed to load OpenNGC catalog: $e',
      source: 'TargetSuggestionProvider',
    );
    logging.debug(
      'Stack trace: $stackTrace',
      source: 'TargetSuggestionProvider',
    );
    if (identical(cache.targets, targets)) cache.targets = null;
    rethrow;
  }
}

Future<List<db.DbTarget>> _readCatalogTargets(
  OpenNgcDsoCatalog reader,
  LoggingService logging,
) async {
  final dsos = await reader.load();
  var fakeId = -1;
  final targets = <db.DbTarget>[];
  final now = DateTime.now();

  for (final dso in dsos) {
    // Brightest first: nothing after this is brighter than 14, and objects
    // with no magnitude sort last.
    if ((dso.magnitude ?? 99) > 14.0) break;

    final target = db.DbTarget(
      id: fakeId--,
      name: dso.name,
      catalogId: dso.id,
      objectType: dso.type.displayName,
      ra: dso.coordinates.ra,
      dec: dso.coordinates.dec,
      magnitude: dso.magnitude,
      constellation: dso.constellation,
      sizeArcmin: dso.sizeArcMin,
      positionAngle: dso.positionAngle,
      minAltitude: 30.0,
      priority: 5,
      totalPlannedSubs: 0,
      capturedSubs: 0,
      totalIntegrationSecs: 0.0,
      goalIntegrationSecs: 0.0,
      filterProgress: null,
      notes: dso.commonNames,
      createdAt: now,
      updatedAt: now,
      isFavorite: false,
    );
    targets.add(target);
  }

  logging.debug(
    'Loaded ${targets.length} DSOs from OpenNGC catalog (mag < 14)',
    source: 'TargetSuggestionProvider',
  );
  return List.unmodifiable(targets);
}
