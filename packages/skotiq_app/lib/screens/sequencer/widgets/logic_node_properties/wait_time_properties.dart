part of '../logic_node_properties.dart';

class WaitTimeProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final WaitTimeNode node;

  const WaitTimeProperties(
      {super.key, required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Wait Settings',
          style: TextStyle(
            fontSize: Responsive.fontSize(context, 13),
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Wait for',
          child: NodeDropdown<String>(
            colors: colors,
            value: node.waitForTwilight != null ? 'twilight' : 'time',
            items: const ['time', 'twilight'],
            labelBuilder: (v) => v == 'time' ? 'Specific Time' : 'Twilight',
            onChanged: (value) {
              if (value == 'twilight') {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(
                          waitForTwilight: TwilightType.astronomical,
                          clearWaitUntil: true),
                    );
              } else {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(clearWaitForTwilight: true),
                    );
              }
            },
          ),
        ),
        if (node.waitForTwilight != null) ...[
          NodePropertyField(
            colors: colors,
            label: 'Twilight type',
            child: NodeDropdown<TwilightType>(
              colors: colors,
              value: node.waitForTwilight!,
              items: TwilightType.values,
              labelBuilder: (t) {
                switch (t) {
                  case TwilightType.civil:
                    return 'Civil (-6\u00B0)';
                  case TwilightType.nautical:
                    return 'Nautical (-12\u00B0)';
                  case TwilightType.astronomical:
                    return 'Astronomical (-18\u00B0)';
                }
              },
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(waitForTwilight: value),
                    );
              },
            ),
          ),
        ],
        if (node.waitForTwilight == null) ...[
          NodePropertyField(
            colors: colors,
            label: 'Wait until',
            child: GestureDetector(
              onTap: () async {
                final time = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay.now(),
                );
                if (time != null) {
                  final now = DateTime.now();
                  var targetDate = DateTime(
                      now.year, now.month, now.day, time.hour, time.minute);
                  if (targetDate.isBefore(now)) {
                    targetDate = targetDate.add(const Duration(days: 1));
                  }
                  ref.read(currentSequenceProvider.notifier).updateNode(
                        node.copyWith(waitUntil: targetDate),
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
                      node.waitUntil != null
                          ? '${node.waitUntil!.hour.toString().padLeft(2, '0')}:${node.waitUntil!.minute.toString().padLeft(2, '0')}'
                          : 'Select time...',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize13,
                        color: node.waitUntil != null
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
      ],
    );
  }
}
