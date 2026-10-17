// The search box and the bottom readout strip must not publish themselves as
// interactive-but-dead.
//
// Undeclared, the planetarium's AT-SPI dump reads:
//
//   panel: Search
//   Ctrl+K [DISABLED]
//   panel: 20:37:18 / 1x / Center RA: 17h 6m 24s / Center Dec: +40 deg 0'
//          / FOV (short axis): 60.0 deg / Bortle: 5 (lim 5.9m) [DISABLED]
//
// Two mechanisms, one root: a widget with a tap action but no role (InkWell,
// GestureDetector) publishes a focusable node with no enabled state, and bare
// sibling Texts have no semantics boundary of their own, so Flutter merges them
// into the nearest enclosing node — here the sky canvas, which is tappable.
// Hence one giant focusable "panel" holding the clock, the rate and every
// readout, reported disabled.
//
// So each readout gets a container node named "<label> <value>" — label AND
// value — and each control a real button role.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/bottom_info_bar.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

List<SemanticsData> _tree(WidgetTester tester) {
  // ignore: deprecated_member_use
  final root = tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
  final out = <SemanticsData>[];
  void visit(SemanticsNode node) {
    out.add(node.getSemanticsData());
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(root);
  return out;
}

void main() {
  testWidgets('a HUD readout is one node naming its label AND its value', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: Stack(
              children: [
                // Stand-in for the sky canvas: a full-bleed tappable region,
                // which is the node that can swallow the readouts.
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () {},
                    child: const ColoredBox(color: Color(0xFF000010)),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: InfoItem(
                    label: 'Center RA',
                    compactLabel: 'RA',
                    value: '17h 6m 24s',
                    colors: SkotiqColors.of(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tree = _tree(tester);
    final readouts = tree.where((d) => d.label.contains('Center RA')).toList();

    expect(readouts, isNotEmpty, reason: 'the readout must name itself');
    expect(
      readouts.any((d) => d.label.contains('17h 6m 24s')),
      isTrue,
      reason: 'a readout node must carry its value, not just its label',
    );
    expect(
      readouts.every((d) =>
          !d.hasFlag(SemanticsFlag.isFocusable) &&
          !d.hasAction(SemanticsAction.tap)),
      isTrue,
      reason: 'it was absorbed into the tappable canvas node and reported '
          'itself as an interactive control that does nothing',
    );

    handle.dispose();
  });
}
