part of '../target_constraints_editor.dart';

class _ConstraintBody extends StatelessWidget {
  final TargetConstraint constraint;
  final List<HorizonProfile> horizonProfiles;
  final Future<void> Function(TargetConstraint) onChange;

  const _ConstraintBody({
    required this.constraint,
    required this.horizonProfiles,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    switch (constraint.kind) {
      case TargetConstraintKind.timeWindow:
        return _TimeWindowField(
          window: constraint.timeWindow ??
              const TargetTimeWindow(
                startMinutes: 22 * 60,
                endMinutes: 5 * 60,
              ),
          onChange: (w) => onChange(constraint.copyWith(timeWindow: w)),
        );
      case TargetConstraintKind.moonIlluminationMax:
        return _MoonField(
          value: constraint.moonIlluminationMax ?? 0.5,
          onChange: (v) =>
              onChange(constraint.copyWith(moonIlluminationMax: v)),
        );
      case TargetConstraintKind.moonSeparationMin:
        return _MoonSeparationField(
          degrees: constraint.moonSeparationMinDeg ?? 30.0,
          onChange: (v) =>
              onChange(constraint.copyWith(moonSeparationMinDeg: v)),
        );
      case TargetConstraintKind.customHorizon:
        return _HorizonField(
          selectedId: constraint.customHorizonId,
          profiles: horizonProfiles,
          onChange: (id) => onChange(constraint.copyWith(customHorizonId: id)),
        );
      case TargetConstraintKind.scheduledWindow:
        return _ScheduledWindowField(
          window: constraint.scheduledWindow ??
              ScheduledWindow(
                startUtc: DateTime.now().toUtc(),
                endUtc: DateTime.now().toUtc().add(const Duration(hours: 6)),
                priorityBoost: 0.5,
              ),
          onChange: (w) => onChange(constraint.copyWith(scheduledWindow: w)),
        );
    }
  }
}

class _TimeWindowField extends StatelessWidget {
  final TargetTimeWindow window;
  final void Function(TargetTimeWindow) onChange;
  const _TimeWindowField({required this.window, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Row(
      children: [
        OutlinedButton.icon(
          icon: const Icon(LucideIcons.clock, size: 14),
          onPressed: () => _pickStart(context),
          label: Text(_format(window.startMinutes)),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Text('to',
            style: SkotiqTypography.body.copyWith(color: colors.textSecondary)),
        const SizedBox(width: SkotiqTokens.spaceSm),
        OutlinedButton.icon(
          icon: const Icon(LucideIcons.clock, size: 14),
          onPressed: () => _pickEnd(context),
          label: Text(_format(window.endMinutes)),
        ),
        if (window.endMinutes < window.startMinutes) ...[
          const SizedBox(width: SkotiqTokens.spaceSm),
          // Flexible: the two time buttons and the word "to" have first claim
          // on the row, and the note about midnight is the part that can wrap
          // away. The Observatory scale raised `body` from 13 to 14, which is
          // what pushed this row 11px over its box.
          Flexible(
            child: Text(
              '(crosses midnight)',
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _pickStart(BuildContext context) async {
    final tod = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: window.startMinutes ~/ 60,
        minute: window.startMinutes % 60,
      ),
    );
    if (tod == null) return;
    onChange(TargetTimeWindow(
      startMinutes: tod.hour * 60 + tod.minute,
      endMinutes: window.endMinutes,
    ));
  }

  Future<void> _pickEnd(BuildContext context) async {
    final tod = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: window.endMinutes ~/ 60,
        minute: window.endMinutes % 60,
      ),
    );
    if (tod == null) return;
    onChange(TargetTimeWindow(
      startMinutes: window.startMinutes,
      endMinutes: tod.hour * 60 + tod.minute,
    ));
  }

  String _format(int mins) {
    final h = mins ~/ 60;
    final m = mins % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }
}

class _MoonField extends StatelessWidget {
  final double value;
  final void Function(double) onChange;
  const _MoonField({required this.value, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Row(
      children: [
        Expanded(
          child: Slider(
            value: value.clamp(0.0, 1.0),
            min: 0.0,
            max: 1.0,
            divisions: 100,
            label: '${(value * 100).round()} %',
            onChanged: onChange,
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            '${(value * 100).round()} %',
            textAlign: TextAlign.right,
            style: SkotiqTypography.caption.copyWith(
                color: colors.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// Minimum target-to-moon angular separation, in degrees.
class _MoonSeparationField extends StatelessWidget {
  final double degrees;
  final void Function(double) onChange;
  const _MoonSeparationField({required this.degrees, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Row(
      children: [
        Expanded(
          child: Slider(
            value: degrees.clamp(0.0, 180.0),
            min: 0.0,
            max: 180.0,
            divisions: 180,
            label: '${degrees.round()}°',
            onChanged: onChange,
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            '${degrees.round()}°',
            textAlign: TextAlign.right,
            style: SkotiqTypography.caption.copyWith(
                color: colors.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _HorizonField extends StatelessWidget {
  final int? selectedId;
  final List<HorizonProfile> profiles;
  final void Function(int) onChange;

  const _HorizonField({
    required this.selectedId,
    required this.profiles,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    if (profiles.isEmpty) {
      return Text(
        'No horizon profiles defined yet.',
        style: SkotiqTypography.caption.copyWith(color: colors.warning),
      );
    }
    return AccessibleDropdown<int>(
      value: selectedId,
      isExpanded: true,
      hint: const Text('Choose horizon profile'),
      items: [
        for (final p in profiles)
          DropdownMenuItem(value: p.id!, child: Text(p.name)),
      ],
      onChanged: (id) {
        if (id != null) onChange(id);
      },
    );
  }
}

class _ScheduledWindowField extends StatelessWidget {
  final ScheduledWindow window;
  final void Function(ScheduledWindow) onChange;
  const _ScheduledWindowField({required this.window, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final startLocal = window.startUtc.toLocal();
    final endLocal = window.endUtc.toLocal();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: SkotiqTokens.spaceSm,
          runSpacing: SkotiqTokens.spaceSm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              icon: const Icon(LucideIcons.calendar, size: 14),
              onPressed: () => _pickStart(context),
              label: Text('Start ${_fmt(startLocal)}'),
            ),
            Text('to',
                style: SkotiqTypography.body
                    .copyWith(color: colors.textSecondary)),
            OutlinedButton.icon(
              icon: const Icon(LucideIcons.calendar, size: 14),
              onPressed: () => _pickEnd(context),
              label: Text('End ${_fmt(endLocal)}'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            SizedBox(
              width: 92,
              child: Text(
                'Priority boost',
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textSecondary),
              ),
            ),
            Expanded(
              child: Slider(
                value: window.priorityBoost.clamp(0.1, 1.0),
                min: 0.1,
                max: 1.0,
                divisions: 9,
                label: '+${window.priorityBoost.toStringAsFixed(1)}',
                onChanged: (v) => onChange(ScheduledWindow(
                  startUtc: window.startUtc,
                  endUtc: window.endUtc,
                  priorityBoost: v,
                )),
              ),
            ),
            SizedBox(
              width: 36,
              child: Text(
                '+${window.priorityBoost.toStringAsFixed(1)}',
                textAlign: TextAlign.right,
                style: SkotiqTypography.caption.copyWith(
                    color: colors.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickStart(BuildContext context) async {
    final picked = await _pickDateTime(context, window.startUtc.toLocal());
    if (picked == null) return;
    onChange(ScheduledWindow(
      startUtc: picked.toUtc(),
      endUtc: window.endUtc,
      priorityBoost: window.priorityBoost,
    ));
  }

  Future<void> _pickEnd(BuildContext context) async {
    final picked = await _pickDateTime(context, window.endUtc.toLocal());
    if (picked == null) return;
    onChange(ScheduledWindow(
      startUtc: window.startUtc,
      endUtc: picked.toUtc(),
      priorityBoost: window.priorityBoost,
    ));
  }

  String _fmt(DateTime t) {
    final mm = t.month.toString().padLeft(2, '0');
    final dd = t.day.toString().padLeft(2, '0');
    final hh = t.hour.toString().padLeft(2, '0');
    final mn = t.minute.toString().padLeft(2, '0');
    return '$mm/$dd $hh:$mn';
  }
}

Future<DateTime?> _pickDateTime(BuildContext context, DateTime initial) async {
  final date = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime.now().subtract(const Duration(days: 1)),
    lastDate: DateTime.now().add(const Duration(days: 365)),
  );
  if (date == null) return null;
  if (!context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
  );
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}
