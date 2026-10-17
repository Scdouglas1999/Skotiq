import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';

void main() {
  group('catalog setup skip persistence', () {
    test('only an explicit persisted true suppresses the prompt', () {
      expect(catalogSetupWasSkipped('true'), isTrue);
      expect(catalogSetupWasSkipped(' TRUE '), isTrue);
      expect(catalogSetupWasSkipped(null), isFalse);
      expect(catalogSetupWasSkipped('false'), isFalse);
      expect(catalogSetupWasSkipped('garbage'), isFalse);
    });
  });

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

  for (final outcome in [
    AppStartupCheckpointOutcome.noRecovery,
    AppStartupCheckpointOutcome.discarded,
  ]) {
    test('catalog setup waits for checkpoint outcome $outcome', () async {
      final checkpoint = Completer<AppStartupCheckpointOutcome>();
      final events = <String>[];

      final checks = runAppStartupChecks(
        checkCheckpoint: () async {
          events.add('checkpoint-started');
          final result = await checkpoint.future;
          events.add('checkpoint-finished');
          return result;
        },
        checkCatalogs: () async {
          events.add('catalogs');
        },
      );

      await Future<void>.delayed(Duration.zero);
      expect(events, ['checkpoint-started']);

      checkpoint.complete(outcome);
      await checks;
      expect(
        events,
        ['checkpoint-started', 'checkpoint-finished', 'catalogs'],
      );
    });
  }

  for (final outcome in [
    AppStartupCheckpointOutcome.resumed,
    AppStartupCheckpointOutcome.failed,
  ]) {
    test('catalog setup is suppressed after checkpoint outcome $outcome',
        () async {
      var catalogsChecked = false;

      await runAppStartupChecks(
        checkCheckpoint: () async => outcome,
        checkCatalogs: () async {
          catalogsChecked = true;
        },
      );

      expect(catalogsChecked, isFalse);
    });
  }
}
