// Before the first radar fetch lands, the Weather card's footer read
// "Updated 20667 days ago" — 20667 days before the audit date is 1970-01-01,
// i.e. weatherStatusProvider handed the card
// DateTime.fromMillisecondsSinceEpoch(0) rather than null, so the card's
// existing `lastUpdate != null` guard could never fire. With no network the
// state is not transient: it persists for the whole session.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/weather/weather_status_card.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pumpCard(WidgetTester tester, {DateTime? lastUpdate}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: WeatherStatusCard(lastUpdate: lastUpdate),
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
}
