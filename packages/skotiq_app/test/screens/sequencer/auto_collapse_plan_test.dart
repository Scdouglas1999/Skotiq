// The auto-collapse planner (spec §4), in isolation from the tree.
//
// Every case here is a moment in a run: where the executor was, where it is
// now, what has finished, and what the operator has opened by hand. The plan
// is the tree's whole response to that moment.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Two targets, each holding one loop of two exposures:
///
///   root
///   ├── A          (TargetHeaderNode)
///   │   └── A loop (LoopNode) -> A1, A2
///   └── B
///       └── B loop -> B1, B2
///
/// The smallest shape with two sibling branches three levels deep, which is
/// what "fold the branch the run has left" needs to be tested against.
({
  Sequence sequence,
  String targetA,
  String loopA,
  String a1,
  String a2,
  String targetB,
  String loopB,
  String b1,
}) _twoTargets() {
  final a1 = ExposureNode(name: 'A1', durationSecs: 60, count: 1);
  final a2 = ExposureNode(name: 'A2', durationSecs: 60, count: 1);
  final b1 = ExposureNode(name: 'B1', durationSecs: 60, count: 1);
  final b2 = ExposureNode(name: 'B2', durationSecs: 60, count: 1);
  final loopA = LoopNode(
    name: 'A loop',
    conditionType: LoopConditionType.count,
    repeatCount: 1,
  );
  final loopB = LoopNode(
    name: 'B loop',
    conditionType: LoopConditionType.count,
    repeatCount: 1,
  );
  final targetA = TargetHeaderNode(
    name: 'A',
    targetName: 'A',
    raHours: 5.5,
    decDegrees: -5.4,
  );
  final targetB = TargetHeaderNode(
    name: 'B',
    targetName: 'B',
    raHours: 20.1,
    decDegrees: 38.0,
  );
  final root = InstructionSetNode(name: 'Root');

  return (
    sequence: Sequence.create(
      name: 'Night',
      rootNodeId: root.id,
      nodes: {
        a1.id: a1.copyWith(parentId: loopA.id, orderIndex: 0),
        a2.id: a2.copyWith(parentId: loopA.id, orderIndex: 1),
        b1.id: b1.copyWith(parentId: loopB.id, orderIndex: 0),
        b2.id: b2.copyWith(parentId: loopB.id, orderIndex: 1),
        loopA.id: loopA.copyWith(
          parentId: targetA.id,
          childIds: [a1.id, a2.id],
        ),
        loopB.id: loopB.copyWith(
          parentId: targetB.id,
          childIds: [b1.id, b2.id],
        ),
        targetA.id: targetA.copyWith(
          parentId: root.id,
          orderIndex: 0,
          childIds: [loopA.id],
        ),
        targetB.id: targetB.copyWith(
          parentId: root.id,
          orderIndex: 1,
          childIds: [loopB.id],
        ),
        root.id: root.copyWith(childIds: [targetA.id, targetB.id]),
      },
    ),
    targetA: targetA.id,
    loopA: loopA.id,
    a1: a1.id,
    a2: a2.id,
    targetB: targetB.id,
    loopB: loopB.id,
    b1: b1.id,
  );
}

AutoCollapsePlan _plan(
  Sequence sequence, {
  String? previousNodeId,
  required String? currentNodeId,
  Map<String, NodeStatus> statuses = const {},
  Set<String> collapsed = const {},
  Set<String> userExpanded = const {},
  bool followExecution = true,
}) {
  return planAutoCollapse(
    sequence: sequence,
    previousNodeId: previousNodeId,
    currentNodeId: currentNodeId,
    statuses: statuses,
    collapsed: collapsed,
    userExpanded: userExpanded,
    followExecution: followExecution,
  );
}

void main() {
  test('ancestors run outermost first and never include the root', () {
    final t = _twoTargets();
    expect(
      sequenceAncestorIds(t.sequence, t.a1),
      <String>[t.targetA, t.loopA],
    );
    expect(sequenceAncestorIds(t.sequence, t.targetA), isEmpty);
  });

  test('a run start opens the executing branch and folds finished ones', () {
    final t = _twoTargets();
    final plan = _plan(
      t.sequence,
      currentNodeId: t.b1,
      statuses: {
        t.targetA: NodeStatus.success,
        t.loopA: NodeStatus.success,
        t.a1: NodeStatus.success,
        t.a2: NodeStatus.success,
      },
      collapsed: {t.targetB, t.loopB},
    );

    expect(plan.toExpand, {t.targetB, t.loopB});
    // Only the OUTERMOST finished container folds: collapsing the loop inside
    // it would be invisible now and a surprise when the target is reopened.
    expect(plan.toCollapse, {t.targetA});
  });

  test('a container whose every child finished counts as finished', () {
    final t = _twoTargets();
    // Neither the loop nor the target carries a status of its own — only the
    // two exposures under them do.
    final plan = _plan(
      t.sequence,
      currentNodeId: t.b1,
      statuses: {t.a1: NodeStatus.success, t.a2: NodeStatus.skipped},
    );

    expect(plan.toCollapse, {t.targetA});
  });

  test('a half-finished container stays open', () {
    final t = _twoTargets();
    final plan = _plan(
      t.sequence,
      currentNodeId: t.b1,
      statuses: {t.a1: NodeStatus.success},
    );

    expect(plan.toCollapse, isEmpty);
  });

  test('moving to the next target folds the one just finished', () {
    final t = _twoTargets();
    final plan = _plan(
      t.sequence,
      previousNodeId: t.a2,
      currentNodeId: t.b1,
      statuses: {
        t.a1: NodeStatus.success,
        t.a2: NodeStatus.success,
        t.loopA: NodeStatus.success,
        t.targetA: NodeStatus.success,
      },
    );

    expect(plan.toExpand, isEmpty);
    expect(plan.toCollapse, {t.targetA});
  });

  test('moving inside the same branch folds nothing', () {
    final t = _twoTargets();
    final plan = _plan(
      t.sequence,
      previousNodeId: t.a1,
      currentNodeId: t.a2,
      statuses: {t.a1: NodeStatus.success},
    );

    expect(plan.isEmpty, isTrue);
  });

  test('a container the operator opened by hand is never folded', () {
    final t = _twoTargets();
    final statuses = {
      t.a1: NodeStatus.success,
      t.a2: NodeStatus.success,
      t.loopA: NodeStatus.success,
      t.targetA: NodeStatus.success,
    };

    expect(
      _plan(
        t.sequence,
        previousNodeId: t.a2,
        currentNodeId: t.b1,
        statuses: statuses,
      ).toCollapse,
      {t.targetA},
      reason: 'the control: without the operator it folds',
    );

    expect(
      _plan(
        t.sequence,
        previousNodeId: t.a2,
        currentNodeId: t.b1,
        statuses: statuses,
        userExpanded: {t.targetA},
      ).toCollapse,
      isEmpty,
    );
  });

  test('a container that has not run is not a candidate at all', () {
    final t = _twoTargets();
    // B's branch is pending and the operator has it open; the run is in A.
    final plan = _plan(
      t.sequence,
      currentNodeId: t.a1,
      statuses: const {},
      userExpanded: {t.targetB},
    );

    expect(plan.toCollapse, isEmpty);
  });

  test('a failed branch stays open', () {
    final t = _twoTargets();
    final plan = _plan(
      t.sequence,
      previousNodeId: t.a2,
      currentNodeId: t.b1,
      statuses: {
        t.a1: NodeStatus.success,
        t.a2: NodeStatus.failure,
        t.loopA: NodeStatus.failure,
        t.targetA: NodeStatus.failure,
      },
    );

    expect(plan.toCollapse, isEmpty);
  });

  test('an already collapsed container is not collapsed again', () {
    final t = _twoTargets();
    final plan = _plan(
      t.sequence,
      previousNodeId: t.a2,
      currentNodeId: t.b1,
      statuses: {t.a1: NodeStatus.success, t.a2: NodeStatus.success},
      collapsed: {t.targetA},
    );

    expect(plan.isEmpty, isTrue);
  });

  test('follow execution off plans nothing', () {
    final t = _twoTargets();
    final plan = _plan(
      t.sequence,
      previousNodeId: t.a2,
      currentNodeId: t.b1,
      statuses: {
        t.a1: NodeStatus.success,
        t.a2: NodeStatus.success,
        t.targetA: NodeStatus.success,
      },
      collapsed: {t.targetB, t.loopB},
      followExecution: false,
    );

    expect(plan.isEmpty, isTrue);
  });

  test('no executing node plans nothing', () {
    final t = _twoTargets();
    expect(_plan(t.sequence, currentNodeId: null).isEmpty, isTrue);
    expect(_plan(t.sequence, currentNodeId: 'gone').isEmpty, isTrue);
  });
}
