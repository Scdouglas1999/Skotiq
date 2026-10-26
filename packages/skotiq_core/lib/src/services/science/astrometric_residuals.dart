import 'dart:math' as math;

import '../../models/science/science_models.dart';

/// Suggestion code stored when the residuals grow toward the field edges and
/// the solve has no SIP terms: the optics distort the field and a linear WCS
/// cannot follow it.
const String residualCodeLinearSolveDistortion = 'linear_solve_distortion';

/// Plain text for a stored residual suggestion code, or null when the code
/// carries no advice. Codes written by older versions (polar alignment, cone
/// error, flexure) came from single-frame fits that cannot show those
/// things, so they read as no advice.
String? residualSuggestionText(String? code) => switch (code) {
  residualCodeLinearSolveDistortion =>
    'Residuals grow toward the edges of the field. The solve is linear and '
        'the optics distort the field; a solve with SIP terms follows it.',
  _ => null,
};

/// One detected star paired with its catalog star projected through the
/// frame's WCS, both in 0-based pixel coordinates.
typedef ResidualPair = ({
  double detectedX,
  double detectedY,
  double catalogX,
  double catalogY,
});

/// Build the residual map for one frame.
///
/// Each vector is catalog minus measured, along the image axes (dx along a
/// row, dy along the stored row order) in arcseconds: it points from where
/// the star is to where the catalog and the WCS put it, so the field pattern
/// draws directly over the frame.
///
/// A plate solve absorbs pointing, cone and polar alignment errors, so one
/// frame's residuals only show what the WCS model cannot follow: optical
/// distortion or a bad solve. Returns null when there are too few pairs, or
/// when the median residual is near what random pairing inside the match
/// radius would give, because then the pairs are not real matches.
AstrometricResidualMap? buildAstrometricResidualMap({
  required List<ResidualPair> pairs,
  required double pixelScaleArcsec,
  required int imageWidth,
  required int imageHeight,
  required double maxMatchPx,
  required bool solveHasSip,
  int sampleCount = 250,
  int minPairs = 6,
}) {
  if (pairs.length < minPairs || pixelScaleArcsec <= 0) return null;

  final separationsPx = [
    for (final p in pairs)
      math.sqrt(
        math.pow(p.catalogX - p.detectedX, 2) +
            math.pow(p.catalogY - p.detectedY, 2),
      ),
  ]..sort();
  // Uniform random pairs inside a disk of radius R have a median separation
  // of R / sqrt(2), about 0.71 R.
  if (separationsPx[separationsPx.length ~/ 2] > 0.4 * maxMatchPx) {
    return null;
  }

  final vectors = [
    for (final p in pairs.take(sampleCount)) _vector(p, pixelScaleArcsec),
  ];
  final rms = math.sqrt(
    vectors.fold<double>(
          0.0,
          (s, v) => s + v.magnitudeArcsec * v.magnitudeArcsec,
        ) /
        vectors.length,
  );

  String? suggestion;
  if (!solveHasSip) {
    final cx = (imageWidth - 1) / 2.0;
    final cy = (imageHeight - 1) / 2.0;
    final halfDiagonal = math.sqrt(cx * cx + cy * cy);
    final inner = <double>[];
    final outer = <double>[];
    for (final v in vectors) {
      final r = math.sqrt(math.pow(v.x - cx, 2) + math.pow(v.y - cy, 2));
      if (r < 0.35 * halfDiagonal) inner.add(v.magnitudeArcsec);
      if (r > 0.7 * halfDiagonal) outer.add(v.magnitudeArcsec);
    }
    if (inner.length >= 5 && outer.length >= 5) {
      final innerMedian = _median(inner);
      final outerMedian = _median(outer);
      if (outerMedian > 1.0 && outerMedian > 2.0 * innerMedian) {
        suggestion = residualCodeLinearSolveDistortion;
      }
    }
  }

  return AstrometricResidualMap(
    vectors: vectors,
    rmsArcsec: rms,
    suggestionCode: suggestion,
  );
}

ResidualVectorSample _vector(ResidualPair p, double scale) {
  final dx = (p.catalogX - p.detectedX) * scale;
  final dy = (p.catalogY - p.detectedY) * scale;
  return ResidualVectorSample(
    x: p.detectedX,
    y: p.detectedY,
    dxArcsec: dx,
    dyArcsec: dy,
    magnitudeArcsec: math.sqrt(dx * dx + dy * dy),
  );
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}
