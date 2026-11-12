import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  group('WeatherState wind units', () {
    test('converts native meters per second to kilometers per hour', () {
      const state = WeatherState(windSpeed: 10);

      expect(state.windSpeedKph, closeTo(36, 1e-9));
    });

    test('preserves unavailable wind telemetry as null', () {
      const state = WeatherState();

      expect(state.windSpeedKph, isNull);
    });
  });
}
