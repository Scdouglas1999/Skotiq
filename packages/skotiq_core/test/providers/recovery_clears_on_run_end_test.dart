import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_event;
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/models/sequencer/recovery_status.dart';
import 'package:skotiq_core/src/providers/event_provider.dart';
import 'package:skotiq_core/src/providers/recovery_provider.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';

RecoveryStatus _guideStarRecovery() => RecoveryStatus(
  startedAt: DateTime.utc(2026, 10, 23, 7, 54),
  cause: RecoveryCause.guideStarLost(),
  lastAttemptAt: DateTime.utc(2026, 10, 23, 8, 10),
  attemptCount: 40,
  maxAttempts: 0,
  retryIntervalSecs: 30,
  maxDurationSecs: 5400,
  phase: RecoveryPhase.waiting,
  lastError: null,
);

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        skotiqEventsProvider.overrideWith(
          (ref) => const Stream<bridge_event.SkotiqEvent>.empty(),
        ),
      ],
    );
    container.read(recoveryEventBridgeProvider);
    container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.recovering;
    container
        .read(currentRecoveryProvider.notifier)
        .update(_guideStarRecovery());
  });

  tearDown(() => container.dispose());

  // A dawn park during a guide-star recovery ends the run with no recovery
  // outcome event; the banner must not outlive the run.
  for (final ended in [
    SequenceExecutionState.idle,
    SequenceExecutionState.completed,
    SequenceExecutionState.failed,
  ]) {
    test('the recovery clears when the run ends ${ended.name}', () {
      container.read(sequenceExecutionStateProvider.notifier).state = ended;
      expect(container.read(currentRecoveryProvider), isNull);
    });
  }

  test('a pause during the recovery keeps it', () {
    container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.paused;
    expect(container.read(currentRecoveryProvider), isNotNull);
  });
}
