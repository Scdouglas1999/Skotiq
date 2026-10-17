// Every Rig-card row must name what it is reporting on.
//
// The old strip published pills whose label was the device noun and whose
// value was the state; assistive tech read "Camera — disconnected". The card's
// rows carry the same sentence — a row that publishes only "Disconnected"
// answers a question nobody asked.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/rig_card.dart';

import '../../harness/pump_app_screen.dart';

Future<void> _pumpCard(WidgetTester tester, {required bool expanded}) async {
  await pumpAppScreen(
    tester,
    SizedBox(
      width: expanded ? 220 : 72,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [RigCard(isExpanded: expanded)],
      ),
    ),
    size: const Size(1400, 900),
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _disposeCard(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

/// Semantic labels published anywhere inside the card.
Set<String> _labelsIn(WidgetTester tester) {
  final found = <String>{};
  final card = find.byType(RigCard).evaluate().single;
  void walk(Element element) {
    final widget = element.widget;
    if (widget is Semantics) {
      final label = widget.properties.label;
      if (label != null && label.isNotEmpty) found.add(label);
    }
    element.visitChildren(walk);
  }

  card.visitChildren(walk);
  return found;
}

void main() {
  testWidgets('each expanded row names its device and its state',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpCard(tester, expanded: true);

    final labels = _labelsIn(tester);
    for (final device in const ['Camera', 'Mount', 'Guider', 'Focus']) {
      expect(
        labels.any((l) => l.startsWith('$device, ')),
        isTrue,
        reason: 'no row publishes "$device, <state>"',
      );
    }
    // The run row reads "Sequence, Idle" with nothing running.
    expect(
      labels.any((l) => l.startsWith('Sequence, ')),
      isTrue,
      reason: 'the run-state row must name the sequence and its state',
    );

    semantics.dispose();
    await _disposeCard(tester);
  });

  testWidgets('the collapsed card still publishes every device',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpCard(tester, expanded: false);

    final labels = _labelsIn(tester);
    for (final device in const ['Camera', 'Mount', 'Guider', 'Focus']) {
      expect(
        labels.any((l) => l.startsWith('$device, ')),
        isTrue,
        reason: 'the icon-only row for $device still has to say what it is',
      );
    }

    semantics.dispose();
    await _disposeCard(tester);
  });
}
