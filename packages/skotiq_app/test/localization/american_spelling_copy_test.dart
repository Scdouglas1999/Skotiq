// User-facing text is American English (qa-night N03): these strings said
// "centre", "colour" and "catalogue".
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _sources = <String>[
  'lib/screens/sequencer/widgets/session_report_dialog.dart',
  'lib/screens/session_review/widgets/integration_settings_panel.dart',
  '../skotiq_core/lib/src/services/optical_train_diagnostics_service.dart',
  '../skotiq_core/lib/src/services/darkroom_autopilot/dawn_draft_builder.dart',
];

final _british = RegExp(r'\b(centre|colour|catalogue)\b', caseSensitive: false);

void main() {
  test('these screens and reports use American spelling in their text', () {
    final offenders = <String>[];
    for (final path in _sources) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.startsWith('//')) continue;
        for (final literal in RegExp(r"'[^']*'").allMatches(line)) {
          if (_british.hasMatch(literal.group(0)!)) {
            offenders.add('$path:${i + 1}: ${literal.group(0)}');
          }
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
