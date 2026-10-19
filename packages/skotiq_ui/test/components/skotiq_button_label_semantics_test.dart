// A button announces its label once.
//
// The button's own Semantics carries the label, and the Text that paints it
// merged into the same node, so a screen reader read "Start now, Start now".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  testWidgets('the label is announced once', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, SkotiqButton(label: 'Start now', onPressed: () {}));
    final data = tester.getSemantics(find.byType(SkotiqButton));
    expect(data.label, 'Start now');
    expect(data.flagsCollection.isButton, isTrue);
    semantics.dispose();
  });

  testWidgets('a badge is announced once, after the label', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      SkotiqButton(
        label: 'Issues',
        badge: '3',
        badgeSemanticsLabel: '3 open',
        onPressed: () {},
      ),
    );
    expect(
      tester.getSemantics(find.byType(SkotiqButton)).label,
      'Issues, 3 open',
    );
    semantics.dispose();
  });

  testWidgets('a disabled button still names itself once', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, const SkotiqButton(label: 'Solve', onPressed: null));
    expect(tester.getSemantics(find.byType(SkotiqButton)).label, 'Solve');
    semantics.dispose();
  });
}
