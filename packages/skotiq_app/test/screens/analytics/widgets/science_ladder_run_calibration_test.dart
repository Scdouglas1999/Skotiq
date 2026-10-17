// Rung 1 of the Science guide says 'Run calibration'. It must run one.
//
// Observed defect: in the populated Science tab the rung scrolled to the FIELD
// QUALITY section, whose only control grades frames. The photometric
// calibration wizard was wired ONLY into the empty-state ladder, so the moment
// a user had any science data at all the wizard became unreachable from
// anywhere in the app while a button promising it stayed on screen.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart'
    show dbSessionImagesProvider;
import 'package:skotiq_app/screens/analytics/widgets/photometric_calibration_wizard.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _sessionId = 7;

class _NoSelectionNotifier extends SciencePhotometrySelectionNotifier {
  @override
  Future<SciencePhotometrySelection> build() async =>
      const SciencePhotometrySelection();
}

ImagingSession _session() => ImagingSession(
      id: _sessionId,
      name: 'Night G - M13',
      startTime: DateTime.utc(2026, 7, 31, 23),
      totalExposures: 1,
      successfulExposures: 1,
      failedExposures: 0,
      totalIntegrationSecs: 300,
      autofocusCount: 0,
      status: 'completed',
    );

DbCapturedImage _frame() => DbCapturedImage(
      id: 1,
      sessionId: _sessionId,
      filePath: '/tmp/1.fits',
      fileName: '1.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 300,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 31, 23, 1),
      createdAt: DateTime.utc(2026, 7, 31, 23, 1),
      isAccepted: true,
      isPlateSolved: true,
      hfr: 2.20,
      starCount: 3000,
    );

ScienceFrameQualityMetricsRow _metrics() => ScienceFrameQualityMetricsRow(
      id: 1,
      capturedImageId: 1,
      sessionId: _sessionId,
      timestamp: DateTime.utc(2026, 7, 31, 23, 1),
      median: 100,
      mean: 101,
      stdDev: 12,
      mad: 8,
      background: 95,
      noise: 4,
      snr: 30,
      dynamicRangeP1P99: 900,
      lowClipPercent: 0,
      highClipPercent: 0,
      uniformityCv: 0.18,
      gradientX: 0.01,
      gradientY: 0.01,
      processingTier: 'full',
      processingMs: 40,
    );

Widget _tab() {
  return ProviderScope(
    overrides: [
      allSessionsProvider.overrideWith((ref) => Stream.value([_session()])),
      latestScienceSessionProvider.overrideWith((ref) async => _sessionId),
      sessionPhotometryProvider.overrideWith(
        (ref, id) => Stream.value(const <PhotometryMeasurementRow>[]),
      ),
      sessionTransparencySamplesProvider.overrideWith(
        (ref, id) => Stream.value(const <TransparencySampleRow>[]),
      ),
      // No calibrated row: rung 1 is the next actionable step, so its CTA is
      // the page-level button.
      sessionFrameCalibrationsProvider.overrideWith(
        (ref, id) => Stream.value(const <FramePhotometricCalibrationRow>[]),
      ),
      sessionPsfTilesProvider.overrideWith(
        (ref, id) => Stream.value(const <PsfFieldTileRow>[]),
      ),
      sessionResidualVectorsProvider.overrideWith(
        (ref, id) => Stream.value(const <AstrometryResidualVectorRow>[]),
      ),
      sessionMovingObjectCandidatesProvider.overrideWith(
        (ref, id) => Stream.value(const <MovingObjectCandidateRow>[]),
      ),
      sessionLineRatioProductsProvider.overrideWith(
        (ref, id) => Stream.value(const <LineRatioProductRow>[]),
      ),
      // One real science product, so the tab renders its POPULATED branch (the
      // all-empty branch has its own ladder wiring) while calibrations stay
      // empty.
      sessionFrameQualityMetricsProvider.overrideWith(
        (ref, id) => Stream.value([_metrics()]),
      ),
      sessionTileMetricsProvider.overrideWith(
        (ref, id) => Stream.value(const <ScienceTileMetricRow>[]),
      ),
      dbSessionImagesProvider.overrideWith(
        (ref, id) => Stream.value([_frame()]),
      ),
      sciencePhotometrySelectionProvider.overrideWith(_NoSelectionNotifier.new),
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: const Scaffold(body: ScienceAnalyticsTab()),
    ),
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1400, 4000);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets("'Run calibration' opens the photometric calibration wizard",
      (tester) async {
    await tester.pumpWidget(_tab());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    final cta = find.text('Run calibration');
    expect(cta, findsOneWidget, reason: 'no calibration exists yet');

    await tester.tap(cta);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(PhotometricCalibrationWizard), findsOneWidget);
  });
}
