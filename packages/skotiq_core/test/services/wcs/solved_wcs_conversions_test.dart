// Every form a solve takes in the app (a stored row, an annotation, a fold
// reference, a master's FITS terms, a catalog overlay key) carries the whole
// solution: the reference pixel and the SIP terms included.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show PlateSolveResult;
import 'package:skotiq_core/src/models/annotation_data.dart';
import 'package:skotiq_core/src/models/imaging/sip_terms.dart';
import 'package:skotiq_core/src/providers/catalog_overlay_provider.dart';
import 'package:skotiq_core/src/services/post_session_integration_service.dart'
    show MasterWcsSolution;
import 'package:skotiq_core/src/services/sky_atlas/sky_atlas_models.dart';
import 'package:skotiq_core/src/services/wcs/gnomonic_projection.dart';
import 'package:skotiq_core/src/services/wcs/plate_solve_data_from_result.dart';

/// A master's solve referenced off its centre, with distortion: the form a
/// cropped master or a PixInsight solve has.
final SolvedWcs _offCentre = SolvedWcs.tryFromFits(
  crval1: 40.53,
  crval2: 42.76,
  crpix1: 812.0,
  crpix2: 300.5,
  cd1_1: -2.7e-4,
  cd1_2: 1.1e-5,
  cd2_1: 1.0e-5,
  cd2_2: 2.7e-4,
  sip: (
    aOrder: 2,
    bOrder: 2,
    aCoeffs: const [0, 0, 2e-7, 0, 1e-7, 0, 3e-7, 0, 0],
    bCoeffs: const [0, 0, 1e-7, 0, 2e-7, 0, 1e-7, 0, 0],
    apOrder: 0,
    bpOrder: 0,
    apCoeffs: const [],
    bpCoeffs: const [],
  ),
  imageWidth: 1914,
  imageHeight: 1074,
)!;

PlateSolveResult _result({
  required double cd11,
  required double cd22,
  bool success = true,
}) => PlateSolveResult(
  success: success,
  ra: 40.5,
  dec: 42.8,
  pixelScale: 0.97,
  rotation: 0,
  fieldWidth: 0.5,
  fieldHeight: 0.3,
  solveTimeSecs: 1,
  cd11: cd11,
  cd12: 0,
  cd21: 0,
  cd22: cd22,
  sipAOrder: 0,
  sipBOrder: 0,
  sipACoeffs: Float64List(0),
  sipBCoeffs: Float64List(0),
  sipApOrder: 0,
  sipBpOrder: 0,
  sipApCoeffs: Float64List(0),
  sipBpCoeffs: Float64List(0),
);

void main() {
  test('an annotation of a solve maps the sky as the solve does', () {
    final back = plateSolveDataFromSolvedWcs(_offCentre).toSolvedWcs();
    expect(back.referencePixel, _offCentre.referencePixel);
    expect(back.sip.aCoeffs, _offCentre.sip.aCoeffs);
    final centre = GnomonicProjection(
      back,
    ).worldToPixel(raDegrees: 40.53, decDegrees: 42.76)!;
    expect(centre.pixel.x, closeTo(811.0, 1e-9));
    expect(centre.pixel.y, closeTo(299.5, 1e-9));
  });

  test('a fold reference keeps the solve\'s reference pixel and SIP', () {
    final ref = SolvedFrameRef.fromSolvedWcs(
      framePath: '/m.fits',
      wcs: _offCentre,
    );
    expect((ref.crpix1, ref.crpix2), (812.0, 300.5));
    expect(ref.toWcsJson()['aCoeffs'], _offCentre.sip.aCoeffs);
  });

  test('a solver\'s CD matrix keeps a mirrored frame mirrored, and the '
      'master\'s FITS terms reference the frame centre', () {
    const scale = 0.97 / 3600;
    final mirrored = solvedWcsFromResult(
      _result(cd11: scale, cd22: scale),
      imageWidth: 1914,
      imageHeight: 1074,
    )!;
    expect(mirrored.isMirrored, isTrue);
    final terms = MasterWcsSolution.of(mirrored);
    expect((terms.crpix1, terms.crpix2), (957.5, 537.5));
    expect((terms.cd1_1, terms.cd2_2), (scale, scale));
    expect(terms.crval1, closeTo(40.5, 1e-12));
  });

  test('a failed solve has no projection', () {
    expect(
      solvedWcsFromResult(
        _result(cd11: 0, cd22: 0, success: false),
        imageWidth: 10,
        imageHeight: 10,
      ),
      isNull,
    );
  });

  test('two solves that differ only in their distortion or reference pixel '
      'are two catalog overlay queries', () {
    CatalogOverlayQuery query(SolvedWcs wcs) => CatalogOverlayQuery(
      wcs: wcs,
      magnitudeLimit: 12,
      includeStars: true,
      includeDsos: true,
    );
    final same = SolvedWcs.tryFromFits(
      crval1: 40.53,
      crval2: 42.76,
      crpix1: 812.0,
      crpix2: 300.5,
      cd1_1: -2.7e-4,
      cd1_2: 1.1e-5,
      cd2_1: 1.0e-5,
      cd2_2: 2.7e-4,
      sip: (
        aOrder: 2,
        bOrder: 2,
        aCoeffs: [0, 0, 2e-7, 0, 1e-7, 0, 3e-7, 0, 0],
        bCoeffs: [0, 0, 1e-7, 0, 2e-7, 0, 1e-7, 0, 0],
        apOrder: 0,
        bpOrder: 0,
        apCoeffs: [],
        bpCoeffs: [],
      ),
      imageWidth: 1914,
      imageHeight: 1074,
    )!;
    expect(query(same), query(_offCentre));
    expect(query(same).hashCode, query(_offCentre).hashCode);

    final otherSip = SolvedWcs(
      raHours: _offCentre.raHours,
      decDegrees: _offCentre.decDegrees,
      rotationDeg: _offCentre.rotationDeg,
      pixelScaleArcsec: _offCentre.pixelScaleArcsec,
      imageWidth: 1914,
      imageHeight: 1074,
      cd1_1: _offCentre.cd1_1,
      cd1_2: _offCentre.cd1_2,
      cd2_1: _offCentre.cd2_1,
      cd2_2: _offCentre.cd2_2,
      referenceX: _offCentre.referenceX,
      referenceY: _offCentre.referenceY,
      sip: (
        aOrder: 2,
        bOrder: 2,
        aCoeffs: const [0, 0, 9e-7, 0, 1e-7, 0, 3e-7, 0, 0],
        bCoeffs: _offCentre.sip.bCoeffs,
        apOrder: 0,
        bpOrder: 0,
        apCoeffs: const [],
        bpCoeffs: const [],
      ),
    );
    expect(query(otherSip), isNot(query(_offCentre)));
    final centred = SolvedWcs(
      raHours: _offCentre.raHours,
      decDegrees: _offCentre.decDegrees,
      rotationDeg: _offCentre.rotationDeg,
      pixelScaleArcsec: _offCentre.pixelScaleArcsec,
      imageWidth: 1914,
      imageHeight: 1074,
      cd1_1: _offCentre.cd1_1,
      cd1_2: _offCentre.cd1_2,
      cd2_1: _offCentre.cd2_1,
      cd2_2: _offCentre.cd2_2,
      sip: _offCentre.sip,
    );
    expect(query(centred), isNot(query(_offCentre)));
  });

  test('a stored SIP block decodes to the terms it was encoded from', () {
    final json = encodeSolvedSip(_offCentre.sip)!;
    final decoded = decodeSolvedSip(json)!;
    expect(decoded.aCoeffs, _offCentre.sip.aCoeffs);
    expect(decoded.bOrder, 2);
    expect(encodeSolvedSip(noSipTerms), isNull);
  });
}
