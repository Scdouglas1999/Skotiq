// The hero's facts line must not contradict the Sequencer about the same
// sequence.
//
// The first cut counted `sequence.nodes.length`, which includes the invisible
// root, so Tonight printed "28 nodes" for the LRGB M51 starter while the
// Sequencer's own header chip printed "27" — two screens, one sequence, two
// numbers. Both now go through `visibleInstructionCount`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/tonight/tonight_hero.dart';
import 'package:skotiq_app/screens/sequencer/sequence_counts.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

/// A sequence shaped like the bundled starters: a root instruction set with
/// [instructions] children under it.
Sequence _sequence({required int instructions}) {
  final root = InstructionSetNode(name: 'Mono LRGB M51');
  final children = <SequenceNode>[
    for (var i = 0; i < instructions; i++)
      ExposureNode().copyWith(parentId: root.id),
  ];
  final placedRoot = root.copyWith(childIds: [for (final c in children) c.id]);
  return Sequence.create(
    name: 'Mono LRGB M51 (Whirlpool) - L then RGB',
    nodes: {
      placedRoot.id: placedRoot,
      for (final c in children) c.id: c,
    },
    rootNodeId: placedRoot.id,
  );
}

class _SeedingNotifier extends CurrentSequenceNotifier {
  _SeedingNotifier(Ref ref, Sequence seed) : super(ref: ref) {
    loadSequence(seed, discardUnsaved: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('visibleInstructionCount excludes the invisible root', () {
    final sequence = _sequence(instructions: 27);
    expect(sequence.nodes.length, 28, reason: 'root + 27 instructions');
    expect(
      visibleInstructionCount(sequence),
      27,
      reason: 'the root is structure, not an instruction the user placed',
    );
  });

  testWidgets('the hero quotes the Sequencer\'s node count, not nodes.length',
      (tester) async {
    final sequence = _sequence(instructions: 27);

    await pumpAppScreen(
      tester,
      const TonightHero(),
      size: const Size(1400, 300),
      settle: false,
      extraOverrides: [
        currentSequenceProvider
            .overrideWith((ref) => _SeedingNotifier(ref, sequence)),
      ],
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(
      find.textContaining('27 nodes'),
      findsOneWidget,
      reason: 'the Sequencer header prints 27 for this sequence; Tonight must '
          'print the same number for the same sequence',
    );
    expect(find.textContaining('28 nodes'), findsNothing);
  });

  // Live: "New Sequence · 0 nodes · ~0 m" led the facts line with nothing
  // loaded, because a fresh sequence's `nodes` holds its root.
  testWidgets('an empty sequence puts no sequence fact on the line',
      (tester) async {
    final empty = _sequence(instructions: 0);
    expect(empty.nodes, isNotEmpty, reason: 'the root is always there');

    await pumpAppScreen(
      tester,
      const TonightHero(),
      size: const Size(1400, 300),
      settle: false,
      extraOverrides: [
        currentSequenceProvider
            .overrideWith((ref) => _SeedingNotifier(ref, empty)),
      ],
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.textContaining('0 nodes'), findsNothing);
    expect(find.textContaining(empty.name), findsNothing);
  });
}
