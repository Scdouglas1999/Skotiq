// The Sequencer page header must offer the transport the run's real state
// admits.
//
// With a run PAUSED (toolbar chip "Paused 75%", node badge PAUSED, Pause
// flipped to Resume, no further frames landing) the chip one row above still
// showed a green dot and the literal text "Sequence Running" — the app's most
// prominent run indicator contradicting the one beside it about whether the
// rig was exposing. It was driven by an `isRunning` bool that was true for
// running AND paused.
//
// Wave 3 deleted that chip: the instrument bar is the app's one status
// surface, and the header carries the ACTION instead. The same lie is
// available to the new header (offering "Pause" on a paused run, or "Start"
// while the executor owns the tree), so the guard moves to the buttons.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/pump_app_screen.dart';

Sequence _seedSequence() {
  final exposure = ExposureNode(name: 'Lum', durationSecs: 120, count: 10);
  final root = InstructionSetNode(name: 'Root');
  final nodes = <String, SequenceNode>{
    exposure.id: exposure.copyWith(parentId: root.id),
    root.id: root.copyWith(childIds: [exposure.id]),
  };
  return Sequence.create(name: 'Test', nodes: nodes, rootNodeId: root.id);
}

/// Live validation that reports [issues] whatever the plan, so the header
/// reacts to the plan's problems and not to this test machine's setup.
class _FixedLiveValidation extends StateNotifier<LiveValidationState>
    implements LiveValidationNotifier {
  _FixedLiveValidation(List<ValidationIssue> issues)
      : super(LiveValidationState(
          result: ValidationResult(issues: issues, validatedAt: DateTime(2026)),
        ));
}

List<Override> _overrides(
  SequenceExecutionState state, {
  List<ValidationIssue> issues = const [],
}) {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = _seedSequence();
  return [
    currentSequenceProvider.overrideWith((_) => notifier),
    runRecordProvider.overrideWith(
      (ref) => RunRecordNotifier(ref, RunRecord(lifecycle: state)),
    ),
    liveValidationProvider.overrideWith((ref) => _FixedLiveValidation(issues)),
    // The ledger ETA clock is a real periodic stream; in the fake-async
    // zone its timer outlives every pump and fails teardown.
    ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Desktop width: the chip is deliberately desktop/tablet-only (a phone
  // surfaces run state through the playback bar instead).
  const desktop = Size(1920, 1080);

  Future<void> pumpAt(
    WidgetTester tester,
    SequenceExecutionState state, {
    List<ValidationIssue> issues = const [],
  }) async {
    await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: desktop,
      extraOverrides: _overrides(state, issues: issues),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('a running sequence offers Pause and Stop', (tester) async {
    await pumpAt(tester, SequenceExecutionState.running);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(
      find.text('Start'),
      findsNothing,
      reason: 'the sequence is already running',
    );
  });

  testWidgets('a PAUSED sequence does not offer Pause', (tester) async {
    await pumpAt(tester, SequenceExecutionState.paused);
    expect(
      find.text('Pause'),
      findsNothing,
      reason: 'the rig is not exposing while the run is paused',
    );
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
  });

  testWidgets('an idle sequence offers Start and nothing else', (tester) async {
    await pumpAt(tester, SequenceExecutionState.idle);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
    expect(find.text('Pause'), findsNothing);
    expect(find.text('Resume'), findsNothing);
  });

  // Beside a red error count the header showed a bright green Start, and
  // pressing it opened a dialog that said "Cannot start".
  testWidgets('an idle plan that cannot start offers the fix, not Start',
      (tester) async {
    await pumpAt(
      tester,
      SequenceExecutionState.idle,
      issues: const [
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.targets,
          title: 'Invalid RA',
          description: 'RA is out of range',
        ),
      ],
    );
    expect(find.text('Start'), findsNothing);
    expect(find.text('Fix 1 error'), findsOneWidget);
  });
}
