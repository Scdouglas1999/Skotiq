import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/errors.dart';

void main() {
  test('bridge errors show the reason and preserve normal messages', () {
    expect(
        userFacingError(
            'Failed to start: SkotiqError.operationFailed(field0: No plate solver (ASTAP) configured)'),
        'Failed to start: No plate solver (ASTAP) configured');
    expect(userFacingError('Camera disconnected'), 'Camera disconnected');
    expect(
        userFacingError(
            'SkotiqError.operationFailed(field0: Line one\nLine two)'),
        'Line one\nLine two');
  });
}
