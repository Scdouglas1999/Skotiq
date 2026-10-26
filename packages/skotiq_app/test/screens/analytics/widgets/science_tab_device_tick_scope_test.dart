import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart'
    show dbSessionImagesProvider;
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_insights_panel.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_surface_explorer.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A camera heartbeat must not rebuild the whole Science tab.
///
/// `cameraStateProvider` re-emits roughly once a second while a camera is
/// connected (cooler temperature, exposure progress, heartbeat). Watching it in
/// the tab's own `build` tore down and rebuilt all nine science sections —
/// every chart, the PSF heatmap, the residual painter — on the screen most
/// likely to be open during a run. Only the equipment-health readout depends on
/// it, so only that readout may rebuild.
class _SelectionNotifier extends SciencePhotometrySelectionNotifier {
  @override
  Future<SciencePhotometrySelection> build() async =>
      const SciencePhotometrySelection();
}

const _sessionId = 11;

ImagingSession _session() => ImagingSession(
      id: _sessionId,
      name: 'Veil night',
      startTime: DateTime(2026, 8, 2, 21),
      totalExposures: 30,
      successfulExposures: 30,
      failedExposures: 0,
      totalIntegrationSecs: 3600,
      autofocusCount: 1,
      status: 'completed',
    );

/// One science product is enough to take the full-layout branch rather than the
/// shared "nothing captured yet" placeholder.
TransparencySampleRow _transparency() => TransparencySampleRow(
      extinctionMeasured: false,
      id: 1,
      sessionId: _sessionId,
      transparencyPercent: 82,
      extinctionCoefficient: 0.21,
      qualityBucket: 'good',
      confidence: 0.9,
      timestamp: DateTime(2026, 8, 2, 22),
    );

List<Override> _overrides() => [
      allSessionsProvider.overrideWith(
        (ref) => Stream.value(<ImagingSession>[_session()]),
      ),
      sessionPhotometryProvider.overrideWith(
        (ref, id) => Stream.value(const <PhotometryMeasurementRow>[]),
      ),
      sessionTransparencySamplesProvider.overrideWith(
        (ref, id) => Stream.value(<TransparencySampleRow>[_transparency()]),
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
      narratorFeedProvider.overrideWith(
        (ref, id) => Stream.value(const <NarratorEvent>[]),
      ),
      sciencePhotometrySelectionProvider.overrideWith(_SelectionNotifier.new),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a camera heartbeat rebuilds only the equipment-health readout',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(),
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: ScienceAnalyticsTab()),
        ),
      ),
    );
    // Not pumpAndSettle: the full-layout branch carries continuous shimmer
    // animations, so the tree never reaches a quiescent state.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Both widgets are rebuilt from scratch by whichever `build` owns them, so
    // instance identity across a pump is an exact record of what rebuilt.
    final explorerBefore = tester.widget(find.byType(ScienceSurfaceExplorer));
    final panelBefore = tester.widget(find.byType(ScienceInsightsPanel));

    // The real heartbeat: `CameraStateNotifier.updateCommunication` is what
    // fires on every successful camera command.
    ProviderScope.containerOf(tester.element(find.byType(ScienceAnalyticsTab)))
        .read(cameraStateProvider.notifier)
        .updateCommunication();
    await tester.pump();

    expect(
      identical(
          tester.widget(find.byType(ScienceSurfaceExplorer)), explorerBefore),
      isTrue,
      reason: 'The camera heartbeat ticks ~1 Hz. Rebuilding the surface '
          'explorer (and with it every chart on the tab) off that tick is the '
          'defect; only the health readout consumes device state.',
    );
    expect(
      identical(tester.widget(find.byType(ScienceInsightsPanel)), panelBefore),
      isFalse,
      reason: 'The health readout must still track device state — scoping the '
          'rebuild must not turn it into a stale snapshot.',
    );
  });
}
