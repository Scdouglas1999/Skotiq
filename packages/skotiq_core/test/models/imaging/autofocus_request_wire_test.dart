import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  const everyField = AutofocusRequest(
    deviceId: 'native:zwo:eaf:0',
    cameraId: 'native:zwo:0',
    exposureTime: 2.5,
    stepSize: 37,
    stepsOut: 6,
    method: 'Star FWHM',
    binning: 2,
    gain: 120,
    offset: 15,
    curveFitting: 'Parabolic',
    numberOfAttempts: 3,
    exposuresPerPoint: 4,
    rSquaredThreshold: 0.83,
    outerCropRatio: 0.9,
    innerCropRatio: 0.2,
    useBrightestNStars: 25,
    focuserSettleTimeMs: 750,
    backlashCompMethod: 'Inward',
    backlashIn: 120,
    backlashOut: 40,
    measuredBacklashIn: 88,
    failureHfrToleranceRatio: 2.2,
  );
  const noOptionals = AutofocusRequest(
    deviceId: 'focuser',
    cameraId: 'camera',
    exposureTime: 4,
    stepSize: 50,
    stepsOut: 4,
    method: 'Star HFR',
    binning: 1,
    gain: null,
    offset: null,
    curveFitting: 'Hyperbolic',
    numberOfAttempts: 2,
    exposuresPerPoint: 1,
    rSquaredThreshold: 0.7,
    outerCropRatio: 1,
    innerCropRatio: 0,
    useBrightestNStars: 0,
    focuserSettleTimeMs: 0,
    backlashCompMethod: 'Overshoot',
    backlashIn: 350,
    backlashOut: 0,
    measuredBacklashIn: null,
    failureHfrToleranceRatio: 1.6,
  );

  for (final (name, request) in [
    ('every field', everyField),
    ('no optional field', noOptionals),
  ]) {
    test('a request reads back from its own body ($name)', () {
      final body = request.toWireJson();
      expect(AutofocusRequest.fromWireJson(body).toWireJson(), body);
    });
  }

  test('a refused body names the field and why', () {
    expect(
      () => AutofocusRequest.fromWireJson({
        ...everyField.toWireJson(),
        'stepsOut': 51,
      }),
      throwsA(
        isA<AutofocusRequestFieldError>()
            .having((e) => e.field, 'field', 'stepsOut')
            .having((e) => e.expected, 'expected', 'number')
            .having((e) => e.message, 'message', 'Value must be <= 50.0'),
      ),
    );
  });
}
