// The altitude curve must describe the same object, at the same instant, as
// the readouts around it: the curve's value at the "Now" marker is the current
// altitude, and its peak is the "Transit alt".
//
// fl_chart animates a LineChart between its old and new data over 150 ms, and
// the first frame of that morph is the OLD curve. When Framing switched from one
// target to M42, a frame painted before the morph finished showed the previous
// object's curve (below the horizon at Now, peaking near 23:00) under M42's
// Alt 54.4 and Transit 09:57. The chart therefore must not animate.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/altitude_chart.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show AppSettingsNotifier, AppSettingsState, appSettingsProvider;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

// The harness profile the defect was seen on: Mauna Kea.
const _latitude = 19.8206;
const _longitude = -155.4681;

class _SiteSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: _latitude, longitude: _longitude);
}

const _m42 = (ra: 5.5878, dec: -5.3897);
// The target framed before M42 in the harness run.
const _previous = (ra: 17.2367, dec: 50.2461);

Widget _host(({double ra, double dec}) target, DateTime now) => ProviderScope(
      overrides: [appSettingsProvider.overrideWith(_SiteSettingsNotifier.new)],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 320,
              child: AltitudeChart(
                raHours: target.ra,
                decDegrees: target.dec,
                compact: true,
                nowOverride: () => now,
              ),
            ),
          ),
        ),
      ),
    );

/// The plotted altitude at chart x [x], linearly interpolated.
double _curveAt(List<FlSpot> spots, double x) {
  for (var i = 1; i < spots.length; i++) {
    if (spots[i].x >= x) {
      final a = spots[i - 1], b = spots[i];
      return a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x);
    }
  }
  return spots.last.y;
}

void main() {
  final now = DateTime.utc(2026, 10, 21, 12, 16).toLocal();

  testWidgets('the chart never morphs from the previous target\'s curve', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_previous, now));
    await tester.pump();

    await tester.pumpWidget(_host(_m42, now));
    // One frame only: whatever the chart paints now is what a screenshot or
    // a glance at this moment sees.
    await tester.pump();

    final chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(chart.duration, Duration.zero);

    final spots = chart.data.lineBarsData.first.spots;
    final nowMarker = chart.data.extraLinesData.verticalLines
        .singleWhere((line) => line.label.labelResolver(line) == 'Now');
    final (altNow, _) = AstronomyCalculations.objectAltAz(
      raDeg: _m42.ra * 15,
      decDeg: _m42.dec,
      dt: now,
      latitudeDeg: _latitude,
      longitudeDeg: _longitude,
    );
    expect(altNow, greaterThan(50), reason: 'M42 is high at this instant');
    expect(_curveAt(spots, nowMarker.x), closeTo(altNow, 1.5));

    final peak = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    expect(find.text('${peak.toStringAsFixed(0)}°'), findsOneWidget,
        reason: 'the curve peak is the Transit alt readout');
  });
}
