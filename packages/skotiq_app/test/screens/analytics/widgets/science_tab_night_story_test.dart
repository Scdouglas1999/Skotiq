import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart'
    show dbSessionImagesProvider;
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The night's story is not a science product and must not be hidden with them.
///
/// The Science tab collapses to a single shared placeholder when every science
/// table is empty. That branch dropped the NIGHT STORY timeline — and with it
/// every narrator detail sheet — so the operator it exists for (imaged all
/// night, no plate solver, therefore no photometry, no PSF tiles, no
/// calibrations) was exactly the operator whose narrator feed was suppressed.
class _SelectionNotifier extends SciencePhotometrySelectionNotifier {
  @override
  Future<SciencePhotometrySelection> build() async =>
      const SciencePhotometrySelection();
}

const _sessionId = 7;

ImagingSession _session() => ImagingSession(
      id: _sessionId,
      name: 'Andromeda night',
      startTime: DateTime(2026, 6, 11, 21),
      totalExposures: 40,
      successfulExposures: 40,
      failedExposures: 0,
      totalIntegrationSecs: 4800,
      autofocusCount: 2,
      status: 'completed',
    );

NarratorEvent _event() => NarratorEvent(
      id: 1,
      sessionId: _sessionId,
      timestamp: DateTime(2026, 6, 11, 22, 15),
      eventType: 'quality.hfr_drift',
      category: NarratorCategory.quality,
      severity: NarratorSeverity.info,
      headline: 'Focus held steady through the meridian flip',
      dedupeKey: 'k1',
    );

/// Every science product empty; the narrator feed is not.
List<Override> _overrides({List<NarratorEvent> narratorEvents = const []}) => [
      allSessionsProvider.overrideWith(
        (ref) => Stream.value(<ImagingSession>[_session()]),
      ),
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
        (ref, id) => Stream.value(const <ScienceFrameQualityMetricsRow>[]),
      ),
      sessionTileMetricsProvider.overrideWith(
        (ref, id) => Stream.value(const <ScienceTileMetricRow>[]),
      ),
      dbSessionImagesProvider.overrideWith(
        (ref, id) => Stream.value(const <DbCapturedImage>[]),
      ),
      narratorFeedProvider.overrideWith(
        (ref, id) => Stream.value(narratorEvents),
      ),
      sciencePhotometrySelectionProvider.overrideWith(_SelectionNotifier.new),
    ];

Future<void> _pumpTab(WidgetTester tester, List<Override> overrides) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: ScienceAnalyticsTab()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a session with no science products still tells its story',
      (tester) async {
    await _pumpTab(tester, _overrides(narratorEvents: [_event()]));

    expect(
      find.text('NIGHT STORY'),
      findsOneWidget,
      reason: 'The narrator feed is the only account of the night for a rig '
          'with no plate solver; the empty-science branch hid it entirely.',
    );
    expect(
      find.text('Focus held steady through the meridian flip'),
      findsOneWidget,
    );
  });

  testWidgets('the section is present even with nothing to tell yet',
      (tester) async {
    await _pumpTab(tester, _overrides());

    // The timeline renders its own empty state; the heading must not blink in
    // and out depending on whether a science table happens to have rows.
    expect(find.text('NIGHT STORY'), findsOneWidget);
  });
}
