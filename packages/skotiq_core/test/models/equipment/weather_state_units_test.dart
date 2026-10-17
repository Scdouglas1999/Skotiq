import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('WeatherState wind units', () {
    test('converts native metres per second to kilometres per hour', () {
      const state = WeatherState(windSpeed: 10);

      expect(state.windSpeedKph, closeTo(36, 1e-9));
    });

    test('preserves unavailable wind telemetry as null', () {
      const state = WeatherState();

      expect(state.windSpeedKph, isNull);
    });
  });
}
