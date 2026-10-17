import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/replay_debug_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/replay_debug_settings.dart'
    as replay_ui;
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('remote Replay settings expose host-backed controls',
      (tester) async {
    await pumpAppScreen(
      tester,
      const replay_ui.ReplayDebugSettings(),
      extraOverrides: [
        isRemoteModeProvider.overrideWithValue(true),
        replayDebugEnabledProvider.overrideWith((ref) async => false),
        replayDebugRetentionDaysProvider.overrideWith((ref) async => 30),
      ],
    );

    expect(find.text('Imaging host only'), findsNothing);
    expect(find.text('Replay decision logging'), findsOneWidget);
    expect(find.text('Clear all replay history'), findsWidgets);
  });

  testWidgets('remote Replay screen renders the host decision timeline',
      (tester) async {
    final decision = ReplayDecision(
      id: 1,
      sequenceRunId: 42,
      timestamp: DateTime.utc(2026, 7, 14),
      category: DecisionCategory.schedulerPick,
      summary: 'Selected M42 after altitude scoring',
      details: const {'score': 0.91},
    );
    await pumpAppScreen(
      tester,
      const ReplayDebugScreen(
        sequenceRunId: 42,
        sequenceName: 'M42 run',
      ),
      extraOverrides: [
        isRemoteModeProvider.overrideWithValue(true),
        decisionsForRunProvider(42).overrideWith(
          (ref) => Stream.value([decision]),
        ),
      ],
    );

    expect(find.text('Replay is available on the imaging host'), findsNothing);
    expect(find.text('Selected M42 after altitude scoring'), findsOneWidget);
    expect(find.text('No decisions recorded for this run.'), findsNothing);
  });
}
