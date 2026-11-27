import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

/// The wire words the sequencer writes into `test_fixtures/wire_words/`.
List<String> _words(String file) =>
    (jsonDecode(File('../../test_fixtures/wire_words/$file').readAsStringSync())
            as List)
        .cast<String>();

void main() {
  test('every adaptive exposure reason the sequencer sends is known', () {
    final words = _words('adaptive_exposure_reasons.json');
    expect(
      words.map(AdaptiveExposureReason.fromWire),
      everyElement(isNot(AdaptiveExposureReason.unknown)),
    );
    expect(
      words.toSet(),
      AdaptiveExposureReason.values
          .where((r) => r != AdaptiveExposureReason.unknown)
          .map((r) => r.wire)
          .toSet(),
    );
  });

  test('every recovery phase the sequencer sends is known', () {
    final words = _words('recovery_phases.json');
    expect(words.map(recoveryPhaseFromWire).map((p) => p.wire), words);
    expect(words, hasLength(RecoveryPhase.values.length));
  });
}
