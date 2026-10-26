// The data lines of an AAVSO Extended Format file, checked against the spec
// (https://www.aavso.org/aavso-extended-file-format): MTYPE is STD or DIF,
// a DIF magnitude is target minus the named comparison, CMAG and KMAG are
// instrumental magnitudes, FILT is the frame's own filter and DATE is the
// mid-exposure time.
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

const int _sessionId = 1;

double _instMag(double flux) => -2.5 * math.log(flux) / math.ln10;

void main() {
  late SkotiqDatabase db;
  late ImagesDao imagesDao;
  late ScienceDao scienceDao;
  late Directory documents;
  late AavsoExportService service;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imagesDao = ImagesDao(db);
    scienceDao = ScienceDao(db);
    final settingsDao = SettingsDao(db);
    documents = await Directory.systemTemp.createTemp('aavso-format-test');
    service = AavsoExportService(
      scienceDao: scienceDao,
      settingsDao: settingsDao,
      imagesDao: imagesDao,
      documentsDirectoryProvider: () async => documents,
    );
    await settingsDao.setSetting('science.aavso.observer_code', 'XSKQ');
    await db
        .into(db.imagingSessions)
        .insert(
          ImagingSessionsCompanion.insert(
            id: const Value(_sessionId),
            startTime: DateTime.utc(2026, 10, 26, 8, 50),
          ),
        );
  });

  tearDown(() async {
    await db.close();
    if (documents.existsSync()) documents.deleteSync(recursive: true);
  });

  /// One 60 s M67 frame: AH Cnc, comparisons C3 and C5, check star C4.
  Future<int> frame(String name, String filter, DateTime recordedAt) async {
    final id = await imagesDao.insertSequenceFrame(
      filePath: '/captures/m67/$name',
      fileName: name,
      fileFormat: 'fits',
      exposureDuration: 60.0,
      capturedAt: recordedAt,
      isAccepted: true,
      producingNodeId: 'node-m67',
      sessionId: _sessionId,
      filter: filter,
      mountAltitude: 46.0,
    );
    PhotometryMeasurementsCompanion row(
      String objectId,
      String role,
      double flux, {
      double? diff,
    }) => PhotometryMeasurementsCompanion.insert(
      capturedImageId: Value(id),
      sessionId: const Value(_sessionId),
      objectId: objectId,
      role: Value(role),
      x: 100,
      y: 100,
      flux: flux,
      differentialMagnitude: Value(diff),
      uncertainty: const Value(0.015),
      snr: const Value(150),
      filter: Value(filter),
      timestamp: Value(recordedAt),
    );
    await scienceDao.insertPhotometryMeasurements([
      row('AH_Cnc', 'target', 125000, diff: 0.52),
      row('C3', 'comparison', 260000),
      row('C5', 'comparison', 310000),
      row('C4', 'check', 128000, diff: 0.30),
    ]);
    return id;
  }

  test(
    'lines are DIF against one named comparison, per filter, mid-exposure',
    () async {
      // Recorded at 09:00:34, the end of a 60 s exposure that began 08:59:34.
      await frame('M67_G_0001.fits', 'G', DateTime.utc(2026, 10, 26, 9, 0, 34));
      await frame('M67_R_0001.fits', 'R', DateTime.utc(2026, 10, 26, 9, 1, 41));
      await frame('M67_B_0001.fits', 'B', DateTime.utc(2026, 10, 26, 9, 2, 50));

      final content = await File(
        await service.exportSession(
          sessionId: _sessionId,
          targetStarName: 'AH CNC',
        ),
      ).readAsString();
      final lines = content
          .split('\n')
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .map((l) => l.split(','))
          .toList();
      expect(lines, hasLength(3));
      for (final f in lines) {
        expect(f, hasLength(15));
        expect(f[6], 'DIF');
        expect(f[5], 'NO');
      }
      expect(lines.map((f) => f[4]).toList(), ['TG', 'TR', 'TB']);

      final g = lines.first;
      // Mid-exposure 08:59:34 + 30 s = 09:00:04 UTC.
      expect(double.parse(g[1]), closeTo(2461339.87505, 0.00001));
      // MAG = target − CNAME, both instrumental; CMAG and KMAG instrumental.
      expect(g[7], 'C3');
      expect(
        double.parse(g[2]),
        closeTo(_instMag(125000) - _instMag(260000), 1e-4),
      );
      expect(double.parse(g[8]), closeTo(_instMag(260000), 1e-4));
      expect(g[9], 'C4');
      expect(double.parse(g[10]), closeTo(_instMag(128000), 1e-4));
    },
  );

  test('a frame in a filter AAVSO has no code for is left out', () async {
    await frame('M67_Ha_0001.fits', 'Ha', DateTime.utc(2026, 10, 26, 9));
    await expectLater(
      service.exportSession(sessionId: _sessionId, targetStarName: 'AH CNC'),
      throwsA(isA<AavsoExportError>()),
    );
  });
}
