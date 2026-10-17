import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../utils/startup_surface_coordinator.dart';
import '../utils/startup_ui_context.dart';

/// Surfaces a one-shot dialog telling the user "your database was corrupted
/// and recovered from backup" on the first launch after the SQLite
/// integrity-check pre-flight rotated a corrupt `skotiq.db` into a
/// `skotiq-corrupt-<ts>.db` forensic backup.
///
/// Why a wrapper widget rather than an inline call in `desktop_app_bootstrap`:
/// the marker file must be consumed inside the Flutter widget tree because
/// (a) we need a [BuildContext] to push the dialog and (b) we don't want to
/// block startup behind an awaited dialog. Mirroring the pattern used by
/// [FirstNightWizardLauncher] keeps the launcher stack uniform — all
/// startup-triggered dialogs live in `widgets/*_launcher.dart`.
class DatabaseRecoveryLauncher extends ConsumerStatefulWidget {
  final Widget child;

  /// Optional override used by tests so the launcher can read the marker
  /// from a temp directory instead of the real `resolveSkotiqDocumentsDirectory()`.
  final Future<DatabaseRecoveryMarker?> Function()? markerConsumer;

  /// Optional acknowledgement hook for a non-consuming [markerConsumer].
  /// When omitted alongside a custom consumer, the consumer is treated as the
  /// legacy read-and-delete operation.
  final Future<void> Function(DatabaseRecoveryMarker marker)?
      markerAcknowledger;

  /// Re-checks the quarantined file so the dialog can describe it honestly.
  /// Overridable so tests do not have to stage a real database on disk.
  final Future<QuarantinedDatabaseCheck> Function(String backupPath)?
      quarantineInspector;

  /// Stages the quarantined file to be swapped back in on the next launch.
  final Future<void> Function(String backupPath)? restoreStager;

  const DatabaseRecoveryLauncher({
    super.key,
    required this.child,
    this.markerConsumer,
    this.markerAcknowledger,
    this.quarantineInspector,
    this.restoreStager,
  });

  @override
  ConsumerState<DatabaseRecoveryLauncher> createState() =>
      _DatabaseRecoveryLauncherState();
}

class _DatabaseRecoveryLauncherState
    extends ConsumerState<DatabaseRecoveryLauncher> {
  bool _hasReadMarker = false;
  bool _surfaceQueued = false;
  bool _dialogShown = false;
  DatabaseRecoveryMarker? _pendingMarker;
  Timer? _deferTimer;
  bool _restoreStaged = false;
  String? _restoreError;

  @override
  void initState() {
    super.initState();
    // Post-frame so the navigator is laid out before we push the dialog.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleCheck());
  }

  @override
  void dispose() {
    _deferTimer?.cancel();
    super.dispose();
  }

  void _scheduleCheck() {
    if (!mounted || _pendingMarker == null && _hasReadMarker) return;
    // Defer slightly so this dialog wins over the first-night wizard but
    // does not collide with the splash transition. 600 ms matches the
    // observed window between MaterialApp first frame and the router's
    // initial route settling.
    _deferTimer = Timer(const Duration(milliseconds: 600), _maybeShow);
  }

  Future<void> _maybeShow() async {
    if (!mounted || _surfaceQueued) return;

    if (!_hasReadMarker) {
      _hasReadMarker = true;
      final consumer =
          widget.markerConsumer ?? SkotiqDatabase.readRecoveryMarker;
      try {
        _pendingMarker = await consumer();
      } catch (e) {
        // This marker is how the operator learns their database was rebuilt
        // and data may be missing. A read that keeps failing retries forever
        // and the notice never appears, so the failure must be recorded —
        // otherwise a recovered database looks exactly like a healthy one.
        developer.log(
          'Could not read the database recovery marker; the recovery notice '
          'will not be shown until a retry succeeds: $e',
          name: 'DatabaseRecovery',
          level: 1000,
        );
        if (!mounted) return;
        _hasReadMarker = false;
        _scheduleRetry();
        return;
      }
    }
    if (!mounted || _pendingMarker == null) return;

    if (_dialogShown) {
      await _acknowledgePendingMarker();
      return;
    }

    _surfaceQueued = true;
    // Re-check the quarantined file BEFORE writing any copy about it. Builds
    // before the result-code fix quarantined healthy databases whenever the
    // open failed for any reason at all — a second instance holding the file,
    // a hot journal after a crash — and then told the user their data was
    // corrupt. The file being named `skotiq-corrupt-*` is not evidence.
    final backupPath = _pendingMarker!.backupPath;
    QuarantinedDatabaseCheck? check;
    if (backupPath != null) {
      final inspect = widget.quarantineInspector ??
          SkotiqDatabase.inspectQuarantinedDatabase;
      try {
        check = await inspect(backupPath);
      } catch (e) {
        // Unverifiable is its own honest answer; the dialog says so rather
        // than guessing in either direction.
        developer.log(
          'Could not re-check the quarantined database at $backupPath: $e',
          name: 'DatabaseRecovery',
          level: 900,
        );
      }
      if (!mounted) return;
    }
    final shown = await _showRecoveryDialog(_pendingMarker!, check);
    if (!mounted) return;
    _surfaceQueued = false;
    if (!shown) {
      _scheduleRetry();
      return;
    }
    _dialogShown = true;
    await _acknowledgePendingMarker();
  }

  Future<bool> _showRecoveryDialog(
    DatabaseRecoveryMarker marker,
    QuarantinedDatabaseCheck? check,
  ) {
    return ref.read(startupSurfaceCoordinatorProvider).run(() async {
      if (!mounted) return false;
      final uiContext = resolveStartupUiContext(ref, context);
      if (uiContext == null || !uiContext.mounted) return false;
      final canRestore = check?.canRestore == true;
      await showDialog<void>(
        context: uiContext,
        barrierDismissible: false,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              if (_restoreStaged) {
                return _buildRestoreStagedDialog(ctx);
              }
              return AlertDialog(
                title: Text(_dialogTitle(check)),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_dialogExplanation(check)),
                      const SizedBox(height: 12),
                      Text(_dialogNextStep(check)),
                      const SizedBox(height: 16),
                      if (marker.backupPath != null) ...[
                        const Text('Backup file:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        SelectableText(marker.backupPath!),
                        const SizedBox(height: 8),
                      ],
                      if (check != null && check.exists) ...[
                        Text(
                          check.integrityOk
                              ? 'Re-checked just now: SQLite reports this file '
                                  'as healthy.'
                              : 'Re-checked just now: SQLite still cannot read '
                                  'this file.',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: check.integrityOk
                                ? Theme.of(ctx).colorScheme.primary
                                : Theme.of(ctx).colorScheme.error,
                          ),
                        ),
                        if (check.detail != null) SelectableText(check.detail!),
                        const SizedBox(height: 8),
                      ],
                      if (marker.reason != null) ...[
                        const Text('What Skotiq reported at the time:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        SelectableText(marker.reason!),
                      ],
                      if (_restoreError != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Could not stage the restore: $_restoreError',
                          style: TextStyle(
                            color: Theme.of(ctx).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text(canRestore ? 'Keep the new database' : 'OK'),
                  ),
                  if (canRestore)
                    FilledButton(
                      onPressed: () async {
                        // Success swaps this dialog for the restart notice;
                        // failure re-renders it with the reason attached.
                        await _stageRestore(marker.backupPath!);
                        setDialogState(() {});
                      },
                      child: const Text('Restore my database'),
                    ),
                ],
              );
            },
          );
        },
      );
      return true;
    });
  }

  Widget _buildRestoreStagedDialog(BuildContext ctx) {
    return AlertDialog(
      title: const Text('Restart to finish restoring'),
      content: const SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Skotiq will put your previous database back the next time '
              'it starts. The swap cannot happen now because the app already '
              'has the current database open.',
            ),
            SizedBox(height: 12),
            Text(
              'Close Skotiq and start it again. The database you are '
              'using right now is kept alongside the restored one, so nothing '
              'is thrown away either way.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK'),
        ),
      ],
    );
  }

  /// The wording is keyed on what the file turned out to be, because calling
  /// a healthy database "corrupted" is how a user gets talked out of the data
  /// they still have.
  String _dialogTitle(QuarantinedDatabaseCheck? check) {
    if (check != null && check.canRestore) {
      return 'Skotiq started with a new database';
    }
    return 'Database recovered';
  }

  String _dialogExplanation(QuarantinedDatabaseCheck? check) {
    if (check != null && check.canRestore) {
      return 'Skotiq could not open your database when it last started, '
          'so it set that file aside and started with a new, empty one. '
          'Your settings, profiles, sessions and captures are not in the '
          'database you are using now.';
    }
    if (check != null && check.exists) {
      return 'Skotiq detected that your database file was corrupted '
          'and recreated a fresh one so the app could start. Your '
          'existing settings, profiles, sessions, and captures from '
          'before the corruption are NOT in the new database.';
    }
    return 'Skotiq could not open your database when it last started and '
        'recreated a fresh one so the app could start. Your existing '
        'settings, profiles, sessions and captures are not in the new '
        'database.';
  }

  String _dialogNextStep(QuarantinedDatabaseCheck? check) {
    if (check != null && check.canRestore) {
      return 'The file that was set aside has just been re-checked and it is '
          'intact — it was not corrupt. You can put it back, which replaces '
          'the database you are using now (that one is kept too).';
    }
    if (check != null && check.exists) {
      return 'A backup of the corrupt file has been retained on disk '
          'so support engineers can recover what is salvageable. '
          'Please contact support if you need help extracting '
          'historical data.';
    }
    return 'A backup of the file was retained on disk so support engineers '
        'can recover what is salvageable. Please contact support if you need '
        'help extracting historical data.';
  }

  Future<void> _stageRestore(String backupPath) async {
    final stage =
        widget.restoreStager ?? SkotiqDatabase.stageDatabaseRestore;
    try {
      await stage(backupPath);
      _restoreStaged = true;
      _restoreError = null;
    } catch (e) {
      // The user asked for their data back and did not get it. Saying so in
      // the dialog matters more than the log line: a silently ignored
      // Restore looks identical to one that worked until the next launch.
      developer.log(
        'Could not stage a restore of $backupPath: $e',
        name: 'DatabaseRecovery',
        level: 1000,
      );
      _restoreError = '$e';
    }
  }

  Future<void> _acknowledgePendingMarker() async {
    final marker = _pendingMarker;
    if (marker == null) return;
    final acknowledge = widget.markerAcknowledger ??
        (widget.markerConsumer == null
            ? SkotiqDatabase.acknowledgeRecoveryMarker
            : null);
    if (acknowledge == null) {
      _pendingMarker = null;
      return;
    }
    try {
      await acknowledge(marker);
      if (mounted) _pendingMarker = null;
    } catch (e) {
      // An unacknowledged marker re-surfaces the recovery dialog on every
      // launch. Harmless on its own, but a permanently failing acknowledge
      // means the marker store is unwritable, which is worth knowing before
      // the next recovery needs to record one.
      developer.log(
        'Could not acknowledge the database recovery marker; the notice will '
        'be shown again: $e',
        name: 'DatabaseRecovery',
        level: 900,
      );
      if (mounted) _scheduleRetry();
    }
  }

  /// Retry backoff over two failure modes. The ordinary one is another startup
  /// surface holding the dialog slot, which clears in a second or two, so the
  /// first attempts stay fast. The pathological one is a marker store that
  /// cannot be read at all: a flat 100 ms there is an unbounded hot loop for
  /// the life of a process expected to run all night, so it backs off to a slow
  /// poll.
  ///
  /// It keeps polling rather than giving up: this notice is how the operator
  /// learns their database was rebuilt and data may be missing, so abandoning
  /// it silently would be worse than the delay.
  static const _retryFloor = Duration(milliseconds: 100);
  static const _retryCeiling = Duration(seconds: 5);
  int _retryAttempt = 0;

  void _scheduleRetry() {
    _deferTimer?.cancel();
    final backoff = _retryFloor * (1 << _retryAttempt.clamp(0, 6));
    final delay = backoff > _retryCeiling ? _retryCeiling : backoff;
    if (delay == _retryCeiling && _retryAttempt == 6) {
      developer.log(
        'Database recovery notice still cannot be surfaced after '
        '$_retryAttempt attempts; continuing to poll every '
        '${_retryCeiling.inSeconds}s.',
        name: 'DatabaseRecovery',
        level: 900,
      );
    }
    _retryAttempt++;
    _deferTimer = Timer(delay, _maybeShow);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
