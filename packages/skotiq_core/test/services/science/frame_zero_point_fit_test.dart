import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/services/science/frame_zero_point_fit.dart';

/// A field like M67 in a 60 s G frame: zero point 21.57 against V, 0.08 mag
/// star-to-star scatter (mostly the field's color spread), matched stars
/// within a pixel of their catalog position.
List<ZeroPointMatch> _realField({
  int count = 360,
  double zeroPoint = 21.57,
  double scatter = 0.08,
  double exposure = 60,
  double Function(double v, double bv)? frameMagnitude,
}) {
  final random = math.Random(67);
  double gauss() =>
      math.sqrt(-2 * math.log(1 - random.nextDouble())) *
      math.cos(2 * math.pi * random.nextDouble());
  return [
    for (var i = 0; i < count; i++)
      () {
        final v = 10.5 + 4.5 * random.nextDouble();
        final bv = 0.3 + 0.9 * random.nextDouble();
        final inst =
            (frameMagnitude?.call(v, bv) ?? v) - zeroPoint + scatter * gauss();
        return (
          flux: exposure * math.pow(10, -0.4 * inst).toDouble(),
          catalogStar: PhotometricCatalogStar(
            raDegrees: 132.8 + i * 1e-4,
            decDegrees: 11.8,
            magV: v,
            colorIndexBv: bv,
            magR: v - 0.25 * bv,
          ),
          separationPx: 0.8 * gauss().abs(),
        );
      }(),
  ];
}

/// Catalog stars that fell within the 9 px match radius of unrelated
/// detections, as the mirrored projection produced on M67: 11-18 pairs whose
/// magnitudes have nothing to do with the detected fluxes.
List<ZeroPointMatch> _chancePairs({int count = 15}) {
  final random = math.Random(891);
  return [
    for (var i = 0; i < count; i++)
      (
        flux:
            60 * math.pow(10, -0.4 * (-9 + 4 * random.nextDouble())).toDouble(),
        catalogStar: PhotometricCatalogStar(
          raDegrees: 132.8 + i * 1e-4,
          decDegrees: 11.8,
          magV: 11 + 4 * random.nextDouble(),
          colorIndexBv: 0.6,
        ),
        separationPx: 9 * math.sqrt(random.nextDouble()),
      ),
  ];
}

void main() {
  test('a real field gives its zero point and the standard error of it', () {
    final fit = fitFrameZeroPoint(
      matches: _realField(),
      exposureSeconds: 60,
      mapping: filterBandFor('G'),
      maxMatchPx: 9,
    );
    expect(fit.rejectionReason, isNull);
    expect(fit.zeroPoint, closeTo(21.57, 0.02));
    expect(fit.band, PhotometricBand.johnsonV);
    expect(fit.bandIsStandard, isTrue);
    // The error of a median of ~360 stars at 0.08 mag, not the 0.08 scatter.
    expect(fit.zeroPointError, inInclusiveRange(0.003, 0.008));
    expect(fit.rms, closeTo(0.08, 0.02));
  });

  test('chance pairs are refused instead of written as a zero point', () {
    final fit = fitFrameZeroPoint(
      matches: _chancePairs(),
      exposureSeconds: 60,
      mapping: filterBandFor('G'),
      maxMatchPx: 9,
    );
    expect(fit.zeroPoint, isNull);
    expect(fit.rejectionReason, contains('chance pairs'));
  });

  test('a fit with magnitude-level scatter is refused', () {
    final matches = _realField(count: 40, scatter: 0.6);
    final fit = fitFrameZeroPoint(
      matches: matches,
      exposureSeconds: 60,
      mapping: filterBandFor('G'),
      maxMatchPx: 9,
    );
    expect(fit.zeroPoint, isNull);
    expect(fit.rejectionReason, contains('scatter'));
  });

  test('too few stars are refused', () {
    final fit = fitFrameZeroPoint(
      matches: _realField(count: 8),
      exposureSeconds: 60,
      mapping: filterBandFor('G'),
      maxMatchPx: 9,
    );
    expect(fit.zeroPoint, isNull);
    expect(fit.rejectionReason, contains('needed'));
  });

  test('B and R frames are calibrated in their own bands', () {
    // A B frame's fluxes follow B = V + (B-V), an R frame's follow r'.
    final b = fitFrameZeroPoint(
      matches: _realField(zeroPoint: 22.2, frameMagnitude: (v, bv) => v + bv),
      exposureSeconds: 60,
      mapping: filterBandFor('B'),
      maxMatchPx: 9,
    );
    final r = fitFrameZeroPoint(
      matches: _realField(
        zeroPoint: 21.8,
        frameMagnitude: (v, bv) => v - 0.25 * bv,
      ),
      exposureSeconds: 60,
      mapping: filterBandFor('R'),
      maxMatchPx: 9,
    );
    expect(b.band, PhotometricBand.johnsonB);
    expect(b.zeroPoint, closeTo(22.2, 0.02));
    expect(r.band, PhotometricBand.sloanR);
    expect(r.zeroPoint, closeTo(21.8, 0.02));
  });

  test("R falls back to a non-standard V zero point without r' magnitudes", () {
    final field = [
      for (final m in _realField())
        (
          flux: m.flux,
          catalogStar: PhotometricCatalogStar(
            raDegrees: m.catalogStar.raDegrees,
            decDegrees: m.catalogStar.decDegrees,
            magV: m.catalogStar.magV,
            colorIndexBv: m.catalogStar.colorIndexBv,
          ),
          separationPx: m.separationPx,
        ),
    ];
    final fit = fitFrameZeroPoint(
      matches: field,
      exposureSeconds: 60,
      mapping: filterBandFor('R'),
      maxMatchPx: 9,
    );
    expect(fit.band, PhotometricBand.johnsonV);
    expect(fit.bandIsStandard, isFalse);
  });

  test('L is a V-equivalent, not a standard band', () {
    final mapping = filterBandFor('Lum');
    expect(mapping.band, PhotometricBand.johnsonV);
    expect(mapping.isStandard, isFalse);
    expect(mapping.aavsoFilterCode, 'CV');
  });
}
