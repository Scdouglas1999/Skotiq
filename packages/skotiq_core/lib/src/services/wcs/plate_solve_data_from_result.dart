import 'package:skotiq_bridge/skotiq_bridge.dart' show PlateSolveResult;

import '../../database/daos/images_dao.dart' show StoredWcsDistortion;
import '../../database/database.dart' show DbCapturedImage;

import '../../models/annotation_data.dart';
import 'gnomonic_projection.dart';
import '../../models/imaging/sip_terms.dart';

/// The annotation model of a solve, carrying the solver's CD matrix and SIP
/// terms so labels and clicks map through the full WCS (parity included)
/// rather than a scalar rotation. A result with an all-zero CD matrix (a
/// solver that reported none) keeps the isotropic fallback.
PlateSolveData plateSolveDataFromResult(
  PlateSolveResult result, {
  required int imageWidth,
  required int imageHeight,
  required double fieldWidth,
  required double fieldHeight,
}) {
  final cd = result.cdMatrix;
  return PlateSolveData(
    ra: result.ra,
    dec: result.dec,
    pixelScale: result.pixelScale,
    rotation: result.rotation,
    fieldWidth: fieldWidth,
    fieldHeight: fieldHeight,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    cd1_1: cd?.cd1_1,
    cd1_2: cd?.cd1_2,
    cd2_1: cd?.cd2_1,
    cd2_2: cd?.cd2_2,
    sip: encodeSolvedSip(result.sipTerms),
  );
}

/// The projection of a solve over its [imageWidth] x [imageHeight] frame,
/// referenced at the frame centre as every solver reports it, with the
/// solver's CD matrix and SIP terms; null for a failed or unusable solve.
SolvedWcs? solvedWcsFromResult(
  PlateSolveResult result, {
  required int imageWidth,
  required int imageHeight,
}) {
  if (!result.success) return null;
  final cd = result.cdMatrix;
  final wcs = SolvedWcs(
    raHours: result.ra / 15.0,
    decDegrees: result.dec,
    rotationDeg: result.rotation,
    pixelScaleArcsec: result.pixelScale,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    cd1_1: cd?.cd1_1,
    cd1_2: cd?.cd1_2,
    cd2_1: cd?.cd2_1,
    cd2_2: cd?.cd2_2,
    sip: result.sipTerms,
  );
  return wcs.isValid ? wcs : null;
}

extension PlateSolveResultWcs on PlateSolveResult {
  /// The solver's CD matrix (degrees per pixel); null when it reported none,
  /// which a result states as all four terms zero.
  ({double cd1_1, double cd1_2, double cd2_1, double cd2_2})? get cdMatrix =>
      cd11 == 0 && cd12 == 0 && cd21 == 0 && cd22 == 0
      ? null
      : (cd1_1: cd11, cd1_2: cd12, cd2_1: cd21, cd2_2: cd22);

  /// The solve's SIP distortion.
  SipTerms get sipTerms => (
    aOrder: sipAOrder,
    bOrder: sipBOrder,
    aCoeffs: sipACoeffs.toList(growable: false),
    bCoeffs: sipBCoeffs.toList(growable: false),
    apOrder: sipApOrder,
    bpOrder: sipBpOrder,
    apCoeffs: sipApCoeffs.toList(growable: false),
    bpCoeffs: sipBpCoeffs.toList(growable: false),
  );
}

/// The annotation model of a [SolvedWcs] (RA hours become degrees), keeping
/// its CD matrix, SIP terms and reference pixel.
PlateSolveData plateSolveDataFromSolvedWcs(SolvedWcs wcs) => PlateSolveData(
  ra: wcs.raHours * 15.0,
  dec: wcs.decDegrees,
  pixelScale: wcs.pixelScaleArcsec,
  rotation: wcs.rotationDeg,
  fieldWidth: wcs.imageWidth * wcs.pixelScaleArcsec / 3600.0,
  fieldHeight: wcs.imageHeight * wcs.pixelScaleArcsec / 3600.0,
  imageWidth: wcs.imageWidth,
  imageHeight: wcs.imageHeight,
  cd1_1: wcs.hasCdMatrix ? wcs.cd1_1 : null,
  cd1_2: wcs.hasCdMatrix ? wcs.cd1_2 : null,
  cd2_1: wcs.hasCdMatrix ? wcs.cd2_1 : null,
  cd2_2: wcs.hasCdMatrix ? wcs.cd2_2 : null,
  sip: encodeSolvedSip(wcs.sip),
  referenceX: wcs.referenceX,
  referenceY: wcs.referenceY,
);

/// The projection model of a stored solve, or null when the row is not
/// solved. Uses the stored CD matrix and SIP when present.
SolvedWcs? solvedWcsFromStored({
  required double? raHours,
  required double? decDegrees,
  required double? rotationDeg,
  required double? pixelScaleArcsec,
  required int imageWidth,
  required int imageHeight,
  double? cd1_1,
  double? cd1_2,
  double? cd2_1,
  double? cd2_2,
  String? sip,
}) {
  if (raHours == null ||
      decDegrees == null ||
      rotationDeg == null ||
      pixelScaleArcsec == null) {
    return null;
  }
  final wcs = SolvedWcs(
    raHours: raHours,
    decDegrees: decDegrees,
    rotationDeg: rotationDeg,
    pixelScaleArcsec: pixelScaleArcsec,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    cd1_1: cd1_1,
    cd1_2: cd1_2,
    cd2_1: cd2_1,
    cd2_2: cd2_2,
    sip: decodeSolvedSip(sip) ?? noSipTerms,
  );
  return wcs.isValid ? wcs : null;
}

/// The projection of [image]'s stored solve over its [imageWidth] x
/// [imageHeight] pixels, with the [stored] CD matrix and SIP when the solve
/// recorded them; null when the row holds no usable solve. `solvedRa` is in
/// hours, as every writer of the row stores it.
SolvedWcs? storedFrameWcs(
  DbCapturedImage image, {
  StoredWcsDistortion? stored,
  required int imageWidth,
  required int imageHeight,
}) => image.isPlateSolved
    ? solvedWcsFromStored(
        raHours: image.solvedRa,
        decDegrees: image.solvedDec,
        rotationDeg: image.solvedRotation,
        pixelScaleArcsec: image.solvedPixelScale,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        cd1_1: stored?.cd1_1,
        cd1_2: stored?.cd1_2,
        cd2_1: stored?.cd2_1,
        cd2_2: stored?.cd2_2,
        sip: stored?.sip,
      )
    : null;
