/// The photometry the dawn autopilot lends a Darkroom render.
///
/// `color_calibrate@1` fits a Johnson B−V colour-versus-flux regression against
/// stars the CALLER supplies: nothing photometric ships in a form the native
/// side can read on its own. With no stars attached the operation records itself
/// as explicitly skipped with that reason, which is honest but leaves every
/// colour master un-calibrated — so the autopilot resolves the field's catalogue
/// stars here and hands them over.
///
/// Two things can stop it, and each is stated rather than passed through as an
/// empty list: a master with no solved WCS cannot be placed on the sky at all,
/// and a catalogue with no colour-indexed star in the field has nothing to fit.
library;

import 'dart:math' as math;

import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../color_calibration_service.dart' show StarConeSearch;
import '../wcs_overlay.dart';
import 'dawn_master_resolver.dart';

/// The catalogue stars for one master's field, or the reason there are none.
class DawnPhotometry {
  /// One entry per usable catalogue star, in the `catalogStars` wire shape the
  /// Darkroom context takes: `{raDeg, decDeg, vMag, bMinusV}`.
  final List<Map<String, dynamic>> stars;

  /// Why the list is empty, in the words the morning report prints. Null when
  /// stars were found.
  final String? unavailableReason;

  const DawnPhotometry._(this.stars, this.unavailableReason);

  /// A resolved field.
  const DawnPhotometry.resolved(List<Map<String, dynamic>> stars)
    : this._(stars, null);

  /// A field the autopilot could not lend photometry for.
  const DawnPhotometry.unavailable(String reason) : this._(const [], reason);

  /// True when at least one colour-indexed star was found.
  bool get hasStars => stars.isNotEmpty;
}

/// Reads the catalogue stars covering a master's field.
class DawnPhotometryResolver {
  /// The catalogue cone search. Production binds the on-disk HYG catalogue —
  /// the same closure [ColorCalibrationService] takes — and a test binds an
  /// in-memory list.
  final StarConeSearch _coneSearch;

  /// Faintest catalogue V magnitude requested, matching `color_calibrate@1`'s
  /// own `magLimit` default so the stars handed over are the stars the fit
  /// would have asked for.
  final double magnitudeLimit;

  const DawnPhotometryResolver({
    required StarConeSearch coneSearch,
    this.magnitudeLimit = 17.0,
  }) : _coneSearch = coneSearch;

  /// Catalogue stars for [master]'s field.
  ///
  /// [wcs] is the master's solved astrometry; a null overlay means the master
  /// was never plate-solved, which is a stated reason and not an empty result.
  Future<DawnPhotometry> resolve({
    required DawnMaster master,
    required WcsOverlay? wcs,
  }) async {
    if (wcs == null) {
      return const DawnPhotometry.unavailable(
        'this master carries no solved astrometry, so its field cannot be '
        'placed on the sky and no catalogue star can be matched to it',
      );
    }
    if (master.width <= 0 || master.height <= 0) {
      return const DawnPhotometry.unavailable(
        'this master records no pixel dimensions, so the field it covers is '
        'unknown',
      );
    }

    final radiusDeg = _fieldRadiusDegrees(master, wcs);
    final centre = CelestialCoordinate(ra: wcs.crval1 / 15.0, dec: wcs.crval2);
    final found = await _coneSearch(
      centre,
      radiusDeg,
      maxMagnitude: magnitudeLimit,
    );

    final stars = <Map<String, dynamic>>[];
    for (final star in found) {
      final bv = star.colorIndex;
      final v = star.magnitude;
      if (bv == null || v == null) continue;
      if (!bv.isFinite || !v.isFinite) continue;
      final ra = star.coordinates.raDegrees;
      final dec = star.coordinates.dec;
      if (!ra.isFinite || !dec.isFinite) continue;
      stars.add({'raDeg': ra, 'decDeg': dec, 'vMag': v, 'bMinusV': bv});
    }

    if (stars.isEmpty) {
      return DawnPhotometry.unavailable(
        'the installed catalogue holds no colour-indexed star inside this '
        "master's ${radiusDeg.toStringAsFixed(2)}° field, so there is nothing "
        'for the colour fit to regress against',
      );
    }
    // Fixed order by right ascension, then declination, then magnitude: the
    // native side sorts the same way, and sorting here keeps two runs over the
    // same field byte-identical even when the catalogue changes its row order.
    stars.sort((a, b) {
      final byRa = (a['raDeg'] as double).compareTo(b['raDeg'] as double);
      if (byRa != 0) return byRa;
      final byDec = (a['decDeg'] as double).compareTo(b['decDeg'] as double);
      if (byDec != 0) return byDec;
      return (a['vMag'] as double).compareTo(b['vMag'] as double);
    });
    return DawnPhotometry.resolved(List.unmodifiable(stars));
  }

  /// Half the frame diagonal in degrees, with the 10 % margin the colour
  /// calibrator already uses, clamped to the range a catalogue cone search
  /// answers usefully.
  static double _fieldRadiusDegrees(DawnMaster master, WcsOverlay wcs) {
    final halfDiagonal =
        0.5 *
        math.sqrt(
          math.pow(master.width * wcs.cdelt1, 2) +
              math.pow(master.height * wcs.cdelt2, 2),
        );
    return (halfDiagonal.abs() * 1.1).clamp(0.05, 30.0);
  }
}

/// Rebuild a [WcsOverlay] from the CD-matrix scalars an `integrated_masters`
/// row persists, or null when the master was never solved. The inversion is
/// [WcsOverlay.fromCd], which keeps the matrix's parity.
WcsOverlay? overlayFromMasterWcs({
  required double? crval1,
  required double? crval2,
  required double? crpix1,
  required double? crpix2,
  required double? cd11,
  required double? cd12,
  required double? cd21,
  required double? cd22,
}) {
  if (crval1 == null ||
      crval2 == null ||
      crpix1 == null ||
      crpix2 == null ||
      cd11 == null ||
      cd12 == null ||
      cd21 == null ||
      cd22 == null) {
    return null;
  }
  if (cd11 * cd22 - cd12 * cd21 == 0.0) return null;
  return WcsOverlay.fromCd(
    crpix1: crpix1,
    crpix2: crpix2,
    crval1: crval1,
    crval2: crval2,
    cd1_1: cd11,
    cd1_2: cd12,
    cd2_1: cd21,
    cd2_2: cd22,
  );
}
