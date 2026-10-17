import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart'
    show dbSessionImagesProvider;
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The live photometry selection a fresh profile carries: no target picked, so
/// `activePhotometryTargetObjectIdProvider` falls back to 'target_primary'.
class _NoSelectionNotifier extends SciencePhotometrySelectionNotifier {
  @override
  Future<SciencePhotometrySelection> build() async =>
      const SciencePhotometrySelection();
}

ImagingSession _session(int id) => ImagingSession(
      id: id,
      name: 'Night D - V-Test',
      startTime: DateTime.utc(2026, 7, 25, 21),
      totalExposures: 0,
      successfulExposures: 0,
      failedExposures: 0,
      totalIntegrationSecs: 0,
      autofocusCount: 0,
      status: 'completed',
    );

/// A stored night's measurements, keyed on the star that WAS being tracked.
List<PhotometryMeasurementRow> _storedCurve(int sessionId, String objectId) => [
      for (var i = 0; i < 20; i++)
        PhotometryMeasurementRow(
          id: i + 1,
          sessionId: sessionId,
          objectId: objectId,
          role: 'target',
          x: 512,
          y: 512,
          flux: 10000 + i * 10,
          differentialMagnitude: -0.30 + i * 0.03,
          snr: 80,
          uncertainty: 0.01,
          isOutlier: false,
          timestamp: DateTime.utc(2026, 7, 25, 21, i),
        ),
    ];

Widget _tab(List<PhotometryMeasurementRow> photometry) {
  const sessionId = 4;
  return ProviderScope(
    overrides: [
      allSessionsProvider.overrideWith(
        (ref) => Stream.value([_session(sessionId)]),
      ),
      latestScienceSessionProvider.overrideWith((ref) async => sessionId),
      sessionPhotometryProvider.overrideWith((ref, id) => Stream.value(
            id == sessionId ? photometry : const <PhotometryMeasurementRow>[],
          )),
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
        (ref, id) => Stream.value(const <ScienceFrameQualityMetricsRow>[]),
      ),
      sessionTileMetricsProvider.overrideWith(
        (ref, id) => Stream.value(const <ScienceTileMetricRow>[]),
      ),
      dbSessionImagesProvider.overrideWith(
        (ref, id) => Stream.value(const <DbCapturedImage>[]),
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

  testWidgets('a reviewed session plots the photometry it actually recorded',
      (tester) async {
    // The stored rows name V-TEST; the live selection names nothing, so the
    // global fallback is 'target_primary'. That mismatch alone must not hide
    // the curve.
    await tester.pumpWidget(_tab(_storedCurve(4, 'V-TEST')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Differential Photometry has no data yet'), findsNothing);
    expect(find.text('Differential Photometry'), findsOneWidget);
  });

  testWidgets('comparison stars are not promoted into a light curve',
      (tester) async {
    // Rows exist for this session, but none of them measure a target. Falling
    // back to "whatever object has the most rows" regardless of role would
    // draw a comparison star's curve and label it the target's.
    final comparisonsOnly = [
      for (final row in _storedCurve(4, 'COMP-1'))
        PhotometryMeasurementRow(
          id: row.id,
          sessionId: row.sessionId,
          objectId: row.objectId,
          role: 'comparison',
          x: row.x,
          y: row.y,
          flux: row.flux,
          differentialMagnitude: row.differentialMagnitude,
          isOutlier: false,
          timestamp: row.timestamp,
        ),
    ];
    await tester.pumpWidget(_tab(comparisonsOnly));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Differential Photometry'), findsNothing);
  });
}
