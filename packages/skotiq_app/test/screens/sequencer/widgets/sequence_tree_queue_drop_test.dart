// sequence_tree drag-drop test for target queue.
//
// Pins that a TargetQueueDragPayload accepted by the sequence tree's
// DragTarget produces a TargetHeaderNode with the right coordinates.
// We can't reliably simulate a real LongPressDraggable gesture across
// the entire toolbox→tree boundary in widget tests (the long-press
// timing + scroll geometry is fragile), so instead we mount a tiny
// host widget that emits the payload directly into a DragTarget that
// reuses the same accept logic as `sequence_tree.dart`. This pins the
// contract: payload kinds the tree accepts → sequence mutations.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/target_queue_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// Minimal harness mirroring `_buildDragTarget` in `sequence_tree.dart`:
/// it accepts a TargetQueueDragPayload and appends the carried
/// TargetHeaderNode under the sequence root. We test against this
/// harness because the real SequenceTree pulls in dozens of providers
/// (validation, equipment, recovery, …) that aren't relevant to the
/// payload-acceptance contract under test.
class _DragTargetHost extends ConsumerWidget {
  const _DragTargetHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: DragTarget<Object>(
        onWillAcceptWithDetails: (details) =>
            details.data is TargetQueueDragPayload,
        onAcceptWithDetails: (details) {
          final data = details.data;
          if (data is TargetQueueDragPayload) {
            ref.read(currentSequenceProvider.notifier).addNode(data.node);
            ref.read(selectedNodeIdProvider.notifier).state = data.node.id;
          }
        },
        builder: (context, candidate, rejected) => Container(
          key: const ValueKey('host_drop_target'),
          width: 200,
          height: 200,
          color: candidate.isNotEmpty ? Colors.green : Colors.grey,
          child: const Center(child: Text('drop here')),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('sequence tree accepts TargetQueueDragPayload', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);

    // Seed an active sequence so addNode has somewhere to land.
    container
        .read(currentSequenceProvider.notifier)
        .createSequence(name: 'test');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: _DragTargetHost()),
      ),
    );

    // Build the payload and dispatch it directly through the DragTarget.
    final payload = TargetQueueDragPayload(
      queuedTarget: const QueuedTarget(
        id: 'q1',
        coordinates: CelestialCoordinate(ra: 5.59, dec: -5.39),
        displayName: 'Orion Nebula',
      ),
      node: TargetHeaderNode(
        name: 'Orion Nebula',
        targetName: 'Orion Nebula',
        raHours: 5.59,
        decDegrees: -5.39,
      ),
    );

    // DragTarget.onWillAcceptWithDetails + onAcceptWithDetails are
    // exercised via the public API by extracting the inner state.
    final dragTargetFinder = find.byType(DragTarget<Object>);
    expect(dragTargetFinder, findsOneWidget);

    // Use the StatefulElement to access the DragTarget's accept
    // callbacks. This mirrors what the framework does when a
    // Draggable's feedback lands on a DragTarget; gestural simulation
    // would add ~30 lines of pointer math without strengthening the
    // contract.
    final state =
        tester.state<State>(dragTargetFinder) as State<DragTarget<Object>>;
    // ignore: invalid_use_of_protected_member
    final widget = state.widget;
    final accepts = widget.onWillAcceptWithDetails!
        .call(DragTargetDetails(data: payload, offset: Offset.zero));
    expect(accepts, isTrue, reason: 'payload should be accepted by tree');

    widget.onAcceptWithDetails!
        .call(DragTargetDetails(data: payload, offset: Offset.zero));
    await tester.pump();

    final seq = container.read(currentSequenceProvider);
    expect(seq, isNotNull);
    final targets = seq!.nodes.values.whereType<TargetHeaderNode>().toList();
    expect(targets, hasLength(1));
    expect(targets.first.targetName, 'Orion Nebula');
    expect(targets.first.raHours, closeTo(5.59, 1e-6));
    expect(targets.first.decDegrees, closeTo(-5.39, 1e-6));
    expect(container.read(selectedNodeIdProvider), targets.first.id);
  });
}
