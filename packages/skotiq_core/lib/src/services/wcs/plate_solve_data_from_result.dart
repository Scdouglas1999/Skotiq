import 'package:skotiq_bridge/skotiq_bridge.dart' show PlateSolveResult;

import '../../models/annotation_data.dart';
import 'gnomonic_projection.dart';
import 'wcs_sip_codec.dart';

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
  final hasCd =
      result.cd11 != 0 ||
      result.cd12 != 0 ||
      result.cd21 != 0 ||
      result.cd22 != 0;
  return PlateSolveData(
    ra: result.ra,
    dec: result.dec,
    pixelScale: result.pixelScale,
    rotation: result.rotation,
    fieldWidth: fieldWidth,
    fieldHeight: fieldHeight,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    cd1_1: hasCd ? result.cd11 : null,
    cd1_2: hasCd ? result.cd12 : null,
    cd2_1: hasCd ? result.cd21 : null,
    cd2_2: hasCd ? result.cd22 : null,
    sip: encodeSolvedSip(
      aOrder: result.sipAOrder,
      bOrder: result.sipBOrder,
      aCoeffs: result.sipACoeffs.toList(),
      bCoeffs: result.sipBCoeffs.toList(),
      apOrder: result.sipApOrder,
      bpOrder: result.sipBpOrder,
      apCoeffs: result.sipApCoeffs.toList(),
      bpCoeffs: result.sipBpCoeffs.toList(),
    ),
  );
}

/// The annotation model of a [SolvedWcs] (RA hours become degrees), keeping
/// its CD matrix and SIP terms.
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
  sip: encodeSolvedSip(
    aOrder: wcs.aOrder,
    bOrder: wcs.bOrder,
    aCoeffs: wcs.aCoeffs,
    bCoeffs: wcs.bCoeffs,
    apOrder: wcs.apOrder,
    bpOrder: wcs.bpOrder,
    apCoeffs: wcs.apCoeffs,
    bpCoeffs: wcs.bpCoeffs,
  ),
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
  final distortion = decodeSolvedSip(sip) ?? noSolvedSip;
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
    aOrder: distortion.aOrder,
    bOrder: distortion.bOrder,
    aCoeffs: distortion.aCoeffs,
    bCoeffs: distortion.bCoeffs,
    apOrder: distortion.apOrder,
    bpOrder: distortion.bpOrder,
    apCoeffs: distortion.apCoeffs,
    bpCoeffs: distortion.bpCoeffs,
  );
  return wcs.isValid ? wcs : null;
}
