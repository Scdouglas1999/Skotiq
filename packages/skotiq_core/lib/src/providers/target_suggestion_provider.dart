import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

import '../backend/network_backend.dart';
import '../database/database.dart' as db;
import '../models/errors/server_error.dart';
import '../models/planning/target_suggestion.dart';
import '../services/logging_service.dart';
import '../services/target_suggestion_service.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'profiles_provider.dart';
import 'settings_provider.dart';

// Service provider

/// Provider for the target suggestion service.
final targetSuggestionServiceProvider = Provider<TargetSuggestionService>((
  ref,
) {
  final logging = ref.watch(loggingServiceProvider);
  return TargetSuggestionService(loggingService: logging);
});

// Configuration provider

/// Provider for target suggestion configuration.
///
/// This allows the UI to modify filter and sort settings for suggestions.
/// Default values provide sensible defaults for most imaging scenarios.
final targetSuggestionConfigProvider = StateProvider<TargetSuggestionConfig>((
  ref,
) {
  return const TargetSuggestionConfig(
    minAltitude: 30.0,
    minScore: 50.0,
    prioritizeIncomplete: true,
    sortMode: SuggestionSortMode.bestScore,
    preferredObjectTypes: [],
  );
});

// Refresh trigger provider

/// Simple counter provider to trigger suggestion refresh.
///
/// UI can call `ref.read(refreshSuggestionsProvider.notifier).state++` to
/// force a rebuild of the suggestions list.
final refreshSuggestionsProvider = StateProvider<int>((ref) => 0);

// Tonight's Suggestions Provider

/// Catalog targets built from one OpenNGC reader. The catalog manager
/// replaces the reader when the file changes, which retires this entry.
final Expando<Future<List<db.Target>>> _catalogTargets = Expando();

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
      // Watch configuration for filter/sort changes
      final config = ref.watch(targetSuggestionConfigProvider);

      // Watch refresh trigger for manual refresh
      ref.watch(refreshSuggestionsProvider);

      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        try {
          final suggestions = await backend.fetchRankedTonightSuggestions(
            config,
          );
          ref.keepAlive();
          return suggestions;
        } on ServerError catch (error) {
          // An older host without the ranking endpoint: rank here, as
          // clients did before it existed.
          if (error.httpStatus != 404) rethrow;
          ref
              .read(loggingServiceProvider)
              .warning(
                'The imaging host cannot rank tonight\'s targets; ranking '
                'them on this computer instead',
                source: 'TargetSuggestionProvider',
              );
        }
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

      // Validate location is set
      if (latitude == 0.0 && longitude == 0.0) {
        // No location configured, return empty list
        // The UI should prompt user to set location in settings
        return [];
      }

      // Get the suggestion service
      final service = ref.read(targetSuggestionServiceProvider);
      final logging = ref.read(loggingServiceProvider);

      try {
        // Fetch host-backed targets and sessions when connected remotely.
        final List<db.Target> userTargets = await ref.watch(
          allDbTargetsProvider.future,
        );
        final List<db.ImagingSession> sessions = await ref.watch(
          allSessionsProvider.future,
        );

        // Fetch catalog objects from OpenNGC
        final catalogTargets = await _loadCatalogTargets(logging);

        // Combine user targets with catalog targets
        // User targets take precedence (they have imaging progress data)
        final seenCatalogIds = <String>{};
        for (final t in userTargets) {
          if (t.catalogId != null) {
            seenCatalogIds.add(t.catalogId!.toUpperCase());
          }
        }

        // Filter out catalog objects that already exist as user targets
        final filteredCatalog = catalogTargets.where((t) {
          if (t.catalogId == null) return true;
          return !seenCatalogIds.contains(t.catalogId!.toUpperCase());
        }).toList();

        // Combine: user targets first (have progress data), then catalog targets
        final allTargets = [...userTargets, ...filteredCatalog];

        logging.info(
          'Loaded ${userTargets.length} user targets + ${filteredCatalog.length} catalog targets = ${allTargets.length} total',
          source: 'TargetSuggestionProvider',
        );

        // Get custom horizon profile for obstruction filtering
        final horizonProfile = ref.read(horizonProfileProvider);

        // Generate suggestions
        final suggestions = await service.getSuggestionsForTonight(
          config: config,
          latitude: latitude,
          longitude: longitude,
          targets: allTargets,
          sessions: sessions,
          opticalConfig: opticalConfig,
          horizonProfile: horizonProfile.isFlat ? null : horizonProfile,
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
/// magnitude 14 (which covers most imageable objects), as [db.Target] rows
/// with negative ids so they cannot be mistaken for the user's own targets.
Future<List<db.Target>> _loadCatalogTargets(LoggingService logging) async {
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

Future<List<db.Target>> _readCatalogTargets(
  OpenNgcDsoCatalog reader,
  LoggingService logging,
) async {
  final dsos = await reader.load();
  var fakeId = -1;
  final targets = <db.Target>[];
  final now = DateTime.now();

  for (final dso in dsos) {
    // Brightest first: nothing after this is brighter than 14, and objects
    // with no magnitude sort last.
    if ((dso.magnitude ?? 99) > 14.0) break;

    targets.add(
      db.Target(
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
      ),
    );
  }

  logging.debug(
    'Loaded ${targets.length} DSOs from OpenNGC catalog (mag < 14)',
    source: 'TargetSuggestionProvider',
  );
  return List.unmodifiable(targets);
}

// Convenience providers
