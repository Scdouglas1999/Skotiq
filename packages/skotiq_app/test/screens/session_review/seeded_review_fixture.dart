// Shared seeded fixture for the narrative + workbench view tests/goldens.
//
// Both `NarrativeView` and `WorkbenchView` read the single
// `sessionReviewControllerProvider(scope)` and hand the resolved
// `SessionReviewController` to their child panels (`SubCullRail`,
// `AbComparePanel`). To render them with a *full* Morning Report — a master
// hero, a multi-severity Night Doctor report, an improvement curve with a
// marked cut, a multi-night growth series, a best-night badge and a catalog
// annotation layer — without a live native pipeline, this fixture overrides the
// provider with a [SeededReviewController]: a real [SessionReviewController]
// (so the child panels' `SessionReviewController`-typed params type-check)
// whose smart-data load is replaced by an in-memory seed.
//
// The base controller's constructor still runs its `_load()` against the
// supplied in-memory database (empty → settles `loading:false` with no subs),
// then calls `loadSmartData()`, which this subclass overrides to publish the
// complete seeded [SessionReviewState]. Every long-running action is a no-op so
// pumping the views never touches the native seam.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
// Hide the core service's `BestNight`/`IntegrationGrowthPoint`: this fixture
// builds the controller's UI-facing `BestNight`/`GrowthPoint` (hours-based),
// which the panels read.
import 'package:skotiq_core/skotiq_core.dart' hide BestNight;

/// A [PostSessionSeam] whose progress stream is empty and whose other members
/// throw — the seeded controller never invokes them.
class FakeReviewSeam implements PostSessionSeam {
  @override
  Stream<({String phase, double fraction})> integrationProgress() =>
      const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '${invocation.memberName} not stubbed in seeded review fixture');
}

/// A representative finished-master hero outcome. The [previewPath] points at
/// the on-disk PNG the [MasterOverlayView] hero loads; pass the path of a
/// synthesized sample PNG.
PostSessionIntegrationOutcome seededOutcome({
  required String previewPath,
  String? rejectionMapPath,
}) {
  return PostSessionIntegrationOutcome(
    masterId: 1,
    filter: 'Ha',
    result: IntegrateSessionResult(
      masterFitsPath: '/tmp/seed/master.fits',
      previewPath: previewPath,
      rejectionMapPath: rejectionMapPath,
      framesIntegrated: 58,
      framesRejected: 6,
      totalIntegrationSec: 58 * 120.0,
      rmsResidual: 0.41,
      width: 400,
      height: 300,
      channels: 1,
      perFrameStats: const [],
    ),
  );
}

/// A representative multi-severity Night Doctor verdict (critical + warn + info,
/// each with evidence subs, advice and a backing metric series).
NightReport seededNightReport() {
  return NightReport(
    score: 72,
    headline: 'Solid night — focus drifted late, but most subs are keepers.',
    createdAt: DateTime.utc(2026, 6, 7, 5, 30),
    findings: const [
      NightFinding(
        id: 'cloud_intrusion',
        severity: NightFindingSeverity.critical,
        title: 'Clouds cost 6 subs',
        explanation:
            'Background flux spiked between 03:10 and 03:40 — six subs show '
            'washed-out backgrounds and dropped star counts consistent with '
            'thin high cloud passing through.',
        advice:
            'check the all-sky forecast and pause acquisition when transparency '
            'drops below 70%.',
        evidenceSubIds: [41, 42, 43, 44, 45, 46],
        metricSeries: [
          120,
          118,
          121,
          119,
          240,
          280,
          260,
          255,
          130,
          122,
          119,
          120
        ],
      ),
      NightFinding(
        id: 'focus_drift',
        severity: NightFindingSeverity.warn,
        title: 'Focus drifted as the night cooled',
        explanation:
            'Median HFR rose from 2.1px to 3.0px over four hours, tracking the '
            'temperature drop. No autofocus run fired after midnight.',
        advice: 'enable temperature-triggered autofocus at a 1.5°C delta.',
        evidenceSubIds: [58, 59, 60, 61],
        metricSeries: [2.1, 2.2, 2.2, 2.4, 2.5, 2.7, 2.8, 3.0],
      ),
      NightFinding(
        id: 'guiding_good',
        severity: NightFindingSeverity.info,
        title: 'Guiding was excellent',
        explanation:
            'Total RMS held at 0.42" for the whole session with no spikes — '
            'mount and seeing cooperated.',
        evidenceSubIds: [],
        metricSeries: [0.45, 0.41, 0.43, 0.40, 0.42, 0.41, 0.42],
      ),
    ],
  );
}

/// A representative marginal-SNR improvement curve with a clear knee and a
/// recommended cut at `keepN = 46` of 64 (a real predicted SNR gain).
IntegrationCurve seededImprovementCurve() {
  const total = 64;
  const keepN = 46;
  final points = <IntegrationCurvePoint>[
    for (var n = 1; n <= total; n++)
      IntegrationCurvePoint(
        n: n,
        // Square-root SNR growth with a gentle tail roll-off past the knee.
        snr:
            10.0 * _sqrt(n.toDouble()) - (n > keepN ? (n - keepN) * 0.18 : 0.0),
        fwhm: 2.0 + (n / total) * 0.6,
        cumulativeIntegrationS: n * 120.0,
      ),
  ];
  return IntegrationCurve(
    points: points,
    recommendation: SubsetRecommendation(
      keepN: keepN,
      keptIndices: [for (var i = 0; i < keepN; i++) i],
      predictedSnrGainPct: 4.2,
      reason: 'Dropping the 18 weakest subs lifts predicted SNR by 4.2%.',
    ),
  );
}

double _sqrt(double v) {
  // A tiny Newton sqrt to avoid importing dart:math into a fixture used by
  // both pure-widget and provider-backed tests.
  if (v <= 0) return 0;
  var x = v;
  for (var i = 0; i < 20; i++) {
    x = 0.5 * (x + v / x);
  }
  return x;
}

/// A representative four-night cumulative-integration growth series.
List<GrowthPoint> seededGrowthPoints() {
  return [
    GrowthPoint(
      date: DateTime.utc(2026, 5, 30),
      cumulativeHours: 1.9,
      framesToDate: 57,
    ),
    GrowthPoint(
      date: DateTime.utc(2026, 6, 2),
      cumulativeHours: 3.6,
      framesToDate: 108,
    ),
    GrowthPoint(
      date: DateTime.utc(2026, 6, 5),
      cumulativeHours: 5.1,
      framesToDate: 153,
    ),
    GrowthPoint(
      date: DateTime.utc(2026, 6, 7),
      cumulativeHours: 7.0,
      framesToDate: 210,
    ),
  ];
}

/// The standout night to badge (the 2026-06-05 session).
BestNight seededBestNight() {
  return BestNight(
    date: DateTime.utc(2026, 6, 5),
    meanWeight: 0.94,
    frameCount: 45,
    integrationHours: 1.5,
  );
}

/// A representative catalog annotation layer over the 400×300 hero.
AnnotationLayer seededAnnotationLayer() {
  return const AnnotationLayer(
    width: 400,
    height: 300,
    items: [
      Annotation(
        label: 'NGC 7000',
        x: 120,
        y: 90,
        kind: AnnotationKind.nebula,
        sizePx: 70,
        paDeg: 30,
      ),
      Annotation(
        label: 'M31',
        x: 280,
        y: 200,
        kind: AnnotationKind.galaxy,
        sizePx: 50,
      ),
      Annotation(
        label: 'Deneb',
        x: 200,
        y: 60,
        kind: AnnotationKind.star,
        sizePx: 8,
      ),
    ],
  );
}

/// A narrowband-flavoured filter so [SessionReviewState.narrowbandChannels]
/// surfaces a channel for the workbench mixer.
IntegratedMaster seededMaster() {
  return IntegratedMaster(
    id: 1,
    targetId: 1,
    name: 'NGC 7000 master',
    masterFitsPath: '/tmp/seed/master.fits',
    previewPngPath: '/tmp/seed/master_preview.png',
    sidecarPath: null,
    rejectionMapPath: null,
    status: IntegratedMasterStatus.finalized,
    accumulationMode: AccumulationMode.batch,
    channels: 1,
    width: 400,
    height: 300,
    frameCount: 58,
    totalIntegrationSeconds: 58 * 120.0,
    filter: 'Ha',
    settingsJson: '{}',
    statsJson: '{}',
    createdAt: DateTime.utc(2026, 6, 7, 5, 0),
    updatedAt: DateTime.utc(2026, 6, 7, 5, 0),
  );
}

/// A fully-seeded [SessionReviewController] for the view tests/goldens.
///
/// Extends the real controller so panels typed on `SessionReviewController`
/// accept it. The inherited constructor runs `_load()` against the (empty)
/// in-memory database, then calls [loadSmartData]; this override publishes the
/// complete seeded state instead of querying the smart services. Every action
/// is a no-op so pumping the views never reaches the native seam.
class SeededReviewController extends SessionReviewController {
  SeededReviewController(super.ref, super.scope, {required this.previewPath});

  /// On-disk hero preview PNG path the seeded outcome points at.
  final String previewPath;

  @override
  Future<void> loadSmartData({bool recomputeNightReport = false}) async {
    state = state.copyWith(
      loading: false,
      loadingSmartData: false,
      title: 'NGC 7000',
      targetId: 1,
      targetName: 'NGC 7000',
      masters: [seededMaster()],
      // The reviewed master is now an explicit, scope-resolved field rather than
      // "newest row in the library" — the seed states it.
      reviewedMaster: seededMaster(),
      lastOutcome: seededOutcome(previewPath: previewPath),
      nightReport: seededNightReport(),
      improvementCurve: seededImprovementCurve(),
      growthPoints: seededGrowthPoints(),
      bestNight: seededBestNight(),
      annotationLayer: seededAnnotationLayer(),
    );
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<PostSessionIntegrationOutcome?> integrate() async => null;

  @override
  Future<PostSessionIntegrationOutcome?> reIntegrate(
          IntegrationSettings settings) async =>
      null;

  @override
  Future<PostSessionIntegrationOutcome?> reIntegratePreview(
          IntegrationSettings settings) async =>
      null;

  @override
  Future<String?> runColorCalibration() async => null;

  @override
  Future<String?> runBackgroundExtraction() async => null;

  @override
  Future<String?> runDeconvolve() async => null;

  @override
  Future<String?> runStarReduction() async => null;

  @override
  Future<String?> runNarrowband(
    String palette,
    List<List<double>> weights, {
    List<NarrowbandChannelRef>? channels,
  }) async =>
      null;

  @override
  Future<CullToRecommendedResult> cullToRecommended() async =>
      CullToRecommendedResult.staleCurve;
}

/// Build the provider overrides that mount a [SeededReviewController] for
/// [scope], wired to [db] (in-memory) and a fake seam.
List<Override> seededReviewOverrides({
  required SkotiqDatabase db,
  required SessionReviewScope scope,
  required String previewPath,
}) {
  return [
    databaseProvider.overrideWithValue(db),
    postSessionSeamProvider.overrideWithValue(FakeReviewSeam()),
    sessionReviewControllerProvider(scope).overrideWith(
      (ref) => SeededReviewController(ref, scope, previewPath: previewPath),
    ),
  ];
}
