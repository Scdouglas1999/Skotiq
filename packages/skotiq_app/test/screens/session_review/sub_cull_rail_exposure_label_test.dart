import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/widgets/sub_cull_rail.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _ReviewController extends Mock implements SessionReviewController {
  @override
  RemoveListener addListener(
    void Function(SessionReviewState) listener, {
    bool fireImmediately = true,
  }) {
    return () {};
  }

  @override
  CullRecommendationOffer get cullRecommendationOffer =>
      CullRecommendationOffer.none;
}

DbCapturedImage _sub(int id, double exposure) => DbCapturedImage(
      id: id,
      filePath: '/tmp/light-$id.fits',
      fileName: 'light-$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      filter: 'R',
      exposureDuration: exposure,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 15, 0, 0, id),
      createdAt: DateTime.utc(2026, 7, 15),
      isAccepted: true,
      isPlateSolved: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a sub tile names a short exposure in milliseconds',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: SubCullRail(
              subs: [_sub(1, 0.005), _sub(2, 0.25)],
              controller: _ReviewController(),
              onTapSub: (_) {},
              onSetAccepted: (_, __) {},
              onBulkCull: ({hfrThreshold, qualityThreshold}) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('R · 5 ms'), findsOneWidget);
    expect(find.text('R · 0.25s'), findsOneWidget);
    expect(find.text('R · 0s'), findsNothing);
  });
}
