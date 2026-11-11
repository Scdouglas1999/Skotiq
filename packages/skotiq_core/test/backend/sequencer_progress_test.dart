import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/ffi_backend.dart';

void main() {
  test('completed non-exposure sequence reports full progress', () {
    expect(
      sequencerProgressFraction(
        state: 'completed',
        completedExposures: 0,
        totalExposures: 0,
      ),
      1.0,
    );
  });

  test('running exposure progress is bounded', () {
    expect(
      sequencerProgressFraction(
        state: 'running',
        completedExposures: 2,
        totalExposures: 4,
      ),
      0.5,
    );
    expect(
      sequencerProgressFraction(
        state: 'running',
        completedExposures: 5,
        totalExposures: 4,
      ),
      1.0,
    );
  });
}
