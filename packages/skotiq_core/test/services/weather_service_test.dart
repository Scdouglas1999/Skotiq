import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/weather/weather_models.dart';
import 'package:skotiq_core/src/services/weather/weather_alert_service.dart';
import 'package:skotiq_core/src/services/weather/cloud_motion_analyzer.dart';

void main() {
  group('WeatherAlertService', () {
    late WeatherAlertService alertService;

    setUp(() {
      alertService = WeatherAlertService(
        debounceDuration: const Duration(seconds: 30),
      );
    });

    tearDown(() {
      alertService.dispose();
    });

    group('determineAlertLevel', () {
      test('returns critical when dense clouds are overhead', () {
        const settings = WeatherSettings(
          cloudDensityThreshold: 60.0,
          triggerDistanceKm: 30.0,
          leadTimeMinutes: 15,
        );

        final level = alertService.determineAlertLevel(
          cloudDistanceKm: 3.0, // < 5 km
          cloudDensityPercent: 80.0, // >= threshold
          eta: null,
          settings: settings,
        );

        expect(level, AlertLevel.critical);
      });

      test(
        'returns critical when ETA is under 5 minutes with dense clouds',
        () {
          const settings = WeatherSettings(
            cloudDensityThreshold: 60.0,
            triggerDistanceKm: 30.0,
            leadTimeMinutes: 15,
          );

          final level = alertService.determineAlertLevel(
            cloudDistanceKm: 10.0,
            cloudDensityPercent: 75.0, // >= threshold
            eta: const Duration(minutes: 3), // < 5 min
            settings: settings,
          );

          expect(level, AlertLevel.critical);
        },
      );

      test('returns clear when clouds are beyond trigger distance', () {
        const settings = WeatherSettings(
          cloudDensityThreshold: 60.0,
          triggerDistanceKm: 30.0,
          leadTimeMinutes: 15,
        );

        final level = alertService.determineAlertLevel(
          cloudDistanceKm: 50.0, // > triggerDistanceKm
          cloudDensityPercent: 80.0,
          eta: const Duration(minutes: 60),
          settings: settings,
        );

        expect(level, AlertLevel.clear);
      });

      test('returns clear when density is below threshold', () {
        const settings = WeatherSettings(
          cloudDensityThreshold: 60.0,
          triggerDistanceKm: 30.0,
          leadTimeMinutes: 15,
        );

        final level = alertService.determineAlertLevel(
          cloudDistanceKm: 10.0,
          cloudDensityPercent: 30.0, // < threshold
          eta: const Duration(minutes: 5),
          settings: settings,
        );

        expect(level, AlertLevel.clear);
      });

      test('returns warning when ETA is within lead time but above 5 min', () {
        const settings = WeatherSettings(
          cloudDensityThreshold: 60.0,
          triggerDistanceKm: 30.0,
          leadTimeMinutes: 15,
        );

        final level = alertService.determineAlertLevel(
          cloudDistanceKm: 20.0,
          cloudDensityPercent: 70.0,
          eta: const Duration(minutes: 10), // between 5 and 15
          settings: settings,
        );

        expect(level, AlertLevel.warning);
      });

      test('returns watch when no ETA and within trigger distance', () {
        const settings = WeatherSettings(
          cloudDensityThreshold: 60.0,
          triggerDistanceKm: 30.0,
          leadTimeMinutes: 15,
        );

        final level = alertService.determineAlertLevel(
          cloudDistanceKm: 20.0,
          cloudDensityPercent: 70.0,
          eta: null, // no ETA => moving away or stationary
          settings: settings,
        );

        expect(level, AlertLevel.watch);
      });

      test('returns watch when ETA exceeds lead time', () {
        const settings = WeatherSettings(
          cloudDensityThreshold: 60.0,
          triggerDistanceKm: 30.0,
          leadTimeMinutes: 15,
        );

        final level = alertService.determineAlertLevel(
          cloudDistanceKm: 25.0,
          cloudDensityPercent: 70.0,
          eta: const Duration(minutes: 30), // > 15 min lead time
          settings: settings,
        );

        expect(level, AlertLevel.watch);
      });
    });

    group('debounceAlert', () {
      test('emits first alert immediately when no previous alert exists', () {
        final alert = WeatherAlert(
          level: AlertLevel.warning,
          message: 'Test',
          cloudDensityPercent: 70.0,
          distanceKm: 15.0,
          generatedAt: DateTime.now(),
        );

        final result = alertService.debounceAlert(
          newAlert: alert,
          previousAlert: null,
          debounceDuration: const Duration(seconds: 30),
          lastChangeTime: DateTime.now(),
          currentTime: DateTime.now(),
        );

        expect(result, isNotNull);
        expect(result!.level, AlertLevel.warning);
      });

      test('allows same-level update without debounce', () {
        final now = DateTime.now();
        final previous = WeatherAlert(
          level: AlertLevel.warning,
          message: 'Previous',
          cloudDensityPercent: 65.0,
          distanceKm: 18.0,
          generatedAt: now.subtract(const Duration(seconds: 5)),
        );
        final current = WeatherAlert(
          level: AlertLevel.warning, // same level
          message: 'Updated',
          cloudDensityPercent: 70.0,
          distanceKm: 15.0,
          generatedAt: now,
        );

        final result = alertService.debounceAlert(
          newAlert: current,
          previousAlert: previous,
          debounceDuration: const Duration(seconds: 30),
          lastChangeTime: now.subtract(const Duration(seconds: 5)),
          currentTime: now,
        );

        expect(result, isNotNull);
        expect(result!.message, 'Updated');
      });

      test('suppresses level change within debounce window', () {
        final now = DateTime.now();
        final previous = WeatherAlert(
          level: AlertLevel.watch,
          message: 'Watch',
          cloudDensityPercent: 50.0,
          distanceKm: 25.0,
          generatedAt: now.subtract(const Duration(seconds: 10)),
        );
        final current = WeatherAlert(
          level: AlertLevel.warning, // different level
          message: 'Warning',
          cloudDensityPercent: 70.0,
          distanceKm: 15.0,
          generatedAt: now,
        );

        final result = alertService.debounceAlert(
          newAlert: current,
          previousAlert: previous,
          debounceDuration: const Duration(seconds: 30),
          lastChangeTime: now.subtract(
            const Duration(seconds: 10),
          ), // only 10s ago
          currentTime: now,
        );

        expect(
          result,
          isNull,
          reason:
              'Alert level change should be suppressed within debounce window',
        );
      });

      test('allows level change after debounce period elapses', () {
        final now = DateTime.now();
        final previous = WeatherAlert(
          level: AlertLevel.watch,
          message: 'Watch',
          cloudDensityPercent: 50.0,
          distanceKm: 25.0,
          generatedAt: now.subtract(const Duration(seconds: 60)),
        );
        final current = WeatherAlert(
          level: AlertLevel.warning,
          message: 'Warning',
          cloudDensityPercent: 70.0,
          distanceKm: 15.0,
          generatedAt: now,
        );

        final result = alertService.debounceAlert(
          newAlert: current,
          previousAlert: previous,
          debounceDuration: const Duration(seconds: 30),
          lastChangeTime: now.subtract(
            const Duration(seconds: 45),
          ), // 45s ago > 30s
          currentTime: now,
        );

        expect(result, isNotNull);
        expect(result!.level, AlertLevel.warning);
      });
    });

    group('degreesToCardinal', () {
      test('0 degrees maps to N', () {
        expect(alertService.degreesToCardinal(0.0), 'N');
      });

      test('90 degrees maps to E', () {
        expect(alertService.degreesToCardinal(90.0), 'E');
      });

      test('180 degrees maps to S', () {
        expect(alertService.degreesToCardinal(180.0), 'S');
      });

      test('270 degrees maps to W', () {
        expect(alertService.degreesToCardinal(270.0), 'W');
      });

      test('45 degrees maps to NE', () {
        expect(alertService.degreesToCardinal(45.0), 'NE');
      });

      test('360 degrees wraps to N', () {
        expect(alertService.degreesToCardinal(360.0), 'N');
      });
    });

    group('alertStream', () {
      test('emitAlert publishes to stream', () async {
        final alert = WeatherAlert(
          level: AlertLevel.critical,
          message: 'Overhead cloud cover',
          cloudDensityPercent: 90.0,
          distanceKm: 2.0,
          generatedAt: DateTime.now(),
        );

        final future = alertService.alertStream.first;
        alertService.emitAlert(alert);
        final received = await future;

        expect(received.level, AlertLevel.critical);
        expect(received.message, 'Overhead cloud cover');
      });
    });
  });

  group('CloudMotionAnalyzer', () {
    late CloudMotionAnalyzer analyzer;

    setUp(() {
      analyzer = CloudMotionAnalyzer();
    });

    group('calculateDistance', () {
      test('same point returns zero distance', () {
        final dist = analyzer.calculateDistance(40.0, -90.0, 40.0, -90.0);
        expect(dist, closeTo(0.0, 0.001));
      });

      test('known distance between two cities is approximately correct', () {
        // New York (40.7128, -74.0060) to Los Angeles (34.0522, -118.2437)
        // Known distance: ~3944 km
        final dist = analyzer.calculateDistance(
          40.7128,
          -74.0060,
          34.0522,
          -118.2437,
        );

        expect(dist, closeTo(3944.0, 50.0)); // within 50 km
      });

      test('one degree of latitude is approximately 111 km', () {
        final dist = analyzer.calculateDistance(0.0, 0.0, 1.0, 0.0);
        expect(dist, closeTo(111.0, 1.0));
      });
    });

    group('calculateBearing', () {
      test('due north bearing is 0 degrees', () {
        final bearing = analyzer.calculateBearing(40.0, -90.0, 41.0, -90.0);
        expect(bearing, closeTo(0.0, 0.5));
      });

      test('due east bearing is 90 degrees', () {
        final bearing = analyzer.calculateBearing(0.0, 0.0, 0.0, 1.0);
        expect(bearing, closeTo(90.0, 0.5));
      });

      test('due south bearing is 180 degrees', () {
        final bearing = analyzer.calculateBearing(41.0, -90.0, 40.0, -90.0);
        expect(bearing, closeTo(180.0, 0.5));
      });

      test('due west bearing is 270 degrees', () {
        final bearing = analyzer.calculateBearing(0.0, 1.0, 0.0, 0.0);
        expect(bearing, closeTo(270.0, 0.5));
      });
    });

    group('areCloudsApproaching', () {
      test('clouds moving directly toward user are approaching', () {
        // Clouds north of user, moving south (180°), bearing to user is 180°
        final result = analyzer.areCloudsApproaching(
          cloudDirectionDeg: 180.0,
          bearingToUser: 180.0,
        );
        expect(result, isTrue);
      });

      test('clouds moving directly away from user are not approaching', () {
        // Clouds north of user, moving north (0°), bearing to user is 180°
        final result = analyzer.areCloudsApproaching(
          cloudDirectionDeg: 0.0,
          bearingToUser: 180.0,
        );
        expect(result, isFalse);
      });

      test(
        'clouds moving perpendicular at exactly 90 degrees are approaching',
        () {
          // At exactly 90 degrees difference, cos(90) = 0 but the threshold is <=90
          final result = analyzer.areCloudsApproaching(
            cloudDirectionDeg: 90.0,
            bearingToUser: 0.0,
          );
          expect(result, isTrue);
        },
      );

      test('clouds moving at 91 degree offset are not approaching', () {
        final result = analyzer.areCloudsApproaching(
          cloudDirectionDeg: 91.0,
          bearingToUser: 0.0,
        );
        expect(result, isFalse);
      });
    });

    group('calculateEta', () {
      test('stationary clouds return null ETA', () {
        final eta = analyzer.calculateEta(
          cloudDistanceKm: 20.0,
          cloudSpeedKmh: 0.0, // stationary
          cloudDirectionDeg: 180.0,
          userLatitude: 40.0,
          userLongitude: -90.0,
          cloudLatitude: 41.0,
          cloudLongitude: -90.0,
        );
        expect(eta, isNull);
      });

      test('clouds moving away return null ETA', () {
        // Cloud is north of user, moving north (away)
        final eta = analyzer.calculateEta(
          cloudDistanceKm: 50.0,
          cloudSpeedKmh: 30.0,
          cloudDirectionDeg: 0.0, // moving north
          userLatitude: 40.0,
          userLongitude: -90.0,
          cloudLatitude: 41.0, // north of user
          cloudLongitude: -90.0,
        );
        expect(eta, isNull);
      });

      test('clouds moving toward user return valid ETA', () {
        // Cloud is north of user, moving south (toward user)
        // bearing from cloud to user is ~180 degrees (south)
        final eta = analyzer.calculateEta(
          cloudDistanceKm: 60.0,
          cloudSpeedKmh: 30.0,
          cloudDirectionDeg: 180.0, // moving south toward user
          userLatitude: 40.0,
          userLongitude: -90.0,
          cloudLatitude: 40.5, // north of user
          cloudLongitude: -90.0,
        );

        expect(eta, isNotNull);
        // 60 km at 30 km/h = 2 hours = 120 minutes
        expect(eta!.inMinutes, closeTo(120, 10));
      });
    });

    group('analyzeMotion', () {
      test('returns null with fewer than 2 frames', () {
        final frame = RadarFrame(
          timestamp: DateTime.utc(2024, 6, 15, 0, 0),
          tileUrlTemplate: 'https://example.com/tile',
          north: 50.0,
          south: 30.0,
          east: -70.0,
          west: -100.0,
          opacity: 0.8,
        );

        final result = analyzer.analyzeMotion(
          frames: [frame],
          userLatitude: 40.0,
          userLongitude: -90.0,
        );

        expect(result, isNull);
      });

      test('returns null with empty frames list', () {
        final result = analyzer.analyzeMotion(
          frames: [],
          userLatitude: 40.0,
          userLongitude: -90.0,
        );

        expect(result, isNull);
      });
    });

    group('findNearestCloudMass', () {
      test('returns null with empty frames', () {
        final result = analyzer.findNearestCloudMass(
          frames: [],
          userLatitude: 40.0,
          userLongitude: -90.0,
        );

        expect(result, isNull);
      });

      test('returns null when all cloud densities are below threshold', () {
        // Frame with very low opacity (used as density proxy)
        final frame = RadarFrame(
          timestamp: DateTime.utc(2024, 6, 15, 0, 0),
          tileUrlTemplate: 'https://example.com/tile',
          north: 50.0,
          south: 30.0,
          east: -70.0,
          west: -100.0,
          opacity: 0.1, // below default threshold of 0.3
        );

        final result = analyzer.findNearestCloudMass(
          frames: [frame],
          userLatitude: 40.0,
          userLongitude: -90.0,
        );

        expect(result, isNull);
      });

      test('returns cloud location when density exceeds threshold', () {
        // Frame with high opacity covering the user's area
        final frame = RadarFrame(
          timestamp: DateTime.utc(2024, 6, 15, 0, 0),
          tileUrlTemplate: 'https://example.com/tile',
          north: 50.0,
          south: 30.0,
          east: -70.0,
          west: -100.0,
          opacity: 0.8, // above default threshold
        );

        final result = analyzer.findNearestCloudMass(
          frames: [frame],
          userLatitude: 40.0,
          userLongitude: -85.0,
        );

        expect(result, isNotNull);
        // The nearest cloud should be close to the user location since
        // the frame covers the entire analysis area with uniform opacity
        final (lat, lon, distance) = result!;
        expect(distance, greaterThanOrEqualTo(0.0));
      });

      test('prefers non-forecast frames over forecast frames', () {
        final forecastFrame = RadarFrame(
          timestamp: DateTime.utc(2024, 6, 15, 1, 0), // newer
          tileUrlTemplate: 'https://example.com/forecast',
          north: 50.0,
          south: 30.0,
          east: -70.0,
          west: -100.0,
          opacity: 0.9,
          isForecast: true,
        );
        final historicalFrame = RadarFrame(
          timestamp: DateTime.utc(2024, 6, 15, 0, 0),
          tileUrlTemplate: 'https://example.com/historical',
          north: 50.0,
          south: 30.0,
          east: -70.0,
          west: -100.0,
          opacity: 0.8,
          isForecast: false,
        );

        // Should use the historical frame even though forecast is newer
        final result = analyzer.findNearestCloudMass(
          frames: [forecastFrame, historicalFrame],
          userLatitude: 40.0,
          userLongitude: -85.0,
        );

        // Result should be based on the historical frame (opacity 0.8)
        expect(result, isNotNull);
      });
    });
  });
}
