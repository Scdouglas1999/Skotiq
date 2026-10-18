// Imaging → Focus layout at the side panel's real content width: the manual
// step sizes are one row, and the tab has one primary action.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/focus_panel.dart';
import 'package:skotiq_app/screens/imaging/widgets/panel_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../golden/surface_golden_harness.dart';
import '../../../harness/harness.dart';

class _ConnectedFocuser extends FocuserStateNotifier {
  _ConnectedFocuser(super.ref) {
    state = const FocuserState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'focuser-1',
      deviceName: 'Test Focuser',
      position: 45484,
      maxPosition: 600000,
      isAbsolute: true,
      hasTemperature: true,
      temperature: 10.7,
    );
  }
}

Future<void> _pump(WidgetTester tester) async {
  // 244 is what the 320 px side panel leaves its content.
  await pumpAppScreen(
    tester,
    const Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 244,
        height: 1400,
        child: FocusPanel(colors: SkotiqColors.dark),
      ),
    ),
    size: const Size(600, 1400),
    settle: false,
    extraOverrides: [
      focuserStateProvider.overrideWith(_ConnectedFocuser.new),
    ],
  );
  await tester.pump();
  await tester.pump();
}

Finder _segment(int step) => find.byWidgetPredicate(
      (Widget w) => w is Semantics && w.properties.label == 'Step size $step',
    );

void main() {
  setUpAll(SurfaceGoldenHarness.ensureFonts);

  testWidgets('the four step sizes share one row', (tester) async {
    await _pump(tester);

    final tops = <double>{
      for (final step in <int>[10, 50, 100, 500])
        tester.getTopLeft(_segment(step)).dy,
    };
    expect(tops, hasLength(1), reason: '500 must not wrap onto its own line');
    // Equal segments: 10 and 500 are the same size of target.
    expect(
      tester.getSize(_segment(10)).width,
      closeTo(tester.getSize(_segment(500)).width, 0.5),
    );
  });

  testWidgets('Run Autofocus is the only primary action on the tab',
      (tester) async {
    await _pump(tester);

    final goTo = tester.widget<SmallButton>(
      find.widgetWithText(SmallButton, 'Go To Position...'),
    );
    final run = tester.widget<SmallButton>(
      find.widgetWithText(SmallButton, 'Run Autofocus'),
    );
    expect(goTo.isOutline, isTrue, reason: 'Go To Position is secondary');
    expect(run.isOutline, isFalse);
  });

  testWidgets('the step-size label lines up with the Autofocus labels',
      (tester) async {
    await _pump(tester);

    expect(find.text('Step Size:'), findsNothing);
    final stepLabels = find.text('Step size');
    // The manual row and the Autofocus row share one label column.
    expect(stepLabels, findsNWidgets(2));
    expect(
      tester.getTopLeft(stepLabels.first).dx,
      tester.getTopLeft(stepLabels.last).dx,
    );
  });
}
