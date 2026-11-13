part of '../target_constraints_editor.dart';

class _LoadedConstraints {
  final SkotiqBackend authority;
  final TargetConstraintService service;
  final List<TargetConstraint> constraints;
  final List<HorizonProfile> horizonProfiles;
  _LoadedConstraints({
    required this.authority,
    required this.service,
    required this.constraints,
    required this.horizonProfiles,
  });
}

class _ConstraintRow extends StatefulWidget {
  final TargetConstraint constraint;
  final List<HorizonProfile> horizonProfiles;
  final Future<void> Function(TargetConstraint) onChange;
  final Future<void> Function() onDelete;

  const _ConstraintRow({
    required this.constraint,
    required this.horizonProfiles,
    required this.onChange,
    required this.onDelete,
  });

  @override
  State<_ConstraintRow> createState() => _ConstraintRowState();
}

class _ConstraintRowState extends State<_ConstraintRow> {
  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final c = widget.constraint;
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceMd,
          vertical: SkotiqTokens.spaceSm,
        ),
        decoration: BoxDecoration(
          color: c.enabled ? colors.well : colors.surfaceHover,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          children: [
            SkotiqSwitch(
              value: c.enabled,
              onChanged: (v) => widget.onChange(c.copyWith(enabled: v)),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            SizedBox(
              width: 150,
              child: Text(
                _kindLabel(c.kind),
                style: SkotiqTypography.labelStrong.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
            Expanded(
              child: _ConstraintBody(
                constraint: c,
                horizonProfiles: widget.horizonProfiles,
                onChange: widget.onChange,
              ),
            ),
            SkotiqIconButton(
              icon: LucideIcons.trash2,
              tooltip: 'Remove constraint',
              size: IconButtonSize.sm,
              color: colors.error,
              onPressed: widget.onDelete,
            ),
          ],
        ),
      ),
    );
  }

  String _kindLabel(TargetConstraintKind k) {
    switch (k) {
      case TargetConstraintKind.timeWindow:
        return 'Time window';
      case TargetConstraintKind.moonIlluminationMax:
        return 'Max moon illumination';
      case TargetConstraintKind.moonSeparationMin:
        return 'Min moon separation';
      case TargetConstraintKind.customHorizon:
        return 'Custom horizon';
      case TargetConstraintKind.scheduledWindow:
        return 'Scheduled window';
    }
  }
}
