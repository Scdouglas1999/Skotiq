import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/src/providers/sequence/run_record.dart';

void main() {
  test('a frame-count message is marked as one until another replaces it', () {
    final run = RunRecordNotifier();
    run.updateProgress(
      message: SequenceProgress.frameCountMessage(3, 10),
      messageIsFrameCount: true,
    );
    expect(run.record.progress.message, 'Progress: 3/10 exposures');
    expect(run.record.progress.messageIsFrameCount, isTrue);

    run.updateProgress(completedExposures: 4);
    expect(run.record.progress.messageIsFrameCount, isTrue);

    run.updateProgress(message: 'Progress: waiting for the target to rise');
    expect(run.record.progress.messageIsFrameCount, isFalse);
  });
}
