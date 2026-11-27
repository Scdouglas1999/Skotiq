// The FRB image statistics reach the core model field for field.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/models.dart';

import '../../harness/frb_contract.dart';

void main() {
  test('image statistics', () {
    final mapped = ImageStatsResult.fromBridge(
      const bridge.ImageStatsResult(
        min: 1,
        max: 65000,
        mean: 812.5,
        median: 790,
        stdDev: 44.25,
        hfr: 2.4,
        eccentricity: 0.31,
        fwhm: 3.7,
        starCount: 412,
      ),
    );
    expect(mapped.toJson(), {
      'min': 1.0,
      'max': 65000.0,
      'mean': 812.5,
      'median': 790.0,
      'stdDev': 44.25,
      'hfr': 2.4,
      'eccentricity': 0.31,
      'fwhm': 3.7,
      'starCount': 412,
    });
    expect(frbFields('api/imaging.dart', 'ImageStatsResult'), {
      'min',
      'max',
      'mean',
      'median',
      'stdDev',
      'hfr',
      'eccentricity',
      'fwhm',
      'starCount',
    });
  });
}
