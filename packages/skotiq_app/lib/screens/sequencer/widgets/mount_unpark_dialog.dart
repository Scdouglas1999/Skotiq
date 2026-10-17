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

  @override
  void initState() {
    super.initState();
    _remainingSeconds = widget.countdownSeconds;
    _startCountdown();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
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
          context.showCommandActionResult(result);
        }
        return;
      }
    }

    if (_cancelled) return;
    if (mounted) {
      Navigator.of(context).pop();
      widget.onUnparkAndContinue();
    }
  }

  void _handleCancel() {
    if (_cancelled) return;
    _cancelled = true;
    _countdownTimer?.cancel();
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
