// "Build sequence" on a second target, in a plan shaped like a night (cool,
// unpark, target, warm, park, darks), moved every one of the night's own
// steps inside the new target, ahead of its slew: the run would have imaged
// the first target, cooled, unparked, warmed, parked and taken darks, and only
// then slewed to the second. The new target goes after the last target and
// adopts nothing.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';

Sequence _night() {
  ExposureNode step(String id, String name) => ExposureNode(
    id: id,
    name: name,
    parentId: 'root',
    durationSecs: 1,
    count: 1,
  );
  final target = TargetHeaderNode(
    id: 'ngc1313',
    name: 'NGC 1313',
    targetName: 'NGC 1313',
    raHours: 3.3,
    decDegrees: -66.5,
    parentId: 'root',
    childIds: const ['lights'],
  );
  final lights = ExposureNode(
    id: 'lights',
    parentId: 'ngc1313',
    durationSecs: 120,
    count: 30,
  );
  return Sequence.create(
    name: 'Night',
    rootNodeId: 'root',
    nodes: {
      'root': InstructionSetNode(
        id: 'root',
        name: 'Night',
        childIds: const ['cool', 'unpark', 'ngc1313', 'warm', 'park', 'darks'],
      ),
      'cool': step('cool', 'Cool'),
      'unpark': step('unpark', 'Unpark'),
      'ngc1313': target,
      'lights': lights,
      'warm': step('warm', 'Warm'),
      'park': step('park', 'Park'),
      'darks': step('darks', 'Darks'),
    },
  );
}

void main() {
  test('a second target goes after the first and adopts nothing', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(currentSequenceProvider.notifier)
      ..loadSequence(_night());

    notifier.addTargetHeader(
      TargetHeaderNode(
        id: 'ngc3132',
        name: 'NGC 3132',
        targetName: 'NGC 3132',
        raHours: 10.1,
        decDegrees: -40.4,
      ),
    );

    final sequence = container.read(currentSequenceProvider)!;
    expect(sequence.nodes['root']!.childIds, [
      'cool',
      'unpark',
      'ngc1313',
      'ngc3132',
      'warm',
      'park',
      'darks',
    ]);
    expect(sequence.nodes['ngc3132']!.childIds, isEmpty);
    expect(sequence.nodes['ngc3132']!.parentId, 'root');
    expect(sequence.nodes['warm']!.parentId, 'root');
    expect(
      [
        for (final id in sequence.nodes['root']!.childIds)
          sequence.nodes[id]!.orderIndex,
      ],
      [0, 1, 2, 3, 4, 5, 6],
    );
  });

  test('merging a target from a whole generated plan adds no orphans', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(currentSequenceProvider.notifier)
      ..loadSequence(_night());

    // A generated plan: its own root, the target, and its own warm step.
    final template = <String, SequenceNode>{
      'troot': InstructionSetNode(
        id: 'troot',
        name: 'Plan',
        childIds: const ['thead', 'twarm'],
      ),
      'thead': TargetHeaderNode(
        id: 'thead',
        name: 'NGC 3132',
        targetName: 'NGC 3132',
        raHours: 10.1,
        decDegrees: -40.4,
        parentId: 'troot',
        childIds: const ['tlights'],
      ),
      'tlights': ExposureNode(
        id: 'tlights',
        parentId: 'thead',
        durationSecs: 30,
        count: 10,
      ),
      'twarm': ExposureNode(
        id: 'twarm',
        name: 'Template warm',
        parentId: 'troot',
        durationSecs: 1,
        count: 1,
      ),
    };
    notifier.withUndoGroup(() {
      notifier.addTargetHeader(
        TargetHeaderNode(
          id: 'ngc3132',
          name: 'NGC 3132',
          targetName: 'NGC 3132',
          raHours: 10.1,
          decDegrees: -40.4,
        ),
      );
      notifier.mergeTemplateNodes(
        templateNodes: template,
        templateRootId: 'thead',
        targetId: 'ngc3132',
      );
    });

    final sequence = container.read(currentSequenceProvider)!;
    final reachable = <String>{};
    void walk(String id) {
      reachable.add(id);
      sequence.nodes[id]!.childIds.forEach(walk);
    }

    walk(sequence.rootNodeId!);
    expect(
      sequence.nodes.keys.toSet(),
      reachable,
      reason: 'every node in the plan is reachable from its root',
    );
    expect(sequence.nodes['ngc3132']!.childIds, hasLength(1));

    // One undo takes the whole target back out.
    notifier.undo();
    expect(container.read(currentSequenceProvider)!.nodes['root']!.childIds, [
      'cool',
      'unpark',
      'ngc1313',
      'warm',
      'park',
      'darks',
    ]);
  });
}
