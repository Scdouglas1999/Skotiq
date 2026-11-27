// One guider word set: every surface names a guider state with the
// same word, and an idle guider, PHD2 or built-in, is "Not guiding".

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/utils/guider_state_label.dart';
import 'package:skotiq_core/models.dart';

void main() {
  test('an idle guider is "Not guiding", never "suspended"', () {
    final l10n = SkotiqLocalizations(const Locale('en'));
    expect(l10n.text(guiderStateLabel(Phd2State.stopped).$1), 'Not guiding');
    for (final state in Phd2State.values) {
      expect(
        l10n.text(guiderStateLabel(state).$1).toLowerCase(),
        isNot(contains('suspend')),
        reason: state.name,
      );
    }
  });

  test('an idle PHD2 and an idle built-in guider read the same', () {
    // PHD2 reports an idle guider as "Connected", the built-in one as
    // "Stopped"; both are the stopped state.
    expect(phd2StateFromGuiderWord('Connected'), Phd2State.stopped);
    expect(phd2StateFromGuiderWord('Stopped'), Phd2State.stopped);
  });
}
