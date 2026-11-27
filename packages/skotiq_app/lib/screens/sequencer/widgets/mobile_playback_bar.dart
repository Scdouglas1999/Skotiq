import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../services/run_control/run_control.dart';
import '../../../services/sequence_action_service.dart';
import '../../../tours/tour_target.dart';
import '../../../utils/snackbar_helper.dart';

/// Pause or resume, stop and skip for a phone's Sequencer, as compact
/// buttons that sit in the plan row while a run is live.
class MobilePlaybackBar extends ConsumerWidget {
  final SkotiqColors colors;

  /// This bar is the tour's run-controls target; only one bar on a screen
  /// may be.
  final bool tourTarget;

  const MobilePlaybackBar({
    super.key,
    required this.colors,
    this.tourTarget = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transport = ref.watch(sequencerRunTransportProvider);
    Future<void> stopSequence() async {
      final result = await ref.read(sequenceActionServiceProvider).stop();
      if (!context.mounted) return;
      context.showCommandActionResult(result);
    }

    final pauseResume = transport.pauseResume?.enabled == true;
    final canPause = pauseResume && !transport.resumes;
    final canStop = transport.stop?.enabled == true;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Play / Pause / Resume — the primary transport button.
        _MobilePlaybackButton(
          key: tourTarget ? TourTarget.sequencerTransport.key : null,
          colors: colors,
          icon: transport.resumes ? LucideIcons.play : LucideIcons.pause,
          label: transport.resumes ? 'Resume' : 'Pause',
          isActive: canPause,
          isEnabled: pauseResume,
          isCompact: true,
          onPressed: () async {
            final service = ref.read(sequenceActionServiceProvider);
            final result =
                await (transport.resumes ? service.resume() : service.pause());
            if (!context.mounted) return;
            context.showCommandActionResult(result);
          },
        ),

        const SizedBox(width: SkotiqTokens.spaceXs),

        // Stop button — hold-to-confirm so a thumb-slip during an
        // overnight session can't abort the run. Enabled wherever a stop
        // is meaningful, including a retry from stopFailed / cleanupFailed.
        HoldToStop(
          enabled: canStop,
          holdColor: colors.error,
          confirmText: 'Hold to stop',
          semanticsLabel: 'Stop the sequence',
          onConfirmed: stopSequence,
          faceSemantics: true,
          face: (onPressed) => _MobilePlaybackButton(
            colors: colors,
            icon: LucideIcons.square,
            label: 'Stop',
            isEnabled: canStop,
            isCompact: true,
            onPressed: onPressed ?? stopSequence,
          ),
        ),

        const SizedBox(width: SkotiqTokens.spaceXs),

        _MobilePlaybackButton(
          colors: colors,
          icon: LucideIcons.skipForward,
          label: 'Skip',
          isEnabled: transport.skip?.enabled == true,
          isCompact: true,
          onPressed: () async {
            final result = await ref.read(sequenceActionServiceProvider).skip();
            if (!context.mounted) return;
            context.showCommandActionResult(result);
          },
        ),
      ],
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
    super.key,
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
            // 44 is the iOS minimum, and this bar is a phone surface, so
            // Android's 48 applies.
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
