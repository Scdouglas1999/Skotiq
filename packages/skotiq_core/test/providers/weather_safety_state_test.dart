import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/weather/weather_models.dart';
import 'package:skotiq_core/src/providers/weather_safety_provider.dart';

void main() {
  test('weather safety starts unavailable and fail-closed', () {
    final state = WeatherSafetyState.initial();

    expect(state.status, WeatherSafetyStatus.unsafe);
    expect(state.dataSource, SafetyDataSource.unavailable);
    expect(state.isSafe, isFalse);
  });

  test('snoozing alerts never certifies conditions as safe', () {
    const state = WeatherSafetyState(
      status: WeatherSafetyStatus.snoozed,
      actions: WeatherSafetyActions.safe,
      currentAlertLevel: AlertLevel.critical,
    );

    expect(state.isSafe, isFalse);
  });
}
