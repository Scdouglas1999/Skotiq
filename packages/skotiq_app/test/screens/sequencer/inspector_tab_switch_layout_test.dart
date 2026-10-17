// Switching the inspector's Settings / Activity / Notes tab must change ONLY
// the inspector's body.
//
// The shipped 7.x build did something else: clicking Activity made the whole
// screen jump ~29px to the left and spring back, revealing blank space on the
// right. The tab strip is an `AdaptiveTabBar`, which called
// `Scrollable.ensureVisible` to keep the selected tab on screen — and that
// helper walks EVERY ancestor `Scrollable` and scrolls each one. The sequencer
// hosts its tabs in a `TabBarView` pager, so "keep this 60px tab visible"
// scrolled the pager toward the next (lazily empty) page until its page
// physics snapped it back.
//
// The assertions therefore run per FRAME, not after `pumpAndSettle`: the
// defect was a bounce that settled back to the right answer, so a
// settled-state check passed while the operator watched the screen lurch.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_properties_panel.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

/// A desktop window wide enough for the full three-column builder (palette +
/// canvas + inspector), so the inspector is the sidebar and not a sheet.
const Size _desktopWindow = Size(1400, 900);

/// Frames sampled after a tab tap. Covers the tab strip's own 160ms scroll
/// animation and the pager's ~300ms spring with room to spare.
const int _framesWatched = 40;
const Duration _frame = Duration(milliseconds: 16);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ExposureNode exposure;

  Sequence seedSequence() {
    exposure = ExposureNode(name: 'Ha 300s', filter: 'Ha', durationSecs: 300);
    final root = InstructionSetNode(name: 'Root');
    return Sequence.create(
      name: 'Inspector layout',
      rootNodeId: root.id,
      nodes: {
        exposure.id: exposure.copyWith(parentId: root.id),
        root.id: root.copyWith(childIds: [exposure.id]),
      },
    );
  }

  List<Override> overrides() => [
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.idle),
        // The ledger ETA clock is a real periodic stream; in the fake-async
        // zone its timer outlives every pump and fails teardown.
        ledgerClockProvider
            .overrideWith((ref) => const Stream<DateTime>.empty()),
      ];

  /// The pager the whole sequencer body sits in. Its offset is the thing the
  /// operator saw move.
  ScrollableState pagerOf(WidgetTester tester) => tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(TabBarView),
              matching: find.byType(Scrollable),
            )
            .first,
      );

  Future<HarnessHandle> pumpBuilderWithSelection(WidgetTester tester) async {
    final handle = await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: _desktopWindow,
      extraOverrides: overrides(),
    );
    handle.container
        .read(currentSequenceProvider.notifier)
        .loadSequence(seedSequence(), discardUnsaved: true);
    handle.container.read(selectedNodeIdProvider.notifier).state = exposure.id;
    await tester.pumpAndSettle();
    return handle;
  }

  /// Run [switchTab] and assert nothing outside the inspector body moves on any
  /// frame of the transition.
  Future<void> expectTabSwitchMovesNothing(
    WidgetTester tester,
    Future<void> Function() switchTab,
  ) async {
    final treeBefore = tester.getRect(find.byType(SequenceTree));
    final panelBefore = tester.getRect(find.byType(NodePropertiesPanel));
    final pagerBefore = pagerOf(tester).position.pixels;

    await switchTab();
    for (var frame = 0; frame < _framesWatched; frame++) {
      await tester.pump(_frame);
      expect(
        tester.getRect(find.byType(SequenceTree)),
        treeBefore,
        reason: 'the tree moved on frame $frame of the switch',
      );
      expect(
        tester.getRect(find.byType(NodePropertiesPanel)),
        panelBefore,
        reason: 'the inspector resized on frame $frame of the switch',
      );
      expect(
        pagerOf(tester).position.pixels,
        pagerBefore,
        reason: 'the screen pager scrolled on frame $frame of the switch',
      );
    }
    await tester.pumpAndSettle();
  }

  testWidgets('tapping Activity moves neither the tree nor the inspector',
      (tester) async {
    await pumpBuilderWithSelection(tester);
    await expectTabSwitchMovesNothing(
      tester,
      () => tester.tap(find.text('Activity')),
    );

    // The tap really did switch tabs: the Settings body's Name field is gone
    // and the Activity body's empty state is up.
    expect(find.text('Name'), findsNothing);
    expect(find.textContaining('Nothing has run'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  // Notes and the return to Settings are driven through [inspectorTabProvider]
  // — the exact state the tab button writes. Under the test font every glyph is
  // a square em, so the three labels measure ~390px in a 300px column and the
  // last tab's centre lands outside the window: a `tap` there would hit nothing
  // and silently assert about a switch that never happened. Widening the window
  // does not help, the inspector column is a fixed 300.
  Future<void> selectTab(HarnessHandle handle, int index) async {
    handle.container
        .read(inspectorTabProvider.notifier)
        .update((memory) => {...memory, exposure.category: index});
    return Future<void>.value();
  }

  testWidgets('opening Notes moves neither the tree nor the inspector',
      (tester) async {
    final handle = await pumpBuilderWithSelection(tester);
    await expectTabSwitchMovesNothing(
      tester,
      () => selectTab(handle, 2),
    );

    expect(find.text('Name'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('returning to Settings moves neither the tree nor the inspector',
      (tester) async {
    final handle = await pumpBuilderWithSelection(tester);
    await expectTabSwitchMovesNothing(tester, () => selectTab(handle, 1));
    await expectTabSwitchMovesNothing(tester, () => selectTab(handle, 0));

    expect(find.text('Name'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });
}
