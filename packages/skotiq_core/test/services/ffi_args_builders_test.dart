// Request builders whose maps go straight to a native `args_json` entry point,
// held to the keys the native request type reads
// (test_fixtures/ffi_args/, traced by a Rust test). The service tests check
// the maps their fake seams receive the same way.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

import '../harness/args_fixture.dart';

void main() {
  test('a calibration master request names only keys the builder reads', () {
    const request = CalibrationMasterBuildRequest(
      kind: 'dark',
      framePaths: ['/darks/d1.fits', '/darks/d2.fits'],
      outputPath: '/masters/dark.fits',
      leakMinRiseAdu: 12.5,
    );
    expectNativeReadsEveryKey(request.toJson(), ['build_calibration_master']);
  });

  test('a misspelled key is reported', () {
    expect(
      unreadArgKeys(
        {
          'kind': 'dark',
          'framePath': ['/darks/d1.fits'],
        },
        ['build_calibration_master'],
      ),
      {'framePath'},
    );
  });
}
