import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

import 'linked_host.dart';
import '../database/database.dart' as db;
import '../models/planning/target_suggestion.dart';
import '../utils/logging_service.dart';
import '../services/smart_night_service.dart';
import '../services/target_suggestion_service.dart';
import 'clock_provider.dart';
import 'database_provider.dart';
import 'hardware_presets_provider.dart';
import 'profiles_provider.dart';
import 'scheduler_provider.dart' show altitudeFloorProvider;
import 'settings_provider.dart';
import 'logging_service_provider.dart';

final targetSuggestionServiceProvider = Provider<TargetSuggestionService>((
  ref,
) {
  final logging = ref.watch(loggingServiceProvider);
  return TargetSuggestionService(loggingService: logging);
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
      if (targetLight(object.type.displayName) == TargetLight.emission) object,
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

/// Simple counter provider to trigger suggestion refresh.
///
/// UI can call `ref.read(refreshSuggestionsProvider.notifier).state++` to
/// force a rebuild of the suggestions list.
final refreshSuggestionsProvider = StateProvider<int>((ref) => 0);

/// A suggestion candidate from the catalog, with every designation that names
/// it ("NGC1952", "M1").
typedef CatalogTarget = ({db.DbTarget target, List<String> designations});

/// Catalog targets built from one OpenNGC reader. The catalog manager
/// replaces the reader when the file changes, which retires this entry.
final Expando<Future<List<CatalogTarget>>> _catalogTargets = Expando();

/// The user's own targets and the catalog's, one entry per object. A user
/// target is the catalog object its catalog id or its name designates (a run
/// saves "M1" by name, which is NGC1952): it keeps its own progress, takes the
/// catalog's description where it has none, and the catalog entry is dropped.
List<db.DbTarget> joinUserAndCatalogTargets(
  List<db.DbTarget> userTargets,
  List<CatalogTarget> catalog,
) {
  final byDesignation = <String, db.DbTarget>{};
  for (final entry in catalog) {
    for (final designation in entry.designations) {
      byDesignation.putIfAbsent(
        normalizeCatalogSearchText(designation),
        () => entry.target,
      );
    }
  }

  final claimed = <int>{};
  final joined = <db.DbTarget>[];
  for (final user in userTargets) {
    db.DbTarget? match;
    for (final name in [user.catalogId, user.name]) {
      if (name == null || name.trim().isEmpty) continue;
      match = byDesignation[normalizeCatalogSearchText(name)];
      if (match != null) break;
    }
    if (match == null) {
      joined.add(user);
      continue;
    }
    claimed.add(match.id);
    joined.add(
      user.copyWith(
        catalogId: Value(user.catalogId ?? match.catalogId),
        objectType: Value(user.objectType ?? match.objectType),
        magnitude: Value(user.magnitude ?? match.magnitude),
        constellation: Value(user.constellation ?? match.constellation),
        sizeArcmin: Value(user.sizeArcmin ?? match.sizeArcmin),
      ),
    );
  }
  return [
    ...joined,
    for (final entry in catalog)
      if (!claimed.contains(entry.target.id)) entry.target,
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

      ref.watch(refreshSuggestionsProvider);

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
      ref.watch(refreshSuggestionsProvider);

      // Watch optical config for FOV-aware framing fit scoring
      final opticalConfig = ref.watch(opticalConfigProvider);

      final observerLocation = ref.watch(appObserverLocationProvider);
      if (observerLocation == null) {
        // Settings not loaded yet, return empty list
        return [];
      }

      final latitude = observerLocation.latitude;
      final longitude = observerLocation.longitude;

      if (latitude == 0.0 && longitude == 0.0) {
        // No location configured, return empty list
        // The UI should prompt user to set location in settings
        return [];
      }

      final service = ref.read(targetSuggestionServiceProvider);
      final logging = ref.read(loggingServiceProvider);

      try {
        // Fetch host-backed targets and sessions when connected remotely.
        final List<db.DbTarget> userTargets = await ref.watch(
          allDbTargetsProvider.future,
        );
        final List<db.ImagingSession> sessions = await ref.watch(
          allSessionsProvider.future,
        );

        final catalogTargets = await _loadCatalogTargets(logging);
        final allTargets = joinUserAndCatalogTargets(
          userTargets,
          catalogTargets,
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
        // Log the error but don't crash - return empty list
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
Future<List<CatalogTarget>> _loadCatalogTargets(LoggingService logging) async {
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
  try {
    return await (_catalogTargets[reader] ??= _readCatalogTargets(
      reader,
      logging,
    ));
  } catch (e, stackTrace) {
    logging.error(
      'Failed to load OpenNGC catalog: $e',
      source: 'TargetSuggestionProvider',
    );
    logging.debug(
      'Stack trace: $stackTrace',
      source: 'TargetSuggestionProvider',
    );
    _catalogTargets[reader] = null;
    rethrow;
  }
}

Future<List<CatalogTarget>> _readCatalogTargets(
  OpenNgcDsoCatalog reader,
  LoggingService logging,
) async {
  final dsos = await reader.load();
  var fakeId = -1;
  final targets = <CatalogTarget>[];
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
    targets.add((target: target, designations: [dso.id, ...dso.catalogIds]));
  }

  logging.debug(
    'Loaded ${targets.length} DSOs from OpenNGC catalog (mag < 14)',
    source: 'TargetSuggestionProvider',
  );
  return List.unmodifiable(targets);
}
