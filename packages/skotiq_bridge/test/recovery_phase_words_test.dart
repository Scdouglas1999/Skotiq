import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

void main() {
  test('the handed-off recovery phase is a phase the sequencer sends', () {
    final words =
        (jsonDecode(
                  File(
                    '../../test_fixtures/wire_words/recovery_phases.json',
                  ).readAsStringSync(),
                )
                as List)
            .cast<String>();
    expect(words, contains(kRecoveryHandedOffPhase));
  });
}
