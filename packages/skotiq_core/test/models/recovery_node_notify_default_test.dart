// Owner decision 2026-10-06: only a risk to the hardware stops a run by
// itself. A Recovery node starts at Retry, which on a trigger means "pause the
// run after N firings", so a node given an HFR, focus-drift, guiding-RMS,
// drift or transparency trigger in the editor paused the run on a judgment of
// the frames. Choosing one of those triggers now gives Notify; an action the
// operator picked is kept.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/services/sequence_wire_codec.dart';

void main() {
  test('a quality trigger on a node still at Retry notifies', () {
    for (final type in [
      TriggerType.hfrDegraded,
      TriggerType.focusDrift,
      TriggerType.guidingFailed,
      TriggerType.driftLimit,
      TriggerType.transparencyDropped,
    ]) {
      final node = RecoveryNode().withTriggerType(type);
      expect(node.triggerType, type);
      expect(node.recoveryAction, RecoveryActionType.notify, reason: '$type');
    }
  });

  test('a safety trigger keeps Retry', () {
    for (final type in [
      TriggerType.weatherUnsafe,
      TriggerType.dawnApproaching,
      TriggerType.domeShutterNotOpen,
      TriggerType.mountTrackingLost,
    ]) {
      expect(
        RecoveryNode().withTriggerType(type).recoveryAction,
        RecoveryActionType.retry,
        reason: '$type',
      );
    }
  });

  test('an action the operator chose is kept', () {
    final node = RecoveryNode(
      recoveryAction: RecoveryActionType.pause,
    ).withTriggerType(TriggerType.hfrDegraded);
    expect(node.recoveryAction, RecoveryActionType.pause);
  });

  test('Notify reaches the engine as its own action and survives a file', () {
    final json = recoveryActionToFileWire(RecoveryActionType.notify);
    expect(
      recoveryActionFromWire(json, fallback: RecoveryActionType.retry),
      RecoveryActionType.notify,
    );
    expect(
      recoveryActionFromWire(
        recoveryActionToDbWire(RecoveryActionType.notify),
        fallback: RecoveryActionType.continueExecution,
      ),
      RecoveryActionType.notify,
    );
  });
}
