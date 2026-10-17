import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../database/database.dart' as db;
import '../models/planning/target_suggestion.dart';
import '../services/logging_service.dart';
import '../services/target_suggestion_service.dart';
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

String? _catalogTargetsCachePath;
List<db.Target>? _catalogTargetsCache;
Future<List<db.Target>>? _catalogTargetsLoadFuture;

/// Provider that generates target suggestions for tonight's imaging session.
///
/// ADVISORY night-outlook supplement: this is NOT the authoritative "what runs
/// tonight" order. The headline pick comes from
/// `schedulerPreviewDecisionProvider` (a read-only preview of the live
/// autopilot); these suggestions add whole-night context — peak altitude,
/// transit time, imaging-window hours, framing-fit — beneath it.
final tonightSuggestionsProvider =
    FutureProvider.autoDispose<List<TargetSuggestion>>((ref) async {
      // Watch configuration for filter/sort changes
      final config = ref.watch(targetSuggestionConfigProvider);

      // Watch refresh trigger for manual refresh
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

        // Keep alive to prevent constant refetching while the user is viewing
        ref.keepAlive();

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

/// Load targets from the OpenNGC catalog.
///
/// Converts OpenNgcData objects to db.Target format for scoring.
/// Uses negative IDs to distinguish catalog objects from user targets.
Future<List<db.Target>> _loadCatalogTargets(LoggingService logging) async {
  final manager = CatalogManager.instance;

  if (!manager.isInitialized) {
    logging.warning(
      'CatalogManager not initialized - no catalog suggestions available',
      source: 'TargetSuggestionProvider',
    );
    return [];
  }

  final dsoStatus = await manager.getDsoCatalogStatus();
  if (!dsoStatus.isInstalled || dsoStatus.installedPath == null) {
    logging.info(
      'OpenNGC catalog not installed - suggestions limited to user targets',
      source: 'TargetSuggestionProvider',
    );
    return [];
  }

  final installedPath = dsoStatus.installedPath!;
  if (_catalogTargetsCachePath == installedPath &&
      _catalogTargetsCache != null) {
    return _catalogTargetsCache!;
  }

  if (_catalogTargetsCachePath == installedPath &&
      _catalogTargetsLoadFuture != null) {
    return _catalogTargetsLoadFuture!;
  }

  _catalogTargetsCachePath = installedPath;
  _catalogTargetsLoadFuture = _readCatalogTargets(installedPath, logging);

  try {
    final targets = await _catalogTargetsLoadFuture!;
    _catalogTargetsCache = List.unmodifiable(targets);
    return _catalogTargetsCache!;
  } catch (e, stackTrace) {
    logging.error(
      'Failed to load OpenNGC catalog: $e',
      source: 'TargetSuggestionProvider',
    );
    logging.debug(
      'Stack trace: $stackTrace',
      source: 'TargetSuggestionProvider',
    );
    _catalogTargetsCachePath = null;
    _catalogTargetsCache = null;
    rethrow;
  } finally {
    _catalogTargetsLoadFuture = null;
  }
}

Future<List<db.Target>> _readCatalogTargets(
  String installedPath,
  LoggingService logging,
) async {
  final loader = OpenNgcCatalogLoader(installedPath);

  // Load all DSOs with reasonable magnitude limit for imaging
  // (mag < 14 covers most imageable objects)
  final dsos = await loader.loadByMagnitude(14.0);

  logging.debug(
    'Loaded ${dsos.length} DSOs from OpenNGC catalog (mag < 14)',
    source: 'TargetSuggestionProvider',
  );

  // Convert to Target format
  // Use negative IDs to distinguish from user-created targets
  var fakeId = -1;
  final targets = <db.Target>[];
  final now = DateTime.now();

  for (final dso in dsos) {
    // Skip non-existent and duplicate entries
    if (dso.type == 'NonEx' || dso.type == 'Dup') continue;

    // Skip objects with invalid coordinates
    if (dso.ra == 0 && dso.dec == 0) continue;

    targets.add(
      db.Target(
        id: fakeId--,
        name: dso.displayName,
        catalogId: dso.name,
        objectType: dso.typeDescription,
        // OpenNGC ra is in degrees, Target expects decimal hours
        ra: dso.ra / 15.0,
        dec: dso.dec,
        magnitude: dso.magnitude,
        constellation: dso.constellation,
        sizeArcmin: dso.majorAxis,
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

  return targets;
}

// Convenience providers

/// Provider that returns the best single suggestion for tonight.
final bestSuggestionProvider =
    Provider.autoDispose<AsyncValue<TargetSuggestion?>>((ref) {
      final suggestionsAsync = ref.watch(tonightSuggestionsProvider);

      return suggestionsAsync.when(
        data: (suggestions) {
          if (suggestions.isEmpty) {
            return const AsyncData(null);
          }
          return AsyncData(suggestions.first);
        },
        loading: () => const AsyncLoading(),
        error: (error, stackTrace) => AsyncError(error, stackTrace),
      );
    });
