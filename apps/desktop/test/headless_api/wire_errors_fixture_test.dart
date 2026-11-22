// The web dashboard's node tests load the error-code script the host serves as
// `js/wire-errors.js` from a committed copy. This keeps that copy equal to
// what the host serves. Regenerate with:
//
//     SKOTIQ_REGENERATE=1 flutter test test/headless_api/wire_errors_fixture_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/wire.dart' show ApiErrorCodes;

void main() {
  test('the node tests load the error codes the host serves', () {
    final fixture = File('web_dashboard/test/fixtures/wire-errors.js');
    final served = ApiErrorCodes.javaScript();
    if (Platform.environment['SKOTIQ_REGENERATE'] == '1') {
      fixture.writeAsStringSync(served);
    }
    expect(
      fixture.readAsStringSync(),
      served,
      reason: 'run with SKOTIQ_REGENERATE=1 to refresh the fixture',
    );
  });
}
