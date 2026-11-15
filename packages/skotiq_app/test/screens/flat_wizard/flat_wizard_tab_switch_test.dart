// Changing the Flat wizard's mode tab must not throw.
//
// The tutorial targets (filter table, histogram target, frame count, start
// button) are GlobalKeys, and a GlobalKey may be on one live element only. The
// screen builds one settings column for the selected mode, so every mode
// switch must leave each key attached exactly once.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_app/screens/flat_wizard/flat_wizard_screen.dart';
import 'package:skotiq_app/tours/tour_target.dart';

import '../../harness/harness.dart';

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('switching mode tabs never duplicates a tutorial GlobalKey',
      (tester) async {
    await pumpAppScreen(
      tester,
      const FlatWizardScreen(),
      // Desktop width: the tab strip shows its labels and the settings sit
      // beside the preview.
      size: const Size(1600, 900),
      settle: false,
    );
    await _drain(tester);
    expect(tester.takeException(), isNull);

    for (final tab in const [
      'Multi-filter batch',
      'Sky flats',
      'Quick capture',
      'Sky flats',
    ]) {
      await tester.tap(find.text(tab).first);
      await _drain(tester);
      expect(
        tester.takeException(),
        isNull,
        reason: 'selecting "$tab" must not duplicate a tutorial GlobalKey',
      );
      for (final target in const [
        TourTarget.flatFilterSelect,
        TourTarget.flatTargetAdu,
        TourTarget.flatFrameCount,
        TourTarget.flatStartButton,
      ]) {
        expect(find.byKey(target.key), findsOneWidget,
            reason: '"$tab" must carry the ${target.name} tutorial target');
      }
    }
  });
}
