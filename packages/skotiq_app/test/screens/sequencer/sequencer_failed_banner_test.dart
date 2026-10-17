// The Sequencer screen's "Sequence failed" banner must name the fault that
// ended the run, not the step the teardown cancelled after it.
//
// On 2026-09-14 the only message the operator saw was "Change Filter:
// Operation cancelled": the filter wheel's wait loop noticing the cancellation
// a second after recovery had already given up. The native executor now ships
// the real cause on `SequenceFailed.error` and Dart files it as
// `terminalCause`, but the cascade keeps the teardown step as its LAST entry.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

const _rejectStorm =
    'Image grading: 3 consecutive rejects (limit 3). Sequence paused for '
    'inspection.';
const _teardown = 'Change Filter: Operation cancelled';

Sequence _seedSequence() {
  final exposure = ExposureNode(name: 'Lum', durationSecs: 120, count: 10);
  final root = InstructionSetNode(name: 'Root');
  final nodes = <String, SequenceNode>{
    exposure.id: exposure.copyWith(parentId: root.id),
    root.id: root.copyWith(childIds: [exposure.id]),
  };
  return Sequence.create(name: 'Test', nodes: nodes, rootNodeId: root.id);
}

List<Override> _overrides(SequenceRunStats stats) {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = _seedSequence();
  return [
    currentSequenceProvider.overrideWith((_) => notifier),
    sequenceExecutionStateProvider
        .overrideWith((ref) => SequenceExecutionState.failed),
    liveSequenceStatsProvider.overrideWith((ref) => stats),
    // The Ledger's minute clock is a periodic timer that outlives the test
    // body; the banner does not read it.
    ledgerClockProvider
        .overrideWith((ref) => Stream.value(DateTime(2026, 9, 15, 3))),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the failed banner names the cause, not the cancelled teardown',
      (tester) async {
    // The cascade exactly as the executor records it: the cause first, the
    // teardown step after it, and the cause filed as `terminalCause`.
    final stats = SequenceRunStats()
      ..recordError(_rejectStorm)
      ..recordError(_teardown)
      ..recordTerminalError(_rejectStorm);

    await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: const Size(1400, 900),
      extraOverrides: _overrides(stats),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 600));

    final banner = find.byType(SkotiqBanner);
    expect(banner, findsOneWidget);
    expect(
      find.descendant(of: banner, matching: find.textContaining(_rejectStorm)),
      findsOneWidget,
      reason: 'the banner must lead with the fault that ended the run',
    );
    expect(
      find.descendant(of: banner, matching: find.textContaining(_teardown)),
      findsNothing,
      reason: 'a step cancelled because the run was already failing is never '
          'the failure reason',
    );
  });

  testWidgets('without a recorded cause the banner still shows the last error',
      (tester) async {
    final stats = SequenceRunStats()..recordError('Slew failed: limit');

    await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: const Size(1400, 900),
      extraOverrides: _overrides(stats),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 600));

    final banner = find.byType(SkotiqBanner);
    expect(
      find.descendant(
        of: banner,
        matching: find.textContaining('Slew failed: limit'),
      ),
      findsOneWidget,
    );
  });
}
