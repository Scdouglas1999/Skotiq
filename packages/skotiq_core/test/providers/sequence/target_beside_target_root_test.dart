// A Quick-Start wizard plan's root is its target. A target added in the
// Builder became a CHILD of that root target, so it ran as part of M34 and a
// Skip of M34 skipped it too, while the Builder drew it at the top level and
// Tonight counted "1 target" (qa-night N08). addTargetHeader also moved the
// wizard target's own steps into the new target.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';

Sequence _wizardPlan() {
  final target = TargetHeaderNode(
    id: 'm34',
    name: 'M34',
    targetName: 'M34',
    raHours: 2.7,
    decDegrees: 42.7,
    childIds: const ['seq'],
  );
  final steps = InstructionSetNode(
    id: 'seq',
    name: 'Sequence',
    parentId: 'm34',
    childIds: const ['exp'],
  );
  final exposure = ExposureNode(
    id: 'exp',
    parentId: 'seq',
    durationSecs: 20,
    count: 40,
  );
  return Sequence.create(
    name: 'M34 wizard',
    nodes: {'m34': target, 'seq': steps, 'exp': exposure},
    rootNodeId: 'm34',
  );
}

TargetHeaderNode _ngc1502() => TargetHeaderNode(
  id: 'ngc1502',
  name: 'NGC 1502',
  targetName: 'NGC 1502',
  raHours: 4.13,
  decDegrees: 62.3,
);

void main() {
  late ProviderContainer container;
  late CurrentSequenceNotifier notifier;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
    notifier = container.read(currentSequenceProvider.notifier);
    notifier.loadSequence(_wizardPlan());
  });

  void expectSiblings() {
    final sequence = container.read(currentSequenceProvider)!;
    final root = sequence.nodes[sequence.rootNodeId]!;
    expect(root, isA<InstructionSetNode>());
    expect(root.childIds, ['m34', 'ngc1502']);
    expect(sequence.nodes['ngc1502']!.parentId, root.id);
    expect(sequence.nodes['m34']!.childIds, [
      'seq',
    ], reason: 'M34 keeps its own steps');
    expect(sequence.nodes['m34']!.parentId, root.id);
  }

  test('the palette adds a target beside the wizard target', () {
    notifier.addNode(_ngc1502(), parentId: 'exp');
    expectSiblings();
  });

  test('Add a target adds it beside the wizard target', () {
    notifier.addTargetHeader(_ngc1502());
    expectSiblings();
  });
}
