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
import 'package:skotiq_app/screens/sequencer/widgets/sequence_progress_bar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/tours/tour_target.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
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
    // A phone on its side draws the ledger, whose ETA clock is a periodic
    // stream that would outlive the fake-async test.
    ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
  ];
}

Override _running() => runRecordProvider.overrideWith(
      (ref) => RunRecordNotifier(
        ref,
        const RunRecord(
          lifecycle: SequenceExecutionState.running,
          progress: SequenceProgress(
            state: SequenceExecutionState.running,
            currentNodeName: 'Lunar Frames',
            message: 'Progress: 48/200 exposures',
            currentFilter: 'R',
            completedExposures: 48,
            totalExposures: 200,
            elapsedSecs: 6,
            estimatedRemainingSecs: 318,
          ),
        ),
      ),
    );

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
    expect(find.byKey(TourTarget.sequencerTabBuilder.key), findsOneWidget);

    // The dominant region: the sequence tree.
    expect(find.byType(SequenceTree), findsOneWidget);

    // Add-node affordance is reachable.
    expect(find.byType(FloatingActionButton), findsWidgets);
  }

  for (final (label, portrait) in phones) {
    final landscape = Size(portrait.height, portrait.width);

    testWidgets('$label landscape, running: one progress bar, no overflow',
        (tester) async {
      await pumpAppScreen(
        tester,
        const SequencerScreen(),
        size: landscape,
        extraOverrides: [..._overrides(), _running()],
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      expect(find.byType(SequenceProgressBar), findsOneWidget);
    });

    testWidgets('$label portrait, running: one progress bar, no overflow',
        (tester) async {
      await pumpAppScreen(
        tester,
        const SequencerScreen(),
        size: portrait,
        extraOverrides: [
          ..._overrides(),
          _running(),
        ],
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 600));
      // The screen's bar only: the phone builder once mounted a second one
      // under the same key, and the wide row overflowed a phone.
      expect(tester.takeException(), isNull);
      expect(find.byType(SequenceProgressBar), findsOneWidget);
    });

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
        ledgerClockProvider.overrideWith(
          (ref) => const Stream<DateTime>.empty(),
        ),
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

  testWidgets('desktop width, running: the wide bar lays out', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: const Size(1280, 800),
      extraOverrides: [..._overrides(), _running()],
      settle: false,
      // The desktop layout's providers run periodic timers; the container is
      // disposed in the body, before the binding checks for them.
      registerTearDown: false,
    );
    addTearDown(handle.database.close);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    expect(find.byType(SequenceProgressBar), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 10));
    handle.container.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  // A phone on its side, running, with no plan yet: under the header, the
  // run's wide band, the toolbar and the status strip the plan kept 196 of
  // the window's 390 px. In a desktop window that size the window frame and
  // the bottom bar take another 109, which left the plan about 87 px.
  Future<double> planHeight(WidgetTester tester, Size size) async {
    await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: size,
      extraOverrides: [
        ..._overrides(),
        currentSequenceProvider.overrideWith((_) => CurrentSequenceNotifier()),
        _running(),
      ],
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    expect(find.byType(SequenceProgressBar), findsOneWidget);
    return tester.getRect(find.byType(SequenceTree)).height;
  }

  testWidgets('844x390 running: the plan keeps usable height', (tester) async {
    expect(await planHeight(tester, const Size(844, 390)),
        greaterThanOrEqualTo(230));
  });
}
