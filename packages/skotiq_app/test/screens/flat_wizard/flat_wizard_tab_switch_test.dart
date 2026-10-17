// Changing the Flat Wizard's mode tab must not throw.
//
// The three mode tabs live in a TabBarView, which keeps the OUTGOING tab
// mounted across a switch. _BatchCaptureControls and _SkyFlatsControls both
// attach FlatWizardTutorialKeys.filterSelect / targetAdu / frameCount, and all
// three tabs mount _ActionButtons with FlatWizardTutorialKeys.startBtn — those
// are GlobalKeys, so two live elements claiming one key throws "The following
// GlobalKey was specified multiple times in the widget tree" in a debug build
// and silently reparents state in release. Only the tab whose mode is selected
// may claim them.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_app/screens/flat_wizard/flat_wizard_screen.dart';

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
      // Desktop width: the tab strip shows its labels and the controls panel
      // sits beside the preview, which is where the duplicated keys mount.
      size: const Size(1280, 900),
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
    }
  });
}
