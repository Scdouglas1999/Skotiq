// Before the first radar fetch lands, the Weather card's footer read
// "Updated 20667 days ago" — 20667 days before the audit date is 1970-01-01,
// i.e. weatherStatusProvider handed the card
// DateTime.fromMillisecondsSinceEpoch(0) rather than null, so the card's
// existing `lastUpdate != null` guard could never fire. With no network the
// state is not transient: it persists for the whole session.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/weather/widgets/weather_status_card.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pumpCard(
  WidgetTester tester, {
  DateTime? lastUpdate,
  WeatherAlert? alert,
  bool fetchFailed = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: WeatherStatusCard(
              lastUpdate: lastUpdate,
              alert: alert,
              fetchFailed: fetchFailed,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('no fetch yet -> says it is waiting, never quotes an age',
      (tester) async {
    await _pumpCard(tester);

    expect(find.text('Waiting for weather data'), findsOneWidget);
    expect(find.textContaining('days ago'), findsNothing);
    expect(find.textContaining('Updated'), findsNothing);
  });

  testWidgets('a real fetch time is reported as an age', (tester) async {
    await _pumpCard(
      tester,
      lastUpdate: DateTime.now().subtract(const Duration(minutes: 3)),
    );

    expect(find.text('Updated 3 min ago'), findsOneWidget);
    expect(find.text('Waiting for weather data'), findsNothing);
  });

  // qa-surfaces S37: "Waiting for weather data" sat under a populated 85%
  // cloud reading.
  testWidgets('a reading on screen is not "waiting"', (tester) async {
    await _pumpCard(
      tester,
      alert: WeatherAlert(
        level: AlertLevel.watch,
        message: 'Clouds nearby',
        cloudDensityPercent: 85,
        distanceKm: 20,
        generatedAt: DateTime.now(),
      ),
    );

    expect(find.text('Waiting for weather data'), findsNothing);
  });

  // ux walk-2 F37: offline, the card said a green "Clear" and "Updated 3 sec
  // ago" under a "Weather data unavailable" banner.
  testWidgets('no data and a failed fetch never claims a condition',
      (tester) async {
    await _pumpCard(tester, fetchFailed: true);

    expect(find.text('Clear'), findsNothing);
    expect(find.text('Unknown'), findsOneWidget);
    expect(find.text('No weather data received'), findsOneWidget);
    expect(find.textContaining('Updated'), findsNothing);
  });

  testWidgets('before the first fetch the card is checking, not clear',
      (tester) async {
    await _pumpCard(tester);

    expect(find.text('Clear'), findsNothing);
    expect(find.text('Checking'), findsOneWidget);
  });

  testWidgets('a failed refresh keeps the last level and says how old it is',
      (tester) async {
    await _pumpCard(
      tester,
      fetchFailed: true,
      lastUpdate: DateTime.now().subtract(const Duration(minutes: 25)),
      alert: WeatherAlert(
        level: AlertLevel.clear,
        message: 'No clouds nearby',
        cloudDensityPercent: 5,
        distanceKm: 0,
        generatedAt: DateTime.now(),
      ),
    );

    expect(find.text('Clear'), findsOneWidget);
    expect(find.text('Last data 25 min ago'), findsOneWidget);
    expect(find.textContaining('Updated'), findsNothing);
    final label = tester.widget<Text>(find.text('Clear'));
    final colors = SkotiqColors.of(tester.element(find.text('Clear')));
    expect(label.style?.color, colors.textMuted);
  });
}
