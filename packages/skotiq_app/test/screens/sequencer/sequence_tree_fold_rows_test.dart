// Run-length folding in the tree (spec §6): the rendering, selection, drag,
// delete and keyboard halves of the model that `sequence_fold_model_test.dart`
// already covers in isolation.
//
// Everything here drives the real tree — real gestures, the real drop targets,
// the real undo stack — because the point of the feature is that a folded row
// behaves like a row: it selects, it drags, it deletes, and the keyboard walks
// past it in one step.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequence_fold_model.dart';
import 'package:skotiq_app/screens/sequencer/sequence_fold_state.dart';
import 'package:skotiq_app/screens/sequencer/widgets/batch_operations_toolbar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/ledger_seconds.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree_shortcuts.dart';
import 'package:skotiq_app/screens/sequencer/widgets/visual_timeline.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequencer_density.dart';
import 'package:skotiq_app/widgets/tutorial_keys/tutorial_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../../harness/pump_app_screen.dart';

/// Test-only bridge so one test can flip the tree's density without rebuilding
/// the ProviderScope.
final _testDensityProvider =
    StateProvider<SequencerDensity>((ref) => SequencerDensity.ledger);

/// Root → `Alpha` (Settle, Ha, OIII, SII) + `Beta` (Warm up).
///
/// The three exposures share every capture field but the filter, so they are
/// one run; `Settle` above them and `Beta` beside them give the drop zones and
/// the arrow-key neighbours something real to land on.
({
  Sequence sequence,
  String alphaId,
  String betaId,
  String settleId,
  String warmUpId,
  List<String> exposureIds,
}) _runInAlpha({int count = 12}) {
  ExposureNode sub(String filter) => ExposureNode(
        name: '$filter subs',
        filter: filter,
        durationSecs: 300,
        count: count,
        ditherEvery: 0,
      );

  final settle = DelayNode(name: 'Settle', seconds: 5);
  final ha = sub('Ha');
  final oiii = sub('OIII');
  final sii = sub('SII');
  final warmUp = DelayNode(name: 'Warm up', seconds: 30);
  final alpha = InstructionSetNode(name: 'Alpha');
  final beta = InstructionSetNode(name: 'Beta');
  final root = InstructionSetNode(name: 'Root');

  return (
    sequence: Sequence.create(
      name: 'T',
      rootNodeId: root.id,
      nodes: {
        settle.id: settle.copyWith(parentId: alpha.id, orderIndex: 0),
        ha.id: ha.copyWith(parentId: alpha.id, orderIndex: 1),
        oiii.id: oiii.copyWith(parentId: alpha.id, orderIndex: 2),
        sii.id: sii.copyWith(parentId: alpha.id, orderIndex: 3),
        warmUp.id: warmUp.copyWith(parentId: beta.id, orderIndex: 0),
        alpha.id: alpha.copyWith(
          parentId: root.id,
          orderIndex: 0,
          childIds: [settle.id, ha.id, oiii.id, sii.id],
        ),
        beta.id: beta.copyWith(
          parentId: root.id,
          orderIndex: 1,
          childIds: [warmUp.id],
        ),
        root.id: root.copyWith(childIds: [alpha.id, beta.id]),
      },
    ),
    alphaId: alpha.id,
    betaId: beta.id,
    settleId: settle.id,
    warmUpId: warmUp.id,
    exposureIds: [ha.id, oiii.id, sii.id],
  );
}

/// The id the fold model gives the run under [parentId]. Read from the model
/// rather than hard-coded: the id is a hash of the member ids, which are
/// fresh UUIDs in every test.
String _groupIdUnder(Sequence sequence, String parentId) {
  final entries =
      foldChildren(sequence, parentId, unfoldedGroupIds: const <String>{});
  return entries.whereType<FoldedEntry>().single.group.id;
}

Future<HarnessHandle> _pumpTree(
  WidgetTester tester,
  Sequence sequence, {
  Size size = const Size(1200, 900),
  ThemeData? theme,
  SequenceProgressNotifier? progressNotifier,
  PreSessionSimulationResult? simulation,
}) async {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = sequence;

  final handle = await pumpAppScreen(
    tester,
    Builder(
      builder: (context) => Column(
        children: [
          BatchOperationsToolbar(colors: SkotiqColors.of(context)),
          Expanded(
            child: SequenceTree(colors: SkotiqColors.of(context)),
          ),
        ],
      ),
    ),
    size: size,
    theme: theme,
    // Live validation debounces 500 ms; drain frames manually instead.
    settle: false,
    extraOverrides: [
      currentSequenceProvider.overrideWith((_) => notifier),
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.idle),
      // The minute clock is a real periodic stream; in the fake-async zone its
      // timer outlives every pump and fails teardown.
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

/// The 28 px row box: the innermost height-only SizedBox above a row's text.
Finder _rowShellOf(Finder nameText) => find.ancestor(
      of: nameText,
      matching: find.byWidgetPredicate(
        (w) => w is SizedBox && w.height == 28.0 && w.width == null,
      ),
    );

/// A plain riverpod container for the provider-level cases (visible order and
/// the arrow-key actions), with no widget tree to focus.
ProviderContainer _container(Sequence sequence) {
  final container = ProviderContainer(overrides: [
    inMemoryDatabaseOverride(),
    currentSequenceProvider.overrideWith((ref) {
      final n = CurrentSequenceNotifier();
      // ignore: invalid_use_of_protected_member
      n.state = sequence;
      return n;
    }),
  ]);
  addTearDown(container.dispose);
  return container;
}

class _ProbeWidget extends ConsumerWidget {
  const _ProbeWidget({required this.onRef});
  final void Function(WidgetRef ref) onRef;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onRef(ref);
    return const SizedBox.shrink();
  }
}

Future<Map<Type, Action<Intent>>> _grabActions(
  WidgetTester tester,
  ProviderContainer container,
) async {
  late Map<Type, Action<Intent>> actions;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: _ProbeWidget(
          onRef: (ref) => actions = buildSequenceTreeActions(ref),
        ),
      ),
    ),
  );
  return actions;
}

void _dispatch(Map<Type, Action<Intent>> actions, Intent intent) {
  // ignore: invalid_use_of_protected_member
  actions[intent.runtimeType]!.invoke(intent);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('three matching exposures render as one folded row',
      (tester) async {
    final built = _runInAlpha();
    await _pumpTree(tester, built.sequence);

    // One row for the run, named by its filters and chipped with the spec the
    // three share.
    expect(find.text('Ha · OIII · SII'), findsOneWidget);
    expect(find.text('300 s ×12 each'), findsOneWidget);
    expect(_rowShellOf(find.text('Ha · OIII · SII')), findsOneWidget);
    expect(
      tester.getSize(_rowShellOf(find.text('Ha · OIII · SII')).first).height,
      28.0,
    );

    // The members themselves are gone from the tree.
    expect(find.text('Ha subs'), findsNothing);
    expect(find.text('OIII subs'), findsNothing);
    expect(find.text('SII subs'), findsNothing);
    // The neighbour row is untouched.
    expect(find.text('Settle'), findsOneWidget);

    // Columns: the shared sub length, and 3 members × 12 frames.
    expect(find.text('300s'), findsOneWidget);
    expect(find.text('36'), findsWidgets);
    await _drainValidationDebounce(tester);
  });

  testWidgets('the chevron unfolds the run into its three member rows',
      (tester) async {
    final built = _runInAlpha();
    final handle = await _pumpTree(tester, built.sequence);
    final groupId = _groupIdUnder(built.sequence, built.alphaId);

    final chevron = find.descendant(
      of: _rowShellOf(find.text('Ha · OIII · SII')).first,
      matching: find.bySemanticsLabel('Expand run'),
    );
    await tester.tap(chevron);
    await tester.pumpAndSettle();

    expect(handle.container.read(unfoldedGroupIdsProvider), contains(groupId));
    expect(find.text('Ha · OIII · SII'), findsNothing);
    expect(find.text('Ha subs'), findsOneWidget);
    expect(find.text('OIII subs'), findsOneWidget);
    expect(find.text('SII subs'), findsOneWidget);
    // Three sibling rows of one type is the shape that used to collide on a
    // static tutorial GlobalKey.
    expect(tester.takeException(), isNull);
    await _drainValidationDebounce(tester);
  });

  testWidgets('a top-level run carries the capture tutorial anchor it hides',
      (tester) async {
    // The coach marks point at the first depth-1 capture node. When a fold
    // hides that node its row is gone, so the folded row has to take the
    // anchor — and exactly one widget may hold it.
    final ha = ExposureNode(
        name: 'Ha subs', filter: 'Ha', durationSecs: 300, count: 12);
    final oiii = ExposureNode(
        name: 'OIII subs', filter: 'OIII', durationSecs: 300, count: 12);
    final root = InstructionSetNode(name: 'Root');
    final sequence = Sequence.create(
      name: 'T',
      rootNodeId: root.id,
      nodes: {
        ha.id: ha.copyWith(parentId: root.id, orderIndex: 0),
        oiii.id: oiii.copyWith(parentId: root.id, orderIndex: 1),
        root.id: root.copyWith(childIds: [ha.id, oiii.id]),
      },
    );
    final handle = await _pumpTree(tester, sequence);

    expect(find.text('Ha · OIII'), findsOneWidget);
    expect(find.byKey(SequencerTutorialKeys.captureNode), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Unfolding hands the anchor back to the first member's own row — still
    // exactly one holder.
    handle.container
        .read(unfoldedGroupIdsProvider.notifier)
        .unfold(_groupIdUnder(sequence, root.id));
    await tester.pumpAndSettle();
    expect(find.byKey(SequencerTutorialKeys.captureNode), findsOneWidget);
    expect(find.text('Ha subs'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _drainValidationDebounce(tester);
  });

  testWidgets('leaving Ledger hands the run back to its member rows',
      (tester) async {
    // The folded row holds the first member's scroll GlobalKey while it is
    // drawn. Switching density unmounts it and mounts that member's own row in
    // the same frame — the key has to move, not collide.
    final built = _runInAlpha();
    final handle = await _pumpTree(tester, built.sequence);
    expect(find.text('Ha · OIII · SII'), findsOneWidget);

    handle.container.read(_testDensityProvider.notifier).state =
        SequencerDensity.comfortable;
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Ha · OIII · SII'), findsNothing);
    expect(find.text('Ha subs'), findsOneWidget);
    expect(find.text('OIII subs'), findsOneWidget);
    expect(find.text('SII subs'), findsOneWidget);
    await _drainValidationDebounce(tester);
  });

  testWidgets('the acquire quartet folds into one Acquire target row',
      (tester) async {
    final slew = SlewNode(name: 'Slew to target');
    final center = CenterNode(name: 'Center');
    final guide = StartGuidingNode(name: 'Start guiding');
    final focus = AutofocusNode(name: 'Autofocus');
    final root = InstructionSetNode(name: 'Root');
    final sequence = Sequence.create(
      name: 'T',
      rootNodeId: root.id,
      nodes: {
        slew.id: slew.copyWith(parentId: root.id, orderIndex: 0),
        center.id: center.copyWith(parentId: root.id, orderIndex: 1),
        guide.id: guide.copyWith(parentId: root.id, orderIndex: 2),
        focus.id: focus.copyWith(parentId: root.id, orderIndex: 3),
        root.id:
            root.copyWith(childIds: [slew.id, center.id, guide.id, focus.id]),
      },
    );
    await _pumpTree(tester, sequence);

    expect(find.text('Acquire target'), findsOneWidget);
    expect(find.text('slew · center · guide · AF'), findsOneWidget);
    expect(find.text('Slew to target'), findsNothing);
    // An acquire run has no shared capture spec, so those two columns stay
    // blank rather than inventing a number.
    expect(find.text('300s'), findsNothing);
    await _drainValidationDebounce(tester);
  });

  testWidgets(
      'tapping the folded row selects every member and the batch bar '
      'counts them', (tester) async {
    final built = _runInAlpha();
    final handle = await _pumpTree(tester, built.sequence);

    await tester.tap(find.text('Ha · OIII · SII'));
    await tester.pump();

    expect(
      handle.container.read(multiSelectedNodeIdsProvider),
      unorderedEquals(built.exposureIds),
    );
    // The inspector points at a real node — the run's first member.
    expect(
      handle.container.read(selectedNodeIdProvider),
      built.exposureIds.first,
    );
    expect(find.text('3 selected'), findsOneWidget);
    await _drainValidationDebounce(tester);
  });

  testWidgets('ctrl-tap toggles the whole run in and out of the selection',
      (tester) async {
    final built = _runInAlpha();
    final handle = await _pumpTree(tester, built.sequence);

    // Select a neighbour first: the first ctrl-tap must fold it into the set
    // rather than leave it highlighted but uncounted.
    await tester.tap(find.text('Settle'));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('Ha · OIII · SII'));
    await tester.pump();
    expect(
      handle.container.read(multiSelectedNodeIdsProvider),
      unorderedEquals(<String>[built.settleId, ...built.exposureIds]),
    );
    expect(find.text('4 selected'), findsOneWidget);

    // Ctrl-tap again removes the run as a unit, leaving the neighbour.
    await tester.tap(find.text('Ha · OIII · SII'));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(
      handle.container.read(multiSelectedNodeIdsProvider),
      <String>{built.settleId},
    );
    await _drainValidationDebounce(tester);
  });

  testWidgets(
      'dropping the folded row into another container moves the run '
      'as one block, in one undo step', (tester) async {
    final built = _runInAlpha();
    final handle = await _pumpTree(tester, built.sequence);
    final notifier = handle.container.read(currentSequenceProvider.notifier);
    expect(notifier.undoStack, isEmpty);

    final payload = FoldDragPayload(
      groupId: _groupIdUnder(built.sequence, built.alphaId),
      memberIds: built.exposureIds,
      parentId: built.alphaId,
    );

    // Beta's inter-row zones: zone 0 sits above 'Warm up'.
    final betaChildren = find
        .ancestor(
          of: find.text('Warm up'),
          matching: find.byType(DragTarget<Object>),
        )
        .first;
    final zones = find
        .descendant(
          of: betaChildren,
          matching: find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_DropZone'),
        )
        .evaluate()
        .toList();
    expect(zones.length, 2);

    final zoneTarget = tester.widget<DragTarget<Object>>(find.descendant(
      of: find.byWidget(zones.first.widget),
      matching: find.byType(DragTarget<Object>),
    ));
    final details =
        DragTargetDetails<Object>(data: payload, offset: Offset.zero);
    expect(zoneTarget.onWillAcceptWithDetails!.call(details), isTrue);
    zoneTarget.onAcceptWithDetails!.call(details);
    await tester.pumpAndSettle();

    final moved = handle.container.read(currentSequenceProvider)!;
    expect(
      moved.nodes[built.betaId]!.childIds,
      <String>[...built.exposureIds, built.warmUpId],
      reason: 'the run lands above Warm up, contiguous and in tree order',
    );
    expect(moved.nodes[built.alphaId]!.childIds, <String>[built.settleId]);

    // One undo entry for three moveNode calls, and one Undo puts all three
    // back where they were.
    expect(notifier.undoStack.length, 1);
    notifier.undo();
    final restored = handle.container.read(currentSequenceProvider)!;
    expect(
      restored.nodes[built.alphaId]!.childIds,
      <String>[built.settleId, ...built.exposureIds],
    );
    expect(restored.nodes[built.betaId]!.childIds, <String>[built.warmUpId]);
    await _drainValidationDebounce(tester);
  });

  testWidgets('Delete on the folded row asks once and removes every member',
      (tester) async {
    // The action chips only render in the pointer branch, and
    // SkotiqTheme.dark bakes its platform at first access — the theme is
    // what has to say linux.
    final pointerTheme =
        SkotiqTheme.dark.copyWith(platform: TargetPlatform.linux);
    final built = _runInAlpha();
    final handle = await _pumpTree(tester, built.sequence, theme: pointerTheme);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('Ha · OIII · SII')));
    await tester.pump();

    await tester.tap(find.descendant(
      of: _rowShellOf(find.text('Ha · OIII · SII')).first,
      matching: find.byTooltip('Delete all'),
    ));
    await tester.pumpAndSettle();

    // One dialog for the whole run, naming what it stands for.
    expect(find.text('Delete 3 steps?'), findsOneWidget);
    await tester.tap(find.widgetWithText(SkotiqButton, 'Delete'));
    await tester.pumpAndSettle();

    final after = handle.container.read(currentSequenceProvider)!;
    for (final id in built.exposureIds) {
      expect(after.nodes.containsKey(id), isFalse);
    }
    expect(after.nodes[built.alphaId]!.childIds, <String>[built.settleId]);
    expect(find.text('Ha · OIII · SII'), findsNothing);
    await _drainValidationDebounce(tester);
  });

  testWidgets('the folded row announces its run, its columns and its size',
      (tester) async {
    final built = _runInAlpha();
    await _pumpTree(tester, built.sequence);

    final semantics = tester.getSemantics(find
        .ancestor(
          of: find.text('Ha · OIII · SII'),
          matching: find.byType(Semantics),
        )
        .first);
    expect(semantics.label, contains('Ha · OIII · SII'));
    expect(semantics.label, contains('300 s ×12 each'));
    expect(semantics.label, contains('300s'));
    expect(semantics.label, contains('36'));
    expect(semantics.label, contains('folded group of 3 steps'));
    await _drainValidationDebounce(tester);
  });

  testWidgets('the visible order lists the run once', (tester) async {
    final built = _runInAlpha();
    final container = _container(built.sequence);
    await _grabActions(tester, container);

    final order =
        container.read(visibleNodeOrderProvider).map((e) => e.id).toList();
    expect(
      order,
      <String>[
        built.alphaId,
        built.settleId,
        built.exposureIds.first,
        built.betaId,
        built.warmUpId,
      ],
      reason: 'the run stands in the order as its first member, once',
    );
  });

  testWidgets(
      'ArrowDown lands on the run, Right unfolds it, Left folds it '
      'again', (tester) async {
    final built = _runInAlpha();
    final container = _container(built.sequence);
    final actions = await _grabActions(tester, container);
    final groupId = _groupIdUnder(built.sequence, built.alphaId);

    // From the row above the run, Down lands on the run's stand-in.
    container.read(selectedNodeIdProvider.notifier).state = built.settleId;
    _dispatch(actions, const TreeMoveSelectionDownIntent());
    expect(container.read(selectedNodeIdProvider), built.exposureIds.first);

    // Right expands the run; the members join the visible order.
    _dispatch(actions, const TreeExpandFocusedIntent());
    expect(container.read(unfoldedGroupIdsProvider), contains(groupId));
    expect(
      container.read(visibleNodeOrderProvider).map((e) => e.id),
      containsAll(built.exposureIds),
    );

    // Down twice walks the members, and Left from the last one folds the run
    // and puts the selection back on the row that is still drawn.
    _dispatch(actions, const TreeMoveSelectionDownIntent());
    _dispatch(actions, const TreeMoveSelectionDownIntent());
    expect(container.read(selectedNodeIdProvider), built.exposureIds.last);

    _dispatch(actions, const TreeCollapseFocusedIntent());
    expect(container.read(unfoldedGroupIdsProvider), isEmpty);
    expect(container.read(selectedNodeIdProvider), built.exposureIds.first);
    expect(
      container.read(visibleNodeOrderProvider).map((e) => e.id),
      isNot(contains(built.exposureIds.last)),
    );
  });

  testWidgets('below the column floor nothing folds', (tester) async {
    // The canvas — not the preference — decides what is on screen: under
    // `_ledgerColumnsMinWidth` the tree falls back to compact rows and draws
    // every child. An arrow-key order still folded there would step over rows
    // the operator can plainly see.
    final built = _runInAlpha();
    final handle = await _pumpTree(
      tester,
      built.sequence,
      size: const Size(420, 900),
    );
    await _drainValidationDebounce(tester);

    expect(
      handle.container.read(canvasSequencerDensityProvider),
      SequencerDensity.compact,
    );
    expect(
      handle.container.read(visibleNodeOrderProvider).map((row) => row.id),
      containsAll(built.exposureIds),
      reason: 'the members are drawn one per row, so they are one row each to '
          'the arrow keys too',
    );
    expect(find.text('Ha · OIII · SII'), findsNothing);
  });

  testWidgets('a wide canvas publishes ledger, and the order folds again',
      (tester) async {
    final built = _runInAlpha();
    final handle = await _pumpTree(tester, built.sequence);
    await _drainValidationDebounce(tester);

    expect(
      handle.container.read(canvasSequencerDensityProvider),
      SequencerDensity.ledger,
    );
    expect(
      handle.container.read(visibleNodeOrderProvider).map((row) => row.id),
      isNot(containsAll(built.exposureIds)),
    );
  });

  testWidgets('the run\'s chip and its Filter / exp cell print one exposure',
      (tester) async {
    final built = _runInAlpha();
    await _pumpTree(tester, built.sequence);

    // The chip reads as prose and the cell is a 70 px column, so the UNIT is
    // spelled differently by design (spec §6 vs §2) — but the DIGITS come from
    // one formatter, because a row quoting `1.5 s` beside a cell saying `2s`
    // is reporting two different exposures.
    final seconds = formatLedgerSeconds(300);
    expect(find.text('$seconds s ×12 each'), findsOneWidget);
    expect(find.text('${seconds}s'), findsOneWidget);
    await _drainValidationDebounce(tester);
  });

  testWidgets('Move Down on the kebab moves the whole run past its neighbour',
      (tester) async {
    final pointerTheme =
        SkotiqTheme.dark.copyWith(platform: TargetPlatform.linux);
    final built = _runInAlpha();
    final handle = await _pumpTree(tester, built.sequence, theme: pointerTheme);

    // Put a step after the run for it to move past.
    final trailing = DelayNode(name: 'Cooldown', seconds: 10);
    handle.container
        .read(currentSequenceProvider.notifier)
        .addNode(trailing, parentId: built.alphaId);
    await tester.pump();

    await _openFoldKebab(tester);
    await tester.tap(find.text('Move Down').last);
    await tester.pumpAndSettle();

    final after = handle.container.read(currentSequenceProvider)!;
    expect(
      after.nodes[built.alphaId]!.childIds,
      <String>[built.settleId, trailing.id, ...built.exposureIds],
      reason: 'the block lands contiguous and in order on the far side',
    );
    await _drainValidationDebounce(tester);
  });

  testWidgets('Move Up on the kebab lifts the whole run above its neighbour',
      (tester) async {
    final pointerTheme =
        SkotiqTheme.dark.copyWith(platform: TargetPlatform.linux);
    final built = _runInAlpha();
    final handle = await _pumpTree(tester, built.sequence, theme: pointerTheme);

    await _openFoldKebab(tester);
    await tester.tap(find.text('Move Up').last);
    await tester.pumpAndSettle();

    expect(
      handle.container
          .read(currentSequenceProvider)!
          .nodes[built.alphaId]!
          .childIds,
      <String>[...built.exposureIds, built.settleId],
    );
    await _drainValidationDebounce(tester);
  });

  testWidgets('Duplicate all leaves the run twice, back to back',
      (tester) async {
    final pointerTheme =
        SkotiqTheme.dark.copyWith(platform: TargetPlatform.linux);
    final built = _runInAlpha();
    final handle = await _pumpTree(tester, built.sequence, theme: pointerTheme);

    await _hoverFoldRow(tester);
    await tester.tap(find.descendant(
      of: _rowShellOf(find.text('Ha · OIII · SII')).first,
      matching: find.byTooltip('Duplicate all'),
    ));
    await tester.pumpAndSettle();

    final children = handle.container
        .read(currentSequenceProvider)!
        .nodes[built.alphaId]!
        .childIds;
    expect(children, hasLength(7));
    expect(children.sublist(1, 4), built.exposureIds);
    expect(
      children.sublist(4).toSet().intersection(built.exposureIds.toSet()),
      isEmpty,
      reason: 'the copies follow the originals as a second block, not '
          'interleaved with them',
    );
    await _drainValidationDebounce(tester);
  });

  testWidgets('Disable all strikes the run out and hands back its member rows',
      (tester) async {
    final pointerTheme =
        SkotiqTheme.dark.copyWith(platform: TargetPlatform.linux);
    final built = _runInAlpha();
    final handle = await _pumpTree(tester, built.sequence, theme: pointerTheme);

    await _hoverFoldRow(tester);
    await tester.tap(find.descendant(
      of: _rowShellOf(find.text('Ha · OIII · SII')).first,
      matching: find.byTooltip('Disable all'),
    ));
    await tester.pumpAndSettle();

    final after = handle.container.read(currentSequenceProvider)!;
    for (final id in built.exposureIds) {
      expect(after.nodes[id]!.isEnabled, isFalse);
    }
    // A disabled step is not a run member, so the fold is gone and the three
    // struck-through rows are back.
    expect(find.text('Ha · OIII · SII'), findsNothing);
    expect(find.text('Ha subs'), findsOneWidget);
    await _drainValidationDebounce(tester);
  });

  testWidgets('shift-tap extends the selection through the run\'s last member',
      (tester) async {
    final built = _runInAlpha();
    final handle = await _pumpTree(tester, built.sequence);

    await tester.tap(find.text('Settle'));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('Ha · OIII · SII'));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(
      handle.container.read(multiSelectedNodeIdsProvider),
      unorderedEquals(<String>[built.settleId, ...built.exposureIds]),
      reason: 'the range covers everything the folded row draws, not just its '
          'first member',
    );
    await _drainValidationDebounce(tester);
  });

  testWidgets('a collapsed container accepts the run as one block',
      (tester) async {
    final built = _runInAlpha();
    final handle = await _pumpTree(tester, built.sequence);
    handle.container.read(collapsedNodeIdsProvider.notifier).collapse(
          built.betaId,
        );
    await tester.pump();

    final payload = FoldDragPayload(
      groupId: _groupIdUnder(built.sequence, built.alphaId),
      memberIds: built.exposureIds,
      parentId: built.alphaId,
    );
    final target = find
        .ancestor(
          of: find.text('Beta'),
          matching: find.byType(DragTarget<Object>),
        )
        .first;
    final dropTarget = tester.widget<DragTarget<Object>>(target);
    expect(
      dropTarget.onWillAcceptWithDetails!(
        DragTargetDetails<Object>(data: payload, offset: Offset.zero),
      ),
      isTrue,
    );
    dropTarget.onAcceptWithDetails!(
      DragTargetDetails<Object>(data: payload, offset: Offset.zero),
    );
    await tester.pumpAndSettle();

    final after = handle.container.read(currentSequenceProvider)!;
    expect(
      after.nodes[built.betaId]!.childIds,
      <String>[built.warmUpId, ...built.exposureIds],
      reason: 'a collapsed header is a drop destination, and the run appends '
          'into it as one contiguous block',
    );
    expect(after.nodes[built.alphaId]!.childIds, <String>[built.settleId]);
    await _drainValidationDebounce(tester);
  });

  testWidgets('the 2 px bar shows the run\'s aggregate, not one member\'s',
      (tester) async {
    final built = _runInAlpha();
    final progress = SequenceProgressNotifier();
    await _pumpTree(tester, built.sequence, progressNotifier: progress);
    final colors = SkotiqTheme.dark.extension<SkotiqColors>()!;

    // One member done, one half way, one untouched: 1.5 of 3.
    progress.updateNodeStatus(built.exposureIds[0], NodeStatus.success);
    progress.updateNodeStatus(built.exposureIds[1], NodeStatus.running);
    progress.updateNodeProgress(built.exposureIds[1], 50, '');
    await tester.pump();

    final shell = _rowShellOf(find.text('Ha · OIII · SII')).first;
    expect(
      find.descendant(
        of: shell,
        matching: find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == colors.surfaceHover,
        ),
      ),
      findsOneWidget,
      reason: 'a run in flight draws the groove behind its fill',
    );
    expect(
      find.descendant(
        of: shell,
        matching: find.byWidgetPredicate(
          (w) => w is FractionallySizedBox && w.widthFactor == 0.5,
        ),
      ),
      findsOneWidget,
    );
    await _drainValidationDebounce(tester);
  });

  testWidgets(
      'the run\'s ETA is its earliest member start, muted once it has '
      'been overtaken', (tester) async {
    final built = _runInAlpha();
    // Anchored at `now`: an idle pre-session simulation is rebased onto the
    // clock, so a fixed wall time would print as whatever today's is.
    final t0 = DateTime.now();
    final simulation = PreSessionSimulationResult(
      start: t0,
      end: t0.add(const Duration(hours: 3)),
      duration: const Duration(hours: 3),
      segments: [
        for (var i = 0; i < built.exposureIds.length; i++)
          PreSessionSimulationSegment(
            nodeId: built.exposureIds[i],
            nodeName: 'sub $i',
            nodeType: 'ExposureNode',
            start: t0.add(Duration(hours: i)),
            end: t0.add(Duration(hours: i + 1)),
            duration: const Duration(hours: 1),
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

    // The run begins when its FIRST member does, not when the last one would.
    final etaCell = find.descendant(
      of: _rowShellOf(find.text('Ha · OIII · SII')).first,
      matching: find.text(formatLedgerClock(t0)),
    );
    expect(etaCell, findsOneWidget);
    expect(
      find.descendant(
        of: _rowShellOf(find.text('Ha · OIII · SII')).first,
        matching:
            find.text(formatLedgerClock(t0.add(const Duration(hours: 2)))),
      ),
      findsNothing,
    );

    // Once the run is under way the cell is still quoting the estimator's
    // projection, so it says so rather than presenting it as fact.
    progress.updateNodeStatus(built.exposureIds.first, NodeStatus.running);
    await tester.pump();
    expect(tester.widget<Text>(etaCell).style!.color, colors.textMuted);
    await _drainValidationDebounce(tester);
  });

  testWidgets('the run\'s badge carries the worst of its members\' issues',
      (tester) async {
    final built = _runInAlpha();
    await _pumpTree(tester, built.sequence);
    // Live validation runs on a debounce; let it settle so the badge is real
    // rather than injected.
    await _drainValidationDebounce(tester);

    // Every member is missing its filter from the (empty) active profile, so
    // the run's badge stands for three issues at once — the folded row is the
    // only place they are reachable.
    final badge = find.descendant(
      of: _rowShellOf(find.text('Ha · OIII · SII')).first,
      matching: find.byType(Tooltip),
    );
    expect(badge, findsWidgets);
  });

  testWidgets('the context menu on a folded row offers the run\'s actions',
      (tester) async {
    final built = _runInAlpha();
    await _pumpTree(tester, built.sequence);

    await tester.tap(
      find.text('Ha · OIII · SII'),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    // The right-click menu must reach the same four operations as the kebab,
    // or the two surfaces on one row disagree about what it can do.
    expect(find.text('Duplicate all'), findsOneWidget);
    expect(find.text('Disable all'), findsOneWidget);
    expect(find.text('Delete 3 steps'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await _drainValidationDebounce(tester);
  });
}

/// Put the pointer over the folded row so its hover actions are live.
Future<void> _hoverFoldRow(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(find.text('Ha · OIII · SII')));
  await tester.pump();
}

/// Open the folded row's kebab, which is where Move Up / Move Down live.
Future<void> _openFoldKebab(WidgetTester tester) async {
  await _hoverFoldRow(tester);
  await tester.tap(find.descendant(
    of: _rowShellOf(find.text('Ha · OIII · SII')).first,
    matching: find.byTooltip('More Actions'),
  ));
  await tester.pumpAndSettle();
}
