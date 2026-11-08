// The Continue Session prompt offered "Rig test NGC 7331 2026-11-03 · 5 days
// ago · No progress yet" on the rig instead of the run stopped (with its
// checkpoint kept) the night before: any interrupted session won over every
// other run, and a stopped run was never a candidate.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;

db.ImagingSession _session(
  int id,
  String status,
  DateTime start, {
  DateTime? end,
  int frames = 0,
}) => db.ImagingSession(
  id: id,
  name: 'session $id',
  startTime: start,
  endTime: end,
  totalExposures: frames,
  successfulExposures: frames,
  failedExposures: 0,
  totalIntegrationSecs: frames * 180.0,
  autofocusCount: 0,
  status: status,
);

void main() {
  final now = DateTime(2026, 11, 8, 16, 4);
  final oldTest = _session(
    7,
    kInterruptedSessionStatus,
    DateTime(2026, 11, 3, 18, 12),
  );
  final lastNight = _session(
    65,
    'paused-stopped',
    DateTime(2026, 11, 7, 18, 30),
    end: DateTime(2026, 11, 8, 1, 4),
    frames: 27,
  );

  db.ImagingSession? pick(List<db.ImagingSession> sessions) =>
      continueSessionCandidate(sessions, now: now);

  test('the newest run is offered, not an older interrupted one', () {
    expect(pick([lastNight, oldTest])?.id, 65);
    // Order of the list does not matter, the start time does.
    expect(pick([oldTest, lastNight])?.id, 65);
  });

  test('a run that finished or discarded its resume point is not offered', () {
    for (final status in ['completed', 'stopped', 'aborted', 'failed']) {
      final ended = _session(
        66,
        status,
        DateTime(2026, 11, 7, 18, 30),
        end: DateTime(2026, 11, 8, 1, 4),
        frames: 27,
      );
      // And it supersedes the older interrupted run, which is stale.
      expect(pick([ended, oldTest]), isNull, reason: status);
    }
  });

  test('nothing is offered during a run; an old or empty run expires', () {
    final live = _session(70, 'active', DateTime(2026, 11, 8, 15));
    expect(pick([live, lastNight]), isNull);
    expect(pick([oldTest]), isNull, reason: 'five days old and empty');
    final weekOld = _session(
      5,
      kInterruptedSessionStatus,
      DateTime(2026, 10, 30, 20),
      frames: 40,
    );
    expect(pick([weekOld]), isNull);
    final tonightEmpty = _session(
      71,
      kInterruptedSessionStatus,
      DateTime(2026, 11, 8, 2),
    );
    expect(pick([tonightEmpty])?.id, 71, reason: 'its setup is still worth it');
  });

  test('a kept resume point is offered with its frames, not as finished', () {
    final context =
        QuickStartContext(
          sessionId: 65,
          sequenceName: 'Heart core SHO all night (rotating)',
          completedFrames: 2,
          lastSessionDate: DateTime(2026, 11, 8, 1, 4),
        ).withCheckpointInfo(
          CheckpointInfo(
            sequenceName: 'Heart core SHO all night (rotating)',
            timestamp: DateTime.utc(2026, 11, 8, 6, 4),
            completedExposures: 27,
            completedIntegrationSecs: 27 * 180.0,
            canResume: true,
            ageSeconds: 0,
            ended: 'stopped',
          ),
        );
    expect(context.canResumeFromCheckpoint, isTrue);
    expect(context.completedFrames, 27);
    // A loop-until-stopped plan has no frame total; the frames taken are not
    // one, or the run reads as finished and is not offered.
    expect(context.totalFrames, 0);
  });
}
