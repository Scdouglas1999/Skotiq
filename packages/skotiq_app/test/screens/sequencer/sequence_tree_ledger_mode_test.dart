// Ledger-mode coverage for SequenceTree: the fixed-height row geometry, the
// four readout columns, collapsed-container rollup text, chevron-driven
// collapse, selection / multi-select / context menu, and a palette drop into a
// container — all with the tree's real gesture wiring rather than synthesized
// callbacks.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree_shortcuts.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequencer_density.dart';
import 'package:skotiq_app/screens/sequencer/widgets/visual_timeline.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

/// Test-only bridge so a single test can flip the tree between densities and
/// exercise the AnimatedSwitcher without rebuilding the ProviderScope.
final _testDensityProvider =
    StateProvider<SequencerDensity>((ref) => SequencerDensity.ledger);

/// The ledger row's own height, as the tree's private constant fixes it. Used
/// to aim a drag at the zone BELOW a named row.
const double _ledgerRowHeightForTest = 28.0;

/// Root -> TargetHeader "M 42" -> Loop "Broadband" -> exposures. The smallest
/// three-level shape that exercises the container column totals, the target's
/// ledger-row form and the collapsed rollup line.
({
  Sequence sequence,
  String loopId,
  List<String> exposureIds,
}) _threeLevelSequence(List<ExposureNode> exposures) {
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
  final placed = <ExposureNode>[
    for (var i = 0; i < exposures.length; i++)
      exposures[i].copyWith(parentId: loop.id, orderIndex: i),
  ];
  return (
    sequence: Sequence.create(
      name: 'T',
      rootNodeId: root.id,
      nodes: {
        for (final child in placed) child.id: child,
        loop.id: loop.copyWith(
          parentId: target.id,
          orderIndex: 0,
          childIds: [for (final child in placed) child.id],
        ),
        target.id: target.copyWith(
          parentId: root.id,
          orderIndex: 0,
          childIds: [loop.id],
        ),
        root.id: root.copyWith(childIds: [target.id]),
      },
    ),
    loopId: loop.id,
    exposureIds: [for (final child in placed) child.id],
  );
}

Future<HarnessHandle> _pumpTree(
  WidgetTester tester,
  Sequence sequence, {
  Size size = const Size(1200, 900),
  SequenceProgressNotifier? progressNotifier,
  PreSessionSimulationResult? simulation,
  ThemeData? theme,
}) async {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = sequence;

  final handle = await pumpAppScreen(
    tester,
    Builder(
      builder: (context) => SequenceTree(colors: SkotiqColors.of(context)),
    ),
    size: size,
    theme: theme,
    // Live validation debounces 500 ms; drain frames manually instead.
    settle: false,
    extraOverrides: [
      currentSequenceProvider.overrideWith((_) => notifier),
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.idle),
      // The minute clock is a real periodic stream; in the fake-async zone
      // its timer outlives every pump and fails teardown. ETA anchoring is
      // exercised through ledgerEtasFor's fake-clock unit tests instead.
      ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      if (progressNotifier != null)
        sequenceProgressProvider.overrideWith((_) => progressNotifier),
      if (simulation != null)
        sequenceTimelineProvider.overrideWithValue(simulation),
      sequencerDensityProvider
          .overrideWith((ref) => ref.watch(_testDensityProvider)),
    ],
  );
  await tester.pump();
  await tester.pump();
  expect(tester.takeException(), isNull);
  return handle;
}

/// Live validation runs on a 500 ms debounce; without a drain the binding
/// fails the test on a pending timer at teardown.
Future<void> _drainValidationDebounce(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
}

/// The 28 px row box is the innermost SizedBox ancestor of a row's name text
/// that pins only its height — the chevron / marker / action boxes all carry a
/// width, so this predicate singles out the row shell.
Finder _rowShellOf(Finder nameText) => find.ancestor(
      of: nameText,
      matching: find.byWidgetPredicate(
        (w) => w is SizedBox && w.height == 28.0 && w.width == null,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders ledger rows at 28 px with columns and a header',
      (tester) async {
    final built = _threeLevelSequence([
      ExposureNode(
        name: 'L subs',
        filter: 'L',
        durationSecs: 60,
        count: 10,
      ),
    ]);
    await _pumpTree(tester, built.sequence);

    // Column header appears once, above the rows.
    expect(find.text('Step'), findsOneWidget);
    expect(find.text('Filter / exp'), findsOneWidget);
    expect(find.text('Count'), findsOneWidget);
    expect(find.text('Duration'), findsOneWidget);
    expect(find.text('ETA'), findsOneWidget);

    // Row shell pins to the ledger height.
    expect(_rowShellOf(find.text('L subs')), findsOneWidget);
    final rowSize = tester.getSize(_rowShellOf(find.text('L subs')).first);
    expect(rowSize.height, 28.0);

    // Exposure columns: filter/exposure text and frame count. '10' also
    // appears on the two container rows (each totals 10 subtree frames).
    expect(find.text('L 60s'), findsOneWidget);
    expect(find.text('10'), findsNWidgets(3));

    // The target renders as a ledger row with coordinate chips, not the card.
    expect(find.text('M 42'), findsOneWidget);
    expect(find.text('05h30m'), findsOneWidget);
    expect(find.text("-05°24'"), findsOneWidget);
    await _drainValidationDebounce(tester);
  });

  testWidgets('chevron toggles collapsed state and shows the rollup summary',
      (tester) async {
    final built = _threeLevelSequence([
      ExposureNode(
        name: 'L subs',
        filter: 'L',
        durationSecs: 60,
        count: 10,
        ditherEvery: 0,
      ),
      ExposureNode(
        name: 'R subs',
        filter: 'R',
        durationSecs: 60,
        count: 10,
        ditherEvery: 0,
      ),
    ]);
    final handle = await _pumpTree(tester, built.sequence);

    // The two exposures share a capture spec, so the loop's one child row is
    // the folded run 'L · R' (spec §6) — that row is what collapsing the loop
    // has to hide.
    expect(find.text('L · R'), findsOneWidget);

    // Collapse 'Broadband' via its chevron (carries the 'Collapse' semantic).
    final setRow = _rowShellOf(find.text('Broadband')).first;
    final chevron = find.descendant(
        of: setRow, matching: find.bySemanticsLabel('Collapse'));
    await tester.tap(chevron);
    await tester.pumpAndSettle();

    expect(handle.container.read(collapsedNodeIdsProvider),
        contains(built.loopId));
    // Children are hidden and the rollup summary rides on the row.
    expect(find.text('L · R'), findsNothing);
    expect(find.text('L · R 60 s ×10 each'), findsOneWidget);

    // Expand again restores the children and drops the summary.
    final expandChevron = find.descendant(
        of: _rowShellOf(find.text('Broadband')).first,
        matching: find.bySemanticsLabel('Expand'));
    await tester.tap(expandChevron);
    await tester.pumpAndSettle();
    expect(find.text('L · R'), findsOneWidget);
    expect(find.text('L · R 60 s ×10 each'), findsNothing);
    await _drainValidationDebounce(tester);
  });

  testWidgets('selection, multi-select, and context menu still work in ledger',
      (tester) async {
    final target = TargetHeaderNode(
      name: 'M 42',
      targetName: 'Orion',
      raHours: 5.5,
      decDegrees: -5.4,
    );
    final e1 =
        ExposureNode(name: 'L subs', filter: 'L', durationSecs: 60, count: 10);
    // A different frame count, so the pair is not a run: a run folds into one
    // row (spec §6) and this test needs two rows to select and reorder
    // between.
    final e2 =
        ExposureNode(name: 'R subs', filter: 'R', durationSecs: 60, count: 6);
    final root = InstructionSetNode(name: 'Root');
    final sequence = Sequence.create(
      name: 'T',
      rootNodeId: root.id,
      nodes: {
        e1.id: e1.copyWith(parentId: target.id, orderIndex: 0),
        e2.id: e2.copyWith(parentId: target.id, orderIndex: 1),
        target.id: target.copyWith(
          parentId: root.id,
          orderIndex: 0,
          childIds: [e1.id, e2.id],
        ),
        root.id: root.copyWith(childIds: [target.id]),
      },
    );
    final handle = await _pumpTree(tester, sequence);

    await tester.tap(find.text('L subs'));
    await tester.pump();
    expect(handle.container.read(selectedNodeIdProvider), e1.id);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('R subs'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(handle.container.read(multiSelectedNodeIdsProvider),
        containsAll(<String>[e1.id, e2.id]));

    // Right-click opens the real context menu for the row. (Long-press is
    // claimed by the row's LongPressDraggable on desktop; the secondary-tap
    // branch is the desktop path.)
    await tester.tap(find.text('L subs'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Insert Above'), findsOneWidget);
    await _drainValidationDebounce(tester);
  });

  testWidgets('palette drop into an expanded container inserts the node',
      (tester) async {
    final built = _threeLevelSequence([
      ExposureNode(
        name: 'L subs',
        filter: 'L',
        durationSecs: 60,
        count: 10,
      ),
    ]);
    final handle = await _pumpTree(tester, built.sequence);

    final payload = NodePaletteItem(
      name: 'Delay',
      icon: 'timer',
      description: 'Wait',
      createNode: () => DelayNode(name: 'Dropped delay', seconds: 5),
    );

    // The innermost DragTarget enclosing a child row is the container's
    // children-area target.
    final childrenTarget = find
        .ancestor(
            of: find.text('L subs'), matching: find.byType(DragTarget<Object>))
        .first;
    final target = tester.widget<DragTarget<Object>>(childrenTarget);
    final details =
        DragTargetDetails<Object>(data: payload, offset: Offset.zero);
    expect(target.onWillAcceptWithDetails!.call(details), isTrue);
    target.onAcceptWithDetails!.call(details);
    await tester.pump();

    final updated = handle.container.read(currentSequenceProvider)!;
    final set = updated.nodes[built.loopId]!;
    expect(set.childIds.length, 2);
    expect(updated.nodes[set.childIds.last], isA<DelayNode>());
    expect(find.text('Dropped delay'), findsOneWidget);
    await _drainValidationDebounce(tester);
  });

  testWidgets('palette drop onto a collapsed header lands inside the container',
      (tester) async {
    // Two exposures so the collapsed rollup is the filter-run line — with a
    // single child the generic summary re-prints that child's name, which is
    // indistinguishable from the row still being there.
    final built = _threeLevelSequence([
      ExposureNode(
        name: 'L subs',
        filter: 'L',
        durationSecs: 60,
        count: 10,
        ditherEvery: 0,
      ),
      ExposureNode(
        name: 'R subs',
        filter: 'R',
        durationSecs: 60,
        count: 10,
        ditherEvery: 0,
      ),
    ]);
    final handle = await _pumpTree(tester, built.sequence);

    handle.container
        .read(collapsedNodeIdsProvider.notifier)
        .toggle(built.loopId);
    await tester.pumpAndSettle();
    expect(find.text('L subs'), findsNothing);
    expect(find.text('L · R 60 s ×10 each'), findsOneWidget);

    final payload = NodePaletteItem(
      name: 'Delay',
      icon: 'timer',
      description: 'Wait',
      createNode: () => DelayNode(name: 'Dropped delay', seconds: 5),
    );

    // With the container collapsed, the innermost DragTarget around its row is
    // the collapsed-header target.
    final headerTarget = find
        .ancestor(
            of: find.text('Broadband'),
            matching: find.byType(DragTarget<Object>))
        .first;
    final target = tester.widget<DragTarget<Object>>(headerTarget);
    final details =
        DragTargetDetails<Object>(data: payload, offset: Offset.zero);
    expect(target.onWillAcceptWithDetails!.call(details), isTrue);
    target.onAcceptWithDetails!.call(details);
    await tester.pump();

    final updated = handle.container.read(currentSequenceProvider)!;
    final set = updated.nodes[built.loopId]!;
    expect(set.childIds.length, 3);
    expect(updated.nodes[set.childIds.last], isA<DelayNode>());
    await _drainValidationDebounce(tester);
  });

  testWidgets('density switching hides and shows inline extras',
      (tester) async {
    final target = TargetHeaderNode(
      name: 'M 42',
      targetName: 'Orion',
      raHours: 5.5,
      decDegrees: -5.4,
    );
    final e1 = ExposureNode(
      name: 'L subs',
      filter: 'L',
      durationSecs: 60,
      count: 10,
      comment: 'seeing bad',
    );
    final root = InstructionSetNode(name: 'Root');
    final sequence = Sequence.create(
      name: 'T',
      rootNodeId: root.id,
      nodes: {
        e1.id: e1.copyWith(parentId: target.id, orderIndex: 0),
        target.id: target.copyWith(
          parentId: root.id,
          orderIndex: 0,
          childIds: [e1.id],
        ),
        root.id: root.copyWith(childIds: [target.id]),
      },
    );
    final handle = await _pumpTree(tester, sequence);

    // Ledger: no comment line, column header present.
    expect(find.text('seeing bad'), findsNothing);
    expect(find.text('Filter / exp'), findsOneWidget);

    // Compact: card rows return but inline extras stay suppressed.
    handle.container.read(_testDensityProvider.notifier).state =
        SequencerDensity.compact;
    await tester.pumpAndSettle();
    expect(find.text('seeing bad'), findsNothing);
    expect(find.text('Filter / exp'), findsNothing);

    // Comfortable: the comment line comes back. The target card animates
    // continuously (altitude chart), so settle on a fixed pump instead of
    // pumpAndSettle.
    handle.container.read(_testDensityProvider.notifier).state =
        SequencerDensity.comfortable;
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('seeing bad'), findsOneWidget);
    await _drainValidationDebounce(tester);
  });

  testWidgets('hover reveals the action chips; Delete removes the node',
      (tester) async {
    // The trio only renders in the pointer branch. SkotiqTheme.dark is a
    // static final — its platform is baked at first access — so the theme,
    // not the debug override, is what has to say linux.
    final pointerTheme =
        SkotiqTheme.dark.copyWith(platform: TargetPlatform.linux);
    final built = _threeLevelSequence([
      ExposureNode(
        name: 'L subs',
        filter: 'L',
        durationSecs: 60,
        count: 10,
      ),
    ]);
    final handle = await _pumpTree(tester, built.sequence, theme: pointerTheme);

    // Before the pointer arrives the chips are not hit-testable (the actions
    // block is opacity-0 + IgnorePointer).
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('L subs')));
    await tester.pump();

    final deleteChip = find.descendant(
      of: _rowShellOf(find.text('L subs')).first,
      matching: find.byTooltip('Delete'),
    );
    expect(deleteChip, findsOneWidget);
    await tester.tap(deleteChip);
    await tester.pumpAndSettle();

    // The shared confirm path asks before it removes (even for a leaf).
    expect(find.text('Delete "L subs"?'), findsOneWidget);
    await tester.tap(find.widgetWithText(SkotiqButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(
      handle.container
          .read(currentSequenceProvider)!
          .nodes
          .containsKey(built.exposureIds.single),
      isFalse,
    );
    await _drainValidationDebounce(tester);
  });

  testWidgets('a running row paints the progress groove under its fill',
      (tester) async {
    final exposure = ExposureNode(
      name: 'L subs',
      filter: 'L',
      durationSecs: 60,
      count: 10,
    );
    final built = _threeLevelSequence([exposure]);
    final progress = SequenceProgressNotifier();
    final handle = await _pumpTree(
      tester,
      built.sequence,
      progressNotifier: progress,
    );
    final colors = SkotiqTheme.dark.extension<SkotiqColors>()!;

    progress.updateNodeStatus(exposure.id, NodeStatus.running);
    progress.updateNodeProgress(exposure.id, 40, '');
    await tester.pump();

    // The groove is the surfaceHover track behind the fill — the fix for the
    // childless ColoredBox that laid out at 0x0.
    final groove = find.descendant(
      of: _rowShellOf(find.text('L subs')).first,
      matching: find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == colors.surfaceHover,
      ),
    );
    expect(groove, findsOneWidget);
    // And the fill inside it is 40% of the row width.
    final fill = find.descendant(
      of: _rowShellOf(find.text('L subs')).first,
      matching: find.byWidgetPredicate(
        (w) => w is FractionallySizedBox && w.widthFactor == 0.4,
      ),
    );
    expect(fill, findsOneWidget);
    expect(handle.container, isNotNull);
    await _drainValidationDebounce(tester);
  });

  testWidgets('compact mode shows the rollup summary on a collapsed container',
      (tester) async {
    final built = _threeLevelSequence([
      ExposureNode(
        name: 'L subs',
        filter: 'L',
        durationSecs: 60,
        count: 10,
        ditherEvery: 0,
      ),
      ExposureNode(
        name: 'R subs',
        filter: 'R',
        durationSecs: 60,
        count: 10,
        ditherEvery: 0,
      ),
    ]);
    final handle = await _pumpTree(tester, built.sequence);

    handle.container.read(_testDensityProvider.notifier).state =
        SequencerDensity.compact;
    await tester.pumpAndSettle();
    handle.container
        .read(collapsedNodeIdsProvider.notifier)
        .toggle(built.loopId);
    await tester.pumpAndSettle();

    // Spec §3: the collapsed line rides the title row in compact too, not
    // just in ledger.
    expect(find.text('L subs'), findsNothing);
    expect(find.text('L · R 60 s ×10 each'), findsOneWidget);
    await _drainValidationDebounce(tester);
  });

  testWidgets('a canvas below the column floor falls back to compact rows',
      (tester) async {
    final built = _threeLevelSequence([
      ExposureNode(
        name: 'L subs',
        filter: 'L',
        durationSecs: 60,
        count: 10,
      ),
    ]);
    // 530 - 2x20 padding = 490 < 500: the density preference is still ledger,
    // but the tree must not draw columns that leave the name no room.
    await _pumpTree(tester, built.sequence, size: const Size(530, 900));

    expect(find.text('Filter / exp'), findsNothing);
    expect(find.text('Step'), findsNothing);
    // The row is a compact card row, not a stripped ledger line.
    expect(find.text('L subs'), findsOneWidget);
    expect(_rowShellOf(find.text('L subs')), findsNothing);
    expect(tester.takeException(), isNull);
    await _drainValidationDebounce(tester);
  });

  testWidgets('long-press drag reorders a ledger row', (tester) async {
    final target = TargetHeaderNode(
      name: 'M 42',
      targetName: 'Orion',
      raHours: 5.5,
      decDegrees: -5.4,
    );
    final e1 =
        ExposureNode(name: 'L subs', filter: 'L', durationSecs: 60, count: 10);
    // A different frame count, so the pair is not a run: a run folds into one
    // row (spec §6) and this test needs two rows to select and reorder
    // between.
    final e2 =
        ExposureNode(name: 'R subs', filter: 'R', durationSecs: 60, count: 6);
    final root = InstructionSetNode(name: 'Root');
    final sequence = Sequence.create(
      name: 'T',
      rootNodeId: root.id,
      nodes: {
        e1.id: e1.copyWith(parentId: target.id, orderIndex: 0),
        e2.id: e2.copyWith(parentId: target.id, orderIndex: 1),
        target.id: target.copyWith(
          parentId: root.id,
          orderIndex: 0,
          childIds: [e1.id, e2.id],
        ),
        root.id: root.copyWith(childIds: [target.id]),
      },
    );
    final handle = await _pumpTree(tester, sequence);

    // LongPressDraggable's 150 ms delay only counts a STATIONARY press —
    // timedDrag starts moving inside the window and the drag never arms.
    // The start point is captured BEFORE the press: once the drag arms the
    // feedback layer draws a second "L subs" and the text finder goes
    // ambiguous.
    final start = tester.getCenter(find.text('L subs'));
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 300));
    // Arm the drag, then let the inter-row zones finish growing (spec §9)
    // before aiming: they are the drop targets, and they are zero-height until
    // a drag is in flight. The row the block has to land AFTER keeps its own
    // name — only the dragged row is duplicated in the feedback layer — so the
    // destination is read from the settled layout rather than guessed.
    await gesture.moveTo(start + const Offset(0, 8));
    await tester.pumpAndSettle();
    final below = tester.getCenter(find.text('R subs')) +
        const Offset(0, _ledgerRowHeightForTest);
    await gesture.moveTo(below);
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    final target2 =
        handle.container.read(currentSequenceProvider)!.nodes[target.id]!;
    expect(target2.childIds, <String>[e2.id, e1.id]);
    await _drainValidationDebounce(tester);
  });

  testWidgets('an inter-row drop zone accepts a palette node at its index',
      (tester) async {
    final built = _threeLevelSequence([
      ExposureNode(
        name: 'L subs',
        filter: 'L',
        durationSecs: 60,
        count: 10,
      ),
      // Different frame count so the two exposures are not a run: a run is one
      // row with one zone on each side, and this test counts the zones
      // between two rows.
      ExposureNode(
        name: 'R subs',
        filter: 'R',
        durationSecs: 60,
        count: 6,
      ),
    ]);
    final handle = await _pumpTree(tester, built.sequence);

    // The loop's children DragTarget encloses the inter-row zones; the zones
    // sit between the child rows in child order.
    final childrenTarget = find
        .ancestor(
            of: find.text('L subs'), matching: find.byType(DragTarget<Object>))
        .first;
    final zones = find
        .descendant(
          of: childrenTarget,
          matching: find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_DropZone'),
        )
        .evaluate()
        .toList();
    // zone 0 before 'L subs', zone 1 between them, zone 2 after 'R subs'.
    expect(zones.length, 3);

    final payload = NodePaletteItem(
      name: 'Delay',
      icon: 'timer',
      description: 'Wait',
      createNode: () => DelayNode(name: 'Zoned delay', seconds: 5),
    );
    final zoneTarget = tester.widget<DragTarget<Object>>(find.descendant(
      of: find.byWidget(zones[1].widget),
      matching: find.byType(DragTarget<Object>),
    ));
    final details =
        DragTargetDetails<Object>(data: payload, offset: Offset.zero);
    expect(zoneTarget.onWillAcceptWithDetails!.call(details), isTrue);
    zoneTarget.onAcceptWithDetails!.call(details);
    await tester.pump();

    final updated = handle.container.read(currentSequenceProvider)!;
    final set = updated.nodes[built.loopId]!;
    expect(set.childIds.length, 3);
    // Index 1 — between the two exposures, not appended.
    expect(updated.nodes[set.childIds[1]], isA<DelayNode>());
    await _drainValidationDebounce(tester);
  });

  testWidgets('the row semantics label carries name, columns and state',
      (tester) async {
    final built = _threeLevelSequence([
      ExposureNode(
        name: 'L subs',
        filter: 'L',
        durationSecs: 60,
        count: 10,
      ),
    ]);
    await _pumpTree(tester, built.sequence);

    // The name text itself is excluded from semantics — the row's own
    // Semantics is the next ancestor up, and it must carry what the columns
    // show.
    final semanticsFinder = find.ancestor(
      of: find.text('L subs'),
      matching: find.byType(Semantics),
    );
    final semantics = tester.getSemantics(semanticsFinder.first);
    expect(semantics.label, contains('L subs'));
    expect(semantics.label, contains('L 60s'));
    expect(semantics.label, contains('10'));
    await _drainValidationDebounce(tester);
  });

  testWidgets('a started-but-unobserved ETA renders muted', (tester) async {
    final exposure = ExposureNode(
      name: 'L subs',
      filter: 'L',
      durationSecs: 60,
      count: 10,
    );
    final built = _threeLevelSequence([exposure]);
    final t0 = DateTime.now();
    final simulation = PreSessionSimulationResult(
      start: t0,
      end: t0.add(const Duration(minutes: 10)),
      duration: const Duration(minutes: 10),
      segments: [
        PreSessionSimulationSegment(
          nodeId: exposure.id,
          nodeName: exposure.name,
          nodeType: 'ExposureNode',
          start: t0,
          end: t0.add(const Duration(minutes: 10)),
          duration: const Duration(minutes: 10),
        ),
      ],
      targetWindows: const {},
      issues: const [],
    );
    final progress = SequenceProgressNotifier();
    await _pumpTree(
      tester,
      built.sequence,
      progressNotifier: progress,
      simulation: simulation,
    );
    final colors = SkotiqTheme.dark.extension<SkotiqColors>()!;

    // The node is running but no NodeStarted event has arrived: the column
    // still quotes the prediction and must mark it as such.
    progress.updateNodeStatus(exposure.id, NodeStatus.running);
    await tester.pump();

    final etaText = tester.widget<Text>(find.descendant(
      of: _rowShellOf(find.text('L subs')).first,
      matching: find.text(formatLedgerClock(t0)),
    ));
    expect(etaText.style?.color, colors.textMuted);
    await _drainValidationDebounce(tester);
  });

  testWidgets('the Watchdog badge drops its label rather than overflow the row',
      (tester) async {
    // A meridian flip nested three deep at the narrowest canvas Ledger will
    // still take: marker, chevron, icon, three depth guides, the reserved
    // actions block, the four columns and the badge gutter leave the name and
    // the badge ~60 px between them. The labelled badge alone is wider than
    // that, so on a real trigger row it ran straight past the row's edge.
    final flip = MeridianFlipNode(name: 'Meridian flip');
    final built = _threeLevelSequence(const <ExposureNode>[]);
    final loop = built.sequence.nodes[built.loopId]!;
    final narrow = built.sequence.copyWith(nodes: {
      ...built.sequence.nodes,
      flip.id: flip.copyWith(parentId: loop.id, orderIndex: 0),
      loop.id: loop.copyWith(childIds: [flip.id]),
    });

    await _pumpTree(tester, narrow, size: const Size(582, 900));

    // Still Ledger — this is the floor, not below it.
    expect(find.text('Filter / exp'), findsOneWidget);
    expect(find.text('Meridian flip'), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: 'a RenderFlex overflow on a trigger row is a red stripe across '
          'the canvas in debug and a clipped row in release',
    );
    // The glyph and its tooltip carry the meaning; the word is what gives way.
    expect(find.text('Watchdog'), findsNothing);
    expect(find.byIcon(LucideIcons.shieldAlert), findsOneWidget);
    await _drainValidationDebounce(tester);
  });

  testWidgets('a wide row still spells the Watchdog badge out', (tester) async {
    final flip = MeridianFlipNode(name: 'Meridian flip');
    final built = _threeLevelSequence(const <ExposureNode>[]);
    final loop = built.sequence.nodes[built.loopId]!;
    final wide = built.sequence.copyWith(nodes: {
      ...built.sequence.nodes,
      flip.id: flip.copyWith(parentId: loop.id, orderIndex: 0),
      loop.id: loop.copyWith(childIds: [flip.id]),
    });

    await _pumpTree(tester, wide);

    expect(find.text('Watchdog'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _drainValidationDebounce(tester);
  });
}
