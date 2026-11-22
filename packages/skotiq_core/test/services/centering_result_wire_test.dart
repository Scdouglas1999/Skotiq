// The centering result the host answers with, and what a linked client
// reads back from it.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

void main() {
  final attempt = CenteringIteration(
    iterationNumber: 1,
    solvedRa: 5.5,
    solvedDec: -5.25,
    targetRa: 5.6,
    targetDec: -5.3,
    offsetArcsec: 42.0,
    offsetArcmin: 0.7,
    plateSolveSuccess: true,
    timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
  );

  test('the wire form keeps every key the host has always sent', () {
    final json = CenteringResult(
      success: false,
      iterations: 1,
      errorMessage: 'Did not converge',
      iterationHistory: [attempt],
    ).toJson();
    expect(json, {
      'success': false,
      'iterations': 1,
      'finalOffsetArcsec': null,
      'errorMessage': 'Did not converge',
      'iterationHistory': [
        {
          'iterationNumber': 1,
          'solvedRa': 5.5,
          'solvedDec': -5.25,
          'targetRa': 5.6,
          'targetDec': -5.3,
          'offsetArcsec': 42.0,
          'offsetArcmin': 0.7,
          'plateSolveSuccess': true,
          'errorMessage': null,
          'timestamp': 1700000000000,
        },
      ],
    });
  });

  test('attempts read back; entries without an attempt number are skipped', () {
    final read = CenteringResult.iterationsFromJson({
      'iterationHistory': [
        attempt.toJson(),
        {'solvedRa': 1.0},
        'not a map',
        {'iterationNumber': 2, 'solvedRa': 'x', 'solvedDec': 3},
      ],
    });
    expect(read, hasLength(2));
    expect(read.first.solvedRa, 5.5);
    expect(read.first.offsetArcsec, 42.0);
    expect(read.first.timestamp, attempt.timestamp);
    expect(read.last.iterationNumber, 2);
    expect(read.last.solvedRa, isNull);
    expect(read.last.solvedDec, 3.0);
    expect(CenteringResult.iterationsFromJson(const {}), isEmpty);
  });
}
