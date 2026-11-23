// One rule says whether a target window ends a Smart Exposure that loops
// until stopped: the nearest target above it has an end condition (ends-when,
// ends-before or a maximum altitude). Native installs the nearest target's
// effective end trigger, so the tree, the rollup and validation agree with it.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/models/sequence/validation/rules/smart_exposure_rules.dart';

Sequence _under(List<TargetHeaderNode> targets) {
  final exposure = SmartExposureNode(
    id: 'exp',
    parentId: 'inner',
    loopUntilStopped: true,
    plans: const [FilterPlan(filterName: 'L', count: 10, durationSecs: 60)],
  );
  final nodes = <String, SequenceNode>{
    'exp': exposure,
    for (final t in targets) t.id: t,
    'root': InstructionSetNode(id: 'root', childIds: [targets.last.id]),
  };
  return Sequence.create(name: 'window', rootNodeId: 'root', nodes: nodes);
}

TargetHeaderNode _target(
  String id, {
  required String parentId,
  required String childId,
  TargetTrigger? endWhen,
  DateTime? endBefore,
  double? maxAltitude,
}) => TargetHeaderNode(
  id: id,
  targetName: id,
  raHours: 1,
  decDegrees: 2,
  parentId: parentId,
  childIds: [childId],
  endWhen: endWhen,
  endBefore: endBefore,
  maxAltitude: maxAltitude,
);

NodeOpenEnd? _rollupOpenEnd(Sequence sequence) =>
    computeNodeRollups(sequence, const SequenceTimeEstimator()).openEnds['exp'];

bool _validatorRefuses(Sequence sequence) => SmartExposureUnboundedLoopRule()
    .validate(sequence)
    .any((issue) => issue.affectedNodeId == 'exp');

void main() {
  test('a target with only a maximum altitude ends the loop', () {
    final sequence = _under([
      _target('inner', parentId: 'root', childId: 'exp', maxAltitude: 70),
    ]);
    expect(_rollupOpenEnd(sequence), NodeOpenEnd.targetWindow);
    expect(sequence.isBoundedByTargetWindow('exp'), isTrue);
    expect(_validatorRefuses(sequence), isFalse);
  });

  test('a target with an ends-before time ends the loop', () {
    final sequence = _under([
      _target(
        'inner',
        parentId: 'root',
        childId: 'exp',
        endBefore: DateTime.utc(2026, 11, 23, 5),
      ),
    ]);
    expect(_rollupOpenEnd(sequence), NodeOpenEnd.targetWindow);
    expect(sequence.isBoundedByTargetWindow('exp'), isTrue);
    expect(_validatorRefuses(sequence), isFalse);
  });

  test('a target with no end condition does not', () {
    final sequence = _under([
      _target('inner', parentId: 'root', childId: 'exp'),
    ]);
    expect(_rollupOpenEnd(sequence), NodeOpenEnd.stopped);
    expect(sequence.isBoundedByTargetWindow('exp'), isFalse);
    expect(_validatorRefuses(sequence), isTrue);
  });

  test('the nearest target decides, as native installs it', () {
    final sequence = _under([
      _target('inner', parentId: 'outer', childId: 'exp'),
      _target(
        'outer',
        parentId: 'root',
        childId: 'inner',
        endWhen: const TargetTrigger.altitudeBelow(30),
      ),
    ]);
    expect(_rollupOpenEnd(sequence), NodeOpenEnd.stopped);
    expect(sequence.isBoundedByTargetWindow('exp'), isFalse);
    expect(_validatorRefuses(sequence), isTrue);
  });
}
