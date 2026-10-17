part of '../logic_node_properties.dart';

class ConditionalProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final ConditionalNode node;

  const ConditionalProperties(
      {super.key, required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Condition Settings',
          style: TextStyle(
            fontSize: Responsive.fontSize(context, 13),
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Condition type',
          child: NodeDropdown<ConditionalType>(
            colors: colors,
            value: node.conditionType,
            items: ConditionalType.values,
            labelBuilder: (t) {
              switch (t) {
                case ConditionalType.always:
                  return 'Always Execute';
                case ConditionalType.altitudeAbove:
                  return 'Altitude Above';
                case ConditionalType.timeAfter:
                  return 'Time After';
                case ConditionalType.guidingRmsBelow:
                  return 'Guiding RMS Below';
                case ConditionalType.hfrBelow:
                  return 'HFR Below';
                case ConditionalType.weatherSafe:
                  return 'Weather is Safe';
                case ConditionalType.moonSeparationAbove:
                  return 'Moon Separation Above';
                case ConditionalType.safetyMonitorSafe:
                  return 'Safety Monitor Safe';
              }
            },
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(conditionType: value),
                  );
            },
          ),
        ),
        if (node.conditionType == ConditionalType.altitudeAbove ||
            node.conditionType == ConditionalType.moonSeparationAbove)
          NodePropertyField(
            colors: colors,
            label: 'Threshold (degrees)',
            child: NodeNumberInput(
              colors: colors,
              value: node.thresholdValue ?? 30,
              suffix: '\u00B0',
              min: 0,
              max: 90,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(thresholdValue: value),
                    );
              },
            ),
          ),
        if (node.conditionType == ConditionalType.guidingRmsBelow)
          NodePropertyField(
            colors: colors,
            label: 'Max RMS (arcsec)',
            child: NodeNumberInput(
              colors: colors,
              value: node.thresholdValue ?? 1.5,
              suffix: '"',
              min: 0.1,
              max: 10,
              decimals: 1,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(thresholdValue: value),
                    );
              },
            ),
          ),
        if (node.conditionType == ConditionalType.hfrBelow)
          NodePropertyField(
            colors: colors,
            label: 'Max HFR (pixels)',
            child: NodeNumberInput(
              colors: colors,
              value: node.thresholdValue ?? 3.0,
              suffix: 'px',
              min: 0.5,
              max: 20,
              decimals: 1,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(thresholdValue: value),
                    );
              },
            ),
          ),
        if (node.conditionType == ConditionalType.timeAfter)
          NodePropertyField(
            colors: colors,
            label: 'Execute After Time',
            child: GestureDetector(
              onTap: () async {
                final time = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay.fromDateTime(
                      node.thresholdTime ?? DateTime.now()),
                );
                if (time != null) {
                  final now = DateTime.now();
                  var targetDate = DateTime(
                      now.year, now.month, now.day, time.hour, time.minute);
                  if (targetDate.isBefore(now)) {
                    targetDate = targetDate.add(const Duration(days: 1));
                  }
                  ref.read(currentSequenceProvider.notifier).updateNode(
                        node.copyWith(thresholdTime: targetDate),
                      );
                }
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: colors.surfaceAlt,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                  border: Border.all(color: colors.border),
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.clock, size: 14, color: colors.textMuted),
                    const SizedBox(width: 8),
                    Text(
                      node.thresholdTime != null
                          ? '${node.thresholdTime!.hour.toString().padLeft(2, '0')}:${node.thresholdTime!.minute.toString().padLeft(2, '0')}'
                          : 'Select time...',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize13,
                        color: node.thresholdTime != null
                            ? colors.textPrimary
                            : colors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
