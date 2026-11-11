// The guide graph's Time / Scale selectors must publish the value they are set
// to, not just the button role.
//
// `Semantics(button: true, label: label, value: value, excludeSemantics: true)`
// drops the child `Text('5m')`, and `SemanticsProperties.value` is not
// published on the Linux AT-SPI bridge for a plain button — the node then reads
// `button: Time:` with the selected scale nowhere in the tree.
//
// The pin is on the NAME, because the name is the one field every bridge
// publishes. The value stays set as well, for the platforms that do read it.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pumpGraph(WidgetTester tester, {double width = 900}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: SizedBox(
          width: width,
          height: 320,
          child: GuideGraphAdvanced(
            data: const [],
            onTimeScaleChanged: (_) {},
            onYScaleChanged: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every accessible name in the tree, the way a screen reader would read them.
List<String> _names(WidgetTester tester) {
  final labels = <String>[];
  void visit(SemanticsNode node) {
    if (node.label.isNotEmpty) labels.add(node.label);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
  return labels;
}

void main() {
  testWidgets('the scale selectors announce their selected value', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpGraph(tester);

    final names = _names(tester);

    expect(
      names.where((n) => n.contains('Time:') && n.contains('5m')),
      isNotEmpty,
      reason: 'the X-axis selector must say WHICH span is selected',
    );
    expect(
      names.where((n) => n.contains('Scale:') && n.contains('2')),
      isNotEmpty,
      reason: 'the Y-axis selector must say WHICH range is selected',
    );

    // ...and it is still a button, which is what the earlier fix bought.
    final timeButtons = <SemanticsNode>[];
    void collect(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.hasFlag(SemanticsFlag.isButton) &&
          data.label.contains('Time:')) {
        timeButtons.add(node);
      }
      node.visitChildren((child) {
        collect(child);
        return true;
      });
    }

    collect(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    expect(
      timeButtons,
      isNotEmpty,
      reason: 'a selector that reads as static text cannot be operated',
    );
    expect(
      timeButtons.every(
        (n) => n.getSemanticsData().hasFlag(SemanticsFlag.isEnabled),
      ),
      isTrue,
      reason: 'and it must not report itself as disabled',
    );
    handle.dispose();
  });
}
