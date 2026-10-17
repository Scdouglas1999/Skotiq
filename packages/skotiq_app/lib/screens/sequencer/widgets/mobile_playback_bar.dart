import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../services/sequence_action_service.dart';
import '../../../utils/snackbar_helper.dart';
import 'preflight_validation_dialog.dart';
import 'run_dashboard/sequence_status_visuals.dart';

/// Compact playback control bar for mobile devices.
/// Shows playback controls and current status in a single horizontal row.
class MobilePlaybackBar extends ConsumerWidget {
  final SkotiqColors colors;

  const MobilePlaybackBar({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final executionState = ref.watch(sequenceExecutionStateProvider);
    final sequence = ref.watch(currentSequenceProvider);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
        boxShadow: [
          BoxShadow(
            // absolute: drop-shadow scrim (theme-independent)
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // At very narrow widths (< 360px), hide info chips to prevent overflow
          final isVeryNarrow = constraints.maxWidth < 360;
          // At narrow widths (< 400px), use smaller spacing
          final isNarrow = constraints.maxWidth < 400;
          final buttonSpacing = isNarrow ? 4.0 : 8.0;
          Future<void> stopSequence() async {
            final result = await ref.read(sequenceActionServiceProvider).stop();
            if (!context.mounted) return;
            context.showCommandActionResult(result);
          }

          // Centralized capabilities so completed/failed offer a functional
          // Start (never a silent exact-idle no-op) and stopFailed/cleanupFailed
          // keep an enabled Stop retry.
          final canStart = executionState.canStart;
          final canPause = executionState.canPause;
          final canResume = executionState.canResume;

          return Row(
            children: [
              // Play / Pause / Resume — the primary transport button.
              _MobilePlaybackButton(
                colors: colors,
                icon: canPause ? LucideIcons.pause : LucideIcons.play,
                label: canPause ? 'Pause' : (canResume ? 'Resume' : 'Start'),
                isActive: canPause,
                isEnabled: canStart || canPause || canResume,
                isCompact: isNarrow,
                onPressed: () async {
                  if (canStart) {
                    await showDialog<void>(
                      context: context,
                      builder: (context) => PreFlightValidationDialog(
                        onStartSequence: () async {
                          final result = await ref
                              .read(sequenceActionServiceProvider)
                              .start();
                          if (!context.mounted) return;
                          context.showCommandActionResult(result);
                        },
                      ),
                    );
                  } else if (canPause) {
                    final result =
                        await ref.read(sequenceActionServiceProvider).pause();
                    if (!context.mounted) return;
                    context.showCommandActionResult(result);
                  } else if (canResume) {
                    final result =
                        await ref.read(sequenceActionServiceProvider).resume();
                    if (!context.mounted) return;
                    context.showCommandActionResult(result);
                  }
                },
              ),

              SizedBox(width: buttonSpacing),

              // Stop button — hold-to-confirm so a thumb-slip during an
              // overnight session can't abort the run. Enabled wherever a stop
              // is meaningful, including a retry from stopFailed / cleanupFailed.
              HoldToConfirmButton(
                enabled: executionState.canStop,
                holdColor: colors.error,
                confirmText: 'Hold to stop',
                semanticsLabel: 'Press and hold to stop the sequence',
                onConfirmed: stopSequence,
                // IgnorePointer so the inner InkWell does not consume the
                // long-press event; gestures are owned exclusively by the
                // surrounding [HoldToConfirmButton]. The visual styling is
                // preserved so the affordance still reads as "Stop".
                child: IgnorePointer(
                  child: _MobilePlaybackButton(
                    colors: colors,
                    icon: LucideIcons.square,
                    label: 'Stop',
                    isEnabled: executionState.canStop,
                    isCompact: isNarrow,
                    onPressed: stopSequence,
                  ),
                ),
              ),

              SizedBox(width: buttonSpacing),

              // Skip button
              _MobilePlaybackButton(
                colors: colors,
                icon: LucideIcons.skipForward,
                label: 'Skip',
                isEnabled: executionState.canSkip,
                isCompact: isNarrow,
                onPressed: () async {
                  final result =
                      await ref.read(sequenceActionServiceProvider).skip();
                  if (!context.mounted) return;
                  context.showCommandActionResult(result);
                },
              ),

              const Spacer(),

              // Status indicator and info (hidden at very narrow widths)
              if (sequence != null && !isVeryNarrow) ...[
                // Frames count
                _InfoChip(
                  colors: colors,
                  icon: LucideIcons.camera,
                  value: '${sequence.totalExposures}',
                  isCompact: isNarrow,
                ),
                SizedBox(width: isNarrow ? 4 : 8),
                // Duration
                _InfoChip(
                  colors: colors,
                  icon: LucideIcons.clock,
                  value: DurationFormat.seconds(sequence.totalIntegrationSecs,
                      style: DurationStyle.compact,
                      rounding: DurationRounding.truncate),
                  isCompact: isNarrow,
                ),
                SizedBox(width: isNarrow ? 4 : 8),
              ],

              // Status badge
              _StatusBadge(
                  colors: colors,
                  state: executionState,
                  isCompact: isVeryNarrow),
            ],
          );
        },
      ),
    );
  }
}

class _MobilePlaybackButton extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final bool isActive;
  final bool isEnabled;
  final bool isCompact;
  final VoidCallback onPressed;

  const _MobilePlaybackButton({
    required this.colors,
    required this.icon,
    required this.label,
    this.isActive = false,
    this.isEnabled = true,
    this.isCompact = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveEnabled = isEnabled;
    // Ensure minimum touch target of 44px even when visually compact
    final buttonSize = isCompact ? 40.0 : 44.0;

    return Tooltip(
      message: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: effectiveEnabled ? onPressed : null,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          child: Container(
            width: buttonSize,
            height: buttonSize,
            // Was a hardcoded 44 under a comment calling it "the minimum" — it
            // is the iOS minimum, and this bar is a phone surface, so Android's
            // 48 applies. Use the token so it cannot drift again.
            constraints: const BoxConstraints(
              minWidth: SkotiqTokens.minTouchTarget,
              minHeight: SkotiqTokens.minTouchTarget,
            ),
            decoration: BoxDecoration(
              color: isActive
                  ? SkotiqDecorations.statusChip(
                      colors.success,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusInline8),
                      bordered: false,
                    ).color
                  : effectiveEnabled
                      ? colors.surfaceAlt
                      : colors.surface,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              border: Border.all(
                color: isActive
                    ? colors.success.withValues(alpha: 0.5)
                    : colors.border,
              ),
            ),
            child: Icon(
              icon,
              size: isCompact ? 16 : 18,
              color: isActive
                  ? colors.success
                  : effectiveEnabled
                      ? colors.textPrimary
                      : colors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String value;
  final bool isCompact;

  const _InfoChip({
    required this.colors,
    required this.icon,
    required this.value,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    final horizontalPadding = isCompact ? 6.0 : 8.0;
    final iconSize = isCompact ? 10.0 : 12.0;
    final fontSize = isCompact ? 10.0 : 11.0;
    final spacing = isCompact ? 3.0 : 4.0;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: iconSize, color: colors.textMuted),
          SizedBox(width: spacing),
          Text(
            value,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w500,
              color: colors.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final SkotiqColors colors;
  final SequenceExecutionState state;
  final bool isCompact;

  const _StatusBadge({
    required this.colors,
    required this.state,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    // Single source of truth for color/icon so the mobile badge cannot
    // diverge from the toolbar badge and recovery LED.
    final visuals = SequenceStatusVisuals.of(state, colors, context.l10n);
    final badgeColor = visuals.color;
    final icon = visuals.icon;

    final badgeSize = isCompact ? 28.0 : 32.0;
    final iconSize = isCompact ? 12.0 : 14.0;

    return Container(
      width: badgeSize,
      height: badgeSize,
      decoration: SkotiqDecorations.statusChip(
        badgeColor,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusFull),
      ),
      child: state == SequenceExecutionState.running
          ? _PulsingIcon(color: badgeColor, icon: icon, size: iconSize)
          : Icon(icon, size: iconSize, color: badgeColor),
    );
  }
}

class _PulsingIcon extends StatefulWidget {
  final Color color;
  final IconData icon;
  final double size;

  const _PulsingIcon({required this.color, required this.icon, this.size = 14});

  @override
  State<_PulsingIcon> createState() => _PulsingIconState();
}

class _PulsingIconState extends State<_PulsingIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // Created idle and started by the OnScreenAnimationGate in build(): a
    // repeat() that outlives visibility schedules a frame on every vsync and
    // stops the whole app from idling.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OnScreenAnimationGate(
      controller: _controller,
      repeating: true,
      reverse: true,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Icon(
            widget.icon,
            size: widget.size,
            color: widget.color.withValues(
              alpha: 0.5 + _controller.value * 0.5,
            ),
          );
        },
      ),
    );
  }
}
