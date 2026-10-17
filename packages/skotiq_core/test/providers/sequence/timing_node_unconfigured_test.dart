import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/sequence/rules/timing_rules.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_validation.dart';

/// A "Wait for Time" node dropped from the palette starts with no time and no
/// twilight condition. Pre-flight said nothing about it and the run completed
/// the node in twelve microseconds — the canonical use of the node is "wait
/// until astronomical dark", so the silent skip started runs in daylight.
///
/// The sibling shape is an until-time Loop with no end time: the executor
/// evaluates `UntilTime` against a missing instant and exits before the first
/// iteration, so the loop body never runs at all.
Sequence _sequenceWith(List<SequenceNode> children) {
  final root = InstructionSetNode(name: 'Root');
  final nodes = <String, SequenceNode>{root.id: root};
  final childIds = <String>[];
  for (final child in children) {
    final placed = child.copyWith(parentId: root.id);
    nodes[placed.id] = placed;
    childIds.add(placed.id);
  }
  nodes[root.id] = root.copyWith(childIds: childIds);
  return Sequence.create(name: 'T', nodes: nodes, rootNodeId: root.id);
}

void main() {
  group('WaitTimeUnconfiguredRule', () {
    final rule = WaitTimeUnconfiguredRule();

    test('an untouched Wait node is a blocking error', () {
      final node = WaitTimeNode();
      final issues = rule.validate(_sequenceWith([node]));
      expect(issues, hasLength(1));
      expect(issues.single.severity, ValidationSeverity.error);
      expect(issues.single.title, 'Wait Has No Time Set');
      expect(issues.single.affectedNodeId, node.id);
    });

    test('a Wait node with an absolute time is clean', () {
      final node = WaitTimeNode(
        waitUntil: DateTime.now().add(const Duration(hours: 2)),
      );
      expect(rule.validate(_sequenceWith([node])), isEmpty);
    });

    test('a Wait node with a twilight condition is clean', () {
      final node = WaitTimeNode(waitForTwilight: TwilightType.astronomical);
      expect(rule.validate(_sequenceWith([node])), isEmpty);
    });

    test('a disabled Wait node never runs, so it is clean', () {
      final node = WaitTimeNode(isEnabled: false);
      expect(rule.validate(_sequenceWith([node])), isEmpty);
    });
  });

  group('LoopUntilTimeUnsetRule', () {
    final rule = LoopUntilTimeUnsetRule();

    test('an until-time loop with no end time is a blocking error', () {
      final node = LoopNode(
        name: 'Repeat',
        conditionType: LoopConditionType.untilTime,
      );
      final issues = rule.validate(_sequenceWith([node]));
      expect(issues, hasLength(1));
      expect(issues.single.severity, ValidationSeverity.error);
      expect(issues.single.title, 'Loop Has No End Time');
      expect(issues.single.affectedNodeId, node.id);
    });

    test('an until-time loop with an end time is clean', () {
      final node = LoopNode(
        name: 'Repeat',
        conditionType: LoopConditionType.untilTime,
        repeatUntil: DateTime.now().add(const Duration(hours: 4)),
      );
      expect(rule.validate(_sequenceWith([node])), isEmpty);
    });

    test('a count loop is not touched by this rule', () {
      final node = LoopNode(
        name: 'Repeat',
        conditionType: LoopConditionType.count,
        repeatCount: 5,
      );
      expect(rule.validate(_sequenceWith([node])), isEmpty);
    });
  });

  // The rules must be REGISTERED, not merely written: `validateSequence` is
  // what the executor's start pre-check and the pre-flight dialog both run.
  group('registered in the pre-flight registry', () {
    test('an unconfigured Wait node blocks the start pre-check', () {
      final issues = validateSequence(_sequenceWith([WaitTimeNode()]));
      final blocking = issues.where(
        (i) => i.severity == ValidationSeverity.error,
      );
      expect(blocking.map((i) => i.title), contains('Wait Has No Time Set'));
    });

    test('an until-time loop with no end time blocks the start pre-check', () {
      final issues = validateSequence(
        _sequenceWith([
          LoopNode(name: 'Repeat', conditionType: LoopConditionType.untilTime),
        ]),
      );
      final blocking = issues.where(
        (i) => i.severity == ValidationSeverity.error,
      );
      expect(blocking.map((i) => i.title), contains('Loop Has No End Time'));
    });
  });
}
