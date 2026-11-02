// History offers to continue the run its checkpoint belongs to, and only that
// run: a stopped run is continued from here instead of being raised at launch.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/continue_run_button.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  final info = CheckpointInfo(
    sequenceName: 'QA M45 pair',
    timestamp: DateTime.utc(2026, 11, 1, 16, 31),
    completedExposures: 5,
    completedIntegrationSecs: 50,
    canResume: true,
    ageSeconds: 60,
    ended: 'stopped',
  );

  test('the run it was saved from matches', () {
    expect(
      checkpointBelongsToRun(
        info,
        sequenceName: 'QA M45 pair',
        startedAt: DateTime.utc(2026, 11, 1, 16, 20),
        endedAt: DateTime.utc(2026, 11, 1, 16, 31),
      ),
      isTrue,
    );
  });

  test('an earlier run of the same plan, or another plan, does not', () {
    expect(
      checkpointBelongsToRun(
        info,
        sequenceName: 'QA M45 pair',
        startedAt: DateTime.utc(2026, 11, 1, 12),
        endedAt: DateTime.utc(2026, 11, 1, 12, 30),
      ),
      isFalse,
    );
    expect(
      checkpointBelongsToRun(
        info,
        sequenceName: 'QA M45 long',
        startedAt: DateTime.utc(2026, 11, 1, 16, 20),
        endedAt: DateTime.utc(2026, 11, 1, 16, 31),
      ),
      isFalse,
    );
  });
}
