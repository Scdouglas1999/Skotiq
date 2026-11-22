import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/ffi_backend.dart';

void main() {
  test('native autofocus curve labels map to supported methods', () {
    expect(autofocusCurveMethodForNativeBridge('Hyperbolic'), 'Hyperbolic');
    expect(autofocusCurveMethodForNativeBridge('Parabolic'), 'Parabolic');
    expect(autofocusCurveMethodForNativeBridge('Quadratic'), 'Parabolic');
    expect(autofocusCurveMethodForNativeBridge('Trend Lines'), 'VCurve');
    expect(autofocusCurveMethodForNativeBridge('V-Curve'), 'VCurve');
  });

  test('an unknown curve label reaches the bridge as it is, which refuses it '
      'rather than running a V-curve', () {
    expect(autofocusCurveMethodForNativeBridge('Mystery'), 'Mystery');
  });
}
