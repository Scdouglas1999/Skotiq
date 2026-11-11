// Pins the results of the night-report, narrowband-composite, campaign and
// stacked-result DAOs on a seeded database: reads on an empty table, null
// columns, ORDER BY ties broken by id, and the rows each write leaves behind.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/campaigns_dao.dart';
import 'package:skotiq_core/src/database/daos/narrowband_composites_dao.dart';
import 'package:skotiq_core/src/database/daos/night_reports_dao.dart';
import 'package:skotiq_core/src/database/daos/stacked_results_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/campaign.dart';
import 'package:skotiq_core/src/models/imaging/narrowband_composite.dart';
import 'package:skotiq_core/src/models/imaging/night_report.dart';
import 'package:skotiq_core/src/models/imaging/stack_and_share_models.dart';
import 'package:skotiq_core/src/services/live_stacking_service.dart';

import 'pin_harness.dart';

Object? _encode(Object value) => switch (value) {
  NightReport r => {
    'sessionId': r.sessionId,
    'targetId': r.targetId,
    'score': r.score,
    'headline': r.headline,
    'findings': r.findings,
    'createdAt': r.createdAt,
  },
  NightFinding f => {
    'id': f.id,
    'severity': f.severity,
    'title': f.title,
    'explanation': f.explanation,
    'evidenceSubIds': f.evidenceSubIds,
    'advice': f.advice,
    'metricSeries': f.metricSeries,
  },
  NarrowbandComposite c => {
    'id': c.id,
    'targetId': c.targetId,
    'palette': c.palette,
    'componentMasterIds': c.componentMasterIds,
    'outputPath': c.outputPath,
    'width': c.width,
    'height': c.height,
    'createdAt': c.createdAt,
  },
  Campaign c => {
    'id': c.id,
    'targetId': c.targetId,
    'filter': c.filter,
    'acceptedCount': c.acceptedCount,
    'desiredCount': c.desiredCount,
    'lastCaptureAt': c.lastCaptureAt,
    'createdAt': c.createdAt,
    'updatedAt': c.updatedAt,
  },
  StackAndShareResult r => {
    'id': r.id,
    'sessionId': r.sessionId,
    'targetId': r.targetId,
    'targetName': r.targetName,
    'width': r.width,
    'height': r.height,
    'framesStacked': r.framesStacked,
    'framesAttempted': r.framesAttempted,
    'integrationSecs': r.integrationSecs,
    'avgAlignmentResidual': r.avgAlignmentResidual,
    'avgHfr': r.avgHfr,
    'filter': r.filter,
    'isColor': r.isColor,
    'channels': r.channels,
    'createdAt': r.createdAt,
    'exportedImagePath': r.exportedImagePath,
    'stats': r.stats,
  },
  LiveStackingStats s => {
    'stackedFrameCount': s.stackedFrameCount,
    'totalFramesAttempted': s.totalFramesAttempted,
    'rejectedAlignmentFailures': s.rejectedAlignmentFailures,
    'avgMatchedPairs': s.avgMatchedPairs,
    'avgAlignmentResidual': s.avgAlignmentResidual,
    'totalSigmaRejectedPixels': s.totalSigmaRejectedPixels,
  },
  _ => null,
};

void main() {
  late SkotiqDatabase db;
  late PinSeed seed;

  setUp(() async {
    db = openPinDatabase();
    seed = await PinSeed.create(db);
  });

  tearDown(() => db.close());

  test('NightReportsDao results are pinned', () async {
    final pins = PinRecorder('night_reports_dao', encode: _encode);
    final dao = NightReportsDao(db);
    final s0 = seed.sessions[0];
    final t0 = seed.targets[0];

    await pins('empty getById', () => dao.getById(1));
    await pins('empty getForSession', () => dao.getForSession(s0));
    await pins('empty latestForSession', () => dao.latestForSession(s0));

    await pins(
      'insert full',
      () => dao.insertReport(
        sessionId: s0,
        targetId: t0,
        score: 71,
        headline: 'Guiding drifted after midnight',
        findings: const [
          NightFinding(
            id: 'guide',
            severity: NightFindingSeverity.warn,
            title: 'Guiding',
            explanation: 'RMS doubled',
            evidenceSubIds: [3, 4],
            advice: 'Balance the mount',
            metricSeries: [0.5, 1.25],
          ),
        ],
        createdAt: pinT(10),
      ),
    );
    await pins(
      'insert tie',
      () => dao.insertReport(
        sessionId: s0,
        score: 40,
        headline: 'Same minute',
        createdAt: pinT(10),
      ),
    );
    await pins(
      'insert nulls',
      () => dao.insertReport(score: 0, headline: '', createdAt: pinT(5)),
    );
    await pins(
      'insert other target',
      () => dao.insertReport(
        sessionId: seed.sessions[1],
        targetId: t0,
        score: 90,
        headline: 'Clean',
        createdAt: pinT(20),
      ),
    );
    await pins(
      'insert default time',
      () =>
          dao.insertReport(targetId: seed.targets[1], score: 1, headline: 'x'),
    );
    await pins.dump(db, 'night_reports', 'after inserts');

    await pins('getById 1', () => dao.getById(1));
    await pins('getById 3 nulls', () => dao.getById(3));
    await pins('getById missing', () => dao.getById(99));
    await pins('getForSession s0', () => dao.getForSession(s0));
    await pins('getForSession s1', () => dao.getForSession(seed.sessions[1]));
    await pins('getForTarget t0', () => dao.getForTarget(t0));
    await pins('getForTarget t2', () => dao.getForTarget(seed.targets[2]));
    await pins('latestForSession s0', () => dao.latestForSession(s0));

    await pins('delete 2', () => dao.deleteReport(2));
    await pins('delete missing', () => dao.deleteReport(2));
    await pins.dump(db, 'night_reports', 'after delete');

    await db.customStatement(
      "UPDATE night_reports SET findings_json = 'not json' WHERE id = 1",
    );
    await pins('getById corrupt findings', () => dao.getById(1));
    pins.verify();
  });

  test('NarrowbandCompositesDao results are pinned', () async {
    final pins = PinRecorder('narrowband_composites_dao', encode: _encode);
    final dao = NarrowbandCompositesDao(db);
    final t0 = seed.targets[0];

    await pins('empty getAll', dao.getAll);
    await pins('empty getById', () => dao.getById(1));
    await pins('empty getForTarget', () => dao.getForTarget(t0));

    await pins(
      'insert full',
      () => dao.insertComposite(
        targetId: t0,
        palette: 'SHO',
        componentMasterIds: const [4, 2, 9],
        outputPath: '/out/sho.tif',
        width: 6248,
        height: 4176,
        createdAt: pinT(30),
      ),
    );
    await pins(
      'insert tie',
      () => dao.insertComposite(
        targetId: t0,
        palette: 'HOO',
        componentMasterIds: const [],
        outputPath: '/out/hoo.tif',
        createdAt: pinT(30),
      ),
    );
    await pins(
      'insert no target',
      () => dao.insertComposite(
        palette: '',
        componentMasterIds: const [1],
        outputPath: '/out/x.tif',
        createdAt: pinT(1),
      ),
    );
    await pins(
      'insert default time',
      () => dao.insertComposite(
        targetId: seed.targets[1],
        palette: 'RGB',
        componentMasterIds: const [7],
        outputPath: '/out/now.tif',
      ),
    );
    await pins.dump(db, 'narrowband_composites', 'after inserts');

    await pins('getAll', dao.getAll);
    await pins('getById 3', () => dao.getById(3));
    await pins('getById missing', () => dao.getById(42));
    await pins('getForTarget t0', () => dao.getForTarget(t0));
    await pins('getForTarget t2', () => dao.getForTarget(seed.targets[2]));
    await pins('delete 1', () => dao.deleteComposite(1));
    await pins('delete missing', () => dao.deleteComposite(1));
    await pins.dump(db, 'narrowband_composites', 'after delete');
    pins.verify();
  });

  test('CampaignsDao results are pinned', () async {
    final pins = PinRecorder('campaigns_dao', encode: _encode);
    final dao = CampaignsDao(db);
    final t0 = seed.targets[0];
    final t1 = seed.targets[1];

    await pins('empty getForTarget', () => dao.getForTarget(t0));
    await pins(
      'empty getForTargetFilter',
      () => dao.getForTargetFilter(t0, 'L'),
    );
    await pins('empty remaining', () => dao.remaining(t0, 'L'));

    await pins(
      'upsertDesired new',
      () => dao.upsertDesired(
        targetId: t0,
        filter: 'Ha',
        desiredCount: 30,
        now: pinT(1),
      ),
    );
    await pins(
      'upsertDesired same pair other case',
      () => dao.upsertDesired(
        targetId: t0,
        filter: 'HA',
        desiredCount: 40,
        now: pinT(2),
      ),
    );
    await pins(
      'recordAccepted existing',
      () => dao.recordAccepted(
        targetId: t0,
        filter: 'ha',
        delta: 3,
        capturedAt: pinT(3),
      ),
    );
    await pins(
      'recordAccepted zero delta',
      () => dao.recordAccepted(targetId: t0, filter: 'Ha', delta: 0),
    );
    await pins(
      'recordAccepted negative delta',
      () => dao.recordAccepted(targetId: t0, filter: 'Ha', delta: -2),
    );
    await pins(
      'recordAccepted creates',
      () => dao.recordAccepted(
        targetId: t0,
        filter: 'B',
        delta: 50,
        capturedAt: pinT(4),
      ),
    );
    await pins(
      'recordAccepted default time',
      () => dao.recordAccepted(targetId: t1, filter: 'L'),
    );
    await pins(
      'upsertDesired default time',
      () => dao.upsertDesired(targetId: t1, filter: 'R', desiredCount: 5),
    );
    await pins(
      'upsertDesired after accepted',
      () => dao.upsertDesired(
        targetId: t0,
        filter: 'b',
        desiredCount: 20,
        now: pinT(6),
      ),
    );
    await pins.dump(db, 'campaigns', 'after writes');

    await pins('getForTarget t0', () => dao.getForTarget(t0));
    await pins('getForTarget t1', () => dao.getForTarget(t1));
    await pins(
      'getForTargetFilter case',
      () => dao.getForTargetFilter(t0, 'hA'),
    );
    await pins(
      'getForTargetFilter missing',
      () => dao.getForTargetFilter(t1, 'Ha'),
    );
    await pins('remaining Ha', () => dao.remaining(t0, 'Ha'));
    await pins('remaining B over goal', () => dao.remaining(t0, 'B'));
    await pins('remaining missing', () => dao.remaining(t0, 'OIII'));
    pins.verify();
  });

  test('StackedResultsDao results are pinned', () async {
    final pins = PinRecorder('stacked_results_dao', encode: _encode);
    final dao = StackedResultsDao(db);
    final s0 = seed.sessions[0];

    await pins('empty getResultById', () => dao.getResultById(1));
    await pins(
      'empty getResultsForSession',
      () => dao.getResultsForSession(s0),
    );
    await pins('empty getRecentResults', () => dao.getRecentResults());
    await pins('getRecentResults zero', () => dao.getRecentResults(limit: 0));

    await pins(
      'insert full',
      () => dao.insertResult(
        StackAndShareResult(
          id: 77,
          sessionId: s0,
          targetId: seed.targets[0],
          targetName: 'M31',
          width: 3000,
          height: 2000,
          framesStacked: 41,
          framesAttempted: 45,
          integrationSecs: 4920,
          avgAlignmentResidual: 0.42,
          avgHfr: 2.1,
          filter: 'L',
          isColor: true,
          channels: 3,
          createdAt: pinT(50),
          exportedImagePath: '/share/m31.jpg',
          stats: const LiveStackingStats(
            stackedFrameCount: 1,
            avgMatchedPairs: 9,
          ),
        ),
      ),
    );
    await pins(
      'insert nulls',
      () => dao.insertResult(
        StackAndShareResult(
          width: 10,
          height: 20,
          framesStacked: 0,
          framesAttempted: 0,
          integrationSecs: 0,
          avgAlignmentResidual: 0,
          createdAt: pinT(50),
        ),
      ),
    );
    await pins(
      'insert session tie',
      () => dao.insertResult(
        StackAndShareResult(
          sessionId: s0,
          width: 1,
          height: 1,
          framesStacked: 2,
          framesAttempted: 3,
          integrationSecs: 60.5,
          avgAlignmentResidual: 1,
          createdAt: pinT(50),
        ),
      ),
    );
    await pins(
      'insert older',
      () => dao.insertResult(
        StackAndShareResult(
          sessionId: seed.sessions[1],
          width: 5,
          height: 5,
          framesStacked: 5,
          framesAttempted: 5,
          integrationSecs: 5,
          avgAlignmentResidual: 0.5,
          createdAt: pinT(-5),
        ),
      ),
    );
    await pins.dump(db, 'stacked_results', 'after inserts');

    await pins('getResultById 1', () => dao.getResultById(1));
    await pins('getResultById 2 nulls', () => dao.getResultById(2));
    await pins('getResultById missing', () => dao.getResultById(9));
    await pins('getResultsForSession s0', () => dao.getResultsForSession(s0));
    await pins('getRecentResults 2', () => dao.getRecentResults(limit: 2));
    await pins('getRecentResults all', () => dao.getRecentResults(limit: 10));
    await pins('updateExportedPath', () => dao.updateExportedPath(2, '/s.png'));
    await pins(
      'updateExportedPath missing',
      () => dao.updateExportedPath(9, 'x'),
    );
    await pins('deleteResult 3', () => dao.deleteResult(3));
    await pins('deleteResult missing', () => dao.deleteResult(3));
    await pins.dump(db, 'stacked_results', 'after updates');
    pins.verify();
  });
}
