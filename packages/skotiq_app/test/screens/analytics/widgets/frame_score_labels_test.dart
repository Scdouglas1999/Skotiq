// The score on the Captured Images rail and in its frame inspector.
//
// Every tile of a clean 32-frame session reading "75 score" while the stored
// quality_score for those same frames runs 83.94-85.38 and is distinct per frame
// makes two different numbers both "the score", with the one on screen not the
// one in the database and neither labelled with its scale.
//
// And the inspector's summary line reading "Good — Low star count (39)" on every
// frame of that same clean session makes the explanation contradict its own
// verdict.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/frame_detail_dialog.dart';
import 'package:skotiq_app/screens/analytics/widgets/image_thumbnail_strip.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart';

/// The live shape from the audit: HFR ~2.1 px, 39 stars, quality score ~85.
DbCapturedImage _frame({required int id, required double qualityScore}) =>
    DbCapturedImage(
      id: id,
      filePath: '/captures/l$id.fits',
      fileName: 'l$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 3,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 8, 13, 9, id),
      createdAt: DateTime.utc(2026, 8, 13, 9, id),
      isAccepted: true,
      isPlateSolved: false,
      hfr: 2.1,
      starCount: 39,
      qualityScore: qualityScore,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  setUp(() => db = mockDatabase());
  tearDown(() async => db.close());

  testWidgets('a tile names its number instead of calling it "score"',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: ImageThumbnailStrip(
              images: [
                _frame(id: 1, qualityScore: 85.38),
                _frame(id: 2, qualityScore: 83.94),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.textContaining('score', findRichText: true),
      findsNothing,
      reason: 'an unqualified "NN score" is the string that collides with the '
          'stored quality score',
    );
    expect(find.textContaining('Advisory 75'), findsWidgets);
  });

  testWidgets('the inspector does not give an observation as the grade reason',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final image = _frame(id: 1, qualityScore: 85.0);
    const assessor = FrameQualityAssessmentService();
    final assessment = assessor.assessFrame(image);
    expect(assessment.level, FrameQualityLevel.good);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: FrameDetailDialog(image: image, assessment: assessment),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Good — Low star count (39)'), findsNothing);
    expect(find.textContaining('not disqualifying'), findsOneWidget);

    // Both numbers on one screen, each with its own name.
    expect(find.text('Advisory score'), findsOneWidget);
    expect(find.text('Recorded quality score'), findsOneWidget);
    expect(find.textContaining('85.0'), findsWidgets);
  });
}
