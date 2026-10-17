// The Weather radar timeline must OPEN on the live edge of the loop.
//
// Opening on frame 1 of N shows the OLDEST tile in the loop, up to two hours
// behind the NOW marker the scrubber itself paints at the far right — so an
// operator glancing at the map before deciding whether to keep the roof open is
// looking at cloud that has already arrived or already gone.
//
// The screen runs a 5-minute refresh timer and a fade animation, so pump with
// settle: false and fixed steps rather than pumpAndSettle.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/weather/weather_screen.dart';
import 'package:skotiq_app/widgets/weather/dashboard_weather_widget.dart';
import 'package:skotiq_app/widgets/weather/radar_timeline_scrubber.dart';
import 'package:skotiq_app/widgets/weather/weather_radar_map.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

RadarFrame _frame(DateTime timestamp, {bool isForecast = false}) => RadarFrame(
      timestamp: timestamp,
      tileUrlTemplate:
          'https://example.invalid/${timestamp.millisecondsSinceEpoch}'
          '/{z}/{x}/{y}.png',
      north: 36,
      south: 34,
      east: -117,
      west: -119,
      isForecast: isForecast,
    );

/// A RainViewer-shaped loop: [past] observed frames every 10 minutes ending at
/// `now`, then [forecast] nowcast frames into the future.
List<RadarFrame> _loop({required int past, int forecast = 0}) {
  final now = DateTime.now();
  return [
    for (var i = past - 1; i >= 0; i--)
      _frame(now.subtract(Duration(minutes: 10 * i))),
    for (var i = 1; i <= forecast; i++)
      _frame(now.add(Duration(minutes: 10 * i)), isForecast: true),
  ];
}

/// A NOAA NEXRAD-shaped loop. [NoaaRadarProvider] sorts its timestamps
/// reverse-chronologically before decoding
/// (noaa_radar_provider.dart:348 — `timestamps.sort((a, b) => b.compareTo(a))`)
/// and nothing between the provider and the widget re-sorts, so its NEWEST
/// frame is `frames.first`.
List<RadarFrame> _reverseChronologicalLoop({required int past}) {
  final now = DateTime.now();
  return [
    for (var i = 0; i < past; i++)
      _frame(now.subtract(Duration(minutes: 5 * i)))
  ];
}

/// A settled observing site, so the screen renders the radar rather than its
/// "set your location" placeholder.
class _SiteSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 35, longitude: -118);
}

Future<void> _pumpWeather(WidgetTester tester, List<RadarFrame> frames) async {
  await pumpAppScreen(
    tester,
    const WeatherScreen(),
    size: const Size(1280, 800),
    settle: false,
    extraOverrides: [
      // A DisconnectedBackend makes WeatherSafetyNotifier's constructor take
      // its passive branch: no alert subscription and no periodic evaluation,
      // whose timers outlive the widget tree and trip the test invariant.
      backendProvider.overrideWith(
        (ref) => TestBackendNotifier(ref, DisconnectedBackend()),
      ),
      appSettingsProvider.overrideWith(_SiteSettingsNotifier.new),
      weatherStatusProvider.overrideWithValue(
        WeatherStatus(radarFrames: frames),
      ),
    ],
  );
  // Drain the fade-in and the initial post-frame fetch without waiting on the
  // screen's own 5-minute refresh timer.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the timeline opens on the newest frame, not the oldest',
      (tester) async {
    await _pumpWeather(tester, _loop(past: 13));

    expect(find.text('Frame 13 of 13'), findsWidgets);
    expect(find.text('Frame 1 of 13'), findsNothing);
  });

  testWidgets('a nowcast tail does not drag the opening frame into the future',
      (tester) async {
    // 10 observations + 3 nowcast frames: the live edge is observation 10, not
    // the +30 min prediction at the end of the list.
    await _pumpWeather(tester, _loop(past: 10, forecast: 3));

    expect(find.text('Frame 10 of 13'), findsWidgets);
  });

  testWidgets('a reverse-chronological NOAA loop still opens on the newest',
      (tester) async {
    // NOAA hands back newest-first. Choosing by list position instead of by
    // timestamp opened this loop on frame 13 — the two-hour-old one.
    await _pumpWeather(tester, _reverseChronologicalLoop(past: 13));

    expect(find.text('Frame 1 of 13'), findsWidgets);
    expect(find.text('Frame 13 of 13'), findsNothing);
  });

  group('latestObservedRadarFrameIndex', () {
    test('picks the newest observation', () {
      expect(latestObservedRadarFrameIndex(_loop(past: 5)), 4);
    });

    test('skips a forecast tail', () {
      expect(latestObservedRadarFrameIndex(_loop(past: 5, forecast: 4)), 4);
    });

    test('picks by timestamp, not by list position', () {
      // The NOAA order. The newest frame is at index 0.
      expect(
          latestObservedRadarFrameIndex(_reverseChronologicalLoop(past: 6)), 0);
    });

    test('falls back to the nearest frame when everything is a forecast', () {
      expect(latestObservedRadarFrameIndex(_loop(past: 0, forecast: 4)), 0);
    });

    test('an empty loop has no frame to point at', () {
      expect(latestObservedRadarFrameIndex(const []), 0);
    });
  });

  group('dashboard radar preview', () {
    testWidgets('the thumbnail shows the live edge, not the oldest frame',
        (tester) async {
      final frames = _loop(past: 6);

      await pumpAppScreen(
        tester,
        const SizedBox(width: 460, child: DashboardWeatherWidget()),
        size: const Size(1280, 800),
        settle: false,
        extraOverrides: [
          backendProvider.overrideWith(
            (ref) => TestBackendNotifier(ref, DisconnectedBackend()),
          ),
          appSettingsProvider.overrideWith(_SiteSettingsNotifier.new),
          weatherStatusProvider.overrideWithValue(
            WeatherStatus(radarFrames: frames),
          ),
        ],
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      final map = tester.widget<WeatherRadarMap>(find.byType(WeatherRadarMap));
      expect(
        map.currentFrame?.timestamp,
        frames.last.timestamp,
        reason: 'frames arrive oldest -> newest; .first is the STALEST frame',
      );
    });
  });
}
