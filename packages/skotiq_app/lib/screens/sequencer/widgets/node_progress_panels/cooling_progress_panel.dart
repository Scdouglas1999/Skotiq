part of '../node_progress_panels.dart';

class _ProgressPanelContainer extends StatelessWidget {
  final SkotiqColors colors;
  final Widget child;
  final Color? accentColor;

  const _ProgressPanelContainer({
    required this.colors,
    required this.child,
    this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final accent = accentColor ?? colors.info;
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: SkotiqDecorations.emphasisSurface(
        accent,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      ),
      child: child,
    );
  }
}

/// Progress panel for cooling/warming operations
class _CoolingProgressPanel extends StatelessWidget {
  final SkotiqColors colors;
  final double progressPercent;
  final String detail;
  final bool isWarming;

  const _CoolingProgressPanel({
    required this.colors,
    required this.progressPercent,
    required this.detail,
    required this.isWarming,
  });

  @override
  Widget build(BuildContext context) {
    // Parse detail string: "Cooling: 15.2°C → -10.0°C (85% power)"
    // or "At target: -10.3°C (45% power)"
    final tempMatch = RegExp(r'(-?\d+\.?\d*)°C').allMatches(detail);
    final powerMatch = RegExp(r'(\d+\.?\d*)% power').firstMatch(detail);

    double? currentTemp;
    double? targetTemp;
    double? power;

    if (tempMatch.isNotEmpty) {
      final temps = tempMatch
          .map((m) => double.tryParse(m.group(1) ?? ''))
          .whereType<double>()
          .toList();
      if (temps.isNotEmpty) currentTemp = temps[0];
      if (temps.length > 1) targetTemp = temps[1];
    }
    if (powerMatch != null) {
      power = double.tryParse(powerMatch.group(1) ?? '');
    }

    return _ProgressPanelContainer(
      colors: colors,
      accentColor: isWarming ? colors.warning : colors.info,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              Icon(
                isWarming ? SkotiqIcons.temperature : SkotiqIcons.frost,
                size: 16,
                color: isWarming ? colors.warning : colors.info,
              ),
              const SizedBox(width: 8),
              Text(
                isWarming ? 'Warming Camera' : 'Cooling Camera',
                style: SkotiqTypography.labelStrongSm
                    .copyWith(color: colors.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Temperature display
          Row(
            children: [
              // Current temp
              _TempDisplay(
                colors: colors,
                label: 'Current',
                temp: currentTemp,
                isTarget: false,
              ),
              const SizedBox(width: 16),
              // Arrow
              Icon(
                SkotiqIcons.arrowRight,
                size: 16,
                color: colors.textMuted,
              ),
              const SizedBox(width: 16),
              // Target temp
              _TempDisplay(
                colors: colors,
                label: 'Target',
                temp: targetTemp ?? currentTemp,
                isTarget: true,
              ),
              const Spacer(),
              // Power gauge
              if (power != null) _PowerGauge(colors: colors, power: power),
            ],
          ),
          const SizedBox(height: 12),

          // Progress bar
          _AnimatedProgressBar(
            colors: colors,
            progress: progressPercent / 100.0,
            color: isWarming ? colors.warning : colors.info,
          ),
        ],
      ),
    );
  }
}

class _TempDisplay extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final double? temp;
  final bool isTarget;

  const _TempDisplay({
    required this.colors,
    required this.label,
    this.temp,
    required this.isTarget,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize9,
            color: colors.textMuted,
          ),
        ),
        Text(
          temp != null ? '${temp!.toStringAsFixed(1)}°C' : '--°C',
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize16,
            fontWeight: FontWeight.w700,
            color: isTarget ? colors.info : colors.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _PowerGauge extends StatelessWidget {
  final SkotiqColors colors;
  final double power;

  const _PowerGauge({required this.colors, required this.power});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          'Power',
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize9,
            color: colors.textMuted,
          ),
        ),
        Row(
          children: [
            SizedBox(
              width: 40,
              height: 8,
              child: ClipRRect(
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline4),
                child: LinearProgressIndicator(
                  value: power / 100.0,
                  backgroundColor: colors.border,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    power > 80
                        ? colors.error
                        : power > 50
                            ? colors.warning
                            : colors.success,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '${power.toStringAsFixed(0)}%',
              style:
                  SkotiqTypography.h6.copyWith(color: colors.textPrimary),
            ),
          ],
        ),
      ],
    );
  }
}
