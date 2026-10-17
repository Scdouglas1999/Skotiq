// "Export report" must carry the period search the operator just ran.
//
// Observed defect: a session with 80 photometry measurements exported a Science
// Report with no light curve and no period analysis at all. The exporter has
// since grown both sections, but the period search is UI state — it is never
// stored — so the report can only contain it if the button hands it over. With
// that hand-off missing the report prints "Not run for this session" while the
// Period Analysis card two inches above the button is showing an LS period, a
// BLS period and a phase fold.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart'
    show dbSessionImagesProvider;
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const int _sessionId = 7;

PeriodAnalysisResult _period() => const PeriodAnalysisResult(
      lombScargle: LombScargleResult(
        frequencies: [1.0, 2.0],
        powers: [0.1, 0.97],
        bestFrequency: 72.0,
        bestPeriod: 0.0138,
        peakPower: 0.97,
        falseAlarmProbability: 1e-11,
        timeBaseline: 0.0823,
        searchedMinPeriod: 0.01,
        searchedMaxPeriod: 0.0823,
      ),
      bls: BlsResult(
        bestPeriod: 0.0139,
        transitDurationFraction: 0.12,
        transitDuration: 0.0017,
        transitDepth: 0.15,
        signalResidueStatistic: 0.02,
        signalDetectionEfficiency: 4.8,
        transitMidPhase: 0.487,
        trialPeriods: [0.01, 0.02],
        srSpectrum: [0.01, 0.02],
      ),
    );

/// Captures what the tab hands the exporter instead of writing a file.
class _RecordingExporter implements ScienceReportExporter {
  PeriodAnalysisResult? seenPeriod;
  int calls = 0;

  @override
  Future<File> exportToDisk(int sessionId,
      {PeriodAnalysisResult? period}) async {
    calls++;
    seenPeriod = period;
    final dir = await Directory.systemTemp.createTemp('sk-report-wiring-');
    final file = File('${dir.path}/session-$sessionId.md');
    await file.writeAsString('stub');
    return file;
  }

  @override
  Future<String> buildMarkdown(int sessionId, {PeriodAnalysisResult? period}) =>
      Future.value('stub');

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Enough stored photometry that the tab renders its populated layout (the
/// all-empty branch has no jump nav and therefore no Export report chip).
List<PhotometryMeasurementRow> _measurements() => [
      for (var i = 0; i < 20; i++)
        PhotometryMeasurementRow(
          id: i + 1,
          sessionId: _sessionId,
          objectId: 'target_primary',
          role: 'target',
          x: 512,
          y: 512,
          flux: 10000 + i * 10,
          differentialMagnitude: -0.30 + i * 0.03,
          snr: 80,
          uncertainty: 0.01,
          isOutlier: false,
          timestamp: DateTime.utc(2026, 8, 1, 5, i),
        ),
    ];

/// Seeds the notifier with a completed run, the state the user is in the
/// moment after pressing "Run Period Search".
class _RanPeriodNotifier extends PeriodAnalysisNotifier {
  @override
  PeriodAnalysisState build() => PeriodAnalysisState(result: _period());
}

ImagingSession _session() => ImagingSession(
      id: _sessionId,
      name: 'Night E - M13',
      startTime: DateTime.utc(2026, 8, 1, 5),
      totalExposures: 0,
      successfulExposures: 0,
      failedExposures: 0,
      totalIntegrationSecs: 0,
      autofocusCount: 0,
      status: 'completed',
    );

Widget _tab(_RecordingExporter exporter) => ProviderScope(
      overrides: [
        allSessionsProvider.overrideWith((ref) => Stream.value([_session()])),
        latestScienceSessionProvider.overrideWith((ref) async => _sessionId),
        sessionPhotometryProvider.overrideWith(
          (ref, id) => Stream.value(_measurements()),
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
        periodAnalysisProvider.overrideWith(_RanPeriodNotifier.new),
        scienceReportExporterProvider.overrideWithValue(exporter),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: ScienceAnalyticsTab()),
      ),
    );

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1600, 2400);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('Export report hands the completed period search to the exporter',
      (tester) async {
    final exporter = _RecordingExporter();
    await tester.pumpWidget(_tab(exporter));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Export report'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(exporter.calls, 1);
    expect(
      exporter.seenPeriod,
      isNotNull,
      reason: 'the report cannot contain a period the button never passed',
    );
    expect(exporter.seenPeriod!.lombScargle.bestPeriod, closeTo(0.0138, 1e-6));
  });
}
