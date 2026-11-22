import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  final exposure = SmartExposureNode(id: 'exp', parentId: 'loop');
  final loop = LoopNode(id: 'loop', parentId: 'inner', childIds: ['exp']);
  final inner = TargetHeaderNode(
    id: 'inner',
    targetName: 'Inner',
    raHours: 1,
    decDegrees: 2,
    parentId: 'outer',
    childIds: ['loop'],
  );
  final outer = TargetHeaderNode(
    id: 'outer',
    targetName: 'Outer',
    raHours: 3,
    decDegrees: 4,
    parentId: 'root',
    endWhen: const TargetTrigger.altitudeBelow(30),
    childIds: ['inner'],
  );
  final root = InstructionSetNode(id: 'root', childIds: ['outer']);
  final loose = SmartExposureNode(id: 'loose', parentId: 'root');
  final sequence = Sequence.create(
    name: 'tree',
    rootNodeId: 'root',
    nodes: {
      for (final n in [exposure, loop, inner, outer, root, loose]) n.id: n,
    },
  );

  test('the nearest target above a node, by parent links', () {
    expect(sequence.enclosingTarget('exp')?.id, 'inner');
    expect(sequence.enclosingTarget('inner')?.id, 'outer');
    expect(sequence.enclosingTarget('loose'), isNull);
    expect(sequence.enclosingTarget('missing'), isNull);
  });

  test('any target above with an end condition bounds the node', () {
    expect(sequence.isBoundedByTargetWindow('exp'), isTrue);
    expect(sequence.isBoundedByTargetWindow('loose'), isFalse);
  });

  test('a parent cycle ends the walk', () {
    final a = LoopNode(id: 'a', parentId: 'b');
    final b = LoopNode(id: 'b', parentId: 'a');
    final cyclic = Sequence.create(
      name: 'cycle',
      rootNodeId: 'a',
      nodes: {'a': a, 'b': b},
    );
    expect(cyclic.treeIndex.ancestorsOf('a').map((n) => n.id), ['b', 'a']);
    expect(cyclic.enclosingTarget('a'), isNull);
  });
}
