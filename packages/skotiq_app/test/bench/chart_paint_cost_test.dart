import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/session_chart.dart';
import 'package:skotiq_app/screens/guiding/widgets/guide_graph_advanced.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'paint_cost.dart';

Widget _host(Widget child, Size size) => MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Center(
          child: SizedBox(width: size.width, height: size.height, child: child),
        ),
      ),
    );

void main() {
  testWidgets('guiding graph paint cost', (tester) async {
    final random = math.Random(7);
    final now = DateTime.now();
    final data = <GuideDataPoint>[
      for (var i = 0; i < 300; i++)
        GuideDataPoint(
          timestamp: now.subtract(Duration(seconds: 300 - i)),
          raError: (random.nextDouble() - 0.5) * 2,
          decError: (random.nextDouble() - 0.5) * 1.4,
        ),
    ];
    await tester.pumpWidget(
      _host(
        GuideGraphAdvanced(
          data: data,
          rmsRa: 0.5,
          rmsDec: 0.4,
          rmsTotal: 0.64,
        ),
        const Size(800, 320),
      ),
    );
    await tester.pump();
    final micros = medianPaintMicros(tester, find.byType(GuideGraphAdvanced));
    // ignore: avoid_print
    print(
        'PAINT guiding_graph 300pts 800x320: ${micros.toStringAsFixed(0)} us');
  });

  testWidgets('analytics session chart paint cost', (tester) async {
    final random = math.Random(11);
    final start = DateTime(2026, 10, 23, 20, 28);
    final points = <ChartDataPoint>[
      for (var i = 0; i < 192; i++)
        ChartDataPoint(
          timestamp: start.add(Duration(seconds: i * 134)),
          value: 2.0 + random.nextDouble() * 1.2,
        ),
    ];
    await tester.pumpWidget(
      _host(
        SingleChildScrollView(
          child: SessionChart(
            title: 'Image quality',
            yAxisLabel: 'HFR (px)',
            dataPoints: points,
            reading: (value) => value.toStringAsFixed(2),
          ),
        ),
        const Size(600, 320),
      ),
    );
    await tester.pump();
    final micros = medianPaintMicros(tester, find.byType(SessionChart));
    // ignore: avoid_print
    print('PAINT session_chart 192pts 600w: ${micros.toStringAsFixed(0)} us');
  });
}
