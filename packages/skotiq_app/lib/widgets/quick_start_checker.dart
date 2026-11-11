import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../utils/authority_bound_dialog.dart';
import '../startup/startup_surface_queue.dart';
import '../utils/startup_ui_context.dart';
import 'quick_start_dialog.dart';
import 'session_recovery_dialog.dart';

/// Widget that checks for quick start opportunities on app startup.
///
/// This widget wraps the app and on first frame:
/// 1. First checks for crashed/interrupted sessions (recovery takes priority)
/// 2. Then checks for recent completed sessions (quick start opportunity)
///
/// Shows appropriate dialog based on what's found.
class QuickStartChecker extends ConsumerStatefulWidget {
  final Widget child;

  const QuickStartChecker({
    super.key,
    required this.child,
  });

  @override
  ConsumerState<QuickStartChecker> createState() => _QuickStartCheckerState();
}

class _QuickStartCheckerState extends ConsumerState<QuickStartChecker> {
  bool _hasChecked = false;
  bool _recheckScheduled = false;
  late final StartupSurfaceQueue _queue;

  @override
  void initState() {
    super.initState();
    _queue = ref.read(startupSurfaceQueueProvider)
      ..expect(StartupSurface.interruptedSession)
      ..expect(StartupSurface.quickStart);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForStartupOptions();
    });
  }

  @override
  void dispose() {
    _passBoth();
    super.dispose();
  }

  void _passBoth() {
    _queue
      ..pass(StartupSurface.interruptedSession)
      ..pass(StartupSurface.quickStart);
  }

  /// Runs one pass of the check. Whatever it found, both surfaces have had
  /// their turn when it returns, so the prompts after them never wait on a
  /// check that ended early.
  Future<void> _checkForStartupOptions() async {
    try {
      await _checkSessions();
    } finally {
      _passBoth();
    }
  }

  Future<CheckpointInfo?> _continuableCheckpoint(SkotiqBackend host) async {
    try {
      return await host.getCheckpointInfo();
    } catch (_) {
      return null;
    }
  }

  Future<void> _checkSessions() async {
    if (_hasChecked || !mounted) return;

    _hasChecked = true;
    final host = ref.backendScope(alive: () => mounted);

    try {
      // A client joining a host mid-run is shown the live run. The host's
      // open session belongs to that run, and restoring a setup would move
      // the host's devices under it.
      final hostControl = host.value.remoteHost?.control;
      if (hostControl != null && await hostControl.hostRunInFlight()) {
        ref.read(loggingServiceProvider).info(
              'The imaging host is running a sequence; skipping the startup '
              'session prompts',
              source: 'QuickStart',
            );
        return;
      }
      if (!mounted) return;

      // The host's own screen decides on its sessions; a client neither
      // resumes nor discards them.
      if (host.value.remoteHost != null) return;

      // First priority: Check for crashed/interrupted sessions. The session
      // of a run whose checkpoint can be continued is that run: the checkpoint
      // prompt or History continues it, so it is not raised a second time.
      final incompleteSessions = withoutCheckpointedRun(
        await ref.read(incompleteSessionsProvider.future),
        await _continuableCheckpoint(host.value),
      );

      if (!mounted) return;
      if (host.isStale) {
        _scheduleRecheck();
        return;
      }

      if (incompleteSessions.isNotEmpty && mounted) {
        if (mounted && host.isCurrent) {
          final uiContext = _uiContext;
          if (uiContext == null || !uiContext.mounted) {
            _scheduleRecheck();
            return;
          }
          await _showStartupDialog<void>(
            surface: StartupSurface.interruptedSession,
            host: host,
            context: uiContext,
            barrierDismissible: false,
            builder: (context) => SessionRecoveryDialog(
              incompleteSessions: incompleteSessions,
            ),
          );
        }
        if (mounted && host.isStale) {
          _scheduleRecheck();
        }
        return;
      }

      _queue.pass(StartupSurface.interruptedSession);

      // Second priority: Check for quick start opportunity. Never on a
      // companion (returned above): restoring a previous setup moves the
      // imaging host's focuser and filter wheel and changes its cooler, and the
      // host may be in the middle of a run.
      final quickStartContext =
          await ref.read(quickStartContextProvider.future);

      if (!mounted) return;
      if (host.isStale) {
        _scheduleRecheck();
        return;
      }

      // A run started while the earlier prompts were up (from a client, the
      // API or a schedule) is not to be offered a restore over it.
      final runInProgress = !ref.read(sequenceExecutionStateProvider).canStart;
      if (quickStartContext != null &&
          !runInProgress &&
          quickStartContext.isRecent &&
          !sessionIsFinished(quickStartContext) &&
          mounted) {
        if (mounted && host.isCurrent) {
          final uiContext = _uiContext;
          if (uiContext == null || !uiContext.mounted) {
            _scheduleRecheck();
            return;
          }
          await _showStartupDialog<void>(
            surface: StartupSurface.quickStart,
            host: host,
            context: uiContext,
            builder: (dialogContext) => QuickStartDialog(
              quickStartContext: quickStartContext,
              onStartFresh: () {
                Navigator.of(dialogContext).pop();
                unawaited(_handleStartFresh(quickStartContext, host));
              },
              onResumeProgress: () {
                Navigator.of(dialogContext).pop();
                unawaited(_handleResumeProgress(quickStartContext, host));
              },
              onSkip: () {
                Navigator.of(dialogContext).pop();
                ref.read(loggingServiceProvider).info(
                      'User skipped quick start',
                      source: 'QuickStart',
                    );
              },
            ),
          );
        }
        if (mounted && host.isStale) {
          _scheduleRecheck();
        }
      }
    } catch (e, st) {
      if (mounted && host.isStale) {
        _scheduleRecheck();
        return;
      }
      ref.read(loggingServiceProvider).warning(
        'Error checking startup options: $e',
        source: 'QuickStart',
        fields: {'stackTrace': st.toString()},
      );
      if (!mounted) return;

      // Recovery discovery is data-protection work, not an ignorable
      // background refresh. Keep the app usable, but make the uncertainty
      // explicit and give the operator a one-tap retry. Do not continue into
      // Quick Start after this failure: that would imply the recovery scan
      // completed and found nothing.
      final uiContext = _uiContext;
      final messenger = uiContext != null && uiContext.mounted
          ? ScaffoldMessenger.maybeOf(uiContext)
          : null;
      messenger?.clearSnackBars();
      messenger?.showSnackBar(
        SnackBar(
          content: const Text(
            'Skotiq could not check for an interrupted imaging session. '
            'Recovery status is unknown.',
          ),
          duration: const Duration(days: 1),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () {
              _hasChecked = false;
              ref.invalidate(incompleteSessionsProvider);
              unawaited(_checkForStartupOptions());
            },
          ),
        ),
      );
    }
  }

  BuildContext? get _uiContext => resolveStartupUiContext(ref, context);

  void _scheduleRecheck() {
    if (!mounted || _recheckScheduled) return;
    _recheckScheduled = true;
    _hasChecked = false;
    ref.invalidate(incompleteSessionsProvider);
    ref.invalidate(quickStartContextProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recheckScheduled = false;
      if (mounted) unawaited(_checkForStartupOptions());
    });
  }

  Future<T?> _showStartupDialog<T>({
    required StartupSurface surface,
    required AsyncScope<SkotiqBackend> host,
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) async {
    return _queue.turn<T?>(surface, () async {
      if (!mounted || !context.mounted || host.isStale) {
        return null;
      }
      // The prompt waited its turn behind other startup prompts; a run that
      // started meanwhile means there is no past run to act on.
      if (!ref.read(sequenceExecutionStateProvider).canStart) return null;
      if (_queue.alreadyAnswered(surface)) {
        ref.read(loggingServiceProvider).info(
              'Not raising ${surface.name}: an earlier startup prompt already '
              'settled the interrupted run',
              source: 'QuickStart',
            );
        return null;
      }

      BuildContext? dialogContext;
      // A startup prompt offers to continue or restore a past run; once a
      // run starts it is not one to act on, so the prompt closes itself.
      final runStarted = ref.listenManual<SequenceExecutionState>(
        sequenceExecutionStateProvider,
        (previous, next) {
          final routeContext = dialogContext;
          if (!next.canStart && routeContext != null && routeContext.mounted) {
            closeAuthorityBoundDialog(routeContext);
          }
        },
      );
      try {
        return await showHostBoundDialog<T>(
          context: context,
          ref: ref,
          barrierDismissible: barrierDismissible,
          builder: (routeContext) {
            dialogContext = routeContext;
            return builder(routeContext);
          },
        );
      } finally {
        runStarted.close();
      }
    });
  }

  void _showHostChanged() {
    if (!mounted) return;
    final uiContext = _uiContext;
    if (uiContext == null) return;
    ScaffoldMessenger.of(uiContext).showSnackBar(
      const SnackBar(
        content: Text(
          'The imaging host changed. Quick Start was canceled.',
        ),
      ),
    );
  }

  Future<void> _handleStartFresh(
    QuickStartContext context,
    AsyncScope<SkotiqBackend> host,
  ) async {
    if (host.isStale) {
      _showHostChanged();
      return;
    }
    final logger = ref.read(loggingServiceProvider);
    logger.info(
      'Starting fresh with context: ${context.displayDescription}',
      source: 'QuickStart',
    );

    try {
      if (context.canResumeFromCheckpoint) {
        await host.value.discardCheckpoint();
        if (host.isStale) return;
        logger.info(
          'Discarded resumable checkpoint before loading a fresh setup',
          source: 'QuickStart',
        );
      }

      // Report what was genuinely re-applied, in the operator's words. A
      // session row carrying no profile id, no sequence id and no equipment
      // snapshot gives this handler nothing to do, so an unconditional success
      // snackbar would announce a restore over a no-op.
      final restored = <String>[];

      if (context.profileId != null) {
        final profilesNotifier = ref.read(equipmentProfilesProvider.notifier);
        await profilesNotifier.setActiveProfile(context.profileId!);
        if (host.isStale) return;
        restored.add('equipment profile');
        logger.info('Activated profile ${context.profileId}',
            source: 'QuickStart');
      }

      // Load the sequence (reset to beginning)
      if (context.sequenceId != null) {
        final sequence = await ref
            .read(sequenceRepositoryProvider)
            .loadSequence(context.sequenceId!);
        if (host.isStale) return;
        if (sequence != null) {
          ref
              .read(currentSequenceProvider.notifier)
              .loadSequence(sequence, discardUnsaved: true);
          restored.add('sequence');
          logger.info(
            'Loaded sequence ${context.sequenceId}, reset to frame 1',
            source: 'QuickStart',
          );
        }
      }

      final snapshotResult = await _applyEquipmentSnapshot(
        context.equipmentSnapshot,
        host,
      );
      if (host.isStale) return;
      restored.addAll(snapshotResult.applied);
      final failures = snapshotResult.failures;

      if (restored.isEmpty) {
        logger.warning(
          'Load Previous Setup had nothing to restore for session '
          '${context.sessionId}: no profile id, no sequence id and no usable '
          'equipment snapshot were recorded',
          source: 'QuickStart',
        );
      }

      final uiContext = _uiContext;
      if (mounted && uiContext != null && uiContext.mounted) {
        final colors = SkotiqColors.of(uiContext);
        final target = context.targetName ?? 'previous target';
        final String message;
        final Color background;
        if (restored.isEmpty && failures.isEmpty) {
          message = 'Nothing to load: that session recorded no equipment '
              'profile, no sequence and no camera settings.';
          background = colors.warning;
        } else {
          final base = restored.isEmpty
              ? 'Could not load the previous setup for $target'
              : 'Loaded ${restored.join(', ')} for $target from frame 1';
          message = failures.isEmpty
              ? base
              : '$base, but could not restore: ${failures.join(', ')}';
          background = failures.isEmpty && restored.isNotEmpty
              ? colors.success
              : colors.warning;
        }
        ScaffoldMessenger.of(uiContext).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: background,
          ),
        );
      }
    } catch (e, st) {
      if (host.isStale) return;
      // Caught + surfaced to user via SnackBar; the failure is not fatal but
      // is user-visible, so log as error and include stack for diagnostics.
      ref.read(loggingServiceProvider).error(
        'Error starting fresh: $e',
        source: 'QuickStart',
        fields: {'stackTrace': st.toString()},
      );
      final uiContext = _uiContext;
      if (mounted && uiContext != null && uiContext.mounted) {
        final colors = SkotiqColors.of(uiContext);
        ScaffoldMessenger.of(uiContext).showSnackBar(
          SnackBar(
            content: Text('Failed to start fresh: ${userFacingError(e)}'),
            backgroundColor: colors.error,
          ),
        );
      }
    }
  }

  Future<void> _handleResumeProgress(
    QuickStartContext context,
    AsyncScope<SkotiqBackend> host,
  ) async {
    if (host.isStale) {
      _showHostChanged();
      return;
    }
    final logger = ref.read(loggingServiceProvider);
    final executor = ref.read(sequenceExecutorProvider);
    logger.info(
      'Resuming progress with context: ${context.displayDescription}',
      source: 'QuickStart',
    );

    try {
      if (!context.canResumeFromCheckpoint) {
        throw StateError('No resumable execution checkpoint is available');
      }

      if (context.profileId != null) {
        final profilesNotifier = ref.read(equipmentProfilesProvider.notifier);
        await profilesNotifier.setActiveProfile(context.profileId!);
        if (host.isStale) return;
        logger.info('Activated profile ${context.profileId}',
            source: 'QuickStart');
      }

      // The executor restores the checkpointed sequence, its progress, runtime
      // state and device mapping, and the run waits for Start. Nothing moves
      // from this dialog.
      await executor.restoreFromCheckpoint();
      if (host.isStale) return;

      final uiContext = _uiContext;
      if (mounted && uiContext != null && uiContext.mounted) {
        final colors = SkotiqColors.of(uiContext);
        final message =
            'Restored ${context.targetName ?? "the previous run"} at frame '
            '${context.completedFrames}. Nothing moves until you press Start.';
        ScaffoldMessenger.of(uiContext).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: colors.success,
          ),
        );
      }
    } catch (e, st) {
      if (host.isStale) return;
      // Caught + surfaced to user via SnackBar; the failure is not fatal but
      // is user-visible, so log as error and include stack for diagnostics.
      ref.read(loggingServiceProvider).error(
        'Error resuming progress: $e',
        source: 'QuickStart',
        fields: {'stackTrace': st.toString()},
      );
      final uiContext = _uiContext;
      if (mounted && uiContext != null && uiContext.mounted) {
        final colors = SkotiqColors.of(uiContext);
        ScaffoldMessenger.of(uiContext).showSnackBar(
          SnackBar(
            content: Text('Failed to resume progress: ${userFacingError(e)}'),
            backgroundColor: colors.error,
          ),
        );
      }
    }
  }

  /// Applies the snapshot best-effort and reports both what was restored and
  /// what failed, so callers can describe the outcome instead of asserting one.
  Future<_SnapshotRestore> _applyEquipmentSnapshot(
    EquipmentSnapshot? snapshot,
    AsyncScope<SkotiqBackend> host,
  ) async {
    final logger = ref.read(loggingServiceProvider);
    if (snapshot == null || !snapshot.hasEquipmentData) {
      logger.info('No equipment snapshot to apply', source: 'QuickStart');
      return const _SnapshotRestore();
    }

    logger.info('Applying equipment snapshot...', source: 'QuickStart');

    final applied = <String>[];
    final failures = <String>[];
    if (host.isStale || host.value.remoteHost != null) {
      return _SnapshotRestore(applied: applied, failures: failures);
    }

    final cameraNotifier = ref.read(cameraStateProvider.notifier);
    if (snapshot.coolerTargetTemp != null) {
      cameraNotifier.setTargetTemp(snapshot.coolerTargetTemp!);
      applied.add('cooler setpoint');
      logger.info(
        'Set cooler target temp to ${snapshot.coolerTargetTemp}',
        source: 'QuickStart',
      );
    }

    // Restore gain/offset into the exposure controls and mark them dirty so the
    // profile sync does not overwrite the restored values on the next build.
    if (snapshot.cameraGain != null || snapshot.cameraOffset != null) {
      final exposure = ref.read(exposureSettingsProvider);
      ref.read(manualExposureSettingsUpdaterProvider).update(
            exposure.copyWith(
              gain: snapshot.cameraGain ?? exposure.gain,
              offset: snapshot.cameraOffset ?? exposure.offset,
            ),
          );
      applied.add('gain/offset');
      logger.info(
        'Restored gain ${snapshot.cameraGain} / offset ${snapshot.cameraOffset}',
        source: 'QuickStart',
      );
    }

    if (snapshot.filterPosition != null) {
      if (host.isStale) {
        return _SnapshotRestore(applied: applied, failures: failures);
      }
      final filterWheelState = ref.read(filterWheelStateProvider);
      if (filterWheelState.connectionState == DeviceConnectionState.connected) {
        final deviceService = ref.read(deviceServiceProvider);
        try {
          await deviceService.setFilterWheelPosition(snapshot.filterPosition!);
          applied.add('filter position');
          logger.info(
            'Moved filter wheel to position ${snapshot.filterPosition}',
            source: 'QuickStart',
          );
        } catch (e) {
          // Caught + degraded: user gets a partial restore; warn so the
          // snapshot-application gap is visible in logs.
          failures.add('filter wheel');
          logger.warning('Failed to move filter wheel: $e',
              source: 'QuickStart');
        }
      } else {
        failures.add('filter wheel (not connected)');
        logger.warning(
          'Could not restore the filter position because no filter wheel is connected',
          source: 'QuickStart',
        );
      }
    }

    if (snapshot.focuserPosition != null) {
      if (host.isStale) {
        return _SnapshotRestore(applied: applied, failures: failures);
      }
      final focuserState = ref.read(focuserStateProvider);
      if (focuserState.connectionState == DeviceConnectionState.connected) {
        final deviceService = ref.read(deviceServiceProvider);
        try {
          await deviceService.moveFocuserTo(snapshot.focuserPosition!);
          applied.add('focuser position');
          logger.info(
            'Moved focuser to position ${snapshot.focuserPosition}',
            source: 'QuickStart',
          );
        } catch (e) {
          // Caught + degraded: user gets a partial restore; warn so the
          // snapshot-application gap is visible in logs.
          failures.add('focuser');
          logger.warning('Failed to move focuser: $e', source: 'QuickStart');
        }
      } else {
        failures.add('focuser (not connected)');
        logger.warning(
          'Could not restore the focus position because no focuser is connected',
          source: 'QuickStart',
        );
      }
    }

    return _SnapshotRestore(applied: applied, failures: failures);
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

/// Outcome of applying an [EquipmentSnapshot]: what was restored, and what was
/// attempted and failed. Both are needed — reporting only failures made an
/// empty snapshot indistinguishable from a fully successful restore.
class _SnapshotRestore {
  final List<String> applied;
  final List<String> failures;

  const _SnapshotRestore({
    this.applied = const <String>[],
    this.failures = const <String>[],
  });
}

/// Whether [context] is a session that captured every planned frame. There is
/// nothing to continue in it, so it is not offered.
@visibleForTesting
bool sessionIsFinished(QuickStartContext context) =>
    context.totalFrames > 0 && context.completedFrames >= context.totalFrames;

/// [sessions] without the session of the run [checkpoint] continues.
@visibleForTesting
List<SessionRecoveryInfo> withoutCheckpointedRun(
  List<SessionRecoveryInfo> sessions,
  CheckpointInfo? checkpoint,
) {
  if (checkpoint == null || !checkpoint.canResume) return sessions;
  return sessions
      .where((s) => s.sessionName != checkpoint.sequenceName)
      .toList(growable: false);
}
