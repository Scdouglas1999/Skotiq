// Every "jump to this node" in the builder must scroll the TREE and nothing
// else.
//
// They all used `Scrollable.ensureVisible`, which walks EVERY ancestor
// Scrollable and scrolls each one. The builder lives inside the sequencer
// screen's TabBarView pager, so each jump also asked the pager to reveal the
// row: the whole screen lurched toward the next (lazily empty) page and the
// page physics sprang it back. The run's auto-follow does this on every step.
//
// The assertions run per FRAME. The defect was a bounce that settled back to
// the right answer, so a settled-state check passed while the operator watched
// the screen lurch.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_properties_panel.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_step_finder.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_app/screens/sequencer/widgets/target_queue_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

/// Wide enough for the full three-column builder, short enough that a 20-row
/// tree overflows its viewport — a tree with nothing to scroll cannot show
/// whether a reveal scrolled the right thing.
const Size _desktopWindow = Size(1400, 700);

/// Frames sampled after each trigger: covers the 300ms reveal and the pager's
/// own spring with room to spare.
const int _framesWatched = 40;
const Duration _frame = Duration(milliseconds: 16);

/// Root -> "M 42" -> "Broadband" -> 20 subs. Every sub is a different length
/// because exposures sharing a capture spec fold into ONE run row, and a folded
/// tree does not overflow.
({Sequence sequence, String targetId, String lastExposureId}) _tallSequence() {
  final target = TargetHeaderNode(
    name: 'M 42',
    targetName: 'Orion',
    raHours: 5.5,
    decDegrees: -5.4,
  );
  final loop = LoopNode(
    name: 'Broadband',
    conditionType: LoopConditionType.count,
    repeatCount: 1,
  );
  final root = InstructionSetNode(name: 'Root');
  final exposures = <ExposureNode>[
    for (var i = 0; i < 20; i++)
      ExposureNode(name: 'Sub $i', durationSecs: 60.0 + i, count: 1)
          .copyWith(parentId: loop.id, orderIndex: i),
  ];
  return (
    sequence: Sequence.create(
      name: 'Reveal',
      rootNodeId: root.id,
      nodes: {
        for (final exposure in exposures) exposure.id: exposure,
        loop.id: loop.copyWith(
          parentId: target.id,
          orderIndex: 0,
          childIds: [for (final exposure in exposures) exposure.id],
        ),
        target.id: target.copyWith(
          parentId: root.id,
          orderIndex: 0,
          childIds: [loop.id],
        ),
        root.id: root.copyWith(childIds: [target.id]),
      },
    ),
    targetId: target.id,
    lastExposureId: exposures.last.id,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<HarnessHandle> pumpBuilder(WidgetTester tester, Sequence sequence) =>
      pumpAppScreen(
        tester,
        const SequencerScreen(),
        size: _desktopWindow,
        settle: false,
        extraOverrides: [
          currentSequenceProvider.overrideWith((_) {
            final notifier = CurrentSequenceNotifier();
            // ignore: invalid_use_of_protected_member
            notifier.state = sequence;
            return notifier;
          }),
          sequenceExecutionStateProvider
              .overrideWith((ref) => SequenceExecutionState.idle),
          // The ledger ETA clock is a real periodic stream; in the fake-async
          // zone its timer outlives every pump and fails teardown.
          ledgerClockProvider
              .overrideWith((ref) => const Stream<DateTime>.empty()),
          // The Targets panel's 30s sky tick is a real aligned timer that
          // outlives every pump in the fake-async zone.
          tickerProvider(TickerCadence.thirtySeconds).overrideWith(
              (ref) => Stream.value(DateTime.utc(2024, 6, 15, 22))),
        ],
      );

  // Live validation debounces 500ms and the reveal animations run 300ms; drain
  // by hand rather than pumpAndSettle, which the ledger clock would spin on.
  Future<void> drain(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  /// The tree's own vertical scroll view — the ONE thing a reveal may move.
  ScrollPosition treePosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(SequenceTree),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;

  /// The screen's Builder/Templates/Saved/History pager. Its offset is what the
  /// operator saw move.
  ScrollPosition pagerPosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(TabBarView),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;

  /// Run [trigger] and assert that on EVERY frame of the transition the tree's
  /// box, the inspector's box and the pager's offset are exactly where they
  /// were — then that the tree really did scroll, so the case proves the reveal
  /// happened at all.
  Future<void> expectRevealMovesOnlyTheTree(
    WidgetTester tester,
    Future<void> Function() trigger,
  ) async {
    final treeRect = tester.getRect(find.byType(SequenceTree));
    final panelRect = tester.getRect(find.byType(NodePropertiesPanel));
    final pagerOffset = pagerPosition(tester).pixels;
    final treeOffsetBefore = treePosition(tester).pixels;

    await trigger();
    for (var frame = 0; frame < _framesWatched; frame++) {
      await tester.pump(_frame);
      expect(
        tester.getRect(find.byType(SequenceTree)),
        treeRect,
        reason: 'the tree moved on frame $frame',
      );
      expect(
        tester.getRect(find.byType(NodePropertiesPanel)),
        panelRect,
        reason: 'the inspector moved or resized on frame $frame',
      );
      expect(
        pagerPosition(tester).pixels,
        pagerOffset,
        reason: 'the screen pager scrolled on frame $frame',
      );
    }
    await drain(tester);

    expect(
      treePosition(tester).pixels,
      isNot(closeTo(treeOffsetBefore, 0.5)),
      reason: 'the tree did not scroll, so this case proves nothing',
    );
  }

  testWidgets('the run auto-follow scrolls the tree, not the pager',
      (tester) async {
    final seed = _tallSequence();
    final handle = await pumpBuilder(tester, seed.sequence);
    await drain(tester);

    await expectRevealMovesOnlyTheTree(tester, () async {
      handle.container
          .read(sequenceProgressProvider.notifier)
          .updateProgress(currentNodeId: seed.lastExposureId);
    });
  });

  testWidgets('tapping a pinned ancestor scrolls the tree, not the pager',
      (tester) async {
    final seed = _tallSequence();
    await pumpBuilder(tester, seed.sequence);
    await drain(tester);

    treePosition(tester).jumpTo(400);
    await drain(tester);
    expect(
      find.byKey(sequenceStickyAncestorsKey),
      findsOneWidget,
      reason: 'the tree has to be scrolled far enough to pin an ancestor',
    );

    await expectRevealMovesOnlyTheTree(
      tester,
      () => tester.tap(
        find.descendant(
          of: find.byKey(sequenceStickyAncestorsKey),
          matching: find.text('M 42'),
        ),
        // The pinned row sits behind an IgnorePointer; the tap belongs to the
        // stack around it.
        warnIfMissed: false,
      ),
    );
  });

  testWidgets('the gutter jump scrolls the tree, not the pager',
      (tester) async {
    final seed = _tallSequence();
    await pumpBuilder(tester, seed.sequence);
    await drain(tester);

    treePosition(tester).jumpTo(treePosition(tester).maxScrollExtent);
    await drain(tester);

    // Tap near the top of the gutter: it stands for the first rows, which are
    // now off the top of the viewport.
    final gutter = tester.getRect(find.byKey(sequenceGutterMapKey));
    await expectRevealMovesOnlyTheTree(
      tester,
      () => tester.tapAt(Offset(gutter.center.dx, gutter.top + 6)),
    );
  });

  testWidgets('Find a step scrolls the tree, not the pager', (tester) async {
    final seed = _tallSequence();
    await pumpBuilder(tester, seed.sequence);
    await drain(tester);

    openStepFinder(tester);
    await drain(tester);
    // Narrow to one match: the finder's result list scrolls, and an unfiltered
    // list leaves the wanted row below its own fold.
    await tester.enterText(
      find.descendant(
          of: find.byType(Dialog), matching: find.byType(TextField)),
      'Sub 19',
    );
    await drain(tester);

    await expectRevealMovesOnlyTheTree(
      tester,
      // `.last`: the query text also lives in the dialog's own field, which
      // `find.text` matches through its EditableText.
      () => tester.tap(
        find
            .descendant(of: find.byType(Dialog), matching: find.text('Sub 19'))
            .last,
      ),
    );
  });

  testWidgets('an "In this sequence" target scrolls the tree, not the pager',
      (tester) async {
    final seed = _tallSequence();
    final handle = await pumpBuilder(tester, seed.sequence);
    await drain(tester);

    handle.container.read(sequencerToolboxTabProvider.notifier).state =
        SequencerToolboxTab.targets;
    await drain(tester);

    treePosition(tester).jumpTo(treePosition(tester).maxScrollExtent);
    await drain(tester);

    await expectRevealMovesOnlyTheTree(
      tester,
      () => tester.tap(
        find.descendant(
          of: find.byType(TargetQueuePanel),
          matching: find.text('Orion'),
        ),
      ),
    );
  });
}

/// Open the step finder against the live screen, the way the canvas bar's
/// overflow item does. Its future completes when the dialog is popped, which is
/// after the test's own assertions, so it is deliberately not awaited.
void openStepFinder(WidgetTester tester) {
  showSequenceStepFinder(tester.element(find.byType(SequenceTree)));
}
