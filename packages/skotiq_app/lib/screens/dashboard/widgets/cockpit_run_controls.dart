import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../services/sequence_action_service.dart';
import '../../../utils/snackbar_helper.dart';
import '../../sequencer/widgets/preflight_validation_dialog.dart';

/// Inline run-control strip for the Dashboard cockpit.
///
/// Mirrors the sequencer's [MobilePlaybackBar] controls so the user can manage
/// a run (pause / resume, hold-to-stop, skip) — and launch one — without
/// leaving the cockpit.
///
/// Visibility:
///   * ACTIVE (running / paused / stopping / recovering) → pause/resume,
///     hold-to-stop, and skip controls.
///   * INACTIVE (idle / completed / failed) with a launchable sequence loaded
///     (has a target or exposures) → a Start button gated by the pre-flight
///     dialog, plus a state badge ("Ready" / "Completed" / "Failed"). Terminal
///     states matter here: a failed one-tap launch leaves the sequence loaded
///     and the executor in `failed`, and without a Start affordance the awake
///     cockpit would be a dead end with nothing clickable.
///   * INACTIVE with equipment connected but no launchable sequence → a slim
///     nudge row offering the one-tap tonight flow and the sequencer (the
///     cockpit is awake because gear is connected, so it must offer a way
///     forward).
///   * Otherwise (nothing loaded, nothing connected) → collapses to a
///     zero-size box; the standby briefing owns that state.
class CockpitRunControls extends ConsumerWidget {
  final SkotiqColors colors;

  const CockpitRunControls({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sequenceExecutionStateProvider);
    final isActive = _isActive(state);

    // A sequence is "launchable" once it has at least one target or exposure —
    // i.e. the user has actually built something to image (not the empty
    // auto-created default). When inactive with such a sequence loaded we offer
    // a Start button so the night can be launched from the cockpit.
    final sequence = ref.watch(currentSequenceProvider);
    final hasLaunchableSequence = sequence != null &&
        (sequence.targetHeaders.isNotEmpty || sequence.totalExposures > 0);
    final showStart = !isActive && hasLaunchableSequence;

    // The no-sequence nudge only appears when the cockpit is awake because
    // equipment is connected. When nothing is connected either, the standby
    // briefing is showing (with its own CTAs) and this strip must stay hidden.
    final anyDeviceConnected = _anyCoreDeviceConnected(ref);
    final showNudge = !isActive && !hasLaunchableSequence && anyDeviceConnected;

    if (!isActive && !showStart && !showNudge) return const SizedBox.shrink();

    final Widget controls;
    if (showStart) {
      Future<void> startSequence() async {
        // Route through the same pre-flight gate the sequencer uses so the
        // cockpit Start can't skip the safety checks.
        await showDialog<void>(
          context: context,
          builder: (_) => PreFlightValidationDialog(
            onStartSequence: () async {
              final result =
                  await ref.read(sequenceActionServiceProvider).start();
              if (!context.mounted) return;
              context.showCommandActionResult(result);
            },
          ),
        );
      }

      // A Start offered against a backend that cannot carry the command is the
      // app claiming a capability it does not have: on a remote controller
      // whose host has gone away, tapping Start could never launch anything.
      // Gate the affordance AND the surrounding copy on the same signal so the
      // strip never reads "Ready" while nothing can be commanded.
      final canCommand = ref.watch(backendCanCommandProvider);

      // After a terminal state the Start button re-arms the same sequence; the
      // helper text + badge stay honest about how the last attempt ended.
      final (String readyText, Widget badge) = switch (state) {
        _ when !canCommand => (
            'Host unreachable — reconnect to start this sequence.',
            _OfflineBadge(colors: colors),
          ),
        SequenceExecutionState.failed => (
            'Run failed — fix the issue and start again.',
            _StateBadge(colors: colors, state: state),
          ),
        SequenceExecutionState.completed => (
            'Run complete — start another pass.',
            _StateBadge(colors: colors, state: state),
          ),
        _ => (
            'Sequence ready — start tonight’s run.',
            _ReadyBadge(colors: colors),
          ),
      };

      controls = Row(
        children: [
          _ControlButton(
            colors: colors,
            icon: LucideIcons.play,
            label: 'Start',
            isActive: canCommand,
            isEnabled: canCommand,
            onPressed: startSequence,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              readyText,
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          badge,
        ],
      );
    } else if (showNudge) {
      controls = Row(
        children: [
          _ControlButton(
            colors: colors,
            icon: LucideIcons.moonStar,
            label: 'Image tonight',
            isActive: true,
            onPressed: () => context.go('/tonight'),
          ),
          const SizedBox(width: 8),
          _ControlButton(
            colors: colors,
            icon: LucideIcons.listOrdered,
            label: 'Sequencer',
            onPressed: () => context.go('/sequencer'),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Equipment connected — no sequence loaded.',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      );
    } else {
      final isRunning = state == SequenceExecutionState.running;
      final isPaused = state == SequenceExecutionState.paused;

      Future<void> pauseOrResume() async {
        final service = ref.read(sequenceActionServiceProvider);
        final result =
            isRunning ? await service.pause() : await service.resume();
        if (!context.mounted) return;
        context.showCommandActionResult(result);
      }

      Future<void> stopSequence() async {
        final result = await ref.read(sequenceActionServiceProvider).stop();
        if (!context.mounted) return;
        context.showCommandActionResult(result);
      }

      Future<void> skipNode() async {
        final result = await ref.read(sequenceActionServiceProvider).skip();
        if (!context.mounted) return;
        context.showCommandActionResult(result);
      }

      controls = Row(
        children: [
          // Play/Pause toggles on the live execution state: running shows
          // Pause, paused shows Resume. The Pause-active styling tells the
          // user the sequence is live.
          _ControlButton(
            colors: colors,
            icon: isRunning ? LucideIcons.pause : LucideIcons.play,
            label: isRunning ? 'Pause' : 'Resume',
            isActive: isRunning,
            // While stopping/recovering, pause/resume isn't a meaningful
            // action — only enable it in the running/paused states.
            isEnabled: isRunning || isPaused,
            onPressed: pauseOrResume,
          ),
          const SizedBox(width: 8),
          // Stop is hold-to-confirm so a stray click can't abort an overnight
          // run; the inner button is IgnorePointer so the hold gesture is
          // owned exclusively by HoldToConfirmButton. Enabled wherever a stop
          // is meaningful — including a retry from stopFailed / cleanupFailed.
          HoldToConfirmButton(
            enabled: state.canStop,
            holdColor: colors.error,
            confirmText: 'Hold to stop',
            semanticsLabel: 'Press and hold to stop the sequence',
            onConfirmed: stopSequence,
            child: IgnorePointer(
              child: _ControlButton(
                colors: colors,
                icon: LucideIcons.square,
                label: 'Stop',
                isEnabled: state.canStop,
                onPressed: stopSequence,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Skip the current instruction — the backend skip advances the node
          // pointer while the run is running OR paused, so route through the
          // canonical [canSkip] instead of open-coding `isRunning` (which hid
          // Skip from a paused run, drifting from every other surface).
          _ControlButton(
            colors: colors,
            icon: LucideIcons.skipForward,
            label: 'Skip',
            isEnabled: state.canSkip,
            onPressed: skipNode,
          ),
          const Spacer(),
          _StateBadge(colors: colors, state: state),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: SkotiqTokens.borderRadiusLg,
        border: Border.all(color: colors.border),
        boxShadow: SkotiqTokens.elevationLevel1,
      ),
      child: controls,
    );
  }

  /// Same core-device set the dashboard's standby branch watches, so this
  /// strip's nudge appears exactly when the cockpit is awake on connectivity.
  bool _anyCoreDeviceConnected(WidgetRef ref) {
    bool connected(ProviderListenable<DeviceConnectionState> p) =>
        ref.watch(p) == DeviceConnectionState.connected;
    return connected(cameraStateProvider.select((s) => s.connectionState)) ||
        connected(mountStateProvider.select((s) => s.connectionState)) ||
        connected(guiderStateProvider.select((s) => s.connectionState)) ||
        connected(focuserStateProvider.select((s) => s.connectionState));
  }

  /// Whether to show the run-control strip (pause/stop/skip) instead of the
  /// Start affordance. True for every non-settled state — including the
  /// retryable stopFailed / cleanupFailed — so the operator keeps a Stop retry
  /// and never faces a Start button while the prior run is still winding down.
  bool _isActive(SequenceExecutionState state) => state.isBusy;
}

/// Small "Ready" chip shown next to the Start button when a launchable
/// sequence is loaded but not yet running.
class _ReadyBadge extends StatelessWidget {
  final SkotiqColors colors;

  const _ReadyBadge({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: SkotiqDecorations.statusChip(
        colors.info,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(color: colors.info, size: 8),
          const SizedBox(width: 6),
          Text(
            'Ready',
            style: SkotiqTypography.eyebrow.copyWith(color: colors.info),
          ),
        ],
      ),
    );
  }
}

/// Shown in place of the "Ready" chip when a launchable sequence is loaded but
/// the backend cannot carry a start command (host unreachable). The sequence
/// really is loaded — what is missing is the host — so this reports the
/// connection, not the sequence.
class _OfflineBadge extends StatelessWidget {
  final SkotiqColors colors;

  const _OfflineBadge({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: SkotiqDecorations.statusChip(
        colors.warning,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(color: colors.warning, size: 8),
          const SizedBox(width: 6),
          Text(
            'Offline',
            style: SkotiqTypography.eyebrow.copyWith(color: colors.warning),
          ),
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final bool isActive;
  final bool isEnabled;
  final VoidCallback onPressed;

  const _ControlButton({
    required this.colors,
    required this.icon,
    required this.label,
    this.isActive = false,
    this.isEnabled = true,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // A bare Tooltip+InkWell publishes a node with a tap action but no role
    // and no enabled flag, so AT-SPI reads the Dashboard's two headline
    // calls-to-action as `panel: Image tonight [DISABLED]` and
    // `panel: Sequencer [DISABLED]` — dead non-controls, while clicking either
    // navigates fine. `excludeSemantics` makes this the ONE node for the
    // control so the InkWell underneath cannot re-describe it.
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        enabled: isEnabled,
        label: label,
        excludeSemantics: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: isEnabled ? onPressed : null,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              constraints: const BoxConstraints(minWidth: 36),
              decoration: BoxDecoration(
                color: isActive
                    ? colors.success.withValues(alpha: 0.12)
                    : isEnabled
                        ? colors.surface
                        : colors.surface.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
                border: Border.all(
                  color: isActive
                      ? colors.success.withValues(alpha: 0.5)
                      : colors.border,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: isActive
                        ? colors.success
                        : isEnabled
                            ? colors.textPrimary
                            : colors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: SkotiqTypography.h6.copyWith(
                      color: isActive
                          ? colors.success
                          : isEnabled
                              ? colors.textPrimary
                              : colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  final SkotiqColors colors;
  final SequenceExecutionState state;

  const _StateBadge({required this.colors, required this.state});

  @override
  Widget build(BuildContext context) {
    final (Color color, IconData icon, String label) = switch (state) {
      SequenceExecutionState.running => (
          colors.success,
          LucideIcons.activity,
          'Running',
        ),
      SequenceExecutionState.paused => (
          colors.warning,
          LucideIcons.pauseCircle,
          'Paused',
        ),
      SequenceExecutionState.stopping => (
          colors.warning,
          LucideIcons.loader,
          'Stopping',
        ),
      SequenceExecutionState.recovering => (
          colors.error,
          LucideIcons.rotateCw,
          'Recovering',
        ),
      // Completed/failed appear next to the re-armed Start button; idle never
      // reaches this widget (the Ready badge covers it).
      SequenceExecutionState.idle => (
          colors.textMuted,
          LucideIcons.circleOff,
          'Idle',
        ),
      SequenceExecutionState.completed => (
          colors.info,
          LucideIcons.checkCircle,
          'Completed',
        ),
      SequenceExecutionState.failed => (
          colors.error,
          LucideIcons.xCircle,
          'Failed',
        ),
      SequenceExecutionState.stopFailed => (
          colors.error,
          LucideIcons.alertOctagon,
          'Stop failed',
        ),
      SequenceExecutionState.cleanupFailed => (
          colors.warning,
          LucideIcons.alertTriangle,
          'Cleanup failed',
        ),
      SequenceExecutionState.finalizing => (
          colors.info,
          LucideIcons.loader,
          'Finalizing',
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: SkotiqDecorations.statusChip(
        color,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(
            color: color,
            size: 8,
            variant: state == SequenceExecutionState.recovering
                ? StatusDotVariant.urgent
                : StatusDotVariant.static,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: SkotiqTypography.eyebrow.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
