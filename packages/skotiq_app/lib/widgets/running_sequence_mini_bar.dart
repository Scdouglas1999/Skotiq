import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../localization/skotiq_localizations.dart';
import '../screens/night_control/night_control_screen.dart'
    show isTonightLocation;
import '../screens/sequencer/sequencer_screen.dart' show kSequencerRoutePath;
import '../screens/sequencer/widgets/run_dashboard/sequence_status_visuals.dart';
import '../services/sequence_action_service.dart';
import '../utils/snackbar_helper.dart';

/// Persistent app-shell mini-player for a running sequence.
///
/// While a sequence is running (or paused) and the operator has navigated
/// *away* from the sequencer route, this bar keeps pause/resume, stop, and skip
/// reachable from anywhere — so checking the weather screen or planetarium
/// mid-run never means losing the run controls. On the sequencer route itself it
/// hides: the full in-page controls own that surface and a second control bar
/// would be redundant.
///
/// Controls route through [sequenceActionServiceProvider] (the same service the
/// in-page mobile playback bar uses), so behavior — including the
/// checkpoint-preserving stop — is identical. Stop is hold-to-confirm so a
/// thumb-slip can't abort an overnight run. Tapping the status area jumps back
/// to the sequencer screen.
class RunningSequenceMiniBar extends ConsumerWidget {
  /// Current shell location (already stripped of query in the caller is fine;
  /// this also strips defensively). Used to hide on the sequencer route.
  final String currentLocation;

  const RunningSequenceMiniBar({super.key, required this.currentLocation});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final executionState = ref.watch(sequenceExecutionStateProvider);

    // Stay reachable across every non-settled state — running, paused,
    // stopping, recovering, AND the retryable stopFailed / cleanupFailed — so
    // navigating away never strands a run without a Stop retry. Idle and the
    // terminal completed/failed states hide the bar.
    if (!executionState.isBusy) return const SizedBox.shrink();

    // On the sequencer route the full controls are already on screen, and
    // Tonight's header carries the same run controls.
    if (currentLocation.split('?').first == kSequencerRoutePath ||
        isTonightLocation(currentLocation)) {
      return const SizedBox.shrink();
    }

    final colors = SkotiqColors.of(context);
    final sessionState = ref.watch(sessionStateProvider);
    final targetName = sessionState.targetName;

    final isRunning = executionState == SequenceExecutionState.running;
    final isPaused = executionState == SequenceExecutionState.paused;
    // Skip / play-pause only make sense while the run is live or paused — not
    // while it's stopping or recovering (transient states the user can't drive).
    final canDrive = isRunning || isPaused;

    final visuals =
        SequenceStatusVisuals.of(executionState, colors, context.l10n);

    Future<void> stopSequence() async {
      final result = await ref.read(sequenceActionServiceProvider).stop();
      if (!context.mounted) return;
      context.showCommandActionResult(result);
    }

    return Material(
      color: colors.surface,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              // Status + target — tap to return to the sequencer screen.
              Expanded(
                // The tap lived on a bare gesture wrapper, which publishes an action
                // and no role, so assistive tech read a live control as an inert
                // disabled panel. The flags are only published when given.
                child: Semantics(
                    button: true,
                    enabled: true,
                    child: InkWell(
                      onTap: () {
                        try {
                          context.go(kSequencerRoutePath);
                        } catch (e, stack) {
                          developer.log(
                            '[RunningSequenceMiniBar] Could not return to the '
                            'sequencer: $e',
                            name: 'RunningSequenceMiniBar',
                            level: 900,
                            error: e,
                            stackTrace: stack,
                          );
                        }
                      },
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusInline8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 4),
                        child: Row(
                          children: [
                            Icon(visuals.icon, size: 16, color: visuals.color),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    visuals.label,
                                    style: SkotiqTypography.labelStrongSm
                                        .copyWith(color: visuals.color),
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                  if (targetName != null &&
                                      targetName.isNotEmpty)
                                    Text(
                                      targetName,
                                      style: TextStyle(
                                        fontSize: SkotiqTypography.fontSize11,
                                        color: colors.textMuted,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    )),
              ),
              // Play / Pause / Resume
              _MiniControlButton(
                colors: colors,
                icon: isRunning ? LucideIcons.pause : LucideIcons.play,
                tooltip: isRunning ? 'Pause' : 'Resume',
                isEnabled: canDrive,
                onPressed: () async {
                  final service = ref.read(sequenceActionServiceProvider);
                  final result = isRunning
                      ? await service.pause()
                      : await service.resume();
                  if (!context.mounted) return;
                  context.showCommandActionResult(result);
                },
              ),
              const SizedBox(width: 6),
              // Stop — hold-to-confirm to avoid accidental aborts. Enabled
              // wherever a stop is meaningful, including a retry from
              // stopFailed / cleanupFailed.
              HoldToConfirmButton(
                enabled: executionState.canStop,
                holdColor: colors.error,
                confirmText: 'Hold to stop',
                semanticsLabel: 'Press and hold to stop the sequence',
                onConfirmed: stopSequence,
                child: IgnorePointer(
                  child: _MiniControlButton(
                    colors: colors,
                    icon: LucideIcons.square,
                    tooltip: 'Stop',
                    isEnabled: executionState.canStop,
                    onPressed: stopSequence,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // Skip current item — valid while the run is live OR paused
              // (== canDrive above). Route through the canonical [canSkip] so
              // this matches the toolbar / mobile playback bar instead of
              // open-coding `isRunning`, which wrongly hid Skip while paused.
              _MiniControlButton(
                colors: colors,
                icon: LucideIcons.skipForward,
                tooltip: 'Skip',
                isEnabled: executionState.canSkip,
                onPressed: () async {
                  final result =
                      await ref.read(sequenceActionServiceProvider).skip();
                  if (!context.mounted) return;
                  context.showCommandActionResult(result);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniControlButton extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String tooltip;
  final bool isEnabled;
  final VoidCallback onPressed;

  const _MiniControlButton({
    required this.colors,
    required this.icon,
    required this.tooltip,
    required this.isEnabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        // The tap lived on a bare gesture wrapper, which publishes an action
        // and no role, so assistive tech read a live control as an inert
        // disabled panel. The flags are only published when given.
        child: Semantics(
            button: true,
            enabled: isEnabled,
            child: InkWell(
              onTap: isEnabled ? onPressed : null,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              child: Container(
                width: 40,
                height: 40,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                decoration: BoxDecoration(
                  color: isEnabled ? colors.surfaceAlt : colors.surface,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                  border: Border.all(color: colors.border),
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: isEnabled ? colors.textPrimary : colors.textMuted,
                ),
              ),
            )),
      ),
    );
  }
}
