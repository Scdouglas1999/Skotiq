import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/weather/sky_star_evidence.dart';
import 'package:skotiq_core/src/models/weather/weather_alert.dart';
import 'package:skotiq_core/src/models/weather/weather_safety_state.dart';

void main() {
  test('a host verdict reads back as the same verdict', () {
    final state = WeatherSafetyState(
      status: WeatherSafetyStatus.unsafe,
      actions: WeatherSafetyActions(
        shouldPause: true,
        shouldPark: true,
        reason: 'Rain sensor wet',
        resumeCheckTime: DateTime.utc(2026, 11, 22, 4),
      ),
      currentAlertLevel: AlertLevel.values.last,
      dataSource: SafetyDataSource.values.first,
      hardwareWeatherSafe: false,
      hardwareWeatherReading: SafetySourceReading.values.last,
      failModeWarning: 'Forecast only',
      lastEvaluation: DateTime.utc(2026, 11, 22, 3, 30),
      autoParkArmed: true,
      decisionSource: WeatherDecisionSource.values.last,
      forecastUnsafe: true,
      starEvidence: SkyStarEvidence(
        latestStars: 12,
        typicalStars: 400,
        latestAt: DateTime.utc(2026, 11, 22, 3, 29),
        clear: false,
      ),
      snoozeReason: 'clear here',
    );

    final wire = jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>;
    final back = WeatherSafetyState.fromJson(wire);

    expect(back.toJson(), state.toJson());
    expect(wire['isSafe'], isFalse);
    expect(wire['advisoryOnly'], state.advisoryOnly);
  });

  test('a verdict missing a field is refused', () {
    final wire = WeatherSafetyState.initial().toJson()..remove('safetyStatus');
    expect(() => WeatherSafetyState.fromJson(wire), throwsA(anything));
  });
}
