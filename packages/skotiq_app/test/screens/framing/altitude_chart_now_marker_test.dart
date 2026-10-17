// The "Now" marker on the altitude chart must never point somewhere that isn't
// now.
//
// The chart plots one night (sunset-1h → sunrise+1h) and drew the red dashed
// "Now" line at `nowX.clamp(0, totalMinutes)`. During the whole daytime — which
// is exactly when people plan — `nowX` is hours negative, so the line was pinned
// to the chart's LEFT EDGE and read as a confident claim about the target's
// current altitude. On the observed M14 card the header said "Alt: -46.2°"
// (below the horizon) while the "Now" line sat where the curve reads ~+32°.
//
// Second defect in the same window maths: `calculateTwilightTimes(date:)`
// returns a sunset-tonight → sunrise-tomorrow window, so anchoring on the
// calendar date described the NEXT night once past midnight — i.e. during real
// imaging hours the chart plotted a night that had not started and "now" fell
// outside it.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/altitude_chart.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show AppSettingsNotifier, AppSettingsState, appSettingsProvider;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _latitude = 40.0;
const _longitude = -75.0;

class _SiteSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: _latitude, longitude: _longitude);
}

/// The window the chart plots for [date], derived through the same public
/// astronomy the widget uses so the test is timezone-independent.
({DateTime start, DateTime end}) windowFor(DateTime date) {
  final twilight = AstronomyCalculations.calculateTwilightTimes(
    date: date,
    latitudeDeg: _latitude,
    longitudeDeg: _longitude,
  );
  return (
    start: twilight.sunset!.subtract(const Duration(hours: 1)),
    end: twilight.sunrise!.add(const Duration(hours: 1)),
  );
}

Future<void> pumpChart(WidgetTester tester, DateTime now) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsProvider.overrideWith(_SiteSettingsNotifier.new),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: AltitudeChart(
              raHours: 16.45,
              decDegrees: -3.25,
              targetName: 'M14',
              nowOverride: () => now,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

List<VerticalLine> nowMarkers(WidgetTester tester) {
  final chart = tester.widget<LineChart>(find.byType(LineChart));
  return chart.data.extraLinesData.verticalLines
      .where((line) => line.label.labelResolver(line) == 'Now')
      .toList();
}

void main() {
  testWidgets('midday: no "Now" marker is drawn inside tonight\'s window', (
    tester,
  ) async {
    final probe = DateTime(2026, 7, 29, 12, 30);
    final window = windowFor(probe);
    // Sanity: the probe really is outside the plotted window.
    expect(probe.isBefore(window.start), isTrue);

    await pumpChart(tester, probe);

    expect(
      nowMarkers(tester),
      isEmpty,
      reason: 'Clamping "now" to the chart edge asserts an altitude the target '
          'will not have for hours, contradicting the Alt chip above it.',
    );
  });

  testWidgets('mid-night: the "Now" marker is drawn at the real position', (
    tester,
  ) async {
    final probe = DateTime(2026, 7, 29, 12, 30);
    final window = windowFor(probe);
    final midNight = window.start.add(
      Duration(minutes: window.end.difference(window.start).inMinutes ~/ 2),
    );

    await pumpChart(tester, midNight);

    final markers = nowMarkers(tester);
    expect(markers, hasLength(1));

    final chart = tester.widget<LineChart>(find.byType(LineChart));
    final expectedX = midNight.difference(window.start).inMinutes.toDouble();
    expect(markers.single.x, closeTo(expectedX, 1));
    // Inside the plotted range, not pinned to an edge.
    expect(markers.single.x, greaterThan(chart.data.minX));
    expect(markers.single.x, lessThan(chart.data.maxX));
  });

  testWidgets('after midnight the chart plots the night in progress', (
    tester,
  ) async {
    // 01:30 belongs to the night that started the PREVIOUS evening.
    final probe = DateTime(2026, 7, 30, 1, 30);
    final runningNight = windowFor(probe.subtract(const Duration(days: 1)));
    expect(probe.isAfter(runningNight.start), isTrue);
    expect(probe.isBefore(runningNight.end), isTrue);

    await pumpChart(tester, probe);

    final markers = nowMarkers(tester);
    expect(
      markers,
      hasLength(1),
      reason: 'At 01:30 the user is imaging; anchoring the window on the '
          'calendar date plotted tomorrow night and left "now" outside it.',
    );
    final expectedX = probe.difference(runningNight.start).inMinutes.toDouble();
    expect(markers.single.x, closeTo(expectedX, 1));
  });

  testWidgets('the culmination chip is labelled as the transit altitude', (
    tester,
  ) async {
    await pumpChart(tester, DateTime(2026, 7, 29, 12, 30));

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? '')
        .toList();
    // "Max Alt" read as the same quantity as the planner card's "Peak" chip,
    // which is the peak while DARK — two different correct numbers under one
    // name (NGC6015: Peak 62.6 vs Max Alt 67.7).
    expect(texts, contains('Transit alt: '));
    expect(texts.where((t) => t.contains('Max Alt')), isEmpty);
  });
}
