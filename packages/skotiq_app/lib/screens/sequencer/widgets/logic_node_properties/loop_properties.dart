part of '../logic_node_properties.dart';

class LoopProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final LoopNode node;

  const LoopProperties({super.key, required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Belt-and-suspenders gate. The parent _NodeEditor
    // already wraps the editor body in IgnorePointer when running; wrap our
    // own subtree in IgnorePointer too so that a future refactor pulling
    // LoopProperties out of the panel can't silently un-gate the inputs.
    final canEdit = ref.watch(canEditSequenceProvider);
    return IgnorePointer(
      ignoring: !canEdit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Loop Settings',
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
            child: NodeDropdown<LoopConditionType>(
              colors: colors,
              value: node.conditionType,
              items: LoopConditionType.values,
              labelBuilder: (t) {
                switch (t) {
                  case LoopConditionType.count:
                    return 'Fixed Count';
                  case LoopConditionType.untilTime:
                    return 'Until Time';
                  case LoopConditionType.untilAltitude:
                    return 'Until Altitude Below';
                  case LoopConditionType.altitudeAbove:
                    return 'Until Altitude Above';
                  case LoopConditionType.integrationTime:
                    return 'Until Integration Time';
                  case LoopConditionType.forever:
                    return 'Forever';
                  case LoopConditionType.whileDark:
                    return 'While Dark';
                }
              },
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(conditionType: value),
                    );
              },
            ),
          ),
          if (node.conditionType == LoopConditionType.count)
            NodePropertyField(
              colors: colors,
              label: 'Repeat count',
              child: NodeNumberInput(
                colors: colors,
                value: (node.repeatCount ?? 1).toDouble(),
                min: 1,
                max: 9999,
                onChanged: (value) {
                  ref.read(currentSequenceProvider.notifier).updateNode(
                        node.copyWith(repeatCount: value.toInt()),
                      );
                },
              ),
            ),
          if (node.conditionType == LoopConditionType.untilTime)
            NodePropertyField(
              colors: colors,
              label: 'Stop time',
              child: Column(
                children: [
                  GestureDetector(
                    onTap: () async {
                      final time = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.fromDateTime(
                            node.repeatUntil ?? DateTime.now()),
                      );
                      if (time != null) {
                        final now = DateTime.now();
                        var targetDate = DateTime(now.year, now.month, now.day,
                            time.hour, time.minute);
                        if (targetDate.isBefore(now)) {
                          targetDate = targetDate.add(const Duration(days: 1));
                        }
                        ref.read(currentSequenceProvider.notifier).updateNode(
                              node.copyWith(repeatUntil: targetDate),
                            );
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: colors.surfaceAlt,
                        borderRadius: BorderRadius.circular(
                            SkotiqTokens.radiusInline8),
                        border: Border.all(color: colors.border),
                      ),
                      child: Row(
                        children: [
                          Icon(LucideIcons.clock,
                              size: 14, color: colors.textMuted),
                          const SizedBox(width: 8),
                          Text(
                            node.repeatUntil != null
                                ? '${node.repeatUntil!.hour.toString().padLeft(2, '0')}:${node.repeatUntil!.minute.toString().padLeft(2, '0')}'
                                : 'Select time...',
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize13,
                              color: node.repeatUntil != null
                                  ? colors.textPrimary
                                  : colors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Quick set buttons for common times
                  Row(
                    children: [
                      NodeQuickTimeButton(
                        colors: colors,
                        label: 'Civil dawn',
                        onPressed: () {
                          // Twilight is a property of a place. With no site on
                          // record there is no dawn to set the loop against.
                          final site = ref.read(observerLocationProvider).site;
                          if (site == null) return;
                          final now = DateTime.now();

                          // Calculate for today first
                          var twilight =
                              AstronomyCalculations.calculateTwilightTimes(
                            date: now,
                            latitudeDeg: site.latitude,
                            longitudeDeg: site.longitude,
                          );

                          var target = twilight.civilDawn;

                          // If dawn passed or not available today, try tomorrow
                          if (target == null || target.isBefore(now)) {
                            twilight =
                                AstronomyCalculations.calculateTwilightTimes(
                              date: now.add(const Duration(days: 1)),
                              latitudeDeg: site.latitude,
                              longitudeDeg: site.longitude,
                            );
                            target = twilight.civilDawn;
                          }

                          if (target != null) {
                            ref
                                .read(currentSequenceProvider.notifier)
                                .updateNode(
                                  node.copyWith(repeatUntil: target),
                                );
                          }
                        },
                      ),
                      const SizedBox(width: 8),
                      NodeQuickTimeButton(
                        colors: colors,
                        label: 'Nautical dawn',
                        onPressed: () {
                          // Twilight is a property of a place. With no site on
                          // record there is no dawn to set the loop against.
                          final site = ref.read(observerLocationProvider).site;
                          if (site == null) return;
                          final now = DateTime.now();

                          // Calculate for today first
                          var twilight =
                              AstronomyCalculations.calculateTwilightTimes(
                            date: now,
                            latitudeDeg: site.latitude,
                            longitudeDeg: site.longitude,
                          );

                          var target = twilight.nauticalDawn;

                          // If dawn passed or not available today, try tomorrow
                          if (target == null || target.isBefore(now)) {
                            twilight =
                                AstronomyCalculations.calculateTwilightTimes(
                              date: now.add(const Duration(days: 1)),
                              latitudeDeg: site.latitude,
                              longitudeDeg: site.longitude,
                            );
                            target = twilight.nauticalDawn;
                          }

                          if (target != null) {
                            ref
                                .read(currentSequenceProvider.notifier)
                                .updateNode(
                                  node.copyWith(repeatUntil: target),
                                );
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (node.conditionType == LoopConditionType.untilAltitude)
            NodePropertyField(
              colors: colors,
              label: 'Stop Below Altitude',
              child: NodeNumberInput(
                colors: colors,
                value: node.repeatUntilAltitude ?? 30,
                suffix: '\u00B0',
                min: 0,
                max: 90,
                onChanged: (value) {
                  ref.read(currentSequenceProvider.notifier).updateNode(
                        node.copyWith(repeatUntilAltitude: value),
                      );
                },
              ),
            ),
          if (node.conditionType == LoopConditionType.altitudeAbove)
            NodePropertyField(
              colors: colors,
              label: 'Loop Until Above Altitude',
              child: NodeNumberInput(
                colors: colors,
                value: node.repeatUntilAltitude ?? 30,
                suffix: '\u00B0',
                min: 0,
                max: 90,
                onChanged: (value) {
                  ref.read(currentSequenceProvider.notifier).updateNode(
                        node.copyWith(repeatUntilAltitude: value),
                      );
                },
              ),
            ),
          if (node.conditionType == LoopConditionType.integrationTime)
            NodePropertyField(
              colors: colors,
              label: 'Target Integration Time',
              child: NodeNumberInput(
                colors: colors,
                value: (node.integrationTimeTarget ?? 3600) / 60.0,
                suffix: 'min',
                min: 1,
                max: 1440,
                decimals: 0,
                onChanged: (value) {
                  ref.read(currentSequenceProvider.notifier).updateNode(
                        node.copyWith(integrationTimeTarget: value * 60.0),
                      );
                },
              ),
            ),

          // Safety iteration limit for unbounded loops
          if (node.isUnbounded) ...[
            const SizedBox(height: 8),
            _UnboundedLoopSafetySection(colors: colors, node: node),
          ],
        ],
      ),
    );
  }
}

/// Safety limit section for Forever/WhileDark loops.
