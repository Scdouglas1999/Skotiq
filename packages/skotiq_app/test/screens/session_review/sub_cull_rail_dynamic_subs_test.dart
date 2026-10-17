import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/widgets/sub_cull_rail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _ReviewController extends Mock implements SessionReviewController {
  @override
  RemoveListener addListener(
    void Function(SessionReviewState) listener, {
    bool fireImmediately = true,
  }) {
    return () {};
  }

  /// No curve in this fixture, so the rail offers no cull. Stubbed rather than
  /// left to `noSuchMethod` because the rail reads it during initState.
  @override
  CullRecommendationOffer get cullRecommendationOffer =>
      CullRecommendationOffer.none;
}

DbCapturedImage _sub() => DbCapturedImage(
      id: 7,
      filePath: '/tmp/light-007.fits',
      fileName: 'light-007.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 15),
      createdAt: DateTime.utc(2026, 7, 15),
      isAccepted: true,
      isPlateSolved: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('blink stops safely when the live sub list becomes empty',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final subs = ValueNotifier<List<DbCapturedImage>>([_sub()]);
    addTearDown(subs.dispose);
    final controller = _ReviewController();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: ValueListenableBuilder<List<DbCapturedImage>>(
              valueListenable: subs,
              builder: (context, value, child) => SubCullRail(
                subs: value,
                controller: controller,
                onTapSub: (_) {},
                onSetAccepted: (_, __) {},
                onBulkCull: ({hfrThreshold, qualityThreshold}) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Blink mode'));
    await tester.pump();
    subs.value = const [];
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.text('No light subs'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
