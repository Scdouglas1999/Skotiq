import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/ffi_backend.dart';

void main() {
  test('native autofocus curve labels map to supported methods', () {
    expect(autofocusCurveMethodForNativeBridge('Hyperbolic'), 'Hyperbolic');
    expect(autofocusCurveMethodForNativeBridge('Parabolic'), 'Parabolic');
    expect(autofocusCurveMethodForNativeBridge('Trend Lines'), 'VCurve');
    expect(autofocusCurveMethodForNativeBridge('V-Curve'), 'VCurve');
  });
}
