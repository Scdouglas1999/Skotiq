import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/services/wcs/gnomonic_projection.dart';
import 'package:skotiq_core/src/services/wcs/wcs_sip_codec.dart';

/// v51 wiring: the full anisotropic WCS (four `solved_cd*` scalars + the
/// `solved_sip` JSON blob) persists on `captured_images` and rebuilds a
/// [SolvedWcs] whose projection matches the CD path, while an isotropic
/// stored solve leaves CD/SIP null and the projection stays scale+rotation.
void main() {
  group('solved_sip codec', () {
    test('round-trips a low-order SIP block', () {
      final json = encodeSolvedSip(
        aOrder: 2,
        bOrder: 2,
        aCoeffs: const [0.0, 0.0, 1.2e-6, 0.0, -3.4e-7, 0.0, 0.0, 0.0, 0.0],
        bCoeffs: const [0.0, 5.6e-7, 0.0, 7.8e-7, 0.0, 0.0, 0.0, 0.0, 0.0],
        apOrder: 1,
        bpOrder: 1,
        apCoeffs: const [0.0, 0.0, 0.0, 0.0],
        bpCoeffs: const [0.0, 0.0, 0.0, 0.0],
      );
      expect(json, isNotNull);

      final decoded = decodeSolvedSip(json)!;
      expect(decoded.aOrder, 2);
      expect(decoded.bOrder, 2);
      expect(decoded.aCoeffs[2], closeTo(1.2e-6, 1e-18));
      expect(decoded.bCoeffs[1], closeTo(5.6e-7, 1e-18));
      expect(decoded.apOrder, 1);
      expect(decoded.bpOrder, 1);
    });

    test('no forward distortion encodes to null', () {
      expect(
        encodeSolvedSip(
          aOrder: 0,
          bOrder: 0,
          aCoeffs: const [],
          bCoeffs: const [],
          apOrder: 0,
          bpOrder: 0,
          apCoeffs: const [],
          bpCoeffs: const [],
        ),
        isNull,
      );
      expect(decodeSolvedSip(null), isNull);
      expect(decodeSolvedSip(''), isNull);
    });
  });

  group('captured_images v51 WCS round-trip', () {
    late SkotiqDatabase db;
    late ImagesDao imagesDao;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      imagesDao = ImagesDao(db);
    });

    tearDown(() async {
      await db.close();
    });

    Future<int> insertFrame(String name) => imagesDao.insertSequenceFrame(
      filePath: '/captures/m31/$name',
      fileName: name,
      fileFormat: 'fits',
      exposureDuration: 120.0,
      capturedAt: DateTime.utc(2026, 1, 1, 22, 15, 0),
      isAccepted: true,
      producingNodeId: 'node-wcs',
    );

    test('persists CD matrix + solved_sip and reads them back', () async {
      const scaleArcsec = 1.7;
      const rotationDeg = 19.0;
      const scaleDeg = scaleArcsec / 3600.0;
      final cosR = math.cos(rotationDeg * math.pi / 180.0);
      final sinR = math.sin(rotationDeg * math.pi / 180.0);
      final sipJson = encodeSolvedSip(
        aOrder: 2,
        bOrder: 2,
        aCoeffs: const [0.0, 0.0, 1.1e-6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        bCoeffs: const [0.0, 2.2e-6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        apOrder: 0,
        bpOrder: 0,
        apCoeffs: const [],
        bpCoeffs: const [],
      );

      final id = await insertFrame('L_cd.fits');
      await imagesDao.updatePlateSolveResult(
        id,
        solvedRa: 8.25,
        solvedDec: 17.0,
        solvedRotation: rotationDeg,
        solvedPixelScale: scaleArcsec,
        solvedCd1_1: -scaleDeg * cosR,
        solvedCd1_2: scaleDeg * sinR,
        solvedCd2_1: scaleDeg * sinR,
        solvedCd2_2: scaleDeg * cosR,
        solvedSip: sipJson,
      );

      final stored = (await imagesDao.getStoredWcsDistortion(id))!;
      expect(stored.cd1_1, closeTo(-scaleDeg * cosR, 1e-18));
      expect(stored.cd1_2, closeTo(scaleDeg * sinR, 1e-18));
      expect(stored.cd2_1, closeTo(scaleDeg * sinR, 1e-18));
      expect(stored.cd2_2, closeTo(scaleDeg * cosR, 1e-18));

      final sip = decodeSolvedSip(stored.sip)!;
      final solved = SolvedWcs(
        raHours: 8.25,
        decDegrees: 17.0,
        rotationDeg: rotationDeg,
        pixelScaleArcsec: scaleArcsec,
        imageWidth: 3000,
        imageHeight: 2000,
        cd1_1: stored.cd1_1,
        cd1_2: stored.cd1_2,
        cd2_1: stored.cd2_1,
        cd2_2: stored.cd2_2,
        aOrder: sip.aOrder,
        bOrder: sip.bOrder,
        aCoeffs: sip.aCoeffs,
        bCoeffs: sip.bCoeffs,
      );
      expect(solved.hasCdMatrix, isTrue);
      expect(solved.hasForwardSip, isTrue);

      // The rebuilt projection must be its own inverse to sub-pixel accuracy.
      final proj = GnomonicProjection(solved);
      final world = proj.pixelToWorld(x: 1234.0, y: 876.0);
      final back = proj.worldToPixel(
        raDegrees: world.raDegrees,
        decDegrees: world.decDegrees,
      )!;
      expect(back.pixel.x, closeTo(1234.0, 1e-3));
      expect(back.pixel.y, closeTo(876.0, 1e-3));
    });

    test('isotropic solve leaves CD/SIP null', () async {
      final id = await insertFrame('L_iso.fits');
      await imagesDao.updatePlateSolveResult(
        id,
        solvedRa: 8.25,
        solvedDec: 17.0,
        solvedRotation: 19.0,
        solvedPixelScale: 1.7,
      );

      final stored = (await imagesDao.getStoredWcsDistortion(id))!;
      expect(stored.cd1_1, isNull);
      expect(stored.cd1_2, isNull);
      expect(stored.cd2_1, isNull);
      expect(stored.cd2_2, isNull);
      expect(stored.sip, isNull);

      final solved = SolvedWcs(
        raHours: 8.25,
        decDegrees: 17.0,
        rotationDeg: 19.0,
        pixelScaleArcsec: 1.7,
        imageWidth: 3000,
        imageHeight: 2000,
        cd1_1: stored.cd1_1,
        cd1_2: stored.cd1_2,
        cd2_1: stored.cd2_1,
        cd2_2: stored.cd2_2,
      );
      expect(solved.hasCdMatrix, isFalse);
      expect(solved.hasForwardSip, isFalse);
    });
  });
}
