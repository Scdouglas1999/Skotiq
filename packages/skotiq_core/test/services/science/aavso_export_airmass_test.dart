// The AMASS column of a real AAVSO submission, driven end to end.
//
// This exercises `AavsoExportService.exportSession` against a real database
// and reads the number out of the file that would be uploaded — not the
// airmass helper in isolation. The exporter must use the shared airmass model:
// its own copy would submit a frame taken low in the sky with an airmass the
// frame's own FITS header disagrees with.
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

const int _sessionId = 1;

/// The AMASS field of the data line whose GROUP column names [capturedImageId].
/// The exporter writes one line per target measurement and uses the captured
/// image id as the group, which is what lets a test tie a line back to the
/// frame's altitude.
String _amassForFrame(String content, int capturedImageId) {
  for (final line in content.split('\n')) {
    if (line.startsWith('#') || line.trim().isEmpty) {
      continue;
    }
    final fields = line.split(',');
    expect(fields.length, 15, reason: 'Extended Format has 15 columns: $line');
    if (fields[12] == '$capturedImageId') {
      return fields[11];
    }
  }
  fail('no data line for captured image $capturedImageId in:\n$content');
}

void main() {
  late SkotiqDatabase db;
  late ImagesDao imagesDao;
  late ScienceDao scienceDao;
  late SettingsDao settingsDao;
  late Directory documents;
  late AavsoExportService service;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imagesDao = ImagesDao(db);
    scienceDao = ScienceDao(db);
    settingsDao = SettingsDao(db);
    documents = await Directory.systemTemp.createTemp('aavso-amass-test');
    service = AavsoExportService(
      scienceDao: scienceDao,
      settingsDao: settingsDao,
      imagesDao: imagesDao,
      documentsDirectoryProvider: () async => documents,
    );

    await settingsDao.setSetting('science.aavso.observer_code', 'NSTS');
    await db
        .into(db.imagingSessions)
        .insert(
          ImagingSessionsCompanion.insert(
            id: const Value(_sessionId),
            startTime: DateTime.utc(2026, 8, 1, 21),
          ),
        );
  });

  tearDown(() async {
    await db.close();
    if (documents.existsSync()) {
      documents.deleteSync(recursive: true);
    }
  });

  /// A plate-solved light frame of the target at [mountAltitude], plus the one
  /// target photometry row the exporter turns into a data line.
  Future<int> frameAtAltitude(String name, double? mountAltitude) async {
    final imageId = await imagesDao.insertSequenceFrame(
      filePath: '/captures/ss-cyg/$name',
      fileName: name,
      fileFormat: 'fits',
      exposureDuration: 60.0,
      capturedAt: DateTime.utc(2026, 8, 1, 23, 30),
      isAccepted: true,
      producingNodeId: 'node-amass',
      sessionId: _sessionId,
      filter: 'V',
      mountAltitude: mountAltitude,
    );
    await scienceDao.insertPhotometryMeasurements([
      PhotometryMeasurementsCompanion.insert(
        capturedImageId: Value(imageId),
        sessionId: const Value(_sessionId),
        objectId: 'SS CYG',
        role: const Value('target'),
        x: 512.0,
        y: 512.0,
        flux: 125000.0,
        differentialMagnitude: const Value(11.234),
        uncertainty: const Value(0.012),
        timestamp: Value(DateTime.utc(2026, 8, 1, 23, 30)),
      ),
      PhotometryMeasurementsCompanion.insert(
        capturedImageId: Value(imageId),
        sessionId: const Value(_sessionId),
        objectId: 'C1',
        role: const Value('comparison'),
        x: 700.0,
        y: 512.0,
        flux: 250000.0,
        uncertainty: const Value(0.008),
        timestamp: Value(DateTime.utc(2026, 8, 1, 23, 30)),
      ),
    ]);
    return imageId;
  }

  test(
    'the submitted AMASS column is the product airmass model at every altitude',
    () async {
      // 60° and 20° sit in the Pickering band; 4° and 0° are where a
      // Pickering-only exporter diverges, and 0° is where an `altitude > 0`
      // guard refuses to answer at all.
      final high = await frameAtAltitude('ss-cyg-60.fits', 60.0);
      final mid = await frameAtAltitude('ss-cyg-20.fits', 20.0);
      final low = await frameAtAltitude('ss-cyg-04.fits', 4.0);
      final horizon = await frameAtAltitude('ss-cyg-00.fits', 0.0);

      final exportPath = await service.exportSession(
        sessionId: _sessionId,
        targetStarName: 'SS CYG',
        filterBand: 'V',
      );
      final content = await File(exportPath).readAsString();

      // Published standard-atmosphere values; see airmass_test.dart for the
      // references. The exporter writes three decimals.
      expect(_amassForFrame(content, high), '1.154');
      expect(_amassForFrame(content, mid), '2.900');

      // The two that matter. Old exporter: 12.361 at 4° (Pickering run past
      // its valid range) and 'na' at 0°.
      expect(_amassForFrame(content, low), '11.897');
      expect(_amassForFrame(content, horizon), '31.735');

      // Every published AMASS must agree with the model to the digit, so a
      // future formula edit cannot pass by only moving one of them.
      for (final (imageId, altitude) in [
        (high, 60.0),
        (mid, 20.0),
        (low, 4.0),
        (horizon, 0.0),
      ]) {
        expect(
          _amassForFrame(content, imageId),
          airmassForTrueAltitude(altitude)!.toStringAsFixed(3),
          reason: 'AMASS at $altitude° must be the shared model',
        );
      }
    },
  );

  test(
    'an unknown or sub-horizon altitude is submitted as na, not a guess',
    () async {
      final unknown = await frameAtAltitude('ss-cyg-noalt.fits', null);
      final below = await frameAtAltitude('ss-cyg-set.fits', -3.5);

      final exportPath = await service.exportSession(
        sessionId: _sessionId,
        targetStarName: 'SS CYG',
        filterBand: 'V',
      );
      final content = await File(exportPath).readAsString();

      // 'na' is legal in the Extended Format. A substituted 1.000 would be
      // indistinguishable from a genuine zenith observation in the archive.
      expect(_amassForFrame(content, unknown), 'na');
      expect(_amassForFrame(content, below), 'na');
      expect(content, isNot(contains(',1.000,')));
    },
  );
}
