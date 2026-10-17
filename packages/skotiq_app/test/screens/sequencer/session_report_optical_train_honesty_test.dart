// The Session Report must not state an optical-train drift verdict for a
// session whose optical train was never measured.
//
// `OpticalTrainBaseline` (the shape persisted in `session_diagnostics`) is two
// penalty scores and a timestamp — nothing in it records whether either score
// came from a measurement. A penalty of 0 is simultaneously "perfectly flat
// field" and "nothing looked", so reconstructing an `OpticalTrainDiagnostics`
// from that snapshot and handing it to `postSessionOpticalTrainDrift` produced
// a confident "Optical Train Held Steady" for a session with zero PSF tiles and
// zero astrometric residuals.
//
// These tests drive the REAL chain — science rows → `psfTilesForSessionProvider`
// / `residualVectorsForSessionProvider` → `opticalTrainDiagnosticsProvider` →
// `OpticalTrainDiagnosticsService.analyze` → the dialog's reconstruction → the
// rendered issue tiles. Only the leaf science-row streams and the persisted
// snapshot are faked, so removing the `tiltMeasured` / `collimationMeasured`
// arguments from the dialog's reconstruction (or the gate they feed) fails
// here rather than passing on hand-made arguments.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/session_report_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const int _sessionId = 4242;

/// The report body itself is irrelevant to these tests — the diagnostics
/// section reads only `report.sessionId`.
SessionReport _report() => SessionReport(
      sessionId: _sessionId,
      sessionName: 'Optical honesty',
      status: 'completed',
      startTime: DateTime.utc(2026, 1, 1, 22),
      endTime: DateTime.utc(2026, 1, 2, 1),
      wallClockDuration: const Duration(hours: 3),
      totalIntegration: const Duration(minutes: 10),
      effectiveImagingFraction: 10 / 180,
      downtime: const Duration(hours: 2, minutes: 50),
      targets: const [
        SessionTargetReport(
          targetId: 1,
          targetName: 'M42',
          filters: [
            SessionFilterReport(
              filter: 'L',
              framesAttempted: 4,
              framesAccepted: 4,
              framesRejected: 0,
              totalIntegrationSecs: 600,
              meanHfr: 2.4,
              meanFwhm: 5.6,
              meanStarCount: 400,
              meanSnr: 20,
              meanGuidingRmsTotal: 0.6,
              meanSensorTemp: -10,
              rejectionReasons: {},
            ),
          ],
        ),
      ],
      guideStats: const SessionGuideStats(
        meanRmsRaArcsec: 0.5,
        meanRmsDecArcsec: 0.4,
        meanRmsTotalArcsec: 0.6,
        maxRmsRaArcsec: 0.9,
        maxRmsDecArcsec: 0.7,
        maxRmsTotalArcsec: 1.1,
        percentUnguidedFrames: 0.0,
      ),
      mountStats: const SessionMountStats(
        autofocusRuns: 1,
        meridianFlips: 0,
        ditherCount: 4,
        triggerFires: 0,
      ),
      avgTemperatureC: null,
      avgHumidityPercent: null,
      avgSeeingArcsec: null,
      notes: null,
      errorMessages: const [],
      warningMessages: const [],
      generatedAt: DateTime.utc(2026, 1, 2, 2),
    );

class _FakeAppSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

PsfFieldTileRow _tile({
  required int id,
  required int row,
  required int col,
  required double hfr,
}) {
  return PsfFieldTileRow(
    id: id,
    sessionId: _sessionId,
    tileRow: row,
    tileCol: col,
    starCount: 40,
    medianFwhm: hfr * 2.35,
    medianHfr: hfr,
    medianEccentricity: 0.1,
    roundness: 0.92,
    timestamp: _rowTime,
  );
}

AstrometryResidualVectorRow _residual({
  required int id,
  required double x,
  required double y,
  required double magnitude,
}) {
  return AstrometryResidualVectorRow(
    id: id,
    sessionId: _sessionId,
    x: x,
    y: y,
    dxArcsec: magnitude,
    dyArcsec: 0,
    magnitudeArcsec: magnitude,
    timestamp: _rowTime,
  );
}

/// Every science row above carries this timestamp.
final _rowTime = DateTime.utc(2026, 1, 1, 23);

/// A baseline captured AFTER the science rows, i.e. one whose scores really
/// were derived from them. This is the default so the tests below isolate the
/// near operand; `_baselineBeforeRows` isolates the far one.
final _baselineAfterRows = DateTime.utc(2026, 1, 2, 0);

/// A baseline captured BEFORE any science row existed: its 0/0 scores are
/// placeholders no matter how well the session went on to measure itself.
final _baselineBeforeRows = DateTime.utc(2026, 1, 1, 22);

/// Both snapshots identical: any drift blend over them is exactly 0, i.e. well
/// under the 8.0 default threshold. So whenever the dialog considers the
/// comparison valid it renders "Optical Train Held Steady" — the exact false
/// reassurance under test.
OpticalTrainBaseline _snapshot(DateTime capturedAt) => OpticalTrainBaseline(
      tiltScore: 0,
      collimationScore: 0,
      capturedAt: capturedAt,
    );

Future<void> _pumpReport(
  WidgetTester tester, {
  required List<PsfFieldTileRow> psfTiles,
  required List<AstrometryResidualVectorRow> residuals,
  DateTime? baselineCapturedAt,
}) async {
  final report = _report();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionReportProvider(_sessionId).overrideWith((ref) async => report),
        appSettingsProvider.overrideWith(_FakeAppSettings.new),
        recoveryHistoryForSessionProvider(_sessionId)
            .overrideWith((ref) async => const []),
        // A run that DID record pre/post snapshots. Without the measured
        // flags this pair is indistinguishable from a flawless optical train.
        opticalTrainSnapshotForSessionProvider(_sessionId).overrideWith(
          (ref) async => SessionOpticalTrainSnapshot(
            baseline: _snapshot(baselineCapturedAt ?? _baselineAfterRows),
            current: _snapshot(DateTime.utc(2026, 1, 2, 1)),
          ),
        ),
        // Leaf science rows — the only fake in the diagnostics chain.
        sessionPsfTilesProvider(_sessionId)
            .overrideWith((ref) => Stream.value(psfTiles)),
        sessionResidualVectorsProvider(_sessionId)
            .overrideWith((ref) => Stream.value(residuals)),
        notesForTargetProvider('M42')
            .overrideWith((ref) => const Stream<List<JournalNote>>.empty()),
        sessionInsightsProvider(_sessionId)
            .overrideWith((ref) async => const <SessionInsight>[]),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => SessionReportDialog.show(ctx, _sessionId),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  // Not `pumpAndSettle`: a Drift-backed stream watched further down the dialog
  // keeps a periodic timer alive, so the tree never reaches steady state.
  // Bounded pumps drive the dialog past its open transition and let the
  // overridden futures/streams publish.
  //
  // The diagnostics section is a three-deep async cascade — settings, then the
  // persisted snapshot, then the science-row streams are each only WATCHED
  // once the level above it has data — so it needs one frame per level.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a session with no PSF tiles or residuals gets no drift verdict',
    (tester) async {
      await _pumpReport(tester, psfTiles: const [], residuals: const []);

      expect(
        find.text('Optical Train Held Steady'),
        findsNothing,
        reason: 'nothing measured this train, so nothing may vouch for it',
      );
      expect(find.text('Optical Train Drifted During Session'), findsNothing);
      expect(find.text('Optical Train Drift Not Measured'), findsOneWidget);
      expect(
        find.textContaining('Field tilt and collimation were not measured'),
        findsOneWidget,
        reason: 'the report must name which axes had no data behind them',
      );
    },
  );

  testWidgets(
    'a tile grid with no residuals still blocks the verdict on collimation',
    (tester) async {
      // A 2x2 PSF grid measures tilt, but with no residual vectors the
      // edge-versus-centre ratio is a clamp floor, not a measurement.
      await _pumpReport(
        tester,
        psfTiles: [
          _tile(id: 1, row: 0, col: 0, hfr: 2.4),
          _tile(id: 2, row: 0, col: 1, hfr: 2.5),
          _tile(id: 3, row: 1, col: 0, hfr: 2.45),
          _tile(id: 4, row: 1, col: 1, hfr: 2.55),
        ],
        residuals: const [],
      );

      expect(find.text('Optical Train Held Steady'), findsNothing);
      expect(find.text('Optical Train Drift Not Measured'), findsOneWidget);
      expect(
        find.textContaining('Collimation was not measured'),
        findsOneWidget,
        reason: 'tilt WAS measured — only collimation may be called missing',
      );
      expect(
        find.textContaining('Field tilt'),
        findsNothing,
        reason: 'naming a measured axis as missing is its own false claim',
      );
    },
  );

  testWidgets(
    'a baseline captured before any science row gets no drift verdict',
    (tester) async {
      // The session measured itself thoroughly — but only AFTER the baseline
      // snapshot was taken, so the baseline's 0/0 is a placeholder and the
      // subtraction would invent the entire delta. Gating only the
      // post-session end of the comparison misses this.
      await _pumpReport(
        tester,
        baselineCapturedAt: _baselineBeforeRows,
        psfTiles: _measuredTiles(),
        residuals: _measuredResiduals(),
      );

      expect(find.text('Optical Train Held Steady'), findsNothing);
      expect(find.text('Optical Train Drifted During Session'), findsNothing);
      expect(find.text('Optical Train Drift Not Measured'), findsOneWidget);
    },
  );

  testWidgets(
    'a fully measured session still reports the drift verdict',
    (tester) async {
      // Guards against the opposite failure: a gate that suppresses the
      // verdict unconditionally would also pass every test above.
      await _pumpReport(
        tester,
        psfTiles: _measuredTiles(),
        residuals: _measuredResiduals(),
      );

      expect(find.text('Optical Train Held Steady'), findsOneWidget);
      expect(find.text('Optical Train Drift Not Measured'), findsNothing);
    },
  );
}

/// A 2x2 grid — two columns and two rows, so there is an across-field gradient
/// to measure.
List<PsfFieldTileRow> _measuredTiles() => [
      _tile(id: 1, row: 0, col: 0, hfr: 2.4),
      _tile(id: 2, row: 0, col: 1, hfr: 2.5),
      _tile(id: 3, row: 1, col: 0, hfr: 2.45),
      _tile(id: 4, row: 1, col: 1, hfr: 2.55),
    ];

/// Residuals on both sides of the 0.25/0.75 edge-versus-centre split, so the
/// collimation ratio has a real denominator.
List<AstrometryResidualVectorRow> _measuredResiduals() => [
      _residual(id: 1, x: 0.05, y: 0.5, magnitude: 0.8),
      _residual(id: 2, x: 0.95, y: 0.5, magnitude: 0.9),
      _residual(id: 3, x: 0.5, y: 0.5, magnitude: 0.7),
      _residual(id: 4, x: 0.45, y: 0.55, magnitude: 0.75),
    ];
