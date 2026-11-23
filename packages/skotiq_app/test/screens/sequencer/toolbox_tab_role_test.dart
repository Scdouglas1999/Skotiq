// The Sequencer palette switch must publish a role and a state on the node
// that carries the label, the one an AT-SPI client reads. A Material `TabBar`
// puts the tab role on an ancestor, so its label node dumps as
// `panel: Nodes / Tab 1 of 3`.
//
// The third pane is named for what it holds: the app has three things called
// a queue (the planetarium wishlist, the autopilot's scheduler queue and this
// pane), and naming the pane after one of them told the owner nothing about
// the targets already in his loaded sequence. The label is also the segment's
// accessible name, the word a screen reader announces for the pane.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/pump_app_screen.dart';

List<Override> _overrides() {
  final notifier = CurrentSequenceNotifier();
  final root = InstructionSetNode(name: 'Root');
  // ignore: invalid_use_of_protected_member
  notifier.state = Sequence.create(
    name: 'New Sequence',
    nodes: {root.id: root},
    rootNodeId: root.id,
  );
  return [
    currentSequenceProvider.overrideWith((_) => notifier),
    // The ETA column's wall clock would leave a periodic timer behind.
    ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'each palette segment is a named button that says whether it is open',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: const Size(1600, 900),
      extraOverrides: _overrides(),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 600));

    const segments = ['Nodes', 'Snippets', 'Targets'];
    for (final label in segments) {
      final data = tester.getSemantics(find.text(label)).getSemanticsData();
      expect(data.label, label, reason: 'the "$label" node carries its name');
      // ignore: deprecated_member_use
      expect(data.hasFlag(SemanticsFlag.isButton), isTrue,
          reason: 'the node that carries "$label" also carries the role');
      expect(
        // ignore: deprecated_member_use
        data.hasFlag(SemanticsFlag.isSelected),
        label == 'Nodes',
        reason: 'the Nodes pane opens first; only its segment is selected',
      );
    }

    semantics.dispose();
  });
}
