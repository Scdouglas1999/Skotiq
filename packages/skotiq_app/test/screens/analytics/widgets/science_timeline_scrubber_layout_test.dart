import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_timeline_scrubber.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

ScienceFrameQualityMetricsRow _metric(int id) => ScienceFrameQualityMetricsRow(
      id: id,
      capturedImageId: id,
      sessionId: 5,
      timestamp: DateTime.utc(2026, 10, 26, 1, id),
      median: 100,
      mean: 101,
      stdDev: 12,
      mad: 8,
      background: 95,
      noise: 4,
      snr: 30,
      dynamicRangeP1P99: 900,
      lowClipPercent: 0,
      highClipPercent: 0,
      uniformityCv: 0.18,
      gradientX: 0.01,
      gradientY: 0.01,
      processingTier: 'full',
      processingMs: 40,
    );

void main() {
  for (final textScale in [1.0, 2.0]) {
    testWidgets('narrow timeline keeps readouts usable at ${textScale}x text', (
      tester,
    ) async {
      int? selectedFrame;
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
              child: Center(
                child: SizedBox(
                  width: 300,
                  child: Builder(
                    builder: (context) => ScienceTimelineScrubber(
                      colors: SkotiqColors.of(context),
                      frameMetrics: [_metric(1), _metric(2)],
                      onFrameSelected: (id) => selectedFrame = id,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Frame 1/2'), findsOneWidget);
      expect(find.textContaining('Sky/read noise 30.0x'), findsOneWidget);
      expect(find.textContaining('Clip H 0.00%'), findsOneWidget);

      await tester.tapAt(
          tester.getTopRight(find.byType(Slider)) + const Offset(-25, 24));
      await tester.pump();
      expect(selectedFrame, 2);
      expect(find.text('Frame 2/2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
