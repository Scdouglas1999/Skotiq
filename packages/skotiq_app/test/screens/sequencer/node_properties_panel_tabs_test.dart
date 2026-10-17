// Inspector tabs (spec §8): the NodePropertiesPanel gains a
// Settings / Activity / Notes tab bar shared by the desktop sidebar and the
// mobile sheet, with the selection remembered per node CATEGORY.
//
// These tests assert the observable contract — the tab strip exists for leaf
// and container nodes, the validation banner stays pinned across tab
// switches, the Activity tab shows the seeded frame count, the Notes editor
// commits to SequenceNode.comment, and tab memory is per-category — rather
// than the private widget names inside the tab bodies.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_activity_tab.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_progress_panels.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_properties_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<HarnessHandle> pumpPanel(WidgetTester tester) => pumpAppScreen(
        tester,
        const SizedBox(
          width: 340,
          height: 800,
          child: NodePropertiesPanel(colors: SkotiqColors.dark),
        ),
        size: const Size(420, 900),
      );

  void loadAndSelect(
    HarnessHandle handle,
    Sequence sequence,
    String nodeId,
  ) {
    handle.container
        .read(currentSequenceProvider.notifier)
        .loadSequence(sequence, discardUnsaved: true);
    handle.container.read(selectedNodeIdProvider.notifier).state = nodeId;
  }

  Sequence singleNodeSequence(SequenceNode node) => Sequence.create(
        name: 'Tabs test',
        rootNodeId: node.id,
        nodes: {node.id: node},
      );

  testWidgets('tabs render for an exposure node', (tester) async {
    final handle = await pumpPanel(tester);
    final node = ExposureNode(name: 'Ha 300s', filter: 'Ha', count: 12);
    loadAndSelect(handle, singleNodeSequence(node), node.id);
    await tester.pump();

    expect(find.byType(AdaptiveTabBar), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.textContaining('Notes'), findsOneWidget);
    // The Settings tab is the default body: the node editor's Name field.
    expect(find.text('Name'), findsOneWidget);
    // Drain live validation's 500ms debounce before teardown.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('tabs render for a target node', (tester) async {
    final handle = await pumpPanel(tester);
    final node = TargetHeaderNode(
      targetName: 'M42',
      raHours: 5.5,
      decDegrees: -5.4,
    );
    loadAndSelect(handle, singleNodeSequence(node), node.id);
    await tester.pump();

    expect(find.byType(AdaptiveTabBar), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.textContaining('Notes'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('switching tabs keeps the selected-node banner pinned',
      (tester) async {
    final handle = await pumpPanel(tester);
    // An unset target fires a real validation issue that names the node, so
    // the banner has something to show.
    final node = TargetHeaderNode(
      targetName: 'Unset target',
      raHours: 0,
      decDegrees: 0,
    );
    loadAndSelect(handle, singleNodeSequence(node), node.id);
    await tester.pump();
    // liveValidationProvider debounces 500 ms before issues land.
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.byType(SkotiqBanner), findsOneWidget);

    await tester.tap(find.text('Activity'), warnIfMissed: false);
    await tester.pump();
    expect(find.byType(SkotiqBanner), findsOneWidget);

    await tester.tap(find.text('Notes'), warnIfMissed: false);
    await tester.pump();
    expect(find.byType(SkotiqBanner), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'Activity tab shows the frame grid with the seeded captured '
      'count', (tester) async {
    final handle = await pumpPanel(tester);
    final node = ExposureNode(
      name: 'L 60s',
      filter: 'L',
      count: 12,
      durationSecs: 60,
    );
    loadAndSelect(handle, singleNodeSequence(node), node.id);
    await tester.pump();

    handle.container
        .read(sequenceProgressProvider.notifier)
        .updateNodeStatus(node.id, NodeStatus.running);
    handle.container
        .read(nodeExposureTallyProvider.notifier)
        .recordFrames(node.id, captured: 6, planned: 12);

    await tester.tap(find.text('Activity'), warnIfMissed: false);
    await tester.pump();

    expect(find.text('6 of 12 done · capturing 7'), findsOneWidget);
    expect(
      find.bySemanticsLabel('6 of 12 frames captured'),
      findsOneWidget,
    );
    // Total integration: 12 frames x 60s = 12m (compactTrimmed).
    expect(find.text('12m'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Notes edit commits to the node comment', (tester) async {
    final handle = await pumpPanel(tester);
    final node = ExposureNode(name: 'Ha 300s', count: 4);
    loadAndSelect(handle, singleNodeSequence(node), node.id);
    await tester.pump();

    await tester.tap(find.text('Notes'), warnIfMissed: false);
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey('node-comment-field')),
      'check flats at dawn',
    );
    // Focus loss commits: switching tabs drops the field's focus.
    await tester.tap(find.text('Settings'), warnIfMissed: false);
    await tester.pump();

    final updated =
        handle.container.read(currentSequenceProvider)!.nodes[node.id]!;
    expect(updated.comment, 'check flats at dawn');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Ctrl+Enter commits the comment from inside the field',
      (tester) async {
    final handle = await pumpPanel(tester);
    final node = ExposureNode(name: 'Ha 300s', count: 4);
    loadAndSelect(handle, singleNodeSequence(node), node.id);
    await tester.pump();

    await tester.tap(find.text('Notes'), warnIfMissed: false);
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('node-comment-field')),
      'focus is drifting',
    );

    // `onSubmitted` cannot fire on a multiline field — the keyboard commit
    // path is Ctrl+Enter.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(
      handle.container.read(currentSequenceProvider)!.nodes[node.id]!.comment,
      'focus is drifting',
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'selecting another node commits the typed note exactly once, '
      'against the node it was typed on', (tester) async {
    final handle = await pumpPanel(tester);
    final a = ExposureNode(name: 'A', count: 2);
    final b = ExposureNode(name: 'B', count: 2);
    final root = InstructionSetNode(name: 'Root');
    final sequence = Sequence.create(
      name: 'Commit attribution',
      rootNodeId: root.id,
      nodes: {
        root.id: root.copyWith(childIds: [a.id, b.id]),
        a.id: a.copyWith(parentId: root.id),
        b.id: b.copyWith(parentId: root.id),
      },
    );
    handle.container
        .read(currentSequenceProvider.notifier)
        .loadSequence(sequence, discardUnsaved: true);
    handle.container.read(selectedNodeIdProvider.notifier).state = a.id;
    await tester.pump();

    await tester.tap(find.text('Notes'), warnIfMissed: false);
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('node-comment-field')),
      'typed on A',
    );

    // Count comment writes per node from here on: the pre-review code
    // committed once via onTapOutside and then AGAIN inside didUpdateWidget
    // (a duplicate undo entry and a provider write mid-build).
    var aWrites = 0;
    var bWrites = 0;
    handle.container.listen(currentSequenceProvider, (prev, next) {
      if (prev?.nodes[a.id]?.comment != next?.nodes[a.id]?.comment) aWrites++;
      if (prev?.nodes[b.id]?.comment != next?.nodes[b.id]?.comment) bWrites++;
    });

    handle.container.read(selectedNodeIdProvider.notifier).state = b.id;
    await tester.pump();
    // Flush the deferred commit's microtask.
    await tester.pump(const Duration(milliseconds: 50));

    expect(aWrites, 1, reason: 'the note must land on A exactly once');
    expect(bWrites, 0, reason: 'B must not inherit A\'s pending text');
    expect(
      handle.container.read(currentSequenceProvider)!.nodes[a.id]!.comment,
      'typed on A',
    );
    expect(
      handle.container.read(currentSequenceProvider)!.nodes[b.id]!.comment,
      isNull,
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('unmounting the Notes tab commits the pending note',
      (tester) async {
    final handle = await pumpPanel(tester);
    final node = ExposureNode(name: 'Ha 300s', count: 4);
    loadAndSelect(handle, singleNodeSequence(node), node.id);
    await tester.pump();

    await tester.tap(find.text('Notes'), warnIfMissed: false);
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('node-comment-field')),
      'save on close',
    );

    // Deselect: the editor unmounts without ever losing focus through the
    // field's own gesture path.
    handle.container.read(selectedNodeIdProvider.notifier).state = null;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      handle.container.read(currentSequenceProvider)!.nodes[node.id]!.comment,
      'save on close',
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'Activity shows last-known values after the run clears the '
      'maps — seeded while the Settings tab was shown', (tester) async {
    final handle = await pumpPanel(tester);
    final node = ExposureNode(name: 'L 60s', count: 4, durationSecs: 60);
    loadAndSelect(handle, singleNodeSequence(node), node.id);
    await tester.pump();
    // The Settings tab is showing — nothing has opened Activity yet, but the
    // panel keeps lastKnownNodeActivityProvider alive, so it still folds.
    expect(find.text('Name'), findsOneWidget);

    final exec = handle.container.read(sequenceExecutionStateProvider.notifier);
    exec.state = SequenceExecutionState.running;
    final progress = handle.container.read(sequenceProgressProvider.notifier);
    progress.updateNodeStatus(node.id, NodeStatus.running);
    handle.container
        .read(nodeExposureTallyProvider.notifier)
        .recordFrames(node.id, captured: 4, planned: 4);
    progress.updateNodeStatus(node.id, NodeStatus.success);
    // The run ends and the per-node maps clear (reset at the next run's
    // start — the tally follows the same lifecycle).
    progress.reset();
    handle.container.read(nodeExposureTallyProvider.notifier).reset();
    exec.state = SequenceExecutionState.completed;
    await tester.pump();

    await tester.tap(find.text('Activity'), warnIfMissed: false);
    await tester.pump();

    expect(find.text('4 of 4 done'), findsOneWidget);
    expect(
      find.bySemanticsLabel('4 of 4 frames captured'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'a NEW run clears last-known activity — run #2 does not show '
      'run #1\'s finished frames', (tester) async {
    final handle = await pumpPanel(tester);
    final node = ExposureNode(name: 'L 60s', count: 4, durationSecs: 60);
    loadAndSelect(handle, singleNodeSequence(node), node.id);
    await tester.pump();

    final exec = handle.container.read(sequenceExecutionStateProvider.notifier);
    final progress = handle.container.read(sequenceProgressProvider.notifier);
    final tally = handle.container.read(nodeExposureTallyProvider.notifier);

    // Run 1: the node completes all four frames.
    exec.state = SequenceExecutionState.running;
    progress.updateNodeStatus(node.id, NodeStatus.running);
    tally.recordFrames(node.id, captured: 4, planned: 4);
    progress.updateNodeStatus(node.id, NodeStatus.success);
    exec.state = SequenceExecutionState.completed;
    await tester.pump();

    // Run 2 starts: the executor resets the progress + tally maps and the
    // execution state re-enters running from a settled state.
    progress.reset();
    tally.reset();
    exec.state = SequenceExecutionState.running;
    await tester.pump();

    await tester.tap(find.text('Activity'), warnIfMissed: false);
    await tester.pump();

    expect(
      find.text('Nothing has run for this node yet.'),
      findsOneWidget,
      reason: 'run #2 has not reached this node — run #1\'s 4/4 must be gone',
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a just-started node captions 0 done, not -1', (tester) async {
    final handle = await pumpPanel(tester);
    final node = ExposureNode(name: 'L 60s', count: 12, durationSecs: 60);
    loadAndSelect(handle, singleNodeSequence(node), node.id);
    await tester.pump();

    // Running with no tally and no parsed detail yet: the unclamped
    // `liveFrame - 1` read "-1 of 12 done" here.
    handle.container
        .read(sequenceProgressProvider.notifier)
        .updateNodeStatus(node.id, NodeStatus.running);
    await tester.pump();

    await tester.tap(find.text('Activity'), warnIfMissed: false);
    await tester.pump();

    expect(find.text('0 of 12 done'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'frame-landed pop does not fire on selection, only on a real '
      'increment', (tester) async {
    final handle = await pumpPanel(tester);
    final node = ExposureNode(name: 'L 60s', count: 12, durationSecs: 60);
    loadAndSelect(handle, singleNodeSequence(node), node.id);
    await tester.pump();

    // Six frames already captured BEFORE the tab opens: opening must not
    // pop — those frames did not "just land".
    handle.container
        .read(sequenceProgressProvider.notifier)
        .updateNodeStatus(node.id, NodeStatus.running);
    handle.container
        .read(nodeExposureTallyProvider.notifier)
        .recordFrames(node.id, captured: 6, planned: 12);
    await tester.pump();

    await tester.tap(find.text('Activity'), warnIfMissed: false);
    await tester.pump();

    expect(
      find.byType(TweenAnimationBuilder<double>),
      findsNothing,
      reason: 'a seeded captured count must not animate on selection',
    );

    // A real landing — the count increments while the tab is open — pops
    // exactly the new cell.
    handle.container
        .read(nodeExposureTallyProvider.notifier)
        .recordFrames(node.id, captured: 7, planned: 12);
    await tester.pump();

    expect(find.byType(TweenAnimationBuilder<double>), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('tab memory is per node category across selection changes',
      (tester) async {
    final handle = await pumpPanel(tester);
    final expA = ExposureNode(name: 'Exp A', count: 2);
    final expB = ExposureNode(name: 'Exp B', count: 2);
    final target = TargetHeaderNode(
      targetName: 'M31',
      raHours: 0.7,
      decDegrees: 41.3,
    );
    final loop = LoopNode(name: 'Loop', repeatCount: 3);
    final root = InstructionSetNode(name: 'Root');
    final children = [expA.id, expB.id, target.id, loop.id];
    final sequence = Sequence.create(
      name: 'Memory test',
      rootNodeId: root.id,
      nodes: {
        root.id: root.copyWith(childIds: children),
        for (final node in [expA, expB, target, loop])
          node.id: node.copyWith(parentId: root.id),
      },
    );
    handle.container
        .read(currentSequenceProvider.notifier)
        .loadSequence(sequence, discardUnsaved: true);

    void select(String id) {
      handle.container.read(selectedNodeIdProvider.notifier).state = id;
    }

    select(expA.id);
    await tester.pump();
    // Settings is the default: the editor's Name field is present.
    expect(find.text('Name'), findsOneWidget);

    await tester.tap(find.text('Activity'), warnIfMissed: false);
    await tester.pump();
    // An unrun node's Activity body is the muted empty-state sentence.
    expect(
      find.text('Nothing has run for this node yet.'),
      findsOneWidget,
    );

    // Another node of the SAME category (instruction) restores Activity.
    select(expB.id);
    await tester.pump();
    expect(
      find.text('Nothing has run for this node yet.'),
      findsOneWidget,
      reason: 'same-category selection should keep the Activity tab',
    );
    expect(find.text('Name'), findsNothing);

    // A different category (target) has its own slot: Settings.
    select(target.id);
    await tester.pump();
    expect(find.text('Name'), findsOneWidget);

    // And logic is a third slot, also defaulting to Settings.
    select(loop.id);
    await tester.pump();
    expect(find.text('Name'), findsOneWidget);

    // Back to the instruction category — its Activity choice is remembered.
    select(expB.id);
    await tester.pump();
    expect(
      find.text('Nothing has run for this node yet.'),
      findsOneWidget,
      reason: 'the instruction category should restore Activity',
    );
    await tester.pump(const Duration(seconds: 1));
  });

  group('subtreeActivityProgress', () {
    Sequence sequenceOf(
      SequenceNode root,
      Map<String, SequenceNode> descendants,
    ) =>
        Sequence.create(
          name: 'subtree test',
          rootNodeId: root.id,
          nodes: {root.id: root, ...descendants},
        );

    test('counts done frames from node statuses against the plan', () {
      final exp = ExposureNode(count: 4, durationSecs: 60);
      final target = TargetHeaderNode(
        targetName: 'M42',
        raHours: 5.5,
        decDegrees: -5.4,
        childIds: [exp.id],
      );
      final sequence = sequenceOf(target, {
        exp.id: exp.copyWith(parentId: target.id),
      });
      final stats = subtreeActivityProgress(
        sequence,
        SequenceProgress(nodeStatuses: {exp.id: NodeStatus.success}),
        const {},
        target.id,
      );

      expect(stats.plannedFrames, 4);
      expect(stats.doneFrames, 4);
      expect(stats.hasKnownCompletion, isTrue);
      expect(stats.ran, isTrue);
      expect(sequence.totalExposures, 4);
    });

    test('a running node contributes its tally as partial progress', () {
      final exp = ExposureNode(count: 10, durationSecs: 60);
      final target = TargetHeaderNode(
        targetName: 'M42',
        raHours: 5.5,
        decDegrees: -5.4,
        childIds: [exp.id],
      );
      final sequence = sequenceOf(target, {
        exp.id: exp.copyWith(parentId: target.id),
      });
      final stats = subtreeActivityProgress(
        sequence,
        SequenceProgress(nodeStatuses: {exp.id: NodeStatus.running}),
        {exp.id: const NodeExposureTally(captured: 3, planned: 10)},
        target.id,
      );
      expect(stats.plannedFrames, 10);
      expect(stats.doneFrames, 3);
      expect(stats.fraction, closeTo(0.3, 0.001));
    });

    test(
        'a count loop defers to the run-level counter when the subtree is '
        'the whole plan', () {
      final exp = ExposureNode(count: 4, durationSecs: 60);
      final loop = LoopNode(repeatCount: 10, childIds: [exp.id]);
      final sequence = sequenceOf(loop, {
        exp.id: exp.copyWith(parentId: loop.id),
      });
      // Per-node statuses cannot scale a 10-pass loop — but the loop IS the
      // whole plan, so the executor's absolute frame counter applies.
      final stats = subtreeActivityProgress(
        sequence,
        SequenceProgress(
          nodeStatuses: {exp.id: NodeStatus.running},
          completedExposures: 18,
        ),
        {exp.id: const NodeExposureTally(captured: 2, planned: 4)},
        loop.id,
      );
      expect(stats.plannedFrames, 40);
      expect(stats.doneFrames, 18);
      expect(stats.hasKnownCompletion, isTrue);
    });

    test('a repeat inside a partial plan stays completion-unknown', () {
      final inside = ExposureNode(count: 4, durationSecs: 60);
      final outside = ExposureNode(count: 4, durationSecs: 60);
      final loop = LoopNode(repeatCount: 10, childIds: [inside.id]);
      final target = TargetHeaderNode(
        targetName: 'M42',
        raHours: 5.5,
        decDegrees: -5.4,
        childIds: [loop.id],
      );
      final root = InstructionSetNode(name: 'Root');
      final sequence = Sequence.create(
        name: 'subtree test',
        rootNodeId: root.id,
        nodes: {
          root.id: root.copyWith(childIds: [target.id, outside.id]),
          target.id: target.copyWith(parentId: root.id),
          loop.id: loop.copyWith(parentId: target.id),
          inside.id: inside.copyWith(parentId: loop.id),
          outside.id: outside.copyWith(parentId: root.id),
        },
      );
      // The run's 18 frames cannot be attributed between the looped node and
      // the sibling exposure — the honest answer is "unknown".
      final stats = subtreeActivityProgress(
        sequence,
        SequenceProgress(
          nodeStatuses: {inside.id: NodeStatus.running},
          completedExposures: 18,
        ),
        const {},
        target.id,
      );
      expect(stats.plannedFrames, 40);
      expect(stats.hasKnownCompletion, isFalse);
    });
  });

  group('lastKnownNodeActivityProvider', () {
    test(
        'keeps last values through progress resets and clears on a fresh '
        'pass', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final progress = container.read(sequenceProgressProvider.notifier);

      // Read first so the notifier is alive while progress flows — the
      // inspector watches it, and a lazy read afterwards would only see the
      // post-reset empty maps.
      container.read(lastKnownNodeActivityProvider);

      progress.updateNodeStatus('n1', NodeStatus.running);
      progress.updateNodeProgress('n1', 50, 'Frame 2/4');
      progress.updateNodeStatus('n1', NodeStatus.success);
      // The success path empties the per-node maps; the snapshot must keep
      // the last true reading.
      progress.reset();

      var snapshot = container.read(lastKnownNodeActivityProvider)['n1'];
      expect(snapshot, isNotNull);
      expect(snapshot!.status, NodeStatus.success);
      expect(snapshot.detail, 'Frame 2/4');
      expect(snapshot.percent, 50);

      // A fresh pass drops the previous run's story entirely.
      progress.updateNodeStatus('n1', NodeStatus.running);
      snapshot = container.read(lastKnownNodeActivityProvider)['n1'];
      expect(snapshot!.status, NodeStatus.running);
      expect(snapshot.detail, isNull);
      expect(snapshot.percent, isNull);
    });

    test(
        'clears every snapshot when a new run enters running from a '
        'settled state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final progress = container.read(sequenceProgressProvider.notifier);
      final exec = container.read(sequenceExecutionStateProvider.notifier);
      container.read(lastKnownNodeActivityProvider);

      // Run 1 leaves a finished-node snapshot behind.
      exec.state = SequenceExecutionState.running;
      progress.updateNodeStatus('n1', NodeStatus.running);
      progress.updateNodeStatus('n1', NodeStatus.success);
      progress.reset();
      exec.state = SequenceExecutionState.completed;
      expect(
        container.read(lastKnownNodeActivityProvider)['n1'],
        isNotNull,
      );

      // Run 2 starts — completed -> running is a start-admissible
      // transition, so run 1's memory is gone with it.
      exec.state = SequenceExecutionState.running;
      expect(container.read(lastKnownNodeActivityProvider), isEmpty);

      // A RESUME (paused -> running) is not a new run and must not clear.
      progress.updateNodeStatus('n2', NodeStatus.running);
      exec.state = SequenceExecutionState.paused;
      exec.state = SequenceExecutionState.running;
      expect(
        container.read(lastKnownNodeActivityProvider)['n2']!.status,
        NodeStatus.running,
      );
    });
  });

  group('value equality (select dedupe)', () {
    test('NodeActivitySnapshot compares by value', () {
      const a = NodeActivitySnapshot(
        status: NodeStatus.success,
        percent: 50,
        detail: 'Frame 2/4',
      );
      const b = NodeActivitySnapshot(
        status: NodeStatus.success,
        percent: 50,
        detail: 'Frame 2/4',
      );
      const c = NodeActivitySnapshot(status: NodeStatus.running);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('SubtreeActivity compares by value', () {
      const a = SubtreeActivity(
        plannedFrames: 10,
        doneFrames: 3,
        plannedIntegrationSecs: 600,
        hasOpenEndedLoop: false,
        hasUnboundedRepeat: false,
        completionUnknown: false,
        ran: true,
      );
      const b = SubtreeActivity(
        plannedFrames: 10,
        doneFrames: 3,
        plannedIntegrationSecs: 600,
        hasOpenEndedLoop: false,
        hasUnboundedRepeat: false,
        completionUnknown: false,
        ran: true,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(SubtreeActivity.empty)));
    });
  });
}
