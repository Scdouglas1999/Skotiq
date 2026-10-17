import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/photometric_calibration_wizard.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

ImagingSession _session(int id, String name) => ImagingSession(
      id: id,
      name: name,
      startTime: DateTime.utc(2026, 7, 14, id),
      totalExposures: 2,
      successfulExposures: 2,
      failedExposures: 0,
      totalIntegrationSecs: 240,
      autofocusCount: 0,
      status: 'completed',
    );

DbCapturedImage _frame(int id, String name, String filter) => DbCapturedImage(
      id: id,
      filePath: '/tmp/$name',
      fileName: name,
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 14),
      createdAt: DateTime.utc(2026, 7, 14),
      isAccepted: true,
      isPlateSolved: true,
      solvedRa: 5.5,
      solvedDec: -5.4,
      filter: filter,
      starCount: 40,
    );

Widget _app({
  required Stream<List<ImagingSession>> sessions,
  required List<DbCapturedImage> Function(int) frames,
}) {
  return ProviderScope(
    overrides: [
      allSessionsProvider.overrideWith((ref) => sessions),
      calibrationSessionImagesProvider.overrideWith(
        (ref, sessionId) async => frames(sessionId),
      ),
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: const Scaffold(body: PhotometricCalibrationWizard()),
    ),
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1200, 900);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('selected frames stay bound to their original session',
      (tester) async {
    final sessions = StreamController<List<ImagingSession>>();
    addTearDown(sessions.close);

    await tester.pumpWidget(
      _app(
        sessions: sessions.stream,
        frames: (sessionId) => sessionId == 1
            ? [_frame(11, 'old-v.fits', 'V')]
            : [_frame(21, 'new-v.fits', 'V')],
      ),
    );
    sessions.add([_session(1, 'Original night')]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('old-v.fits'));
    await tester.pump();

    sessions.add([
      _session(2, 'New active night'),
      _session(1, 'Original night'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('old-v.fits'), findsOneWidget);
    expect(find.text('new-v.fits'), findsNothing);
  });

  testWidgets('mixed-filter frames are rejected and filter edits clear input',
      (tester) async {
    await tester.pumpWidget(
      _app(
        sessions: Stream.value([_session(1, 'Standards')]),
        frames: (_) => [
          _frame(11, 'v-frame.fits', 'V'),
          _frame(12, 'b-frame.fits', 'B'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('v-frame.fits'));
    await tester.pump();
    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Next'),
          )
          .onPressed,
      isNotNull,
    );

    await tester.ensureVisible(find.text('b-frame.fits'));
    await tester.tap(find.text('b-frame.fits'));
    await tester.pump();
    expect(find.textContaining('uses filter B'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'B');
    await tester.pump();
    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Next'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('session load failures are not presented as an empty history',
      (tester) async {
    await tester.pumpWidget(
      _app(
        sessions: Stream.error(StateError('database offline')),
        frames: (_) => const [],
      ),
    );
    await tester.pumpAndSettle();

    expect(
        find.textContaining('Could not load imaging sessions'), findsOneWidget);
    expect(find.textContaining('No imaging sessions found'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
  });
}
