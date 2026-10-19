// Tonight's copy uses only marks the bundled faces can draw.
//
// Hanken Grotesk and Spline Sans Mono have no ″, ′, σ, ✓ or ✕, so each one
// fell back to whatever face the host had, or to a box. Arc marks are
// written as " and ', and a check or cross is an icon.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';

import 'fixtures/night_fixtures.dart';

const String _missing = '″′σ✓✕';

void main() {
  test('no night-control string carries a mark the faces lack', () {
    final offenders = <String>[];
    SkotiqLocalizations.debugLocalizedValues.forEach((language, values) {
      values.forEach((key, value) {
        if (!key.startsWith('night') && !key.startsWith('nc')) return;
        if (value.split('').any(_missing.contains)) {
          offenders.add('$language.$key: $value');
        }
      });
    });
    expect(offenders, isEmpty);
  });

  test('the board fixtures render what the app renders', () {
    final running = NightFixtures.running();
    final texts = <String>[
      for (final m in running.lastFrame!.metrics) ...<String>[
        m.label.literal ?? '',
        m.value ?? '',
      ],
      for (final m in running.guideSeries.legend) m.value ?? '',
      for (final entry in NightFixtures.ready().log)
        entry.message.literal ?? '',
    ];
    for (final text in texts) {
      expect(text.split('').where(_missing.contains), isEmpty, reason: text);
    }
  });
}
