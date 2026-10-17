// The Science tab's status banner reports the IN-MEMORY processing pipeline,
// which is empty after every app launch. Reviewing a stored session therefore
// rendered "Science idle / Waiting for the first captured frame" directly above
// that session's own frames and solve-rate card. Reviewing stored results is
// now its own state, and the Science tab is what supplies the frame count.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart'
    show dbSessionImagesProvider;
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

DbCapturedImage _light(int id) => DbCapturedImage(
      id: id,
      sessionId: 42,
      filePath: '/tmp/m13_$id.fits',
      fileName: 'm13_$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 8, 1, 5, id),
      createdAt: DateTime.utc(2026, 8, 1, 5, id),
      isAccepted: true,
      isPlateSolved: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a stored session is reported as review, not as "no frame yet"',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final session = ImagingSession(
      id: 42,
      name: 'Night D - V-Test',
      startTime: DateTime(2026, 8, 1, 5),
      totalExposures: 3,
      successfulExposures: 3,
      failedExposures: 0,
      totalIntegrationSecs: 360,
      autofocusCount: 0,
      status: 'completed',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allSessionsProvider.overrideWith(
            (ref) => Stream<List<ImagingSession>>.value([session]),
          ),
          dbSessionImagesProvider(42).overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(
              [_light(0), _light(1), _light(2)],
            ),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: ScienceAnalyticsTab()),
        ),
      ),
    );
    // pump, not pumpAndSettle: the tab's image/thumbnail futures never idle.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Reviewing stored results'), findsOneWidget);
    expect(find.textContaining('3 frames on record'), findsOneWidget);
    expect(
      find.text('Waiting for the first captured frame'),
      findsNothing,
      reason: 'the session under review has frames on record',
    );
  });
}
