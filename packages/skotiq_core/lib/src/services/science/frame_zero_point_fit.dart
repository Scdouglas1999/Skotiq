import 'dart:math' as math;

import 'photometric_bands.dart';
import 'photometric_catalog_service.dart';

/// One detected star matched to a catalog star.
typedef ZeroPointMatch = ({
  double flux,
  PhotometricCatalogStar catalogStar,
  double separationPx,
});

/// Result of [fitFrameZeroPoint]: a zero point, or the reason none is given.
class FrameZeroPointFit {
  const FrameZeroPointFit({
    required this.band,
    required this.bandIsStandard,
    required this.starCount,
    this.zeroPoint,
    this.zeroPointError,
    this.rms,
    this.medianSeparationPx,
    this.rejectionReason,
  });

  final PhotometricBand band;
  final bool bandIsStandard;

  /// Stars left after clipping (or matched, for a refused fit).
  final int starCount;
  final double? zeroPoint;

  /// Standard error of the zero point: 1.2533·σ/√N for a median.
  final double? zeroPointError;

  /// Per-star scatter about the zero point.
  final double? rms;
  final double? medianSeparationPx;
  final String? rejectionReason;
}

/// Fewest clipped stars a zero point is given from.
const int kMinZeroPointStars = 10;

/// Largest per-star scatter (mag) a zero point is given with. Real fits on
/// broadband filters scatter 0.05–0.18 mag, most of it the color spread of
/// the field; catalog stars paired with the wrong detections scatter by
/// magnitudes.
const double kMaxZeroPointRms = 0.25;

/// Largest median catalog-to-detection offset, as a fraction of the match
/// radius. Real matches sit within a pixel or two; pairs that only fell
/// inside the radius by chance spread over it (median about 0.7 of it).
const double kMaxMedianSeparationFraction = 0.4;

/// Fit a frame's zero point in the catalog band [mapping] names:
/// `ZP = median(m_cat − m_inst)` with `m_inst = −2.5·log10(flux / t)`.
///
/// The fit is refused, with a reason, when the matches do not line up with
/// the catalog, when too few stars remain, or when their scatter is too large
/// for the zero point to mean anything. When fewer than
/// [kMinZeroPointStars] matched stars have a magnitude in the filter's band
/// (no Sloan r' in an older catalog cache), the fit falls back to V and is
/// marked non-standard.
FrameZeroPointFit fitFrameZeroPoint({
  required List<ZeroPointMatch> matches,
  required double exposureSeconds,
  required FilterBandMapping mapping,
  required double maxMatchPx,
  bool brighterHalfOnly = true,
}) {
  var band = mapping.band;
  var standard = mapping.isStandard;
  bool hasBand(ZeroPointMatch m, PhotometricBand b) =>
      m.catalogStar.magIn(b) != null;
  if (matches.where((m) => hasBand(m, band)).length < kMinZeroPointStars &&
      band != PhotometricBand.johnsonV) {
    band = PhotometricBand.johnsonV;
    standard = false;
  }
  FrameZeroPointFit refuse(String reason, {int? count, double? rms}) =>
      FrameZeroPointFit(
        band: band,
        bandIsStandard: standard,
        starCount: count ?? matches.length,
        rms: rms,
        rejectionReason: reason,
      );

  final separations = matches.map((m) => m.separationPx).toList()..sort();
  final medianSeparation = separations.isEmpty
      ? double.infinity
      : separations[separations.length ~/ 2];
  if (medianSeparation > kMaxMedianSeparationFraction * maxMatchPx) {
    return refuse(
      'catalog stars do not line up with the detected stars (median offset '
      '${medianSeparation.toStringAsFixed(1)} px), so the matches are '
      'chance pairs',
    );
  }

  // Detector fluxes are summed inside each star's own footprint, which
  // reaches less far into the wings of a faint star, and less far still in
  // poor seeing; low in the sky that biases the zero point faint. With such
  // fluxes ([brighterHalfOnly]) only the brighter half of the matched stars
  // is used, which carries much less of that loss.
  final usable = matches
      .where((m) => m.flux > 0 && m.flux.isFinite)
      .toList(growable: false);
  final List<ZeroPointMatch> fitted;
  if (brighterHalfOnly && usable.length >= 2 * kMinZeroPointStars) {
    final sorted = usable.toList()..sort((a, b) => b.flux.compareTo(a.flux));
    fitted = sorted.sublist(0, (sorted.length + 1) ~/ 2);
  } else {
    fitted = usable;
  }
  final samples = <double>[];
  for (final m in fitted) {
    final catalogMag = m.catalogStar.magIn(band);
    if (catalogMag == null || !catalogMag.isFinite) continue;
    final bv = m.catalogStar.colorIndexBv;
    final reference = mapping.colorTermBv == 0
        ? catalogMag
        : (bv == null ? null : catalogMag + mapping.colorTermBv * bv);
    if (reference == null) continue;
    final rate = m.flux / exposureSeconds;
    if (!(rate > 0) || !rate.isFinite) continue;
    final sample = reference + 2.5 * math.log(rate) / math.ln10;
    if (sample.isFinite) samples.add(sample);
  }
  final clipped = _sigmaClip(samples, sigma: 2.8, iterations: 4);
  if (clipped.length < kMinZeroPointStars) {
    return refuse(
      '${clipped.length} catalog stars fit; $kMinZeroPointStars needed',
      count: clipped.length,
    );
  }
  final zp = _median(clipped);
  final rms = math.sqrt(
    clipped.map((v) => (v - zp) * (v - zp)).reduce((a, b) => a + b) /
        clipped.length,
  );
  if (rms > kMaxZeroPointRms) {
    return refuse(
      'star-to-star scatter ${rms.toStringAsFixed(2)} mag is above '
      '$kMaxZeroPointRms mag',
      count: clipped.length,
      rms: rms,
    );
  }
  return FrameZeroPointFit(
    band: band,
    bandIsStandard: standard,
    starCount: clipped.length,
    zeroPoint: zp,
    zeroPointError: 1.2533 * rms / math.sqrt(clipped.length),
    rms: rms,
    medianSeparationPx: medianSeparation,
  );
}

double _median(List<double> values) {
  final sorted = values.toList()..sort();
  final n = sorted.length;
  if (n == 0) return double.nan;
  return n.isOdd ? sorted[n ~/ 2] : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
}

/// Iterative clip about the median using the MAD-based sigma.
List<double> _sigmaClip(
  List<double> values, {
  required double sigma,
  required int iterations,
}) {
  var current = values.toList();
  for (var i = 0; i < iterations; i++) {
    if (current.length < 3) break;
    final med = _median(current);
    final mad = _median(current.map((v) => (v - med).abs()).toList());
    final s = 1.4826 * mad;
    if (s <= 0) break;
    final next = current.where((v) => (v - med).abs() <= sigma * s).toList();
    if (next.length == current.length) break;
    current = next;
  }
  return current;
}
