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
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart' show NetworkBackend, SequencerBackend;
import 'package:skotiq_core/models.dart'
    show BackendErrorCategory, CheckpointInfo, SkotiqError;
import 'package:skotiq_core/errors.dart' show userFacingError;
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockHost extends Mock implements NetworkBackend {}

class _MockLocal extends Mock implements SequencerBackend {}

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
  CheckpointInfo? info,
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
                info: info ?? _info,
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

    expect(find.text('Restore'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);
    expect(
      find.text('Not now'),
      findsNothing,
      reason: 'an interrupted run is decided up front; the escape exists only '
          'for a recovery that has already failed',
    );
  });

  // Restoring loads the run and waits for Start; the text says so, so a
  // daytime press cannot be mistaken for starting the night again.
  testWidgets('the prompt says that restoring does not start the run', (
    tester,
  ) async {
    await showRecoveryDialog(tester, failure: null);

    expect(
      find.textContaining('Restore loads its sequence and progress'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Nothing moves until you press Start'),
      findsOneWidget,
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
    expect(
      find.textContaining('Nothing moves until you press Start'),
      findsOneWidget,
    );
    expect(find.text('Restore'), findsOneWidget);
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

    expect(find.text('Retry restore'), findsOneWidget);
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
      find.textContaining('This checkpoint can no longer be restored'),
      findsOneWidget,
    );
    expect(
      find.text('Retry restore'),
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
        userFacingError(Exception('checkpoint is corrupt')),
        'checkpoint is corrupt',
      );
    });

    test('prefers the operator-facing message of a SkotiqError', () {
      expect(
        userFacingError(const SkotiqError(
            category: BackendErrorCategory.connection,
            message: 'ipc channel closed while resuming',
            userMessage: 'The imaging host stopped responding.',
          )),
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

  testWidgets('the counts read as the run reached them, in plain units', (
    tester,
  ) async {
    await showRecoveryDialog(tester, failure: null);
    expect(find.text('6 frames (18m integration)'), findsOneWidget);
  });

  testWidgets('one 30 s frame is one frame of 30 s, not "1 frames (1m)"', (
    tester,
  ) async {
    await showRecoveryDialog(
      tester,
      failure: null,
      info: CheckpointInfo(
        sequenceName: 'Smart Night',
        timestamp: DateTime(2026, 11, 1, 11, 59),
        completedExposures: 1,
        completedIntegrationSecs: 30,
        canResume: true,
        ageSeconds: 60,
      ),
    );
    expect(find.text('1 frame (30s integration)'), findsOneWidget);
  });

  test('only a run the app died under is offered at launch', () {
    CheckpointInfo info({String? ended, bool canResume = true}) =>
        CheckpointInfo(
          sequenceName: 'QA M45 pair',
          timestamp: DateTime.utc(2026, 11, 1, 16),
          completedExposures: 5,
          completedIntegrationSecs: 50,
          canResume: canResume,
          ageSeconds: 60,
          ended: ended,
        );
    final now = DateTime.utc(2026, 11, 1, 18);
    bool offers(CheckpointInfo? i) => offersCheckpointRecovery(i, now: now);
    expect(offers(info()), isTrue);
    expect(offers(info(ended: 'stopped')), isFalse);
    expect(offers(info(ended: 'failed')), isFalse);
    expect(offers(info(ended: 'ended_early')), isFalse);
    expect(offers(info(canResume: false)), isFalse);
    expect(offers(null), isFalse);
  });

  test('a stale or empty checkpoint is not offered', () {
    // A linked client showed "Recover Sequence? (0 frames)", and the rig a
    // run from days before.
    CheckpointInfo info({int frames = 5, required DateTime saved}) =>
        CheckpointInfo(
          sequenceName: 'Rig test NGC 7331',
          timestamp: saved,
          completedExposures: frames,
          completedIntegrationSecs: frames * 60.0,
          canResume: true,
          ageSeconds: 0,
        );
    final now = DateTime.utc(2026, 11, 8, 21);
    final lastNight = DateTime.utc(2026, 11, 8, 6);
    expect(offersCheckpointRecovery(info(saved: lastNight), now: now), isTrue);
    expect(
      offersCheckpointRecovery(info(frames: 0, saved: lastNight), now: now),
      isFalse,
    );
    expect(
      offersCheckpointRecovery(
        info(saved: now.subtract(const Duration(days: 8))),
        now: now,
      ),
      isFalse,
    );
  });

  test('the age comes from the save time, not from an age the host cached', () {
    final info = CheckpointInfo(
      sequenceName: 'M74 Plan',
      timestamp: DateTime.utc(2026, 10, 31, 9, 27, 27),
      completedExposures: 120,
      completedIntegrationSecs: 3600,
      canResume: true,
      ageSeconds: 104402,
    );
    final age = checkpointAgeSeconds(
      info,
      now: DateTime.utc(2026, 11, 1, 16, 16, 27),
    );
    expect(age, 30 * 3600 + 49 * 60);
  });

  test(
      'a host running its sequence holds its checkpoint; an idle host or '
      'this machine does not', () async {
    final running = _MockHost();
    when(() => running.hostRunInFlight()).thenAnswer((_) async => true);
    final idle = _MockHost();
    when(() => idle.hostRunInFlight()).thenAnswer((_) async => false);

    expect(await hostRunHoldsCheckpoint(running), isTrue);
    expect(await hostRunHoldsCheckpoint(idle), isFalse);
    expect(await hostRunHoldsCheckpoint(_MockLocal()), isFalse);
  });
}
