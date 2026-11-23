// Each generated plan pressed on a screen (Smart Night, Image tonight, a
// mosaic capture) starts through the pre-flight dialog (R1E1-1): the caller
// hands startOwnedPlan the dialog as its confirm step.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final path in [
    'lib/screens/sequencer/widgets/smart_night_dialog/plan_helpers.dart',
    'lib/screens/planner/planner_screen_parts/_recommendation_tab.dart',
    'lib/screens/discover/mosaic/mosaic_project_controller_parts/_providers.dart',
  ]) {
    test('$path asks the pre-flight checks before its plan starts', () {
      final source = File(path).readAsStringSync();
      expect(source, contains('confirmPreflight('));
    });
  }
}
