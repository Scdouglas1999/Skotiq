import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../utils/authority_bound_dialog.dart';
import '../utils/startup_surface_coordinator.dart';
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

  @override
  void initState() {
    super.initState();
    // Schedule check after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForStartupOptions();
    });
  }

  Future<void> _checkForStartupOptions() async {
    if (_hasChecked || !mounted) return;

    _hasChecked = true;
    final authority = ref.read(backendProvider);

    try {
      // First priority: Check for crashed/interrupted sessions
      final incompleteSessions =
          await ref.read(incompleteSessionsProvider.future);

      if (!mounted) return;
      if (!_isCurrentAuthority(authority)) {
        _scheduleRecheck();
        return;
      }

      if (incompleteSessions.isNotEmpty && mounted) {
        // Show recovery dialog for interrupted sessions (takes priority)
        await Future.delayed(const Duration(milliseconds: 500));

        if (mounted && _isCurrentAuthority(authority)) {
          final uiContext = _uiContext;
          if (uiContext == null || !uiContext.mounted) {
            _scheduleRecheck();
            return;
          }
          await _showAuthorityDialog<void>(
            authority: authority,
            context: uiContext,
            barrierDismissible: false,
            builder: (context) => SessionRecoveryDialog(
              incompleteSessions: incompleteSessions,
            ),
          );
        }
        if (mounted && !_isCurrentAuthority(authority)) {
          _scheduleRecheck();
        }
        return;
      }

      // Second priority: Check for quick start opportunity
      final quickStartContext =
          await ref.read(quickStartContextProvider.future);

      if (!mounted) return;
      if (!_isCurrentAuthority(authority)) {
        _scheduleRecheck();
        return;
      }

      if (quickStartContext != null && quickStartContext.isRecent && mounted) {
        // Show quick start dialog
        await Future.delayed(const Duration(milliseconds: 500));

        if (mounted && _isCurrentAuthority(authority)) {
          final uiContext = _uiContext;
          if (uiContext == null || !uiContext.mounted) {
            _scheduleRecheck();
            return;
          }
          await _showAuthorityDialog<void>(
            authority: authority,
            context: uiContext,
            builder: (dialogContext) => QuickStartDialog(
              quickStartContext: quickStartContext,
              onStartFresh: () {
                Navigator.of(dialogContext).pop();
                unawaited(_handleStartFresh(quickStartContext, authority));
              },
              onResumeProgress: () {
                Navigator.of(dialogContext).pop();
                unawaited(_handleResumeProgress(quickStartContext, authority));
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
        if (mounted && !_isCurrentAuthority(authority)) {
          _scheduleRecheck();
        }
      }
    } catch (e, st) {
      if (mounted && !_isCurrentAuthority(authority)) {
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

  bool _isCurrentAuthority(SkotiqBackend authority) =>
      mounted && identical(ref.read(backendProvider), authority);

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

  Future<T?> _showAuthorityDialog<T>({
    required SkotiqBackend authority,
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) async {
    return ref.read(startupSurfaceCoordinatorProvider).run<T?>(() async {
      if (!mounted || !context.mounted || !_isCurrentAuthority(authority)) {
        return null;
      }

      BuildContext? dialogContext;
      final subscription = ref.listenManual<SkotiqBackend>(
        backendProvider,
        (previous, next) {
          if (identical(next, authority)) return;
          final routeContext = dialogContext;
          if (routeContext != null && routeContext.mounted) {
            closeAuthorityBoundDialog(routeContext);
          }
        },
      );
      try {
        return await showDialog<T>(
          context: context,
          barrierDismissible: barrierDismissible,
          builder: (routeContext) {
            dialogContext = routeContext;
            return builder(routeContext);
          },
        );
      } finally {
        subscription.close();
      }
    });
  }

  void _showAuthorityChanged() {
    if (!mounted) return;
    final uiContext = _uiContext;
    if (uiContext == null) return;
    ScaffoldMessenger.of(uiContext).showSnackBar(
      const SnackBar(
        content: Text(
          'The imaging host changed. Quick Start was cancelled.',
        ),
      ),
    );
  }

  Future<void> _handleStartFresh(
    QuickStartContext context,
    SkotiqBackend authority,
  ) async {
    if (!_isCurrentAuthority(authority)) {
      _showAuthorityChanged();
      return;
    }
    final logger = ref.read(loggingServiceProvider);
    logger.info(
      'Starting fresh with context: ${context.displayDescription}',
      source: 'QuickStart',
    );

    try {
      if (context.canResumeFromCheckpoint) {
        await authority.discardCheckpoint();
        if (!_isCurrentAuthority(authority)) return;
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

      // Load the equipment profile
      if (context.profileId != null) {
        final profilesNotifier = ref.read(equipmentProfilesProvider.notifier);
        await profilesNotifier.setActiveProfile(context.profileId!);
        if (!_isCurrentAuthority(authority)) return;
        restored.add('equipment profile');
        logger.info('Activated profile ${context.profileId}',
            source: 'QuickStart');
      }

      // Load the sequence (reset to beginning)
      if (context.sequenceId != null) {
        final sequence = await ref
            .read(sequenceRepositoryProvider)
            .loadSequence(context.sequenceId!);
        if (!_isCurrentAuthority(authority)) return;
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

      // Apply equipment settings from snapshot
      final snapshotResult = await _applyEquipmentSnapshot(
        context.equipmentSnapshot,
        authority,
      );
      if (!_isCurrentAuthority(authority)) return;
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
      if (!_isCurrentAuthority(authority)) return;
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
            content: Text('Failed to start fresh: $e'),
            backgroundColor: colors.error,
          ),
        );
      }
    }
  }

  Future<void> _handleResumeProgress(
    QuickStartContext context,
    SkotiqBackend authority,
  ) async {
    if (!_isCurrentAuthority(authority)) {
      _showAuthorityChanged();
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

      // Load the equipment profile
      if (context.profileId != null) {
        final profilesNotifier = ref.read(equipmentProfilesProvider.notifier);
        await profilesNotifier.setActiveProfile(context.profileId!);
        if (!_isCurrentAuthority(authority)) return;
        logger.info('Activated profile ${context.profileId}',
            source: 'QuickStart');
      }

      // The executor restores the checkpointed sequence, runtime state, and
      // device mapping, then starts execution. Merely loading the editor copy
      // would leave the backend idle while the UI claimed a resume occurred.
      await executor.resumeFromCheckpoint();
      if (!_isCurrentAuthority(authority)) return;

      final uiContext = _uiContext;
      if (mounted && uiContext != null && uiContext.mounted) {
        final colors = SkotiqColors.of(uiContext);
        final message =
            'Resuming session for ${context.targetName ?? "previous target"} '
            'from frame ${context.completedFrames}';
        ScaffoldMessenger.of(uiContext).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: colors.success,
          ),
        );
      }
    } catch (e, st) {
      if (!_isCurrentAuthority(authority)) return;
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
            content: Text('Failed to resume progress: $e'),
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
    SkotiqBackend authority,
  ) async {
    final logger = ref.read(loggingServiceProvider);
    if (snapshot == null || !snapshot.hasEquipmentData) {
      logger.info('No equipment snapshot to apply', source: 'QuickStart');
      return const _SnapshotRestore();
    }

    logger.info('Applying equipment snapshot...', source: 'QuickStart');

    final applied = <String>[];
    final failures = <String>[];
    if (!_isCurrentAuthority(authority)) {
      return _SnapshotRestore(applied: applied, failures: failures);
    }

    // Apply camera settings
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

    // Apply filter position
    if (snapshot.filterPosition != null) {
      if (!_isCurrentAuthority(authority)) {
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

    // Apply focus position
    if (snapshot.focuserPosition != null) {
      if (!_isCurrentAuthority(authority)) {
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
