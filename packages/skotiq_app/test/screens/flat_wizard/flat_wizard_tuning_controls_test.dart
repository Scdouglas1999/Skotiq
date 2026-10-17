// Flat wizard tuning controls: the frame count is TYPEABLE, and the two
// sliders carry their captions on every tab.
//
// A read-only frame count between -/+ steppers costs 27 taps to walk from the
// default 30 down to 3. And on Multi-filter batch / Sky flats the histogram
// target and tolerance sliders render as a bare "11%" over a bare "±10%" under
// one "Global Settings" heading, with nothing saying which is which.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/flat_wizard/flat_wizard_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

Future<HarnessHandle> _pump(WidgetTester tester) async {
  final handle = await pumpAppScreen(
    tester,
    const FlatWizardScreen(),
    size: const Size(1280, 900),
    settle: false,
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return handle;
}

/// Move to one of the three mode tabs and drain the tab animation.
Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

TextField _frameField(WidgetTester tester) {
  final fields = tester.widgetList<TextField>(find.byType(TextField)).where(
        (f) => f.textAlign == TextAlign.center,
      );
  expect(fields, isNotEmpty, reason: 'the frame count must be a text field');
  return fields.first;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the frame count accepts a typed value in one edit',
      (tester) async {
    final container = (await _pump(tester)).container;
    container.read(flatWizardProvider.notifier).setFrameCount(30);
    await tester.pump();

    expect(_frameField(tester).controller!.text, '30');

    await tester.enterText(find.byType(TextField).first, '3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(
      container.read(flatWizardProvider).globalSettings.frameCount,
      3,
      reason: 'typing 3 must set the frame count without 27 stepper taps',
    );
  });

  testWidgets('a typed frame count outside the accepted range snaps back',
      (tester) async {
    final container = (await _pump(tester)).container;

    await tester.enterText(find.byType(TextField).first, '0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(container.read(flatWizardProvider).globalSettings.frameCount, 1);
    expect(_frameField(tester).controller!.text, '1',
        reason: 'the field must show what the run will actually use');
  });

  testWidgets('a typed frame count commits when the field loses focus',
      (tester) async {
    // The operator who types "3" and then reaches straight for Start never
    // presses Enter. An edit that lands only on submit leaves the run using the
    // previous count, silently.
    final container = (await _pump(tester)).container;
    container.read(flatWizardProvider.notifier).setFrameCount(30);
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '3');
    await tester.pump();
    // Anywhere outside the field: the Start button, a label, the background.
    await tester.tap(find.text('Frames').first);
    await tester.pump();

    expect(
      container.read(flatWizardProvider).globalSettings.frameCount,
      3,
      reason: 'leaving the field must commit what is in it',
    );
  });

  testWidgets('the steppers still work and keep the field in sync',
      (tester) async {
    final container = (await _pump(tester)).container;
    container.read(flatWizardProvider.notifier).setFrameCount(5);
    await tester.pump();

    await tester.tap(find.byTooltip('One more frame').first);
    await tester.pump();

    expect(container.read(flatWizardProvider).globalSettings.frameCount, 6);
    expect(_frameField(tester).controller!.text, '6');
  });

  for (final tab in const ['Multi-filter batch', 'Sky flats']) {
    testWidgets('$tab labels its capture-settings rows', (tester) async {
      await _pump(tester);
      await _openTab(tester, tab);

      // The labels live in the FormRow's left column now, not in a caption
      // stacked above each control.
      expect(find.text('Histogram target'), findsWidgets,
          reason: '$tab must say which slider is the target');
      expect(find.text('Tolerance'), findsWidgets,
          reason: '$tab must say which slider is the tolerance');
      expect(find.text('Frames'), findsWidgets);
    });
  }
}
