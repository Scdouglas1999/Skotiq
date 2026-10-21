// Startup checkpoint discovery, recovery dialog and close-confirmation helpers.
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

/// Render [error] as a sentence rather than as a Dart object.
///
/// `'$error'` on a plain `Exception` prints `Exception: <message>`, which is
/// how a raw runtime string ended up in the operator's startup modal.
@visibleForTesting
String describeCheckpointFailure(Object error) {
  final text = error is SkotiqError ? error.userMessage : '$error';
  final trimmed = text.trim();
  for (final prefix in const ['Exception: ', 'Bad state: ']) {
    if (trimmed.startsWith(prefix)) return trimmed.substring(prefix.length);
  }
  return trimmed;
}

const String kCatalogSetupSkippedSettingKey = 'catalog_setup_skipped';

/// File names the native `CheckpointManager` uses inside the checkpoint
/// directory (`native/skotiq_native/sequencer/src/checkpoint.rs`,
/// `CHECKPOINT_FILENAME` / `CHECKPOINT_BACKUP`). Only
/// [adoptLegacyGuiCheckpoint] needs them, and only to move a pre-existing pair
/// forward; if the native names ever change, the adoption quietly finds
/// nothing, which is the same outcome as not migrating at all.
const List<String> _kCheckpointFileNames = <String>[
  'skotiq_session.checkpoint',
  'skotiq_session.checkpoint.bak',
];

/// Directory the desktop GUI keeps its sequence-recovery checkpoint in.
///
/// Anchored to the folder that holds the *open database*, not the platform
/// application-support folder. Every Skotiq GUI on a machine shares one
/// support folder, so anchoring there offers a second instance — pointed at its
/// own database via `SKOTIQ_DATABASE_DIR` — the first instance's
/// interrupted run, and its Discard deletes the OTHER instance's recovery
/// state. On the database directory that is structurally impossible: a
/// checkpoint can only ever be found beside the database whose run wrote it.
///
/// The `checkpoints/` subfolder mirrors `resolveHostCheckpointDirectory` in
/// the headless host, so a GUI and a daemon sharing a database directory still
/// do not overwrite one another's file.
@visibleForTesting
Future<Directory> resolveGuiCheckpointDirectory({
  Future<File> Function() databaseFileResolver = resolveDefaultDatabaseFile,
}) async {
  final databaseFile = await databaseFileResolver();
  return Directory(
    '${databaseFile.parent.path}${Platform.pathSeparator}checkpoints',
  );
}

/// Carries a checkpoint written by a build that stored it in the application
/// support directory into [targetDir], so upgrading between a crash and the
/// next launch does not silently drop a resumable night.
///
/// Only performed when `SKOTIQ_DATABASE_DIR` is unset. In that default
/// layout there is exactly one database on the machine, so the legacy file
/// provably belongs to it — and [SingleInstanceLock] guarantees no other
/// Skotiq is running against it, so nothing can be moved out from under a
/// live process. With the override set, the legacy file may belong to any of
/// several databases; adopting it would re-create the cross-database mix-up
/// this guards against, so it is left alone (and ignored) instead.
///
/// Never throws: a failed adoption must not stop the app from configuring the
/// checkpoint directory it will write tonight's recovery data to.
@visibleForTesting
Future<void> adoptLegacyGuiCheckpoint({
  required Directory targetDir,
  Future<Directory> Function() legacyDirectoryResolver =
      resolveSkotiqDataDirectory,
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  final override = env[skotiqDatabaseDirEnv]?.trim();
  if (override != null && override.isNotEmpty) return;

  try {
    final legacyDir = await legacyDirectoryResolver();
    if (legacyDir.path == targetDir.path) return;

    for (final name in _kCheckpointFileNames) {
      final legacyFile =
          File('${legacyDir.path}${Platform.pathSeparator}$name');
      if (!await legacyFile.exists()) continue;
      final destination =
          File('${targetDir.path}${Platform.pathSeparator}$name');
      // An existing file at the destination is this database's own, newer
      // checkpoint; never let the legacy copy overwrite it.
      if (await destination.exists()) continue;
      await targetDir.create(recursive: true);
      await legacyFile.rename(destination.path);
    }
  } catch (_) {
    // Deliberately swallowed — see doc comment.
  }
}

@visibleForTesting
bool catalogSetupWasSkipped(String? persistedValue) =>
    persistedValue?.trim().toLowerCase() == 'true';

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
/// [remoteHost] is set when this app is a linked client of a remote rig. The
/// checkpoint is then the host's: the modal names the host, says that Resume
/// restarts the run there, and always offers "Leave it".
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
      : 'This checkpoint can no longer be resumed. Discard it to clear the '
          'prompt.';
  final colors = SkotiqColors.of(context);
  final ageMinutes = info.ageSeconds ~/ 60;
  final ageStr = ageMinutes < 60
      ? '${ageMinutes}m ago'
      : '${ageMinutes ~/ 60}h ${ageMinutes % 60}m ago';
  final integrationMins = (info.completedIntegrationSecs / 60).round();

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
                ? 'A sequence on $remoteHost was interrupted and can be '
                    'resumed there. Resume restarts the run on the rig, which '
                    'can move the mount right away. Leave it to decide later.'
                : 'A previous sequence was interrupted and can be resumed.',
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
                  '${info.completedExposures} frames '
                      '(${integrationMins}m integration)',
                ),
              ],
            ),
          ),
          if (failure != null) ...[
            const SizedBox(height: 16),
            SkotiqAlert(
              severity: SkotiqAlertSeverity.error,
              title: 'Recovery did not complete',
              message: '${describeCheckpointFailure(failure.error)}\n\n'
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
      // Offering "Retry Resume" for a checkpoint the backend has just reported
      // as no longer resumable gives a button that can only fail again.
      // Discard (and "Not now") remain.
      if (canRetry)
        SkotiqButton(
          onPressed: () => Navigator.of(context).pop(
            AppCheckpointRecoveryChoice.resume,
          ),
          label: failure == null ? 'Resume' : 'Retry Resume',
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
Future<void> runAppStartupChecks({
  required Future<AppStartupCheckpointOutcome> Function() checkCheckpoint,
  required Future<void> Function() checkCatalogs,
}) async {
  final checkpointOutcome = await checkCheckpoint();
  if (checkpointOutcome == AppStartupCheckpointOutcome.noRecovery ||
      checkpointOutcome == AppStartupCheckpointOutcome.discarded ||
      checkpointOutcome == AppStartupCheckpointOutcome.deferred) {
    await checkCatalogs();
  }
}

@visibleForTesting
bool appCloseHasActiveOperations({
  required bool sequenceOwnsHardware,
  required bool sessionBusy,
  required bool cameraBusy,
  required bool mountBusy,
  required bool flatWizardBusy,
  required bool autofocusBusy,
}) {
  return sequenceOwnsHardware ||
      sessionBusy ||
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
