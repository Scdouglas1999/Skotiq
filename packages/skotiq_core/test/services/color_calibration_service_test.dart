import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/imaging/color_calibration_result.dart';
import 'package:skotiq_core/src/models/imaging/star_photometry.dart';
import 'package:skotiq_core/src/services/color_calibration_service.dart';
import 'package:skotiq_core/src/services/post_session_seam.dart';
import 'package:skotiq_core/src/services/wcs_overlay.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Minimal scriptable [PostSessionSeam]: records the photometry + calibrate
/// calls and returns canned results. Only the two methods the colour-cal
/// service uses are meaningful; the rest throw if ever reached.
class _FakeSeam implements PostSessionSeam {
  StarPhotometryResult photometry = StarPhotometryResult.empty;

  /// The args of the (single) `colorCalibrate` call, or null if never called.
  List<Map<String, dynamic>>? lastMatchedStars;
  int? lastChannels;

  @override
  Future<StarPhotometryResult> detectStarsPhotometry({
    required String inputFits,
    int? maxStars,
    int? aperture,
  }) async => photometry;

  @override
  Future<ColorCalibrationResult> colorCalibrate({
    required String inputFits,
    required String outputFits,
    required int channels,
    double? whiteRefBv,
    required List<Map<String, dynamic>> matchedStars,
  }) async {
    lastMatchedStars = matchedStars;
    lastChannels = channels;
    return ColorCalibrationResult(
      outputPath: outputFits,
      channelScale: List<double>.filled(channels, 1.0),
      matched: matchedStars.length,
      residual: 0.01,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not scripted');
}

/// A 3-channel detection at pixel ([x], [y]) with the given per-channel flux,
/// high SNR and round shape so it passes the usability gate.
DetectedStarPhotometry _det(
  double x,
  double y, {
  List<double> flux = const [1000.0, 900.0, 800.0],
  double snr = 50.0,
  double ecc = 0.1,
  double peak = 1000.0,
}) => DetectedStarPhotometry(
  x: x,
  y: y,
  flux: flux[0],
  snr: snr,
  hfr: 2.0,
  fwhm: 3.0,
  eccentricity: ecc,
  peak: peak,
  channelFlux: flux,
);

/// A catalog star at (RA°, Dec°) with colour index [bv].
Star _star(String id, double raDeg, double decDeg, {double? bv}) => Star(
  id: id,
  name: id,
  coordinates: CelestialCoordinate(ra: raDeg / 15.0, dec: decDeg),
  magnitude: 8.0,
  colorIndex: bv,
);

void main() {
  // Identity-ish WCS centred at RA=10°, Dec=20°, 1"/px, 100×100, no rotation.
  // crpix at the centre so pixel (50,50) ≈ the reference coordinate.
  WcsOverlay buildWcs() => WcsOverlay(
    crpix1: 50,
    crpix2: 50,
    crval1: 10.0,
    crval2: 20.0,
    cdelt1: 1.0 / 3600.0,
    cdelt2: 1.0 / 3600.0,
  );

  late _FakeSeam seam;
  setUp(() => seam = _FakeSeam());

  test('cross-match picks the nearest colour-indexed star and forms '
      'matchedStars', () {
    final wcs = buildWcs();
    final service = ColorCalibrationService(
      seam: seam,
      starSearch: (_, __, {maxMagnitude}) async => const [],
    );

    // One detection at the reference pixel → projects to ≈ (10°, 20°).
    final (ra, dec) = wcs.pixelToCelestial(50, 50);

    final photometry = StarPhotometryResult(
      width: 100,
      height: 100,
      channels: 3,
      stars: [
        _det(50, 50, flux: const [1200.0, 1000.0, 800.0]),
      ],
    );

    // Two catalog stars: one essentially on top of the detection (with B-V),
    // one far away. Cross-match must select the near one.
    final catalog = [
      _star('near', ra, dec, bv: 0.65),
      _star('far', ra + 0.5, dec + 0.5, bv: 1.4),
    ];

    final matched = service.crossMatch(
      photometry: photometry,
      wcs: wcs,
      catalog: catalog,
      channels: 3,
    );

    expect(matched, hasLength(1));
    expect(matched.single.catalogBv, 0.65);
    expect(matched.single.channelFlux, const [1200.0, 1000.0, 800.0]);
    expect(matched.single.separationArcsec, lessThan(1.0));
  });

  test('cross-match rejects blends/low-SNR/wrong-channel detections', () {
    final wcs = buildWcs();
    final service = ColorCalibrationService(
      seam: seam,
      starSearch: (_, __, {maxMagnitude}) async => const [],
    );
    final (ra, dec) = wcs.pixelToCelestial(50, 50);

    final photometry = StarPhotometryResult(
      width: 100,
      height: 100,
      channels: 3,
      stars: [
        _det(50, 50, snr: 2.0), // too noisy
        _det(50, 50, ecc: 0.95), // trailed/blended
        _det(50, 50, flux: const [1000.0, 900.0]), // wrong channel count
      ],
    );
    final catalog = [_star('near', ra, dec, bv: 0.5)];

    final matched = service.crossMatch(
      photometry: photometry,
      wcs: wcs,
      catalog: catalog,
      channels: 3,
    );
    expect(matched, isEmpty);
  });

  test('cross-match rejects saturated detections (peak at the ceiling)', () {
    final wcs = buildWcs();
    final service = ColorCalibrationService(
      seam: seam,
      starSearch: (_, __, {maxMagnitude}) async => const [],
    );
    final (ra, dec) = wcs.pixelToCelestial(50, 50);

    // A bright, round, high-SNR detection — exactly the kind a naive matcher
    // keeps — but its peak sits at the detection-plane ceiling: saturated, so
    // its colour ratio is unreliable and it must be dropped.
    const saturatedPeak =
        ColorCalibrationService.detectionPlaneFullScale; // 65535
    final photometry = StarPhotometryResult(
      width: 100,
      height: 100,
      channels: 3,
      stars: [_det(50, 50, snr: 200.0, peak: saturatedPeak)],
    );
    final catalog = [_star('near', ra, dec, bv: 0.5)];

    final matched = service.crossMatch(
      photometry: photometry,
      wcs: wcs,
      catalog: catalog,
      channels: 3,
    );
    expect(matched, isEmpty);

    // The same star below the saturation ceiling DOES match — proving the gate
    // is the discriminator, not some other filter.
    final unsat = StarPhotometryResult(
      width: 100,
      height: 100,
      channels: 3,
      stars: [
        _det(
          50,
          50,
          snr: 200.0,
          peak: 0.5 * ColorCalibrationService.detectionPlaneFullScale,
        ),
      ],
    );
    final matched2 = service.crossMatch(
      photometry: unsat,
      wcs: wcs,
      catalog: catalog,
      channels: 3,
    );
    expect(matched2, hasLength(1));
  });

  test(
    'cross-match rejects channel-clipped (flat-topped) bright detections',
    () {
      final wcs = buildWcs();
      final service = ColorCalibrationService(
        seam: seam,
        starSearch: (_, __, {maxMagnitude}) async => const [],
      );
      final (ra, dec) = wcs.pixelToCelestial(50, 50);

      // Bright (peak above half scale) with two channels flat-topped at the same
      // ADU — a clip signature even though the peak is below the hard ceiling.
      final photometry = StarPhotometryResult(
        width: 100,
        height: 100,
        channels: 3,
        stars: [
          _det(
            50,
            50,
            snr: 150.0,
            peak: 0.7 * ColorCalibrationService.detectionPlaneFullScale,
            flux: const [5000.0, 5000.0, 3000.0],
          ),
        ],
      );
      final catalog = [_star('near', ra, dec, bv: 0.5)];

      final matched = service.crossMatch(
        photometry: photometry,
        wcs: wcs,
        catalog: catalog,
        channels: 3,
      );
      expect(matched, isEmpty);
    },
  );

  test('cross-match is order-independent: the NEARER detection wins a contested '
      'catalog star (not the first iterated)', () {
    final wcs = buildWcs();
    final service = ColorCalibrationService(
      seam: seam,
      starSearch: (_, __, {maxMagnitude}) async => const [],
    );

    // One catalog star at the centre. Two detections compete for it: the FAR one
    // is iterated FIRST, the NEAR one second. Old "first-iterated wins" would
    // bind the far detection; nearest-detection-wins must bind the near one.
    final (cra, cdec) = wcs.pixelToCelestial(50, 50);
    final catalog = [_star('center', cra, cdec, bv: 0.77)];

    // Far detection 4" away (within the 5" tolerance), near detection ~0".
    const farFlux = [111.0, 222.0, 333.0];
    const nearFlux = [1200.0, 1000.0, 800.0];
    final photometry = StarPhotometryResult(
      width: 100,
      height: 100,
      channels: 3,
      stars: [
        _det(54, 50, flux: farFlux), // 4 px = 4" off — iterated first
        _det(50, 50, flux: nearFlux), // on the star — iterated second
      ],
    );

    final matched = service.crossMatch(
      photometry: photometry,
      wcs: wcs,
      catalog: catalog,
      channels: 3,
    );

    // Exactly one match (the catalog star is consumed once) and it carries the
    // NEAR detection's flux, regardless of iteration order.
    expect(matched, hasLength(1));
    expect(matched.single.catalogBv, 0.77);
    expect(matched.single.channelFlux, nearFlux);
  });

  test('cross-match drops genuine blends rather than mis-pairing them', () {
    final wcs = buildWcs();
    final service = ColorCalibrationService(
      seam: seam,
      starSearch: (_, __, {maxMagnitude}) async => const [],
    );

    // One detection sits within tolerance of TWO catalog stars (both ~2" away on
    // opposite sides) → ambiguous blend. It must be dropped, not bound to either.
    final (dra, ddec) = wcs.pixelToCelestial(50, 50);
    const twoArcsecDeg = 2.0 / 3600.0;
    final catalog = [
      _star('a', dra - twoArcsecDeg, ddec, bv: 0.3),
      _star('b', dra + twoArcsecDeg, ddec, bv: 1.2),
    ];
    final photometry = StarPhotometryResult(
      width: 100,
      height: 100,
      channels: 3,
      stars: [_det(50, 50)],
    );

    final matched = service.crossMatch(
      photometry: photometry,
      wcs: wcs,
      catalog: catalog,
      channels: 3,
    );
    expect(matched, isEmpty);
  });

  test('calibrate solves when enough stars cross-match', () async {
    final wcs = buildWcs();

    // Build N detections on a grid and a coincident catalog star (with B-V) for
    // each, so we clear the minMatchesToCalibrate threshold.
    final stars = <DetectedStarPhotometry>[];
    final catalog = <Star>[];
    for (var i = 0; i < ColorCalibrationService.minMatchesToCalibrate; i++) {
      final px = 10.0 + i * 5.0;
      final py = 10.0 + i * 5.0;
      stars.add(_det(px, py, flux: [1000.0 + i, 900.0 + i, 800.0 + i]));
      final (ra, dec) = wcs.pixelToCelestial(px, py);
      catalog.add(_star('s$i', ra, dec, bv: 0.5 + i * 0.05));
    }
    seam.photometry = StarPhotometryResult(
      width: 100,
      height: 100,
      channels: 3,
      stars: stars,
    );

    final service = ColorCalibrationService(
      seam: seam,
      starSearch: (_, __, {maxMagnitude}) async => catalog,
    );

    final result = await service.calibrate(
      masterFits: '/m/master.fits',
      outputFits: '/m/master_cc.fits',
      wcs: wcs,
      channels: 3,
    );

    expect(ColorCalibrationService.wasSkipped(result), isFalse);
    expect(result.outputPath, '/m/master_cc.fits');
    expect(result.matched, ColorCalibrationService.minMatchesToCalibrate);
    // The seam was handed matchedStars carrying channelFlux + catalogBv.
    expect(seam.lastChannels, 3);
    expect(
      seam.lastMatchedStars,
      hasLength(ColorCalibrationService.minMatchesToCalibrate),
    );
    expect(
      seam.lastMatchedStars!.first.keys,
      containsAll(['channelFlux', 'catalogBv']),
    );
  });

  test('calibrate fail-softs to skipped on a sparse field', () async {
    final wcs = buildWcs();
    seam.photometry = StarPhotometryResult(
      width: 100,
      height: 100,
      channels: 3,
      stars: [_det(50, 50)],
    );
    // Catalog returns nothing → zero matches → skipped.
    final service = ColorCalibrationService(
      seam: seam,
      starSearch: (_, __, {maxMagnitude}) async => const [],
    );

    final result = await service.calibrate(
      masterFits: '/m/master.fits',
      outputFits: '/m/master_cc.fits',
      wcs: wcs,
      channels: 3,
    );

    expect(ColorCalibrationService.wasSkipped(result), isTrue);
    expect(result.matched, 0);
    // Output path echoes the requested (un-calibrated) target.
    expect(result.outputPath, '/m/master_cc.fits');
    expect(seam.lastMatchedStars, isNull); // colorCalibrate never invoked
  });

  test('calibrate fail-softs to skipped with no WCS', () async {
    seam.photometry = StarPhotometryResult(
      width: 100,
      height: 100,
      channels: 3,
      stars: [_det(50, 50)],
    );
    final service = ColorCalibrationService(
      seam: seam,
      starSearch: (_, __, {maxMagnitude}) async => const [],
    );

    final result = await service.calibrate(
      masterFits: '/m/master.fits',
      outputFits: '/m/master_cc.fits',
      wcs: null,
      channels: 3,
    );

    expect(ColorCalibrationService.wasSkipped(result), isTrue);
    expect(seam.lastMatchedStars, isNull);
  });
}
