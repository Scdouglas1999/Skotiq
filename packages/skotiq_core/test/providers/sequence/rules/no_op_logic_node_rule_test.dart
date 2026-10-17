// A Loop that repeats once and a Conditional that always executes are the
// palette's opening state for both nodes - i.e. dragging either in gives you
// something that does nothing, with no sign of it anywhere in the builder.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/sequence/rules/logic_node_rules.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_validation.dart';

Sequence _sequenceWith(List<SequenceNode> nodes) {
  final root = InstructionSetNode(id: 'root', name: 'Root');
  return Sequence.create(
    id: 'seq',
    name: 'test',
    nodes: {
      for (final n in nodes) n.id: n.copyWith(parentId: root.id),
      root.id: root.copyWith(childIds: [for (final n in nodes) n.id]),
    },
    rootNodeId: root.id,
  );
}

List<ValidationIssue> _run(Sequence sequence) =>
    NoOpLogicNodeRule().validate(sequence);

void main() {
  test('a freshly added Loop is flagged as a no-op', () {
    // Exactly what the palette produces: LoopNode() with its defaults.
    final loop = LoopNode(id: 'loop');
    expect(loop.conditionType, LoopConditionType.count);
    expect(loop.repeatCount, 1);

    final issues = _run(_sequenceWith([loop]));

    expect(issues, hasLength(1));
    expect(issues.single.title, 'Loop Repeats Once');
    expect(issues.single.severity, ValidationSeverity.info);
    expect(issues.single.affectedNodeId, 'loop');
  });

  test('a freshly added Conditional is flagged as unconditioned', () {
    final conditional = ConditionalNode(id: 'cond');
    expect(conditional.conditionType, ConditionalType.always);

    final issues = _run(_sequenceWith([conditional]));

    expect(issues, hasLength(1));
    expect(issues.single.title, 'Conditional Has No Condition');
    expect(issues.single.severity, ValidationSeverity.info);
    expect(issues.single.affectedNodeId, 'cond');
  });

  test('a configured Loop is silent', () {
    final issues = _run(_sequenceWith([LoopNode(id: 'loop', repeatCount: 12)]));
    expect(issues, isEmpty);
  });

  test('a non-count loop condition is left to the loop-termination rules', () {
    final issues = _run(
      _sequenceWith([
        LoopNode(
          id: 'loop',
          conditionType: LoopConditionType.whileDark,
          repeatCount: 1,
        ),
      ]),
    );
    expect(issues, isEmpty);
  });

  test('a configured Conditional is silent', () {
    final issues = _run(
      _sequenceWith([
        ConditionalNode(
          id: 'cond',
          conditionType: ConditionalType.altitudeAbove,
          thresholdValue: 30,
        ),
      ]),
    );
    expect(issues, isEmpty);
  });

  test('a disabled node is not flagged', () {
    final issues = _run(
      _sequenceWith([LoopNode(id: 'loop', isEnabled: false)]),
    );
    expect(issues, isEmpty);
  });

  test('the rule is wired into the default validator set', () {
    final issues = validateSequence(_sequenceWith([LoopNode(id: 'loop')]));
    expect(issues.where((i) => i.title == 'Loop Repeats Once'), hasLength(1));
  });
}
