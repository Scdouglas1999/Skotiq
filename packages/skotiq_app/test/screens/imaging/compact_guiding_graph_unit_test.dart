// The Imaging side panel's guide graph speaks the unit of the RMS and peak
// readouts beside it: arcseconds once the guider reports its scale, pixels
// before. It read "4 px" over readouts in ″.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/guiding_panel.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<SkotiqChart> _chart(WidgetTester tester, double? arcsecPerPixel) async {
  final now = DateTime(2026, 11, 11, 22);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          child: CompactGuidingGraph(
            colors: SkotiqColors.dark,
            data: [
              GuideGraphPoint(
                  0.5, -0.25, now.subtract(const Duration(seconds: 2))),
              GuideGraphPoint(1.0, 3.0, now),
            ],
            isGuiding: true,
            isConnected: true,
            arcsecPerPixel: arcsecPerPixel,
          ),
        ),
      ),
    ),
  );
  return tester.widget<SkotiqChart>(find.byType(SkotiqChart));
}

void main() {
  testWidgets('with a known guide scale the graph plots arcseconds', (
    tester,
  ) async {
    final chart = await _chart(tester, 2.0);

    expect(chart.y.unit, '″');
    expect(chart.semanticLabel, contains('±4″ full scale'));
    final ra = chart.series.firstWhere((s) => s.label == 'RA');
    final dec = chart.series.firstWhere((s) => s.label == 'Dec');
    expect(ra.points.map((p) => p.dy), [1.0, 2.0]);
    // 3 px is 6″, past the ±4″ scale.
    expect(dec.points.map((p) => p.dy), [-0.5, 4.0]);
  });

  testWidgets('without a guide scale the graph plots pixels', (tester) async {
    final chart = await _chart(tester, null);

    expect(chart.y.unit, ' px');
    expect(chart.semanticLabel, contains('±4 px full scale'));
    final ra = chart.series.firstWhere((s) => s.label == 'RA');
    expect(ra.points.map((p) => p.dy), [0.5, 1.0]);
  });
}
