// The two Field Quality charts must describe the same frames, and the HFR
// card's empty state must name the real reason.
//
// Observed defect: after rejecting both of a session's frames in the Image
// grader (metrics untouched), "HFR over time" rendered "HFR appears once star
// metrics are recorded on captures." — sending the user after a star-detection
// problem that did not exist — while "Field uniformity (CV)" beside it kept
// plotting the same two rejected frames.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart'
    show dbSessionImagesProvider;
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _sessionId = 5;

class _NoSelectionNotifier extends SciencePhotometrySelectionNotifier {
  @override
  Future<SciencePhotometrySelection> build() async =>
      const SciencePhotometrySelection();
}

ImagingSession _session() => ImagingSession(
      id: _sessionId,
      name: 'Night E - M13',
      startTime: DateTime.utc(2026, 7, 31, 23),
      totalExposures: 2,
      successfulExposures: 2,
      failedExposures: 0,
      totalIntegrationSecs: 600,
      autofocusCount: 0,
      status: 'completed',
    );

DbCapturedImage _frame({required int id, required bool accepted}) =>
    DbCapturedImage(
      id: id,
      sessionId: _sessionId,
      filePath: '/tmp/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 300,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 31, 23, id),
      createdAt: DateTime.utc(2026, 7, 31, 23, id),
      isAccepted: accepted,
      isPlateSolved: true,
      hfr: 2.20,
      starCount: 3000,
    );

ScienceFrameQualityMetricsRow _metrics(
        {required int imageId, required double cv}) =>
    ScienceFrameQualityMetricsRow(
      id: imageId,
      capturedImageId: imageId,
      sessionId: _sessionId,
      timestamp: DateTime.utc(2026, 7, 31, 23, imageId),
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
      uniformityCv: cv,
      gradientX: 0.01,
      gradientY: 0.01,
      processingTier: 'full',
      processingMs: 40,
    );

Widget _tab({required bool accepted}) {
  final frames = [
    _frame(id: 1, accepted: accepted),
    _frame(id: 2, accepted: accepted),
  ];
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
      sessionFrameQualityMetricsProvider.overrideWith(
        (ref, id) => Stream.value([
          _metrics(imageId: 1, cv: 0.180),
          _metrics(imageId: 2, cv: 0.240),
        ]),
      ),
      sessionTileMetricsProvider.overrideWith(
        (ref, id) => Stream.value(const <ScienceTileMetricRow>[]),
      ),
      dbSessionImagesProvider.overrideWith((ref, id) => Stream.value(frames)),
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

  testWidgets(
      'rejected frames leave both Field Quality charts, and the empty '
      'state says why', (tester) async {
    await tester.pumpWidget(_tab(accepted: false));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('HFR appears once star metrics are recorded on captures.'),
      findsNothing,
      reason: 'the frames have HFR 2.20 and 3000 stars; they were rejected',
    );
    expect(
      find.textContaining('No accepted frames with star metrics'),
      findsOneWidget,
    );
    expect(
      find.textContaining('No accepted frames with uniformity maps'),
      findsOneWidget,
      reason: 'uniformity must not keep plotting frames HFR dropped',
    );
  });

  testWidgets('accepted frames feed both charts', (tester) async {
    await tester.pumpWidget(_tab(accepted: true));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('No accepted frames'), findsNothing);
    expect(find.text('HFR over time'), findsOneWidget);
    expect(find.text('Field uniformity (CV)'), findsOneWidget);
  });
}
