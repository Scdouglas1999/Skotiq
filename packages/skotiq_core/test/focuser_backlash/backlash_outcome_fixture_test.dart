// The backlash result decoder reads the outcomes the native calibration
// writes: test_fixtures/ffi_replies/focuser_backlash_outcomes.json holds a
// measured outcome from the simulated run and a refusal, serialized by a Rust
// test. A key renamed in Rust makes the decoder answer "no result" and fails
// here.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

import '../harness/reply_fixture.dart';

void main() {
  final samples = replyFixtureObject('focuser_backlash_outcomes');

  test('a measured outcome decodes the fields the app shows', () {
    final sample = samples['measured'] as Map<String, dynamic>;
    final (result, unread) = decodeRecordingReads(
      sample,
      FocuserBacklashResult.fromJson,
    );
    expect(result, isNotNull);
    // The app draws each scan from its points' position and HFR; the fit
    // method, FWHM and star count are not shown.
    expect(unread, {
      for (final scan in ['above', 'below']) ...{
        'calibration.$scan.method',
        'calibration.$scan.points[].fwhm',
        'calibration.$scan.points[].star_count',
      },
    });
    final calibration = sample['calibration'] as Map<String, dynamic>;
    expect(result!.kind, FocuserBacklashOutcomeKind.measured);
    expect(result.calibration!.steps, calibration['steps']);
    expect(
      result.calibration!.measuredAtPosition,
      calibration['measured_at_position'],
    );
    expect(
      result.calibration!.below.points,
      hasLength((calibration['below']['points'] as List).length),
    );
  });

  test('a refusal decodes its code and sentences', () {
    final sample = samples['refused'] as Map<String, dynamic>;
    final (result, unread) = decodeRecordingReads(
      sample,
      FocuserBacklashResult.fromJson,
    );
    expect(result, isNotNull);
    expect(result!.kind, FocuserBacklashOutcomeKind.refused);
    expect(result.refusal!.code, sample['refusal']['code']);
    expect(result.refusal!.message, sample['message']);
    expect(result.refusal!.remedy, sample['remedy']);
    // The refusal's figures are in its message.
    expect(unread.where((k) => !k.startsWith('refusal.')), isEmpty);
  });
}
