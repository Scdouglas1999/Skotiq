part of '../target_constraints_editor.dart';

class _AddConstraintButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _AddConstraintButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SkotiqButton(
      key: const ValueKey('add-constraint-button'),
      label: 'Add constraint',
      icon: LucideIcons.plus,
      size: ButtonSize.small,
      variant: ButtonVariant.secondary,
      onPressed: onPressed,
    );
  }
}

/// 3-step wizard for creating a new constraint. The dialog itself owns the
/// step state — selecting a kind on step 1 prefills sensible defaults so
/// step 2 starts useful immediately. The wizard returns the persisted
/// [TargetConstraint] via `Navigator.pop` on Save.
class _AddConstraintWizardDialog extends StatefulWidget {
  final int targetId;
  final String targetName;
  final List<HorizonProfile> horizonProfiles;
  final Set<TargetConstraintKind> existingKinds;

  const _AddConstraintWizardDialog({
    required this.targetId,
    required this.targetName,
    required this.horizonProfiles,
    required this.existingKinds,
  });

  @override
  State<_AddConstraintWizardDialog> createState() =>
      _AddConstraintWizardDialogState();
}

class _AddConstraintWizardDialogState
    extends State<_AddConstraintWizardDialog> {
  int _step = 1;
  TargetConstraintKind? _kind;
  TargetTimeWindow _timeWindow = const TargetTimeWindow(
    startMinutes: 22 * 60,
    endMinutes: 2 * 60,
  );
  double _moonMax = 0.30;
  // 30° is the separation NINA's default avoidance curve reaches at full moon
  // and the value this app's own planner filter seeds.
  double _moonSeparationDeg = 30.0;
  int? _horizonId;
  late ScheduledWindow _scheduledWindow;

  @override
  void initState() {
    super.initState();
    if (widget.horizonProfiles.isNotEmpty) {
      _horizonId = widget.horizonProfiles.first.id;
    }
    final now = DateTime.now();
    // Defaults: today's sunset → tomorrow's sunrise approximated as
    // 20:00 → 06:00 local. Astronomical twilight varies by latitude /
    // time of year; this is the operator-friendly fallback that's
    // obviously editable on the next step.
    final start = DateTime(now.year, now.month, now.day, 20, 0);
    final end = start.add(const Duration(hours: 10));
    _scheduledWindow = ScheduledWindow(
      startUtc: start.toUtc(),
      endUtc: end.toUtc(),
      priorityBoost: 0.5,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        side: BorderSide(color: colors.border),
      ),
      child: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 540,
          designMaxHeight: 680,
        ),
        child: Padding(
          padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _WizardHeader(step: _step, colors: colors),
              const SizedBox(height: SkotiqTokens.spaceMd),
              Flexible(
                child: SingleChildScrollView(
                  child: _buildStep(colors),
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceLg),
              _buildFooter(colors),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep(SkotiqColors colors) {
    switch (_step) {
      case 1:
        return _Step1ChooseKind(
          existingKinds: widget.existingKinds,
          selected: _kind,
          onSelect: (k) {
            setState(() {
              _kind = k;
            });
          },
        );
      case 2:
        return _Step2Params(
          targetName: widget.targetName,
          kind: _kind!,
          timeWindow: _timeWindow,
          moonMax: _moonMax,
          moonSeparationDeg: _moonSeparationDeg,
          horizonId: _horizonId,
          horizonProfiles: widget.horizonProfiles,
          scheduledWindow: _scheduledWindow,
          onTimeWindow: (w) => setState(() => _timeWindow = w),
          onMoonMax: (v) => setState(() => _moonMax = v),
          onMoonSeparation: (v) => setState(() => _moonSeparationDeg = v),
          onHorizon: (id) => setState(() => _horizonId = id),
          onScheduledWindow: (w) => setState(() => _scheduledWindow = w),
        );
      case 3:
        return _Step3Review(
          targetName: widget.targetName,
          kind: _kind!,
          timeWindow: _timeWindow,
          moonMax: _moonMax,
          moonSeparationDeg: _moonSeparationDeg,
          horizonId: _horizonId,
          horizonProfiles: widget.horizonProfiles,
          scheduledWindow: _scheduledWindow,
        );
      default:
        throw StateError('Unknown wizard step: $_step');
    }
  }

  Widget _buildFooter(SkotiqColors colors) {
    final canAdvance = _step == 1
        ? _kind != null
        : !(_step == 2 &&
            _kind == TargetConstraintKind.customHorizon &&
            (widget.horizonProfiles.isEmpty || _horizonId == null));
    return Row(
      children: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () => Navigator.of(context).pop(),
        ),
        const Spacer(),
        if (_step > 1)
          SkotiqButton(
            key: const ValueKey('wizard-back'),
            label: 'Back',
            icon: LucideIcons.chevronLeft,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => setState(() => _step -= 1),
          ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        if (_step < 3)
          SkotiqButton(
            key: const ValueKey('wizard-next'),
            label: 'Next',
            icon: LucideIcons.chevronRight,
            size: ButtonSize.small,
            onPressed: canAdvance ? () => setState(() => _step += 1) : null,
          )
        else
          SkotiqButton(
            key: const ValueKey('wizard-save'),
            label: 'Save',
            icon: LucideIcons.check,
            size: ButtonSize.small,
            onPressed: _save,
          ),
      ],
    );
  }

  void _save() {
    final TargetConstraint c;
    switch (_kind!) {
      case TargetConstraintKind.timeWindow:
        c = TargetConstraint(
          targetId: widget.targetId,
          kind: _kind!,
          timeWindow: _timeWindow,
        );
        break;
      case TargetConstraintKind.moonIlluminationMax:
        c = TargetConstraint(
          targetId: widget.targetId,
          kind: _kind!,
          moonIlluminationMax: _moonMax,
        );
        break;
      case TargetConstraintKind.moonSeparationMin:
        c = TargetConstraint(
          targetId: widget.targetId,
          kind: _kind!,
          moonSeparationMinDeg: _moonSeparationDeg,
        );
        break;
      case TargetConstraintKind.customHorizon:
        if (_horizonId == null) {
          throw StateError(
            'customHorizon step reached step 3 with no horizon profile id; '
            'wizard step 2 must enforce a selection.',
          );
        }
        c = TargetConstraint(
          targetId: widget.targetId,
          kind: _kind!,
          customHorizonId: _horizonId,
        );
        break;
      case TargetConstraintKind.scheduledWindow:
        c = TargetConstraint(
          targetId: widget.targetId,
          kind: _kind!,
          scheduledWindow: _scheduledWindow,
        );
        break;
    }
    Navigator.of(context).pop(c);
  }
}
