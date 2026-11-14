// Axis behaviour of the session charts.
//
// Two defects were visible in the running app and are guarded here:
//   * y-axis boundary labels drew on top of the outermost tick ("2.83" over
//     "2.75"), because the bounds were data +/- 10% while ticks were range/4;
//   * a descending series (what `watchStandaloneImages` returns) produced a
//     negative x axis, which silently removed every x-axis label and drew the
//     night backwards.
// The chart paints its labels on a canvas, so these read the layout and the
// painted label rectangles rather than Text widgets.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/session_chart.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../support/chart_probe.dart';

Future<void> _pump(WidgetTester tester, List<ChartDataPoint> points) async {
  await tester.pumpWidget(MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(
      body: SizedBox(
        width: 640,
        height: 320,
        child: SessionChart(
          title: 'Probe',
          yAxisLabel: 'HFR (px)',
          measurementName: 'half-flux radius',
          dataPoints: points,
          reading: (value) => value.toStringAsFixed(value.abs() >= 100 ? 0 : 2),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

final _chart = find.byType(SkotiqChart);

void main() {
  final start = DateTime(2026, 7, 28, 21, 40);
  // 4.2 h run, the HFR range that used to collide on the axis.
  final ascending = List.generate(
    24,
    (i) => ChartDataPoint(
      timestamp: start.add(Duration(seconds: i * 630)),
      value: 2.26 + (i / 23) * 0.50,
    ),
  );

  testWidgets('no two axis labels overlap', (tester) async {
    await _pump(tester, ascending);
    expectNoOverlappingChartLabels(tester, _chart);
  });

  // A series with no variation gets a window built around its value. Three
  // frames all guiding at 0.70" once gave a bottom of 0.20 against ticks at
  // multiples of 0.25, and "0.20" printed on top of "0.25".
  for (final flatValue in <double>[0.70, 0.60, 15220.0]) {
    testWidgets('a flat $flatValue series draws no overlapping axis labels',
        (tester) async {
      await _pump(
        tester,
        List.generate(
          3,
          (i) => ChartDataPoint(
            timestamp: start.add(Duration(seconds: i * 600)),
            value: flatValue,
          ),
        ),
      );
      expectNoOverlappingChartLabels(tester, _chart);
      final range =
          chartLayoutOf(tester, _chart).valueRange(ChartValueAxis.left)!;
      expect(range.ticks.values.first, range.min);
      expect(range.ticks.values.last, range.max);
    });
  }

  testWidgets(
      'a night is drawn on clock time, forward even for descending input',
      (tester) async {
    await _pump(tester, ascending.reversed.toList());
    final layout = chartLayoutOf(tester, _chart);
    expect(layout.xMin, start.millisecondsSinceEpoch);
    expect(
      layout.xMax,
      start.add(const Duration(seconds: 23 * 630)).millisecondsSinceEpoch,
    );
    final xs = layout.series.first.points.map((p) => p.dx).toList();
    expect(xs, List<double>.of(xs)..sort());
    expect(
      layout.xLabel(
        DateTime(2026, 7, 28, 23).millisecondsSinceEpoch.toDouble(),
      ),
      '23:00',
    );
  });

  testWidgets('a run of a few minutes keeps elapsed time from zero',
      (tester) async {
    await _pump(
      tester,
      List.generate(
        8,
        (i) => ChartDataPoint(
          timestamp: start.add(Duration(seconds: i * 5)),
          value: 2.4,
        ),
      ),
    );
    final layout = chartLayoutOf(tester, _chart);
    expect(layout.xMin, 0);
    expect(layout.xMax, 35);
  });

  testWidgets('ordering does not change what is drawn', (tester) async {
    await _pump(tester, ascending);
    final forward = chartLayoutOf(tester, _chart);
    await _pump(tester, ascending.reversed.toList());
    final reversed = chartLayoutOf(tester, _chart);
    expect(reversed.series.first.points, forward.series.first.points);
    expect(
      reversed.valueRange(ChartValueAxis.left)!.ticks.values,
      forward.valueRange(ChartValueAxis.left)!.ticks.values,
    );
  });

  testWidgets('a constant series still gets a readable axis', (tester) async {
    final flat = List.generate(
      12,
      (i) => ChartDataPoint(
        timestamp: start.add(Duration(seconds: i * 600)),
        value: 20.0,
      ),
    );
    await _pump(tester, flat);
    final range =
        chartLayoutOf(tester, _chart).valueRange(ChartValueAxis.left)!;
    expect(range.ticks.values, contains(20.0));
    // A zero-range series must not invent a spread it never measured.
    expect(range.min, lessThanOrEqualTo(20.0));
    expect(range.max, greaterThanOrEqualTo(20.0));
    expect(range.span, lessThan(5));
  });

  testWidgets('empty series explains itself', (tester) async {
    await _pump(tester, const []);
    // The measurement as a noun, not the axis label: composing the sentence
    // from the axis gave "No HFR (px) recorded for these frames" and, on the
    // temperature chart, "No °C recorded for these frames".
    expect(
      find.textContaining('No half-flux radius recorded'),
      findsOneWidget,
    );
    expect(find.textContaining('No HFR (px) recorded'), findsNothing);
    expect(find.byType(SkotiqChart), findsNothing);
  });
}
