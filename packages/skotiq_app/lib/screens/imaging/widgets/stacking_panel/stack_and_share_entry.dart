part of '../stacking_panel.dart';

/// The Stack-and-Share launcher (component C10): the session to stack and
/// the button that opens [StackAndShareDialog] for it.
///
/// While a run is imaging, its session is the one stacked. Otherwise the
/// operator picks one of the sessions that took frames, the newest by
/// default, so a finished night can still be stacked the next morning.
///
/// The button is disabled, with an explanatory [SkotiqTooltip], when there is
/// no session to stack or while live stacking runs (the stacking engine is a
/// singleton, so that exclusivity is shown here rather than failing at the
/// click). While the selection preview is being computed the button shows its
/// loading state.
class _StackAndShareEntry extends StatelessWidget {
  /// The session the button stacks, or null when there is none.
  final int? sessionId;

  /// The sessions the operator can pick from, newest first; empty while a run
  /// is imaging (its session is the one stacked) or on a linked client.
  final List<ImagingSession> pickable;

  /// Whether live stacking is currently running (singleton-exclusivity gate).
  final bool liveStackingActive;

  /// Whether the selection preview is currently being computed.
  final bool isBusy;

  /// Whether this UI is controlling a separate imaging host. Stack & Share's
  /// result database and artifacts are host-local in this release.
  final bool isRemoteMode;

  final ValueChanged<int> onSessionPicked;

  /// Invoked when the button is pressed; null when the action is unavailable.
  final VoidCallback? onPressed;

  const _StackAndShareEntry({
    required this.sessionId,
    required this.pickable,
    required this.liveStackingActive,
    required this.isBusy,
    required this.isRemoteMode,
    required this.onSessionPicked,
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
                ? 'No session has taken frames yet'
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

    final launcher = disabledReason == null
        ? button
        : SkotiqTooltip(message: disabledReason, child: button);
    if (pickable.isEmpty) return launcher;

    final colors = SkotiqColors.of(context);
    return Wrap(
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceSm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Semantics(
          label: 'Session to stack',
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: DropdownButtonHideUnderline(
              child: AccessibleDropdown<int>(
                value: sessionId,
                isDense: true,
                isExpanded: true,
                dropdownColor: colors.surfaceElevated,
                borderRadius: SkotiqTokens.borderRadiusMd,
                style:
                    SkotiqTypography.bodySm.copyWith(color: colors.textPrimary),
                onChanged: isBusy
                    ? null
                    : (id) {
                        if (id != null) onSessionPicked(id);
                      },
                items: [
                  for (final session in pickable)
                    DropdownMenuItem<int>(
                      value: session.id,
                      child: Text(
                        // When and how much first: the side panel is narrow
                        // and the name is what an ellipsis may cut.
                        '${ClockFormat.monthDayHm(session.startTime.toLocal())}'
                        '  ·  ${session.totalExposures} frames'
                        '  ·  ${session.name ?? 'Session ${session.id}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        launcher,
      ],
    );
  }
}
