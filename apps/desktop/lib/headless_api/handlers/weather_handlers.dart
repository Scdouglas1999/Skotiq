import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for weather data and alerts
class WeatherHandlers {
  final ProviderContainer container;

  WeatherHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'WeatherHandlers');

  /// Coarsen a coordinate before it reaches a log line. The observer's
  /// precise latitude/longitude is their home/observatory location and
  /// must not be persisted to the structured log (which is readable on
  /// disk and downloadable over `/api/logs/*`). Rounding to one decimal
  /// place (~11 km) keeps the entry useful for debugging which region a
  /// fetch covered without recording where the operator lives. The full
  /// value still flows to the upstream weather provider and the API
  /// response — only the log copy is coarsened.
  static String _coarseCoord(double? value) =>
      value == null ? 'null' : value.toStringAsFixed(1);

  // Get radar data

  Future<Response> handleGetRadarData(Request request) async {
    final query = request.url.queryParameters;
    if ((query['lat'] ?? '').isEmpty || (query['lon'] ?? '').isEmpty) {
      return jsonBadRequest({'error': 'Missing lat/lon query parameters'});
    }
    final lat = requireQueryDouble(query, 'lat', min: -90, max: 90);
    final lon = requireQueryDouble(query, 'lon', min: -180, max: 180);
    final forceRefresh = optionalQueryBool(query, 'refresh') ?? false;
    _logInfo(
      '[API] GET /api/weather/radar?lat=${_coarseCoord(lat)}&lon=${_coarseCoord(lon)}',
    );

    final service = container.read(weatherRadarServiceProvider);
    service.initialize();

    final result = await service.fetchRadarFrames(
      latitude: lat,
      longitude: lon,
      forceRefresh: forceRefresh,
    );

    if (result.isSuccess) {
      return jsonOk({
        "frames": result.frames.map((f) => _frameToJson(f)).toList(),
        "fetchedAt": result.fetchedAt.millisecondsSinceEpoch,
        "cachedAt": DateTime.now().millisecondsSinceEpoch,
      });
    }
    // An upstream radar failure is a 502, never a 200 with an empty frames
    // list — that would read to a client as "no weather" rather than "no
    // answer".
    return jsonResponse({
      "error": result.errorMessage ?? 'radar_fetch_failed',
      "frames": [],
    }, statusCode: 502);
  }

  // Get weather forecast

  Future<Response> handleGetForecast(Request request) async {
    final query = request.url.queryParameters;
    if ((query['lat'] ?? '').isEmpty || (query['lon'] ?? '').isEmpty) {
      return jsonBadRequest({'error': 'Missing lat/lon query parameters'});
    }
    final lat = requireQueryDouble(query, 'lat', min: -90, max: 90);
    final lon = requireQueryDouble(query, 'lon', min: -180, max: 180);
    _logInfo(
      '[API] GET /api/weather/forecast?lat=${_coarseCoord(lat)}&lon=${_coarseCoord(lon)}',
    );

    // Back the forecast with the same Open-Meteo hourly cloud feed the desktop
    // planner uses (weekForecastCloudProvider, keyed only on the site so remote
    // and local share one cached fetch). It returns a RadarFetchResult whose
    // frames are hourly cloud-cover samples (opacity 0-1 == cloud cover 0-100%)
    // spanning the past day plus the next several forecast days.
    try {
      final result = await container.read(
        weekForecastCloudProvider(ForecastSite(lat, lon)).future,
      );

      if (!result.isSuccess) {
        return jsonResponse({
          "error": "forecast_fetch_failed",
          "message": result.errorMessage ?? 'Cloud forecast unavailable',
        }, statusCode: 502);
      }

      final now = DateTime.now().toUtc();
      final hourly = result.frames
          .where((f) => !f.timestamp.toUtc().isBefore(now))
          .map(
            (f) => {
              'timestamp': f.timestamp.toUtc().millisecondsSinceEpoch,
              'time': f.timestamp.toUtc().toIso8601String(),
              // Open-Meteo cloud frames carry cloud cover as opacity in [0, 1].
              'cloudCoverPercent': (f.opacity.clamp(0.0, 1.0) * 100.0),
            },
          )
          .toList();

      return jsonOk({
        "hasData": true,
        "latitude": lat,
        "longitude": lon,
        "source": result.providerName ?? 'Open-Meteo',
        "fetchedAt": result.fetchedAt.millisecondsSinceEpoch,
        "lastUpdated": DateTime.now().millisecondsSinceEpoch,
        "hourly": hourly,
      });
    } catch (e, stackTrace) {
      // The fetch genuinely requires a live network call; surface a clean 502
      // rather than fabricating a forecast.
      throw HandlerFailure(
        code: 'forecast_fetch_failed',
        message: 'Cloud forecast unavailable.',
        statusCode: 502,
        cause: e,
        stackTrace: stackTrace,
      );
    }
  }

  // Get active alerts

  Future<Response> handleGetAlerts(Request request) async {
    _logInfo('[API] GET /api/weather/alerts');
    final alertService = container.read(weatherAlertServiceProvider);
    final currentAlert = alertService.currentAlert;

    if (currentAlert == null) {
      return jsonOk({"alerts": []});
    }

    return jsonOk({
      "alerts": [_alertToJson(currentAlert)],
    });
  }

  // Get cloud cover prediction

  Future<Response> handleGetCloudCover(Request request) async {
    final query = request.url.queryParameters;
    if ((query['lat'] ?? '').isEmpty || (query['lon'] ?? '').isEmpty) {
      return jsonBadRequest({'error': 'Missing lat/lon query parameters'});
    }
    final lat = requireQueryDouble(query, 'lat', min: -90, max: 90);
    final lon = requireQueryDouble(query, 'lon', min: -180, max: 180);
    _logInfo(
      '[API] GET /api/weather/cloud-cover?lat=${_coarseCoord(lat)}&lon=${_coarseCoord(lon)}',
    );

    // Use the same Open-Meteo hourly cloud feed the desktop app uses
    // (weekForecastCloudProvider), then read the sample nearest to "now" — the
    // same nearest-hour lookup OpenMeteoCloudProvider.getCloudCoverAt performs.
    // The cloudCoverPercentageProvider the UI watches is location-bound (it
    // reads the configured observer location, not an arbitrary lat/lon), so we
    // can't honor the request's lat/lon through it; this feed takes lat/lon
    // directly and shares the same provider/cache as the planner.
    try {
      final result = await container.read(
        weekForecastCloudProvider(ForecastSite(lat, lon)).future,
      );

      if (!result.isSuccess || result.frames.isEmpty) {
        return jsonResponse({
          "error": "cloud_cover_fetch_failed",
          "message": result.errorMessage ?? 'No cloud cover data available',
        }, statusCode: 502);
      }

      // Nearest frame to the current instant (frame timestamps are UTC) — the
      // same nearest-hour lookup OpenMeteoCloudProvider.getCloudCoverAt does.
      final now = DateTime.now().toUtc();
      RadarFrame nearest = result.frames.first;
      Duration bestDistance = nearest.timestamp.toUtc().difference(now).abs();
      for (final frame in result.frames) {
        final d = frame.timestamp.toUtc().difference(now).abs();
        if (d < bestDistance) {
          bestDistance = d;
          nearest = frame;
        }
      }

      return jsonOk({
        "hasData": true,
        "latitude": lat,
        "longitude": lon,
        "source": result.providerName ?? 'Open-Meteo',
        // Open-Meteo cloud frames carry cloud cover as opacity in [0, 1].
        "cloudCoverPercent": (nearest.opacity.clamp(0.0, 1.0) * 100.0),
        "timestamp": nearest.timestamp.toUtc().millisecondsSinceEpoch,
        "fetchedAt": result.fetchedAt.millisecondsSinceEpoch,
      });
    } catch (e, stackTrace) {
      // Genuine live network fetch can fail; surface a clean 502.
      throw HandlerFailure(
        code: 'cloud_cover_fetch_failed',
        message: 'Cloud cover data unavailable.',
        statusCode: 502,
        cause: e,
        stackTrace: stackTrace,
      );
    }
  }

  // Get weather settings

  /// The writable weather settings, by the names both the GET and the POST
  /// use. [handleUpdateSettings] refuses a body naming none of them.
  static const Set<String> _writableSettings = {
    'preferredProvider',
    'refreshIntervalSeconds',
    'triggerDistanceKm',
    'leadTimeMinutes',
    'cloudDensityThreshold',
    'weatherSafetyEnabled',
    'maxHumidityPercent',
    'maxWindSpeedKph',
    'maxCloudCoverPercent',
    'autoParkEnabled',
    'autoResumeEnabled',
    'forecastHoldsRun',
    'starEvidenceOverridesForecast',
  };

  /// Keys the GET echoes that are not settings. A client posting the GET
  /// document back sends `id`; it changes nothing and is not a misspelling.
  static const Set<String> _readOnlySettings = {
    'id',
    'requiredSafeDurationSeconds',
  };

  static Map<String, dynamic> _policyJson(WeatherDecisionPolicy policy) => {
    'forecastHoldsRun': policy.forecastHoldsRun,
    'starEvidenceOverridesForecast': policy.starEvidenceOverridesForecast,
    'requiredSafeDurationSeconds': policy.requiredSafeDurationSeconds,
  };

  Future<Response> handleGetSettings(Request request) async {
    _logInfo('[API] GET /api/weather/settings');
    final database = container.read(databaseProvider);
    final settings = await database.weatherSettingsDao.getOrCreateSettings();
    final policy = await SafetyConfigStore(database).loadDecisionPolicy();

    return jsonOk({
      "settings": {
        ..._policyJson(policy),
        "id": settings.id,
        "preferredProvider": settings.preferredProvider,
        "refreshIntervalSeconds": settings.refreshIntervalSeconds,
        "triggerDistanceKm": settings.triggerDistanceKm,
        "leadTimeMinutes": settings.leadTimeMinutes,
        "cloudDensityThreshold": settings.cloudDensityThreshold,
        "weatherSafetyEnabled": settings.weatherSafetyEnabled,
        "maxHumidityPercent": settings.maxHumidityPercent,
        "maxWindSpeedKph": settings.maxWindSpeedKph,
        "maxCloudCoverPercent": settings.maxCloudCoverPercent,
        "autoParkEnabled": settings.autoParkEnabled,
        "autoResumeEnabled": settings.autoResumeEnabled,
      },
    });
  }

  // Update weather settings

  Future<Response> handleUpdateSettings(Request request) async {
    _logInfo('[API] POST /api/weather/settings');
    // The GET above answers `{"settings": {...}}`, so that document is a shape
    // this endpoint must accept; the flat body older clients send stays
    // accepted too. Weather safety is armed through here, and a write that
    // stored nothing while answering "updated" left rigs unguarded overnight,
    // so a body naming no writable setting is refused instead.
    final payload = await readJsonObject(request);
    final body = settingsBody(payload, _writableSettings);
    final applied = requireSettingsFields(
      body,
      _writableSettings,
      readOnly: _readOnlySettings,
    );
    final database = container.read(databaseProvider);
    final preferredProvider = optionalString(body, 'preferredProvider');
    if (preferredProvider != null &&
        !RadarProviderType.values.any(
          (provider) =>
              provider.name.toLowerCase() == preferredProvider.toLowerCase(),
        )) {
      throw BadRequestError(
        field: 'preferredProvider',
        expected: 'radar_provider',
        message: 'Unknown weather provider',
      );
    }

    final policyStore = SafetyConfigStore(database);
    final forecastHoldsRun = optionalBool(body, 'forecastHoldsRun');
    if (forecastHoldsRun != null) {
      await policyStore.setForecastHoldsRun(forecastHoldsRun);
    }
    final starEvidence = optionalBool(body, 'starEvidenceOverridesForecast');
    if (starEvidence != null) {
      await policyStore.setStarEvidenceOverridesForecast(starEvidence);
    }

    await database.weatherSettingsDao.updateSettings(
      preferredProvider: preferredProvider,
      refreshIntervalSeconds: optionalInt(
        body,
        'refreshIntervalSeconds',
        min: 30,
        max: 3600,
      ),
      triggerDistanceKm: optionalDouble(
        body,
        'triggerDistanceKm',
        min: 1,
        max: 500,
      ),
      leadTimeMinutes: optionalInt(body, 'leadTimeMinutes', min: 1, max: 180),
      cloudDensityThreshold: optionalDouble(
        body,
        'cloudDensityThreshold',
        min: 0,
        max: 100,
      ),
      weatherSafetyEnabled: optionalBool(body, 'weatherSafetyEnabled'),
      maxHumidityPercent: optionalDouble(
        body,
        'maxHumidityPercent',
        min: 0,
        max: 100,
      ),
      maxWindSpeedKph: optionalDouble(
        body,
        'maxWindSpeedKph',
        min: 0,
        max: 150,
      ),
      maxCloudCoverPercent: optionalDouble(
        body,
        'maxCloudCoverPercent',
        min: 0,
        max: 100,
      ),
      autoParkEnabled: optionalBool(body, 'autoParkEnabled'),
      autoResumeEnabled: optionalBool(body, 'autoResumeEnabled'),
    );

    // The safety verdict is runtime policy, not just persisted preferences.
    // Reload the settings stream and await a fresh evaluation so the response
    // cannot claim the toggle succeeded while safety/status still exposes the
    // previous decision.
    final backend = container.read(backendProvider);
    if (backend is! DisconnectedBackend) {
      container.invalidate(weatherDecisionPolicyProvider);
      container.invalidate(weatherSettingsDataProvider);
      await container.read(weatherSettingsDataProvider.future);
      await container.read(weatherSafetyProvider.notifier).evaluateNow();
    }

    // Answer with the row as it now stands, not a word. "updated" alone is
    // unfalsifiable — the client that armed weather safety and got it back had
    // no way to see the toggle had not moved. `applied` names the fields this
    // request actually stored; `ignored` names the rest, so a misspelling is
    // visible without a second GET.
    final stored = await database.weatherSettingsDao.getOrCreateSettings();
    final storedPolicy = await policyStore.loadDecisionPolicy();
    final ignored =
        body.keys
            .where(
              (k) =>
                  !_writableSettings.contains(k) &&
                  !_readOnlySettings.contains(k),
            )
            .toList()
          ..sort();
    return jsonOk({
      "status": "updated",
      "applied": applied,
      if (ignored.isNotEmpty) ...{
        "ignored": ignored,
        "warning":
            'These fields are not weather settings and were not applied: '
            '${ignored.join(', ')}. Accepted fields: '
            '${(_writableSettings.toList()..sort()).join(', ')}.',
      },
      "settings": {
        ..._policyJson(storedPolicy),
        "id": stored.id,
        "preferredProvider": stored.preferredProvider,
        "refreshIntervalSeconds": stored.refreshIntervalSeconds,
        "triggerDistanceKm": stored.triggerDistanceKm,
        "leadTimeMinutes": stored.leadTimeMinutes,
        "cloudDensityThreshold": stored.cloudDensityThreshold,
        "weatherSafetyEnabled": stored.weatherSafetyEnabled,
        "maxHumidityPercent": stored.maxHumidityPercent,
        "maxWindSpeedKph": stored.maxWindSpeedKph,
        "maxCloudCoverPercent": stored.maxCloudCoverPercent,
        "autoParkEnabled": stored.autoParkEnabled,
        "autoResumeEnabled": stored.autoResumeEnabled,
      },
    });
  }

  // Check safe imaging conditions

  Future<Response> handleCheckSafeImaging(Request request) async {
    _logInfo('[API] GET /api/weather/safe-imaging');
    final alertService = container.read(weatherAlertServiceProvider);
    final currentAlert = alertService.currentAlert;
    final safety = container.read(weatherSafetyProvider);

    return jsonOk({
      "safeToImage": safety.isSafe,
      "alertLevel": currentAlert?.level.name ?? safety.currentAlertLevel.name,
      "message": _safetyMessage(safety, currentAlert),
      "dataSource": safety.dataSource.name,
      "lastEvaluation": safety.lastEvaluation?.toIso8601String(),
    });
  }

  // Live telemetry (hardware + safety aggregate)

  /// GET /api/weather/current
  ///
  /// Returns safe-imaging status plus live ObservingConditions telemetry when
  /// a weather device is connected ([weatherStateProvider]). Fields are omitted
  /// (null) when no hardware source is available — clients must not invent
  /// values.
  Future<Response> handleGetCurrent(Request request) async {
    _logInfo('[API] GET /api/weather/current');
    final alertService = container.read(weatherAlertServiceProvider);
    final currentAlert = alertService.currentAlert;
    final safety = container.read(weatherSafetyProvider);

    final weatherState = container.read(weatherStateProvider);
    final hardwareConnected =
        weatherState.connectionState == DeviceConnectionState.connected;

    double? temperature;
    double? humidity;
    double? cloudCover;
    double? windSpeed;
    double? dewPoint;
    if (hardwareConnected) {
      temperature = weatherState.temperature;
      humidity = weatherState.humidity;
      cloudCover = weatherState.cloudCover;
      windSpeed = weatherState.windSpeed;
      dewPoint = weatherState.dewPoint;
    }

    return jsonOk({
      'safeToImage': safety.isSafe,
      'alertLevel': currentAlert?.level.name ?? safety.currentAlertLevel.name,
      'message': _safetyMessage(safety, currentAlert),
      'dataSource': safety.dataSource.name,
      'lastEvaluation': safety.lastEvaluation?.toIso8601String(),
      'currentAlert': currentAlert != null ? _alertToJson(currentAlert) : null,
      'hardwareConnected': hardwareConnected,
      'deviceId': weatherState.deviceId,
      'deviceName': weatherState.deviceName,
      'lastUpdated': weatherState.lastUpdated?.toIso8601String(),
      'temperature': temperature,
      'humidity': humidity,
      'cloudCover': cloudCover,
      // Native observing-condition drivers report wind in m/s. Keep the
      // legacy `windSpeed` field in that unit for wire compatibility, while
      // publishing explicit-unit fields so new clients cannot accidentally
      // compare it with the km/h safety threshold.
      'windSpeed': windSpeed,
      'windSpeedMps': windSpeed,
      'windSpeedKph': hardwareConnected ? weatherState.windSpeedKph : null,
      'dewPoint': dewPoint,
      'pressure': hardwareConnected ? weatherState.pressure : null,
      'windDirection': hardwareConnected ? weatherState.windDirection : null,
      'skyQuality': hardwareConnected ? weatherState.skyQuality : null,
      'skyTemperature': hardwareConnected ? weatherState.skyTemperature : null,
      'rainRate': hardwareConnected ? weatherState.rainRate : null,
    });
  }

  // Clear weather cache

  Future<Response> handleClearCache(Request request) async {
    _logInfo('[API] POST /api/weather/clear-cache');
    final service = container.read(weatherRadarServiceProvider);
    service.clearCache();

    return jsonOk({"status": "cache_cleared"});
  }

  // Helpers

  String _safetyMessage(WeatherSafetyState safety, WeatherAlert? currentAlert) {
    if (currentAlert != null) return currentAlert.message;
    if (safety.actions.reason != null) return safety.actions.reason!;
    if (safety.failModeWarning != null) return safety.failModeWarning!;
    if (safety.isSafe) return 'Conditions are safe for imaging';
    return 'Weather safety has not been evaluated';
  }

  Map<String, dynamic> _frameToJson(RadarFrame frame) {
    return {
      'timestamp': frame.timestamp.millisecondsSinceEpoch,
      'tileUrlTemplate': frame.tileUrlTemplate,
      'north': frame.north,
      'south': frame.south,
      'east': frame.east,
      'west': frame.west,
      'opacity': frame.opacity,
      'isForecast': frame.isForecast,
      'tileType': frame.tileType.name,
    };
  }

  Map<String, dynamic> _alertToJson(WeatherAlert alert) {
    return {
      'level': alert.level.name,
      'message': alert.message,
      'eta': alert.eta?.millisecondsSinceEpoch,
      'cloudDensityPercent': alert.cloudDensityPercent.isFinite
          ? alert.cloudDensityPercent
          : null,
      // "No cloud front detected" is represented in memory as an infinite
      // distance, which is the right sentinel for the threshold comparisons in
      // WeatherAlertService but has no JSON encoding — emitting it raw made
      // jsonEncode throw and turned both /api/weather/current and
      // /api/weather/alerts into a 500 on a *clear* night, i.e. exactly when
      // the honest answer was "nothing out there". Null is that answer: there
      // is no front, so there is no distance to it.
      'distanceKm': alert.distanceKm.isFinite ? alert.distanceKm : null,
      'generatedAt': alert.generatedAt.millisecondsSinceEpoch,
    };
  }
}
