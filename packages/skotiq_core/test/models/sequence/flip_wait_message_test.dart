// A run that holds its next frame for a meridian flip said so only in its
// own message; the Tonight header kept showing the step and frame count for
// the two minutes nothing exposed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  test('the flip hold reads as a short wait', () {
    expect(
      flipWaitMessage(
        'Waiting for the meridian flip before the next 120s exposure: the '
        'flip fires in ~102s (hour angle +0.05h, threshold 5 min past '
        'meridian) and would interrupt the frame',
      ),
      'Waiting for the flip',
    );
    expect(flipWaitMessage('AdaptiveExposure: 120 s exposures (0%)'), isNull);
    expect(flipWaitMessage(null), isNull);
  });

  test('the prefix matches the message the run engine sends', () {
    final source = File(
      '../../native/skotiq_native/sequencer/src/instructions/center.rs',
    ).readAsStringSync();
    expect(source, contains('"$kFlipWaitMessagePrefix before the next'));
  });
}
