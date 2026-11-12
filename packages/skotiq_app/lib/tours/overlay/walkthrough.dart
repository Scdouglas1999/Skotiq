part of '../tour_overlay.dart';

/// One card of a walkthrough tour, as a dialog over the app.
///
/// "Show me" opens the screen the card is about and parks the walkthrough
/// there (see [_ParkedWalkthrough]) rather than ending it.
class _Walkthrough extends StatelessWidget {
  const _Walkthrough({
    required this.step,
    required this.index,
    required this.total,
    required this.busy,
    required this.onNext,
    required this.onBack,
    required this.onSkip,
    required this.onClose,
    required this.onShowMe,
  });

  final TourStep step;
  final int index;
  final int total;
  final bool busy;
  final VoidCallback onNext;
  final VoidCallback onBack;
  final VoidCallback onSkip;
  final VoidCallback onClose;
  final ValueChanged<AppRoute> onShowMe;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    final showMe = step.showMe;
    final isLast = index >= total - 1;

    return Stack(
      children: [
        Positioned.fill(
          child: ModalBarrier(
            dismissible: false,
            color: colors.background.withValues(alpha: 0.6),
          ),
        ),
        Positioned.fill(
          child: SkotiqDialog(
            title: l10n.text('firstNightWizardTitle'),
            icon: SkotiqIcons.sparkle,
            width: 640,
            height: 560,
            closeEnabled: !busy,
            // Closing keeps the step: the walkthrough resumes here from
            // Settings > Help.
            onClose: onClose,
            actions: [
              SkotiqButton(
                label: l10n.text('firstNightWizardSkipForever'),
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: busy ? null : onSkip,
              ),
              const SizedBox(width: 8),
              if (index == 0)
                SkotiqButton(
                  label: l10n.text('commonClose'),
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: busy ? null : onClose,
                )
              else
                SkotiqButton(
                  label: l10n.text('commonBack'),
                  icon: SkotiqIcons.chevronLeft,
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: busy ? null : onBack,
                ),
              const SizedBox(width: 8),
              SkotiqButton(
                label: l10n.text(isLast ? 'commonDone' : 'commonNext'),
                icon: isLast ? SkotiqIcons.check : SkotiqIcons.chevronRight,
                variant: ButtonVariant.primary,
                size: ButtonSize.small,
                isLoading: busy,
                onPressed: busy ? null : onNext,
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: SkotiqDecorations.iconChip(
                        colors.primary,
                        borderRadius: SkotiqTokens.borderRadiusLg,
                      ),
                      child: Icon(
                        step.icon ?? SkotiqIcons.sparkle,
                        color: colors.primary,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.text('firstNightWizardStepLabel', params: {
                              'current': '${index + 1}',
                              'total': '$total',
                            }),
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize11,
                              color: colors.textMuted,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            step.title,
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize18,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  step.description,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize13,
                    height: 1.55,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 20),
                if (showMe != null)
                  SkotiqButton(
                    label: switch (showMe.label?.of(l10n)) {
                      final screen? => l10n.text(
                          'firstNightWizardShowMeOnScreen',
                          params: {'screen': screen},
                        ),
                      null => 'Show me',
                    },
                    icon: SkotiqIcons.externalLink,
                    variant: ButtonVariant.secondary,
                    size: ButtonSize.small,
                    onPressed: busy ? null : () => onShowMe(showMe),
                  ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    for (var i = 0; i < total; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Container(
                          width: i == index ? 16 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: i == index
                                ? colors.primary
                                : i < index
                                    ? colors.primary.withValues(alpha: 0.5)
                                    : colors.border,
                            borderRadius: SkotiqTokens.borderRadiusInline4,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A walkthrough that has sent the user to a screen: a small bar that stays
/// out of the way and brings the walkthrough back.
class _ParkedWalkthrough extends StatelessWidget {
  const _ParkedWalkthrough({
    required this.index,
    required this.total,
    required this.onReturn,
    required this.onClose,
  });

  final int index;
  final int total;
  final VoidCallback onReturn;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 84, left: 16, right: 16),
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            label: l10n.text('firstNightWizardTitle'),
            child: Material(
              color: colors.surfaceElevated,
              elevation: 8,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                side: BorderSide(color: colors.primary.withValues(alpha: 0.3)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(SkotiqIcons.sparkle, size: 16, color: colors.primary),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        l10n.text('firstNightWizardStepLabel', params: {
                          'current': '${index + 1}',
                          'total': '$total',
                        }),
                        overflow: TextOverflow.ellipsis,
                        style: SkotiqTypography.bodySm
                            .copyWith(color: colors.textSecondary),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SkotiqButton(
                      label: l10n.text('firstNightWizardReturn'),
                      icon: SkotiqIcons.chevronLeft,
                      variant: ButtonVariant.primary,
                      size: ButtonSize.small,
                      onPressed: onReturn,
                    ),
                    const SizedBox(width: 4),
                    SkotiqIconButton(
                      icon: LucideIcons.x,
                      tooltip: l10n.text('commonClose'),
                      onPressed: onClose,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
