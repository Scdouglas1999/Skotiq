import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../services/mount_command_service.dart';
import '../../../utils/snackbar_helper.dart';

/// Result from the mount unpark dialog
enum MountUnparkResult {
  /// User chose to unpark and continue
  unparkAndContinue,

  /// User cancelled the sequence
  cancel,
}

/// Dialog shown when the mount is parked before starting a sequence.
/// Provides a 15-second countdown with options to unpark immediately or cancel.
class MountUnparkDialog extends ConsumerStatefulWidget {
  /// Callback when the user chooses to unpark and continue
  final VoidCallback onUnparkAndContinue;

  /// Callback when the user cancels
  final VoidCallback onCancel;

  /// Countdown duration in seconds
  final int countdownSeconds;

  const MountUnparkDialog({
    super.key,
    required this.onUnparkAndContinue,
    required this.onCancel,
    this.countdownSeconds = 15,
  });

  @override
  ConsumerState<MountUnparkDialog> createState() => _MountUnparkDialogState();
}

class _MountUnparkDialogState extends ConsumerState<MountUnparkDialog> {
  late int _remainingSeconds;
  Timer? _countdownTimer;
  bool _isUnparking = false;

  /// Set the moment the operator presses Cancel, and checked again AFTER the
  /// unpark round-trip.
  ///
  /// The countdown used to become unbeatable the instant it expired: the
  /// Cancel button was disabled for the whole `unpark()` await, so a press in
  /// that window did nothing at all and the sequence started anyway. Cancel
  /// stays live and this latch is what makes it authoritative — a cancel that
  /// lands mid-unpark still aborts the start.
  bool _cancelled = false;

  /// This countdown as the window at the other end of a link sees it. It
  /// can cancel or unpark now from there; this window still does the work.
  late final PendingSequenceStart _shared;
  late final StateController<PendingSequenceStart?> _sharedController;
  ProviderSubscription<PendingSequenceStart?>? _sharedSubscription;

  @override
  void initState() {
    super.initState();
    _remainingSeconds = widget.countdownSeconds;
    _shared = PendingSequenceStart(
      id: '$runtimeMirrorOrigin-${DateTime.now().microsecondsSinceEpoch}',
      owner: runtimeMirrorOrigin,
      deadline: DateTime.now().toUtc().add(
            Duration(seconds: widget.countdownSeconds),
          ),
      seconds: widget.countdownSeconds,
    );
    _sharedController = ref.read(pendingSequenceStartProvider.notifier);
    _sharedSubscription = ref.listenManual<PendingSequenceStart?>(
      pendingSequenceStartProvider,
      (_, next) {
        if (next == null || next.id != _shared.id) return;
        // Acted on after the write that carried it, which may be a runtime
        // update still being applied.
        switch (next.phase) {
          case PendingStartPhase.cancelled:
            scheduleMicrotask(() {
              if (mounted) _handleCancel();
            });
          case PendingStartPhase.unparkNow:
            scheduleMicrotask(() {
              if (mounted) _handleUnparkAndContinue();
            });
          case PendingStartPhase.counting:
          case PendingStartPhase.unparking:
            break;
        }
      },
    );
    // A provider cannot change while the tree is building.
    scheduleMicrotask(() {
      if (mounted && !_cancelled) _publish(PendingStartPhase.counting);
    });
    _startCountdown();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _sharedSubscription?.close();
    scheduleMicrotask(_clearShared);
    super.dispose();
  }

  void _publish(PendingStartPhase phase) {
    final current = _sharedController.state;
    if (current != null && current.id != _shared.id) return;
    _sharedController.state = _shared.withPhase(phase);
  }

  void _clearShared() {
    if (_sharedController.state?.id == _shared.id) {
      _sharedController.state = null;
    }
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      setState(() {
        _remainingSeconds--;
      });

      if (_remainingSeconds <= 0) {
        timer.cancel();
        _handleUnparkAndContinue();
      }
    });
  }

  Future<void> _handleUnparkAndContinue() async {
    if (_isUnparking || _cancelled) return;

    _countdownTimer?.cancel();

    setState(() {
      _isUnparking = true;
    });
    _publish(PendingStartPhase.unparking);

    final mountState = ref.read(mountStateProvider);
    final isAlreadyUnparked =
        mountState.connectionState == DeviceConnectionState.connected &&
            !mountState.isParked;
    if (!isAlreadyUnparked) {
      final result = await ref.read(mountCommandServiceProvider).unpark();
      // Re-read the latch after the await: the operator had a live Cancel
      // button for the whole round-trip and may have used it.
      if (_cancelled) return;
      if (!result.isSuccess) {
        if (mounted) {
          setState(() {
            _isUnparking = false;
          });
          _publish(PendingStartPhase.counting);
          context.showCommandActionResult(result);
        }
        return;
      }
    }

    if (_cancelled) return;
    if (mounted) {
      _clearShared();
      Navigator.of(context).pop();
      widget.onUnparkAndContinue();
    }
  }

  void _handleCancel() {
    if (_cancelled) return;
    _cancelled = true;
    _countdownTimer?.cancel();
    _clearShared();
    Navigator.of(context).pop();
    widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return SkotiqDialog(
      title: 'Mount is parked',
      icon: LucideIcons.parkingCircle,
      width: 420,
      actions: [
        SkotiqButton(
          onPressed: _handleCancel,
          label: 'Cancel sequence',
          variant: ButtonVariant.ghost,
        ),
        SkotiqButton(
          onPressed: _isUnparking ? null : _handleUnparkAndContinue,
          icon: LucideIcons.play,
          label: _isUnparking ? 'Unparking...' : 'Unpark now',
          isLoading: _isUnparking,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SkotiqBanner(
            title: 'The mount will unpark automatically.',
            message: 'Cancel the sequence to keep it parked.',
            tone: BannerTone.warning,
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          if (!_isUnparking)
            Readout(
              value: '$_remainingSeconds',
              unit: 's',
              label: 'Unparking in',
              size: ReadoutSize.lg,
              valueColor: colors.warning,
            )
          else
            Text('Unparking mount...',
                style: SkotiqTypography.bodySm
                    .copyWith(color: colors.textSecondary)),
        ],
      ),
    );
  }
}

/// Shows the mount unpark dialog and returns the result
Future<MountUnparkResult?> showMountUnparkDialog(BuildContext context) async {
  MountUnparkResult? result;

  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => MountUnparkDialog(
      onUnparkAndContinue: () {
        result = MountUnparkResult.unparkAndContinue;
      },
      onCancel: () {
        result = MountUnparkResult.cancel;
      },
    ),
  );

  return result;
}

/// The unpark countdown a sequence start in the window at the other end of a
/// link is running. That window unparks and starts the run; this one shows
/// the same countdown and can cancel the start or unpark now.
class LinkedMountUnparkDialog extends ConsumerStatefulWidget {
  const LinkedMountUnparkDialog({super.key, required this.startId});

  final String startId;

  /// How long past its deadline a countdown nobody resolved stays up. The
  /// owning window may have gone away mid-countdown.
  static const Duration staleAfter = Duration(seconds: 30);

  @override
  ConsumerState<LinkedMountUnparkDialog> createState() =>
      _LinkedMountUnparkDialogState();
}

class _LinkedMountUnparkDialogState
    extends ConsumerState<LinkedMountUnparkDialog> {
  Timer? _tick;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      final pending = ref.read(pendingSequenceStartProvider);
      if (pending != null &&
          pending.id == widget.startId &&
          DateTime.now().toUtc().isAfter(
                pending.deadline.add(LinkedMountUnparkDialog.staleAfter),
              )) {
        ref.read(pendingSequenceStartProvider.notifier).state = null;
        return;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  void _ask(PendingStartPhase phase) {
    final pending = ref.read(pendingSequenceStartProvider);
    if (pending == null || pending.id != widget.startId) return;
    ref.read(pendingSequenceStartProvider.notifier).state =
        pending.withPhase(phase);
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final watched = ref.watch(pendingSequenceStartProvider);
    final pending =
        watched != null && watched.id == widget.startId ? watched : null;
    final current = pending != null;
    if (pending == null || pending.phase == PendingStartPhase.cancelled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _close();
      });
    }
    final unparking = pending != null &&
        (pending.phase == PendingStartPhase.unparking ||
            pending.phase == PendingStartPhase.unparkNow);
    final remaining =
        pending == null ? 0 : pending.remainingSeconds(DateTime.now().toUtc());
    final otherWindow = ref.watch(isRemoteModeProvider)
        ? 'the imaging computer'
        : 'a linked window';

    return SkotiqDialog(
      title: 'Mount is parked',
      icon: LucideIcons.parkingCircle,
      width: 420,
      actions: [
        SkotiqButton(
          onPressed: current ? () => _ask(PendingStartPhase.cancelled) : null,
          label: 'Cancel sequence',
          variant: ButtonVariant.ghost,
        ),
        SkotiqButton(
          onPressed: current && !unparking
              ? () => _ask(PendingStartPhase.unparkNow)
              : null,
          icon: LucideIcons.play,
          label: unparking ? 'Unparking...' : 'Unpark now',
          isLoading: unparking,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SkotiqBanner(
            title: 'The mount will unpark automatically.',
            message: 'A sequence was started from $otherWindow. '
                'Cancel the sequence to keep the mount parked.',
            tone: BannerTone.warning,
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          if (!unparking)
            Readout(
              value: '$remaining',
              unit: 's',
              label: 'Unparking in',
              size: ReadoutSize.lg,
              valueColor: colors.warning,
            )
          else
            Text('Unparking mount...',
                style: SkotiqTypography.bodySm
                    .copyWith(color: colors.textSecondary)),
        ],
      ),
    );
  }
}
