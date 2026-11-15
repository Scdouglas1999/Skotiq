// A site is set but no weather service answered: the screen says so once, in
// place of the map, instead of an empty basemap under a HUD of dashes and a
// banner repeating the same failure.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/weather/weather_screen.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';

import '../../harness/harness.dart';

class _SiteSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 35, longitude: -118);
}

RadarFrame _frame() => RadarFrame(
      timestamp: DateTime.now(),
      tileUrlTemplate: 'https://example.invalid/{z}/{x}/{y}.png',
      north: 36,
      south: 34,
      east: -117,
      west: -119,
    );

Future<void> _pumpWeather(
  WidgetTester tester, {
  required List<RadarFrame> frames,
  double? cloudPercent,
  String? fetchError,
}) async {
  await pumpAppScreen(
    tester,
    const WeatherScreen(),
    size: const Size(1280, 800),
    settle: false,
    extraOverrides: [
      backendProvider.overrideWith(
        (ref) => TestBackendNotifier(ref, DisconnectedBackend()),
      ),
      appSettingsProvider.overrideWith(_SiteSettingsNotifier.new),
      cloudCoverForecastProvider.overrideWith(
        (ref) async => cloudPercent == null
            ? null
            : CloudCoverForecast(
                percent: cloudPercent,
                source: 'Open-Meteo',
                validAt: DateTime.utc(2026, 11, 14, 2, 45),
              ),
      ),
      weatherStatusProvider.overrideWithValue(
        WeatherStatus(radarFrames: frames, errorMessage: fetchError),
      ),
    ],
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('no radar and no forecast is one empty state, not a banner too',
      (tester) async {
    await _pumpWeather(
      tester,
      frames: const [],
      fetchError: 'SocketException: no route to host',
    );

    expect(find.text('No weather source'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('Weather data unavailable'), findsNothing,
        reason: 'the empty state already says the data did not come');
    expect(find.text('FORECAST CLOUD COVER'), findsNothing);
  });

  testWidgets('a forecast without radar still shows the map and the figure',
      (tester) async {
    await _pumpWeather(tester, frames: const [], cloudPercent: 40);

    expect(find.text('No weather source'), findsNothing);
    expect(find.text('FORECAST CLOUD COVER'), findsOneWidget);
  });

  testWidgets('an unknown cloud cover is left out of the headline',
      (tester) async {
    await _pumpWeather(tester, frames: [_frame()]);

    expect(find.text('No weather source'), findsNothing);
    expect(find.text('FORECAST CLOUD COVER'), findsNothing,
        reason: 'a dash in the headline slot reads as a value');
  });
}
