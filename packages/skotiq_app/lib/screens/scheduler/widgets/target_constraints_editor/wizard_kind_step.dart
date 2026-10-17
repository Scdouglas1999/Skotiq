part of '../target_constraints_editor.dart';

class _WizardHeader extends StatelessWidget {
  final int step;
  final SkotiqColors colors;
  const _WizardHeader({required this.step, required this.colors});

  @override
  Widget build(BuildContext context) {
    String label;
    switch (step) {
      case 1:
        label = 'Step 1 of 3 — Choose constraint type';
        break;
      case 2:
        label = 'Step 2 of 3 — Set parameters';
        break;
      case 3:
        label = 'Step 3 of 3 — Review';
        break;
      default:
        label = '';
    }
    return Row(
      children: [
        Icon(LucideIcons.filter,
            size: SkotiqTokens.iconMd, color: colors.primary),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Text(
          'Add constraint',
          style: SkotiqTypography.sectionTitle
              .copyWith(color: colors.textPrimary),
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Expanded(
          child: Text(
            label,
            textAlign: TextAlign.right,
            style:
                SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
          ),
        ),
      ],
    );
  }
}

class _Step1ChooseKind extends StatelessWidget {
  final Set<TargetConstraintKind> existingKinds;
  final TargetConstraintKind? selected;
  final void Function(TargetConstraintKind) onSelect;

  const _Step1ChooseKind({
    required this.existingKinds,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'What kind of constraint?',
          style: SkotiqTypography.bodyStrong
              .copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        _KindCard(
          key: const ValueKey('wizard-kind-timeWindow'),
          kind: TargetConstraintKind.timeWindow,
          icon: LucideIcons.clock,
          title: 'Time window',
          body: 'Only image between these hours of the night.',
          selected: selected == TargetConstraintKind.timeWindow,
          disabled: existingKinds.contains(TargetConstraintKind.timeWindow),
          onTap: () => onSelect(TargetConstraintKind.timeWindow),
        ),
        _KindCard(
          key: const ValueKey('wizard-kind-moon'),
          kind: TargetConstraintKind.moonIlluminationMax,
          icon: LucideIcons.moon,
          title: 'Moon illumination',
          body: "Skip this target when the moon's illumination is above a "
              'set percentage, wherever the moon is in the sky.',
          selected: selected == TargetConstraintKind.moonIlluminationMax,
          disabled:
              existingKinds.contains(TargetConstraintKind.moonIlluminationMax),
          onTap: () => onSelect(TargetConstraintKind.moonIlluminationMax),
        ),
        _KindCard(
          key: const ValueKey('wizard-kind-moon-separation'),
          kind: TargetConstraintKind.moonSeparationMin,
          icon: LucideIcons.moonStar,
          title: 'Moon separation',
          body: 'Skip this target when the moon is closer to it than a set '
              'angle. This is the one that protects the frames.',
          selected: selected == TargetConstraintKind.moonSeparationMin,
          disabled:
              existingKinds.contains(TargetConstraintKind.moonSeparationMin),
          onTap: () => onSelect(TargetConstraintKind.moonSeparationMin),
        ),
        _KindCard(
          key: const ValueKey('wizard-kind-horizon'),
          kind: TargetConstraintKind.customHorizon,
          icon: LucideIcons.mountain,
          title: 'Custom horizon',
          body: 'Respect terrain blocking from a saved horizon profile.',
          selected: selected == TargetConstraintKind.customHorizon,
          disabled: existingKinds.contains(TargetConstraintKind.customHorizon),
          onTap: () => onSelect(TargetConstraintKind.customHorizon),
        ),
        _KindCard(
          key: const ValueKey('wizard-kind-scheduledWindow'),
          kind: TargetConstraintKind.scheduledWindow,
          icon: LucideIcons.calendar,
          title: 'Scheduled window',
          body: 'Force the scheduler onto this target during these hours.',
          selected: selected == TargetConstraintKind.scheduledWindow,
          // Scheduled windows are not unique per target — multiple
          // windows can be stacked.
          disabled: false,
          onTap: () => onSelect(TargetConstraintKind.scheduledWindow),
        ),
      ],
    );
  }
}

class _KindCard extends StatelessWidget {
  final TargetConstraintKind kind;
  final IconData icon;
  final String title;
  final String body;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;

  const _KindCard({
    super.key,
    required this.kind,
    required this.icon,
    required this.title,
    required this.body,
    required this.selected,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final borderColor = selected
        ? colors.primary
        : disabled
            ? colors.border.withValues(alpha: 0.4)
            : colors.border;
    final bg = selected
        ? colors.primary.withValues(alpha: 0.08)
        : disabled
            ? colors.surfaceHover
            : colors.well;
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: disabled ? null : onTap,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          child: Container(
            padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
            decoration: BoxDecoration(
              color: bg,
              borderRadius:
                  BorderRadius.circular(SkotiqTokens.radiusInline8),
              border: Border.all(color: borderColor, width: selected ? 2 : 1),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon,
                    size: SkotiqTokens.iconMd,
                    color: disabled
                        ? colors.textMuted
                        : selected
                            ? colors.primary
                            : colors.textSecondary),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            title,
                            style: SkotiqTypography.bodyStrong.copyWith(
                                color: disabled
                                    ? colors.textMuted
                                    : colors.textPrimary),
                          ),
                          if (disabled) ...[
                            const SizedBox(width: SkotiqTokens.spaceSm),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: colors.surfaceHover,
                                borderRadius: BorderRadius.circular(
                                    SkotiqTokens.radiusLg),
                                border: Border.all(color: colors.border),
                              ),
                              child: Text(
                                'already added',
                                style: SkotiqTypography.caption
                                    .copyWith(color: colors.textMuted),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        body,
                        style: SkotiqTypography.caption.copyWith(
                            color: disabled
                                ? colors.textMuted
                                : colors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
