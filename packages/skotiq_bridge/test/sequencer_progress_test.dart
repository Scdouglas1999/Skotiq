import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

void main() {
  test('completed non-exposure sequence reports full progress', () {
    expect(
      calculateSequencerProgressFraction(
        state: 'completed',
        completedExposures: 0,
        totalExposures: 0,
      ),
      1.0,
    );
  });

  test('running exposure progress is bounded', () {
    expect(
      calculateSequencerProgressFraction(
        state: 'running',
        completedExposures: 2,
        totalExposures: 4,
      ),
      0.5,
    );
    expect(
      calculateSequencerProgressFraction(
        state: 'running',
        completedExposures: 5,
        totalExposures: 4,
      ),
      1.0,
    );
  });
}
