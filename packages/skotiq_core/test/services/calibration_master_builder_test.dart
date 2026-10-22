import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/calibration_master_builder.dart';

void main() {
  final result = <String, dynamic>{
    'outputPath': '/calibration/master-dark.fits',
    'kind': 'dark',
    'width': 640,
    'height': 480,
    'frameCount': 20,
    'leakBaseline': 100.0,
    'leakThreshold': 110.0,
    'masterMean': 101.0,
    'rejectionFraction': 0.02,
  };

  test('native master result retains measured fields', () {
    final parsed = CalibrationMasterBuildResult.fromJson(result);
    expect(parsed.width, 640);
    expect(parsed.height, 480);
    expect(parsed.frameCount, 20);
    expect(parsed.masterMean, 101.0);
    expect(parsed.gain, isNull);
  });

  test('incomplete native result cannot look like a zero-valued master', () {
    for (final key in [
      'width',
      'height',
      'frameCount',
      'leakBaseline',
      'leakThreshold',
      'masterMean',
      'rejectionFraction',
    ]) {
      final incomplete = Map<String, dynamic>.from(result)..remove(key);
      expect(
        () => CalibrationMasterBuildResult.fromJson(incomplete),
        throwsA(isA<TypeError>()),
        reason: key,
      );
    }
  });
}
