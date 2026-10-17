// Phone-tier responsive coverage for the Sequencer screen.
//
// Per the mobile responsive standard (docs/plans/2026-06-01-mobile-responsive-
// standard.md) we pump the real `SequencerScreen` at the three reference phone
// sizes in BOTH orientations and assert:
//   * no RenderFlex / layout overflow at any size or orientation,
//   * the tab strip is the non-overflowing AdaptiveTabBar (and scrolls
//     rather than overflowing — the whole point of the rework),
//   * the sequence tree (the dominant primary region) is on screen,
//   * the add-node FAB is reachable.
//
// The screen is service-backed (settings, backend, tutorial DB). We pump it
// through the shared `pumpAppScreen` harness so those run against an in-memory
// database + mock backend — the layout (the thing under test) renders without
// touching real hardware or disk.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_properties_panel.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/widgets/tutorial_keys/sequencer_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

/// A small but realistic sequence: a container with one exposure child.
Sequence _seedSequence() {
  final exposure = ExposureNode(name: 'Lum', durationSecs: 120, count: 10);
  final container = InstructionSetNode(name: 'Lights');
  final root = InstructionSetNode(name: 'Root');
  final nodes = <String, SequenceNode>{
    exposure.id: exposure.copyWith(parentId: container.id),
    container.id:
        container.copyWith(parentId: root.id, childIds: [exposure.id]),
    root.id: root.copyWith(childIds: [container.id]),
  };
  return Sequence.create(name: 'Test', nodes: nodes, rootNodeId: root.id);
}

List<Override> _overrides() {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = _seedSequence();
  return [
    currentSequenceProvider.overrideWith((_) => notifier),
    // Idle = editable; the builder shows its add/edit affordances.
    sequenceExecutionStateProvider
        .overrideWith((ref) => SequenceExecutionState.idle),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // (label, portrait size). Landscape is the transpose.
  const phones = <(String, Size)>[
    ('small 360x640', Size(360, 640)),
    ('modern 390x844', Size(390, 844)),
    ('large 430x932', Size(430, 932)),
  ];

  Future<void> expectUsable(WidgetTester tester) async {
    // No layout / overflow exception was thrown while building.
    expect(tester.takeException(), isNull);

    // Tab strip — the overflow-proof AdaptiveTabBar. The Builder tab is
    // present (located by its tutorial key, since on a compact phone the
    // AdaptiveTabBar collapses text labels to icon-only — that's by design,
    // so we don't assert on the literal "Builder" text here).
    expect(find.byType(AdaptiveTabBar), findsOneWidget);
    expect(find.byKey(SequencerTutorialKeys.tabBuilder), findsOneWidget);

    // The dominant region: the sequence tree.
    expect(find.byType(SequenceTree), findsOneWidget);

    // Add-node affordance is reachable.
    expect(find.byType(FloatingActionButton), findsWidgets);
  }

  for (final (label, portrait) in phones) {
    final landscape = Size(portrait.height, portrait.width);

    testWidgets('$label portrait: no overflow, tree + tabs present',
        (tester) async {
      await pumpAppScreen(
        tester,
        const SequencerScreen(),
        size: portrait,
        extraOverrides: _overrides(),
        settle: false,
      );
      // Drain the fade controller + the post-frame default-sequence /
      // tour-prompt callbacks without risking a pumpAndSettle timeout.
      await tester.pump(const Duration(milliseconds: 600));
      await expectUsable(tester);
    });

    testWidgets('$label landscape: no overflow, tree + tabs present',
        (tester) async {
      await pumpAppScreen(
        tester,
        const SequencerScreen(),
        size: landscape,
        extraOverrides: _overrides(),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 600));
      await expectUsable(tester);
    });
  }

  // Bespoke: in phone LANDSCAPE with a node selected, the builder shows a
  // side-by-side tree + properties split (TwoPane) inline — no sheet needed —
  // and still doesn't overflow. Drive the selection through the provider so
  // we don't depend on hit-testing the tree row.
  testWidgets('phone landscape with a selection shows the inline split',
      (tester) async {
    final notifier = CurrentSequenceNotifier();
    final seq = _seedSequence();
    // ignore: invalid_use_of_protected_member
    notifier.state = seq;
    final selectedId = seq.nodes.values.firstWhere((n) => n is ExposureNode).id;

    final handle = await pumpAppScreen(
      tester,
      const SequencerScreen(),
      // 844x390 landscape — wide enough (>= 560) for the split.
      size: const Size(844, 390),
      extraOverrides: [
        currentSequenceProvider.overrideWith((_) => notifier),
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.idle),
      ],
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 600));

    // Select a node, then rebuild.
    handle.container.read(selectedNodeIdProvider.notifier).state = selectedId;
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    // The inline properties pane is on screen alongside the tree.
    expect(find.byType(NodePropertiesPanel), findsWidgets);
    expect(find.byType(SequenceTree), findsOneWidget);
  });
}
