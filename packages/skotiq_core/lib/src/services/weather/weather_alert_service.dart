// ignore_for_file: unused_local_variable

import 'package:skotiq_astro/format.dart';
import 'dart:async';

import '../../models/weather/weather_models.dart';

class WeatherAlertService {
  WeatherAlertService({Duration debounceDuration = const Duration(seconds: 30)})
    : _debounceDuration = debounceDuration;

  final StreamController<WeatherAlert> _alertController =
      StreamController<WeatherAlert>.broadcast();

  final Duration _debounceDuration;
  WeatherAlert? _previousAlert;
  DateTime? _lastAlertChangeTime;

  Stream<WeatherAlert> get alertStream => _alertController.stream;

  void dispose() {
    _alertController.close();
  }

  WeatherAlert evaluateConditions({
    required CloudMotion? motion,
    required double currentCloudDensity,
    required WeatherSettings settings,
  }) {
    final now = DateTime.now();

    // Determine distance and ETA from motion data
    // If we have high cloud cover but no motion data, treat as clouds overhead (distance = 0)
    // This handles the case where clouds are directly over the user but motion can't be calculated
    final double distanceKm;
    if (motion != null) {
      distanceKm = motion.distanceKm;
    } else if (currentCloudDensity >= settings.cloudDensityThreshold) {
      // High cloud cover but no motion - clouds are likely overhead
      distanceKm = 0.0;
    } else {
      // No clouds detected
      distanceKm = double.infinity;
    }
    final eta = motion?.etaToLocation;

    final level = determineAlertLevel(
      cloudDistanceKm: distanceKm,
      cloudDensityPercent: currentCloudDensity,
      eta: eta,
      settings: settings,
    );

    final message = generateAlertMessage(
      level: level,
      distanceKm: distanceKm,
      densityPercent: currentCloudDensity,
      eta: eta,
      directionDegrees: motion?.directionDegrees,
    );

    final alert = WeatherAlert(
      level: level,
      message: message,
      eta: eta != null ? now.add(eta) : null,
      cloudDensityPercent: currentCloudDensity,
      distanceKm: distanceKm,
      generatedAt: now,
    );

    final debouncedAlert = debounceAlert(
      newAlert: alert,
      previousAlert: _previousAlert,
      debounceDuration: _debounceDuration,
      lastChangeTime: _lastAlertChangeTime ?? now,
      currentTime: now,
    );

    if (debouncedAlert != null) {
      emitAlert(debouncedAlert);
      _previousAlert = debouncedAlert;
      _lastAlertChangeTime = now;
    }

    return alert;
  }

  AlertLevel determineAlertLevel({
    required double cloudDistanceKm,
    required double cloudDensityPercent,
    required Duration? eta,
    required WeatherSettings settings,
  }) {
    // Critical: Dense clouds overhead or ETA < 5 minutes
    if (cloudDistanceKm < 5.0 &&
        cloudDensityPercent >= settings.cloudDensityThreshold) {
      return AlertLevel.critical;
    }

    if (eta != null &&
        eta.inMinutes < 5 &&
        cloudDensityPercent >= settings.cloudDensityThreshold) {
      return AlertLevel.critical;
    }

    // Clear: No clouds within trigger distance OR density below threshold
    if (cloudDistanceKm > settings.triggerDistanceKm) {
      return AlertLevel.clear;
    }

    if (cloudDensityPercent < settings.cloudDensityThreshold) {
      return AlertLevel.clear;
    }

    // Watch: Clouds detected but moving away or ETA > lead time
    if (eta == null) {
      // No ETA means clouds are moving away or stationary far away
      return AlertLevel.watch;
    }

    if (eta.inMinutes > settings.leadTimeMinutes) {
      return AlertLevel.watch;
    }

    // Warning: Clouds approaching within lead time threshold
    if (eta.inMinutes <= settings.leadTimeMinutes && eta.inMinutes >= 5) {
      return AlertLevel.warning;
    }

    return AlertLevel.clear;
  }

  String generateAlertMessage({
    required AlertLevel level,
    required double distanceKm,
    required double densityPercent,
    required Duration? eta,
    double? directionDegrees,
  }) {
    switch (level) {
      case AlertLevel.clear:
        return 'Forecast cloud cover: ${densityPercent.toStringAsFixed(0)}%. '
            'Local conditions may differ.';

      case AlertLevel.watch:
        final distance = distanceKm.toStringAsFixed(0);
        final density = densityPercent.toStringAsFixed(0);

        if (eta == null) {
          // Clouds detected but moving away
          return 'Clouds detected ${distance}km away ($density% density), moving away from location';
        } else {
          // Clouds detected but ETA beyond lead time
          final etaMinutes = eta.inMinutes;
          final direction = directionDegrees != null
              ? AngleFormat.compass(directionDegrees, points: 8)
              : 'unknown direction';
          return 'Clouds detected ${distance}km away from $direction, ETA ~$etaMinutes minutes';
        }

      case AlertLevel.warning:
        final distance = distanceKm.toStringAsFixed(0);
        final density = densityPercent.toStringAsFixed(0);
        final etaMinutes = eta?.inMinutes ?? 0;
        final direction = directionDegrees != null
            ? AngleFormat.compass(directionDegrees, points: 8)
            : 'unknown direction';

        if (densityPercent >= 80.0) {
          return 'Dense clouds ($density%) approaching from $direction, ETA ~$etaMinutes minutes';
        } else {
          return 'Clouds approaching from $direction, ETA ~$etaMinutes minutes ($density% density)';
        }

      case AlertLevel.critical:
        final density = densityPercent.toStringAsFixed(0);

        if (distanceKm < 5.0) {
          return 'Heavy cloud cover overhead ($density% density)';
        } else {
          final etaMinutes = eta?.inMinutes ?? 0;
          return 'Dense clouds ($density%) arriving in ~$etaMinutes minutes';
        }
    }
  }

  /// Debounce alert changes to prevent rapid flapping
  ///
  /// Only change alert level if new level persists for debounce duration.
  /// Returns the alert to emit, or null if still debouncing.
  WeatherAlert? debounceAlert({
    required WeatherAlert newAlert,
    required WeatherAlert? previousAlert,
    required Duration debounceDuration,
    required DateTime lastChangeTime,
    required DateTime currentTime,
  }) {
    // First alert ever - emit immediately
    if (previousAlert == null) {
      return newAlert;
    }

    // Alert level hasn't changed - update with latest data
    if (newAlert.level == previousAlert.level) {
      return newAlert;
    }

    // Alert level changed - check debounce period
    final timeSinceChange = currentTime.difference(lastChangeTime);

    if (timeSinceChange >= debounceDuration) {
      // Debounce period elapsed - allow level change
      return newAlert;
    }

    // Still within debounce period - keep previous level
    return null;
  }

  void emitAlert(WeatherAlert alert) {
    if (!_alertController.isClosed) {
      _alertController.add(alert);
    }
  }

  /// Get current alert state (for non-stream access)
  WeatherAlert? get currentAlert => _previousAlert;
}
