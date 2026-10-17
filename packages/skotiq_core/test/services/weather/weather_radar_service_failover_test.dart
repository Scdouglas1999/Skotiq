// Tests for the failover candidate ordering that WeatherRadarService uses.
//
// The service itself reads `databaseProvider` for settings, so driving its full
// fetch path would require faking a Drift database — disproportionate and
// without precedent in this suite. Instead the ordering logic lives as a pure,
// testable method on RadarProviderFactory (`failoverCandidates`); the service
// just calls it and tries each candidate in turn. We unit-test that ordering
// here, and the service's integration is covered by analyze + the existing
// suites.

import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/models/weather/weather_models.dart';
import 'package:skotiq_core/src/services/weather/radar_provider.dart';
import 'package:skotiq_core/src/services/weather/radar_provider_factory.dart';

/// Minimal RadarProvider stub with configurable type and coverage.
class _FakeProvider extends RadarProvider {
  _FakeProvider(this.providerType, {GeoBounds? bounds})
    : coverageBounds = bounds ?? const GeoBounds.global();

  @override
  final RadarProviderType providerType;

  @override
  final GeoBounds coverageBounds;

  @override
  String get name => providerType.name;

  @override
  Future<RadarFetchResult> fetchRadarFrames({
    required double latitude,
    required double longitude,
    double radiusKm = 100.0,
  }) async => RadarFetchResult.error('stub');

  @override
  (Duration, Duration) getAvailableTimeRange() =>
      (Duration.zero, Duration.zero);

  @override
  String buildTileUrl(RadarFrame frame, int z, int x, int y) => '';
}

void main() {
  test('selected provider leads, others follow in priority order', () {
    final factory = RadarProviderFactory();
    final openmeteo = _FakeProvider(RadarProviderType.openmeteo);
    final metno = _FakeProvider(RadarProviderType.metno);
    final rainviewer = _FakeProvider(RadarProviderType.rainviewer);
    factory.registerProvider(openmeteo);
    factory.registerProvider(metno);
    factory.registerProvider(rainviewer);
    addTearDown(factory.dispose);

    final candidates = factory.failoverCandidates(
      latitude: 40.0,
      longitude: -105.0,
      selected: openmeteo,
    );

    // Open-Meteo first (selected), then the rest in autoPriority order:
    // rainviewer before metno.
    expect(candidates.map((p) => p.providerType).toList(), [
      RadarProviderType.openmeteo,
      RadarProviderType.rainviewer,
      RadarProviderType.metno,
    ]);
  });

  test('selected provider is never duplicated', () {
    final factory = RadarProviderFactory();
    final metno = _FakeProvider(RadarProviderType.metno);
    final openmeteo = _FakeProvider(RadarProviderType.openmeteo);
    factory.registerProvider(metno);
    factory.registerProvider(openmeteo);
    addTearDown(factory.dispose);

    final candidates = factory.failoverCandidates(
      latitude: 40.0,
      longitude: -105.0,
      selected: metno,
    );

    expect(candidates.map((p) => p.providerType).toList(), [
      RadarProviderType.metno,
      RadarProviderType.openmeteo,
    ]);
    // metno appears exactly once.
    expect(
      candidates.where((p) => p.providerType == RadarProviderType.metno),
      hasLength(1),
    );
  });

  test('excludes providers that do not cover the location', () {
    final factory = RadarProviderFactory();
    final openmeteo = _FakeProvider(RadarProviderType.openmeteo);
    // NOAA stub only covers CONUS; a non-US point must drop it.
    final noaa = _FakeProvider(
      RadarProviderType.noaa,
      bounds: const GeoBounds.conus(),
    );
    final metno = _FakeProvider(RadarProviderType.metno);
    factory.registerProvider(openmeteo);
    factory.registerProvider(noaa);
    factory.registerProvider(metno);
    addTearDown(factory.dispose);

    // Oslo: outside CONUS.
    final candidates = factory.failoverCandidates(
      latitude: 59.9,
      longitude: 10.7,
      selected: openmeteo,
    );

    expect(
      candidates.map((p) => p.providerType),
      isNot(contains(RadarProviderType.noaa)),
    );
    expect(candidates.map((p) => p.providerType).toList(), [
      RadarProviderType.openmeteo,
      RadarProviderType.metno,
    ]);
  });

  test('metno ranks last in the shared auto priority', () {
    expect(RadarProviderFactory.autoPriority.last, RadarProviderType.metno);
  });
}
