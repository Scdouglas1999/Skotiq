import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_core/src/utils/fwhm_conversion.dart';
import 'package:nightshade_core/src/database/daos/images_dao.dart';
import 'package:nightshade_core/src/database/daos/sequence_runs_dao.dart';
import 'package:nightshade_core/src/database/daos/sessions_dao.dart';
import 'package:nightshade_core/src/database/daos/targets_dao.dart';
import 'package:nightshade_core/src/database/database.dart';
import 'package:nightshade_core/src/services/imaging_records_repository.dart';
import 'package:nightshade_core/src/services/session_report_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionReportService', () {
    late NightshadeDatabase db;
    late SessionsDao sessionsDao;
    late ImagesDao imagesDao;
    late SequenceRunsDao runsDao;
    late TargetsDao targetsDao;
    late SessionReportService service;

    setUp(() {
      db = NightshadeDatabase.forTesting(NativeDatabase.memory());
      sessionsDao = SessionsDao(db);
      imagesDao = ImagesDao(db);
      runsDao = SequenceRunsDao(db);
      targetsDao = TargetsDao(db);
      service = SessionReportService(
        records: ImagingRecordsRepository.local(
          sessionsDao: sessionsDao,
          imagesDao: imagesDao,
        ),
        sequenceRunsDao: runsDao,
        targetsDao: targetsDao,
      );
    });

    tearDown(() async {
      await db.close();
    });

    Future<int> createTarget(String name) async {
      return db
          .into(db.targets)
          .insert(TargetsCompanion.insert(name: name, ra: 5.6, dec: -5.4));
    }

    Future<int> insertSession({
      required String name,
      required int? targetId,
      required DateTime startTime,
      DateTime? endTime,
      String status = 'completed',
      int autofocusCount = 0,
      double? avgSeeing,
    }) async {
      return sessionsDao.createSession(
        ImagingSessionsCompanion.insert(
          name: Value(name),
          targetId: Value(targetId),
          startTime: startTime,
          endTime: Value(endTime),
          status: Value(status),
          autofocusCount: Value(autofocusCount),
          avgSeeing: Value(avgSeeing),
        ),
      );
    }

    Future<void> insertFrame({
      required int sessionId,
      int? targetId,
      String filter = 'L',
      bool accepted = true,
      String? rejectionReason,
      double exposure = 60.0,
      double? hfr,
      int? starCount,
      double? rmsRa,
      double? rmsDec,
      double? rmsTotal,
      double? background,
      double? noise,
      double? sensorTemp,
      String frameType = 'light',
    }) async {
      await imagesDao.createImage(
        CapturedImagesCompanion.insert(
          filePath: 'C:/fake/$filter-$sessionId.fits',
          fileName: 'frame.fits',
          sessionId: Value(sessionId),
          targetId: Value(targetId),
          frameType: Value(frameType),
          exposureDuration: exposure,
          filter: Value(filter),
          hfr: Value(hfr),
          starCount: Value(starCount),
          guidingRmsRa: Value(rmsRa),
          guidingRmsDec: Value(rmsDec),
          guidingRmsTotal: Value(rmsTotal),
          background: Value(background),
          noise: Value(noise),
          sensorTemp: Value(sensorTemp),
          capturedAt: DateTime.now(),
          isAccepted: Value(accepted),
          rejectionReason: Value(rejectionReason),
        ),
      );
    }

    test('builds per-filter / per-target rollup with means', () async {
      final targetId = await createTarget('M42');
      final sessionId = await insertSession(
        name: 'Orion Night 1',
        targetId: targetId,
        startTime: DateTime.utc(2026, 1, 1, 22),
        endTime: DateTime.utc(2026, 1, 2, 2),
        autofocusCount: 2,
        avgSeeing: 2.5,
      );

      // L filter: 2 accepted, 1 rejected
      await insertFrame(
        sessionId: sessionId,
        targetId: targetId,
        filter: 'L',
        exposure: 60,
        hfr: 2.0,
        starCount: 500,
        rmsRa: 0.5,
        rmsDec: 0.4,
        rmsTotal: 0.64,
        background: 100,
        noise: 5,
      );
      await insertFrame(
        sessionId: sessionId,
        targetId: targetId,
        filter: 'L',
        exposure: 60,
        hfr: 2.4,
        starCount: 540,
        rmsRa: 0.6,
        rmsDec: 0.5,
        rmsTotal: 0.78,
        background: 110,
        noise: 5,
      );
      await insertFrame(
        sessionId: sessionId,
        targetId: targetId,
        filter: 'L',
        exposure: 60,
        accepted: false,
        rejectionReason: 'High HFR',
      );

      // R filter: 1 accepted
      await insertFrame(
        sessionId: sessionId,
        targetId: targetId,
        filter: 'R',
        exposure: 120,
        hfr: 2.2,
        starCount: 450,
      );

      // Junk dark frame that must NOT appear in the report.
      await insertFrame(
        sessionId: sessionId,
        targetId: targetId,
        filter: 'L',
        frameType: 'dark',
        exposure: 60,
      );

      final report = await service.buildReport(sessionId);

      expect(report.sessionName, 'Orion Night 1');
      expect(report.status, 'completed');
      expect(report.targets.length, 1);

      final target = report.targets.single;
      expect(target.targetName, 'M42');
      expect(target.targetId, targetId);
      expect(target.filters.map((f) => f.filter).toList(), ['L', 'R']);

      final l = target.filters.firstWhere((f) => f.filter == 'L');
      expect(l.framesAttempted, 3);
      expect(l.framesAccepted, 2);
      expect(l.framesRejected, 1);
      expect(l.totalIntegrationSecs, 120.0);
      expect(l.meanHfr, closeTo(2.2, 1e-6));
      // FWHM = 2.0 x HFR: HFR is the half-flux RADIUS, so the 2.35
      // sigma->FWHM factor would overstate every reported FWHM by 17.7% and
      // disagree with the native measurement path.
      expect(l.meanFwhm, closeTo(2.2 * kFwhmPerHfr, 1e-6));
      expect(l.meanStarCount, closeTo(520.0, 1e-6));
      // SNR proxy: (100/5 + 110/5) / 2 = 21
      expect(l.meanSnr, closeTo(21.0, 1e-6));
      expect(l.rejectionReasons, {'High HFR': 1});

      final r = target.filters.firstWhere((f) => f.filter == 'R');
      expect(r.framesAttempted, 1);
      expect(r.totalIntegrationSecs, 120.0);

      // Light-frame totals exclude darks: a dark contributes nothing to a
      // target's integration, so "Integration" and the per-target rollup are
      // lights only.
      expect(report.lightFramesAttempted, 4);
      expect(report.lightFramesAccepted, 3);
      expect(report.totalIntegration.inSeconds, 240);

      // Whole-session frame COUNTS include the dark. They used to exclude it,
      // which is how a calibration-only session reported "Frames accepted 0/0"
      // beside three FITS files on disk — see
      // session_report_counts_calibration_test.dart.
      expect(report.totalFramesAttempted, 5);
      expect(report.totalFramesAccepted, 4);
      expect(report.totalFramesRejected, 1);
      expect(report.calibration.single.frameType, 'dark');
      expect(report.calibration.single.framesAccepted, 1);
    });

    test('guide stats expose unguided fraction and max RMS', () async {
      final targetId = await createTarget('NGC7000');
      final sessionId = await insertSession(
        name: 'Pelican',
        targetId: targetId,
        startTime: DateTime.utc(2026, 2, 1, 22),
        endTime: DateTime.utc(2026, 2, 2, 0),
      );

      await insertFrame(
        sessionId: sessionId,
        targetId: targetId,
        rmsRa: 0.4,
        rmsDec: 0.3,
        rmsTotal: 0.5,
      );
      await insertFrame(
        sessionId: sessionId,
        targetId: targetId,
        rmsRa: 0.8,
        rmsDec: 0.6,
        rmsTotal: 1.0,
      );
      // Frame with no guide data at all (e.g. unguided exposure).
      await insertFrame(sessionId: sessionId, targetId: targetId);

      final report = await service.buildReport(sessionId);
      final gs = report.guideStats;
      expect(gs.meanRmsRaArcsec, closeTo(0.6, 1e-6));
      expect(gs.maxRmsTotalArcsec, closeTo(1.0, 1e-6));
      expect(gs.percentUnguidedFrames, closeTo(1 / 3, 1e-6));
    });

    test(
      'pulls mount stats from related sequence_runs and session row',
      () async {
        final targetId = await createTarget('M31');
        final sessionStart = DateTime.utc(2026, 3, 1, 22);
        final sessionEnd = DateTime.utc(2026, 3, 2, 4);
        final sessionId = await insertSession(
          name: 'Andromeda',
          targetId: targetId,
          startTime: sessionStart,
          endTime: sessionEnd,
          autofocusCount: 1,
        );

        // Inject a sequence run whose stats blob holds the operations counters.
        await db
            .into(db.sequenceRuns)
            .insert(
              SequenceRunsCompanion.insert(
                sequenceName: 'Andromeda sequence',
                startedAt: sessionStart.add(const Duration(minutes: 5)),
                endedAt: Value(sessionEnd.subtract(const Duration(minutes: 5))),
                status: const Value('completed'),
                statsJson: const Value(
                  '{"autofocusRuns":3,"meridianFlips":1,"ditherCount":12,"triggerFires":2,"errorMessages":["Guider lost star","Recovered"]}',
                ),
              ),
            );

        final report = await service.buildReport(sessionId);
        // session.autofocusCount=1, run stats=3 -> max wins.
        expect(report.mountStats.autofocusRuns, 3);
        expect(report.mountStats.meridianFlips, 1);
        expect(report.mountStats.ditherCount, 12);
        expect(report.mountStats.triggerFires, 2);
        expect(report.errorMessages, ['Guider lost star', 'Recovered']);
      },
    );

    test('a session of several runs takes the cause from the earliest failure '
        'and the reject folder from the latest run, in time order', () async {
      final sessionStart = DateTime.utc(2026, 9, 14, 20);
      final sessionId = await insertSession(
        name: 'Two runs',
        targetId: null,
        startTime: sessionStart,
        endTime: DateTime.utc(2026, 9, 15, 2),
        status: 'failed',
      );
      Future<void> insertRun(
        DateTime startedAt,
        String cause,
        String folder,
      ) async {
        await db
            .into(db.sequenceRuns)
            .insert(
              SequenceRunsCompanion.insert(
                sequenceName: 'Night',
                startedAt: startedAt,
                endedAt: Value(startedAt.add(const Duration(hours: 1))),
                status: const Value('failed'),
                statsJson: Value(
                  '{"errorMessages":["$cause"],'
                  '"terminalCause":"$cause","rejectFolder":"$folder"}',
                ),
              ),
            );
      }

      // Inserted in time order; the DAO hands them back newest first.
      await insertRun(DateTime.utc(2026, 9, 14, 20, 10), 'A cause', '/a');
      await insertRun(DateTime.utc(2026, 9, 14, 23), 'B cause', '/b');

      final report = await service.buildReport(sessionId);
      expect(
        report.terminalCause,
        'A cause',
        reason: 'the earliest failure explains the session',
      );
      expect(
        report.rejectFolder,
        '/b',
        reason: 'the folder the most recent reject landed in',
      );
      expect(
        report.errorMessages,
        ['A cause', 'B cause'],
        reason: 'the error list reads in the order things happened',
      );
    });

    test('renderMarkdown emits headings and per-filter rows', () async {
      final targetId = await createTarget('Heart');
      final sessionId = await insertSession(
        name: 'IC1805',
        targetId: targetId,
        startTime: DateTime.utc(2026, 4, 1, 22),
        endTime: DateTime.utc(2026, 4, 2, 1),
      );
      await insertFrame(
        sessionId: sessionId,
        targetId: targetId,
        filter: 'Ha',
        hfr: 2.5,
        starCount: 700,
        exposure: 180,
      );

      final report = await service.buildReport(sessionId);
      final markdown = service.renderMarkdown(report);
      expect(markdown, contains('# Session Report: IC1805'));
      expect(markdown, contains('## Targets'));
      expect(markdown, contains('### Heart'));
      // Filter row includes our HFR.
      expect(markdown, contains('| Ha |'));
      expect(markdown, contains('Generated'));
    });

    test('throws when session id does not exist', () async {
      await expectLater(service.buildReport(99999), throwsA(isA<StateError>()));
    });

    test('handles untargeted captures with synthetic bucket', () async {
      final sessionId = await insertSession(
        name: 'Quick capture',
        targetId: null,
        startTime: DateTime.utc(2026, 5, 1, 22),
        endTime: DateTime.utc(2026, 5, 1, 23),
      );
      await insertFrame(sessionId: sessionId);

      final report = await service.buildReport(sessionId);
      expect(report.targets, hasLength(1));
      expect(report.targets.single.targetName, 'Untargeted');
      expect(report.targets.single.targetId, isNull);
    });
  });
}
