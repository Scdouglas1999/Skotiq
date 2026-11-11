import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? SkotiqTheme.dark,
  home: Scaffold(
    body: Center(child: SizedBox(width: 400, height: 220, child: child)),
  ),
);

List<Offset> _ramp(int n) => <Offset>[
  for (var i = 0; i < n; i++) Offset(i.toDouble(), 2 + i * 0.1),
];

void main() {
  group('ChartLayout', () {
    test('a fitted value axis snaps outward to round ticks', () {
      final layout = ChartLayout(
        series: <ChartSeries>[
          ChartSeries(points: const <Offset>[Offset(0, 1.71), Offset(1, 3.25)]),
        ],
        x: const ChartAxis(),
        y: const ChartAxis(),
        y2: null,
        rules: const <ChartRule>[],
      );
      final range = layout.valueRange(ChartValueAxis.left)!;
      expect(range.min, lessThanOrEqualTo(1.71));
      expect(range.max, greaterThanOrEqualTo(3.25));
      expect(range.ticks.values.first, range.min);
      expect(range.ticks.values.last, range.max);
    });

    test('a fixed range is kept exactly and gaps are ignored', () {
      final layout = ChartLayout(
        series: <ChartSeries>[
          ChartSeries(
            points: const <Offset>[
              Offset(0, 0.4),
              Offset(1, double.nan),
              Offset(2, -9),
            ],
          ),
        ],
        x: const ChartAxis(min: -300, max: 0, kind: ChartAxisKind.elapsed),
        y: const ChartAxis(min: -2, max: 2, ticks: <double>[-2, -1, 0, 1, 2]),
        y2: null,
        rules: const <ChartRule>[],
      );
      expect(layout.xMin, -300);
      expect(layout.xMax, 0);
      final range = layout.valueRange(ChartValueAxis.left)!;
      expect((range.min, range.max), (-2.0, 2.0));
      expect(layout.valueLabel(-1, ChartValueAxis.left), '-1');
      expect(layout.xLabel(-120), '-2m');
    });

    test('a rule widens a fitted range so it is always on the plot', () {
      final layout = ChartLayout(
        series: <ChartSeries>[
          ChartSeries(points: const <Offset>[Offset(0, 1), Offset(1, 2)]),
        ],
        x: const ChartAxis(),
        y: const ChartAxis(),
        y2: null,
        rules: const <ChartRule>[ChartRule.y(5)],
      );
      expect(
        layout.valueRange(ChartValueAxis.left)!.max,
        greaterThanOrEqualTo(5),
      );
    });

    test('points map into the plot rectangle', () {
      final layout = ChartLayout(
        series: <ChartSeries>[
          ChartSeries(points: const <Offset>[Offset(0, 0), Offset(10, 4)]),
        ],
        x: const ChartAxis(),
        y: const ChartAxis(min: 0, max: 4),
        y2: null,
        rules: const <ChartRule>[],
      );
      const plot = Rect.fromLTWH(40, 10, 300, 100);
      expect(layout.xOf(0, plot), 40);
      expect(layout.xOf(10, plot), 340);
      expect(layout.yOf(0, ChartValueAxis.left, plot), 110);
      expect(layout.yOf(4, ChartValueAxis.left, plot), 10);
      expect(layout.yOf(1, ChartValueAxis.right, plot), isNull);
    });

    test('with no data nothing is fitted', () {
      final layout = ChartLayout(
        series: const <ChartSeries>[],
        x: const ChartAxis(),
        y: const ChartAxis(),
        y2: null,
        rules: const <ChartRule>[],
      );
      expect(layout.hasData, isFalse);
      expect(layout.valueRange(ChartValueAxis.left), isNull);
    });
  });

  group('SkotiqChart', () {
    testWidgets('paints series and exposes one semantic sentence', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SkotiqChart(
            semanticLabel: 'HFR over the session',
            series: <ChartSeries>[
              ChartSeries(points: _ramp(40), label: 'HFR'),
              ChartSeries(
                points: _ramp(40),
                kind: ChartSeriesKind.scatter,
                tone: SeriesChartTone.secondary,
              ),
              ChartSeries(
                points: _ramp(10),
                kind: ChartSeriesKind.bars,
                tone: SeriesChartTone.tertiary,
                axis: ChartValueAxis.right,
              ),
            ],
            y: const ChartAxis(unit: ' px'),
            y2: const ChartAxis(includeZero: true),
            rules: const <ChartRule>[
              ChartRule.y(3, label: 'median'),
              ChartRule.x(20),
            ],
            legend: true,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('HFR over the session'), findsOneWidget);
      expect(find.text('HFR'), findsOneWidget, reason: 'the legend entry');
    });

    testWidgets('says so when there is nothing to plot', (tester) async {
      await tester.pumpWidget(
        _host(
          const SkotiqChart(
            semanticLabel: 'Guide error',
            series: <ChartSeries>[],
            emptyText: 'No guide steps yet',
          ),
        ),
      );
      expect(find.text('No guide steps yet'), findsOneWidget);
    });

    testWidgets('shows progress, not the empty text, while loading', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const SkotiqChart(
            semanticLabel: 'Guide error',
            series: <ChartSeries>[],
            loading: true,
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('No data yet'), findsNothing);
    });

    testWidgets('hovering repaints only the readout layer', (tester) async {
      await tester.pumpWidget(
        _host(
          SkotiqChart(
            semanticLabel: 'HFR',
            series: <ChartSeries>[ChartSeries(points: _ramp(40), label: 'HFR')],
          ),
        ),
      );
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(SkotiqChart)));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('draws in every theme, red night included', (tester) async {
      for (final theme in <ThemeData>[
        SkotiqTheme.dark,
        SkotiqTheme.light,
        SkotiqTheme.redNight,
      ]) {
        await tester.pumpWidget(
          _host(
            SkotiqChart(
              semanticLabel: 'HFR',
              series: <ChartSeries>[
                ChartSeries(
                  points: _ramp(12),
                  color: SkotiqChartColors.seriesBlue,
                ),
              ],
            ),
            theme: theme,
          ),
        );
        expect(tester.takeException(), isNull);
      }
    });

    test('a fixed hue is moved onto the red channel in red night', () {
      final red = SkotiqChart.resolveColor(
        SkotiqColors.redNight,
        SeriesChartTone.primary,
        SkotiqChartColors.seriesBlue,
      );
      expect((red.g * 255).round(), 0);
      expect((red.b * 255).round(), 0);
    });
  });
}
