import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/daos/sessions_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/services/session_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionExportService', () {
    late SkotiqDatabase database;
    late SessionsDao sessionsDao;
    late ImagesDao imagesDao;

    setUp(() async {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      sessionsDao = SessionsDao(database);
      imagesDao = ImagesDao(database);
    });

    tearDown(() async {
      await database.close();
    });

    test('exportToHtml writes an HTML report file', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_session_export_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final sessionId = await sessionsDao.createSession(
        ImagingSessionsCompanion.insert(
          name: const Value('Rosette'),
          startTime: DateTime.utc(2026, 2, 1, 2),
          status: const Value('completed'),
        ),
      );

      await sessionsDao.updateSessionStats(
        sessionId,
        totalExposures: 10,
        successfulExposures: 8,
        failedExposures: 2,
        totalIntegrationSecs: 3600.0,
        avgHfr: 2.3,
        avgGuidingRms: 0.9,
      );
      await sessionsDao.endSession(sessionId);

      final service = SessionExportService(
        sessionsDao: sessionsDao,
        imagesDao: imagesDao,
        documentsDirectoryProvider: () async => tempDir,
      );

      final reportPath = await service.exportToHtml(sessionId);
      addTearDown(() async {
        final file = File(reportPath);
        if (await file.exists()) {
          await file.delete();
        }
      });

      final report = await File(reportPath).readAsString();
      expect(reportPath, endsWith('.html'));
      expect(report, contains('Skotiq Session Report'));
      expect(report, contains('Rosette'));
      expect(report, contains('Integration'));
    });

    // Observed defect: a report whose summary read "Average HFR -   Guiding RMS
    // -   Humidity -%   Temperature - C" sat directly above a frame table that
    // listed an HFR for every one of the eight frames. The session-level
    // avg_hfr column was simply never written for that run.
    test('exportToHtml derives the HFR/RMS summary from the frames when the '
        'session columns are null, and never prints a bare unit', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_session_export_summary_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final sessionId = await sessionsDao.createSession(
        ImagingSessionsCompanion.insert(
          name: const Value('MF PROBE B'),
          startTime: DateTime.utc(2026, 7, 25, 17, 4),
          status: const Value('completed'),
        ),
      );
      // No updateSessionStats call: avg_hfr / avg_guiding_rms / humidity /
      // temperature all stay NULL, exactly like the observed session.
      for (var i = 0; i < 4; i++) {
        await imagesDao.createImage(
          CapturedImagesCompanion.insert(
            filePath: '/lights/l$i.fits',
            fileName: 'l$i.fits',
            sessionId: Value(sessionId),
            exposureDuration: 3.0,
            frameType: const Value('light'),
            capturedAt: DateTime.utc(
              2026,
              7,
              25,
              17,
              4,
            ).add(Duration(minutes: i)),
            hfr: Value(2.0 + i * 0.2), // 2.0, 2.2, 2.4, 2.6 -> mean 2.30
            guidingRmsTotal: const Value(0.50),
            isAccepted: const Value(true),
          ),
        );
      }

      final service = SessionExportService(
        sessionsDao: sessionsDao,
        imagesDao: imagesDao,
        documentsDirectoryProvider: () async => tempDir,
      );
      final reportPath = await service.exportToHtml(sessionId);
      addTearDown(() async {
        final file = File(reportPath);
        if (await file.exists()) await file.delete();
      });
      final report = await File(reportPath).readAsString();

      // The summary now states the mean of the frames it is built from…
      expect(report, contains('2.30 px'));
      expect(report, contains('mean of 4 accepted frames'));
      expect(report, contains('0.50"'));
      // …and the missing ambient readings show an em dash with NO stray unit.
      expect(report, isNot(contains('-%')));
      expect(report, isNot(contains('- C')));
      expect(report, contains('not recorded'));
      // The frame table still lists the per-frame HFRs it always did.
      expect(report, contains('2.60'));
    });

    // Observed defect: the CSV's "FWHM (px)" column was always hfr * 2.3548 —
    // the sigma->FWHM factor applied to a half-flux RADIUS, an 18% inflation —
    // and the measured `fwhm` column the pipeline writes was never read.
    test('exportToCsv prefers the measured FWHM and derives 2x HFR '
        'only when there is none', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_session_export_fwhm_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final sessionId = await sessionsDao.createSession(
        ImagingSessionsCompanion.insert(
          name: const Value('FWHM PROBE'),
          startTime: DateTime.utc(2026, 8, 1, 2),
        ),
      );
      // Frame 1: pipeline measured a real FWHM that disagrees with any
      // multiple of HFR, so a derived column cannot accidentally match it.
      final measuredId = await imagesDao.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/lights/m.fits',
          fileName: 'm.fits',
          sessionId: Value(sessionId),
          exposureDuration: 300.0,
          frameType: const Value('light'),
          capturedAt: DateTime.utc(2026, 8, 1, 2, 1),
          hfr: const Value(2.00),
          isAccepted: const Value(true),
        ),
      );
      await imagesDao.stampProducingNode(imageId: measuredId, fwhm: 3.11);
      // Frame 2: no measured FWHM, so the exporter must derive it.
      await imagesDao.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/lights/d.fits',
          fileName: 'd.fits',
          sessionId: Value(sessionId),
          exposureDuration: 300.0,
          frameType: const Value('light'),
          capturedAt: DateTime.utc(2026, 8, 1, 2, 2),
          hfr: const Value(2.00),
          isAccepted: const Value(true),
        ),
      );

      final csvPath = await SessionExportService(
        sessionsDao: sessionsDao,
        imagesDao: imagesDao,
        documentsDirectoryProvider: () async => tempDir,
      ).exportToCsv(sessionId);
      addTearDown(() async {
        final file = File(csvPath);
        if (await file.exists()) await file.delete();
      });

      final table = const CsvToListConverter(
        shouldParseNumbers: false,
      ).convert(await File(csvPath).readAsString());
      final header = table.first.cast<String>();
      final hfrCol = header.indexWhere((c) => c.contains('HFR (px)'));
      final fwhmCol = header.indexWhere((c) => c.startsWith('FWHM'));
      expect(hfrCol, isNonNegative);
      expect(fwhmCol, isNonNegative);

      final measuredRow = table.firstWhere((r) => r[0] == 'm.fits');
      final derivedRow = table.firstWhere((r) => r[0] == 'd.fits');
      // The measured column wins outright.
      expect(measuredRow[fwhmCol], '3.11');
      // With no measurement, FWHM = 2.0 * HFR — NOT 2.3548 * HFR (4.71).
      expect(derivedRow[hfrCol], '2.00');
      expect(derivedRow[fwhmCol], '4.00');
      // And the header says the number can be derived.
      expect(header[fwhmCol], contains('HFR'));
    });

    test('exportSummary derives Average HFR from frames when null', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_session_export_summary_text_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final sessionId = await sessionsDao.createSession(
        ImagingSessionsCompanion.insert(
          name: const Value('MF PROBE B'),
          startTime: DateTime.utc(2026, 7, 25, 17, 4),
        ),
      );
      await imagesDao.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/lights/only.fits',
          fileName: 'only.fits',
          sessionId: Value(sessionId),
          exposureDuration: 3.0,
          frameType: const Value('light'),
          capturedAt: DateTime.utc(2026, 7, 25, 17, 5),
          hfr: const Value(2.38),
          isAccepted: const Value(true),
        ),
      );

      final summary = await SessionExportService(
        sessionsDao: sessionsDao,
        imagesDao: imagesDao,
        documentsDirectoryProvider: () async => tempDir,
      ).exportSummary(sessionId);

      expect(summary, contains('Average HFR: 2.38 px'));
    });

    // Observed defect: a night the grader threw out entirely — 4 subs
    // captured, 4 rejected, 0.00 h integrated — exported as "Exposures 4/4"
    // and "Success Rate 100.0%", two sections above "No accepted frames
    // recorded." The camera's counters answer "did the frame come back", and
    // the document presented them as the night's verdict.
    group('a night where every sub was rejected', () {
      late int sessionId;
      late Directory tempDir;
      late SessionExportService service;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp(
          'skotiq_session_export_rejected_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        sessionId = await sessionsDao.createSession(
          ImagingSessionsCompanion.insert(
            name: const Value('D3 all-rejected night'),
            startTime: DateTime.utc(2026, 8, 17, 11, 22),
            status: const Value('completed'),
          ),
        );
        // The camera returned every frame it was asked for; the grader kept
        // none of them.
        await sessionsDao.updateSessionStats(
          sessionId,
          totalExposures: 4,
          successfulExposures: 4,
          failedExposures: 0,
          totalIntegrationSecs: 0.0,
        );
        for (var i = 0; i < 4; i++) {
          await imagesDao.createImage(
            CapturedImagesCompanion.insert(
              filePath: '/lights/reject$i.fits',
              fileName: 'reject$i.fits',
              sessionId: Value(sessionId),
              exposureDuration: 2.0,
              frameType: const Value('light'),
              capturedAt: DateTime.utc(
                2026,
                8,
                17,
                11,
                22,
              ).add(Duration(minutes: i)),
              isAccepted: const Value(false),
              rejectionReason: const Value(
                'star count 43 below minimum 100000',
              ),
            ),
          );
        }
        await sessionsDao.endSession(sessionId);
        service = SessionExportService(
          sessionsDao: sessionsDao,
          imagesDao: imagesDao,
          documentsDirectoryProvider: () async => tempDir,
        );
      });

      test(
        'the HTML report states the grading verdict, not a 100% rate',
        () async {
          final report = await File(
            await service.exportToHtml(sessionId),
          ).readAsString();

          expect(report, isNot(contains('Success Rate')));
          expect(report, isNot(contains('100.0%')));
          expect(report, contains('Frames Kept'));
          expect(report, contains('<strong>0/4</strong>'));
          expect(report, contains('0.0% kept, 4 rejected'));
          expect(report, contains('accepted of all captures'));
          expect(report, contains('No accepted frames recorded.'));
        },
      );

      test('the JSON export carries the accepted/rejected truth', () async {
        final data =
            jsonDecode(
                  await File(
                    await service.exportToJson(sessionId),
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        final stats =
            (data['session'] as Map<String, dynamic>)['statistics']
                as Map<String, dynamic>;

        expect(stats['successfulExposures'], 4);
        expect(stats['lightFrames'], 4);
        expect(stats['acceptedLights'], 0);
        expect(stats['rejectedLights'], 4);
      });

      test('the text summary separates the camera from the grader', () async {
        final summary = await service.exportSummary(sessionId);

        expect(summary, isNot(contains('Success Rate')));
        expect(summary, contains('Frames the camera returned: 4 of 4'));
        expect(summary, contains('Light frames graded: 4'));
        expect(summary, contains('Kept: 0'));
        expect(summary, contains('Rejected: 4'));
        expect(summary, contains('Kept Rate: 0.0%'));
      });
    });

    test(
      'a night with no light frame states that rather than a rate',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_session_export_nolights_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final sessionId = await sessionsDao.createSession(
          ImagingSessionsCompanion.insert(
            name: const Value('calibration only'),
            startTime: DateTime.utc(2026, 8, 17, 11, 22),
            status: const Value('completed'),
          ),
        );
        final service = SessionExportService(
          sessionsDao: sessionsDao,
          imagesDao: imagesDao,
          documentsDirectoryProvider: () async => tempDir,
        );

        final report = await File(
          await service.exportToHtml(sessionId),
        ).readAsString();
        final summary = await service.exportSummary(sessionId);

        expect(report, contains('no light frames recorded'));
        expect(report, isNot(contains('100.0%')));
        expect(report, isNot(contains('0.0% kept')));
        expect(summary, contains('Kept Rate: no light frames recorded'));
      },
    );

    // The verdict every document surface shares, so two of them cannot
    // disagree about one night.
    test('the grading verdict counts light frames only', () async {
      final sessionId = await sessionsDao.createSession(
        ImagingSessionsCompanion.insert(
          name: const Value('mixed'),
          startTime: DateTime.utc(2026, 8, 17),
        ),
      );
      Future<void> frame(String type, bool accepted, int i) =>
          imagesDao.createImage(
            CapturedImagesCompanion.insert(
              filePath: '/f/$type$i.fits',
              fileName: '$type$i.fits',
              sessionId: Value(sessionId),
              exposureDuration: 1.0,
              frameType: Value(type),
              capturedAt: DateTime.utc(2026, 8, 17).add(Duration(minutes: i)),
              isAccepted: Value(accepted),
            ),
          );
      await frame('light', true, 0);
      await frame('light', false, 1);
      await frame('light', false, 2);
      // Calibration frames are not the night's subject and are never graded
      // against it; counting them would move the rate for a reason no
      // operator would recognise.
      await frame('dark', true, 3);
      await frame('flat', false, 4);

      final grading = SessionFrameGrading.of(
        await imagesDao.getImagesForSession(sessionId),
      );

      expect(grading.lights, 3);
      expect(grading.accepted, 1);
      expect(grading.rejected, 2);
      expect(grading.keptPercent, closeTo(33.33, 0.01));
      // A rate over no frames is not 0% and not 100%; it does not exist.
      expect(
        const SessionFrameGrading(lights: 0, accepted: 0).keptPercent,
        equals(null),
      );
    });
  });
}
