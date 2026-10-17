// Unit tests for the collapsed-container rollup line (spec §3).
//
// `rollupSummary` is pure: give it a container and the sequence holding it,
// get back the line a collapsed ledger/compact row appends after the name.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/rollup_summary.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Wrap [children] under [container], itself under a root, and hand back the
/// sequence. Children get canonical `parentId` / `orderIndex` so
/// `getChildren` returns them in the given order.
Sequence _sequence(SequenceNode container, List<SequenceNode> children) {
  final root = InstructionSetNode(name: 'Root');
  final placed = <SequenceNode>[
    for (var i = 0; i < children.length; i++)
      children[i].copyWith(parentId: container.id, orderIndex: i),
  ];
  return Sequence.create(
    name: 'T',
    rootNodeId: root.id,
    nodes: {
      for (final child in placed) child.id: child,
      container.id: container.copyWith(
        parentId: root.id,
        childIds: [for (final child in placed) child.id],
      ),
      root.id: root.copyWith(childIds: [container.id]),
    },
  );
}

void main() {
  group('filter run', () {
    test('exposures differing only by filter summarise as one run', () {
      final loop = LoopNode(name: 'Narrowband');
      final sequence = _sequence(loop, [
        ExposureNode(name: 'Ha', filter: 'Ha', durationSecs: 300, count: 12),
        ExposureNode(
            name: 'OIII', filter: 'OIII', durationSecs: 300, count: 12),
        ExposureNode(name: 'SII', filter: 'SII', durationSecs: 300, count: 12),
      ]);

      // ExposureNode.ditherEvery defaults to 3.
      expect(
        rollupSummary(loop, sequence),
        'Ha · OIII · SII 300 s ×12 each · dither every 3',
      );
    });

    test('the dither clause is dropped when the run does not dither', () {
      final set = InstructionSetNode(name: 'Broadband');
      final sequence = _sequence(set, [
        ExposureNode(
            name: 'L',
            filter: 'L',
            durationSecs: 60,
            count: 20,
            ditherEvery: 0),
        ExposureNode(
            name: 'R',
            filter: 'R',
            durationSecs: 60,
            count: 20,
            ditherEvery: 0),
      ]);

      expect(rollupSummary(set, sequence), 'L · R 60 s ×20 each');
    });

    test('a single exposure is not a "run"', () {
      final set = InstructionSetNode(name: 'Set');
      final sequence = _sequence(set, [
        ExposureNode(name: 'Ha subs', filter: 'Ha', durationSecs: 300),
      ]);

      // One child means there is nothing for "each" to distribute over;
      // the generic shape names it.
      expect(rollupSummary(set, sequence), 'Ha subs');
    });

    test('exposures that disagree on length are two plans, not a run', () {
      final set = InstructionSetNode(name: 'Set');
      final sequence = _sequence(set, [
        ExposureNode(
            name: 'Ha long', filter: 'Ha', durationSecs: 300, count: 12),
        ExposureNode(
            name: 'Ha short', filter: 'OIII', durationSecs: 60, count: 12),
      ]);

      expect(rollupSummary(set, sequence), 'Ha long · Ha short');
    });

    test('unfiltered exposures have no bands to name', () {
      final set = InstructionSetNode(name: 'Set');
      final sequence = _sequence(set, [
        ExposureNode(name: 'Bias A', durationSecs: 1, count: 10),
        ExposureNode(name: 'Bias B', durationSecs: 1, count: 10),
      ]);

      expect(rollupSummary(set, sequence), 'Bias A · Bias B');
    });
  });

  group('target', () {
    test('target name plus the bands its subtree images', () {
      final target = TargetHeaderNode(
        name: 'NA Nebula',
        targetName: 'North America Nebula',
        raHours: 20.97,
        decDegrees: 44.5,
      );
      final sequence = _sequence(target, [
        ExposureNode(name: 'Ha', filter: 'Ha', durationSecs: 300, count: 12),
        ExposureNode(
            name: 'OIII', filter: 'OIII', durationSecs: 300, count: 12),
        ExposureNode(name: 'SII', filter: 'SII', durationSecs: 300, count: 12),
      ]);

      expect(
        rollupSummary(target, sequence),
        'North America Nebula · Ha/OIII/SII',
      );
    });

    test('a target imaging nothing falls through to the generic shape', () {
      final target = TargetHeaderNode(
        name: 'Setup',
        targetName: 'Test field',
        raHours: 1.0,
        decDegrees: 30.0,
      );
      final sequence = _sequence(target, [
        DelayNode(name: 'Park', seconds: 5),
        DelayNode(name: 'Slew home', seconds: 5),
      ]);

      expect(rollupSummary(target, sequence), 'Park · Slew home');
    });
  });

  group('trigger group', () {
    test('watchdogs describe themselves by their own summaries', () {
      final set = InstructionSetNode(name: 'Triggers');
      final sequence = _sequence(set, [
        MeridianFlipNode(name: 'Meridian Flip'),
        AutofocusNode(name: 'Autofocus'),
      ]);

      expect(
        rollupSummary(set, sequence),
        'meridian flip minutesPastMeridian · 5 min past · auto-center · '
        'autofocus global AF settings',
      );
    });

    test('an autofocus-only set is not a trigger group', () {
      final set = InstructionSetNode(name: 'Set');
      final sequence = _sequence(set, [
        AutofocusNode(name: 'AF one'),
        AutofocusNode(name: 'AF two'),
      ]);

      // Nothing watchdogs here — two plain instructions read as names.
      expect(rollupSummary(set, sequence), 'AF one · AF two');
    });
  });

  group('generic', () {
    test('first three child names, then +k more', () {
      final set = InstructionSetNode(name: 'Setup');
      final sequence = _sequence(set, [
        DelayNode(name: 'Unpark', seconds: 1),
        DelayNode(name: 'Slew', seconds: 1),
        DelayNode(name: 'Center', seconds: 1),
        DelayNode(name: 'Guide', seconds: 1),
        DelayNode(name: 'Focus', seconds: 1),
      ]);

      expect(
        rollupSummary(set, sequence),
        'Unpark · Slew · Center · +2 more',
      );
    });

    test('exactly three children need no count', () {
      final set = InstructionSetNode(name: 'Set');
      final sequence = _sequence(set, [
        DelayNode(name: 'A', seconds: 1),
        DelayNode(name: 'B', seconds: 1),
        DelayNode(name: 'C', seconds: 1),
      ]);

      expect(rollupSummary(set, sequence), 'A · B · C');
    });
  });

  test('an empty container says nothing', () {
    final set = InstructionSetNode(name: 'Empty');
    final sequence = _sequence(set, const []);

    expect(rollupSummary(set, sequence), isEmpty);
  });
}
