import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  test('the reasons and their words are the native sequencer\'s', () {
    // The same file `stop_reasons_match_the_app` in guiding_stop.rs reads.
    final fixture =
        jsonDecode(
              File(
                'test/fixtures/guiding_stop_reasons.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect({
      for (final reason in GuidingStopReason.values) reason.wire: reason.text,
    }, fixture);
  });

  test('a mount-fault hold is told in words, not as its wire name', () {
    expect(
      guidingStopReasonText('mount_fault'),
      'Guiding stopped: the mount moved on its own',
    );
  });

  test('a reason this build does not know is shown as given', () {
    expect(guidingStopReasonText('new_reason'), 'Guiding stopped (new_reason)');
    expect(guidingStopReasonText(null), isNull);
    expect(guidingStopReasonText(''), isNull);
  });
}
