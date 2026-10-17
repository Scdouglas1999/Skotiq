// Two producers write an exposure node's progress line, and a card that
// understands only one wording misreads the other. This pins the round trip —
// everything a formatter emits, the parser reads back — so a third wording
// cannot be added on one side alone.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/sequence/exposure_progress_vocabulary.dart';

void main() {
  test('the started wording round-trips as a frame in flight', () {
    final parsed = parseExposureProgressDetail(
      formatExposureStartedDetail(3, 4, 'R'),
    );
    expect(parsed, isNotNull);
    expect(parsed!.frame, 3);
    expect(parsed.total, 4);
    expect(parsed.frameCompleted, isFalse);
  });

  test('the started wording round-trips without a filter', () {
    final parsed = parseExposureProgressDetail(
      formatExposureStartedDetail(1, 8, null),
    );
    expect(parsed!.frame, 1);
    expect(parsed.total, 8);
    expect(parsed.frameCompleted, isFalse);
  });

  // The line that made a fully successful run read "0 / 4 frames".
  test('the completed wording round-trips as a finished frame', () {
    final parsed = parseExposureProgressDetail(
      formatExposureCompletedDetail(4, 4),
    );
    expect(parsed, isNotNull);
    expect(parsed!.frame, 4);
    expect(parsed.total, 4);
    expect(parsed.frameCompleted, isTrue);
  });

  test('a line from another instruction is not misread as frames', () {
    expect(parseExposureProgressDetail(''), isNull);
    expect(parseExposureProgressDetail('Slewing to M42'), isNull);
    expect(parseExposureProgressDetail('Autofocus: point 3 of 9'), isNull);
  });
}
