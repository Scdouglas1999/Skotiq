// Three controls that must not publish the wrong thing about themselves.
//
// Undeclared, the tree reads:
//   * Imaging: `panel: Overlays [DISABLED]` — a live popup trigger announced as
//     an inert panel. (The harness prints [DISABLED] on a node that is
//     interactive but carries no enabled/sensitive state.)
//   * Imaging: `panel: Frame Type` then `button: Light`, and `panel: Binning`
//     then `button: 1x1` — the label and the value it belongs to arrive as two
//     adjacent, unassociated nodes, so a screen reader announces "Light" with
//     nothing saying what is Light.
//   * Sequencer palette: `panel: Nodes / Tab 1 of 3` — role-less.
//
// The first two are asserted on the rendered semantics here. The palette tab
// lives in a private widget inside SequencerScreen, so it is guarded at source
// level in `toolbox_tab_role_test.dart`.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_preview_toolbar.dart';
import 'package:skotiq_app/screens/imaging/widgets/panel_widgets.dart';
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

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );
  await tester.pump();
}

void _noop() {}

void main() {
  testWidgets('the Overlays menu announces itself as an enabled button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      const OverlaysMenuButton(
        showCrosshair: false,
        showStarOverlay: false,
        onToggleCrosshair: _noop,
        onToggleStarOverlay: _noop,
      ),
    );

    final overlays =
        _tree(tester).where((d) => d.label.contains('Overlays')).toList();
    expect(overlays, isNotEmpty, reason: 'the control must name itself');
    expect(
      overlays.any(
        (d) =>
            d.hasFlag(SemanticsFlag.isButton) &&
            d.hasFlag(SemanticsFlag.hasEnabledState) &&
            d.hasFlag(SemanticsFlag.isEnabled) &&
            d.hasAction(SemanticsAction.tap),
      ),
      isTrue,
      reason: 'undeclared it publishes as `panel: Overlays [DISABLED]`',
    );
    expect(
      overlays.length,
      1,
      reason: 'one control, one node — not a named panel beside a button',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    handle.dispose();
  });

  testWidgets('a panel dropdown carries its label and its value on one node', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownRow(
              label: 'Frame type',
              value: 'Light',
              items: const ['Light', 'Dark', 'Flat', 'Bias'],
              colors: SkotiqColors.dark,
              onChanged: (_) {},
            ),
            DropdownRow(
              label: 'Binning',
              value: '1x1',
              items: const ['1x1', '2x2'],
              colors: SkotiqColors.dark,
              onChanged: (_) {},
            ),
          ],
        ),
      ),
    );

    final tree = _tree(tester);
    for (final pair in const [
      ('Frame type', 'Light'),
      ('Binning', '1x1'),
    ]) {
      expect(
        tree.any(
          (d) => d.label.contains(pair.$1) && d.label.contains(pair.$2),
        ),
        isTrue,
        reason:
            'unmerged, "${pair.$1}" and "${pair.$2}" arrive as two adjacent, '
            'unassociated nodes',
      );
      // And the label is not left stranded on a node of its own.
      expect(
        tree.where((d) => d.label.trim() == pair.$1),
        isEmpty,
        reason: '"${pair.$1}" alone on a node says nothing about the value',
      );
    }

    await tester.pumpWidget(const SizedBox.shrink());
    handle.dispose();
  });
}
