// The panel must announce its clipped content. At a 1600x1000 window the
// guiding controls card is taller than the slot the Guiding screen gives it,
// and a ~4 px sliver of a card edge at the bottom margin is the only hint more
// exists — so "Settle Settings", the control that governs post-dither settle
// behaviour, is invisible unless the user guesses they can scroll inside the
// card.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/phd2/guide_controls_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pumpPanel(WidgetTester tester, {required double height}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(420, height + 40);
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
          height: height,
          child: const GuideControlsPanel(
            state: Phd2GuidingState.stopped,
            isConnected: true,
          ),
        ),
      ),
    ),
  );
  // One extra frame: the affordance is computed from live scroll metrics and
  // committed in a post-frame callback.
  await tester.pump();
  await tester.pump();
}

Finder get _moreBelowChevron => find.byKey(GuideControlsPanel.moreBelowKey);

void main() {
  testWidgets('short panel advertises the content below the fold',
      (tester) async {
    await _pumpPanel(tester, height: 380);

    expect(
      _moreBelowChevron,
      findsOneWidget,
      reason: 'clipped controls must announce themselves',
    );
    final scrollbar = tester.widget<Scrollbar>(
      find.descendant(
        of: find.byType(GuideControlsPanel),
        matching: find.byType(Scrollbar),
      ),
    );
    expect(scrollbar.thumbVisibility, isTrue);
  });

  testWidgets('tall panel shows no affordance because nothing is hidden',
      (tester) async {
    await _pumpPanel(tester, height: 1400);

    expect(_moreBelowChevron, findsNothing);
    expect(find.text('Settle settings'), findsOneWidget);
  });

  testWidgets('scrolling to the settle section reveals it', (tester) async {
    await _pumpPanel(tester, height: 380);

    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -600),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Settle settings'), findsOneWidget);
  });
}
