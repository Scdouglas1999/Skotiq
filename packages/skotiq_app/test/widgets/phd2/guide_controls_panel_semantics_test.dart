// The guiding controls are what start and stop guiding, so assistive tech has
// to be told what they are and whether they can be used.
//
// The audit's tree dump of the Guiding screen with PHD2 disconnected read
// "panel: Start / panel: Pause / panel: Loop Exposures / panel: Auto Select /
// panel: Deselect / panel: Dither Now" — role "panel", never "button", and
// never [DISABLED], even though all six were logically disabled. The same dump
// carried "button: Connect", so the harness does read roles and states when
// they are published; these controls simply published none.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/phd2/guide_controls_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pumpPanel(
  WidgetTester tester, {
  required Phd2GuidingState state,
  required bool isConnected,
  Future<void> Function()? onStartGuiding,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(420, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: SizedBox(
          width: 360,
          height: 820,
          child: GuideControlsPanel(
            state: state,
            isConnected: isConnected,
            onStartGuiding: onStartGuiding,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a disabled guiding control announces button + disabled',
      (tester) async {
    final handle = tester.ensureSemantics();

    // PHD2 disconnected: every control is logically disabled (onPressed null).
    await _pumpPanel(
      tester,
      state: Phd2GuidingState.disconnected,
      isConnected: false,
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('Start')),
      isSemantics(
        label: 'Start',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('an available guiding control announces button + enabled',
      (tester) async {
    final handle = tester.ensureSemantics();

    await _pumpPanel(
      tester,
      state: Phd2GuidingState.stopped,
      isConnected: true,
      onStartGuiding: () async {},
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('Start')),
      isSemantics(
        label: 'Start',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('the control is still activatable through its semantics action',
      (tester) async {
    final handle = tester.ensureSemantics();

    var starts = 0;
    await _pumpPanel(
      tester,
      state: Phd2GuidingState.stopped,
      isConnected: true,
      onStartGuiding: () async => starts++,
    );

    tester.semantics.performAction(
      find.semantics.byLabel('Start'),
      SemanticsAction.tap,
    );
    await tester.pump();

    expect(starts, 1,
        reason: 'excluding descendant semantics must not cost the tap action');
    handle.dispose();
  });
}
