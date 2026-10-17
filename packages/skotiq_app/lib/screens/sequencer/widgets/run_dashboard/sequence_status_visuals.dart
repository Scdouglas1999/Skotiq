import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';

/// Single source of truth for the (color, label, icon, dot-variant) tuple
/// that every sequence-status surface renders.
///
/// Before this existed, the toolbar status badge, the mobile playback-bar
/// badge, and the recovery LED each carried their own
/// `switch (executionState)` block — and the icons quietly diverged (e.g.
/// `loader` vs `rotateCw` for stopping/recovering). Routing all three
/// through [SequenceStatusVisuals.of] keeps the iconography consistent while
/// each widget keeps its own layout.
class SequenceStatusVisuals {
  const SequenceStatusVisuals({
    required this.color,
    required this.label,
    required this.icon,
    required this.variant,
  });

  final Color color;
  final String label;
  final IconData icon;
  final StatusDotVariant variant;

  /// [l10n] is required, not optional-with-an-English-default: this tuple is
  /// what the shell status bar, the sequencer toolbar and the mobile playback
  /// bar all render, and a silent English fallback here is how the bar stayed
  /// English while the rest of the chrome translated.
  static SequenceStatusVisuals of(
    SequenceExecutionState state,
    SkotiqColors colors,
    SkotiqLocalizations l10n,
  ) {
    switch (state) {
      case SequenceExecutionState.idle:
        return SequenceStatusVisuals(
          color: colors.textMuted,
          label: l10n.text('idle'),
          icon: LucideIcons.circleOff,
          variant: StatusDotVariant.static,
        );
      case SequenceExecutionState.running:
        return SequenceStatusVisuals(
          color: colors.success,
          label: l10n.text('sequenceRunning'),
          icon: LucideIcons.activity,
          variant: StatusDotVariant.static,
        );
      case SequenceExecutionState.paused:
        return SequenceStatusVisuals(
          color: colors.warning,
          label: l10n.text('sequencePaused'),
          icon: LucideIcons.pauseCircle,
          variant: StatusDotVariant.static,
        );
      case SequenceExecutionState.stopping:
        return SequenceStatusVisuals(
          color: colors.warning,
          label: l10n.text('statusSequenceStopping'),
          icon: LucideIcons.loader,
          variant: StatusDotVariant.static,
        );
      case SequenceExecutionState.completed:
        return SequenceStatusVisuals(
          color: colors.info,
          label: l10n.text('statusSequenceCompleted'),
          icon: LucideIcons.checkCircle,
          variant: StatusDotVariant.static,
        );
      case SequenceExecutionState.failed:
        return SequenceStatusVisuals(
          color: colors.error,
          label: l10n.text('statusSequenceFailed'),
          icon: LucideIcons.xCircle,
          variant: StatusDotVariant.urgent,
        );
      case SequenceExecutionState.recovering:
        return SequenceStatusVisuals(
          color: colors.error,
          label: l10n.text('statusSequenceRecovering'),
          icon: LucideIcons.rotateCw,
          variant: StatusDotVariant.urgent,
        );
      case SequenceExecutionState.stopFailed:
        // The native stop failed — the hardware may still be imaging. Urgent
        // error styling so the operator retries the Stop.
        return SequenceStatusVisuals(
          color: colors.error,
          label: l10n.text('statusSequenceStopFailed'),
          icon: LucideIcons.alertOctagon,
          variant: StatusDotVariant.urgent,
        );
      case SequenceExecutionState.cleanupFailed:
        // Hardware stopped, but saving the session record failed. Warning
        // styling — safe, but the Stop retry is needed to finish the wrap-up.
        return SequenceStatusVisuals(
          color: colors.warning,
          label: l10n.text('statusSequenceCleanupFailed'),
          icon: LucideIcons.alertTriangle,
          variant: StatusDotVariant.urgent,
        );
      case SequenceExecutionState.finalizing:
        // The run has ended and durable cleanup is wrapping up. Calm, transient
        // styling — nothing is wrong, the executor is just persisting the run.
        return SequenceStatusVisuals(
          color: colors.info,
          label: l10n.text('statusSequenceFinalizing'),
          icon: LucideIcons.loader,
          variant: StatusDotVariant.static,
        );
    }
  }
}
