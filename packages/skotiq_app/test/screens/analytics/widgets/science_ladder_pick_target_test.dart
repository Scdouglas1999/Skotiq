// Rung 2 of the Science guide says 'Pick a target'. It must lead to the
// control that picks one.
//
// Observed defect (residual of the rung-1 fix): rung 2 was routed through
// `onJumpToPhotometry`, which the populated tab answered with a scroll to the
// PHOTOMETRY charts — a section that plots and exports curves and contains no
// target control — and which the all-empty tab answered by opening the
// photometric calibration wizard. A button reading 'Pick a target' opened a
// star-field calibration dialog. The only control in the app that sets a
// photometry target is the science HUD over the live frame.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart'
    show dbSessionImagesProvider;
import 'package:skotiq_app/screens/analytics/widgets/photometric_calibration_wizard.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _sessionId = 11;

class _NoSelectionNotifier extends SciencePhotometrySelectionNotifier {
  @override
  Future<SciencePhotometrySelection> build() async =>
      const SciencePhotometrySelection();
}

ImagingSession _session() => ImagingSession(
      id: _sessionId,
      name: 'Night H - M13',
      startTime: DateTime.utc(2026, 8, 1, 23),
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
      capturedAt: DateTime.utc(2026, 8, 1, 23, 1),
      createdAt: DateTime.utc(2026, 8, 1, 23, 1),
      isAccepted: true,
      isPlateSolved: true,
      hfr: 2.20,
      starCount: 3000,
    );

ScienceFrameQualityMetricsRow _metrics() => ScienceFrameQualityMetricsRow(
      id: 1,
      capturedImageId: 1,
      sessionId: _sessionId,
      timestamp: DateTime.utc(2026, 8, 1, 23, 1),
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

/// [populated] chooses which branch of the tab renders: one frame-quality row
/// is a science product, so the tab leaves its all-empty branch.
Widget _tab({required bool populated}) {
  final router = GoRouter(
    initialLocation: '/analytics',
    routes: [
      GoRoute(
        path: '/analytics',
        builder: (_, __) => const Scaffold(body: ScienceAnalyticsTab()),
      ),
      GoRoute(
        path: '/imaging',
        builder: (_, __) => const Scaffold(body: Text('IMAGING SCREEN')),
      ),
    ],
  );

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
        (ref, id) => Stream.value(
          populated ? [_metrics()] : const <ScienceFrameQualityMetricsRow>[],
        ),
      ),
      sessionTileMetricsProvider.overrideWith(
        (ref, id) => Stream.value(const <ScienceTileMetricRow>[]),
      ),
      dbSessionImagesProvider.overrideWith(
        (ref, id) => Stream.value([_frame()]),
      ),
      sciencePhotometrySelectionProvider.overrideWith(_NoSelectionNotifier.new),
    ],
    child: MaterialApp.router(
      theme: SkotiqTheme.dark,
      routerConfig: router,
    ),
  );
}

/// The tab keeps a progress spinner alive while its streams are open, so
/// `pumpAndSettle` never returns here.
Future<void> _tapRung2(WidgetTester tester, {required bool populated}) async {
  await tester.pumpWidget(_tab(populated: populated));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));

  await tester.tap(find.text('Track a star'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text('Pick a target'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _tapPickATarget(WidgetTester tester) =>
    _tapRung2(tester, populated: false);

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

  testWidgets("'Pick a target' leads to the imaging screen, not the wizard",
      (tester) async {
    await _tapPickATarget(tester);

    expect(
      find.byType(PhotometricCalibrationWizard),
      findsNothing,
      reason: 'the button says pick a target, not calibrate',
    );
    expect(find.text('IMAGING SCREEN'), findsOneWidget);
  });

  testWidgets('and opens the science HUD so the control is on screen',
      (tester) async {
    await _tapPickATarget(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.text('IMAGING SCREEN')),
    );
    expect(
      container.read(scienceModeStateProvider).scienceHudVisible,
      isTrue,
      reason: 'the target picker lives inside the HUD; arriving with it '
          'hidden is another dead end',
    );
  });

  testWidgets('the populated branch routes rung 2 the same way',
      (tester) async {
    await _tapRung2(tester, populated: true);

    expect(find.text('IMAGING SCREEN'), findsOneWidget);
  });
}
