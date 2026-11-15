// Weather notices come from the weather-safety verdict, once per episode.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

WeatherSafetyState _state({
  WeatherSafetyStatus status = WeatherSafetyStatus.safe,
  String? reason,
  AlertLevel clouds = AlertLevel.clear,
  WeatherDecisionSource source = WeatherDecisionSource.none,
  bool monitored = true,
  bool evaluated = true,
}) => WeatherSafetyState.initial().copyWith(
  status: status,
  actions: WeatherSafetyActions(shouldPause: false, reason: reason),
  currentAlertLevel: clouds,
  decisionSource: source,
  monitoringEnabled: monitored,
  lastEvaluation: evaluated ? DateTime.utc(2026, 11, 15, 3) : null,
);

void main() {
  test('unsafe weather is told once, and once when it is safe again', () {
    final tracker = WeatherNoticeTracker();
    final unsafe = _state(
      status: WeatherSafetyStatus.unsafe,
      reason: 'Safety monitor reports unsafe conditions',
      source: WeatherDecisionSource.safetyMonitor,
    );
    final told = [
      for (final state in [
        _state(),
        unsafe,
        unsafe,
        unsafe,
        _state(),
        _state(),
      ])
        ...tracker.next(state),
    ];

    expect(told.map((n) => n.$1), [
      NotificationCategory.weatherUnsafe,
      NotificationCategory.weatherSafeAgain,
    ]);
    expect(
      told.first.$2[kWeatherReasonContextKey],
      'Safety monitor reports unsafe conditions',
    );
  });

  test('clouds coming and clearing are told once each', () {
    final tracker = WeatherNoticeTracker();
    final told = [
      for (final level in [
        AlertLevel.clear,
        AlertLevel.watch,
        AlertLevel.warning,
        AlertLevel.critical,
        AlertLevel.warning,
        AlertLevel.watch,
        AlertLevel.clear,
        AlertLevel.clear,
      ])
        ...tracker.next(_state(clouds: level)),
    ];

    expect(told.map((n) => n.$1), [
      NotificationCategory.cloudArriving,
      NotificationCategory.cloudOpening,
    ]);
  });

  test('dawn, an unmonitored or unevaluated verdict tell nothing', () {
    final tracker = WeatherNoticeTracker();
    expect(
      [
        _state(
          status: WeatherSafetyStatus.unsafe,
          source: WeatherDecisionSource.dawn,
        ),
        _state(status: WeatherSafetyStatus.unsafe, monitored: false),
        _state(status: WeatherSafetyStatus.unsafe, evaluated: false),
      ].expand(tracker.next),
      isEmpty,
    );
  });
}
