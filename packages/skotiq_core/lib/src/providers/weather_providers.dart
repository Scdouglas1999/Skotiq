import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../models/weather/weather_models.dart';
import '../services/weather/transient_http_retry.dart';
import '../services/weather/providers/metno_cloud_provider.dart';
import '../services/weather/weather_radar_service.dart';
import '../services/weather/cloud_motion_analyzer.dart';
import '../services/weather/weather_alert_service.dart';
import '../database/database.dart' as db;
import '../backend/network_backend.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'settings_provider.dart';

// Export weather safety provider
export 'weather_safety_provider.dart';

// Service providers

/// Provider for the weather radar service
///
/// Manages radar data fetching from multiple providers (NOAA, RainViewer, OpenMeteo).
/// Initializes on first access and disposes when the provider is destroyed.
final weatherRadarServiceProvider = Provider<WeatherRadarService>((ref) {
  final service = WeatherRadarService(ref);
  service.initialize();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Provider for the cloud motion analyzer
///
/// Stateless service that analyzes radar frame sequences to predict cloud movement
/// and calculate estimated time of arrival at user location.
final cloudMotionAnalyzerProvider = Provider<CloudMotionAnalyzer>((ref) {
  return CloudMotionAnalyzer();
});

/// Provider for the weather alert service
///
/// Evaluates weather conditions and generates alerts based on cloud proximity,
/// density, and motion. Disposes stream resources when provider is destroyed.
final weatherAlertServiceProvider = Provider<WeatherAlertService>((ref) {
  final service = WeatherAlertService();
  ref.onDispose(() => service.dispose());
  return service;
});

// Settings providers

/// Synchronous provider for weather settings
///
/// Returns the current weather settings model, converting from the database
/// row type. Returns default settings if database settings are not yet loaded.
final weatherSettingsDataProvider = StreamProvider<WeatherSettings>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return Stream.fromFuture(
      backend.getWeatherSettings().then(_weatherSettingsFromWire),
    );
  }
  final database = ref.watch(databaseProvider);
  return database.weatherSettingsDao.watchSettings().map(
    (row) => row == null
        ? WeatherSettings.defaultSettings
        : _weatherSettingsFromRow(row),
  );
});

final weatherSettingsProvider = Provider<WeatherSettings>((ref) {
  return ref.watch(weatherSettingsDataProvider).valueOrNull ??
      WeatherSettings.defaultSettings;
});

WeatherSettings _weatherSettingsFromRow(db.WeatherSettingRow row) {
  return WeatherSettings(
    triggerDistanceKm: row.triggerDistanceKm,
    cloudDensityThreshold: row.cloudDensityThreshold,
    leadTimeMinutes: row.leadTimeMinutes,
    weatherSafetyEnabled: row.weatherSafetyEnabled,
    maxHumidityPercent: row.maxHumidityPercent,
    maxWindSpeedKph: row.maxWindSpeedKph,
    maxCloudCoverPercent: row.maxCloudCoverPercent,
    autoParkEnabled: row.autoParkEnabled,
    autoResumeEnabled: row.autoResumeEnabled,
    preferredProvider: _parseProviderType(row.preferredProvider),
    refreshIntervalSeconds: row.refreshIntervalSeconds,
  );
}

WeatherSettings _weatherSettingsFromWire(Map<String, dynamic> json) {
  final defaults = WeatherSettings.defaultSettings;
  double finiteDouble(String key, double fallback) {
    final value = json[key];
    return value is num && value.isFinite ? value.toDouble() : fallback;
  }

  int integer(String key, int fallback) {
    final value = json[key];
    return value is int ? value : fallback;
  }

  bool boolean(String key, bool fallback) {
    final value = json[key];
    return value is bool ? value : fallback;
  }

  return WeatherSettings(
    triggerDistanceKm: finiteDouble(
      'triggerDistanceKm',
      defaults.triggerDistanceKm,
    ).clamp(1, 500).toDouble(),
    cloudDensityThreshold: finiteDouble(
      'cloudDensityThreshold',
      defaults.cloudDensityThreshold,
    ).clamp(0, 100).toDouble(),
    leadTimeMinutes: integer(
      'leadTimeMinutes',
      defaults.leadTimeMinutes,
    ).clamp(1, 180).toInt(),
    weatherSafetyEnabled: boolean(
      'weatherSafetyEnabled',
      defaults.weatherSafetyEnabled,
    ),
    maxHumidityPercent: finiteDouble(
      'maxHumidityPercent',
      defaults.maxHumidityPercent,
    ).clamp(0, 100).toDouble(),
    maxWindSpeedKph: finiteDouble(
      'maxWindSpeedKph',
      defaults.maxWindSpeedKph,
    ).clamp(0, 150).toDouble(),
    maxCloudCoverPercent: finiteDouble(
      'maxCloudCoverPercent',
      defaults.maxCloudCoverPercent,
    ).clamp(0, 100).toDouble(),
    autoParkEnabled: boolean('autoParkEnabled', defaults.autoParkEnabled),
    autoResumeEnabled: boolean('autoResumeEnabled', defaults.autoResumeEnabled),
    preferredProvider: _parseProviderType(
      json['preferredProvider'] is String
          ? json['preferredProvider'] as String
          : defaults.preferredProvider.name,
    ),
    refreshIntervalSeconds: integer(
      'refreshIntervalSeconds',
      defaults.refreshIntervalSeconds,
    ).clamp(30, 3600).toInt(),
  );
}

class WeatherSettingsActions {
  final Ref _ref;

  WeatherSettingsActions(this._ref);

  Future<void> updateSettings({
    double? triggerDistanceKm,
    double? cloudDensityThreshold,
    int? leadTimeMinutes,
    bool? weatherSafetyEnabled,
    double? maxHumidityPercent,
    double? maxWindSpeedKph,
    double? maxCloudCoverPercent,
    bool? autoParkEnabled,
    bool? autoResumeEnabled,
    RadarProviderType? preferredProvider,
    int? refreshIntervalSeconds,
  }) async {
    final payload = <String, dynamic>{
      if (triggerDistanceKm != null) 'triggerDistanceKm': triggerDistanceKm,
      if (cloudDensityThreshold != null)
        'cloudDensityThreshold': cloudDensityThreshold,
      if (leadTimeMinutes != null) 'leadTimeMinutes': leadTimeMinutes,
      if (weatherSafetyEnabled != null)
        'weatherSafetyEnabled': weatherSafetyEnabled,
      if (maxHumidityPercent != null) 'maxHumidityPercent': maxHumidityPercent,
      if (maxWindSpeedKph != null) 'maxWindSpeedKph': maxWindSpeedKph,
      if (maxCloudCoverPercent != null)
        'maxCloudCoverPercent': maxCloudCoverPercent,
      if (autoParkEnabled != null) 'autoParkEnabled': autoParkEnabled,
      if (autoResumeEnabled != null) 'autoResumeEnabled': autoResumeEnabled,
      if (preferredProvider != null)
        'preferredProvider': preferredProvider.name,
      if (refreshIntervalSeconds != null)
        'refreshIntervalSeconds': refreshIntervalSeconds,
    };
    if (payload.isEmpty) return;

    final backend = _ref.read(backendProvider);
    if (backend is NetworkBackend) {
      await backend.updateWeatherSettings(payload);
      _ref.invalidate(weatherSettingsDataProvider);
      return;
    }
    await _ref
        .read(databaseProvider)
        .weatherSettingsDao
        .updateSettings(
          triggerDistanceKm: triggerDistanceKm,
          cloudDensityThreshold: cloudDensityThreshold,
          leadTimeMinutes: leadTimeMinutes,
          weatherSafetyEnabled: weatherSafetyEnabled,
          maxHumidityPercent: maxHumidityPercent,
          maxWindSpeedKph: maxWindSpeedKph,
          maxCloudCoverPercent: maxCloudCoverPercent,
          autoParkEnabled: autoParkEnabled,
          autoResumeEnabled: autoResumeEnabled,
          preferredProvider: preferredProvider?.name,
          refreshIntervalSeconds: refreshIntervalSeconds,
        );
  }

  /// Write "park the mount when conditions go unsafe" as the ONE logical
  /// setting it is.
  ///
  /// The runtime gate is `parkOnUnsafeWeather && autoParkEnabled` (see
  /// [SafetyConfig.autoParkOnUnsafe] and the weather-safety evaluator), but the
  /// two halves live in different stores. Before this method the Weather Safety
  /// page wrote only the weather half and the Sequencer page only the
  /// app-settings half, so turning either off silently disarmed auto-park while
  /// the other page kept showing a confident "Enabled". Every UI writer goes
  /// through here — the headless `/api/safety/config` handler already wrote both
  /// for one logical request, so this makes the GUI match the API.
  Future<void> setAutoParkOnUnsafe(bool value) async {
    await updateSettings(autoParkEnabled: value);
    await _ref.read(appSettingsProvider.notifier).setParkOnUnsafeWeather(value);
  }
}

final weatherSettingsActionsProvider = Provider<WeatherSettingsActions>((ref) {
  return WeatherSettingsActions(ref);
});

/// Parse radar provider type from database string
RadarProviderType _parseProviderType(String providerString) {
  switch (providerString.toLowerCase()) {
    case 'auto':
      return RadarProviderType.auto;
    case 'goessatellite':
      return RadarProviderType.goesSatellite;
    case 'noaa':
      return RadarProviderType.noaa;
    case 'rainviewer':
      return RadarProviderType.rainviewer;
    case 'openmeteo':
      return RadarProviderType.openmeteo;
    case 'metno':
      return RadarProviderType.metno;
    default:
      return RadarProviderType.auto;
  }
}

// Cloud cover provider

/// Provider for current cloud cover percentage from Open-Meteo
///
/// Fetches real-time cloud cover data independent of the visual satellite overlay.
/// Returns a percentage 0-100 where 0 = clear skies, 100 = fully overcast.
final cloudCoverPercentageProvider = FutureProvider<double?>((ref) async {
  final observerLocation = ref.watch(appObserverLocationProvider);
  if (observerLocation == null) {
    return null;
  }

  final latitude = observerLocation.latitude;
  final longitude = observerLocation.longitude;

  // Skip if location not set
  if (latitude == 0.0 && longitude == 0.0) {
    return null;
  }

  try {
    // Use Open-Meteo API directly for cloud cover
    final uri = Uri.parse('https://api.open-meteo.com/v1/forecast').replace(
      queryParameters: {
        'latitude': latitude.toString(),
        'longitude': longitude.toString(),
        'current': 'cloud_cover',
      },
    );

    final client = http.Client();
    try {
      // Retry transient 5xx / dropped-TLS blips (Open-Meteo's single host
      // degrades that way under load) before giving up for this fetch.
      final response = await getWithTransientRetry(client, uri);

      if (response.statusCode != 200) {
        developer.log(
          'Cloud cover fetch failed: ${response.statusCode}, '
          'trying MET Norway fallback',
          name: 'Weather',
          level: 900,
        );
        // Open-Meteo returned a non-200 even after transient retries; fall back
        // to MET Norway's independent host before giving up. The client is kept
        // alive by the enclosing finally until this completes.
        final fallback = await MetNoCloudProvider.fetchCurrentCloudCover(
          client,
          latitude,
          longitude,
        );
        if (fallback != null) {
          developer.log(
            'Current cloud cover: $fallback% (source: MET Norway)',
            name: 'Weather',
          );
          return fallback;
        }
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final current = json['current'] as Map<String, dynamic>?;

      if (current == null) {
        return null;
      }

      final cloudCover = current['cloud_cover'];
      if (cloudCover is num) {
        developer.log(
          'Current cloud cover: ${cloudCover.toDouble()}%',
          name: 'Weather',
        );
        return cloudCover.toDouble();
      }

      return null;
    } finally {
      client.close();
    }
  } catch (e) {
    developer.log(
      'Error fetching cloud cover: $e, trying MET Norway fallback',
      name: 'Weather',
      level: 1000,
    );
    // Open-Meteo threw (network error, even after transient retries). The
    // original client was already closed by the inner finally, so use a fresh
    // one for the MET Norway fallback.
    final fallbackClient = http.Client();
    try {
      final fallback = await MetNoCloudProvider.fetchCurrentCloudCover(
        fallbackClient,
        latitude,
        longitude,
      );
      if (fallback != null) {
        developer.log(
          'Current cloud cover: $fallback% (source: MET Norway)',
          name: 'Weather',
        );
        return fallback;
      }
    } catch (fallbackError) {
      developer.log(
        'MET Norway fallback also failed: $fallbackError',
        name: 'Weather',
        level: 1000,
      );
    } finally {
      fallbackClient.close();
    }
    return null;
  }
});

// Data stream providers

/// Provider for radar frames that triggers fetching automatically.
///
/// Watches the user's location from app settings and fetches radar frames
/// from the appropriate provider. Re-fetches when invalidated.
final weatherRadarFramesProvider = FutureProvider<List<RadarFrame>>((
  ref,
) async {
  final observerLocation = ref.watch(appObserverLocationProvider);
  if (observerLocation == null) {
    developer.log('No app settings yet, returning empty', name: 'WeatherRadar');
    return [];
  }

  final latitude = observerLocation.latitude;
  final longitude = observerLocation.longitude;

  // Skip fetch if location not set
  if (latitude == 0.0 && longitude == 0.0) {
    developer.log('Location not set, returning empty', name: 'WeatherRadar');
    return [];
  }

  developer.log(
    'Fetching for location ($latitude, $longitude)',
    name: 'WeatherRadar',
  );

  final radarService = ref.read(weatherRadarServiceProvider);

  // Force fresh fetch (clear cache to get updated URL format)
  radarService.clearCache();

  final result = await radarService.fetchRadarFrames(
    latitude: latitude,
    longitude: longitude,
    forceRefresh: true,
  );

  if (result.isSuccess) {
    if (result.frames.isEmpty) {
      throw StateError(
        '${result.providerName ?? 'Weather provider'} returned no radar frames',
      );
    }
    developer.log('Got ${result.frames.length} frames', name: 'WeatherRadar');
    return result.frames;
  } else {
    developer.log(
      'Fetch failed - ${result.errorMessage}',
      name: 'WeatherRadar',
      level: 900,
    );
    // Surface the failure so `framesAsync.hasError` populates the weather
    // status error and the UI shows an offline state instead of an empty radar
    // presented as "Clear".
    throw Exception(result.errorMessage ?? 'Weather radar fetch failed');
  }
});

/// Attribution + freshness info for the currently displayed radar frames.
///
/// Carries the human-readable name of the provider that produced the frames
/// (e.g. "GOES Satellite", "NOAA NEXRAD") and the instant they were fetched,
/// so the UI can show the operator where the imagery came from and how fresh
/// it is. Null fields mean the data isn't available yet.
class RadarSourceInfo {
  /// Display name of the active radar/satellite provider, or null if unknown.
  final String? providerName;

  /// When the frames were fetched, or null if no successful fetch yet.
  final DateTime? fetchedAt;

  /// Number of frames in the active set (1 means a single static frame, which
  /// the UI uses to decide whether animation controls are meaningful).
  final int frameCount;

  const RadarSourceInfo({
    this.providerName,
    this.fetchedAt,
    this.frameCount = 0,
  });
}

/// Provider exposing the source/freshness of the current radar frames.
///
/// Watches [weatherRadarFramesProvider] so it stays in lockstep with the
/// frames currently rendered, then reads the producing provider's name and
/// fetch time from the radar service's cached result.
final radarSourceInfoProvider = Provider<RadarSourceInfo>((ref) {
  // Re-read whenever the frames change so attribution tracks the live data.
  final framesAsync = ref.watch(weatherRadarFramesProvider);
  final frames = framesAsync.valueOrNull ?? const [];

  final radarService = ref.watch(weatherRadarServiceProvider);
  final result = radarService.lastResult;

  return RadarSourceInfo(
    providerName: result != null && result.isSuccess
        ? result.providerName
        : null,
    fetchedAt: result?.fetchedAt,
    frameCount: frames.length,
  );
});

/// Stream provider for weather alerts
///
/// Broadcasts weather alerts as conditions change. Alerts are debounced
/// to prevent rapid flapping between alert levels.
final weatherAlertStreamProvider = StreamProvider<WeatherAlert>((ref) {
  final alertService = ref.watch(weatherAlertServiceProvider);
  return alertService.alertStream;
});

// Combined status provider

/// Combined weather status provider for UI consumption
///
/// Aggregates radar frames, evaluated alert conditions, and settings into a
/// single status object for convenient access in UI widgets. Watches the
/// evaluated conditions provider directly so that the alert level reflects
/// real cloud cover and motion data rather than relying on the alert stream
/// (which only emits after debouncing and explicit evaluation calls).
final weatherStatusProvider = Provider<WeatherStatus>((ref) {
  final framesAsync = ref.watch(weatherRadarFramesProvider);

  // Watch evaluated conditions directly - this is the source of truth for
  // current weather alert level, incorporating real cloud cover from Open-Meteo
  // and cloud motion analysis from radar frames.
  final evaluatedAsync = ref.watch(evaluateWeatherConditionsProvider);

  // Also watch the stream for debounced alerts (used for notifications)
  final streamAlertAsync = ref.watch(weatherAlertStreamProvider);

  // Determine loading state
  final isLoading = framesAsync.isLoading || evaluatedAsync.isLoading;

  // Determine error message
  String? errorMessage;
  if (framesAsync.hasError) {
    errorMessage = framesAsync.error.toString();
  } else if (evaluatedAsync.hasError) {
    errorMessage = evaluatedAsync.error.toString();
  }

  // Use the evaluated alert as the primary source of truth for current level.
  // Fall back to the stream alert if evaluation hasn't completed yet.
  // Only default to clear if neither source has data.
  final WeatherAlert? activeAlert;
  final AlertLevel currentLevel;

  if (evaluatedAsync.hasValue) {
    activeAlert = evaluatedAsync.value;
    currentLevel = activeAlert?.level ?? AlertLevel.clear;
  } else if (streamAlertAsync.hasValue) {
    activeAlert = streamAlertAsync.value;
    currentLevel = activeAlert?.level ?? AlertLevel.clear;
  } else {
    activeAlert = null;
    currentLevel = AlertLevel.clear;
  }

  // Get radar frames or empty list
  final radarFrames = framesAsync.valueOrNull ?? [];

  // Freshness comes from the actual radar fetch, not wall-clock now — an
  // offline session must not read as "Updated just now".
  final radarService = ref.watch(weatherRadarServiceProvider);
  final lastFetchedAt = radarService.lastResult?.fetchedAt;

  // Build combined status
  return WeatherStatus(
    currentLevel: currentLevel,
    activeAlert: activeAlert,
    motion: null, // Updated separately by motion analysis
    radarFrames: radarFrames,
    currentFrameIndex: 0,
    // No sentinel: before the first successful radar fetch there is no update
    // time, and any stand-in date is read downstream as a real one.
    lastUpdate: lastFetchedAt,
    isLoading: isLoading,
    errorMessage: errorMessage,
  );
});

// Action providers

/// Provider that triggers radar data fetch for user's location
///
/// Call ref.read(fetchWeatherProvider) to trigger a radar data fetch.
/// Automatically uses location from app settings. Auto-disposes after use.
final fetchWeatherProvider = FutureProvider.autoDispose<void>((ref) async {
  final observerLocation = ref.watch(appObserverLocationProvider);
  if (observerLocation == null) {
    return;
  }

  final latitude = observerLocation.latitude;
  final longitude = observerLocation.longitude;

  // Skip fetch if location not set
  if (latitude == 0.0 && longitude == 0.0) {
    return;
  }

  final radarService = ref.read(weatherRadarServiceProvider);
  await radarService.fetchRadarFrames(latitude: latitude, longitude: longitude);
});

/// Provider that performs cloud motion analysis on current radar frames,
/// surfacing *why* a prediction is unavailable.
///
/// Returns a [CloudMotionResult] carrying either a real [CloudMotion] or an
/// explicit [CloudMotionUnavailableReason]. When the observer location or
/// radar frames are missing, the result is
/// [CloudMotionUnavailableReason.insufficientFrames] (there is nothing to
/// analyze) so the UI can say so honestly rather than silently hiding the
/// prediction. Auto-disposes.
final analyzeCloudMotionDetailedProvider =
    FutureProvider.autoDispose<CloudMotionResult>((ref) async {
      final observerLocation = ref.watch(appObserverLocationProvider);
      if (observerLocation == null) {
        return const CloudMotionResult.unavailable(
          CloudMotionUnavailableReason.insufficientFrames,
        );
      }

      final latitude = observerLocation.latitude;
      final longitude = observerLocation.longitude;

      // Skip analysis if location not set
      if (latitude == 0.0 && longitude == 0.0) {
        return const CloudMotionResult.unavailable(
          CloudMotionUnavailableReason.insufficientFrames,
        );
      }

      final radarService = ref.read(weatherRadarServiceProvider);
      final frames = radarService.getCachedFrames();

      if (frames == null || frames.isEmpty) {
        return const CloudMotionResult.unavailable(
          CloudMotionUnavailableReason.insufficientFrames,
        );
      }

      final analyzer = ref.read(cloudMotionAnalyzerProvider);
      return analyzer.analyzeMotionDetailed(
        frames: frames,
        userLatitude: latitude,
        userLongitude: longitude,
      );
    });

/// The legacy `CloudMotion?` shape over [analyzeCloudMotionDetailedProvider].
/// Callers that need the unavailable reason — why prediction is off — watch
/// the detailed provider instead.
final analyzeCloudMotionProvider = FutureProvider.autoDispose<CloudMotion?>((
  ref,
) async {
  final result = await ref.watch(analyzeCloudMotionDetailedProvider.future);
  return result.motion;
});

/// Provider that evaluates weather conditions and generates alerts
///
/// Call ref.read(evaluateWeatherConditionsProvider) to evaluate current
/// conditions and generate an alert. Auto-disposes after use.
final evaluateWeatherConditionsProvider =
    FutureProvider.autoDispose<WeatherAlert>((ref) async {
      final weatherSettings = await ref.watch(
        weatherSettingsDataProvider.future,
      );
      final motion = await ref.watch(analyzeCloudMotionProvider.future);

      // Get actual cloud cover percentage from Open-Meteo API
      // This is the real-time cloud cover at the user's location
      final cloudCoverPercent = await ref.watch(
        cloudCoverPercentageProvider.future,
      );

      // No real weather data at all (offline / APIs blocked): refuse to
      // fabricate a "Clear" alert. Throwing leaves no currentAlert, so
      // WeatherSafetyNotifier's fail-closed no-data path governs instead of
      // treating unknown conditions as safe.
      if (cloudCoverPercent == null && motion == null) {
        throw StateError(
          'No weather data available (cloud cover and motion unknown)',
        );
      }

      // Motion data is real radar output, so a null cloud percentage here is a
      // measured-clear-sky signal rather than a no-data fabrication.
      final currentCloudDensity = cloudCoverPercent ?? 0.0;

      final alertService = ref.read(weatherAlertServiceProvider);
      return alertService.evaluateConditions(
        motion: motion,
        currentCloudDensity: currentCloudDensity,
        settings: weatherSettings,
      );
    });
