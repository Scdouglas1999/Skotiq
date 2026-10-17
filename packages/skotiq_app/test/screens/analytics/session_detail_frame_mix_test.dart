// The session detail dialog shows two counts of "frames" side by side: the
// session's denormalised exposure counters (lights only) and the captured-image
// list (every frame on disk, calibration included). Live, that read as
// "Total Exposures 12" directly above "Images (16)" with nothing saying the two
// measure different things.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _TutorialsDisabledNotifier extends TutorialNotifier {
  _TutorialsDisabledNotifier() : super(_NoopTutorialProgressDao()) {
    // ignore: invalid_use_of_protected_member
    state = const TutorialProgress(tutorialsEnabled: false);
  }
}

class _NoopTutorialProgressDao implements TutorialProgressDao {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'NoopTutorialProgressDao.${invocation.memberName} called in test',
      );
}

DbCapturedImage _image(int id, String frameType) => DbCapturedImage(
      id: id,
      sessionId: 5,
      filePath: '/tmp/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      frameType: frameType,
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 30, 22, id),
      createdAt: DateTime.utc(2026, 7, 30, 22, id),
      isAccepted: true,
      isPlateSolved: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the image list says how many of its frames are calibration',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final session = ImagingSession(
      id: 5,
      name: 'Night A - M31',
      startTime: DateTime(2026, 7, 30),
      totalExposures: 12,
      successfulExposures: 10,
      failedExposures: 2,
      totalIntegrationSecs: 1440,
      autofocusCount: 0,
      status: 'completed',
    );
    final images = [
      for (var i = 0; i < 12; i++) _image(i, 'light'),
      for (var i = 12; i < 16; i++) _image(i, 'dark'),
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
            (ref) => Stream<List<DbCapturedImage>>.value(const []),
          ),
          dbSessionImagesProvider(5).overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(images),
          ),
          tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: AnalyticsScreen(initialTab: AnalyticsTab.history),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Night A - M31'));
    // pump, not pumpAndSettle: the thumbnail futures never go idle locally.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Images (16)'), findsOneWidget);
    expect(find.text('12 light · 4 calibration'), findsOneWidget);
    expect(
      find.textContaining('Exposure counts are light frames only.'),
      findsOneWidget,
    );
    // The stats block now carries a THIRD reading beside those two: the
    // culling's verdict on the light frames. The four darks are excluded —
    // calibration is never graded, so counting it would inflate Accepted.
    // The pair is one Readout widget now, so the test reads the widget
    // instead of walking to the Column that used to hold label and value as
    // separate Texts. Scoped to the dialog: the History row behind it carries
    // readouts of its own.
    final accepted = tester
        .widgetList<Readout>(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.byType(Readout),
          ),
        )
        .where((r) => r.label == 'Accepted')
        .toList(growable: false);
    expect(accepted, hasLength(1));
    expect(accepted.single.value, '12');
  });
}
