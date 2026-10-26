import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// AH Cnc and four M67 comparison stars as measured in two G frames 25 min
/// apart (fluxes in ADU, 60 s): AH Cnc faded 0.15 mag between them, which
/// moves the comparison closest to it in flux from C4 to C6.
StarMeasurement _star(double flux, {double snr = 300}) => StarMeasurement(
  x: 0,
  y: 0,
  flux: flux,
  hfr: 2.3,
  fwhm: 4.6,
  snr: snr,
  eccentricity: 0.2,
  sharpness: 0.1,
  background: 2400,
  peak: 20000,
);

const _ids = ['C3', 'C4', 'C5', 'C6'];

List<({String objectId, StarMeasurement star})> _comparisons() => [
  (objectId: 'C3', star: _star(260000)),
  (objectId: 'C4', star: _star(128000)),
  (objectId: 'C5', star: _star(310000)),
  (objectId: 'C6', star: _star(104000)),
];

void main() {
  test('the check star and ensemble stay the same as the target fades', () {
    final first = ScienceProcessingService.buildDifferentialFrame(
      target: _star(125000),
      comparisons: _comparisons(),
      comparisonIds: _ids,
      sessionCheckId: null,
      gainElectronsPerAdu: 0.1231,
    );
    expect(first.checkObjectId, 'C4');
    expect(first.ensembleObjectIds, ['C3', 'C5', 'C6']);

    // 0.15 mag fainter: C6 is now closest in flux, but the session's check
    // star stays C4 and the ensemble stays C3+C5+C6.
    final later = ScienceProcessingService.buildDifferentialFrame(
      target: _star(125000 * math.pow(10, -0.4 * 0.15).toDouble()),
      comparisons: _comparisons(),
      comparisonIds: _ids,
      sessionCheckId: first.checkObjectId,
      gainElectronsPerAdu: 0.1231,
    );
    expect(later.checkObjectId, 'C4');
    expect(later.ensembleObjectIds, first.ensembleObjectIds);
    expect(later.ensembleFlux, 260000 + 310000 + 104000);
  });

  test('a frame missing an ensemble star is skipped, not re-weighted', () {
    final frame = ScienceProcessingService.buildDifferentialFrame(
      target: _star(125000),
      comparisons: _comparisons().where((c) => c.objectId != 'C5').toList(),
      comparisonIds: _ids,
      sessionCheckId: 'C4',
      gainElectronsPerAdu: 0.1231,
    );
    expect(frame.skipReason, contains('C5'));
  });

  test('flux errors include the star photon noise', () {
    // A bright star whose detector SNR counts only the background: at
    // 0.1231 e-/ADU its own photon noise is larger than that.
    final star = _star(125000, snr: 400);
    final backgroundOnly = 125000 / 400;
    final sigma = ScienceProcessingService.fluxSigma(star, 0.1231);
    expect(sigma, greaterThan(backgroundOnly * 1.5));
    expect(
      sigma,
      closeTo(math.sqrt(backgroundOnly * backgroundOnly + 125000 / 0.1231), 1),
    );
  });
}
