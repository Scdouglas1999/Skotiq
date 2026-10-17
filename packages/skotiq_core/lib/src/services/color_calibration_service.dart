import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../models/imaging/color_calibration_result.dart';
import '../models/imaging/star_photometry.dart';
import 'post_session_seam.dart';
import 'wcs_overlay.dart';

/// A cone search over a photometric star catalog: returns the catalog [Star]s
/// within [radiusDegrees] of [center], optionally magnitude-limited.
///
/// Mirrors `HygStarCatalog.getStarsNear`. Injected as a closure so the service
/// is exercisable with an in-memory catalog stub (no on-disk HYG CSV) in tests,
/// while production binds the real catalog.
typedef StarConeSearch =
    Future<List<Star>> Function(
      CelestialCoordinate center,
      double radiusDegrees, {
      double? maxMagnitude,
    });

/// One detected star cross-matched to a catalog star with a known colour index,
/// carrying the per-channel aperture flux the native solver consumes.
class MatchedColorStar {
  /// Background-subtracted per-channel aperture flux of the detected star.
  final List<double> channelFlux;

  /// The matched catalog star's B–V colour index.
  final double catalogBv;

  /// Separation between the detected centroid and the catalog position (arcsec).
  final double separationArcsec;

  const MatchedColorStar({
    required this.channelFlux,
    required this.catalogBv,
    required this.separationArcsec,
  });

  /// The `{channelFlux, catalogBv}` map the native `apiColorCalibrate` consumes.
  Map<String, dynamic> toSeamJson() => {
    'channelFlux': channelFlux,
    'catalogBv': catalogBv,
  };
}

/// Orchestrates **catalog-powered (SPCC-grade) colour calibration** of a
/// finished master, in pure Dart, routing the pixel work through the
/// [PostSessionSeam].
///
/// The pipeline (per the Smart Morning Report design, Pillar 3):
///  1. **Detect + measure** stars on the master via
///     [PostSessionSeam.detectStarsPhotometry] — each detection carries its
///     centroid, SNR, shape, and per-channel aperture flux.
///  2. **Project** each detection's pixel centroid to (RA, Dec) with the
///     supplied [WcsOverlay].
///  3. **Cone-search** the photometric catalog over the master's field and
///     **cross-match** each detection to the nearest catalog star within an
///     arcsecond tolerance, keeping only well-measured, unsaturated, single
///     stars with a known B–V.
///  4. **Solve + apply** the per-channel white balance via
///     [PostSessionSeam.colorCalibrate] from the matched `{channelFlux,
///     catalogBv}` pairs.
///
/// **Fail-soft contract.** When there is no WCS, the field is too sparse, or too
/// few stars cross-match, the service returns a *skipped* result
/// ([ColorCalibrationResult] with `matched == 0`) — never throwing — so a caller
/// can simply keep the un-calibrated master. [wasSkipped] classifies a result.
class ColorCalibrationService {
  ColorCalibrationService({
    required PostSessionSeam seam,
    required StarConeSearch starSearch,
  }) : _seam = seam,
       _starSearch = starSearch;

  final PostSessionSeam _seam;
  final StarConeSearch _starSearch;

  /// Minimum cross-matched stars required to attempt a solve. Below this the
  /// field is too sparse and the result is *skipped* (`matched == 0`).
  static const int minMatchesToCalibrate = 8;

  /// Cross-match tolerance: a detection matches a catalog star only when their
  /// angular separation is within this many arcseconds.
  static const double defaultMatchToleranceArcsec = 5.0;

  /// Detections below this SNR are too noisy for a reliable colour ratio.
  static const double minStarSnr = 10.0;

  /// Detections above this eccentricity are trailed / blended and rejected.
  static const double maxStarEccentricity = 0.7;

  /// **Saturation rejection ceiling.** A detection whose [DetectedStarPhotometry.peak]
  /// reaches this fraction of the rescaled 0..65535 detection-plane full scale is
  /// treated as saturated and rejected: a saturated star clips its brightest
  /// channel first, so its per-channel flux ratio (hence B–V) is systematically
  /// wrong. Because saturated stars are the brightest/highest-SNR detections they
  /// sail through the [minStarSnr] gate, so they must be dropped explicitly — this
  /// is the SPCC "drop saturated stars first" rule. `0.0` peaks (a payload that
  /// predates the native `peak` field) disable the gate rather than reject
  /// everything.
  static const double saturationPeakFraction = 0.9;

  /// Full scale of the rescaled mono detection plane the native `peak` is
  /// measured on (`detect_stars_photometry_impl` rescales into 0..65535).
  static const double detectionPlaneFullScale = 65535.0;

  /// Per-channel "implausibly clipped" guard: when the two brightest channels of
  /// a multi-channel detection are equal to within this relative epsilon AND the
  /// star is near the saturation ceiling, the channels have flat-topped at the
  /// same ADU — a saturation signature that biases colour. Used only as a
  /// belt-and-braces check behind [saturationPeakFraction].
  static const double channelClipRelEpsilon = 1e-3;

  /// A *skipped* result: no calibration was applied. The output path echoes the
  /// (un-calibrated) input so callers can fall back to it transparently.
  static ColorCalibrationResult skipped(String outputPath) =>
      ColorCalibrationResult(
        outputPath: outputPath,
        channelScale: const [],
        matched: 0,
        residual: 0.0,
      );

  /// Whether [result] is the fail-soft *skipped* sentinel (no stars matched).
  static bool wasSkipped(ColorCalibrationResult? result) =>
      result == null || result.matched == 0;

  /// Calibrate [masterFits], writing the rebalanced master to [outputFits].
  ///
  /// [wcs] is the master's solved WCS; pass `null` (or omit) when the master is
  /// un-solved — the call then fail-softs to [skipped]. [channels] is the
  /// master's channel count (the per-star `channelFlux` length). [whiteRefBv] is
  /// the optional white-reference colour index forwarded to the solver.
  ///
  /// Returns the native [ColorCalibrationResult] on success, or a [skipped]
  /// result when there is no WCS or too few cross-matches.
  Future<ColorCalibrationResult> calibrate({
    required String masterFits,
    required String outputFits,
    required WcsOverlay? wcs,
    required int channels,
    double? whiteRefBv,
    double matchToleranceArcsec = defaultMatchToleranceArcsec,
    int? maxStars,
    int? aperture,
  }) async {
    // No WCS → we cannot place detections on the sky. Skip, keep the master.
    if (wcs == null) return skipped(outputFits);

    final photometry = await _seam.detectStarsPhotometry(
      inputFits: masterFits,
      maxStars: maxStars,
      aperture: aperture,
    );
    if (photometry.stars.isEmpty) return skipped(outputFits);

    final matched = crossMatch(
      photometry: photometry,
      wcs: wcs,
      catalog: await _coneSearchForField(photometry, wcs),
      matchToleranceArcsec: matchToleranceArcsec,
      channels: channels,
    );

    if (matched.length < minMatchesToCalibrate) return skipped(outputFits);

    return _seam.colorCalibrate(
      inputFits: masterFits,
      outputFits: outputFits,
      channels: channels,
      whiteRefBv: whiteRefBv,
      matchedStars: [for (final m in matched) m.toSeamJson()],
    );
  }

  /// Cone-search the catalog over the master's field: centre on the WCS
  /// reference, radius = half the frame diagonal (with a small margin).
  Future<List<Star>> _coneSearchForField(
    StarPhotometryResult photometry,
    WcsOverlay wcs,
  ) {
    final halfDiagDeg =
        0.5 *
        math.sqrt(
          math.pow(photometry.width * wcs.cdelt1, 2) +
              math.pow(photometry.height * wcs.cdelt2, 2),
        );
    final radiusDeg = (halfDiagDeg.abs() * 1.1).clamp(0.05, 30.0);
    // `getStarsNear` takes RA in *hours* on its `CelestialCoordinate`; the WCS
    // reference RA (`crval1`) is in degrees.
    final center = CelestialCoordinate(ra: wcs.crval1 / 15.0, dec: wcs.crval2);
    return _starSearch(center, radiusDeg);
  }

  /// Cross-match detected stars to [catalog] stars with a known colour index.
  ///
  /// For each well-measured, unsaturated, single detection, project its centroid
  /// to (RA, Dec). The match is then a **stable global-greedy nearest-first**
  /// assignment, independent of detection iteration order: every (detection,
  /// catalog-star) pair within [matchToleranceArcsec] is collected, sorted by
  /// separation ascending, and assigned nearest-first while marking both the
  /// detection and the catalog star consumed. This delivers the documented
  /// "nearest-detection wins" contract — the closer of two detections competing
  /// for one catalog star takes it, not whichever happened to be iterated first.
  ///
  /// **Blend rejection.** A detection is discarded outright when a *second*
  /// catalog star also lies within tolerance of it: we cannot say which catalog
  /// B–V the detection belongs to, so pairing it either way would inject a wrong
  /// colour. (The mirror case — one catalog star within tolerance of two
  /// detections — is *not* a blend; it is exactly what nearest-detection-wins
  /// resolves, so the closer detection takes the star and the farther one is
  /// left to find its own.)
  ///
  /// Exposed for testing.
  List<MatchedColorStar> crossMatch({
    required StarPhotometryResult photometry,
    required WcsOverlay wcs,
    required List<Star> catalog,
    required int channels,
    double matchToleranceArcsec = defaultMatchToleranceArcsec,
  }) {
    final colored = [
      for (final s in catalog)
        if (s.colorIndex != null) s,
    ];
    if (colored.isEmpty) return const [];

    // Usable detections, paired with their projected sky position and a stable
    // index. Order-independence below relies on these indices, not list order.
    final detections =
        <({int idx, DetectedStarPhotometry star, double ra, double dec})>[];
    for (final star in photometry.stars) {
      if (!_isUsableDetection(star, channels)) continue;
      final (ra, dec) = wcs.pixelToCelestial(star.x, star.y);
      detections.add((idx: detections.length, star: star, ra: ra, dec: dec));
    }
    if (detections.isEmpty) return const [];

    // All within-tolerance candidate pairs, plus a per-detection partner count
    // so we can drop ambiguous blends (a detection with >1 catalog star in
    // range — we cannot say which colour it is).
    final candidates = <({int detIdx, int catIdx, double sep})>[];
    final detPartnerCount = List<int>.filled(detections.length, 0);
    for (final d in detections) {
      for (var c = 0; c < colored.length; c++) {
        final cat = colored[c];
        final sep = _angularSeparationArcsec(
          d.ra,
          d.dec,
          cat.coordinates.raDegrees,
          cat.coordinates.dec,
        );
        if (sep <= matchToleranceArcsec) {
          candidates.add((detIdx: d.idx, catIdx: c, sep: sep));
          detPartnerCount[d.idx]++;
        }
      }
    }
    if (candidates.isEmpty) return const [];

    // Nearest-first global assignment. Sort by separation (tie-broken by stable
    // indices so the result is deterministic regardless of input order), then
    // claim the closest still-free pair. A detection that is an ambiguous blend
    // (more than one catalog star within tolerance) is dropped; a catalog star
    // contested by several detections is simply won by the closest one (the
    // nearest-detection-wins contract).
    candidates.sort((a, b) {
      final c = a.sep.compareTo(b.sep);
      if (c != 0) return c;
      final d = a.detIdx.compareTo(b.detIdx);
      return d != 0 ? d : a.catIdx.compareTo(b.catIdx);
    });

    final usedDet = List<bool>.filled(detections.length, false);
    final usedCat = List<bool>.filled(colored.length, false);
    final matches = <MatchedColorStar>[];
    for (final pair in candidates) {
      if (usedDet[pair.detIdx] || usedCat[pair.catIdx]) continue;
      if (detPartnerCount[pair.detIdx] > 1) {
        // Ambiguous blend: burn the detection so neither of its catalog stars
        // mis-binds to it, but leave those catalog stars free for an unambiguous
        // detection elsewhere.
        usedDet[pair.detIdx] = true;
        continue;
      }
      usedDet[pair.detIdx] = true;
      usedCat[pair.catIdx] = true;
      matches.add(
        MatchedColorStar(
          channelFlux: detections[pair.detIdx].star.channelFlux,
          catalogBv: colored[pair.catIdx].colorIndex!,
          separationArcsec: pair.sep,
        ),
      );
    }

    return matches;
  }

  /// A detection is usable for colour calibration when it is bright enough,
  /// round (not trailed/blended), finite/positive in every channel, carries the
  /// expected [channels] count, and is **not saturated** — a saturated star
  /// clips its brightest channel first and so reports a wrong colour ratio.
  bool _isUsableDetection(DetectedStarPhotometry star, int channels) {
    if (star.snr < minStarSnr) return false;
    if (star.eccentricity > maxStarEccentricity) return false;
    if (star.channelFlux.length != channels) return false;
    for (final f in star.channelFlux) {
      if (!f.isFinite || f <= 0) return false;
    }
    if (_isSaturated(star)) return false;
    return true;
  }

  /// Saturation gate. Primary criterion: the detection peak is at/near the
  /// rescaled detection-plane ceiling ([saturationPeakFraction] of
  /// [detectionPlaneFullScale]). Backstop: when the peak is plausibly high, two
  /// channels that flat-top at the same ADU (within [channelClipRelEpsilon])
  /// betray a clip. A `peak <= 0` (payload without the native field) disables
  /// the gate rather than rejecting every star.
  bool _isSaturated(DetectedStarPhotometry star) {
    if (star.peak <= 0) return false;
    if (star.peak >= saturationPeakFraction * detectionPlaneFullScale) {
      return true;
    }
    // Belt-and-braces per-channel clip detection: only meaningful when the star
    // is already bright (peak above half scale) and multi-channel.
    if (star.channelFlux.length >= 2 &&
        star.peak >= 0.5 * detectionPlaneFullScale) {
      final sorted = [...star.channelFlux]..sort((a, b) => b.compareTo(a));
      final top = sorted[0];
      final next = sorted[1];
      if (top > 0 && (top - next).abs() <= top * channelClipRelEpsilon) {
        return true;
      }
    }
    return false;
  }

  /// Great-circle separation between two (RA, Dec) points in degrees, returned
  /// in arcseconds. Uses the haversine formula for stability at small angles.
  static double _angularSeparationArcsec(
    double ra1Deg,
    double dec1Deg,
    double ra2Deg,
    double dec2Deg,
  ) {
    const deg2rad = math.pi / 180.0;
    final dRa = (ra2Deg - ra1Deg) * deg2rad;
    final dDec = (dec2Deg - dec1Deg) * deg2rad;
    final lat1 = dec1Deg * deg2rad;
    final lat2 = dec2Deg * deg2rad;
    final a =
        math.sin(dDec / 2) * math.sin(dDec / 2) +
        math.cos(lat1) * math.cos(lat2) * math.sin(dRa / 2) * math.sin(dRa / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return c / deg2rad * 3600.0;
  }
}

/// Provider for the [ColorCalibrationService]. The star cone search binds the
/// real on-disk HYG catalog; tests override [postSessionSeamProvider] and may
/// construct the service directly with an in-memory [StarConeSearch] stub.
final colorCalibrationServiceProvider = Provider<ColorCalibrationService>((
  ref,
) {
  final catalog = HygStarCatalog();
  return ColorCalibrationService(
    seam: ref.watch(postSessionSeamProvider),
    starSearch: catalog.getStarsNear,
  );
});
