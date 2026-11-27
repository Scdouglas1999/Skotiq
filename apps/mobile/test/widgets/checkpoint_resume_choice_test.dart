import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_mobile/widgets/checkpoint_resume_dialog.dart';

class _RecordingExecutor extends Fake implements SequenceExecutor {
  _RecordingExecutor({this.restored = false});

  final bool restored;
  final calls = <String>[];

  @override
  bool get hasRestoredCheckpoint => restored;

  @override
  Future<void> restoreFromCheckpoint() async => calls.add('restore');

  @override
  Future<void> start() async => calls.add('start');

  @override
  Future<void> resumeFromCheckpoint() async {
    calls.add('restore');
    calls.add('start');
  }

  @override
  Future<void> discardCheckpoint() async => calls.add('discard');
}

void main() {
  test(
    'Restore on the phone prompt restores and never starts the run',
    () async {
      final executor = _RecordingExecutor();

      await settleCheckpointChoice(executor, restore: true);

      expect(executor.calls, ['restore']);
    },
  );

  test('Discard on the phone prompt only discards', () async {
    final executor = _RecordingExecutor();

    await settleCheckpointChoice(executor, restore: false);

    expect(executor.calls, ['discard']);
  });

  group('a run already restored and waiting for Start', () {
    final info = CheckpointInfo(
      sequenceName: 'NGC 891',
      timestamp: DateTime.utc(2026, 11, 26, 3),
      completedExposures: 4,
      completedIntegrationSecs: 240,
      canResume: true,
      ageSeconds: 30,
    );

    test('by this phone is not offered again', () {
      expect(
        restoredRunAwaitsStart(_RecordingExecutor(restored: true), null),
        isTrue,
      );
    });

    test('by another client of the host is not offered again', () {
      expect(restoredRunAwaitsStart(_RecordingExecutor(), info), isTrue);
    });

    test('nothing restored: the prompt is offered', () {
      expect(restoredRunAwaitsStart(_RecordingExecutor(), null), isFalse);
    });
  });
}
