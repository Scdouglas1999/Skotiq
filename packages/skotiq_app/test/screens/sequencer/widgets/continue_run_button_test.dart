// History offers to continue the run its checkpoint belongs to, and only that
// run: a stopped run is continued from here instead of being raised at launch.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/continue_run_button.dart';
import 'package:skotiq_core/database.dart' show SequenceRun;
import 'package:skotiq_core/models.dart';

SequenceRun _run(
  int id,
  String name,
  DateTime startedAt,
  SequenceRunStatus status, {
  DateTime? endedAt,
}) =>
    SequenceRun(
      id: id,
      sequenceName: name,
      startedAt: startedAt,
      endedAt: endedAt,
      status: status.token,
      statsJson: '{}',
    );

CheckpointInfo _checkpoint(String name, DateTime savedAt) => CheckpointInfo(
      sequenceName: name,
      timestamp: savedAt,
      completedExposures: 5,
      completedIntegrationSecs: 50,
      canResume: true,
      ageSeconds: 60,
      ended: 'stopped',
    );

void main() {
  DateTime at(int h, int m, [int s = 0]) => DateTime.utc(2026, 11, 27, h, m, s);

  test('the run it was saved from owns it', () {
    final runs = [
      _run(1, 'QA M45 pair', at(16, 20), SequenceRunStatus.stoppedResumable,
          endedAt: at(16, 31)),
    ];
    expect(checkpointOwner(_checkpoint('QA M45 pair', at(16, 31)), runs), 1);
  });

  test('an earlier run of the same plan, or another plan, does not', () {
    final runs = [
      _run(1, 'QA M45 pair', at(12, 0), SequenceRunStatus.stoppedResumable,
          endedAt: at(12, 30)),
      _run(2, 'QA M45 long', at(16, 20), SequenceRunStatus.stoppedResumable,
          endedAt: at(16, 31)),
    ];
    expect(
        checkpointOwner(_checkpoint('QA M45 pair', at(16, 31)), runs), isNull);
  });

  // The phone check's night: a run cut by a host crash, the restored run that
  // completed, and a rerun stopped half a minute in. Its checkpoint is the
  // stopped rerun's; the interrupted run (no end recorded) and the completed
  // one ending a minute before it was saved both offered to continue it.
  final night = [
    _run(1, 'M74 Plan', at(15, 25, 42), SequenceRunStatus.interrupted),
    _run(2, 'M74 Plan', at(15, 50, 22), SequenceRunStatus.completed,
        endedAt: at(15, 58, 49)),
    _run(3, 'M74 Plan', at(15, 59, 28), SequenceRunStatus.stoppedResumable,
        endedAt: at(15, 59, 57)),
  ];

  test('only the newest run started before the save owns it', () {
    expect(checkpointOwner(_checkpoint('M74 Plan', at(15, 59, 57)), night), 3);
  });

  test('the interrupted run owns the checkpoint written before the restart',
      () {
    expect(
      checkpointOwner(_checkpoint('M74 Plan', at(15, 47, 6)), night.take(1)),
      1,
    );
  });

  test('a completed run never owns one', () {
    expect(
      checkpointOwner(_checkpoint('M74 Plan', at(15, 58, 49)), night.take(2)),
      isNull,
    );
  });
}
