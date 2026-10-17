// A period search belongs to the night it was run on.
//
// `periodAnalysisProvider` is one global result with no session key, and
// nothing dropped it when the operator changed the session under review. The
// Period Analysis card kept rendering the previous night's Lomb-Scargle period,
// and `hasPeriodResult` (science_analytics_tab.dart) kept feeding the Science
// guide, whose "Analyse the period" rung then read `done` for a session that had
// never been searched — the same guide-vs-page contradiction from the other
// direction.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart'
    show dbSessionImagesProvider;
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A genuine result, produced by the real service from a clean 0.5 d sinusoid,
/// so the test never has to hand-build the periodogram structures.
PeriodAnalysisResult _realResult() {
  const service = PeriodAnalysisService();
  final start = DateTime.utc(2026, 7, 25, 21);
  final points = <LightCurvePoint>[
    for (var i = 0; i < 60; i++)
      LightCurvePoint(
        timestamp: start.add(Duration(minutes: i * 30)),
        flux: 10000,
        differentialMagnitude:
            0.2 * math.sin(2 * math.pi * (i * 0.5 / 24.0) / 0.5),
        snr: 80,
        uncertainty: 0.01,
      ),
  ];
  return service.analyze(points: points, minPeriodDays: 0.05, maxPeriodDays: 2);
}

/// Seeds the global provider as if the operator had just pressed Run Period
/// Search on the session they were looking at a moment ago.
class _SeededPeriodNotifier extends PeriodAnalysisNotifier {
  @override
  PeriodAnalysisState build() => PeriodAnalysisState(result: _realResult());
}

class _NoSelectionNotifier extends SciencePhotometrySelectionNotifier {
  @override
  Future<SciencePhotometrySelection> build() async =>
      const SciencePhotometrySelection();
}

ImagingSession _session(int id, String name) => ImagingSession(
      id: id,
      name: name,
      startTime: DateTime.utc(2026, 7, 20 + id, 21),
      totalExposures: 0,
      successfulExposures: 0,
      failedExposures: 0,
      totalIntegrationSecs: 0,
      autofocusCount: 0,
      status: 'completed',
    );

List<PhotometryMeasurementRow> _curve(int sessionId) => [
      for (var i = 0; i < 20; i++)
        PhotometryMeasurementRow(
          id: sessionId * 100 + i,
          sessionId: sessionId,
          objectId: 'V-TEST',
          role: 'target',
          x: 512,
          y: 512,
          flux: 10000 + i * 10,
          differentialMagnitude: -0.30 + i * 0.03,
          snr: 80,
          uncertainty: 0.01,
          isOutlier: false,
          timestamp: DateTime.utc(2026, 7, 20 + sessionId, 21, i),
        ),
    ];

Widget _tab() => ProviderScope(
      overrides: [
        allSessionsProvider.overrideWith(
          (ref) => Stream.value([
            _session(4, 'Night D - V-Test'),
            _session(5, 'Night E - M13'),
          ]),
        ),
        latestScienceSessionProvider.overrideWith((ref) async => 4),
        sessionPhotometryProvider
            .overrideWith((ref, id) => Stream.value(_curve(id))),
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
        sciencePhotometrySelectionProvider
            .overrideWith(_NoSelectionNotifier.new),
        periodAnalysisProvider.overrideWith(_SeededPeriodNotifier.new),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: ScienceAnalyticsTab()),
      ),
    );

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

  testWidgets(
      'changing the reviewed session drops the previous night\'s period',
      (tester) async {
    await tester.pumpWidget(_tab());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ScienceAnalyticsTab)),
    );
    expect(
      container.read(periodAnalysisProvider).result,
      isNotNull,
      reason: 'the seeded result stands in for a search the operator just ran',
    );

    // The session picker at the top of the tab — the production control.
    // Fixed pumps, not pumpAndSettle: the tab hosts continuously animating
    // chart widgets, so the frame queue never drains.
    await tester.tap(find.byType(DropdownButton<int>));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.textContaining('Night E - M13').last);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(
      container.read(periodAnalysisProvider).result,
      isNull,
      reason: 'a period measured on Night D is not Night E\'s result, and it '
          'was marking the guide\'s period rung done for a session that was '
          'never searched',
    );
  });
}
