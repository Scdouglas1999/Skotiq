import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/capture_settings_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// The Exp/Gain boxes commit on BLUR as well as Enter: committing only on Enter
/// leaves a value typed and then abandoned by Tab — or by clicking Capture,
/// which unfocuses on desktop — on screen while the rig exposes at the old one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Finder fieldAfter(String label) => find.ancestor(
        of: find.text('$label:'),
        matching: find.byType(Row),
      );

  Finder textFieldFor(String label) => find.descendant(
        of: fieldAfter(label).first,
        matching: find.byType(TextField),
      );

  testWidgets('exposure typed then blurred commits to the provider',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const CaptureSettingsCard(colors: SkotiqColors.dark),
    );

    expect(handle.container.read(exposureSettingsProvider).exposureTime, 2.0);

    await tester.enterText(textFieldFor('Exp'), '7');
    await tester.pump();
    // Blur without pressing Enter — the gesture that must still commit.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pump();

    expect(handle.container.read(exposureSettingsProvider).exposureTime, 7.0);
    expect(
      tester.widget<TextField>(textFieldFor('Exp')).controller!.text,
      '7.0',
      reason: 'the box must renormalise onto the committed value',
    );
  });

  testWidgets('gain typed then blurred commits to the provider',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const CaptureSettingsCard(colors: SkotiqColors.dark),
    );

    await tester.enterText(textFieldFor('Gain'), '250');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pump();

    expect(handle.container.read(exposureSettingsProvider).gain, 250);
  });

  testWidgets('unparseable exposure snaps back to the value in force',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const CaptureSettingsCard(colors: SkotiqColors.dark),
    );
    final before = handle.container.read(exposureSettingsProvider).exposureTime;

    await tester.enterText(textFieldFor('Exp'), 'abc');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pump();

    expect(
        handle.container.read(exposureSettingsProvider).exposureTime, before);
    expect(
      tester.widget<TextField>(textFieldFor('Exp')).controller!.text,
      before.toString(),
      reason: 'a rejected edit must not keep sitting there looking committed',
    );
  });
}
