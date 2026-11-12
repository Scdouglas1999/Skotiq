// Analytics' session picker beside the graded frame counts.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

DbCapturedImage _image(int id, String frameType, {bool accepted = true}) =>
    DbCapturedImage(
      id: id,
      sessionId: 5,
      filePath: '/tmp/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      frameType: frameType,
      exposureDuration: 60,
      binX: 1,
      binY: 1,
      capturedAt: DateTime(2026, 11, 3, 18, 20 + id),
      createdAt: DateTime(2026, 11, 3, 18, 20 + id),
      isAccepted: accepted,
      isPlateSolved: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Rig, 2026-11-03: the picker read "7/8 frames kept" from the session row
  // while the readouts under it read "4/8 exposures" from the graded frames.
  // The row's `successful_exposures` is what the camera returned, not what the
  // grading kept, so the picker names only the captures.
  testWidgets('the session picker does not call captures frames kept',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final session = ImagingSession(
      id: 5,
      name: 'Rig test NGC 7331',
      startTime: DateTime(2026, 11, 3, 18, 17),
      totalExposures: 8,
      successfulExposures: 7,
      failedExposures: 1,
      totalIntegrationSecs: 420,
      autofocusCount: 0,
      status: 'completed',
    );
    final images = [
      for (var i = 0; i < 8; i++) _image(i, 'light', accepted: i < 4),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allSessionsProvider.overrideWith(
            (ref) => Stream<List<ImagingSession>>.value([session]),
          ),
          standaloneImagesProvider.overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(const []),
          ),
          allDbImagesProvider.overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(images),
          ),
          dbSessionImagesProvider(5).overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(images),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: AnalyticsScreen(initialTab: AnalyticsTab.session),
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.byType(DropdownButton<int>).first);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.textContaining('frames kept'), findsNothing);
    expect(find.textContaining('8 exposures'), findsWidgets);
  });
}
