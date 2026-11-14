import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/weather/weather_models.dart';
import '../models/weather/cloud_cover_forecast.dart';

import '../services/weather/location_cloud_forecast_service.dart';
import '../services/weather/weather_radar_service.dart';
import '../services/weather/cloud_motion_analyzer.dart';
import '../services/weather/weather_alert_service.dart';
import '../database/database.dart' as db;
import '../services/safety_config_service.dart';
import '../backend/remote_host.dart';
import 'host_role.dart';
import 'database_provider.dart';
import 'settings_provider.dart';
import '../services/logging_service.dart';

export 'weather_safety_provider.dart';

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

/// Synchronous provider for weather settings
///
/// Returns the current weather settings model, converting from the database
/// row type. Returns default settings if database settings are not yet loaded.
final weatherSettingsDataProvider = StreamProvider<WeatherSettings>(
  (ref) => ref.watch(weatherRulesProvider).watchSettings(),
);

/// How weather verdicts act on a run (see [WeatherDecisionPolicy]).
final weatherDecisionPolicyProvider = FutureProvider<WeatherDecisionPolicy>(
  (ref) => ref.watch(weatherRulesProvider).decisionPolicy(),
);

/// The weather thresholds and decision switches of whichever machine is the
/// imaging host, where the weather watch runs.
abstract interface class WeatherRules {
  Stream<WeatherSettings> watchSettings();

  Future<WeatherDecisionPolicy> decisionPolicy();

  /// Stores the given settings; a null one is left as it is.
  Future<void> updateSettings(WeatherSettingsChange change);

  Future<void> setDecisionPolicy({
    bool? forecastHoldsRun,
    bool? starEvidenceOverridesForecast,
  });
}

typedef WeatherSettingsChange = ({
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
});

final weatherRulesProvider = hostRoleProvider<WeatherRules>(
  here: (ref) => _LocalWeatherRules(ref.watch(databaseProvider)),
  linked: (ref, host) => _HostWeatherRules(host.weather),
);

final class _LocalWeatherRules implements WeatherRules {
  _LocalWeatherRules(this._database);

  final db.SkotiqDatabase _database;

  @override
  Stream<WeatherSettings> watchSettings() =>
      _database.weatherSettingsDao.watchSettings().map(
        (row) => row == null
            ? WeatherSettings.defaultSettings
            : _weatherSettingsFromRow(row),
      );

  @override
  Future<WeatherDecisionPolicy> decisionPolicy() =>
      SafetyConfigStore(_database).loadDecisionPolicy();

  @override
  Future<void> updateSettings(WeatherSettingsChange change) =>
      _database.weatherSettingsDao.updateSettings(
        triggerDistanceKm: change.triggerDistanceKm,
        cloudDensityThreshold: change.cloudDensityThreshold,
        leadTimeMinutes: change.leadTimeMinutes,
        weatherSafetyEnabled: change.weatherSafetyEnabled,
        maxHumidityPercent: change.maxHumidityPercent,
        maxWindSpeedKph: change.maxWindSpeedKph,
        maxCloudCoverPercent: change.maxCloudCoverPercent,
        autoParkEnabled: change.autoParkEnabled,
        autoResumeEnabled: change.autoResumeEnabled,
        preferredProvider: change.preferredProvider?.name,
        refreshIntervalSeconds: change.refreshIntervalSeconds,
      );

  @override
  Future<void> setDecisionPolicy({
    bool? forecastHoldsRun,
    bool? starEvidenceOverridesForecast,
  }) async {
    final store = SafetyConfigStore(_database);
    if (forecastHoldsRun != null) {
      await store.setForecastHoldsRun(forecastHoldsRun);
    }
    if (starEvidenceOverridesForecast != null) {
      await store.setStarEvidenceOverridesForecast(
        starEvidenceOverridesForecast,
      );
    }
  }
}

final class _HostWeatherRules implements WeatherRules {
  _HostWeatherRules(this._host);

  final HostWeather _host;
  final _watchers = <StreamController<WeatherSettings>>{};

  /// The host's settings as read when listened to, and again after a change
  /// made from here.
  @override
  Stream<WeatherSettings> watchSettings() {
    late final StreamController<WeatherSettings> controller;
    controller = StreamController<WeatherSettings>(
      onListen: () {
        _watchers.add(controller);
        unawaited(_read(controller));
      },
      onCancel: () => _watchers.remove(controller),
    );
    return controller.stream;
  }

  Future<void> _read(StreamController<WeatherSettings> to) async {
    try {
      final settings = _weatherSettingsFromWire(
        await _host.getWeatherSettings(),
      );
      if (_watchers.contains(to)) to.add(settings);
    } on Object catch (error, stackTrace) {
      if (_watchers.contains(to)) to.addError(error, stackTrace);
    }
  }

  @override
  Future<WeatherDecisionPolicy> decisionPolicy() async {
    final wire = await _host.getWeatherSettings();
    const defaults = WeatherDecisionPolicy.defaults;
    final safeSecs = wire['requiredSafeDurationSeconds'];
    return WeatherDecisionPolicy(
      forecastHoldsRun: wire['forecastHoldsRun'] is bool
          ? wire['forecastHoldsRun'] as bool
          : defaults.forecastHoldsRun,
      starEvidenceOverridesForecast:
          wire['starEvidenceOverridesForecast'] is bool
          ? wire['starEvidenceOverridesForecast'] as bool
          : defaults.starEvidenceOverridesForecast,
      requiredSafeDurationSeconds: safeSecs is int
          ? safeSecs
          : defaults.requiredSafeDurationSeconds,
    );
  }

  @override
  Future<void> updateSettings(WeatherSettingsChange change) async {
    await _host.updateWeatherSettings({
      if (change.triggerDistanceKm != null)
        'triggerDistanceKm': change.triggerDistanceKm,
      if (change.cloudDensityThreshold != null)
        'cloudDensityThreshold': change.cloudDensityThreshold,
      if (change.leadTimeMinutes != null)
        'leadTimeMinutes': change.leadTimeMinutes,
      if (change.weatherSafetyEnabled != null)
        'weatherSafetyEnabled': change.weatherSafetyEnabled,
      if (change.maxHumidityPercent != null)
        'maxHumidityPercent': change.maxHumidityPercent,
      if (change.maxWindSpeedKph != null)
        'maxWindSpeedKph': change.maxWindSpeedKph,
      if (change.maxCloudCoverPercent != null)
        'maxCloudCoverPercent': change.maxCloudCoverPercent,
      if (change.autoParkEnabled != null)
        'autoParkEnabled': change.autoParkEnabled,
      if (change.autoResumeEnabled != null)
        'autoResumeEnabled': change.autoResumeEnabled,
      if (change.preferredProvider != null)
        'preferredProvider': change.preferredProvider!.name,
      if (change.refreshIntervalSeconds != null)
        'refreshIntervalSeconds': change.refreshIntervalSeconds,
    });
    await Future.wait(_watchers.toList().map(_read));
  }

  @override
  Future<void> setDecisionPolicy({
    bool? forecastHoldsRun,
    bool? starEvidenceOverridesForecast,
  }) => _host.updateWeatherSettings({
    if (forecastHoldsRun != null) 'forecastHoldsRun': forecastHoldsRun,
    if (starEvidenceOverridesForecast != null)
      'starEvidenceOverridesForecast': starEvidenceOverridesForecast,
  });
}

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

const WeatherSettingsChange _noWeatherChange = (
  triggerDistanceKm: null,
  cloudDensityThreshold: null,
  leadTimeMinutes: null,
  weatherSafetyEnabled: null,
  maxHumidityPercent: null,
  maxWindSpeedKph: null,
  maxCloudCoverPercent: null,
  autoParkEnabled: null,
  autoResumeEnabled: null,
  preferredProvider: null,
  refreshIntervalSeconds: null,
);

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
    final change = (
      triggerDistanceKm: triggerDistanceKm,
      cloudDensityThreshold: cloudDensityThreshold,
      leadTimeMinutes: leadTimeMinutes,
      weatherSafetyEnabled: weatherSafetyEnabled,
      maxHumidityPercent: maxHumidityPercent,
      maxWindSpeedKph: maxWindSpeedKph,
      maxCloudCoverPercent: maxCloudCoverPercent,
      autoParkEnabled: autoParkEnabled,
      autoResumeEnabled: autoResumeEnabled,
      preferredProvider: preferredProvider,
      refreshIntervalSeconds: refreshIntervalSeconds,
    );
    if (change == _noWeatherChange) return;
    await _ref.read(weatherRulesProvider).updateSettings(change);
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
  /// Write the [WeatherDecisionPolicy] switches. Each is a host setting; a
  /// linked client writes the host's.
  Future<void> setDecisionPolicy({
    bool? forecastHoldsRun,
    bool? starEvidenceOverridesForecast,
  }) async {
    await _ref
        .read(weatherRulesProvider)
        .setDecisionPolicy(
          forecastHoldsRun: forecastHoldsRun,
          starEvidenceOverridesForecast: starEvidenceOverridesForecast,
        );
    _ref.invalidate(weatherDecisionPolicyProvider);
  }

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

/// The numerical projection used by existing forecast consumers.
final cloudCoverPercentageProvider = FutureProvider<double?>((ref) async {
  return (await ref.watch(cloudCoverForecastProvider.future))?.percent;
});

/// The location-aware source policy shared by current and hourly forecasts.
final locationCloudForecastServiceProvider =
    Provider<LocationCloudForecastService>((ref) {
      final service = LocationCloudForecastService();
      ref.onDispose(service.dispose);
      return service;
    });

/// Forecast cloud cover with its source and valid time, independent of imagery.
final cloudCoverForecastProvider = FutureProvider<CloudCoverForecast?>((ref) {
  final location = ref.watch(appObserverLocationProvider);
  if (location == null) return null;
  return ref
      .watch(locationCloudForecastServiceProvider)
      .fetchCurrentCloudForecast(
        latitude: location.latitude,
        longitude: location.longitude,
      );
});

/// Provider for radar frames that triggers fetching automatically.
///
/// Watches the user's location from app settings and fetches radar frames
/// from the appropriate provider. Re-fetches when invalidated.
final weatherRadarFramesProvider = FutureProvider<List<RadarFrame>>((
  ref,
) async {
  final observerLocation = ref.watch(appObserverLocationProvider);
  if (observerLocation == null) {
    Log.debug('No app settings yet, returning empty', source: 'WeatherRadar');
    return [];
  }

  final latitude = observerLocation.latitude;
  final longitude = observerLocation.longitude;

  // Skip fetch if location not set
  if (latitude == 0.0 && longitude == 0.0) {
    Log.debug('Location not set, returning empty', source: 'WeatherRadar');
    return [];
  }

  Log.debug(
    'Fetching for location ($latitude, $longitude)',
    source: 'WeatherRadar',
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
    Log.debug('Got ${result.frames.length} frames', source: 'WeatherRadar');
    return result.frames;
  } else {
    Log.warning(
      'Fetch failed - ${result.errorMessage}',
      source: 'WeatherRadar',
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
/// fetch time from the radar service's last successful fetch.
final radarSourceInfoProvider = Provider<RadarSourceInfo>((ref) {
  // Re-read whenever the frames change so attribution tracks the live data.
  final framesAsync = ref.watch(weatherRadarFramesProvider);
  final frames = framesAsync.valueOrNull ?? const [];

  final radarService = ref.watch(weatherRadarServiceProvider);
  final result = radarService.lastSuccessfulResult;

  return RadarSourceInfo(
    providerName: result?.providerName,
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

  final isLoading = framesAsync.isLoading || evaluatedAsync.isLoading;

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

  final radarFrames = framesAsync.valueOrNull ?? [];

  // Freshness is the time of the last fetch that returned data: a failed
  // attempt is not an update.
  final radarService = ref.watch(weatherRadarServiceProvider);
  final lastFetchedAt = radarService.lastSuccessfulResult?.fetchedAt;

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

      // Read the model estimate for the site, independent of satellite imagery.
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
