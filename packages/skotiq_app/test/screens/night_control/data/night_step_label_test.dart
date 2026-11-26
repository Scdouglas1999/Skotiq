// Night test 2026-11-26: a dark step read "10 × 55 s" in Tonight's Steps
// list, like an unfiltered light, while the header called it "Dark 55 s".

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_steps_provider.dart';
import 'package:skotiq_core/models.dart';

void main() {
  test('a dark or bias step reads as its frame type, a light as its filter',
      () {
    String label(FrameType type) => nightStepLabel(ExposureNode(
          durationSecs: 55,
          count: 10,
          filter: 'G',
          frameType: type,
        ));
    expect(label(FrameType.dark), startsWith('Dark 10 × '));
    expect(label(FrameType.bias), startsWith('Bias 10 × '));
    expect(label(FrameType.darkFlat), startsWith('Dark flat 10 × '));
    expect(label(FrameType.light), startsWith('G 10 × '));
  });
}
