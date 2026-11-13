import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  test('a time trigger reads as a local date and time, not an epoch', () {
    final at = DateTime(2026, 10, 29, 21, 3);
    final seconds = at.millisecondsSinceEpoch ~/ 1000;
    final label = TargetTrigger.and([
      const TargetTrigger.altitudeAbove(30),
      TargetTrigger.timeAfter(seconds),
    ]).label;
    expect(label, '(altitude ≥ 30.0° AND time ≥ 2026-10-29 21:03)');
    expect(label, isNot(contains('$seconds')));
  });
}
