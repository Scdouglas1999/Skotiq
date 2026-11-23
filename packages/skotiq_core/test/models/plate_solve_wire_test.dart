import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show PlateSolveResult;
import 'package:skotiq_core/src/models/imaging/plate_solve_wire.dart';

PlateSolveResult _solve({double pixelScale = 1.2, Float64List? sipA}) =>
    PlateSolveResult(
      success: true,
      ra: 10.68,
      dec: 41.27,
      pixelScale: pixelScale,
      rotation: 12.5,
      fieldWidth: 1.4,
      fieldHeight: 0.9,
      solveTimeSecs: 3.2,
      cd11: 2.0e-4,
      cd12: 8.0e-5,
      cd21: -8.0e-5,
      cd22: 2.0e-4,
      sipAOrder: 2,
      sipBOrder: 2,
      sipApOrder: 0,
      sipBpOrder: 0,
      sipACoeffs: sipA ?? Float64List.fromList([0, 1e-6, -2e-7]),
      sipBCoeffs: Float64List.fromList([3e-7]),
      sipApCoeffs: Float64List(0),
      sipBpCoeffs: Float64List(0),
    );

void main() {
  test('the published REST keys are the wire keys', () {
    expect(plateSolveResultToJson(_solve()).keys.toSet(), {
      'success', 'ra', 'dec', 'pixelScale', 'rotation', 'fieldWidth', //
      'fieldHeight', 'solveTimeSecs', 'error', 'cd11', 'cd12', 'cd21',
      'cd22', 'sipAOrder', 'sipBOrder', 'sipApOrder', 'sipBpOrder',
      'sipACoeffs', 'sipBCoeffs', 'sipApCoeffs', 'sipBpCoeffs',
    });
  });

  test('a solve survives JSON, unmeasured values as NaN', () {
    final solve = _solve(
      pixelScale: double.nan,
      sipA: Float64List.fromList([double.nan, 1e-6]),
    );
    final back = plateSolveResultFromJson(
      jsonDecode(jsonEncode(plateSolveResultToJson(solve)))
          as Map<String, dynamic>,
    );
    expect(back.pixelScale.isNaN, isTrue);
    expect(back.sipACoeffs[0].isNaN, isTrue);
    expect(back.sipACoeffs[1], 1e-6);
    expect(
      (back.ra, back.dec, back.cd12, back.sipAOrder),
      (10.68, 41.27, 8.0e-5, 2),
    );
  });

  test('a producer without a distortion model reads as linear', () {
    final back = plateSolveResultFromJson({
      'success': true,
      'ra': 1.0,
      'dec': 2.0,
      'pixelScale': 1.0,
      'rotation': 0.0,
      'fieldWidth': 1.0,
      'fieldHeight': 1.0,
      'solveTimeSecs': 1.0,
    });
    expect((back.cd11, back.cd22, back.sipAOrder), (0.0, 0.0, 0));
    expect(back.sipACoeffs, isEmpty);
  });

  test('a missing sky position is refused', () {
    expect(
      () => plateSolveResultFromJson({'success': true, 'dec': 2.0}),
      throwsFormatException,
    );
  });
}
