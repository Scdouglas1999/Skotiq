// The calibration wizard's frame picker has to make the airmass spread it asks
// for reachable, and has to say what its numbers are.
//
// Observed on a 120-frame night: every row read
// "vt_0NN.fits / V | 120.0s | Stars: 1500 | RA: 120.0000 Dec: 25.0000".
// No Select All, no Clear, no altitude or airmass anywhere — even though the
// step's own instructions ask for "frames of the same field at different
// altitudes" and star matching REFUSES a frame whose altitude was never
// recorded. And solvedRa is HOURS, so the bare decimal was both unitless and
// easy to read as degrees.

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

DbCapturedImage _frame(
  int id,
  String name, {
  double? altitude,
  String filter = 'V',
}) =>
    DbCapturedImage(
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
      // 5.5 hours = 05:30:00, NOT 5.5 degrees.
      solvedRa: 5.5,
      solvedDec: 25.0,
      mountAltitude: altitude,
      filter: filter,
      starCount: 1500,
    );

Widget _app(List<DbCapturedImage> frames) => ProviderScope(
      overrides: [
        allSessionsProvider
            .overrideWith((ref) => Stream.value([_session(1, 'Standards')])),
        calibrationSessionImagesProvider
            .overrideWith((ref, sessionId) async => frames),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: PhotometricCalibrationWizard()),
      ),
    );

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

  testWidgets('every row states its altitude and airmass', (tester) async {
    await tester.pumpWidget(_app([
      _frame(11, 'high.fits', altitude: 75.0),
      _frame(12, 'low.fits', altitude: 25.0),
    ]));
    await tester.pumpAndSettle();

    // Airmass rises as altitude falls, which is the spread the fit needs.
    expect(find.textContaining('Alt 75.0° · X 1.0'), findsOneWidget);
    expect(find.textContaining('Alt 25.0° · X 2.3'), findsOneWidget);
  });

  testWidgets('a frame with no recorded altitude says it cannot be fitted',
      (tester) async {
    await tester.pumpWidget(_app([
      _frame(11, 'ok.fits', altitude: 60.0),
      _frame(12, 'no-alt.fits'),
    ]));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('no recorded altitude — cannot fit'),
      findsOneWidget,
      reason: 'star matching refuses it; the picker must not hide that until '
          'the user has already pressed Match Stars',
    );
  });

  testWidgets('RA is printed in hours, sexagesimally, not as a bare decimal',
      (tester) async {
    await tester.pumpWidget(_app([_frame(11, 'v.fits', altitude: 60.0)]));
    await tester.pumpAndSettle();

    expect(find.textContaining('RA 05:30:00.00'), findsOneWidget);
    expect(find.textContaining('Dec +25:00:00.00'), findsOneWidget);
    expect(
      find.textContaining('RA: 5.5000'),
      findsNothing,
      reason: 'a bare decimal in an hours column reads as degrees',
    );
  });

  testWidgets('Select all usable takes the fittable frames in one click',
      (tester) async {
    await tester.pumpWidget(_app([
      _frame(11, 'a.fits', altitude: 70.0),
      _frame(12, 'b.fits', altitude: 40.0),
      _frame(13, 'c.fits', altitude: 25.0),
      // Refused by the fit: no altitude at all.
      _frame(14, 'd.fits'),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('0 of 4 selected · 1 unusable'), findsOneWidget);

    await tester.tap(find.text('Select all usable'));
    await tester.pumpAndSettle();

    expect(
      find.text('3 of 4 selected · 1 unusable'),
      findsOneWidget,
      reason: 'the airmass-less frame would only fail at Match Stars',
    );

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('0 of 4 selected · 1 unusable'), findsOneWidget);
  });

  testWidgets('Select all respects the filter being calibrated',
      (tester) async {
    await tester.pumpWidget(_app([
      _frame(11, 'v1.fits', altitude: 70.0),
      _frame(12, 'b1.fits', altitude: 40.0, filter: 'B'),
    ]));
    await tester.pumpAndSettle();

    // Pick the V frame first, which anchors the filter to V.
    await tester.tap(find.text('v1.fits'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all usable'));
    await tester.pumpAndSettle();

    expect(find.text('1 of 2 selected · 1 unusable'), findsOneWidget);
  });

  testWidgets('Select all anchors the filter when none has been chosen yet',
      (tester) async {
    // The wizard opens with an empty Filter field. Tapping a frame anchors the
    // calibration on that frame's filter and every other filter is then
    // refused, so a bulk select that ignored the filter entirely would hand the
    // extinction fit a mixed-filter set in one click — a k fitted across
    // filters, saved as a transform for one of them.
    await tester.pumpWidget(_app([
      _frame(11, 'v1.fits', altitude: 70.0),
      _frame(12, 'v2.fits', altitude: 40.0),
      _frame(13, 'b1.fits', altitude: 55.0, filter: 'B'),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('0 of 3 selected'), findsOneWidget,
        reason: 'with no filter chosen yet nothing is unusable on filter '
            'grounds — every frame has an altitude');

    await tester.tap(find.text('Select all usable'));
    await tester.pumpAndSettle();

    expect(
      find.text('2 of 3 selected · 1 unusable'),
      findsOneWidget,
      reason: 'the two V frames, not the B frame that shares the session',
    );
    // The anchor is visible in the Filter field, so the user can see (and
    // change) which filter the one click committed them to.
    expect(find.widgetWithText(TextField, 'V'), findsOneWidget);
  });
}
