import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  final entry = MountGuardEntry(
    deviceId: 'sim_mount_1',
    blockReason:
        'Skotiq is not moving the mount because its position is unknown.',
    fault: MountMotionFault(
      kind: 'runaway',
      message: 'The mount moved at 4.7 degrees per second with no command.',
      detectedAt: DateTime.utc(2026, 11, 8, 5, 29, 20),
      rateDegPerSec: 4.7,
      raHours: 2.5,
      decDegrees: 61.0,
      altitudeDegrees: null,
      stillMoving: false,
      stopAttempts: const ['Round 1: Abort slew sent'],
      runPaused: true,
    ),
    positionUnknown: MountPositionUnknown(
      reason: 'came_back_after_fault',
      message: 'The mount stopped answering for 31 s.',
      flaggedAt: DateTime.utc(2026, 11, 8, 5, 34, 24),
      runPaused: true,
    ),
  );

  test('a guard entry survives the trip to a linked client', () {
    final back = MountGuardEntry.fromJson(entry.toJson());
    expect(back.deviceId, 'sim_mount_1');
    expect(back.blockReason, entry.blockReason);
    expect(back.fault!.rateDegPerSec, 4.7);
    expect(back.fault!.altitudeDegrees, isNull);
    expect(back.fault!.stopAttempts, ['Round 1: Abort slew sent']);
    expect(back.fault!.detectedAt, entry.fault!.detectedAt);
    expect(back.positionUnknown!.reason, 'came_back_after_fault');
    expect(back.autoRecovering, isFalse);
  });

  test('a host answer missing a field is refused, not filled in', () {
    final json = entry.toJson();
    (json['fault'] as Map<String, dynamic>).remove('stillMoving');
    expect(() => MountGuardEntry.fromJson(json), throwsFormatException);
  });
}
