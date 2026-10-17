// The Captured Images summary must not grade a frame nobody measured.
//
// Observed defect: a session of 12 lights (8 good, 2 needs-review, 2 poor) plus
// 4 darks with no HFR / star count / guiding RMS / quality score reported
// "Good: 12". FrameQualityAssessmentService starts every frame at an advisory
// 75 and only ever decrements it from a metric, so the four unmeasured darks
// came back Good/75 and were rendered with a green GOOD badge.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/image_thumbnail_strip.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

DbCapturedImage _frame({
  required int id,
  required String type,
  double? hfr,
  int? starCount,
  double? guidingRms,
}) =>
    DbCapturedImage(
      id: id,
      filePath: '/tmp/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      frameType: type,
      exposureDuration: 300,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 30, 21, id),
      createdAt: DateTime.utc(2026, 7, 30, 21, id),
      isAccepted: true,
      isPlateSolved: false,
      hfr: hfr,
      starCount: starCount,
      guidingRmsTotal: guidingRms,
    );

Widget _strip(List<DbCapturedImage> images) => ProviderScope(
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: ImageThumbnailStrip(images: images)),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('unmeasured calibration frames are not counted as Good',
      (tester) async {
    // The lights sit on the heuristic's own fallback values (hfr 2.6, guiding
    // 1.4"), which is what a real session of typical frames looks like to it —
    // so the unmeasured darks, which are scored on exactly those fallbacks,
    // graded "Good" alongside them.
    await tester.pumpWidget(_strip([
      _frame(id: 1, type: 'light', hfr: 2.6, starCount: 900, guidingRms: 1.4),
      _frame(id: 2, type: 'light', hfr: 2.6, starCount: 880, guidingRms: 1.4),
      // Four darks: sensor temperature only, every quality metric null.
      _frame(id: 3, type: 'dark'),
      _frame(id: 4, type: 'dark'),
      _frame(id: 5, type: 'dark'),
      _frame(id: 6, type: 'dark'),
    ]));
    await tester.pump();

    expect(
      find.text('Good: 2'),
      findsOneWidget,
      reason: 'only the two measured lights were assessed good',
    );
    expect(find.text('Unrated: 4'), findsOneWidget);
    expect(find.text('Total: 6'), findsOneWidget);
  });

  testWidgets('an unmeasured frame is badged UNRATED, not GOOD',
      (tester) async {
    await tester.pumpWidget(_strip([_frame(id: 9, type: 'dark')]));
    await tester.pump();

    expect(find.text('UNRATED'), findsOneWidget);
    expect(find.text('GOOD'), findsNothing);
    expect(
      find.textContaining('75 score'),
      findsNothing,
      reason: 'the 75 default is a starting point, not a measurement',
    );
  });
}
