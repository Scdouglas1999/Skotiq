import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:skotiq_core/src/models/weather/weather_models.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/providers/weather_providers.dart';
import 'package:skotiq_core/src/services/weather/cloud_motion_analyzer.dart';
import 'package:skotiq_core/src/services/weather/weather_radar_service.dart';
import '../harness/in_memory_database.dart';

/// Analyzer that returns a programmed [CloudMotionResult] and records the
/// frames it was handed, so the test can assert wiring without recomputing
/// real optical flow (the analyzer has its own dedicated tests).
class _FakeAnalyzer extends CloudMotionAnalyzer {
  _FakeAnalyzer(this._result);
  final CloudMotionResult _result;
  List<RadarFrame>? lastFrames;

  @override
  CloudMotionResult analyzeMotionDetailed({
    required List<RadarFrame> frames,
    required double userLatitude,
    required double userLongitude,
    double analysisRadiusKm = 100.0,
  }) {
    lastFrames = frames;
    return _result;
  }
}

/// Radar service returning programmed cached frames without any network I/O.
class _FakeRadarService extends WeatherRadarService {
  _FakeRadarService(super.ref, this._frames);
  final List<RadarFrame>? _frames;

  @override
  List<RadarFrame>? getCachedFrames() => _frames;
}

RadarFrame _frame(DateTime t) => RadarFrame(
  timestamp: t,
  tileUrlTemplate: 'https://example.test/{z}/{x}/{y}.png',
  north: 41,
  south: 39,
  east: -73,
  west: -75,
  opacity: 0.6,
);

void main() {
  group('analyzeCloudMotionDetailedProvider', () {
    test(
      'returns insufficientFrames when observer location is unset (0,0)',
      () async {
        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            appObserverLocationProvider.overrideWithValue(
              const LocationSettings(),
            ),
            cloudMotionAnalyzerProvider.overrideWithValue(
              _FakeAnalyzer(
                const CloudMotionResult.unavailable(
                  CloudMotionUnavailableReason.noSpatialData,
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(
          analyzeCloudMotionDetailedProvider.future,
        );

        // Location unset short-circuits BEFORE the analyzer runs — so the result
        // is insufficientFrames, not the analyzer's noSpatialData.
        expect(result.isAvailable, isFalse);
        expect(
          result.unavailableReason,
          CloudMotionUnavailableReason.insufficientFrames,
        );
      },
    );

    test(
      'returns insufficientFrames when no cached radar frames exist',
      () async {
        late _FakeRadarService radar;
        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            appObserverLocationProvider.overrideWithValue(
              const LocationSettings(latitude: 40, longitude: -74),
            ),
            weatherRadarServiceProvider.overrideWith((ref) {
              radar = _FakeRadarService(ref, null);
              return radar;
            }),
            cloudMotionAnalyzerProvider.overrideWithValue(
              _FakeAnalyzer(
                const CloudMotionResult.unavailable(
                  CloudMotionUnavailableReason.noSpatialData,
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(
          analyzeCloudMotionDetailedProvider.future,
        );

        expect(
          result.unavailableReason,
          CloudMotionUnavailableReason.insufficientFrames,
        );
      },
    );

    test(
      'passes cached frames to the analyzer and surfaces its reason',
      () async {
        final analyzer = _FakeAnalyzer(
          const CloudMotionResult.unavailable(
            CloudMotionUnavailableReason.noSpatialData,
          ),
        );
        final frames = [
          _frame(DateTime.utc(2026, 1, 1, 0, 0, 0)),
          _frame(DateTime.utc(2026, 1, 1, 0, 10, 0)),
        ];
        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            appObserverLocationProvider.overrideWithValue(
              const LocationSettings(latitude: 40, longitude: -74),
            ),
            weatherRadarServiceProvider.overrideWith(
              (ref) => _FakeRadarService(ref, frames),
            ),
            cloudMotionAnalyzerProvider.overrideWithValue(analyzer),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(
          analyzeCloudMotionDetailedProvider.future,
        );

        expect(analyzer.lastFrames, same(frames));
        expect(
          result.unavailableReason,
          CloudMotionUnavailableReason.noSpatialData,
        );
      },
    );

    test(
      'thin analyzeCloudMotionProvider wrapper returns motion from detailed',
      () async {
        final motion = CloudMotion(
          speedKmh: 25,
          directionDegrees: 180,
          distanceKm: 50,
          etaToLocation: const Duration(minutes: 90),
          calculatedAt: DateTime.utc(2026, 1, 1),
        );
        final frames = [
          _frame(DateTime.utc(2026, 1, 1, 0, 0, 0)),
          _frame(DateTime.utc(2026, 1, 1, 0, 10, 0)),
        ];
        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            appObserverLocationProvider.overrideWithValue(
              const LocationSettings(latitude: 40, longitude: -74),
            ),
            weatherRadarServiceProvider.overrideWith(
              (ref) => _FakeRadarService(ref, frames),
            ),
            cloudMotionAnalyzerProvider.overrideWithValue(
              _FakeAnalyzer(CloudMotionResult.available(motion)),
            ),
          ],
        );
        addTearDown(container.dispose);

        final viaThin = await container.read(analyzeCloudMotionProvider.future);
        expect(viaThin, isNotNull);
        expect(viaThin!.etaToLocation, const Duration(minutes: 90));
      },
    );
  });
}
