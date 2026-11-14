import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show FrameWcs;
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_desktop/headless_api/handlers/science_handlers.dart';
import 'package:shelf/shelf.dart';

const _pixels = [
  (100.0, 120.0),
  (880.0, 140.0),
  (150.0, 650.0),
  (850.0, 620.0),
];
const _sip = (
  aOrder: 2,
  bOrder: 2,
  aCoeffs: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0002, 0.0, 0.0],
  bCoeffs: [0.0, 0.0, -0.0002, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
  apOrder: 0,
  bpOrder: 0,
  apCoeffs: <double>[],
  bpCoeffs: <double>[],
);

class _Science extends Mock implements ScienceBackend {
  ScienceFrameContext? context;

  @override
  Future<List<StarMeasurement>> measureStars(
    String path,
    PhotometryOptions options,
  ) async => [
    for (final pixel in _pixels)
      StarMeasurement(
        x: pixel.$1,
        y: pixel.$2,
        flux: 10000,
        hfr: 2,
        fwhm: 3,
        snr: 50,
        eccentricity: 0.2,
        sharpness: 0.5,
        background: 100,
        peak: 2000,
      ),
  ];

  @override
  Future<FramePhotometricCalibration?> calibrateFramePhotometry(
    String path,
    WcsSolution wcs,
    PhotometricCatalogSource catalog,
    ScienceFrameContext? frameContext,
  ) async {
    context = frameContext;
    return FramePhotometricCalibration(
      capturedImageId: frameContext?.capturedImageId,
      sessionId: null,
      timestamp: DateTime.utc(2026),
      isCalibrated: true,
      zeroPoint: 22,
      solverId: 'fixture',
    );
  }
}

void main() {
  for (final fromHeader in [false, true]) {
    test(
      'linked matches retain ${fromHeader ? 'header CRPIX' : 'stored'} CD and SIP',
      () async {
        final dir = await Directory.systemTemp.createTemp('science-wcs');
        final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
        final backend = _Science();
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(database),
            scienceBackendProvider.overrideWithValue(backend),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
          await dir.delete(recursive: true);
        });
        final solved = SolvedWcs(
          raHours: 5.5,
          decDegrees: -5.4,
          rotationDeg: 0,
          pixelScaleArcsec: 1.5,
          imageWidth: 1024,
          imageHeight: 768,
          cd1_1: 0.0004,
          cd1_2: 0.00015,
          cd2_1: -0.0001,
          cd2_2: 0.0005,
          sip: _sip,
          referenceX: fromHeader ? 420 : null,
          referenceY: fromHeader ? 320 : null,
        );
        final projection = GnomonicProjection(solved);
        final skies = [
          for (final p in _pixels) projection.pixelToWorld(x: p.$1, y: p.$2),
        ];
        final csv = StringBuffer('fixture header\n');
        for (var i = 0; i < skies.length; i++) {
          final row = List.filled(30, '');
          row[0] = '${i + 1}';
          row[6] = 'Fixture $i';
          row[7] = '${skies[i].raDegrees / 15}';
          row[8] = '${skies[i].decDegrees}';
          row[13] = '10';
          row[16] = '0.65';
          csv.writeln(row.join(','));
        }
        await File('${dir.path}/hyg_v44.csv').writeAsString(csv.toString());
        await CatalogManager.instance.initialize(dir.path);
        expect(await CatalogManager.instance.stars.load(), hasLength(4));
        final file = await File('${dir.path}/frame.fits').writeAsBytes([0]);
        final id = await database.imagesDao.insertSequenceFrame(
          filePath: file.path,
          fileName: 'frame.fits',
          fileFormat: 'fits',
          exposureDuration: 60,
          capturedAt: DateTime.utc(2026),
          isAccepted: true,
          producingNodeId: 'fixture',
          filter: 'V',
          mountAltitude: 45,
        );
        await database.imagesDao.updatePlateSolveResult(
          id,
          solvedRa: 5.5,
          solvedDec: -5.4,
          solvedRotation: 0,
          solvedPixelScale: 1.5,
          solvedCd1_1: solved.cd1_1,
          solvedCd1_2: solved.cd1_2,
          solvedCd2_1: solved.cd2_1,
          solvedCd2_2: solved.cd2_2,
          solvedSip: encodeSolvedSip(_sip),
        );
        final terms = solved.fitsTerms;
        final header = FrameHeader(
          {'NAXIS1': 1024, 'NAXIS2': 768},
          astrometry: fromHeader
              ? FrameWcs(
                  crval1: terms.crval1,
                  crval2: terms.crval2,
                  crpix1: terms.crpix1,
                  crpix2: terms.crpix2,
                  cd11: terms.cd1_1,
                  cd12: terms.cd1_2,
                  cd21: terms.cd2_1,
                  cd22: terms.cd2_2,
                  aOrder: 2,
                  bOrder: 2,
                  aCoeffs: Float64List.fromList(_sip.aCoeffs),
                  bCoeffs: Float64List.fromList(_sip.bCoeffs),
                  apOrder: 0,
                  bpOrder: 0,
                  apCoeffs: Float64List(0),
                  bpCoeffs: Float64List(0),
                )
              : null,
        );
        final handler = ScienceHandlers(
          container,
          readHeader: (_) async => header,
        );
        final response = await handler.handleMatchPhotometricCalibrationStars(
          Request(
            'POST',
            Uri.parse(
              'http://localhost/api/science/calibration/image/$id/match-stars',
            ),
          ),
          '$id',
        );
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(response.statusCode, 200, reason: '$body');
        final matches = body['starMatches'] as List;
        expect(
          matches,
          hasLength(4),
          reason: 'scalar rotation loses parity, skew and distortion',
        );
        for (var i = 0; i < matches.length; i++) {
          expect(matches[i]['instrumentalFlux'], closeTo(10000 / 60, 1e-10));
          expect(matches[i]['catalogMagV'], 10);
          expect(matches[i]['catalogMagB'], 10.65);
          expect(matches[i]['raDegrees'], closeTo(skies[i].raDegrees, 1e-8));
          expect(matches[i]['decDegrees'], closeTo(skies[i].decDegrees, 1e-8));
        }
        expect(backend.context?.capturedImageId, id);
        expect(backend.context?.exposureSeconds, 60);
        expect(backend.context?.imageWidth, 1024);
        expect(
          backend.context?.airmass,
          closeTo(airmassForTrueAltitude(45)!, 1e-10),
        );
      },
    );
  }
}
