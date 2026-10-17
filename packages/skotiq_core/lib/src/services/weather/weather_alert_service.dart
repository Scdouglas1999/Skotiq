// ignore_for_file: unused_local_variable

import 'dart:async';

import '../../models/weather/weather_models.dart';

/// Service for generating weather alerts based on radar data and thresholds
class WeatherAlertService {
  WeatherAlertService({Duration debounceDuration = const Duration(seconds: 30)})
    : _debounceDuration = debounceDuration;

  final StreamController<WeatherAlert> _alertController =
      StreamController<WeatherAlert>.broadcast();

  final Duration _debounceDuration;
  WeatherAlert? _previousAlert;
  DateTime? _lastAlertChangeTime;

  /// Stream of weather alerts for UI subscription
  Stream<WeatherAlert> get alertStream => _alertController.stream;

  /// Dispose resources
  void dispose() {
    _alertController.close();
  }

  /// Evaluate weather conditions and generate appropriate alert
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

    // Determine alert level
    final level = determineAlertLevel(
      cloudDistanceKm: distanceKm,
      cloudDensityPercent: currentCloudDensity,
      eta: eta,
      settings: settings,
    );

    // Generate human-readable message
    final message = generateAlertMessage(
      level: level,
      distanceKm: distanceKm,
      densityPercent: currentCloudDensity,
      eta: eta,
      directionDegrees: motion?.directionDegrees,
    );

    // Create alert
    final alert = WeatherAlert(
      level: level,
      message: message,
      eta: eta != null ? now.add(eta) : null,
      cloudDensityPercent: currentCloudDensity,
      distanceKm: distanceKm,
      generatedAt: now,
    );

    // Apply debouncing
    final debouncedAlert = debounceAlert(
      newAlert: alert,
      previousAlert: _previousAlert,
      debounceDuration: _debounceDuration,
      lastChangeTime: _lastAlertChangeTime ?? now,
      currentTime: now,
    );

    // Emit alert if debouncing passed
    if (debouncedAlert != null) {
      emitAlert(debouncedAlert);
      _previousAlert = debouncedAlert;
      _lastAlertChangeTime = now;
    }

    return alert;
  }

  /// Determine alert level based on conditions and thresholds
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

    // Default to clear
    return AlertLevel.clear;
  }

  /// Generate human-readable alert message
  String generateAlertMessage({
    required AlertLevel level,
    required double distanceKm,
    required double densityPercent,
    required Duration? eta,
    double? directionDegrees,
  }) {
    switch (level) {
      case AlertLevel.clear:
        if (distanceKm.isInfinite) {
          return 'No clouds detected in monitoring range';
        }
        final distance = distanceKm.toStringAsFixed(0);
        return 'Skies clear within ${distance}km radius';

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
              ? degreesToCardinal(directionDegrees)
              : 'unknown direction';
          return 'Clouds detected ${distance}km away from $direction, ETA ~$etaMinutes minutes';
        }

      case AlertLevel.warning:
        final distance = distanceKm.toStringAsFixed(0);
        final density = densityPercent.toStringAsFixed(0);
        final etaMinutes = eta?.inMinutes ?? 0;
        final direction = directionDegrees != null
            ? degreesToCardinal(directionDegrees)
            : 'unknown direction';

        if (densityPercent >= 80.0) {
          return 'Dense clouds ($density%) approaching from $direction, ETA ~$etaMinutes minutes';
        } else {
          return 'Clouds approaching from $direction, ETA ~$etaMinutes minutes ($density% density)';
        }

      case AlertLevel.critical:
        final density = densityPercent.toStringAsFixed(0);

        if (distanceKm < 5.0) {
          return 'Heavy cloud cover overhead ($density% density) - consider pausing';
        } else {
          final etaMinutes = eta?.inMinutes ?? 0;
          return 'Critical: Dense clouds ($density%) arriving in ~$etaMinutes minutes - take protective action';
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

  /// Emit new alert to stream
  void emitAlert(WeatherAlert alert) {
    if (!_alertController.isClosed) {
      _alertController.add(alert);
    }
  }

  /// Convert degrees to cardinal direction (N, NE, E, SE, S, SW, W, NW)
  ///
  /// Direction represents where clouds are coming FROM:
  /// - 0° = North (clouds moving from north to south)
  /// - 90° = East (clouds moving from east to west)
  /// - 180° = South (clouds moving from south to north)
  /// - 270° = West (clouds moving from west to east)
  String degreesToCardinal(double degrees) {
    // Normalize to 0-360 range
    final normalized = degrees % 360;

    // 8 cardinal directions, each covering 45 degrees
    // Add 22.5 to center each direction on its cardinal point
    final index = ((normalized + 22.5) / 45).floor() % 8;

    const directions = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return directions[index];
  }

  /// Get current alert state (for non-stream access)
  WeatherAlert? get currentAlert => _previousAlert;
}
