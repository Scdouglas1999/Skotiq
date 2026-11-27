import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_mobile/widgets/checkpoint_resume_dialog.dart';

class _RecordingExecutor extends Fake implements SequenceExecutor {
  final calls = <String>[];

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
}
