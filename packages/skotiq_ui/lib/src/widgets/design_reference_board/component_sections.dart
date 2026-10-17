part of '../design_reference_board.dart';

// Components

class _ComponentsSection extends StatelessWidget {
  const _ComponentsSection({required this.colors});

  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return ShowcaseSection.boxed(
      title: 'Components',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SubLabel('Buttons', colors: colors),
          const SizedBox(height: SkotiqTokens.spaceSm),
          const Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              SkotiqButton(
                label: 'Capture',
                icon: LucideIcons.camera,
                onPressed: _noop,
              ),
              SkotiqButton(
                label: 'Settings',
                icon: LucideIcons.settings,
                variant: ButtonVariant.outline,
                onPressed: _noop,
              ),
              SkotiqButton(
                label: 'More',
                icon: LucideIcons.moreHorizontal,
                variant: ButtonVariant.ghost,
                onPressed: _noop,
              ),
              SkotiqButton(
                label: 'Stop',
                icon: LucideIcons.octagon,
                variant: ButtonVariant.destructive,
                onPressed: _noop,
              ),
              SkotiqButton(label: 'Disabled', icon: LucideIcons.lock),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _SubLabel('Cards', colors: colors),
          const SizedBox(height: SkotiqTokens.spaceSm),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _CardSpecimen(
                  title: 'STANDARD',
                  value: 'Ready',
                  variant: CardVariant.standard,
                ),
              ),
              SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: _CardSpecimen(
                  title: 'ELEVATED',
                  value: 'Guiding',
                  variant: CardVariant.elevated,
                ),
              ),
              SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: _CardSpecimen(
                  title: 'SELECTED',
                  value: 'Profile A',
                  variant: CardVariant.standard,
                  isSelected: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _SubLabel('Inputs', colors: colors),
          const SizedBox(height: SkotiqTokens.spaceSm),
          const SkotiqTextField(
            label: 'Target',
            initialValue: 'M31',
            prefixIcon: LucideIcons.search,
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          const SkotiqTextField(
            label: 'Exposure',
            initialValue: '120',
            suffix: 'sec',
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Row(
            children: [
              const SkotiqSwitch(value: true, onChanged: _noopBool),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                'Cooling',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceLg),
              const SkotiqCheckbox(
                value: true,
                onChanged: _noopNullableBool,
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                'Autosave',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _SubLabel('Sub-tabs', colors: colors),
          const SizedBox(height: SkotiqTokens.spaceSm),
          const Row(
            children: [
              SubTabButton(label: 'Capture', isSelected: true, onTap: _noop),
              SubTabButton(label: 'Focus', isSelected: false, onTap: _noop),
              SubTabButton(label: 'Guiding', isSelected: false, onTap: _noop),
            ],
          ),
        ],
      ),
    );
  }
}

// Status + feedback

class _StatusAndFeedbackSection extends StatelessWidget {
  const _StatusAndFeedbackSection({required this.colors});

  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return ShowcaseSection.boxed(
      title: 'Status & feedback',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SubLabel('Status pills', colors: colors),
          const SizedBox(height: SkotiqTokens.spaceSm),
          const Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              StatusPill(
                icon: LucideIcons.radio,
                label: 'Camera',
                value: 'Connected',
                status: StatusPillStatus.active,
              ),
              StatusPill(
                icon: LucideIcons.checkCircle2,
                label: 'Solver',
                value: 'Solved',
                status: StatusPillStatus.success,
              ),
              StatusPill(
                icon: LucideIcons.cloudRain,
                label: 'Weather',
                value: 'Warning',
                status: StatusPillStatus.warning,
              ),
              StatusPill(
                icon: LucideIcons.wifiOff,
                label: 'Mount',
                value: 'Offline',
                status: StatusPillStatus.error,
              ),
              StatusPill(
                icon: LucideIcons.circleDashed,
                label: 'Rotator',
                value: 'Idle',
                status: StatusPillStatus.inactive,
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _SubLabel('Status dots', colors: colors),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Row(
            children: [
              StatusDot(color: colors.success),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                'Online',
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceLg),
              StatusDot(
                color: colors.warning,
                variant: StatusDotVariant.attention,
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                'Attention',
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceLg),
              StatusDot(color: colors.error, variant: StatusDotVariant.urgent),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                'Urgent',
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _SubLabel('Progress', colors: colors),
          const SizedBox(height: SkotiqTokens.spaceSm),
          const SkotiqProgressBar(
            value: 0.64,
            label: 'Sequence progress',
            showPercentage: true,
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          const SkotiqProgressBar(
            value: 0.4,
            state: SkotiqProgressState.warning,
            label: 'Disk usage',
            showPercentage: true,
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _SubLabel('Alerts', colors: colors),
          const SizedBox(height: SkotiqTokens.spaceSm),
          const SkotiqAlert(
            title: 'Self-test complete',
            message: 'Backend, storage, and route metadata passed.',
            severity: SkotiqAlertSeverity.info,
            compact: true,
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          const SkotiqAlert(
            title: 'Unsafe weather',
            message: 'Sequence start is blocked until safety clears.',
            severity: SkotiqAlertSeverity.warning,
            compact: true,
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          const SkotiqAlert(
            title: 'Restore failed',
            message: 'Backup file is missing a version field.',
            severity: SkotiqAlertSeverity.error,
            compact: true,
          ),
        ],
      ),
    );
  }
}

// Layout primitives (ScreenHeader / SectionHeader / SectionWell)

class _LayoutPrimitivesSection extends StatelessWidget {
  const _LayoutPrimitivesSection({required this.colors});

  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SubLabel('ScreenHeader', colors: colors),
        const SizedBox(height: SkotiqTokens.spaceSm),
        ClipRRect(
          borderRadius: SkotiqTokens.borderRadiusSm,
          child: const ScreenHeader(
            title: 'Sequencer',
            subtitle: 'Build and run unattended imaging sequences',
            icon: LucideIcons.listOrdered,
            trailing: SkotiqButton(
              label: 'Run',
              icon: LucideIcons.play,
              size: ButtonSize.small,
              onPressed: _noop,
            ),
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        _SubLabel('SectionHeader + SectionWell', colors: colors),
        const SizedBox(height: SkotiqTokens.spaceSm),
        SectionWell(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(
                title: 'Cooling',
                subtitle: 'Set point and ramp behavior',
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              Row(
                children: [
                  const SkotiqSwitch(value: true, onChanged: _noopBool),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Text(
                    'Cool camera before capture',
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
