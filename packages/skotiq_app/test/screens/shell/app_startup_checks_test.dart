import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';

void main() {
  test('failed resume is retried without losing the checkpoint prompt',
      () async {
    var choices = 0;
    var resumeAttempts = 0;
    Object? errorShownByRetry;

    final outcome = await runAppCheckpointRecovery(
      choose: (lastFailure) async {
        choices++;
        errorShownByRetry = lastFailure?.error;
        return AppCheckpointRecoveryChoice.resume;
      },
      resume: () async {
        resumeAttempts++;
        if (resumeAttempts == 1) throw Exception('settings unavailable');
      },
      discard: () async {},
      checkpointStillResumable: () async => true,
    );

    expect(outcome, AppStartupCheckpointOutcome.resumed);
    expect(choices, 2);
    expect(resumeAttempts, 2);
    expect(errorShownByRetry, isA<Exception>());
  });

  test('user can discard after a failed resume', () async {
    var chooseDiscard = false;
    var discarded = false;

    final outcome = await runAppCheckpointRecovery(
      choose: (lastFailure) async {
        if (lastFailure != null) chooseDiscard = true;
        return chooseDiscard
            ? AppCheckpointRecoveryChoice.discard
            : AppCheckpointRecoveryChoice.resume;
      },
      resume: () async => throw Exception('resume failed'),
      discard: () async => discarded = true,
      checkpointStillResumable: () async => true,
    );

    expect(outcome, AppStartupCheckpointOutcome.discarded);
    expect(discarded, isTrue);
  });
}
