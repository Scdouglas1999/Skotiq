// The Builder's own palette (the one on the Sequencer screen) dropped a "+"
// pressed with no sequence open, so a linked client showing "No sequence"
// could not start a plan from it; its "+" was also invisible to screen
// readers.
import 'dart:ui' show SemanticsFlag;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/pump_app_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the Builder palette add starts a sequence when none is open',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final notifier = CurrentSequenceNotifier();
    final handle = await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: const Size(1800, 1000),
      extraOverrides: [
        currentSequenceProvider.overrideWith((_) => notifier),
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.idle),
        ledgerClockProvider
            .overrideWith((ref) => const Stream<DateTime>.empty()),
      ],
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 400));
    // A standalone Builder opens a blank plan by itself; a linked client
    // with nothing on the host shows "No sequence", which is this state.
    // ignore: invalid_use_of_protected_member
    notifier.state = null;
    await tester.pump();

    final add = find.semantics.byLabel('Add Take exposures to the sequence');
    expect(
      add.evaluate().single.getSemanticsData().hasFlag(SemanticsFlag.isEnabled),
      isTrue,
      reason: 'a button without the enabled flag reads as disabled',
    );
    tester.semantics.tap(add);
    await tester.pump();

    final sequence = handle.container.read(currentSequenceProvider);
    expect(sequence?.nodes.values.whereType<ExposureNode>(), hasLength(1));
    // Drain the editor's debounced validation and autosave timers.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 15));
    semantics.dispose();
  });
}
