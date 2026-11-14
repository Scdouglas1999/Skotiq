part of '../app_shell.dart';

enum AppStartupCheckpointOutcome {
  noRecovery,
  resumed,
  discarded,

  /// A remote client left the host's checkpoint untouched.
  deferred,
  failed,
}

enum AppCheckpointRecoveryChoice {
  resume,
  discard,

  /// Leave the checkpoint where it is. Offered up front only to a remote
  /// client, because the checkpoint belongs to the host: linking in must not
  /// force a choice between restarting the host's run and deleting its
  /// recovery state.
  later,
}

/// What a failed recovery attempt actually left behind.
///
/// [checkpointStillResumable] is re-read from the backend AFTER the failure, so
/// the modal states what is true now. Asserting unconditionally that "the
/// checkpoint is still available" puts a claim directly under the executor's
/// own `No valid checkpoint to resume from`, and one of the two must be wrong.
@visibleForTesting
class CheckpointAttemptFailure {
  final Object error;
  final bool checkpointStillResumable;

  const CheckpointAttemptFailure({
    required this.error,
    required this.checkpointStillResumable,
  });
}

/// Whether the linked host ([hostControl], null where the imaging host is
/// this process) has a run in flight. Its checkpoint is then that live run's,
/// so a client joining it is shown the run and is never offered to recover
/// it.
@visibleForTesting
Future<bool> hostRunHoldsCheckpoint(HostControlSession? hostControl) async =>
    hostControl != null && await hostControl.hostRunInFlight();

/// Whether launch offers to recover [info]'s run: only a run the app died
/// under. A run that was stopped, failed or ended early keeps its checkpoint
/// and is continued from History instead of being raised as an interruption.
///
/// Nor a run with nothing to recover (no frame taken) or one older than the
/// Continue Session window: a "Recover Sequence? (0 frames)" prompt for a
/// days-old checkpoint offers to restore nothing.
@visibleForTesting
bool offersCheckpointRecovery(CheckpointInfo? info, {DateTime? now}) =>
    info != null &&
    info.canResume &&
    info.wasInterrupted &&
    (info.completedExposures > 0 || info.completedIntegrationSecs > 0) &&
    checkpointAgeSeconds(info, now: now) <= kContinueSessionMaxAge.inSeconds;

/// How old [info]'s checkpoint is now, from its save time. A host that
/// reports a cached age keeps reporting the age it had when first read.
@visibleForTesting
int checkpointAgeSeconds(CheckpointInfo info, {DateTime? now}) {
  final age = (now ?? DateTime.now())
      .toUtc()
      .difference(info.timestamp.toUtc())
      .inSeconds;
  return age < 0 ? 0 : age;
}

/// The startup "Recover Sequence?" modal.
///
/// Top-level and [visibleForTesting] because its escape hatch is the thing that
/// keeps a failing recovery from wedging the whole app: the modal is
/// deliberately `barrierDismissible: false` (an interrupted run must be decided,
/// not swiped away), so with only Resume and Discard a backend that throws on
/// BOTH — a read-only checkpoint directory, a corrupt file — re-presents the
/// dialog forever with no way out. "Not now" appears only after an attempt has
/// actually failed, leaves the checkpoint on disk, and lets the operator into
/// the app to fix the cause.
///
/// Restore loads the interrupted run's sequence and progress and leaves it
/// ready; nothing moves until the operator presses Start.
///
/// [remoteHost] is set when this app is a linked client of a remote rig. The
/// checkpoint is then the host's: the modal names the host and always offers
/// "Leave it".
@visibleForTesting
Widget buildCheckpointRecoveryDialog({
  required BuildContext context,
  required CheckpointInfo info,
  required CheckpointAttemptFailure? failure,
  String? remoteHost,
}) {
  final isRemote = remoteHost != null;
  final canRetry = failure == null || failure.checkpointStillResumable;
  final aftermath = canRetry
      ? 'The checkpoint is still on disk. Retry, or discard it to start fresh.'
      : 'This checkpoint can no longer be restored. Discard it to clear the '
          'prompt.';
  final colors = SkotiqColors.of(context);
  final ageMinutes = checkpointAgeSeconds(info) ~/ 60;
  final ageStr = ageMinutes < 60
      ? '${ageMinutes}m ago'
      : '${ageMinutes ~/ 60}h ${ageMinutes % 60}m ago';
  final integration = DurationFormat.of(
    Duration(seconds: info.completedIntegrationSecs.round()),
    style: DurationStyle.short,
  );
  final frames = info.completedExposures;

  return AlertDialog(
    backgroundColor: colors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: SkotiqTokens.borderRadiusInline8,
      side: BorderSide(color: colors.border),
    ),
    title: Row(
      children: [
        Icon(
          SkotiqIcons.warning,
          size: 22,
          color: colors.warning,
        ),
        const SizedBox(width: 12),
        Text(
          'Recover Sequence?',
          style: TextStyle(color: colors.textPrimary),
        ),
      ],
    ),
    // The backend's failure text is arbitrary length and the modal is
    // barrier-locked, so content that cannot fit has to scroll: clipped at the
    // dialog's height ceiling it took the reason for the failure — and, on a
    // short window, the sequence facts the decision rests on — off the screen.
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isRemote
                ? 'A sequence on $remoteHost was interrupted. Restore loads '
                    'its sequence and progress on the rig. Nothing moves until '
                    'you press Start. Leave it to decide later.'
                : 'A previous sequence was interrupted. Restore loads its '
                    'sequence and progress. Nothing moves until you press '
                    'Start.',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: SkotiqTypography.fontSize13,
            ),
          ),
          const SizedBox(height: 16),
          SkotiqCard(
            variant: CardVariant.standard,
            borderRadius: SkotiqTokens.radiusInline8,
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _checkpointInfoRow(colors, 'Sequence', info.sequenceName),
                const SizedBox(height: 6),
                _checkpointInfoRow(colors, 'Saved', ageStr),
                const SizedBox(height: 6),
                _checkpointInfoRow(
                  colors,
                  'Completed',
                  '$frames ${frames == 1 ? 'frame' : 'frames'} '
                      '($integration integration)',
                ),
              ],
            ),
          ),
          if (failure != null) ...[
            const SizedBox(height: 16),
            SkotiqAlert(
              severity: SkotiqAlertSeverity.error,
              title: 'Recovery did not complete',
              message: '${userFacingError(failure.error)}\n\n'
                  '$aftermath',
            ),
          ],
        ],
      ),
    ),
    actions: [
      if (isRemote)
        SkotiqButton(
          onPressed: () => Navigator.of(context).pop(
            AppCheckpointRecoveryChoice.later,
          ),
          label: 'Leave it',
          variant: ButtonVariant.ghost,
        )
      else if (failure != null)
        SkotiqButton(
          onPressed: () => Navigator.of(context).pop(),
          label: 'Not now',
          variant: ButtonVariant.ghost,
        ),
      SkotiqButton(
        onPressed: () => Navigator.of(context).pop(
          AppCheckpointRecoveryChoice.discard,
        ),
        label: 'Discard',
        variant: ButtonVariant.destructive,
      ),
      // Offering "Retry restore" for a checkpoint the backend has just
      // reported as no longer resumable gives a button that can only fail
      // again. Discard (and "Not now") remain.
      if (canRetry)
        SkotiqButton(
          onPressed: () => Navigator.of(context).pop(
            AppCheckpointRecoveryChoice.resume,
          ),
          label: failure == null ? 'Restore' : 'Retry restore',
        ),
    ],
  );
}

Widget _checkpointInfoRow(SkotiqColors colors, String label, String value) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 80,
        child: Text(
          label,
          style: SkotiqTypography.labelSm.copyWith(color: colors.textMuted),
        ),
      ),
      Expanded(
        child: Text(
          value,
          style: SkotiqTypography.h6.copyWith(color: colors.textPrimary),
        ),
      ),
    ],
  );
}

@visibleForTesting
Future<AppStartupCheckpointOutcome> runAppCheckpointRecovery({
  required Future<AppCheckpointRecoveryChoice?> Function(
    CheckpointAttemptFailure? lastFailure,
  ) choose,
  required Future<void> Function() resume,
  required Future<void> Function() discard,
  required Future<bool> Function() checkpointStillResumable,
}) async {
  CheckpointAttemptFailure? lastFailure;
  while (true) {
    final choice = await choose(lastFailure);
    if (choice == null) return AppStartupCheckpointOutcome.failed;

    try {
      switch (choice) {
        case AppCheckpointRecoveryChoice.resume:
          await resume();
          return AppStartupCheckpointOutcome.resumed;
        case AppCheckpointRecoveryChoice.discard:
          await discard();
          return AppStartupCheckpointOutcome.discarded;
        case AppCheckpointRecoveryChoice.later:
          return AppStartupCheckpointOutcome.deferred;
      }
    } catch (error) {
      // Ask the backend what survived the attempt instead of assuming. A
      // resume that failed because the checkpoint is invalid must not be
      // followed by "the checkpoint is still available"; a probe that itself
      // fails is treated as "cannot be resumed", the conservative reading.
      var stillResumable = false;
      try {
        stillResumable = await checkpointStillResumable();
      } catch (_) {
        stillResumable = false;
      }
      lastFailure = CheckpointAttemptFailure(
        error: error,
        checkpointStillResumable: stillResumable,
      );
    }
  }
}

@visibleForTesting
bool appCloseHasActiveOperations({
  required bool sequenceOwnsHardware,
  required bool sessionBusy,
  required Phd2State guider,
  required bool cameraBusy,
  required bool mountBusy,
  required bool flatWizardBusy,
  required bool autofocusBusy,
}) {
  return sequenceOwnsHardware ||
      sessionBusy ||
      guider.inGuideSession ||
      cameraBusy ||
      mountBusy ||
      flatWizardBusy ||
      autofocusBusy;
}

/// An unavailable close preference is not an opt-out. When hardware is active,
/// only a successfully loaded, explicit `false` may bypass confirmation.
@visibleForTesting
bool appCloseShouldConfirm({
  required bool hasActiveOperations,
  required bool? confirmBeforeClosing,
}) {
  return hasActiveOperations && confirmBeforeClosing != false;
}
