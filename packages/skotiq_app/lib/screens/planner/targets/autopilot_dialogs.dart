part of 'plan_targets_tab.dart';

/// Why the autopilot chose what it chose: its reasoning, then every target it
/// weighed with the score and what ruled it out.
void _showWhy(BuildContext context, _AutopilotView view) {
  showDialog<void>(
    context: context,
    builder: (_) => _WhyDialog(view: view),
  );
}

class _WhyDialog extends StatefulWidget {
  const _WhyDialog({required this.view});

  final _AutopilotView view;

  @override
  State<_WhyDialog> createState() => _WhyDialogState();
}

class _WhyDialogState extends State<_WhyDialog> {
  final Set<int> _open = {};

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final decision = widget.view.decision;
    final blockers = widget.view.readiness?.blockers ?? const [];
    final rejected = {
      for (final r in decision?.rejected ?? const <RejectedCandidate>[])
        r.targetId: r,
    };
    final scoredIds = {
      for (final s in decision?.scoredCandidates ?? const <TargetScore>[])
        s.targetId,
    };
    final weighed = <_Weighed>[
      for (final s in decision?.scoredCandidates ?? const <TargetScore>[])
        _Weighed(
          targetId: s.targetId,
          name: s.targetName,
          score: s.hardConstraintFailed ? null : s.totalScore,
          reason: s.targetId == decision?.chosenTargetId
              ? 'Chosen'
              : rejected[s.targetId]?.primaryReason ??
                  (s.hardConstraintFailed
                      ? s.rejectionReasons.firstOrNull ?? 'Ruled out'
                      : 'Could be imaged'),
          failures: rejected[s.targetId]?.hardConstraintFailures ??
              s.rejectionReasons,
          factors: s.factors.isNotEmpty
              ? s.factors
              : rejected[s.targetId]?.factors ?? const [],
        ),
      for (final r in rejected.values)
        if (!scoredIds.contains(r.targetId))
          _Weighed(
            targetId: r.targetId,
            name: r.targetName,
            score: r.hardConstraintFailures.isEmpty ? r.score : null,
            reason: r.primaryReason,
            failures: r.hardConstraintFailures,
            factors: r.factors,
          ),
    ];
    final eyebrow = SkotiqTypography.eyebrow.copyWith(color: colors.textMuted);
    final muted = SkotiqTypography.bodySm.copyWith(color: colors.textSecondary);

    return SkotiqDialog(
      title: 'Why the autopilot chose this',
      width: 640,
      actions: [
        SkotiqButton(
          label: 'Close',
          variant: ButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (blockers.isNotEmpty) ...[
            Text('BEFORE IT CAN START', style: eyebrow),
            const SizedBox(height: SkotiqTokens.spaceSm),
            for (final b in blockers)
              Padding(
                padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
                child: Text('${b.title}. ${b.detail}', style: muted),
              ),
            const SizedBox(height: SkotiqTokens.spaceLg),
          ],
          Text('DECISION', style: eyebrow),
          const SizedBox(height: SkotiqTokens.spaceSm),
          if (decision == null || decision.reasoning.isEmpty)
            Text('It has not scored the targets yet.', style: muted)
          else
            for (final line in decision.reasoning)
              Padding(
                padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
                child: Text(line, style: muted),
              ),
          if (decision != null) ...[
            const SizedBox(height: SkotiqTokens.spaceXs),
            Text(
              'Scored at ${ClockFormat.hms(decision.evaluatedAt.toLocal())}',
              style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
            ),
          ],
          if (weighed.isNotEmpty) ...[
            const SizedBox(height: SkotiqTokens.spaceLg),
            Text('TARGETS IT WEIGHED', style: eyebrow),
            const SizedBox(height: SkotiqTokens.spaceXs),
            for (var i = 0; i < weighed.length; i++)
              _ScoredTarget(
                key: ValueKey('why-target-${weighed[i].targetId}'),
                target: weighed[i],
                open: _open.contains(weighed[i].targetId),
                showDivider: i < weighed.length - 1,
                onToggle: () => setState(() {
                  final id = weighed[i].targetId;
                  if (!_open.remove(id)) _open.add(id);
                }),
              ),
          ],
        ],
      ),
    );
  }
}

/// One target the autopilot weighed: its score (none when it was ruled
/// out), the short reason, and what the reason rests on.
@immutable
class _Weighed {
  const _Weighed({
    required this.targetId,
    required this.name,
    required this.score,
    required this.reason,
    required this.failures,
    required this.factors,
  });

  final int targetId;
  final String name;
  final double? score;
  final String reason;
  final List<String> failures;
  final List<ScoreFactor> factors;
}

class _ScoredTarget extends StatelessWidget {
  const _ScoredTarget({
    super.key,
    required this.target,
    required this.open,
    required this.showDivider,
    required this.onToggle,
  });

  final _Weighed target;
  final bool open;
  final bool showDivider;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final mono = SkotiqTypography.monoCaption.copyWith(
      color: colors.textSecondary,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ListRow(
          title: target.name,
          subtitle: target.reason,
          trailing: target.score?.toStringAsFixed(1),
          showDivider: showDivider && !open,
          onTap: onToggle,
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SkotiqTokens.spaceSm,
              0,
              SkotiqTokens.spaceSm,
              SkotiqTokens.spaceMd,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final failure in target.failures)
                  Text(
                    failure,
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textSecondary),
                  ),
                for (final f in target.factors)
                  Text(
                    '${f.name.padRight(16)} ${f.value.toStringAsFixed(2)}'
                    ' × ${f.weight.toStringAsFixed(1)}'
                    ' = ${f.weighted.toStringAsFixed(2)}'
                    '${f.detail == null ? '' : '   ${f.detail}'}',
                    style: mono,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The autopilot's scoring weights and switching rules.
void _showAutopilotSettings(
  BuildContext context, {
  required ValueListenable<SchedulerConfig> config,
  required ValueChanged<SchedulerConfig> onChanged,
}) {
  showDialog<void>(
    context: context,
    builder: (_) => _AutopilotSettingsDialog(config: config, onChanged: onChanged),
  );
}

class _AutopilotSettingsDialog extends ConsumerStatefulWidget {
  const _AutopilotSettingsDialog({required this.config, required this.onChanged});

  final ValueListenable<SchedulerConfig> config;
  final ValueChanged<SchedulerConfig> onChanged;

  @override
  ConsumerState<_AutopilotSettingsDialog> createState() =>
      _AutopilotSettingsDialogState();
}

class _AutopilotSettingsDialogState
    extends ConsumerState<_AutopilotSettingsDialog> {
  void _set(SchedulerConfig config) => widget.onChanged(config);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: widget.config,
        builder: (context, config, _) => _body(context, config),
      );

  Widget _body(BuildContext context, SchedulerConfig _config) {
    final colors = SkotiqColors.of(context);
    final w = _config.weights;
    final eyebrow = SkotiqTypography.eyebrow.copyWith(color: colors.textMuted);
    void weights(SchedulerWeights next) => _set(_config.copyWith(weights: next));

    return SkotiqDialog(
      title: 'Autopilot settings',
      width: 480,
      actions: [
        SkotiqButton(
          label: 'Done',
          variant: ButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('HOW MUCH EACH COUNTS', style: eyebrow),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _SettingSlider(
            label: 'Altitude',
            value: w.altitude,
            onChanged: (v) => weights(w.copyWith(altitude: v)),
          ),
          _SettingSlider(
            label: 'Near meridian',
            value: w.meridian,
            onChanged: (v) => weights(w.copyWith(meridian: v)),
          ),
          _SettingSlider(
            label: 'Moon',
            value: w.moon,
            onChanged: (v) => weights(w.copyWith(moon: v)),
          ),
          _SettingSlider(
            label: 'Time left',
            value: w.timeRemaining,
            onChanged: (v) => weights(w.copyWith(timeRemaining: v)),
          ),
          _SettingSlider(
            label: 'Filters due',
            value: w.filterCoverage,
            onChanged: (v) => weights(w.copyWith(filterCoverage: v)),
          ),
          _SettingSlider(
            label: 'Priority',
            value: w.userPriority,
            onChanged: (v) => weights(w.copyWith(userPriority: v)),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          Text('RULES', style: eyebrow),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _SettingSlider(
            key: const ValueKey('autopilot-min-altitude'),
            label: 'Min altitude',
            value: _config.minAltitudeDegrees,
            max: 60,
            divisions: 60,
            format: (v) => '${v.round()}°',
            onChanged: (v) => _set(_config.copyWith(minAltitudeDegrees: v)),
          ),
          if (ref.watch(altitudeFloorProvider).followsHorizon)
            Padding(
              padding: const EdgeInsets.only(
                left: FormRow.defaultLabelWidth + SkotiqTokens.spaceMd,
                bottom: SkotiqTokens.spaceSm,
              ),
              child: Text(
                'Not in force: the site horizon in Settings > Location '
                'decides how high a target must be while it is set.',
                key: const Key('scheduler.minAltitudeNotInForce'),
                style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
              ),
            ),
          _SettingSlider(
            label: 'Switch margin',
            value: _config.hysteresisRatio,
            min: 1,
            max: 2,
            divisions: 20,
            format: (v) => '${v.toStringAsFixed(2)}×',
            help: 'How much better another target must score before the '
                'autopilot leaves the one it is on.',
            onChanged: (v) => _set(_config.copyWith(hysteresisRatio: v)),
          ),
        ],
      ),
    );
  }
}

/// A labelled slider with its value at the right.
class _SettingSlider extends StatelessWidget {
  const _SettingSlider({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 3,
    this.divisions = 30,
    this.format,
    this.help,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double value)? format;
  final String? help;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return FormRow(
      label: label,
      help: help,
      child: Row(
        children: [
          Expanded(
            child: SkotiqSlider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              format?.call(value) ?? value.toStringAsFixed(1),
              textAlign: TextAlign.right,
              style: SkotiqTypography.readoutXs.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
