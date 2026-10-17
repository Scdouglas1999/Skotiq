// F4: a tooltip whose trigger is rebuilt or unmounted under the cursor.
//
// `MouseRegion.onExit` reports a POINTER leaving. Nothing moves when the
// widget under a stationary cursor is rebuilt with new configuration, or is
// taken out of the tree entirely, so no exit ever arrives and the label stays
// up naming a control that has changed or gone.
//
// The rail is where this is worst: clicking a collapsed rail item rebuilds the
// whole rail with a new selection while the pointer sits still on the item,
// and the label for the item as it WAS stayed painted over the page body until
// the six-second self-retirement clock caught it.
//
// Three retirement paths are pinned here: didUpdateWidget, deactivate, and a
// pointer-up.

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  const trigger = Key('trigger');
  const message = 'Equipment';

  Widget host({
    required String label,
    bool mounted = true,
    VoidCallback? onTap,
  }) {
    return MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Center(
          child: mounted
              ? SkotiqTooltip(
                  message: label,
                  child: GestureDetector(
                    onTap: onTap,
                    child: ColoredBox(
                      key: trigger,
                      color: const Color(0xFF224466),
                      child: const SizedBox(width: 40, height: 40),
                    ),
                  ),
                )
              : const SizedBox(width: 40, height: 40),
        ),
      ),
    );
  }

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

  testWidgets('a rebuild under a stationary cursor retires the label', (
    tester,
  ) async {
    await tester.pumpWidget(host(label: message));
    await hover(tester);
    expect(find.text(message), findsOneWidget, reason: 'tooltip should show');

    // The pointer does NOT move. Only the tree is rebuilt, which is what
    // happens when a rail item is clicked or a status pill's value ticks.
    await tester.pumpWidget(host(label: message));
    await tester.pump();

    expect(
      find.text(message),
      findsNothing,
      reason:
          'no onExit arrives for a rebuild, so the tooltip must retire '
          'itself; otherwise the label outlives the state it described',
    );
  });

  testWidgets('a trigger taken out of the tree takes its label with it', (
    tester,
  ) async {
    await tester.pumpWidget(host(label: message));
    await hover(tester);
    expect(find.text(message), findsOneWidget);

    await tester.pumpWidget(host(label: message, mounted: false));
    await tester.pump();

    expect(find.text(message), findsNothing);
  });

  testWidgets('a click on the hovered trigger retires the label', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(host(label: message, onTap: () => taps++));
    await hover(tester);
    expect(find.text(message), findsOneWidget);

    await tester.tap(find.byKey(trigger));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(message), findsNothing);
    expect(
      taps,
      1,
      reason: 'the pointer listener must not steal the trigger\'s own gesture',
    );
  });
}
