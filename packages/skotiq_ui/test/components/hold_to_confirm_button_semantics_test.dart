import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pump(
  WidgetTester tester, {
  required VoidCallback onConfirmed,
  bool enabled = true,
}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: HoldToConfirmButton(
              onConfirmed: onConfirmed,
              enabled: enabled,
              confirmText: 'Hold to stop',
              semanticsLabel: 'Stop the run',
              child: const SizedBox(width: 80, height: 32),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('a screen reader can press it: activate and long press confirm',
      (tester) async {
    final handle = tester.ensureSemantics();
    var confirmed = 0;
    await _pump(tester, onConfirmed: () => confirmed++);

    final node = tester.getSemantics(find.byType(HoldToConfirmButton));
    expect(node.label, 'Stop the run');
    final data = node.getSemanticsData();
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(data.hasAction(SemanticsAction.longPress), isTrue);

    tester.binding.pipelineOwner.semanticsOwner!
        .performAction(node.id, SemanticsAction.tap);
    await tester.pump();
    expect(confirmed, 1);

    tester.binding.pipelineOwner.semanticsOwner!
        .performAction(node.id, SemanticsAction.longPress);
    await tester.pump();
    expect(confirmed, 2);
    handle.dispose();
  });

  testWidgets('a pointer still has to hold: a tap confirms nothing',
      (tester) async {
    var confirmed = 0;
    await _pump(tester, onConfirmed: () => confirmed++);

    await tester.tap(find.byType(HoldToConfirmButton));
    await tester.pump(const Duration(seconds: 3));
    expect(confirmed, 0);

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(HoldToConfirmButton)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(confirmed, 1);
  });

  testWidgets('disabled, it offers no action', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, onConfirmed: () {}, enabled: false);
    final data = tester
        .getSemantics(find.byType(HoldToConfirmButton))
        .getSemanticsData();
    expect(data.hasAction(SemanticsAction.tap), isFalse);
    expect(data.hasAction(SemanticsAction.longPress), isFalse);
    handle.dispose();
  });
}
