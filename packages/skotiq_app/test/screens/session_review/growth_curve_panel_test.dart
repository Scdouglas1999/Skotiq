// The project-growth curve is drawn by the shared chart kit, which remaps
// every data hue for the red night theme; the panel names hues and points
// only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart'
    show ReviewBestNight, GrowthPoint;
import 'package:skotiq_app/screens/session_review/widgets/growth_curve_panel.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Four nights of accrued integration, so the curve draws a real line.
List<GrowthPoint> _points() => List.generate(
      4,
      (i) => GrowthPoint(
        date: DateTime.utc(2026, 7, 10 + i),
        cumulativeHours: 1.5 * (i + 1),
        framesToDate: 30 * (i + 1),
      ),
    );

void main() {
  testWidgets('the growth curve and its best night are chart-kit series',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: SkotiqTheme.redNight,
      home: Scaffold(
        body: SingleChildScrollView(
          child: GrowthCurvePanel(
            points: _points(),
            best: ReviewBestNight(
              date: DateTime.utc(2026, 7, 12),
              meanWeight: 1.4,
              frameCount: 30,
              integrationHours: 1.5,
            ),
          ),
        ),
      ),
    ));

    final chart = tester.widget<SkotiqChart>(find.byType(SkotiqChart));
    final total = chart.series.firstWhere((s) => s.label == 'Total');
    expect(total.points.map((p) => p.dy), [1.5, 3.0, 4.5, 6.0]);
    final best = chart.series.singleWhere((s) => s.label == 'Best night');
    expect(best.points.single, const Offset(2, 4.5));
    expect(chart.semanticLabel, contains('over 4 nights'));
  });
}
