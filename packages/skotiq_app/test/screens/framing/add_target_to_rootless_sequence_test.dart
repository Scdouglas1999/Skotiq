// Framing -> Add to Sequence -> "Add target" could not add a target to a
// sequence that had no root node. The editor's `addTargetHeader` bailed out on
// `rootNodeId == null`, so the flow's read-back correctly refused to claim
// success — and told the user to "Open the Sequencer and add it there", which
// was the same dead end.
//
// `rootNodeId` is nullable on the model, on the `sequences` table and in the
// `.nseq.json` schema, so a library row can genuinely arrive without one. This
// drives the real flow — picker, `loadCopyForEditing`, insert, read-back — and
// pins that the target now lands, reachable from a root, with no failure toast.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/add_target_to_sequence_flow.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

const _target = FramingTarget(
  name: 'NGC 891',
  catalogId: 'NGC891',
  raHours: 2.375,
  decDegrees: 42.349,
);

/// A saved sequence whose `root_node_id` is null: real nodes, no root.
Sequence _rootlessSavedSequence() => Sequence.create(
      databaseId: 7,
      name: 'Old Plan',
      nodes: {
        'tgt-m31': TargetHeaderNode(
          id: 'tgt-m31',
          name: 'M31',
          targetName: 'M31',
          raHours: 0.712,
          decDegrees: 41.27,
          childIds: const ['exp-m31'],
        ),
        'exp-m31': ExposureNode(
          id: 'exp-m31',
          parentId: 'tgt-m31',
          durationSecs: 120,
          count: 20,
        ),
      },
    );

Future<(BuildContext, WidgetRef)> _pumpHost(
  WidgetTester tester,
  ProviderContainer container,
) async {
  late WidgetRef capturedRef;
  late BuildContext capturedContext;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Consumer(
          builder: (ctx, ref, _) {
            capturedRef = ref;
            capturedContext = ctx;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    ),
  );
  return (capturedContext, capturedRef);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a saved sequence with no root node still accepts the target',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        savedSequencesProvider
            .overrideWith((ref) async => [_rootlessSavedSequence()]),
      ],
    );
    addTearDown(container.dispose);

    final (context, ref) = await _pumpHost(tester, container);

    final future = addFramedTargetToExistingSequence(
      context: context,
      ref: ref,
      target: _target,
    );
    await tester.pumpAndSettle();

    // "Old Plan" is the default destination (nothing is open in the editor).
    expect(find.text('Old Plan'), findsOneWidget);
    await tester.tap(find.text('Add target'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Could not add'),
      findsNothing,
      reason: 'the flow used to send the user to the Sequencer, where the same '
          'insert failed the same way',
    );
    expect(await future, isTrue);

    final sequence = container.read(currentSequenceProvider)!;
    expect(sequence.name, 'Old Plan');
    final rootId = sequence.rootNodeId;
    expect(rootId, isNotNull);
    final added = sequence.nodes.values
        .whereType<TargetHeaderNode>()
        .firstWhere((t) => t.targetName == 'NGC 891');
    expect(
      added.parentId,
      rootId,
      reason: 'a header in `nodes` but under no parent is invisible in the '
          'Sequencer, which is the failure the user reported',
    );
    expect(sequence.descendantsOf(rootId!), contains(added.id));
    expect(sequence.targetHeaders.map((t) => t.targetName), ['M31', 'NGC 891']);
    expect(sequence.invariants(), isEmpty);
  });
}
