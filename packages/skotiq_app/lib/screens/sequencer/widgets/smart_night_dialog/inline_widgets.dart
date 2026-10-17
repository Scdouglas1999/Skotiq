part of '../smart_night_dialog.dart';

// Inline widgets

class _StepChip extends StatelessWidget {
  final String label;
  final SkotiqColors colors;
  final bool isActive;
  final bool isComplete;

  const _StepChip({
    required this.label,
    required this.colors,
    required this.isActive,
    required this.isComplete,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isActive
        ? colors.primary
        : (isComplete ? colors.surfaceAlt : Colors.transparent);
    final fg = isActive
        ? colors.onPrimary
        : (isComplete ? colors.textPrimary : colors.textSecondary);
    final border = isActive ? colors.primary : colors.border;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: SkotiqTypography.labelQuiet.copyWith(color: fg),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final String label;
  final Widget child;
  final SkotiqColors colors;

  const _SettingsRow({
    required this.label,
    required this.child,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: SkotiqTypography.fontSize12,
              ),
            ),
          ),
          SizedBox(
              width: 140,
              child: Align(
                alignment: Alignment.centerRight,
                child: child,
              )),
        ],
      ),
    );
  }
}

class _CompactNumberField extends StatefulWidget {
  final double initial;
  final String suffix;
  final void Function(double) onChanged;

  const _CompactNumberField({
    required this.initial,
    required this.suffix,
    required this.onChanged,
  });

  @override
  State<_CompactNumberField> createState() => _CompactNumberFieldState();
}

class _CompactNumberFieldState extends State<_CompactNumberField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial.toStringAsFixed(0));

  @override
  void didUpdateWidget(covariant _CompactNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When the parent clamps a submitted value (e.g. 50 -> 10) the displayed
    // text would otherwise keep showing the raw input while the effective
    // setting is the clamped one. Re-sync only when the incoming value moved
    // and the field isn't already showing it, so valid in-range typing isn't
    // disturbed.
    if (widget.initial != oldWidget.initial &&
        double.tryParse(_controller.text.trim()) != widget.initial) {
      _controller.text = widget.initial.toStringAsFixed(0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 60,
          child: TextField(
            controller: _controller,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
            ),
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: colors.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
              ),
            ),
            onSubmitted: (text) {
              final v = double.tryParse(text.trim());
              if (v != null) widget.onChanged(v);
            },
            onEditingComplete: () {
              final v = double.tryParse(_controller.text.trim());
              if (v != null) widget.onChanged(v);
            },
          ),
        ),
        if (widget.suffix.isNotEmpty) ...[
          const SizedBox(width: 4),
          Text(
            widget.suffix,
            style: TextStyle(
                color: colors.textSecondary,
                fontSize: SkotiqTypography.fontSize11),
          ),
        ],
      ],
    );
  }
}

class _MissingLocationCard extends StatelessWidget {
  final SkotiqColors colors;
  const _MissingLocationCard({required this.colors});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: SkotiqDecorations.emphasisSurface(
        colors.warning,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.mapPin, color: colors.warning, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'No observer location set — open Settings → Location and '
              'enter your latitude / longitude. Smart Night needs them to '
              'compute the dark window.',
              style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: SkotiqTypography.fontSize13),
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowUnavailableCard extends StatelessWidget {
  final SkotiqColors colors;
  final String message;

  const _WindowUnavailableCard({
    required this.colors,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: SkotiqDecorations.emphasisSurface(
        colors.error,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.sun, color: colors.error, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: SkotiqTypography.fontSize13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MissingProfileCard extends StatelessWidget {
  final SkotiqColors colors;
  const _MissingProfileCard({required this.colors});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.alertTriangle, size: 32, color: colors.error),
            const SizedBox(height: 10),
            Text(
              'No active equipment profile',
              style: TextStyle(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Open the Equipment screen and activate a profile before '
              'running Smart Night.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: SkotiqTypography.fontSize12),
            ),
          ],
        ),
      ),
    );
  }
}

/// Banner shown on the Targets step when the wizard was opened seeded from a
/// project (C11 handoff). States the source campaign and, when some of the
/// campaign's targets are below tonight's cut-offs, names them so the operator
/// is not surprised that they aren't in the plan.
class _SeedSourceBanner extends StatelessWidget {
  final String label;
  final List<String> missingNames;
  final SkotiqColors colors;

  const _SeedSourceBanner({
    required this.label,
    required this.missingNames,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    if (missingNames.isEmpty) {
      return SkotiqInlineBanner(
        severity: SkotiqAlertSeverity.info,
        message: 'Pre-selected the incomplete targets from "$label". '
            'Adjust the selection below if you like.',
      );
    }
    final names = missingNames.join(', ');
    return SkotiqInlineBanner(
      severity: SkotiqAlertSeverity.warning,
      message: 'Pre-selected the incomplete targets from "$label". '
          '${missingNames.length} '
          '($names) are below tonight\'s altitude / score cut-offs and '
          'won\'t be planned tonight.',
    );
  }
}

class _EmptyTargetsCard extends StatelessWidget {
  final SkotiqColors colors;
  const _EmptyTargetsCard({required this.colors});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.search, size: 28, color: colors.textMuted),
            const SizedBox(height: 8),
            Text(
              'No saved targets scored above the cut-off tonight',
              style: TextStyle(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Add targets in the Planner or lower the min-altitude / '
              'min-score knobs in suggestion settings.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: SkotiqTypography.fontSize12),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final SkotiqColors colors;

  const _ProfileRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: colors.textMuted),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: SkotiqTypography.fontSize12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style:
                  SkotiqTypography.labelSm.copyWith(color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _StrategyTile extends StatelessWidget {
  final SmartNightStrategy strategy;
  final bool isSelected;
  final bool filtersAvailable;
  final VoidCallback onSelected;
  final SkotiqColors colors;

  const _StrategyTile({
    required this.strategy,
    required this.isSelected,
    required this.filtersAvailable,
    required this.onSelected,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final descriptors = _descriptors(strategy);
    return InkWell(
      onTap: filtersAvailable ? onSelected : null,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? SkotiqDecorations.tintedBadge(
                  colors.primary,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                ).color
              : colors.surfaceAlt,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          border: Border.all(
            color: isSelected ? colors.primary : colors.border,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? LucideIcons.circleDot : LucideIcons.circle,
              size: 18,
              color: isSelected ? colors.primary : colors.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    descriptors.title,
                    style: TextStyle(
                      color: filtersAvailable
                          ? colors.textPrimary
                          : colors.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    descriptors.subtitle,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: SkotiqTypography.fontSize11,
                    ),
                  ),
                ],
              ),
            ),
            if (!filtersAvailable)
              Tooltip(
                message: 'Needs filters this profile doesn\'t have',
                child: Icon(LucideIcons.alertTriangle,
                    size: 14, color: colors.warning),
              ),
          ],
        ),
      ),
    );
  }

  ({String title, String subtitle}) _descriptors(SmartNightStrategy s) {
    switch (s) {
      case SmartNightStrategy.autoLrgb:
        return (
          title: 'Auto-balance LRGB',
          subtitle: 'L weighted 2x R/G/B; default for broadband nights.',
        );
      case SmartNightStrategy.monoLrgb:
        return (
          title: 'Mono LRGB (even)',
          subtitle: 'Equal time per L/R/G/B; classic mono workflow.',
        );
      case SmartNightStrategy.narrowbandHoo:
        return (
          title: 'Narrowband HOO',
          subtitle: 'Ha + OIII bicolor — emission nebulae, bright-moon nights.',
        );
      case SmartNightStrategy.narrowbandSho:
        return (
          title: 'Narrowband SHO (Hubble)',
          subtitle: 'Ha + OIII + SII tricolor.',
        );
      case SmartNightStrategy.oscOneShot:
        return (
          title: 'OSC One-Shot',
          subtitle: 'Single light filter — Bayer cameras and L-eXtreme.',
        );
    }
  }
}

class _AfCadenceSelector extends StatelessWidget {
  final SmartNightSettings value;
  final void Function(SmartNightSettings) onChanged;
  final SkotiqColors colors;

  const _AfCadenceSelector({
    required this.value,
    required this.onChanged,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final c in SmartNightAfCadence.values)
          ChoiceChip(
            label: Text(_labelFor(c)),
            selected: value.afCadence == c,
            onSelected: (_) => onChanged(value.copyWith(afCadence: c)),
          ),
      ],
    );
  }

  String _labelFor(SmartNightAfCadence c) {
    switch (c) {
      case SmartNightAfCadence.everyNFrames:
        return 'Every ${value.afEveryFrames} frames';
      case SmartNightAfCadence.everyNMinutes:
        return 'Every ${value.afEveryMinutes} min';
      case SmartNightAfCadence.onTempDelta:
        return 'On Δ${value.afTempDeltaC.toStringAsFixed(1)}°C';
    }
  }
}

class _TargetTile extends StatelessWidget {
  final TargetSuggestion suggestion;
  final bool isSelected;
  final bool isAutoMode;
  final int rank;
  final bool autoPickedTop;
  final VoidCallback onToggle;
  final SkotiqColors colors;

  const _TargetTile({
    required this.suggestion,
    required this.isSelected,
    required this.isAutoMode,
    required this.rank,
    required this.autoPickedTop,
    required this.onToggle,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final autoBorder = (isAutoMode && autoPickedTop);
    return InkWell(
      onTap: isAutoMode ? null : onToggle,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isSelected
              ? SkotiqDecorations.tintedBadge(
                  colors.primary,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                ).color
              : colors.surfaceAlt,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          border: Border.all(
            color: autoBorder
                ? colors.primary
                : (isSelected ? colors.primary : colors.border),
          ),
        ),
        child: Row(
          children: [
            if (!isAutoMode)
              SkotiqCheckbox(
                value: isSelected,
                onChanged: (_) => onToggle(),
              ),
            Container(
              width: 32,
              alignment: Alignment.center,
              child: Text(
                '#$rank',
                style: SkotiqTypography.labelStrongSm
                    .copyWith(color: colors.textMuted),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    suggestion.targetName,
                    style: SkotiqTypography.labelStrong
                        .copyWith(color: colors.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    suggestion.reasoning.isEmpty
                        ? '${suggestion.objectType ?? "target"} · '
                            'score ${suggestion.totalScore.toStringAsFixed(0)}'
                        : suggestion.reasoning,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: SkotiqTypography.fontSize11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: SkotiqDecorations.emphasisSurface(
                colors.primary,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
              ),
              child: Text(
                '${suggestion.totalScore.toStringAsFixed(0)}/100',
                style: SkotiqTypography.labelStrongSm
                    .copyWith(color: colors.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanSummary extends StatelessWidget {
  final SmartNightPlan plan;

  const _PlanSummary({required this.plan});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Tonight: ${plan.plannedTargets.length} '
              'target${plan.plannedTargets.length == 1 ? '' : 's'}, '
              '${(plan.totalIntegrationSecs / 3600).toStringAsFixed(1)}h '
              'integration',
          subtitle: 'Estimated wall-clock: '
              '${(plan.estimatedWallClockSecs / 3600).toStringAsFixed(1)}h '
              '(includes slews, AF, dither, downloads).',
        ),
      ],
    );
  }
}

class _PlannedTargetCard extends StatelessWidget {
  final SmartNightPlannedTarget planned;
  final SkotiqColors colors;
  final void Function(int filterIndex, int delta) onCountChanged;

  const _PlannedTargetCard({
    required this.planned,
    required this.colors,
    required this.onCountChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SkotiqCard(
        padding: const EdgeInsets.all(12),
        borderRadius: SkotiqTokens.radiusInline8,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.target, size: 16, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    planned.suggestion.targetName,
                    style:
                        SkotiqTypography.h5.copyWith(color: colors.textPrimary),
                  ),
                ),
                Text(
                  '${planned.suggestion.totalScore.toStringAsFixed(0)}/100',
                  style: SkotiqTypography.h6.copyWith(color: colors.primary),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              planned.rationale,
              style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: SkotiqTypography.fontSize11),
            ),
            const SizedBox(height: 8),
            _WindowBar(
              start: planned.windowStart,
              end: planned.windowEnd,
              colors: colors,
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < planned.filterPlans.length; i++)
              _FilterRow(
                plan: planned.filterPlans[i],
                colors: colors,
                onAdjust: (delta) => onCountChanged(i, delta),
              ),
            if (planned.filterPlans.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Total: '
                  '${(planned.integrationSecs / 3600).toStringAsFixed(1)}h '
                  '${planned.isUnfiltered ? 'unfiltered.' : 'across '
                      '${planned.filterPlans.length} '
                      'filter${planned.filterPlans.length == 1 ? '' : 's'}.'}',
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: SkotiqTypography.fontSize11,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  final SmartNightFilterPlan plan;
  final SkotiqColors colors;
  final void Function(int delta) onAdjust;

  const _FilterRow({
    required this.plan,
    required this.colors,
    required this.onAdjust,
  });

  @override
  Widget build(BuildContext context) {
    final integrationMins = plan.integrationSecs / 60;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 44,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: SkotiqDecorations.tintedBadge(
              colors.primary,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
            ),
            alignment: Alignment.center,
            child: Text(
              plan.isUnfiltered ? 'None' : plan.filterName,
              style: SkotiqTypography.labelStrongSm
                  .copyWith(color: colors.primary),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            icon: const Icon(LucideIcons.minus, size: 14),
            visualDensity: VisualDensity.compact,
            tooltip: 'Remove one frame',
            onPressed: () => onAdjust(-1),
          ),
          SizedBox(
            width: 56,
            child: Text(
              '${plan.count} × ${plan.durationSecs.toStringAsFixed(0)}s',
              textAlign: TextAlign.center,
              style:
                  SkotiqTypography.labelSm.copyWith(color: colors.textPrimary),
            ),
          ),
          IconButton(
            icon: const Icon(LucideIcons.plus, size: 14),
            visualDensity: VisualDensity.compact,
            tooltip: 'Add one frame',
            onPressed: () => onAdjust(1),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${integrationMins.toStringAsFixed(0)} min '
              '${plan.recommendation == null ? "" : "· ${plan.recommendation!.rationale}"}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: SkotiqTypography.fontSize11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowBar extends StatelessWidget {
  final DateTime start;
  final DateTime end;
  final SkotiqColors colors;

  const _WindowBar({
    required this.start,
    required this.end,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final mins = end.difference(start).inMinutes;
    return Row(
      children: [
        Icon(LucideIcons.clock, size: 14, color: colors.textMuted),
        const SizedBox(width: 6),
        Text(
          '${_format(start)} → ${_format(end)} '
          '(${(mins / 60).toStringAsFixed(1)}h)',
          style: TextStyle(
            color: colors.textSecondary,
            fontSize: SkotiqTypography.fontSize11,
          ),
        ),
      ],
    );
  }

  String _format(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _SummaryRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final SkotiqColors colors;

  const _SummaryRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: colors.textMuted),
          const SizedBox(width: 8),
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: SkotiqTypography.fontSize12,
              ),
            ),
          ),
          Text(
            value,
            style: SkotiqTypography.labelSm.copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    );
  }
}
