// A session that was never closed must be described the same way everywhere.
//
// For one row (status in_progress, end_time NULL, three frames spanning 20
// minutes) Analytics > History reads `now - startTime` — "46h 2m elapsed",
// growing forever after a crash — while Analytics > Session computes
// `(endTime ?? startTime) - startTime` and reads "DURATION 0s". Two readouts,
// both false, in one app.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

final _start = DateTime.utc(2026, 7, 30, 20, 30);

/// Night C - M31: never closed, three frames over 20.3 minutes.
final _unfinished = ImagingSession(
  id: 3,
  name: 'Night C - M31',
  startTime: _start,
  totalExposures: 3,
  successfulExposures: 3,
  failedExposures: 0,
  totalIntegrationSecs: 900,
  autofocusCount: 0,
  status: 'in_progress',
);

DbCapturedImage _image({required int id, required int minutesIn}) =>
    DbCapturedImage(
      id: id,
      sessionId: 3,
      filePath: '/tmp/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 300,
      binX: 1,
      binY: 1,
      capturedAt: _start.add(Duration(minutes: minutesIn)),
      createdAt: _start.add(Duration(minutes: minutesIn)),
      isAccepted: true,
      isPlateSolved: false,
      hfr: 2.2,
    );

final _frames = [
  _image(id: 1, minutesIn: 0),
  _image(id: 2, minutesIn: 10),
  _image(id: 3, minutesIn: 20),
];

Widget _app(AnalyticsTab tab) {
  return ProviderScope(
    overrides: [
      allSessionsProvider.overrideWith((ref) => Stream.value([_unfinished])),
      allDbImagesProvider.overrideWith((ref) => Stream.value(_frames)),
      dbSessionImagesProvider.overrideWith((ref, id) => Stream.value(_frames)),
      scienceDefaultSessionProvider.overrideWith((ref) async => 3),
      standaloneImagesProvider.overrideWith(
        (ref) => Stream.value(const <DbCapturedImage>[]),
      ),
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: AnalyticsScreen(initialTab: tab)),
    ),
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1400, 2400);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('the Session tab does not report 0s for an unclosed session',
      (tester) async {
    await tester.pumpWidget(_app(AnalyticsTab.session));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('0s'),
      findsNothing,
      reason: 'a 20-minute session must not be reported as lasting 0s',
    );
    expect(find.text('20m'), findsWidgets);
    // The stat strip uppercases its caption.
    expect(find.textContaining('TO LAST FRAME'), findsOneWidget);
  });
}
