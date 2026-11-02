// Surfaces that serve every guider (the built-in guider, a driver guider and
// PHD2) must not tell the user that PHD2 is doing the work. Text about
// PHD2-only features (Brain settings) may still name it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _guiderNeutralSources = <String>[
  'lib/screens/sequencer/widgets/quick_start_wizard_dialog/_automation_step.dart',
  'lib/screens/sequencer/widgets/node_properties_panel_parts/_guiding_properties.dart',
  'lib/screens/guiding/guiding_screen_parts/desktop_sections.dart',
];

/// Sentences that say PHD2 guides, calibrates or measures.
const _guiderClaims = <String>[
  'Start PHD2 guiding',
  'Stops PHD2 guiding',
  'PHD2 is measuring',
  'PHD2 calibrates',
];

void main() {
  test('guider-neutral surfaces do not name PHD2 as the guider', () {
    final offenders = <String>[];
    for (final path in _guiderNeutralSources) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.startsWith('//')) continue;
        for (final phrase in _guiderClaims) {
          if (line.contains(phrase)) offenders.add('$path:${i + 1}: $line');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
