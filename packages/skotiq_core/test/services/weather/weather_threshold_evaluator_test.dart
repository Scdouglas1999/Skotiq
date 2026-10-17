import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/weather/weather_threshold_evaluator.dart';

void main() {
  const evaluator = WeatherThresholdEvaluator();
  const thresholds = WeatherThresholds(
    maxHumidityPercent: 90.0,
    maxWindSpeedKph: 30.0,
    maxCloudCoverPercent: 80.0,
  );

  group('WeatherThresholdEvaluator', () {
    test('all readings within limits => safe', () {
      final result = evaluator.evaluate(
        const WeatherReading(
          humidityPercent: 50.0,
          windSpeedKph: 10.0,
          rainRate: 0.0,
          cloudCoverPercent: 20.0,
        ),
        thresholds,
      );
      expect(result.isSafe, isTrue);
      expect(result.breach, WeatherThresholdBreach.none);
    });

    test('no readings at all => safe (absence is not evidence of danger)', () {
      final result = evaluator.evaluate(const WeatherReading(), thresholds);
      expect(result.isSafe, isTrue);
      expect(result.breach, WeatherThresholdBreach.none);
    });

    test('humidity strictly above limit => unsafe', () {
      final result = evaluator.evaluate(
        const WeatherReading(humidityPercent: 90.1),
        thresholds,
      );
      expect(result.isSafe, isFalse);
      expect(result.breach, WeatherThresholdBreach.humidity);
    });

    test('humidity exactly at limit => safe (strict >)', () {
      final result = evaluator.evaluate(
        const WeatherReading(humidityPercent: 90.0),
        thresholds,
      );
      expect(result.isSafe, isTrue);
    });

    test('wind strictly above limit => unsafe', () {
      final result = evaluator.evaluate(
        const WeatherReading(windSpeedKph: 30.5),
        thresholds,
      );
      expect(result.isSafe, isFalse);
      expect(result.breach, WeatherThresholdBreach.wind);
    });

    test('any positive rain rate => unsafe regardless of other limits', () {
      final result = evaluator.evaluate(
        const WeatherReading(rainRate: 0.01),
        thresholds,
      );
      expect(result.isSafe, isFalse);
      expect(result.breach, WeatherThresholdBreach.rain);
    });

    test('zero rain rate => not a rain breach', () {
      final result = evaluator.evaluate(
        const WeatherReading(rainRate: 0.0),
        thresholds,
      );
      expect(result.isSafe, isTrue);
    });

    test('cloud strictly above limit => unsafe', () {
      final result = evaluator.evaluate(
        const WeatherReading(cloudCoverPercent: 80.1),
        thresholds,
      );
      expect(result.isSafe, isFalse);
      expect(result.breach, WeatherThresholdBreach.cloud);
    });

    test('breach order is humidity -> wind -> rain -> cloud', () {
      // Every metric breaches; the first-in-order (humidity) is reported, which
      // matches the historical inline ordering so reasons are unchanged.
      final result = evaluator.evaluate(
        const WeatherReading(
          humidityPercent: 99.0,
          windSpeedKph: 99.0,
          rainRate: 5.0,
          cloudCoverPercent: 99.0,
        ),
        thresholds,
      );
      expect(result.breach, WeatherThresholdBreach.humidity);

      // Drop humidity: wind is next.
      final windResult = evaluator.evaluate(
        const WeatherReading(
          windSpeedKph: 99.0,
          rainRate: 5.0,
          cloudCoverPercent: 99.0,
        ),
        thresholds,
      );
      expect(windResult.breach, WeatherThresholdBreach.wind);

      // Drop wind: rain is next.
      final rainResult = evaluator.evaluate(
        const WeatherReading(rainRate: 5.0, cloudCoverPercent: 99.0),
        thresholds,
      );
      expect(rainResult.breach, WeatherThresholdBreach.rain);
    });
  });

  /// The humidity ceiling has exactly ONE definition: the operator-configured
  /// `maxHumidityPercent` consumed by this evaluator and folded into the pushed
  /// weather verdict (Rust `WeatherUnsafe`). A second, hardcoded ceiling
  /// anywhere would let the two gates judge the same reading differently.
  group(
    'humidity gate uses the operator-configured ceiling (single source)',
    () {
      test('a 70% operator ceiling makes 80% unsafe', () {
        const strict = WeatherThresholds(
          maxHumidityPercent: 70.0,
          maxWindSpeedKph: 30.0,
          maxCloudCoverPercent: 80.0,
        );
        final result = evaluator.evaluate(
          const WeatherReading(humidityPercent: 80.0),
          strict,
        );
        expect(
          result.isSafe,
          isFalse,
          reason:
              'with a 70% ceiling, 80% humidity is unsafe — the old hardcoded '
              'Rust 85% gate would have wrongly judged this safe.',
        );
        expect(result.breach, WeatherThresholdBreach.humidity);
      });

      test('a 95% operator ceiling keeps 90% safe (looser than old 85)', () {
        const loose = WeatherThresholds(
          maxHumidityPercent: 95.0,
          maxWindSpeedKph: 30.0,
          maxCloudCoverPercent: 80.0,
        );
        final result = evaluator.evaluate(
          const WeatherReading(humidityPercent: 90.0),
          loose,
        );
        expect(
          result.isSafe,
          isTrue,
          reason:
              'with a 95% ceiling, 90% humidity is safe — the old hardcoded '
              'Rust 85% gate would have wrongly aborted here.',
        );
      });
    },
  );
}
