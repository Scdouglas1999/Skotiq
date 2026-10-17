// Pause under the built-in guider: unavailable, and it has to SAY so.
//
// With the built-in multi-star guider connected and guiding, clicking Pause
// does nothing observable — the state chip stays "Guiding", the frame counter
// keeps climbing, no toast, no log line. A hover TOOLTIP cannot carry the
// explanation: it is invisible to the operator who clicks, and does not exist at
// all on touch. Only a disabled button carrying that text as its reason closes
// this.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/guiding/guiding_screen.dart'
    show kBuiltinGuiderNoPauseReason;
import 'package:skotiq_app/widgets/phd2/guide_controls_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pumpBuiltinGuiderPanel(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(420, 1200);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: SizedBox(
          width: 380,
          height: 1100,
          child: GuideControlsPanel(
            // Steady-state guiding on the built-in guider: the screen passes no
            // pause handler (it is a PHD2 command) and the reason instead.
            state: Phd2GuidingState.guiding,
            isConnected: true,
            onStopGuiding: () async {},
            pauseUnavailableReason: kBuiltinGuiderNoPauseReason,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('Pause is published as a disabled button with its reason',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpBuiltinGuiderPanel(tester);

    final pause = find.bySemanticsLabel(RegExp('^Pause —'));
    expect(pause, findsOneWidget);
    final node = tester.getSemantics(pause);
    expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(node.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(
      node.hasFlag(SemanticsFlag.isEnabled),
      isFalse,
      reason: 'a control that does nothing must not present as live',
    );
    expect(
      node.getSemanticsData().label,
      contains('The built-in guider has no pause'),
    );

    handle.dispose();
  });

  testWidgets('pressing Pause states the reason instead of doing nothing',
      (tester) async {
    await _pumpBuiltinGuiderPanel(tester);

    expect(find.byKey(GuideControlsPanel.noticeBannerKey), findsNothing);

    await tester.tap(find.text('Pause'));
    await tester.pump();

    expect(
      find.byKey(GuideControlsPanel.noticeBannerKey),
      findsOneWidget,
      reason: 'the click produced no visible response at all',
    );
    expect(
      find.textContaining('The built-in guider has no pause'),
      findsWidgets,
    );

    // And it is dismissible, so the explanation does not become permanent
    // chrome on a panel the operator uses all night.
    await tester.tap(find.bySemanticsLabel('Dismiss notice'));
    await tester.pump();
    expect(find.byKey(GuideControlsPanel.noticeBannerKey), findsNothing);
  });

  testWidgets('a PHD2 guider keeps a live Pause button', (tester) async {
    final handle = tester.ensureSemantics();
    var paused = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SizedBox(
            width: 380,
            height: 1100,
            child: GuideControlsPanel(
              state: Phd2GuidingState.guiding,
              isConnected: true,
              onStopGuiding: () async {},
              onPauseGuiding: () async => paused = true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final node = tester.getSemantics(find.bySemanticsLabel('Pause'));
    expect(node.hasFlag(SemanticsFlag.isEnabled), isTrue);

    await tester.tap(find.text('Pause'));
    await tester.pump();
    expect(paused, isTrue);
    expect(find.byKey(GuideControlsPanel.noticeBannerKey), findsNothing);

    handle.dispose();
  });
}
