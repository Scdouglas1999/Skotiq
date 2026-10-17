part of '../stacking_panel.dart';

// Private widgets

/// The Stack-and-Share launcher button (component C10).
///
/// A secondary [SkotiqButton] that opens [StackAndShareDialog] for the
/// current session. The button is disabled — with an explanatory
/// [SkotiqTooltip] — when there is no active/selected session, or when live
/// stacking is running (the stacking engine is a singleton, so we surface that
/// exclusivity here rather than letting the run fail at click). While the
/// selection preview is being computed the button shows its loading state.
class _StackAndShareEntry extends StatelessWidget {
  /// Current imaging session id, or null when none is active/selected.
  final int? sessionId;

  /// Whether live stacking is currently running (singleton-exclusivity gate).
  final bool liveStackingActive;

  /// Whether the selection preview is currently being computed.
  final bool isBusy;

  /// Whether this UI is controlling a separate imaging host. Stack & Share's
  /// result database and artifacts are host-local in this release.
  final bool isRemoteMode;

  /// Invoked when the button is pressed; null when the action is unavailable.
  final VoidCallback? onPressed;

  const _StackAndShareEntry({
    required this.sessionId,
    required this.liveStackingActive,
    required this.isBusy,
    required this.isRemoteMode,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // Live stacking takes precedence in the disabled reason: even with a valid
    // session, the singleton engine is busy.
    final disabledReason = isRemoteMode
        ? 'Stack & Share uses session files and result storage on the imaging '
            'host. Open Skotiq on that computer to run it.'
        : liveStackingActive
            ? 'Stop live stacking to run Stack & Share'
            : sessionId == null
                ? 'Select a session to stack'
                : null;

    // Only enable when there is a session, live stacking is idle, and we are not
    // mid-preview. The reason text is mutually exclusive with an active handler.
    final enabled = disabledReason == null && !isBusy && onPressed != null;

    final button = SkotiqButton(
      label: isRemoteMode ? 'Stack & Share on imaging host' : 'Stack & Share',
      icon: SkotiqIcons.sparkle,
      variant: ButtonVariant.secondary,
      size: ButtonSize.small,
      isLoading: isBusy,
      onPressed: enabled ? onPressed : null,
    );

    if (disabledReason == null) {
      return button;
    }

    return SkotiqTooltip(
      message: disabledReason,
      child: button,
    );
  }
}
