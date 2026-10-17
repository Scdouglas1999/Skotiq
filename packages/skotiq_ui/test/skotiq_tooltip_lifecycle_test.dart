// D-2 (third look): planetarium tooltips never left the accessibility tree.
//
// Live evidence: hover the five command-bar icons for ~1.8 s each, park the
// pointer over the star field, wait 12 s — the screenshot shows a completely
// clean command bar while `tree --all` still lists
// `panel: Reset view (zenith, FOV 60)`, `panel: Projection: Stereographic` and
// `panel: Layers`.
//
// Two mechanisms, pinned separately:
//
//  1. the overlay was retired from `_animController.reverse().then(...)`, and a
//     TickerFuture whose ticker is cancelled NEVER completes — so any second
//     hide (or a show that interrupts a hide) silently dropped the `hide()`
//     call and left the portal mounted at zero opacity;
//  2. the floating label published its own accessible node, so any overlay that
//     outlives its hover is a panel in the tree naming a control that is not on
//     screen. The message now rides on the trigger, as `Semantics.tooltip`.

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  const trigger = Key('trigger');
  const message = 'Reset view (zenith, FOV 60)';

  Widget host() => MaterialApp(
    theme: SkotiqTheme.dark,
    home: const Scaffold(
      body: Center(
        child: SkotiqTooltip(
          message: message,
          child: ColoredBox(
            key: trigger,
            color: Color(0xFF224466),
            child: SizedBox(width: 34, height: 34),
          ),
        ),
      ),
    ),
  );

  Future<TestGesture> hover(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byKey(trigger)));
    await tester.pump();
    // Past the 300 ms show delay, then through the fade.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    return gesture;
  }

  testWidgets('the overlay is gone after the pointer leaves', (tester) async {
    await tester.pumpWidget(host());
    final gesture = await hover(tester);
    expect(find.text(message), findsOneWidget, reason: 'tooltip should show');

    await gesture.moveTo(const Offset(5, 5));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text(message), findsNothing);
  });

  testWidgets('a hide that interrupts a hide still retires the overlay', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final gesture = await hover(tester);
    expect(find.text(message), findsOneWidget);

    // Leave, and leave again a frame later: the second reverse() cancels the
    // first one's TickerFuture. A `.then()` retirement drops the hide the first
    // call scheduled and completes the second against an already-dismissed
    // controller, leaving the portal mounted forever.
    await gesture.moveTo(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.moveTo(const Offset(6, 6));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text(message), findsNothing);
  });

  testWidgets('a tooltip whose onExit never arrives retires itself', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await hover(tester);
    expect(find.text(message), findsOneWidget);

    // No exit event at all — the shape that stranded "Forward 1 hour" over the
    // sky for the rest of the session when the transport rebuilt under the
    // cursor.
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();

    expect(find.text(message), findsNothing);
  });

  testWidgets('the floating label publishes no accessible node', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host());
    await hover(tester);
    expect(find.text(message), findsOneWidget, reason: 'it is on screen');

    final labels = <String>[];
    final tooltips = <String>[];
    void visit(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.label.isNotEmpty) labels.add(data.label);
      if (data.tooltip.isNotEmpty) tooltips.add(data.tooltip);
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);

    expect(
      labels.where((l) => l.contains('Reset view')),
      isEmpty,
      reason: 'a floating label must never become a panel in the tree',
    );
    expect(
      tooltips,
      contains(message),
      reason: 'the message belongs to the trigger, which cannot outlive it',
    );
    handle.dispose();
  });
}
