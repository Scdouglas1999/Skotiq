// The startup recovery modal must not be able to trap the operator, and must
// not contradict itself.
//
// "Recover Sequence?" is deliberately barrierDismissible:false and ignores
// Escape — an interrupted run has to be decided, not swiped away — and
// runAppCheckpointRecovery re-presents it whenever resume() or discard()
// throws. With only Resume and Discard on it, a backend that throws on BOTH (a
// read-only checkpoint directory, a corrupt file) re-presents it forever and
// the app is unusable behind the barrier. The escape appears only once an
// attempt has actually failed, so the clean first-run flow still forces a
// decision.
//
// The second half: pressing Resume produced, inside the same dialog,
// "Recovery did not complete — Exception: No valid checkpoint to resume from"
// immediately followed by "The checkpoint is still available. Retry resume or
// discard it to start fresh." Two contradictory statements, one of them a raw
// Dart exception string, plus a Retry button that could only fail again. The
// modal now re-reads whether the checkpoint survived the attempt and says that.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show BackendErrorCategory, CheckpointInfo, SkotiqError;
import 'package:skotiq_ui/skotiq_ui.dart';

final _info = CheckpointInfo(
  sequenceName: 'Veil Nebula',
  timestamp: DateTime(2026, 8, 1, 23, 15),
  completedExposures: 6,
  completedIntegrationSecs: 1080,
  canResume: true,
  ageSeconds: 120,
);

/// Shows the real dialog and returns whatever the operator's choice popped.
Future<Object?> showRecoveryDialog(
  WidgetTester tester, {
  required CheckpointAttemptFailure? failure,
  String? remoteHost,
  void Function(Object?)? onPopped,
}) async {
  Object? popped;
  var settled = false;

  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            popped = await showDialog<Object?>(
              context: context,
              barrierDismissible: false,
              builder: (dialogContext) => buildCheckpointRecoveryDialog(
                context: dialogContext,
                info: _info,
                failure: failure,
                remoteHost: remoteHost,
              ),
            );
            settled = true;
            onPopped?.call(popped);
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.text('Recover Sequence?'), findsOneWidget);
  addTearDown(() => expect(settled || popped == null, isTrue));
  return popped;
}

void main() {
  testWidgets('the first prompt offers no way to defer the decision', (
    tester,
  ) async {
    await showRecoveryDialog(tester, failure: null);

    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);
    expect(
      find.text('Not now'),
      findsNothing,
      reason: 'an interrupted run is decided up front; the escape exists only '
          'for a recovery that has already failed',
    );
  });

  // A linked client sees the host's checkpoint, so it can always leave it, and
  // the text says whose run it is.
  testWidgets('a remote client can leave the host checkpoint untouched', (
    tester,
  ) async {
    Object? choice = #unset;
    await showRecoveryDialog(
      tester,
      failure: null,
      remoteHost: '192.168.1.100',
      onPopped: (value) => choice = value,
    );

    expect(find.textContaining('A sequence on 192.168.1.100'), findsOneWidget);
    expect(find.textContaining('move the mount'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);

    await tester.tap(find.text('Leave it'));
    await tester.pumpAndSettle();

    expect(find.text('Recover Sequence?'), findsNothing);
    expect(choice, AppCheckpointRecoveryChoice.later);
  });

  test('leaving a remote checkpoint neither resumes nor discards', () async {
    var resumed = false;
    var discarded = false;
    final outcome = await runAppCheckpointRecovery(
      choose: (_) async => AppCheckpointRecoveryChoice.later,
      resume: () async => resumed = true,
      discard: () async => discarded = true,
      checkpointStillResumable: () async => true,
    );

    expect(outcome, AppStartupCheckpointOutcome.deferred);
    expect(resumed, isFalse);
    expect(discarded, isFalse);
  });

  testWidgets('after a failed attempt the operator can leave the modal', (
    tester,
  ) async {
    await showRecoveryDialog(
      tester,
      failure: const CheckpointAttemptFailure(
        error: FileSystemException('checkpoint directory is read-only'),
        checkpointStillResumable: true,
      ),
    );

    expect(find.text('Retry Resume'), findsOneWidget);
    expect(find.textContaining('Recovery did not complete'), findsOneWidget);

    final escape = find.text('Not now');
    expect(
      escape,
      findsOneWidget,
      reason: 'both actions can keep throwing, and the barrier cannot be '
          'dismissed — without this the app is wedged',
    );

    await tester.tap(escape);
    await tester.pumpAndSettle();

    // Gone, and it resolved to no choice — which runAppCheckpointRecovery
    // treats as "stop asking", leaving the checkpoint on disk.
    expect(find.text('Recover Sequence?'), findsNothing);
  });

  testWidgets('a checkpoint that cannot be resumed is not called available', (
    tester,
  ) async {
    await showRecoveryDialog(
      tester,
      failure: const CheckpointAttemptFailure(
        error: FormatException('No valid checkpoint to resume from'),
        checkpointStillResumable: false,
      ),
    );

    expect(
      find.textContaining('The checkpoint is still on disk'),
      findsNothing,
      reason: 'the executor just said the checkpoint is not usable; claiming '
          'it is still available in the same box is the contradiction this '
          'test exists for',
    );
    expect(
      find.textContaining('This checkpoint can no longer be resumed'),
      findsOneWidget,
    );
    expect(
      find.text('Retry Resume'),
      findsNothing,
      reason: 'a retry against an unusable checkpoint can only fail again',
    );
    expect(find.text('Discard'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
  });

  testWidgets('the failure reads as a sentence, not as a Dart object', (
    tester,
  ) async {
    await showRecoveryDialog(
      tester,
      failure: CheckpointAttemptFailure(
        error: Exception('No valid checkpoint to resume from'),
        checkpointStillResumable: false,
      ),
    );

    expect(
      find.textContaining('Exception:'),
      findsNothing,
      reason: 'a raw runtime string in a startup modal is not a message',
    );
    expect(
      find.textContaining('No valid checkpoint to resume from'),
      findsOneWidget,
    );
  });

  group('describeCheckpointFailure', () {
    test('strips the Dart wrapper from a plain Exception', () {
      expect(
        describeCheckpointFailure(Exception('checkpoint is corrupt')),
        'checkpoint is corrupt',
      );
    });

    test('prefers the operator-facing message of a SkotiqError', () {
      expect(
        describeCheckpointFailure(
          const SkotiqError(
            category: BackendErrorCategory.connection,
            message: 'ipc channel closed while resuming',
            userMessage: 'The imaging host stopped responding.',
          ),
        ),
        'The imaging host stopped responding.',
      );
    });
  });

  testWidgets('deferring returns no choice, so recovery stops re-prompting', (
    tester,
  ) async {
    var prompts = 0;
    final outcome = await runAppCheckpointRecovery(
      choose: (lastFailure) async {
        prompts++;
        // First round the operator tries Discard; it throws. Second round they
        // give up — exactly what tapping "Not now" pops.
        return prompts == 1 ? AppCheckpointRecoveryChoice.discard : null;
      },
      resume: () async => throw StateError('unused'),
      discard: () async => throw const FileSystemException('read-only'),
      checkpointStillResumable: () async => true,
    );

    expect(prompts, 2);
    expect(outcome, AppStartupCheckpointOutcome.failed);
  });

  test('a failed attempt re-reads whether the checkpoint survived', () async {
    final seen = <CheckpointAttemptFailure?>[];
    var probes = 0;

    await runAppCheckpointRecovery(
      choose: (lastFailure) async {
        seen.add(lastFailure);
        return seen.length == 1 ? AppCheckpointRecoveryChoice.resume : null;
      },
      resume: () async => throw Exception('No valid checkpoint to resume from'),
      discard: () async {},
      checkpointStillResumable: () async {
        probes++;
        return false;
      },
    );

    expect(probes, 1,
        reason: 'the backend is the authority, not an assumption');
    expect(seen.last?.checkpointStillResumable, isFalse);
  });

  test('a probe that itself fails reports the checkpoint as unusable',
      () async {
    final seen = <CheckpointAttemptFailure?>[];

    await runAppCheckpointRecovery(
      choose: (lastFailure) async {
        seen.add(lastFailure);
        return seen.length == 1 ? AppCheckpointRecoveryChoice.resume : null;
      },
      resume: () async => throw Exception('resume failed'),
      discard: () async {},
      checkpointStillResumable: () async => throw StateError('backend gone'),
    );

    expect(seen.last?.checkpointStillResumable, isFalse);
  });
}
