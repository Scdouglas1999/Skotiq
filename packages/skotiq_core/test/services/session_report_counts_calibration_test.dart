// The Session Report said a night that captured three frames captured none.
//
// Live repro on a fresh install (release bundle, empty data dirs): a 3 x 2s
// DARK sequence against the simulator finished "Completed" and the Sequencer
// showed "3 / 3 frames". `captured_images` held three rows — session_id 1,
// frame_type 'dark', exposure_duration 2.0, is_accepted 1 — `imaging_sessions`
// row 1 recorded total_exposures 3 / successful_exposures 3 /
// total_integration_secs 6.0, and three FITS files sat in the capture folder.
// The Session Report for that same session showed:
//
//     Wall clock 8s | Integration 0s | Effective imaging 0.0%
//     Downtime 8s   | Frames accepted 0/0 | Frames rejected 0
//     Targets: "No accepted light frames recorded."
//
// Cause: `buildReport` filtered `captured_images` to `frame_type == 'light'`
// and every headline number folded over the resulting (empty) target rollup,
// so a calibration-only session was structurally zero on every tile — and the
// downtime tile then reported 100% of the wall clock as idle.
//
// This is not a join bug. Nothing here joins by list position; `session_id`
// matched, the frames were simply thrown away.
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/daos/sequence_runs_dao.dart';
import 'package:skotiq_core/src/database/daos/sessions_dao.dart';
import 'package:skotiq_core/src/database/daos/targets_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/services/imaging_records_repository.dart';
import 'package:skotiq_core/src/services/session_report_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionReportService counts every frame the session captured', () {
    late SkotiqDatabase db;
    late SessionsDao sessionsDao;
    late ImagesDao imagesDao;
    late SessionReportService service;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      sessionsDao = SessionsDao(db);
      imagesDao = ImagesDao(db);
      service = SessionReportService(
        records: ImagingRecordsRepository.local(
          sessionsDao: sessionsDao,
          imagesDao: imagesDao,
        ),
        sequenceRunsDao: SequenceRunsDao(db),
        targetsDao: TargetsDao(db),
      );
    });

    tearDown(() async => db.close());

    Future<int> insertSession(DateTime start, DateTime end) {
      return sessionsDao.createSession(
        ImagingSessionsCompanion.insert(
          name: const Value('New Sequence'),
          startTime: start,
          endTime: Value(end),
          status: const Value('completed'),
        ),
      );
    }

    Future<void> insertFrame({
      required int sessionId,
      required String frameType,
      double exposure = 2.0,
      bool accepted = true,
      int seq = 0,
    }) {
      return imagesDao.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/captures/$frameType-$seq.fits',
          fileName: '$frameType-$seq.fits',
          sessionId: Value(sessionId),
          frameType: Value(frameType),
          exposureDuration: exposure,
          capturedAt: DateTime.now(),
          isAccepted: Value(accepted),
        ),
      );
    }

    test('a dark-only session reports its frames, not zero', () async {
      // The live run, to the second: 8s wall clock, 3 x 2.0s darks.
      final start = DateTime(2026, 9, 1, 14, 46, 46);
      final sessionId = await insertSession(
        start,
        start.add(const Duration(seconds: 8)),
      );
      for (var i = 0; i < 3; i++) {
        await insertFrame(sessionId: sessionId, frameType: 'dark', seq: i);
      }

      final report = await service.buildReport(sessionId);

      // The headline the operator reads. Pre-fix: 0/0.
      expect(report.totalFramesAttempted, 3);
      expect(report.totalFramesAccepted, 3);
      expect(report.calibrationFramesAccepted, 3);

      // Shutter-open time is reported, and downtime is what is left of the
      // wall clock — not all of it. Pre-fix: downtime 8s, effective 0.0%.
      expect(report.calibrationIntegrationSecs, closeTo(6.0, 1e-9));
      expect(report.downtime, const Duration(seconds: 2));
      expect(report.effectiveImagingFraction, closeTo(6.0 / 8.0, 1e-9));

      // The dark is still not a target's integration — that part was right.
      expect(report.targets, isEmpty);
      expect(report.totalIntegration, Duration.zero);
      expect(report.lightFramesAccepted, 0);

      // Broken out by frame type so the report says WHAT it captured.
      expect(report.calibration, hasLength(1));
      expect(report.calibration.single.frameType, 'dark');
      expect(report.calibration.single.framesAttempted, 3);
      expect(
        report.calibration.single.totalIntegrationSecs,
        closeTo(6.0, 1e-9),
      );
      expect(report.isEmpty, isFalse);
    });

    test('a light session is unchanged by the calibration rollup', () async {
      final start = DateTime(2026, 9, 1, 22, 0, 0);
      final sessionId = await insertSession(
        start,
        start.add(const Duration(seconds: 100)),
      );
      for (var i = 0; i < 2; i++) {
        await insertFrame(
          sessionId: sessionId,
          frameType: 'light',
          exposure: 30.0,
          seq: i,
        );
      }

      final report = await service.buildReport(sessionId);

      expect(report.calibration, isEmpty);
      expect(report.totalIntegration, const Duration(seconds: 60));
      expect(report.totalFramesAccepted, 2);
      expect(report.totalFramesAttempted, 2);
      expect(report.downtime, const Duration(seconds: 40));
      expect(report.effectiveImagingFraction, closeTo(0.6, 1e-9));
    });

    test(
      'a mixed night keeps lights and calibration apart but counts both',
      () async {
        final start = DateTime(2026, 9, 1, 21, 0, 0);
        final sessionId = await insertSession(
          start,
          start.add(const Duration(seconds: 200)),
        );
        await insertFrame(
          sessionId: sessionId,
          frameType: 'light',
          exposure: 60.0,
        );
        await insertFrame(
          sessionId: sessionId,
          frameType: 'dark',
          exposure: 60.0,
          seq: 1,
        );
        // A bias is ~0 s of shutter-open time but is still a captured frame.
        await insertFrame(
          sessionId: sessionId,
          frameType: 'bias',
          exposure: 0.0,
          seq: 2,
        );
        // A rejected dark counts as attempted, not accepted.
        await insertFrame(
          sessionId: sessionId,
          frameType: 'dark',
          exposure: 60.0,
          accepted: false,
          seq: 3,
        );

        final report = await service.buildReport(sessionId);

        // "Integration" stays LIGHT integration; a dark contributes nothing to a
        // target, and mixing it in would overstate a science night.
        expect(report.totalIntegration, const Duration(seconds: 60));
        expect(report.lightFramesAccepted, 1);

        expect(report.totalFramesAttempted, 4);
        expect(report.totalFramesAccepted, 3);
        expect(report.totalFramesRejected, 1);

        // Ordered by frame type, so the rendering is stable run to run.
        expect(report.calibration.map((c) => c.frameType).toList(), [
          'bias',
          'dark',
        ]);
        final dark = report.calibration.firstWhere(
          (c) => c.frameType == 'dark',
        );
        expect(dark.framesAttempted, 2);
        expect(dark.framesAccepted, 1);
        expect(dark.framesRejected, 1);
        expect(dark.totalIntegrationSecs, closeTo(60.0, 1e-9));
      },
    );

    test('frame_type is matched case-insensitively', () async {
      // The native sequencer emits "Light"/"Dark" capitalised
      // (`node_factory.rs`, `event_bridge.rs`) and Dart lower-cases on the way
      // in — but `images_dao`, `equipment_stats` and `session_chart` all
      // normalise before comparing, and the report did not. A row that reached
      // the table with its original capitalisation was invisible here alone.
      final start = DateTime(2026, 9, 1, 23, 0, 0);
      final sessionId = await insertSession(
        start,
        start.add(const Duration(seconds: 60)),
      );
      await insertFrame(
        sessionId: sessionId,
        frameType: 'Light',
        exposure: 30.0,
      );
      await insertFrame(
        sessionId: sessionId,
        frameType: 'Dark',
        exposure: 10.0,
        seq: 1,
      );

      final report = await service.buildReport(sessionId);

      expect(
        report.lightFramesAccepted,
        1,
        reason: '"Light" must count as a light frame',
      );
      expect(report.totalIntegration, const Duration(seconds: 30));
      expect(
        report.calibration.single.frameType,
        'dark',
        reason: 'calibration frame types are normalised for display',
      );
    });
  });
}
