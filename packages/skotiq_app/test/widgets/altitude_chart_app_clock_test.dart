// The chart's "now" (the Alt chip, the Now marker, the plotted night) is the
// app clock's instant, so a replay or a fixed test clock moves it with the rest
// of the app.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/altitude_chart.dart';
import 'package:skotiq_core/providers.dart'
    show AppSettingsNotifier, Clock, appSettingsProvider, clockProvider;
import 'package:skotiq_core/settings.dart' show AppSettingsState;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _SiteSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 40, longitude: -75);
}

class _FixedClock implements Clock {
  const _FixedClock(this._at);
  final DateTime _at;

  @override
  DateTime now() => _at;

  @override
  DateTime nowUtc() => _at.toUtc();

  @override
  Duration get utcOffset => _at.timeZoneOffset;

  @override
  DateTime fromUtc(DateTime utc) => utc.toLocal();
}

Future<String?> _altitudeAt(
  WidgetTester tester, {
  Clock? clock,
  DateTime Function()? nowOverride,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inMemoryDatabaseOverride(),
        appSettingsProvider.overrideWith(_SiteSettingsNotifier.new),
        if (clock != null) clockProvider.overrideWithValue(clock),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: AltitudeChart(
              raHours: 16.45,
              decDegrees: -3.25,
              targetName: 'M14',
              nowOverride: nowOverride,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  final texts = [
    for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? '',
  ];
  final label = texts.indexOf('Alt: ');
  final alt = label < 0 ? null : texts[label + 1];
  await tester.pumpWidget(const SizedBox.shrink());
  return alt;
}

void main() {
  testWidgets('the chart reads now from the app clock', (tester) async {
    final at = DateTime(2026, 7, 30, 1, 30);

    final expected = await _altitudeAt(tester, nowOverride: () => at);
    final fromClock = await _altitudeAt(tester, clock: _FixedClock(at));

    expect(expected, isNotNull);
    expect(fromClock, expected);
  });
}
