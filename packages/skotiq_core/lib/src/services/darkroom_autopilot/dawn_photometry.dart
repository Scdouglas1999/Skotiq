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


import 'package:skotiq_astro/skotiq_astro.dart';

import '../color_calibration_service.dart' show StarConeSearch;
import '../calibration/fits_header_reader.dart';
import '../wcs/gnomonic_projection.dart';
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

  const DawnPhotometry.resolved(List<Map<String, dynamic>> stars)
    : this._(stars, null);

  /// A field the autopilot could not lend photometry for.
  const DawnPhotometry.unavailable(String reason) : this._(const [], reason);

  /// True when at least one colour-indexed star was found.
  bool get hasStars => stars.isNotEmpty;
}

/// Reads the catalogue stars covering a master's field.
class DawnPhotometryResolver {
  /// Production uses the shared APASS cache/online service with HYG fallback.
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
  /// A library row may lack WCS even when the integrated FITS is solved.
  /// Read its header before declaring the field unavailable.
  Future<DawnPhotometry> resolve({
    required DawnMaster master,
    required SolvedWcs? wcs,
  }) async {
    if (wcs == null) {
      try {
        final header = await const FitsHeaderReader().readPrimaryHeader(
          master.masterFitsPath,
        );
        double? value(String key) => FitsHeaderReader.doubleValue(header, key);
        wcs = SolvedWcs.tryFromFitsCd(
          crval1: value('CRVAL1'),
          crval2: value('CRVAL2'),
          crpix1: value('CRPIX1'),
          crpix2: value('CRPIX2'),
          cd1_1: value('CD1_1'),
          cd1_2: value('CD1_2'),
          cd2_1: value('CD2_1'),
          cd2_2: value('CD2_2'),
          imageWidth: master.width,
          imageHeight: master.height,
        );
      } catch (error) {
        return DawnPhotometry.unavailable(
          'the library has no solved astrometry and the master FITS header '
          'could not be read: $error',
        );
      }
    }
    if (wcs == null) {
      return const DawnPhotometry.unavailable(
        'this master carries no solved astrometry, so its field cannot be '
        'placed on the sky and no catalog star can be matched to it',
      );
    }
    if (master.width <= 0 || master.height <= 0) {
      return const DawnPhotometry.unavailable(
        'this master records no pixel dimensions, so the field it covers is '
        'unknown',
      );
    }

    final radiusDeg = wcs.coneSearchRadiusDegrees;
    final centre = GnomonicProjection(wcs).imageCentre;
    final found = await _coneSearch(
      CelestialCoordinate(ra: centre.raDegrees / 15.0, dec: centre.decDegrees),
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
        'the installed catalog holds no color-indexed star inside this '
        "master's ${radiusDeg.toStringAsFixed(2)}° field, so there is nothing "
        'for the color fit to regress against',
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
}
