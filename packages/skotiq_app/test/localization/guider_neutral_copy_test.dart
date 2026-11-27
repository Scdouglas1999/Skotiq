// Surfaces that serve every guider (the built-in guider, a driver guider and
// PHD2) must not tell the user that PHD2 is doing the work. Text about
// PHD2-only features (Brain settings, the PHD2 connection) may still name it.
import 'package:flutter_test/flutter_test.dart';

import 'source_literals.dart';

/// Sentences that say PHD2 guides, calibrates or measures.
const _guiderClaims = <String>[
  'Start PHD2 guiding',
  'Stops PHD2 guiding',
  'PHD2 is measuring',
  'PHD2 calibrates',
];

void main() {
  test('app and core text does not name PHD2 as the guider', () {
    final offenders = [
      for (final literal in sourceLiterals(['lib', '../skotiq_core/lib']))
        if (!literal.path.toLowerCase().contains('phd2') &&
            _guiderClaims.any(literal.text.contains))
          '${literal.path}:${literal.line}: ${literal.text}',
    ];
    expect(offenders, isEmpty);
  });
}
