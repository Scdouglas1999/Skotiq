// An operator-run autofocus request reaches the bridge's AutofocusConfigApi
// field for field.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/src/backend/ffi_backend.dart';
import 'package:skotiq_core/src/models/imaging/autofocus_request.dart';

import '../harness/frb_contract.dart';

void main() {
  test('every request field arrives in the bridge config', () {
    const request = AutofocusRequest(
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
    );

    final expected = bridge.AutofocusConfigApi(
      exposureTime: 2.5,
      stepSize: 37,
      stepsOut: 6,
      method: 'Parabolic',
      binning: 2,
      gain: 120,
      offset: 15,
      numberOfAttempts: 3,
      exposuresPerPoint: 4,
      rSquaredThreshold: 0.83,
      outerCropRatio: 0.9,
      innerCropRatio: 0.2,
      useBrightestNStars: 25,
      focuserSettleTimeMs: BigInt.from(750),
      backlashCompMethod: 'Inward',
      backlashIn: 120,
      backlashOut: 40,
      measuredBacklashIn: 88,
    );

    expect(autofocusConfigForBridge(request), expected);
    expect(frbFields('api/imaging.dart', 'AutofocusConfigApi'), {
      'exposureTime',
      'stepSize',
      'stepsOut',
      'method',
      'binning',
      'gain',
      'offset',
      'numberOfAttempts',
      'exposuresPerPoint',
      'rSquaredThreshold',
      'outerCropRatio',
      'innerCropRatio',
      'useBrightestNStars',
      'focuserSettleTimeMs',
      'backlashCompMethod',
      'backlashIn',
      'backlashOut',
      'measuredBacklashIn',
    });
  });
}
