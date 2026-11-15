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
    // The kind and its switch on one line, its values on the next, so the
    // row fits the detail column as well as a dialog.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SkotiqSwitch(
                value: c.enabled,
                onChanged: (v) => widget.onChange(c.copyWith(enabled: v)),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  _kindLabel(c.kind),
                  style: SkotiqTypography.bodyStrong.copyWith(
                    color: c.enabled ? colors.textPrimary : colors.textMuted,
                  ),
                ),
              ),
              SkotiqIconButton(
                icon: LucideIcons.trash2,
                tooltip: 'Remove constraint',
                size: IconButtonSize.sm,
                onPressed: widget.onDelete,
              ),
            ],
          ),
          _ConstraintBody(
            constraint: c,
            horizonProfiles: widget.horizonProfiles,
            onChange: widget.onChange,
          ),
        ],
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
