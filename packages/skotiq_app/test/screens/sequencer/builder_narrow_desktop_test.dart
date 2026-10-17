// The builder at a small desktop window.
//
// At 900x900 an unyielding three-pane builder keeps the properties pane at
// ~250px and the palette at ~200px while the CANVAS — the pane holding the
// document — is squeezed to roughly 180px. At that width the exposure node's
// inline editors break to one control per line (leaving a bare "x" alone on a
// row), "Total 3.0" is clipped mid-value, "+ Add note" is sliced by the pane
// edge and the target rollup truncates to "12 planne...". The rail fallback does
// not fire, because it only triggers below palette + 300 + properties
// *collapsed*, which 900px clears easily.
//
// The same window from the palette's side clips its tab strip to "\odes" and
// "Queu" — the outer labels cut by a scrollable strip in a viewport too small
// for it.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/pump_app_screen.dart';

Sequence _seedSequence() {
  final exposure = ExposureNode(name: 'Lights', durationSecs: 180, count: 12);
  final target = TargetHeaderNode(
    targetName: 'M42-TEST',
    raHours: 5.588,
    decDegrees: -5.39,
  );
  final root = InstructionSetNode(name: 'Root');
  final nodes = <String, SequenceNode>{
    exposure.id: exposure.copyWith(parentId: target.id),
    target.id: target.copyWith(parentId: root.id, childIds: [exposure.id]),
    root.id: root.copyWith(childIds: [target.id]),
  };
  return Sequence.create(name: 'Narrow', nodes: nodes, rootNodeId: root.id);
}

List<Override> _overrides() {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = _seedSequence();
  return [
    currentSequenceProvider.overrideWith((_) => notifier),
    sequenceExecutionStateProvider
        .overrideWith((ref) => SequenceExecutionState.idle),
    // The ledger ETA clock is a real periodic stream; in the fake-async
    // zone its timer outlives every pump and fails teardown.
    ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a narrow builder collapses a side panel, not the canvas',
      (tester) async {
    // 700px of pane area is what a 900px WINDOW leaves once the nav rail and
    // the shell chrome take their share. With both side panels at their
    // minimums the canvas gets 700 - 220 - 270 = 210px, the ~180px squeeze.
    await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: const Size(700, 900),
      extraOverrides: _overrides(),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 600));

    final treeWidth = tester.getSize(find.byType(SequenceTree)).width;
    expect(
      treeWidth,
      greaterThanOrEqualTo(360.0),
      reason: 'the side panels must give way before the canvas does; the live '
          'defect left the canvas at ~180px while properties kept ~250 and '
          'the palette ~200',
    );
  });

  testWidgets('at a 1600px window all three panes stay open', (tester) async {
    await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: const Size(1600, 900),
      extraOverrides: _overrides(),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
    // The palette's tab strip is only rendered when the panel is expanded, so
    // finding its labels proves the wide layout did not collapse anything.
    expect(find.text('Nodes'), findsOneWidget);
    expect(find.text('Snippets'), findsOneWidget);
    expect(find.text('Targets'), findsOneWidget);
  });

  // The palette tabs switch panes on click, so the accessibility tree must not
  // publish them as "Tab 1 of 3 [DISABLED]".
  testWidgets('the palette tabs announce themselves as enabled',
      (tester) async {
    final semantics = tester.ensureSemantics();

    await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: const Size(1600, 900),
      extraOverrides: _overrides(),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 600));

    for (final label in const ['Nodes', 'Snippets', 'Targets']) {
      final data = tester.getSemantics(find.text(label)).getSemanticsData();
      expect(
        // ignore: deprecated_member_use
        data.hasFlag(SemanticsFlag.isEnabled),
        isTrue,
        reason: 'the "$label" tab is live and must not announce as disabled',
      );
    }
    semantics.dispose();
  });

  testWidgets('the palette tab labels are never clipped by their strip',
      (tester) async {
    // 1000x900 is the width the strip clips its outer labels at.
    await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: const Size(1000, 900),
      extraOverrides: _overrides(),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 600));

    final tabBar = find.byType(TabBar);
    if (tabBar.evaluate().isEmpty) {
      // The toolbox collapsed at this width — nothing to clip.
      return;
    }
    final stripRect = tester.getRect(tabBar.first);
    for (final label in const ['Nodes', 'Snippets', 'Targets']) {
      final finder = find.text(label);
      if (finder.evaluate().isEmpty) continue;
      final rect = tester.getRect(finder.first);
      expect(
        rect.left,
        greaterThanOrEqualTo(stripRect.left - 0.5),
        reason: '"$label" is cut off the left edge of the tab strip',
      );
      expect(
        rect.right,
        lessThanOrEqualTo(stripRect.right + 0.5),
        reason: '"$label" runs past the right edge of the tab strip',
      );
    }
  });
}
