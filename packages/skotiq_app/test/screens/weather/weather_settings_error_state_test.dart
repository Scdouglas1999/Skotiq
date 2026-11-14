import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/weather/weather_screen.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _FailingSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() =>
      Future<AppSettingsState>.error(StateError('settings offline'));
}

// lastUpdate stays null: no radar fetch has landed in this scenario.
WeatherStatus _status() => const WeatherStatus(currentLevel: AlertLevel.clear);

WeatherAlert _clearAlert() => WeatherAlert(
      level: AlertLevel.clear,
      message: 'Clear',
      cloudDensityPercent: 0,
      distanceKm: 0,
      generatedAt: DateTime(2026, 7, 13),
    );

Widget _app(ProviderContainer container, Widget child) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('Weather screen distinguishes settings failure from no location',
      (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        appSettingsProvider.overrideWith(_FailingSettingsNotifier.new),
        weatherStatusProvider.overrideWithValue(_status()),
        analyzeCloudMotionProvider.overrideWith((ref) async => null),
        evaluateWeatherConditionsProvider.overrideWith(
          (ref) async => _clearAlert(),
        ),
        cloudCoverPercentageProvider.overrideWith((ref) async => 0),
        radarSourceInfoProvider.overrideWithValue(const RadarSourceInfo()),
        weatherSettingsDataProvider.overrideWith(
          (ref) => Stream.value(WeatherSettings.defaultSettings),
        ),
      ],
    );

    await tester.pumpWidget(_app(container, const WeatherScreen()));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Weather settings unavailable'), findsOneWidget);
    expect(find.text('No observing site'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
}
